using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using MonitorTools.Engine;

internal static class WorkerServiceTests
{
    private static int assertions;
    private static void Assert(bool condition, string message) { assertions++; if (!condition) throw new Exception(message); }
    private static void Throws(Action action, string message)
    {
        bool threw = false; try { action(); } catch { threw = true; }
        Assert(threw, message);
    }
    private static Dictionary<string, object> Object(string json) { return WorkerConfiguration.Json().DeserializeObject(json) as Dictionary<string, object>; }
    private static int Main(string[] args)
    {
        string root = Path.Combine(Path.GetTempPath(), "monitor-tools-worker-service-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            string path = Path.Combine(root, "profiles.json");
            File.WriteAllText(Path.Combine(root, "config-path.txt"), path);
            var config = Object("{\"schemaVersion\":2,\"profiles\":{\"this-pc\":{\"left\":\"0x05\",\"center\":{\"input\":\"dp1\",\"brightness\":42,\"volume\":0}}},\"calibration\":{\"left\":{\"status\":\"verified\"}},\"settings\":{\"custom\":true}}");
            WorkerConfiguration.Save(config, path);
            string original = File.ReadAllText(path);
            Assert(WorkerConfiguration.ConfigPath(root) == path, "Absolute installed config pointer preserved");
            WorkerConfiguration.Save(config, path);
            Assert(Directory.GetFiles(root, "*.bak").Length == 1, "Save backs up existing config");
            Assert(File.ReadAllText(Directory.GetFiles(root, "*.bak")[0]) == original, "Backup preserves original bytes");
            Assert(File.ReadAllText(path) == original, "Save preserves metadata and tested 0x05 input");
            foreach (string invalid in new[] {
                "{\"schemaVersion\":99,\"profiles\":{\"work\":{\"left\":\"dp1\"}}}",
                "{\"profiles\":{\"work\":{\"left\":{\"brightness\":101}}}}",
                "{\"profiles\":{\"work\":{\"left\":{\"volume\":1.5}}}}",
                "{\"profiles\":{\"work\":{\"left\":{\"unknown\":5}}}}",
                "{\"profiles\":{\"work\":{\"left\":\"0x100\"}}}",
                "{\"profiles\":{\"work\":{\"left\":null}}}",
                "{\"profiles\":{\"work\":{\"left\":{}}}}",
                "{\"profiles\":{}}"
            }) Throws(delegate { WorkerConfiguration.Save(Object(invalid), path); }, "Invalid config must fail before saving");
            Assert(File.ReadAllText(path) == original && Directory.GetFiles(root, "*.bak").Length == 1, "Invalid saves leave file and backup count unchanged");
            WorkerConfiguration.Validate(Object("{\"profiles\":{\"legacy\":{\"all\":17}}}"));
            File.WriteAllText(Path.Combine(root, "config-path.txt"), "relative.json");
            Throws(delegate { WorkerConfiguration.ConfigPath(root); }, "Reject relative installed pointer");
            File.WriteAllText(Path.Combine(root, "config-path.txt"), path);

            // Constructing an engine does not enumerate or write hardware. Only ping/save are dispatched.
            var service = new WorkerService(root, new MonitorEngine());
            var ping = Object(service.Handle("{\"id\":\"a\",\"action\":\"ping\"}"));
            Assert((bool)ping["success"] && (string)ping["id"] == "a", "Ping echoes correlation ID");
            Assert(!(bool)Object(service.Handle("{"))["success"], "Malformed request returns failure");
            Assert(!(bool)Object(service.Handle("{\"action\":\"saveConfig\"}"))["success"], "Missing ID fails without mutation");
            Assert(!(bool)Object(service.Handle("{\"id\":\"bad\",\"action\":\"unknown\"}"))["success"], "Unknown action fails");
            Assert((bool)Object(service.Handle("{\"id\":\"again\",\"action\":\"ping\"}"))["success"], "Application failures do not break subsequent requests");
            Assert(WorkerProgram.ReadRequest(new StringReader("{\"id\":1}\r\n")) == "{\"id\":1}", "CRLF framing");
            Assert(WorkerProgram.ReadRequest(new StringReader("")) == null, "EOF closes worker");
            Throws(delegate { WorkerProgram.ReadRequest(new StringReader("partial")); }, "Truncated frame fails");
            Throws(delegate { WorkerProgram.ReadRequest(new StringReader(new string('x', 1024 * 1024 + 1))); }, "Oversized frame bounded");

            var privateDocument = Object("{\"monitors\":[{\"StableId\":\"id-0123456789abcdefabcd\",\"Serial\":\"SERIAL-$SECRET\",\"Topology\":{\"AdapterPath\":\"GPU-SECRET\",\"MonitorPath\":\"DISPLAY-SECRET\"}}],\"profiles\":{\"work\":{\"id-0123456789abcdefabcd\":\"0x05\"}},\"Error\":\"serial-$secret gpu-secret display-secret c:/private/profile$.json machine$name\"}");
            var protector = new DiagnosticProtector(new[] { "C:/Private/Profile$.json", "MACHINE$NAME" });
            protector.Collect(privateDocument);
            string redacted = WorkerConfiguration.Json().Serialize(protector.Protect(privateDocument));
            Assert(redacted.IndexOf("secret", StringComparison.OrdinalIgnoreCase) < 0 && !redacted.Contains("id-0123") &&
                redacted.IndexOf("C:/private", StringComparison.OrdinalIgnoreCase) < 0 && redacted.IndexOf("machine$name", StringComparison.OrdinalIgnoreCase) < 0,
                "Diagnostic values, keys and differently-cased free-text errors are redacted");
            Assert(redacted.Contains("monitor-1") && redacted.Contains("0x05"), "Anonymous profile/monitor relationships remain usable");

            string oldLog = Environment.GetEnvironmentVariable("MONITOR_TOOLS_LOG_DIRECTORY");
            try
            {
                string logs = Path.Combine(root, "logs"); Directory.CreateDirectory(logs);
                Environment.SetEnvironmentVariable("MONITOR_TOOLS_LOG_DIRECTORY", logs);
                File.WriteAllText(Path.Combine(logs, "operation-user-note.json"), "preserve");
                for (int i = 0; i < 102; i++) WorkerDiagnostics.Log(Object("{\"action\":\"profile\",\"profile\":\"work\"}"), path, DateTime.UtcNow, false,
                    "{\"Success\":false,\"Results\":[{\"OperationId\":\"test-operation\",\"Status\":\"Failed\"}]}", "injected failure");
                Assert(Directory.GetFiles(logs).Length == 101, "Log rotation retains 100 owned files and unowned notes");
                string log = File.ReadAllText(Directory.GetFiles(logs).First(f => !f.EndsWith("operation-user-note.json")));
                Assert(log.Contains("test-operation") && log.Contains("Failed"), "Partial results survive in operation log");
            }
            finally { Environment.SetEnvironmentVariable("MONITOR_TOOLS_LOG_DIRECTORY", oldLog); }

            if (args.Length == 1) TestProcess(root, args[0]);
            Console.WriteLine("PASS: " + assertions + " worker protocol, configuration, privacy, logging, and lifecycle assertions");
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
        finally
        {
            string expected = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (!Path.GetFullPath(root).StartsWith(expected, StringComparison.OrdinalIgnoreCase) || !Path.GetFileName(root).StartsWith("monitor-tools-worker-service-")) throw new Exception("Unsafe test cleanup");
            Directory.Delete(root, true);
        }
    }

    private static void TestProcess(string root, string worker)
    {
        string app = Path.Combine(root, "app"); Directory.CreateDirectory(app);
        string copied = Path.Combine(app, "MonitorTools.Worker.exe"); File.Copy(worker, copied);
        using (var parent = Process.GetCurrentProcess())
        using (var process = new Process())
        {
            process.StartInfo = new ProcessStartInfo(copied, "--parent " + parent.Id + " --parent-start " + parent.StartTime.ToUniversalTime().Ticks) {
                UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false)
            };
            try
            {
                process.Start();
                var errors = process.StandardError.ReadToEndAsync();
                int initialId = 0;
                for (int i = 0; i < 3; i++)
                {
                    process.StandardInput.WriteLine("{\"id\":\"" + i + "\",\"action\":\"ping\"}"); process.StandardInput.Flush();
                    var read = process.StandardOutput.ReadLineAsync();
                    Assert(read.Wait(5000), "Worker responds within bound");
                    var response = Object(read.Result);
                    Assert((bool)response["success"] && (string)response["id"] == i.ToString(), "Real stdio correlation");
                    int pid = Convert.ToInt32(Object((string)response["payload"])["processId"]);
                    if (i == 0) initialId = pid;
                    Assert(initialId == pid, "Worker persists across requests");
                }
                process.StandardInput.Close();
                Assert(process.WaitForExit(5000), "Worker exits on parent pipe EOF");
                Assert(process.ExitCode == 0, "Worker clean exit: " + errors.Result);
            }
            finally { try { if (!process.HasExited) { process.Kill(); process.WaitForExit(5000); } } catch (InvalidOperationException) { } }
        }
    }
}
