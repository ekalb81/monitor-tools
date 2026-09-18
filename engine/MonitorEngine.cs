using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

namespace MonitorTools.Engine
{
    internal interface IMonitorBackend
    {
        IList<MonitorRecord> Enumerate(bool includeCapabilities, bool includeCurrentInput);
        bool TryGetVcp(IntPtr handle, byte code, out uint current, out uint maximum);
        bool TrySetVcp(IntPtr handle, byte code, uint value, out int nativeError);
        void Destroy(IntPtr handle);
    }

    internal sealed class NativeMonitorBackend : IMonitorBackend
    {
        private sealed class RawMonitor
        {
            internal IntPtr Handle;
            internal string Description;
            internal string DisplayDevice;
            internal int Left;
            internal int Top;
            internal int Right;
            internal int Bottom;
        }

        public IList<MonitorRecord> Enumerate(bool includeCapabilities, bool includeCurrentInput)
        {
            List<RawMonitor> handles = new List<RawMonitor>();
            NativeMethods.MonitorEnumProc callback = delegate(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data)
            {
                NativeMethods.MonitorInfoEx info = new NativeMethods.MonitorInfoEx();
                info.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(NativeMethods.MonitorInfoEx));
                bool hasInfo = NativeMethods.GetMonitorInfo(monitor, ref info);
                uint count;
                if (!NativeMethods.GetNumberOfPhysicalMonitorsFromHMONITOR(monitor, out count) || count == 0) return true;
                NativeMethods.PhysicalMonitor[] physical = new NativeMethods.PhysicalMonitor[count];
                if (!NativeMethods.GetPhysicalMonitorsFromHMONITOR(monitor, count, physical)) return true;
                foreach (NativeMethods.PhysicalMonitor item in physical)
                {
                    handles.Add(new RawMonitor {
                        Handle = item.hPhysicalMonitor,
                        Description = item.szPhysicalMonitorDescription,
                        DisplayDevice = hasInfo ? info.szDevice : null,
                        Left = hasInfo ? info.rcMonitor.Left : 0,
                        Top = hasInfo ? info.rcMonitor.Top : 0,
                        Right = hasInfo ? info.rcMonitor.Right : 0,
                        Bottom = hasInfo ? info.rcMonitor.Bottom : 0
                    });
                }
                return true;
            };

