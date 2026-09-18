using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

internal interface IWorkerConnection : IDisposable
{
    Task WriteLineAsync(string line);
    Task<string> ReadLineAsync(int maximumBytes);
    string ErrorText { get; }
    void Kill();
}

internal interface IWorkerConnectionFactory
{
    IWorkerConnection Start(string root);
}

internal sealed class WorkerRequestException : InvalidOperationException
{
    internal string Payload { get; private set; }

    internal WorkerRequestException(string message, string payload) : base(message)
    {
        Payload = payload;
    }
}

internal sealed class WorkerClient : IDisposable
{
    private const int MaximumQueuedRequests = 64;
    private const int MaximumRequestBytes = 1024 * 1024;
    private const int MaximumResponseBytes = 4 * 1024 * 1024;

    private sealed class WorkItem
    {
        internal Dictionary<string, object> Request;
        internal int Timeout;
        internal TaskCompletionSource<string> Completion;
    }

    private readonly string root;
    private readonly IWorkerConnectionFactory factory;
    private readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = MaximumResponseBytes };
    private readonly object gate = new object();
    private readonly Queue<WorkItem> priority = new Queue<WorkItem>();
    private readonly Queue<WorkItem> normal = new Queue<WorkItem>();
    private IWorkerConnection connection;
    private WorkItem current;
    private WorkItem pendingList;
    private bool pumping;
    private bool disposed;
    private int connectionGeneration;

    internal WorkerClient(string applicationRoot) : this(applicationRoot, new ProcessWorkerConnectionFactory()) { }

    internal WorkerClient(string applicationRoot, IWorkerConnectionFactory connectionFactory)
    {
        if (String.IsNullOrWhiteSpace(applicationRoot)) throw new ArgumentNullException("applicationRoot");
        if (connectionFactory == null) throw new ArgumentNullException("connectionFactory");
        root = Path.GetFullPath(applicationRoot);
        factory = connectionFactory;
    }

    internal Task<string> InvokeAsync(Dictionary<string, object> request, int timeout)
    {
        if (request == null) throw new ArgumentNullException("request");
        if (timeout < 1) throw new ArgumentOutOfRangeException("timeout");
        Dictionary<string, object> copy = new Dictionary<string, object>(request, StringComparer.OrdinalIgnoreCase);
        TaskCompletionSource<string> completion = new TaskCompletionSource<string>();
        WorkItem item = new WorkItem { Request = copy, Timeout = timeout, Completion = completion };
        lock (gate)
        {
            if (disposed) throw new ObjectDisposedException("WorkerClient");
            string action = GetString(copy, "action");
            if (String.Equals(action, "list", StringComparison.OrdinalIgnoreCase) && pendingList != null) return pendingList.Completion.Task;
            if (priority.Count + normal.Count >= MaximumQueuedRequests)
            {
                completion.SetException(new InvalidOperationException("Too many Monitor Tools operations are queued."));
                return completion.Task;
            }
            if (String.Equals(action, "profile", StringComparison.OrdinalIgnoreCase)) priority.Enqueue(item);
            else
            {
                normal.Enqueue(item);
                if (String.Equals(action, "list", StringComparison.OrdinalIgnoreCase)) pendingList = item;
            }
            if (!pumping)
            {
                pumping = true;
                Task.Run((Func<Task>)PumpAsync);
            }
        }
        return completion.Task;
    }

    private async Task PumpAsync()
    {
        while (true)
        {
            WorkItem item;
            lock (gate)
            {
                if (disposed) { pumping = false; return; }
                if (priority.Count > 0) item = priority.Dequeue();
                else if (normal.Count > 0)
                {
                    item = normal.Dequeue();
                    if (Object.ReferenceEquals(pendingList, item)) pendingList = null;
                }
                else { pumping = false; return; }
                current = item;
            }
            try
            {
                string result = await DispatchAsync(item).ConfigureAwait(false);
                item.Completion.TrySetResult(result);
            }
            catch (Exception error)
            {
                item.Completion.TrySetException(error);
            }
            finally
            {
                lock (gate) { if (Object.ReferenceEquals(current, item)) current = null; }
            }
        }
    }

    private async Task<string> DispatchAsync(WorkItem item)
    {
        string id = Guid.NewGuid().ToString("N");
        item.Request["id"] = id;
        string line = json.Serialize(item.Request);
        if (Encoding.UTF8.GetByteCount(line) > MaximumRequestBytes) throw new InvalidOperationException("The Monitor Tools request is too large.");

        IWorkerConnection active = null;
        int generation;
        lock (gate) { generation = connectionGeneration; }
        Task<string> exchange = Task.Run(async delegate {
            active = EnsureConnection(generation);
            return await ExchangeAsync(active, line).ConfigureAwait(false);
        });
        CancellationTokenSource timeoutCancellation = new CancellationTokenSource();
        Task timeoutTask = Task.Delay(item.Timeout, timeoutCancellation.Token);
        Task winner = await Task.WhenAny(exchange, timeoutTask).ConfigureAwait(false);
        if (Object.ReferenceEquals(winner, exchange)) timeoutCancellation.Cancel();
        timeoutCancellation.Dispose();
        if (!Object.ReferenceEquals(winner, exchange))
        {
            Task ignoredTask = exchange.ContinueWith(delegate(Task<string> failed) { Exception ignored = failed.Exception; }, TaskContinuationOptions.OnlyOnFaulted);
            string details = ResetConnection(active, generation);
            FailQueued("The Monitor Tools worker was restarted after a timeout; queued operations were canceled.");
            throw new TimeoutException("The monitor operation timed out. Its hardware result is unknown and it was not retried." + FormatDetails(details));
        }

        string responseLine;
        try { responseLine = await exchange.ConfigureAwait(false); }
        catch (Exception error)
        {
            string details = ResetConnection(active, generation);
            FailQueued("The Monitor Tools worker stopped; queued operations were canceled.");
            if (error is InvalidDataException) throw;
            throw new InvalidOperationException("The Monitor Tools worker stopped before replying. The operation was not retried." + FormatDetails(details), error);
        }
        if (responseLine == null)
        {
            string details = ResetConnection(active, generation);
            FailQueued("The Monitor Tools worker stopped; queued operations were canceled.");
            throw new InvalidOperationException("The Monitor Tools worker closed unexpectedly. The operation was not retried." + FormatDetails(details));
        }
        Dictionary<string, object> response;
        try { response = json.Deserialize<Dictionary<string, object>>(responseLine); }
        catch (Exception error)
        {
            ResetConnection(active, generation);
            FailQueued("The Monitor Tools worker returned invalid data; queued operations were canceled.");
            throw new InvalidDataException("The Monitor Tools worker returned invalid JSON.", error);
        }
        if (response == null || !String.Equals(GetString(response, "id"), id, StringComparison.Ordinal))
        {
            ResetConnection(active, generation);
            FailQueued("The Monitor Tools worker response did not match its request; queued operations were canceled.");
            throw new InvalidDataException("The Monitor Tools worker returned a mismatched response.");
        }
        string payload = GetString(response, "payload") ?? "";
        object successValue;
        bool success = response.TryGetValue("success", out successValue) && Convert.ToBoolean(successValue);
        if (!success)
        {
            string message = GetString(response, "error");
            if (String.IsNullOrWhiteSpace(message)) message = "The Monitor Tools worker rejected the operation.";
            throw new WorkerRequestException(message, payload);
        }
        return payload;
    }

    private static async Task<string> ExchangeAsync(IWorkerConnection active, string line)
    {
        await active.WriteLineAsync(line).ConfigureAwait(false);
        return await active.ReadLineAsync(MaximumResponseBytes).ConfigureAwait(false);
    }

    private IWorkerConnection EnsureConnection(int expectedGeneration)
    {
        lock (gate)
        {
            if (disposed) throw new ObjectDisposedException("WorkerClient");
            if (connectionGeneration != expectedGeneration) throw new InvalidOperationException("The worker start was canceled.");
            if (connection != null) return connection;
        }
        IWorkerConnection candidate = factory.Start(root);
        lock (gate)
        {
            if (disposed || connectionGeneration != expectedGeneration)
            {
                try { candidate.Kill(); } catch { }
                candidate.Dispose();
                throw new InvalidOperationException("The worker start was canceled.");
            }
            if (connection == null) connection = candidate;
            else candidate.Dispose();
            return connection;
        }
    }

    private string ResetConnection(IWorkerConnection expected, int expectedGeneration)
    {
        IWorkerConnection stopped = null;
        lock (gate)
        {
            if (connectionGeneration == expectedGeneration) connectionGeneration++;
            if (expected == null || Object.ReferenceEquals(connection, expected)) { stopped = connection; connection = null; }
        }
        if (stopped == null) return "";
        try { stopped.Kill(); } catch { }
        string details = stopped.ErrorText;
        try { stopped.Dispose(); } catch { }
        return details;
    }

    private void FailQueued(string message)
    {
        List<WorkItem> canceled = new List<WorkItem>();
        lock (gate)
        {
            while (priority.Count > 0) canceled.Add(priority.Dequeue());
            while (normal.Count > 0) canceled.Add(normal.Dequeue());
            pendingList = null;
        }
        foreach (WorkItem item in canceled) item.Completion.TrySetException(new InvalidOperationException(message));
    }

    private static string GetString(Dictionary<string, object> value, string name)
    {
        object item;
        return value.TryGetValue(name, out item) && item != null ? Convert.ToString(item) : null;
    }

    private static string FormatDetails(string value)
    {
        if (String.IsNullOrWhiteSpace(value)) return "";
        value = value.Replace('\r', ' ').Replace('\n', ' ').Trim();
        if (value.Length > 500) value = value.Substring(0, 500) + "…";
        return " Worker detail: " + value;
    }

    public void Dispose()
    {
        IWorkerConnection stopped;
        WorkItem active;
        List<WorkItem> canceled = new List<WorkItem>();
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            connectionGeneration++;
            stopped = connection; connection = null;
            active = current;
            while (priority.Count > 0) canceled.Add(priority.Dequeue());
            while (normal.Count > 0) canceled.Add(normal.Dequeue());
            pendingList = null;
        }
        ObjectDisposedException error = new ObjectDisposedException("WorkerClient");
        if (active != null) active.Completion.TrySetException(error);
        foreach (WorkItem item in canceled) item.Completion.TrySetException(error);
        if (stopped != null)
        {
            try { stopped.Kill(); } catch { }
            try { stopped.Dispose(); } catch { }
        }
    }
}

