using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace MonitorTools.Engine
{
    internal static class WorkerDiagnostics
    {
        internal static string LogDirectory()
        {
            string directory = Environment.GetEnvironmentVariable("MONITOR_TOOLS_LOG_DIRECTORY");
            return String.IsNullOrWhiteSpace(directory) ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Monitor Tools", "logs") : directory;
        }

        internal static void Log(Dictionary<string, object> request, string configPath, DateTime started, bool success, string payload, string error)
        {
            try
            {
                var json = WorkerConfiguration.Json();
                object result = payload == null ? null : json.DeserializeObject(payload);
                var batch = result as Dictionary<string, object>;
                object rows = batch == null ? result : WorkerConfiguration.Get(batch, "Results");
                string operationId = Guid.NewGuid().ToString("N");
                var results = rows as IEnumerable;
                if (results != null)
                    foreach (object row in results)
                    {
                        string value = WorkerConfiguration.Text(WorkerConfiguration.Get(row as Dictionary<string, object>, "OperationId"));
                        if (!String.IsNullOrEmpty(value)) { operationId = value; break; }
                    }
                var record = new {
                    OperationId = operationId, StartedAtUtc = started.ToString("o"), CompletedAtUtc = DateTime.UtcNow.ToString("o"),
                    Command = WorkerConfiguration.Get(request, "action"), Profile = WorkerConfiguration.Get(request, "profile"),
                    ConfigPath = configPath, Succeeded = success, Errors = error == null ? new string[0] : new[] { error }, Results = rows,
                    Engine = "compiled-worker"
                };
                string directory = LogDirectory();
                Directory.CreateDirectory(directory);
                string name = "operation-" + DateTime.UtcNow.ToString("yyyyMMddTHHmmssfffffff") + "-" + Guid.NewGuid().ToString("N") + ".json";
                File.WriteAllText(Path.Combine(directory, name), json.Serialize(record), new UTF8Encoding(false));
                var files = new DirectoryInfo(directory).GetFiles("operation-*.json")
                    .Where(f => Regex.IsMatch(f.Name, @"\Aoperation-\d{8}T\d{13}-[0-9a-f]{32}\.json\z"))
                    .OrderByDescending(f => f.Name).ToArray();
                for (int i = 0; i < files.Length; i++)
                    if (i >= 100 || files[i].LastWriteTimeUtc < DateTime.UtcNow.AddDays(-30)) files[i].Delete();
            }
            catch (Exception ex) { Console.Error.WriteLine("Could not save operation details: " + ex.Message); }
        }

        internal static string Export(string root, string configPath, string destination, bool capabilities, MonitorEngine engine)
        {
            var json = WorkerConfiguration.Json();
            var issues = new List<string>();
            object inventory = new object[0], config = null;
            try
            {
                inventory = json.DeserializeObject(engine.Execute(new Dictionary<string, object> {
                    { "action", "list" }, { "includeCurrentInput", true }, { "includeCapabilities", capabilities }
                }, configPath));
                var failure = inventory as Dictionary<string, object>;
                if (failure != null && Object.Equals(WorkerConfiguration.Get(failure, "Success"), false))
                    throw new InvalidDataException(WorkerConfiguration.Text(WorkerConfiguration.Get(failure, "Error")));
            }
            catch (Exception ex) { inventory = new object[0]; issues.Add("Discovery: " + ex.Message); }
            try { config = WorkerConfiguration.Read(configPath); }
            catch (Exception ex) { issues.Add("Configuration: " + ex.Message); }
            var operations = new List<object>();
            try
            {
                if (Directory.Exists(LogDirectory()))
                    foreach (string file in Directory.GetFiles(LogDirectory(), "operation-*.json").OrderByDescending(f => f).Take(20))
                    {
                        try { operations.Add(json.DeserializeObject(File.ReadAllText(file))); }
                        catch { issues.Add("An operation log could not be read."); }
                    }
            }
            catch { issues.Add("Operation logs could not be listed."); }
            string versionPath = Path.Combine(root, "VERSION");
            object document = new Dictionary<string, object> {
                { "diagnosticSchemaVersion", 1 }, { "generatedAtUtc", DateTime.UtcNow.ToString("o") },
                { "applicationVersion", File.Exists(versionPath) ? File.ReadAllText(versionPath).Trim() : "development" },
                { "windowsVersion", Environment.OSVersion.VersionString }, { "engine", "compiled-worker" },
                { "capabilitiesRequested", capabilities }, { "identifiersIncluded", false },
                { "note", "API acceptance and reported inputs do not prove a visible switch. Calibration records describe earlier user observations." },
                { "monitors", inventory }, { "configuration", config }, { "recentOperations", operations }, { "issues", issues }
            };
            var protector = new DiagnosticProtector(new[] { configPath, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Environment.MachineName });
            protector.Collect(document);
            document = protector.Protect(document);
            destination = Path.GetFullPath(destination);
            Directory.CreateDirectory(Path.GetDirectoryName(destination));
            File.WriteAllText(destination, json.Serialize(document), new UTF8Encoding(false));
            return json.Serialize(new { FullName = destination, Length = new FileInfo(destination).Length });
        }
    }

    internal sealed class DiagnosticProtector
    {
        private readonly List<string> secrets = new List<string>();
        private readonly Dictionary<string, string> aliases = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        private static readonly Regex PrivateKey = new Regex("serial|devicepath|hardwareid|identitykey|configpath|displaydevice|handle|adapterpath|monitorpath|adapterluid", RegexOptions.IgnoreCase);
        internal DiagnosticProtector(IEnumerable<string> values) { foreach (string value in values) Add(value); }
        private void Add(string value) { if (!String.IsNullOrWhiteSpace(value) && !secrets.Contains(value)) secrets.Add(value); }
        internal void Collect(object value)
        {
            var dictionary = value as IDictionary<string, object>;
            if (dictionary != null)
                foreach (var item in dictionary) { if (PrivateKey.IsMatch(item.Key) && item.Value is string) Add((string)item.Value); Collect(item.Value); }
            else if (!(value is string) && value is IEnumerable) foreach (object child in (IEnumerable)value) Collect(child);
        }
        internal object Protect(object value)
        {
            string text = value as string;
            if (text != null)
            {
                foreach (string secret in secrets.OrderByDescending(s => s.Length))
                    text = Regex.Replace(text, Regex.Escape(secret), delegate(Match match) { return "[redacted]"; },
                        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
                return Regex.Replace(text, "id-[a-f0-9]{8,64}", delegate(Match match) {
                    string alias;
                    if (!aliases.TryGetValue(match.Value, out alias)) aliases[match.Value] = alias = "monitor-" + (aliases.Count + 1);
                    return alias;
                }, RegexOptions.IgnoreCase);
            }
            var dictionary = value as IDictionary<string, object>;
            if (dictionary != null)
            {
                var result = new Dictionary<string, object>();
                foreach (var item in dictionary) if (!PrivateKey.IsMatch(item.Key)) result[(string)Protect(item.Key)] = Protect(item.Value);
                return result;
            }
            if (value is IEnumerable)
            {
                var result = new List<object>();
                foreach (object child in (IEnumerable)value) result.Add(Protect(child));
                return result;
            }
            return value;
        }
    }
}
