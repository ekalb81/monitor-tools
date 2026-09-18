using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;

namespace MonitorTools.Engine
{
    internal static class NativeMethods
    {
        [StructLayout(LayoutKind.Sequential)]
        internal struct Rect
        {
            internal int Left;
            internal int Top;
            internal int Right;
            internal int Bottom;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        internal struct MonitorInfoEx
        {
            internal int cbSize;
            internal Rect rcMonitor;
            internal Rect rcWork;
            internal uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] internal string szDevice;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
        internal struct PhysicalMonitor
        {
            internal IntPtr hPhysicalMonitor;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string szPhysicalMonitorDescription;
        }

        internal delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc callback, IntPtr data);

        [DllImport("user32.dll", CharSet = CharSet.Auto)]
        internal static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfoEx info);

        [DllImport("dxva2.dll", SetLastError = true)]
        internal static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count);

        [DllImport("dxva2.dll", SetLastError = true)]
        internal static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, [Out] PhysicalMonitor[] monitors);

        [DllImport("dxva2.dll", SetLastError = true)]
        internal static extern bool DestroyPhysicalMonitor(IntPtr monitor);

        [DllImport("dxva2.dll", SetLastError = true)]
        internal static extern bool GetCapabilitiesStringLength(IntPtr monitor, out uint length);

        [DllImport("dxva2.dll", SetLastError = true, CharSet = CharSet.Ansi)]
        internal static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr monitor, StringBuilder text, uint length);

        [DllImport("dxva2.dll", SetLastError = true)]
        internal static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, out uint type, out uint current, out uint maximum);

        [DllImport("dxva2.dll", EntryPoint = "SetVCPFeature", SetLastError = true)]
        private static extern bool SetVcpFeatureNative(IntPtr monitor, byte code, uint value);

        [DllImport("dxva2.dll", EntryPoint = "SaveCurrentSettings", SetLastError = true)]
        private static extern bool SaveCurrentSettingsNative(IntPtr monitor);

        internal static bool SetVcpFeature(IntPtr monitor, byte code, uint value, out int nativeError)
        {
            bool accepted = SetVcpFeatureNative(monitor, code, value);
            nativeError = accepted ? 0 : Marshal.GetLastWin32Error();
            return accepted;
        }

        internal static bool SaveCurrentSettings(IntPtr monitor, out int nativeError)
        {
            bool saved = SaveCurrentSettingsNative(monitor);
            nativeError = saved ? 0 : Marshal.GetLastWin32Error();
            return saved;
        }
    }

    internal sealed class MonitorIdentity
    {
        internal string Manufacturer;
        internal string ProductCode;
        internal string Model;
        internal string Serial;
        internal string DevicePath;
        internal string IdentityStatus;
        internal string StableMaterial;
    }

    internal static class MonitorIdentityReader
    {
        private const uint GetDeviceInterfaceName = 1;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DisplayDevice
        {
            internal int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] internal string DeviceName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string DeviceString;
            internal int StateFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string DeviceID;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string DeviceKey;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern bool EnumDisplayDevices(string device, uint number, ref DisplayDevice display, uint flags);

        internal static bool ParseDeviceInterface(string deviceId, out string hardwareId, out string instanceId)
        {
            hardwareId = null;
            instanceId = null;
            if (String.IsNullOrWhiteSpace(deviceId)) return false;
            string[] parts = deviceId.Split('#');
            if (parts.Length < 3 || !parts[0].EndsWith("DISPLAY", StringComparison.OrdinalIgnoreCase)) return false;
            hardwareId = parts[1];
            instanceId = parts[2];
            return !String.IsNullOrWhiteSpace(hardwareId) && !String.IsNullOrWhiteSpace(instanceId);
        }

        internal static string SelectLegacyDevicePath(string enumDevicePath, string displayDevice, string topologyDevicePath)
        {
            // Topology is intentionally metadata-only. Changing this material would
            // silently invalidate stable IDs for monitors without an EDID serial.
            return !String.IsNullOrWhiteSpace(enumDevicePath) ? enumDevicePath : displayDevice;
        }

        internal static MonitorIdentity GetIdentity(string displayDevice, string description, string topologyPath, string topologyName)
        {
            DisplayDevice device = new DisplayDevice();
            device.cb = Marshal.SizeOf(typeof(DisplayDevice));
            bool found = EnumDisplayDevices(displayDevice, 0, ref device, GetDeviceInterfaceName);
            string enumPath = found && !String.IsNullOrWhiteSpace(device.DeviceID) ? device.DeviceID : null;
            string path = SelectLegacyDevicePath(enumPath, displayDevice, topologyPath);
            string interfacePath = enumPath;
            string hardwareId;
            string instanceId;
            ParseDeviceInterface(interfacePath, out hardwareId, out instanceId);
            byte[] edid = FindEdid(hardwareId, instanceId);
            string friendly = found && !String.IsNullOrWhiteSpace(device.DeviceString) ? device.DeviceString : description;
            return DecodeEdid(edid, path, displayDevice, friendly);
        }

        internal static MonitorIdentity DecodeEdid(byte[] edid, string path, string displayDevice, string description)
        {
            string manufacturer = null;
            string product = null;
            string serial = null;
            string model = null;
            if (edid != null && edid.Length >= 18)
            {
                int word = (edid[8] << 8) | edid[9];
                manufacturer = new String(new[] {
                    (char)(((word >> 10) & 31) + 64),
                    (char)(((word >> 5) & 31) + 64),
                    (char)((word & 31) + 64)
                });
                product = ((int)(edid[10] | (edid[11] << 8))).ToString("X4");
                model = TextDescriptor(edid, 0xFC);
                serial = TextDescriptor(edid, 0xFF);
                if (String.IsNullOrWhiteSpace(serial))
                {
                    uint numeric = (uint)(edid[12] | (edid[13] << 8) | (edid[14] << 16) | (edid[15] << 24));
                    if (numeric != 0) serial = numeric.ToString();
                }
            }
            if (String.IsNullOrWhiteSpace(model)) model = description;
            bool hasSerial = !String.IsNullOrWhiteSpace(serial);
            string stable = hasSerial
                ? String.Join("|", new[] { manufacturer ?? "", product ?? "", serial })
                : (!String.IsNullOrWhiteSpace(path) ? path : String.Join("|", new[] { displayDevice ?? "", description ?? "" }));
            return new MonitorIdentity {
                Manufacturer = manufacturer,
                ProductCode = product,
                Model = model,
                Serial = serial,
                DevicePath = path,
                IdentityStatus = hasSerial ? "edid-serial" : "connection-fallback",
                StableMaterial = stable.ToLowerInvariant()
            };
        }

        private static string TextDescriptor(byte[] edid, byte tag)
        {
            if (edid == null) return null;
            for (int offset = 54; offset + 17 < edid.Length && offset < 126; offset += 18)
            {
                if (edid[offset] == 0 && edid[offset + 1] == 0 && edid[offset + 2] == 0 && edid[offset + 3] == tag)
                    return Encoding.ASCII.GetString(edid, offset + 5, 13).Trim('\0', ' ', '\r', '\n');
            }
            return null;
        }

        private static byte[] FindEdid(string hardwareId, string instanceId)
        {
            if (String.IsNullOrEmpty(hardwareId) || String.IsNullOrWhiteSpace(instanceId)) return null;
            try
            {
                using (RegistryKey root = Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Enum\DISPLAY\" + hardwareId))
                {
                    if (root == null) return null;
                    foreach (string instance in root.GetSubKeyNames())
                    {
                        if (!String.Equals(instance, instanceId, StringComparison.OrdinalIgnoreCase)) continue;
                        using (RegistryKey parameters = root.OpenSubKey(instance + @"\Device Parameters"))
                        {
                            byte[] value = parameters == null ? null : parameters.GetValue("EDID") as byte[];
                            if (value != null && value.Length >= 18) return value;
                        }
                    }
                }
            }
            catch { }
            return null;
        }
    }
}