internal sealed class ProcessWorkerConnectionFactory : IWorkerConnectionFactory
{
    public IWorkerConnection Start(string root) { return new ProcessWorkerConnection(root); }
}

internal sealed class ProcessWorkerConnection : IWorkerConnection
{
    private readonly Process process;
    private readonly StreamWriter input;
    private readonly StreamReader output;
    private string outputCarry = "";
    private readonly object errorGate = new object();
    private readonly StringBuilder errors = new StringBuilder();

    internal ProcessWorkerConnection(string root)
    {
        string executable = Path.Combine(root, "app", "MonitorTools.Worker.exe");
        if (!File.Exists(executable)) throw new FileNotFoundException("MonitorTools.Worker.exe is not installed.", executable);
        int parentId;
        long startTicks;
        using (Process parent = Process.GetCurrentProcess())
        {
            parentId = parent.Id;
            try { startTicks = parent.StartTime.ToUniversalTime().Ticks; }
            catch { startTicks = DateTime.UtcNow.Ticks; }
        }
        ProcessStartInfo start = new ProcessStartInfo(executable,
            "--parent " + parentId + " --parent-start " + startTicks);
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardInput = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.StandardOutputEncoding = new UTF8Encoding(false);
        start.StandardErrorEncoding = new UTF8Encoding(false);
        start.WorkingDirectory = root;
        process = Process.Start(start);
        input = new StreamWriter(process.StandardInput.BaseStream, new UTF8Encoding(false));
        input.AutoFlush = true;
        output = process.StandardOutput;
        process.ErrorDataReceived += ErrorReceived;
        process.BeginErrorReadLine();
    }

