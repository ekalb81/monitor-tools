using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;

namespace MonitorTools.Engine
{
    // A private child process: inherited stdin/stdout are the only command transport.
    // There is no listening socket, service account, or shared request directory.
    internal static class WorkerProgram
    {
        internal static int Main(string[] args)
        {
            Console.InputEncoding = new UTF8Encoding(false);
            Console.OutputEncoding = new UTF8Encoding(false);
            Process parent = null;
            Timer lifetime = null;
            try
            {
                if (args.Length != 0)
                {
                    if (args.Length != 4 || args[0] != "--parent" || args[2] != "--parent-start") throw new ArgumentException("Invalid worker arguments.");
                    parent = Process.GetProcessById(Int32.Parse(args[1]));
                    if (parent.StartTime.ToUniversalTime().Ticks != Int64.Parse(args[3])) return 1;
                    // EOF handles normal shutdown. This also stops an orphan stuck in a native call.
                    lifetime = new Timer(delegate {
                        try { if (parent.HasExited) Environment.Exit(0); }
                        catch { Environment.Exit(0); }
                    }, null, 1000, 1000);
                }
                string root = Directory.GetParent(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar)).FullName;
                var service = new WorkerService(root, new MonitorEngine());
                while (true)
                {
                    string line = ReadRequest(Console.In);
                    if (line == null) return 0;
                    Console.WriteLine(service.Handle(line));
                    Console.Out.Flush();
                }
            }
            catch (Exception ex) { Console.Error.WriteLine(ex.Message); return 1; }
            finally { if (lifetime != null) lifetime.Dispose(); if (parent != null) parent.Dispose(); }
        }

        internal static string ReadRequest(TextReader reader)
        {
            var line = new StringBuilder();
            int value;
            while ((value = reader.Read()) != -1)
            {
                if (value == '\n') return line.ToString().TrimEnd('\r');
                if (line.Length >= 1024 * 1024) throw new InvalidDataException("Worker request exceeds 1 MiB.");
                line.Append((char)value);
            }
            if (line.Length != 0) throw new InvalidDataException("Incomplete worker request.");
            return null;
        }
    }

    internal sealed class WorkerService
    {
        private readonly string root;
        private readonly MonitorEngine engine;
        internal WorkerService(string root, MonitorEngine engine) { this.root = root; this.engine = engine; }

        internal string Handle(string line)
        {
            var json = WorkerConfiguration.Json();
            string id = null, action = null, configPath = null, payload = null, error = null;
            bool success = false;
            DateTime started = DateTime.UtcNow;
            Dictionary<string, object> request = null;
            try
            {
                request = json.DeserializeObject(line) as Dictionary<string, object>;
                id = WorkerConfiguration.Text(WorkerConfiguration.Get(request, "id"));
                if (String.IsNullOrWhiteSpace(id) || id.Length > 128) throw new InvalidDataException("A worker request ID is required.");
                action = WorkerConfiguration.Text(WorkerConfiguration.Get(request, "action"));
                if (action == "ping") payload = json.Serialize(new { protocolVersion = 1, processId = Process.GetCurrentProcess().Id });
                else
                {
                    configPath = WorkerConfiguration.ConfigPath(root);
                    switch (action)
                    {
                        case "list":
                        case "profile":
                            payload = engine.Execute(request, configPath);
                            var result = json.DeserializeObject(payload) as Dictionary<string, object>;
                            if (result != null && Object.Equals(WorkerConfiguration.Get(result, "Success"), false))
                                throw new InvalidOperationException(WorkerConfiguration.Text(WorkerConfiguration.Get(result, "Error")));
                            break;
                        case "saveConfig":
                            WorkerConfiguration.Save(WorkerConfiguration.Get(request, "config") as Dictionary<string, object>, configPath);
                            payload = json.Serialize(new { Status = "saved", ConfigPath = configPath });
                            break;
                        case "diagnostics":
                            string outputPath = WorkerConfiguration.Text(WorkerConfiguration.Get(request, "outputPath"));
                            if (String.IsNullOrWhiteSpace(outputPath)) throw new InvalidDataException("Choose a diagnostics output path.");
                            payload = WorkerDiagnostics.Export(root, configPath, outputPath, Object.Equals(WorkerConfiguration.Get(request, "includeCapabilities"), true), engine);
                            break;
                        default: throw new InvalidDataException("Unknown worker action: " + action);
                    }
                }
                success = true;
            }
            catch (Exception ex) { error = ex.Message; }
            if (action == "profile" || action == "list")
                WorkerDiagnostics.Log(request, configPath, started, success, payload, error);
            return json.Serialize(new { id = id, success = success, payload = payload, error = error });
        }
    }
}