            try
            {
                if (!NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero))
                {
                    int nativeError = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                    throw new InvalidOperationException("Display enumeration failed. Win32 error: " + nativeError);
                }
                Dictionary<string, TopologyInfo> topology = DisplayTopology.Read();
                List<MonitorRecord> result = new List<MonitorRecord>();
                int index = 1;
                foreach (RawMonitor raw in handles)
                {
                    TopologyInfo topologyInfo = null;
                    if (!String.IsNullOrWhiteSpace(raw.DisplayDevice)) topology.TryGetValue(raw.DisplayDevice, out topologyInfo);
                    MonitorIdentity identity = MonitorIdentityReader.GetIdentity(raw.DisplayDevice, raw.Description,
                        topologyInfo == null ? null : topologyInfo.MonitorDevicePath,
                        topologyInfo == null ? null : topologyInfo.MonitorFriendlyName);
                    string capabilities = includeCapabilities ? GetCapabilities(raw.Handle) : null;
                    uint current = 0;
                    uint maximum = 0;
                    bool hasInput = includeCurrentInput && TryGetVcp(raw.Handle, 0x60, out current, out maximum);
                    result.Add(new MonitorRecord {
                        Index = index++,
                        StableId = MonitorEngine.GetStableId(identity.StableMaterial),
                        IdentityStatus = identity.IdentityStatus,
                        Manufacturer = identity.Manufacturer,
                        ProductCode = identity.ProductCode,
                        Model = identity.Model,
                        Serial = identity.Serial,
                        DevicePath = identity.DevicePath,
                        Description = raw.Description,
                        DisplayDevice = raw.DisplayDevice,
                        MonitorLeft = raw.Left,
                        MonitorTop = raw.Top,
                        MonitorRight = raw.Right,
                        MonitorBottom = raw.Bottom,
                        Handle = raw.Handle,
                        Capabilities = capabilities,
                        AdvertisedInputs = includeCapabilities ? MonitorEngine.GetAdvertisedInputs(capabilities) : new string[0],
                        CurrentInputCode = hasInput ? (int?)current : null,
                        CurrentInputHex = hasInput ? "0x" + current.ToString("X2") : null,
                        CurrentInputName = hasInput ? MonitorEngine.GetPrimaryInputName((int)current) : null,
                        Topology = topologyInfo
                    });
                }
                return result;
            }
            catch
            {
                foreach (RawMonitor monitor in handles)
                {
                    if (monitor.Handle != IntPtr.Zero) NativeMethods.DestroyPhysicalMonitor(monitor.Handle);
                }
                throw;
            }
        }

        private static string GetCapabilities(IntPtr handle)
        {
            uint length;
            if (!NativeMethods.GetCapabilitiesStringLength(handle, out length) || length == 0 || length > 65536) return null;
            StringBuilder text = new StringBuilder((int)length);
            return NativeMethods.CapabilitiesRequestAndCapabilitiesReply(handle, text, length) ? text.ToString() : null;
        }

        public bool TryGetVcp(IntPtr handle, byte code, out uint current, out uint maximum)
        {
            uint featureType;
            return NativeMethods.GetVCPFeatureAndVCPFeatureReply(handle, code, out featureType, out current, out maximum);
        }

        public bool TrySetVcp(IntPtr handle, byte code, uint value, out int nativeError)
        {
            return NativeMethods.SetVcpFeature(handle, code, value, out nativeError);
        }

        public void Destroy(IntPtr handle)
        {
            if (handle != IntPtr.Zero) NativeMethods.DestroyPhysicalMonitor(handle);
        }
    }

    internal sealed class MonitorRecord
    {
        public int Index { get; set; }
        public string Position { get; set; }
        public string StableId { get; set; }
        public string IdentityStatus { get; set; }
        public string Manufacturer { get; set; }
        public string ProductCode { get; set; }
        public string Model { get; set; }
        public string Serial { get; set; }
        public string DevicePath { get; set; }
        public string DisplayDevice { get; set; }
        public string Description { get; set; }
        public int MonitorLeft { get; set; }
        public int MonitorTop { get; set; }
        public int MonitorRight { get; set; }
        public int MonitorBottom { get; set; }
        public string Capabilities { get; set; }
        public string[] AdvertisedInputs { get; set; }
        public int? CurrentInputCode { get; set; }
        public string CurrentInputHex { get; set; }
        public string CurrentInputName { get; set; }
        public TopologyInfo Topology { get; set; }
        [ScriptIgnore] public IntPtr Handle { get; set; }
    }

    internal sealed class MonitorAssignment
    {
        internal string Target;
        internal object Input;
        internal object Brightness;
        internal object Volume;
    }

    internal sealed class MonitorOperation
    {
        internal MonitorRecord Monitor;
        internal string Feature;
        internal byte VcpCode;
        internal uint RawValue;
        internal string Requested;
        internal string RequestedCode;
    }

    internal sealed class OperationResult
    {
        public string OperationId { get; set; }
        public string Phase { get; set; }
        public string StableId { get; set; }
        public string IdentityStatus { get; set; }
        public int Index { get; set; }
        public string Position { get; set; }
        public string Model { get; set; }
        public string Description { get; set; }
        public string Feature { get; set; }
        public string Requested { get; set; }
        public string RequestedCode { get; set; }
        public string Status { get; set; }
        public bool ApiAccepted { get; set; }
        public bool PhysicalVerified { get; set; }
        public bool Saved { get; set; }
        public int AttemptCount { get; set; }
        public string Error { get; set; }
    }

    public sealed class MonitorEngine
    {
        private static readonly Dictionary<string, byte> InputAliases = new Dictionary<string, byte>(StringComparer.OrdinalIgnoreCase) {
            { "vga1", 0x01 }, { "dvi1", 0x03 }, { "dvi2", 0x04 },
            { "dp1", 0x0F }, { "displayport", 0x0F }, { "displayport1", 0x0F },
            { "dp2", 0x10 }, { "displayport2", 0x10 }, { "hdmi", 0x11 },
            { "hdmi1", 0x11 }, { "hdmi2", 0x12 }
        };

        private static readonly Dictionary<int, string> PrimaryInputNames = new Dictionary<int, string> {
            { 0x01, "vga1" }, { 0x03, "dvi1" }, { 0x04, "dvi2" },
            { 0x0F, "displayport1" }, { 0x10, "displayport2" },
            { 0x11, "hdmi1" }, { 0x12, "hdmi2" }
        };

        private readonly IMonitorBackend backend;
        private readonly Action<int> delay;
        private readonly JavaScriptSerializer json;

        public MonitorEngine() : this(new NativeMonitorBackend(), Thread.Sleep) { }

        internal MonitorEngine(IMonitorBackend monitorBackend, Action<int> delayAction)
        {
            if (monitorBackend == null) throw new ArgumentNullException("monitorBackend");
            if (delayAction == null) throw new ArgumentNullException("delayAction");
            backend = monitorBackend;
            delay = delayAction;
            json = new JavaScriptSerializer { MaxJsonLength = Int32.MaxValue, RecursionLimit = 100 };
        }

        public string Execute(Dictionary<string, object> request, string configPath)
        {
            if (request == null) throw new ArgumentNullException("request");
            string action = GetString(request, "action");
            if (!String.Equals(action, "list", StringComparison.OrdinalIgnoreCase) &&
                !String.Equals(action, "profile", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Unknown monitor engine action '" + action + "'.");

            bool profileAction = String.Equals(action, "profile", StringComparison.OrdinalIgnoreCase);
            Mutex mutex = null;
            bool mutexOwned = false;
            List<MonitorRecord> inventory = new List<MonitorRecord>();
            try
            {
                mutex = new Mutex(false, GetMutexName());
                try { mutexOwned = mutex.WaitOne(TimeSpan.FromSeconds(10)); }
                catch (AbandonedMutexException) { mutexOwned = true; }
                if (!mutexOwned) throw new InvalidOperationException("Another monitor switch operation is still running. Try again after it completes.");

                bool includeCapabilities = !profileAction && GetBoolean(request, "includeCapabilities", false);
                bool includeCurrentInput = !profileAction && GetBoolean(request, "includeCurrentInput", false);
                inventory.AddRange(backend.Enumerate(includeCapabilities, includeCurrentInput));
                NormalizeInventory(inventory);
                if (inventory.Count == 0) throw new InvalidOperationException("No DDC/CI-capable monitors were found.");
                if (!profileAction) return json.Serialize(inventory);

                string profile = GetString(request, "profile");
                string monitorId = GetOptionalString(request, "monitorId");
                List<MonitorAssignment> assignments = ReadProfile(configPath, profile);
                List<MonitorOperation> plan = BuildPlan(inventory, assignments, monitorId, profile);
                return json.Serialize(ApplyPlan(plan));
            }
            catch (Exception error)
            {
                if (!profileAction) throw;
                return json.Serialize(new Dictionary<string, object> {
                    { "Success", false }, { "Results", new object[0] }, { "Error", error.Message }
                });
            }
            finally
            {
                foreach (MonitorRecord monitor in inventory)
                {
                    try { backend.Destroy(monitor.Handle); } catch { }
                }
                if (mutexOwned && mutex != null) mutex.ReleaseMutex();
                if (mutex != null) mutex.Dispose();
            }
        }

        private Dictionary<string, object> ApplyPlan(List<MonitorOperation> plan)
        {
            string operationId = Guid.NewGuid().ToString("N");
            List<OperationResult> results = new List<OperationResult>();
            List<string> errors = new List<string>();
            foreach (MonitorOperation operation in plan)
            {
                OperationResult result = ApplyOperation(operation, operationId);
                results.Add(result);
                if (!String.IsNullOrWhiteSpace(result.Error)) errors.Add(result.Error);
            }
            string aggregate = errors.Count == 0 ? null
                : "Monitor operation " + operationId + " completed with " + errors.Count + " failure(s): " + String.Join(" | ", errors.ToArray());
            return new Dictionary<string, object> {
                { "Success", errors.Count == 0 }, { "Results", results }, { "Error", aggregate }
            };
        }

        private OperationResult ApplyOperation(MonitorOperation operation, string operationId)
        {
            MonitorRecord monitor = operation.Monitor;
            OperationResult result = new OperationResult {
                OperationId = operationId,
                Phase = "Apply",
                StableId = monitor.StableId,
                IdentityStatus = monitor.IdentityStatus,
                Index = monitor.Index,
                Position = monitor.Position,
                Model = monitor.Model,
                Description = monitor.Description,
                Feature = operation.Feature,
                Requested = operation.Requested,
                RequestedCode = operation.RequestedCode,
                Status = "Failed",
                ApiAccepted = false,
                PhysicalVerified = false,
                Saved = false,
                AttemptCount = 0
            };
            int nativeError = 0;
            for (int attempt = 1; attempt <= 3; attempt++)
            {
                result.AttemptCount = attempt;
                bool accepted;
                try { accepted = backend.TrySetVcp(monitor.Handle, operation.VcpCode, operation.RawValue, out nativeError); }
                catch (Exception error)
                {
                    result.Error = "Failed to set " + operation.Feature + " on monitor " + monitor.Index + " [" + monitor.Description + "] (" + monitor.StableId + "). Backend error: " + error.Message;
                    return result;
                }
                if (accepted)
                {
                    result.Status = "Accepted";
                    result.ApiAccepted = true;
                    return result;
                }
                if (attempt >= 3 || !IsTransientDdcError(nativeError)) break;
                delay(attempt == 1 ? 100 : 250);
            }
            result.Error = "Failed to set " + operation.Feature + " on monitor " + monitor.Index + " [" + monitor.Description + "] (" + monitor.StableId + "). Win32 error: " + nativeError;
            return result;
        }

        private List<MonitorOperation> BuildPlan(List<MonitorRecord> inventory, List<MonitorAssignment> assignments,
            string filterMonitorId, string profile)
        {
            MonitorRecord filter = String.IsNullOrWhiteSpace(filterMonitorId) ? null : ResolveTarget(inventory, filterMonitorId);
            List<KeyValuePair<MonitorRecord, MonitorAssignment>> resolved = new List<KeyValuePair<MonitorRecord, MonitorAssignment>>();
            foreach (MonitorAssignment assignment in assignments)
            {
                if (filter != null && !String.Equals(assignment.Target, "all", StringComparison.OrdinalIgnoreCase) &&
                    !String.Equals(assignment.Target, filter.StableId, StringComparison.OrdinalIgnoreCase) &&
                    !String.Equals(assignment.Target, filter.Index.ToString(CultureInfo.InvariantCulture), StringComparison.OrdinalIgnoreCase) &&
                    !String.Equals(assignment.Target, filter.Position, StringComparison.OrdinalIgnoreCase)) continue;
                IEnumerable<MonitorRecord> targets = String.Equals(assignment.Target, "all", StringComparison.OrdinalIgnoreCase)
                    ? (filter == null ? (IEnumerable<MonitorRecord>)inventory : new[] { filter })
                    : new[] { ResolveTarget(inventory, assignment.Target) };
                foreach (MonitorRecord monitor in targets) resolved.Add(new KeyValuePair<MonitorRecord, MonitorAssignment>(monitor, assignment));
            }
            if (filter != null && resolved.Count == 0)
                throw new InvalidOperationException("Monitor '" + filterMonitorId + "' is not included in profile '" + profile + "'.");
            foreach (KeyValuePair<MonitorRecord, MonitorAssignment> item in resolved)
            {
                if (String.Equals(item.Key.IdentityStatus, "ambiguous", StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("Monitor target '" + item.Key.StableId + "' is ambiguous. Reconnect or rebind the monitor before switching; no writes were attempted.");
            }

            List<MonitorOperation> plan = new List<MonitorOperation>();
            foreach (KeyValuePair<MonitorRecord, MonitorAssignment> item in resolved)
            {
                MonitorRecord monitor = item.Key;
                MonitorAssignment assignment = item.Value;
                if (assignment.Input != null && !String.IsNullOrWhiteSpace(Convert.ToString(assignment.Input, CultureInfo.InvariantCulture)))
                {
                    byte code = ResolveInputCode(Convert.ToString(assignment.Input, CultureInfo.InvariantCulture));
                    plan.Add(new MonitorOperation {
                        Monitor = monitor, Feature = "input", VcpCode = 0x60, RawValue = code,
                        Requested = GetPrimaryInputName(code), RequestedCode = "0x" + code.ToString("X2")
                    });
                }
                AddPercentageOperation(plan, monitor, "brightness", 0x10, assignment.Brightness);
                AddPercentageOperation(plan, monitor, "volume", 0x62, assignment.Volume);
            }
            return plan;
        }

        private void AddPercentageOperation(List<MonitorOperation> plan, MonitorRecord monitor,
            string feature, byte code, object value)
        {
            if (value == null) return;
            int percent = ConvertToPercent(value, feature);
            uint current;
            uint maximum;
            if (!backend.TryGetVcp(monitor.Handle, code, out current, out maximum) || maximum == 0)
                throw new InvalidOperationException("Monitor '" + monitor.StableId + "' does not report a usable " + feature + " range; no writes were attempted.");
            uint raw = (uint)Math.Round(((double)maximum * percent) / 100.0, MidpointRounding.ToEven);
            plan.Add(new MonitorOperation {
                Monitor = monitor, Feature = feature, VcpCode = code, RawValue = raw,
                Requested = percent + "%", RequestedCode = raw + "/" + maximum
            });
        }

        private List<MonitorAssignment> ReadProfile(string configPath, string selectedProfile)
        {
            if (String.IsNullOrWhiteSpace(configPath) || !File.Exists(configPath))
                throw new InvalidOperationException("Profile file '" + configPath + "' was not found.");
            if (String.IsNullOrWhiteSpace(selectedProfile) || !Regex.IsMatch(selectedProfile, "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$"))
                throw new InvalidOperationException("Profile names use 1-64 letters, digits, hyphens, or underscores.");
            Dictionary<string, object> config = WorkerConfiguration.Read(configPath);
            object profilesValue;
            Dictionary<string, object> profiles;
            if (!TryGetValue(config, "profiles", out profilesValue) || (profiles = profilesValue as Dictionary<string, object>) == null)
                throw new InvalidOperationException("Profile file '" + configPath + "' does not contain a 'profiles' object.");
            object settingsValue;
            Dictionary<string, object> settings;
            if (!TryGetValue(profiles, selectedProfile, out settingsValue) || (settings = settingsValue as Dictionary<string, object>) == null)
                throw new InvalidOperationException("Profile '" + selectedProfile + "' was not found. Available profiles: " + String.Join(", ", profiles.Keys.ToArray()));

            List<MonitorAssignment> assignments = new List<MonitorAssignment>();
            foreach (KeyValuePair<string, object> property in settings)
            {
                MonitorAssignment assignment = new MonitorAssignment { Target = property.Key };
                if (property.Value is string || property.Value is ValueType) assignment.Input = property.Value;
                else
                {
                    Dictionary<string, object> scene = property.Value as Dictionary<string, object>;
                    if (scene == null) throw new InvalidOperationException("Profile '" + selectedProfile + "' monitor '" + property.Key + "' must be an input or scene object.");
                    foreach (string name in scene.Keys)
                    {
                        if (!String.Equals(name, "input", StringComparison.OrdinalIgnoreCase) &&
                            !String.Equals(name, "brightness", StringComparison.OrdinalIgnoreCase) &&
                            !String.Equals(name, "volume", StringComparison.OrdinalIgnoreCase))
                            throw new InvalidOperationException("Profile '" + selectedProfile + "' monitor '" + property.Key + "' has unknown scene setting '" + name + "'.");
                    }
                    TryGetValue(scene, "input", out assignment.Input);
                    TryGetValue(scene, "brightness", out assignment.Brightness);
                    TryGetValue(scene, "volume", out assignment.Volume);
                    if (assignment.Input == null && assignment.Brightness == null && assignment.Volume == null)
                        throw new InvalidOperationException("Profile '" + selectedProfile + "' monitor '" + property.Key + "' has an empty scene.");
                }
                assignments.Add(assignment);
            }
            return assignments;
        }

        private static MonitorRecord ResolveTarget(List<MonitorRecord> inventory, string target)
        {
            List<MonitorRecord> matches = inventory.Where(delegate(MonitorRecord item) {
                return String.Equals(item.StableId, target, StringComparison.OrdinalIgnoreCase);
            }).ToList();
            int index;
            if (matches.Count == 0 && Int32.TryParse(target, NumberStyles.None, CultureInfo.InvariantCulture, out index))
                matches = inventory.Where(delegate(MonitorRecord item) { return item.Index == index; }).ToList();
            if (matches.Count == 0)
                matches = inventory.Where(delegate(MonitorRecord item) { return String.Equals(item.Position, target, StringComparison.OrdinalIgnoreCase); }).ToList();
            if (matches.Count == 0)
                throw new InvalidOperationException("Monitor target '" + target + "' was not found. List monitors to see active stable IDs, indexes, and positions.");
            if (matches.Count > 1 || String.Equals(matches[0].IdentityStatus, "ambiguous", StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Monitor target '" + target + "' is ambiguous. Reconnect or rebind the monitor before switching; no writes were attempted.");
            return matches[0];
        }

        private static void NormalizeInventory(List<MonitorRecord> inventory)
        {
            List<MonitorRecord> ordered = inventory.OrderBy(delegate(MonitorRecord item) { return item.MonitorLeft; })
                .ThenBy(delegate(MonitorRecord item) { return item.MonitorTop; })
                .ThenBy(delegate(MonitorRecord item) { return item.Index; }).ToList();
            for (int i = 0; i < ordered.Count; i++)
            {
                if (ordered.Count == 1) ordered[i].Position = "center";
                else if (ordered.Count == 2) ordered[i].Position = i == 0 ? "left" : "right";
                else if (ordered.Count == 3) ordered[i].Position = i == 0 ? "left" : (i == 1 ? "center" : "right");
                else ordered[i].Position = "position-" + (i + 1);
            }
            foreach (IGrouping<string, MonitorRecord> group in inventory.GroupBy(delegate(MonitorRecord item) { return item.StableId; }, StringComparer.OrdinalIgnoreCase))
            {
                if (group.Count() > 1) foreach (MonitorRecord monitor in group) monitor.IdentityStatus = "ambiguous";
            }
        }

        internal static string GetStableId(string material)
        {
            if (material == null) throw new ArgumentNullException("material");
            using (SHA256 sha = SHA256.Create())
            {
                byte[] hash = sha.ComputeHash(Encoding.UTF8.GetBytes(material));
                StringBuilder text = new StringBuilder("id-");
                for (int i = 0; i < 10; i++) text.Append(hash[i].ToString("x2"));
                return text.ToString();
            }
        }

        internal static string GetPrimaryInputName(int code)
        {
            string name;
            return PrimaryInputNames.TryGetValue(code, out name) ? name : "0x" + code.ToString("X2");
        }

        internal static string[] GetAdvertisedInputs(string capabilities)
        {
            if (String.IsNullOrWhiteSpace(capabilities)) return new string[0];
            Match match = Regex.Match(capabilities, "60\\(([^)]*)\\)", RegexOptions.IgnoreCase);
            if (!match.Success) return new string[0];
            List<string> inputs = new List<string>();
            foreach (string token in Regex.Split(match.Groups[1].Value, "\\s+").Where(delegate(string item) { return item.Length > 0; }))
            {
                int code;
                if (Int32.TryParse(token, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out code)) inputs.Add(GetPrimaryInputName(code));
            }
            return inputs.ToArray();
        }

        private static byte ResolveInputCode(string inputName)
        {
            Match hex = Regex.Match(inputName ?? "", "^\\s*0x([0-9a-fA-F]{1,2})\\s*$");
            if (hex.Success) return Byte.Parse(hex.Groups[1].Value, NumberStyles.HexNumber, CultureInfo.InvariantCulture);
            Match number = Regex.Match(inputName ?? "", "^\\s*(\\d{1,3})\\s*$");
            if (number.Success)
            {
                int value = Int32.Parse(number.Groups[1].Value, CultureInfo.InvariantCulture);
                if (value < 0 || value > 255) throw new InvalidOperationException("Numeric input source values must be between 0 and 255.");
                return (byte)value;
            }
            byte code;
            string normalized = (inputName ?? "").Trim();
            if (InputAliases.TryGetValue(normalized, out code)) return code;
            throw new InvalidOperationException("Unknown input source '" + inputName + "'. Use a named input, a decimal value, or a hex value like 0x11.");
        }

        private static int ConvertToPercent(object value, string name)
        {
            int number;
            if (value == null || !Int32.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), NumberStyles.Integer, CultureInfo.InvariantCulture, out number) || number < 0 || number > 100)
                throw new InvalidOperationException(name + " must be a whole number from 0 through 100.");
            return number;
        }

        private static bool IsTransientDdcError(int code)
        {
            return code == 21 || code == 121 || code == 170 || code == 1460;
        }

        private static string GetMutexName()
        {
            string identity;
            try { using (WindowsIdentity current = WindowsIdentity.GetCurrent()) identity = current.User.Value; }
            catch { identity = Environment.UserName; }
            return "Local\\MonitorTools.Switch." + GetStableId(identity).Substring(3);
        }

        private static string GetString(Dictionary<string, object> values, string name)
        {
            object value;
            if (!TryGetValue(values, name, out value) || String.IsNullOrWhiteSpace(Convert.ToString(value, CultureInfo.InvariantCulture)))
                throw new InvalidOperationException("Request field '" + name + "' is required.");
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }

        private static string GetOptionalString(Dictionary<string, object> values, string name)
        {
            object value;
            return TryGetValue(values, name, out value) ? Convert.ToString(value, CultureInfo.InvariantCulture) : null;
        }

        private static bool GetBoolean(Dictionary<string, object> values, string name, bool fallback)
        {
            object value;
            if (!TryGetValue(values, name, out value) || value == null) return fallback;
            bool parsed;
            if (value is bool) return (bool)value;
            if (Boolean.TryParse(Convert.ToString(value, CultureInfo.InvariantCulture), out parsed)) return parsed;
            throw new InvalidOperationException("Request field '" + name + "' must be true or false.");
        }

        private static bool TryGetValue(Dictionary<string, object> values, string name, out object value)
        {
            if (values.TryGetValue(name, out value)) return true;
            foreach (KeyValuePair<string, object> pair in values)
            {
                if (String.Equals(pair.Key, name, StringComparison.OrdinalIgnoreCase)) { value = pair.Value; return true; }
            }
            value = null;
            return false;
        }
    }
}