    public Task WriteLineAsync(string line) { return input.WriteLineAsync(line); }
    public async Task<string> ReadLineAsync(int maximumBytes)
    {
        StringBuilder line = new StringBuilder();
        int byteCount = 0;
        char[] buffer = new char[4096];
        while (true)
        {
            string value;
            if (outputCarry.Length > 0) { value = outputCarry; outputCarry = ""; }
            else
            {
                int count = await output.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                if (count == 0) return line.Length == 0 ? null : line.ToString();
                value = new string(buffer, 0, count);
            }
            int newline = value.IndexOf('\n');
            string part = newline >= 0 ? value.Substring(0, newline) : value;
            if (newline >= 0 && part.EndsWith("\r", StringComparison.Ordinal)) part = part.Substring(0, part.Length - 1);
            byteCount += Encoding.UTF8.GetByteCount(part);
            if (byteCount > maximumBytes) throw new InvalidDataException("The Monitor Tools worker response exceeded 4 MiB.");
            line.Append(part);
            if (newline >= 0)
            {
                outputCarry = value.Substring(newline + 1);
                return line.ToString();
            }
        }
    }

    private void ErrorReceived(object sender, DataReceivedEventArgs e)
    {
        if (e.Data == null) return;
        lock (errorGate)
        {
            if (errors.Length < 8192) errors.AppendLine(e.Data);
        }
    }

    public string ErrorText { get { lock (errorGate) { return errors.ToString(); } } }

    public void Kill()
    {
        if (!process.HasExited)
        {
            process.Kill();
            process.WaitForExit(2000);
        }
    }

    public void Dispose()
    {
        try { input.Close(); } catch { }
        try { if (!process.HasExited) process.WaitForExit(1000); } catch { }
        process.Dispose();
    }
}
