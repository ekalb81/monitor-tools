using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

internal static class WorkerClientTests
{
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();

    private static int Main(string[] args)
    {
        try
        {
            TestPriorityAndCoalescing();
            TestTimeoutDoesNotReplay();
            TestCrashCancelsQueuedRequests();
            TestWorkerFailurePreservesPayload();
            TestWorkerStartUsesRequestTimeout();
            TestOversizedRequestRejectedBeforeStart();
            if (args.Length == 2 && args[0] == "--transport") TestProductionTransport(args[1]);
            Console.WriteLine("PASS: persistent worker priority, scan coalescing, timeout, crash recovery, and no replay");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }

    private static void TestProductionTransport(string root)
    {
        using (WorkerClient client = new WorkerClient(root))
        {
            string payload = client.InvokeAsync(Request("ping"), 3000).GetAwaiter().GetResult();
            Assert(payload.Contains("--parent ") && payload.Contains(" --parent-start "), "Production transport must send parent identity arguments.");
            Assert(payload.Contains("påss-✓"), "Production transport must preserve UTF-8 request and response data.");
            ExpectFailure<System.IO.InvalidDataException>(client.InvokeAsync(Request("oversized"), 5000),
                "Production transport must reject an oversized response while reading it.");
        }
    }

    private static void TestPriorityAndCoalescing()
    {
        FakeConnection connection = new FakeConnection();
        FakeFactory factory = new FakeFactory(connection);
        using (WorkerClient client = new WorkerClient("C:\\monitor-tools-test", factory))
        {
            Task<string> first = client.InvokeAsync(Request("diagnostics"), 3000);
            connection.WaitForWrites(1);
            Task<string> scanOne = client.InvokeAsync(Request("list"), 3000);
            Task<string> scanTwo = client.InvokeAsync(Request("list"), 3000);
            Task<string> profile = client.InvokeAsync(Request("profile"), 3000);
            Assert(Object.ReferenceEquals(scanOne, scanTwo), "Queued list requests must coalesce.");

            connection.Complete(0, true, "first", null);
            connection.WaitForWrites(2);
            Assert(connection.ActionAt(1) == "profile", "Profiles must run before queued background requests.");
            connection.Complete(1, true, "profile", null);
            connection.WaitForWrites(3);
            Assert(connection.ActionAt(2) == "list", "The coalesced list request must run after the profile.");
            connection.Complete(2, true, "scan", null);
            Task.WaitAll(first, scanOne, scanTwo, profile);
            Assert(connection.WriteCount == 3, "Two queued scans must produce one worker request.");
        }
    }

    private static void TestTimeoutDoesNotReplay()
    {
        FakeConnection timedOut = new FakeConnection();
        FakeConnection restarted = new FakeConnection();
        FakeFactory factory = new FakeFactory(timedOut, restarted);
        using (WorkerClient client = new WorkerClient("C:\\monitor-tools-test", factory))
        {
            Task<string> request = client.InvokeAsync(Request("profile"), 75);
            timedOut.WaitForWrites(1);
            ExpectFailure<TimeoutException>(request, "A timed-out profile must report an indeterminate result.");
            Assert(timedOut.Killed, "A timed-out worker must be killed.");
            Assert(timedOut.WriteCount == 1, "A timed-out profile must not be replayed.");

            Task<string> next = client.InvokeAsync(Request("ping"), 3000);
            restarted.WaitForWrites(1);
            restarted.Complete(0, true, "pong", null);
            Assert(next.GetAwaiter().GetResult() == "pong", "The next explicit request must start a fresh worker.");
            Assert(factory.StartCount == 2, "Exactly one replacement worker should start.");
        }
    }

    private static void TestCrashCancelsQueuedRequests()
    {
        FakeConnection crashed = new FakeConnection();
        FakeConnection restarted = new FakeConnection();
        FakeFactory factory = new FakeFactory(crashed, restarted);
        using (WorkerClient client = new WorkerClient("C:\\monitor-tools-test", factory))
        {
            Task<string> active = client.InvokeAsync(Request("diagnostics"), 3000);
            crashed.WaitForWrites(1);
            Task<string> queued = client.InvokeAsync(Request("profile"), 3000);
            crashed.CompleteEof(0);
            ExpectFailure<InvalidOperationException>(active, "A crashed worker must fail the active request.");
            ExpectFailure<InvalidOperationException>(queued, "A crashed worker must cancel queued profile requests rather than replay them.");
            Assert(crashed.WriteCount == 1, "A queued profile must not reach a crashed worker.");

            Task<string> next = client.InvokeAsync(Request("ping"), 3000);
            restarted.WaitForWrites(1);
            restarted.Complete(0, true, "pong", null);
            Assert(next.GetAwaiter().GetResult() == "pong", "A later explicit request must recover after a crash.");
        }
    }

    private static void TestWorkerFailurePreservesPayload()
    {
        FakeConnection connection = new FakeConnection();
        FakeFactory factory = new FakeFactory(connection);
        using (WorkerClient client = new WorkerClient("C:\\monitor-tools-test", factory))
        {
            Task<string> failed = client.InvokeAsync(Request("profile"), 3000);
            connection.WaitForWrites(1);
            connection.Complete(0, false, "partial-result", "one monitor failed");
            bool sawFailure = false;
            try { failed.GetAwaiter().GetResult(); }
            catch (WorkerRequestException error)
            {
                sawFailure = true;
                Assert(error.Payload == "partial-result", "Worker failures must preserve structured partial results.");
                Assert(error.Message == "one monitor failed", "Worker failures must preserve their error message.");
            }
            Assert(sawFailure, "A worker-reported failure must fault the request.");
            Task<string> next = client.InvokeAsync(Request("ping"), 3000);
            connection.WaitForWrites(2);
            connection.Complete(1, true, "pong", null);
            Assert(next.GetAwaiter().GetResult() == "pong", "A reported operation failure must not discard a healthy worker.");
            Assert(factory.StartCount == 1, "Application-level failures should reuse the worker.");
        }
    }

    private static void TestWorkerStartUsesRequestTimeout()
    {
        FakeConnection late = new FakeConnection();
        SlowFactory factory = new SlowFactory(late, 300);
        using (WorkerClient client = new WorkerClient("C:\\monitor-tools-test", factory))
        {
            DateTime started = DateTime.UtcNow;
            Task<string> request = client.InvokeAsync(Request("ping"), 75);
            ExpectFailure<TimeoutException>(request, "Worker startup must be covered by the request timeout.");
            Assert((DateTime.UtcNow - started).TotalMilliseconds < 250, "A blocked worker start delayed the timeout.");
            Thread.Sleep(350);
            Assert(late.Killed, "A worker that starts after its request timed out must be reaped.");
            Assert(late.WriteCount == 0, "A late worker must not receive the timed-out request.");
        }
    }

    private static void TestOversizedRequestRejectedBeforeStart()
    {
        FakeFactory factory = new FakeFactory();
        using (WorkerClient client = new WorkerClient("C:\\monitor-tools-test", factory))
        {
            Dictionary<string, object> request = Request("ping");
            request["value"] = new string('x', 1024 * 1024 + 1);
            ExpectFailure<InvalidOperationException>(client.InvokeAsync(request, 3000), "Oversized requests must be rejected.");
            Assert(factory.StartCount == 0, "An oversized request must not start the worker.");
        }
    }

    private static Dictionary<string, object> Request(string action)
    {
        return new Dictionary<string, object> { { "action", action } };
    }

    private static void ExpectFailure<T>(Task<string> task, string message) where T : Exception
    {
        try { task.GetAwaiter().GetResult(); }
        catch (T) { return; }
        catch (Exception error) { throw new InvalidOperationException(message + " Received " + error.GetType().Name + ".", error); }
        throw new InvalidOperationException(message + " The task succeeded unexpectedly.");
    }

    private static void Assert(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }

    private sealed class FakeFactory : IWorkerConnectionFactory
    {
        private readonly Queue<FakeConnection> connections = new Queue<FakeConnection>();
        internal int StartCount;

        internal FakeFactory(params FakeConnection[] values)
        {
            foreach (FakeConnection value in values) connections.Enqueue(value);
        }

        public IWorkerConnection Start(string root)
        {
            StartCount++;
            if (connections.Count == 0) throw new InvalidOperationException("No fake worker remains.");
            return connections.Dequeue();
        }
    }

    private sealed class SlowFactory : IWorkerConnectionFactory
    {
        private readonly FakeConnection connection;
        private readonly int delay;
        internal SlowFactory(FakeConnection value, int delayMilliseconds) { connection = value; delay = delayMilliseconds; }
        public IWorkerConnection Start(string root) { Thread.Sleep(delay); return connection; }
    }

    private sealed class FakeConnection : IWorkerConnection
    {
        private sealed class Exchange
        {
            internal string Id;
            internal string Action;
            internal TaskCompletionSource<string> Response = new TaskCompletionSource<string>();
        }

        private readonly object gate = new object();
        private readonly List<Exchange> exchanges = new List<Exchange>();
        private readonly AutoResetEvent wrote = new AutoResetEvent(false);
        private int reads;
        internal bool Killed;

        internal int WriteCount { get { lock (gate) { return exchanges.Count; } } }
        public string ErrorText { get { return "fake worker detail"; } }

        public Task WriteLineAsync(string line)
        {
            Dictionary<string, object> request = Json.Deserialize<Dictionary<string, object>>(line);
            lock (gate)
            {
                exchanges.Add(new Exchange { Id = Convert.ToString(request["id"]), Action = Convert.ToString(request["action"]) });
            }
            wrote.Set();
            return Task.FromResult(0);
        }

        public Task<string> ReadLineAsync(int maximumBytes)
        {
            lock (gate)
            {
                if (reads >= exchanges.Count) throw new InvalidOperationException("Read was requested before write.");
                return exchanges[reads++].Response.Task;
            }
        }

        internal void WaitForWrites(int count)
        {
            DateTime deadline = DateTime.UtcNow.AddSeconds(3);
            while (WriteCount < count)
            {
                int remaining = (int)Math.Max(1, (deadline - DateTime.UtcNow).TotalMilliseconds);
                if (DateTime.UtcNow >= deadline || !wrote.WaitOne(remaining)) throw new TimeoutException("Timed out waiting for fake worker request " + count + ".");
            }
        }

        internal string ActionAt(int index) { lock (gate) { return exchanges[index].Action; } }

        internal void Complete(int index, bool success, string payload, string error)
        {
            Exchange item; lock (gate) { item = exchanges[index]; }
            item.Response.TrySetResult(Json.Serialize(new Dictionary<string, object> {
                { "id", item.Id }, { "success", success }, { "payload", payload }, { "error", error }
            }));
        }

        internal void CompleteEof(int index)
        {
            Exchange item; lock (gate) { item = exchanges[index]; }
            item.Response.TrySetResult(null);
        }

        public void Kill() { Killed = true; }
        public void Dispose() { wrote.Dispose(); }
    }
}

internal static class WorkerStub
{
    private static int Main(string[] args)
    {
        Console.InputEncoding = new System.Text.UTF8Encoding(false);
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 8 * 1024 * 1024 };
        string line;
        while ((line = Console.ReadLine()) != null)
        {
            Dictionary<string, object> request = json.Deserialize<Dictionary<string, object>>(line);
            string id = Convert.ToString(request["id"]);
            string action = Convert.ToString(request["action"]);
            if (action == "eof") return 2;
            string payload = action == "oversized" ? new string('x', 4 * 1024 * 1024 + 1) : String.Join(" ", args) + "|påss-✓";
            Dictionary<string, object> response = new Dictionary<string, object> {
                { "id", id }, { "success", true },
                { "payload", payload }, { "error", null }
            };
            Console.WriteLine(json.Serialize(response));
        }
        return 0;
    }
}
