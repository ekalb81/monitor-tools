using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace MonitorTools.Engine
{
    internal static class WorkerConfiguration
    {
        internal static JavaScriptSerializer Json()
        {
            return new JavaScriptSerializer { MaxJsonLength = 4 * 1024 * 1024, RecursionLimit = 64 };
        }

        internal static object Get(IDictionary<string, object> value, string key)
        {
            object result;
            if (value == null) return null;
            if (value.TryGetValue(key, out result)) return result;
            foreach (var pair in value) if (String.Equals(pair.Key, key, StringComparison.OrdinalIgnoreCase)) return pair.Value;
            return null;
        }

        internal static string Text(object value) { return Convert.ToString(value, CultureInfo.InvariantCulture); }

        internal static string ConfigPath(string root)
        {
            string pointer = Path.Combine(root, "config-path.txt");
            if (!File.Exists(pointer)) return Path.Combine(root, "monitor-profiles.json");
            string path = File.ReadAllText(pointer).Trim();
            if (!Path.IsPathRooted(path)) throw new InvalidDataException("The installed configuration path must be absolute. Run Repair.");
            return Path.GetFullPath(path);
        }

        internal static Dictionary<string, object> Read(string path)
        {
            var config = Json().DeserializeObject(File.ReadAllText(path)) as Dictionary<string, object>;
            Validate(config);
            return config;
        }

        internal static void Validate(Dictionary<string, object> config)
        {
            if (config == null) throw new InvalidDataException("Configuration must be an object.");
            ValidatePropertyNames(config);
            object version = Get(config, "schemaVersion");
            bool hasVersion = false;
            foreach (string key in config.Keys) if (String.Equals(key, "schemaVersion", StringComparison.OrdinalIgnoreCase)) hasVersion = true;
            if (hasVersion && Text(version) != "1" && Text(version) != "2")
                throw new InvalidDataException("Unsupported configuration schema version. Upgrade Monitor Tools before editing this file.");
            var profiles = Get(config, "profiles") as Dictionary<string, object>;
            if (profiles == null || profiles.Count == 0) throw new InvalidDataException("Configuration requires at least one profile.");
            foreach (var profile in profiles)
            {
                if (!Regex.IsMatch(profile.Key, @"\A[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}\z")) throw new InvalidDataException("Invalid profile name: " + profile.Key);
                var assignments = profile.Value as Dictionary<string, object>;
                if (assignments == null) throw new InvalidDataException("Profile must contain monitor assignments: " + profile.Key);
                foreach (var assignment in assignments)
                {
                    if (!Regex.IsMatch(assignment.Key, @"\A[\w-]+\z")) throw new InvalidDataException("Invalid monitor key: " + assignment.Key);
                    var scene = assignment.Value as Dictionary<string, object>;
                    if (scene == null)
                    {
                        if (!(assignment.Value is string) && !(assignment.Value is ValueType)) throw new InvalidDataException("Invalid monitor assignment: " + assignment.Key);
                        ValidateInput(Text(assignment.Value));
                        continue;
                    }
                    if (scene.Count == 0) throw new InvalidDataException("A scene must contain input, brightness, or volume.");
                    foreach (var field in scene)
                    {
                        string fieldName = field.Key.ToLowerInvariant();
                        if (fieldName == "input") ValidateInput(Text(field.Value));
                        else if (fieldName == "brightness" || fieldName == "volume")
                        {
                            int number;
                            if (!Int32.TryParse(Text(field.Value), NumberStyles.Integer, CultureInfo.InvariantCulture, out number) || number < 0 || number > 100)
                                throw new InvalidDataException(field.Key + " must be an integer percentage from 0 to 100.");
                        }
                        else throw new InvalidDataException("Unknown scene setting: " + field.Key);
                    }
                }
            }
        }

        private static void ValidatePropertyNames(object value)
        {
            var dictionary = value as IDictionary<string, object>;
            if (dictionary != null)
            {
                var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var pair in dictionary)
                {
                    if (String.IsNullOrEmpty(pair.Key) || !names.Add(pair.Key)) throw new InvalidDataException("Configuration contains an empty or ambiguous property name: " + pair.Key);
                    ValidatePropertyNames(pair.Value);
                }
            }
            else if (!(value is string) && value is IEnumerable)
                foreach (object child in (IEnumerable)value) ValidatePropertyNames(child);
        }

        private static void ValidateInput(string input)
        {
            int number;
            if (Int32.TryParse(input, NumberStyles.Integer, CultureInfo.InvariantCulture, out number) && number >= 0 && number <= 255) return;
            if (!Regex.IsMatch(input, @"\A(?:0x[0-9a-f]{1,2}|vga1|dvi[12]|dp[12]|displayport[12]?|hdmi[12]?)\z", RegexOptions.IgnoreCase))
                throw new InvalidDataException("Unknown input source: " + input);
        }

        internal static void Save(Dictionary<string, object> config, string path)
        {
            Validate(config);
            path = Path.GetFullPath(path);
            string directory = Path.GetDirectoryName(path);
            Directory.CreateDirectory(directory);
            string key;
            using (var hash = SHA256.Create()) key = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(path.ToUpperInvariant()))).Replace("-", "");
            using (var mutex = new Mutex(false, "Local\\MonitorTools.Config." + key))
            {
                bool locked = false;
                string staged = Path.Combine(directory, ".profiles-" + Guid.NewGuid().ToString("N") + ".tmp");
                try
                {
                    try { locked = mutex.WaitOne(5000); } catch (AbandonedMutexException) { locked = true; }
                    if (!locked) throw new TimeoutException("Another process is saving profiles. Try again.");
                    File.WriteAllText(staged, Json().Serialize(config), new UTF8Encoding(false));
                    if (File.Exists(path)) File.Replace(staged, path, path + "." + DateTime.UtcNow.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N") + ".bak");
                    else File.Move(staged, path);
                }
                finally
                {
                    if (File.Exists(staged)) File.Delete(staged);
                    if (locked) mutex.ReleaseMutex();
                }
            }
        }
    }
}
