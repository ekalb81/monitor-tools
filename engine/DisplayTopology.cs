using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace MonitorTools.Engine
{
    // Native contracts:
    // https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-querydisplayconfig
    // https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-displayconfiggetdeviceinfo
    public sealed class TopologyInfo
    {
        public string DisplayDevice { get; set; }
        public string SourceAdapterLuid { get; set; }
        public uint SourceId { get; set; }
        public string TargetAdapterLuid { get; set; }
        public uint TargetId { get; set; }
        public string MonitorDevicePath { get; set; }
        public string MonitorFriendlyName { get; set; }
        public string SourceAdapterDevicePath { get; set; }
        public string TargetAdapterDevicePath { get; set; }
    }

    public static class DisplayTopology
    {
        private const uint QdcOnlyActivePaths = 0x00000002;
        private const int ErrorSuccess = 0;
        private const int ErrorInsufficientBuffer = 122;
        private const int MaximumBufferAttempts = 3;

        public static Dictionary<string, TopologyInfo> Read()
        {
            try { return Read(new WindowsDisplayTopologyNative()); }
            catch { return Empty(); }
        }

        internal static Dictionary<string, TopologyInfo> Read(IDisplayTopologyNative native)
        {
            if (native == null) throw new ArgumentNullException("native");
            try
            {
                for (int attempt = 0; attempt < MaximumBufferAttempts; attempt++)
                {
                    uint pathCount;
                    uint modeCount;
                    int status = native.GetDisplayConfigBufferSizes(QdcOnlyActivePaths, out pathCount, out modeCount);
                    if (status == ErrorInsufficientBuffer) continue;
                    if (status != ErrorSuccess) return Empty();
                    if (pathCount == 0) return Empty();

                    DisplayConfigPathInfo[] paths = new DisplayConfigPathInfo[checked((int)pathCount)];
                    // The native parameter is required even when a transient topology reports zero modes.
                    DisplayConfigModeInfo[] modes = new DisplayConfigModeInfo[Math.Max(1, checked((int)modeCount))];
                    status = native.QueryDisplayConfig(QdcOnlyActivePaths, ref pathCount, paths, ref modeCount, modes);
                    if (status == ErrorInsufficientBuffer) continue;
                    if (status != ErrorSuccess) return Empty();

                    Dictionary<string, TopologyInfo> result = Empty();
                    HashSet<string> ambiguousSources = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    int validPathCount = Math.Min(paths.Length, checked((int)pathCount));
                    for (int index = 0; index < validPathCount; index++)
                    {
                        DisplayConfigPathInfo path = paths[index];
                        DisplayConfigSourceDeviceName source = DisplayConfigSourceDeviceName.Create(path.SourceInfo.AdapterId, path.SourceInfo.Id);
                        if (native.GetSourceName(ref source) != ErrorSuccess || String.IsNullOrWhiteSpace(source.ViewGdiDeviceName)) continue;

                        // A cloned GDI source can drive multiple physical targets. A dictionary keyed by the GDI
                        // name cannot represent that relationship accurately, so omit every ambiguous source.
                        if (ambiguousSources.Contains(source.ViewGdiDeviceName)) continue;
                        if (result.ContainsKey(source.ViewGdiDeviceName))
                        {
                            result.Remove(source.ViewGdiDeviceName);
                            ambiguousSources.Add(source.ViewGdiDeviceName);
                            continue;
                        }

                        DisplayConfigTargetDeviceName target = DisplayConfigTargetDeviceName.Create(path.TargetInfo.AdapterId, path.TargetInfo.Id);
                        if (native.GetTargetName(ref target) != ErrorSuccess) target = DisplayConfigTargetDeviceName.Empty;
                        DisplayConfigAdapterName sourceAdapter = DisplayConfigAdapterName.Create(path.SourceInfo.AdapterId);
                        if (native.GetAdapterName(ref sourceAdapter) != ErrorSuccess) sourceAdapter = DisplayConfigAdapterName.Empty;
                        DisplayConfigAdapterName targetAdapter = DisplayConfigAdapterName.Create(path.TargetInfo.AdapterId);
                        if (native.GetAdapterName(ref targetAdapter) != ErrorSuccess) targetAdapter = DisplayConfigAdapterName.Empty;

                        result[source.ViewGdiDeviceName] = new TopologyInfo
                        {
                            DisplayDevice = source.ViewGdiDeviceName,
                            SourceAdapterLuid = FormatLuid(path.SourceInfo.AdapterId),
                            SourceId = path.SourceInfo.Id,
                            TargetAdapterLuid = FormatLuid(path.TargetInfo.AdapterId),
                            TargetId = path.TargetInfo.Id,
                            MonitorDevicePath = target.MonitorDevicePath ?? String.Empty,
                            MonitorFriendlyName = target.MonitorFriendlyDeviceName ?? String.Empty,
                            SourceAdapterDevicePath = sourceAdapter.AdapterDevicePath ?? String.Empty,
                            TargetAdapterDevicePath = targetAdapter.AdapterDevicePath ?? String.Empty
                        };
                    }
                    return result;
                }
            }
            catch { }
            return Empty();
        }

        private static Dictionary<string, TopologyInfo> Empty()
        {
            return new Dictionary<string, TopologyInfo>(StringComparer.OrdinalIgnoreCase);
        }

        internal static string FormatLuid(DisplayConfigLuid luid)
        {
            return String.Format("0x{0:X8}:0x{1:X8}", unchecked((uint)luid.HighPart), luid.LowPart);
        }
    }

    internal interface IDisplayTopologyNative
    {
        int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);
        int QueryDisplayConfig(uint flags, ref uint pathCount, DisplayConfigPathInfo[] paths,
            ref uint modeCount, DisplayConfigModeInfo[] modes);
        int GetSourceName(ref DisplayConfigSourceDeviceName source);
        int GetTargetName(ref DisplayConfigTargetDeviceName target);
        int GetAdapterName(ref DisplayConfigAdapterName adapter);
    }

    internal sealed class WindowsDisplayTopologyNative : IDisplayTopologyNative
    {
        public int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount)
        {
            return Native.GetDisplayConfigBufferSizes(flags, out pathCount, out modeCount);
        }

        public int QueryDisplayConfig(uint flags, ref uint pathCount, DisplayConfigPathInfo[] paths,
            ref uint modeCount, DisplayConfigModeInfo[] modes)
        {
            return Native.QueryDisplayConfig(flags, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
        }

        public int GetSourceName(ref DisplayConfigSourceDeviceName source) { return Native.GetSourceName(ref source); }
        public int GetTargetName(ref DisplayConfigTargetDeviceName target) { return Native.GetTargetName(ref target); }
        public int GetAdapterName(ref DisplayConfigAdapterName adapter) { return Native.GetAdapterName(ref adapter); }

        private static class Native
        {
            [DllImport("user32.dll")]
            internal static extern int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount);

            [DllImport("user32.dll")]
            internal static extern int QueryDisplayConfig(uint flags, ref uint pathCount,
                [Out] DisplayConfigPathInfo[] paths, ref uint modeCount,
                [Out] DisplayConfigModeInfo[] modes, IntPtr currentTopologyId);

            [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")]
            internal static extern int GetSourceName(ref DisplayConfigSourceDeviceName source);

            [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")]
            internal static extern int GetTargetName(ref DisplayConfigTargetDeviceName target);

            [DllImport("user32.dll", EntryPoint = "DisplayConfigGetDeviceInfo")]
            internal static extern int GetAdapterName(ref DisplayConfigAdapterName adapter);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigLuid
    {
        internal uint LowPart;
        internal int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigPathSourceInfo
    {
        internal DisplayConfigLuid AdapterId;
        internal uint Id;
        internal uint ModeInfoIndex;
        internal uint StatusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigRational
    {
        internal uint Numerator;
        internal uint Denominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigPathTargetInfo
    {
        internal DisplayConfigLuid AdapterId;
        internal uint Id;
        internal uint ModeInfoIndex;
        internal uint OutputTechnology;
        internal uint Rotation;
        internal uint Scaling;
        internal DisplayConfigRational RefreshRate;
        internal uint ScanLineOrdering;
        [MarshalAs(UnmanagedType.Bool)] internal bool TargetAvailable;
        internal uint StatusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigPathInfo
    {
        internal DisplayConfigPathSourceInfo SourceInfo;
        internal DisplayConfigPathTargetInfo TargetInfo;
        internal uint Flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigPoint
    {
        internal int X;
        internal int Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigSize
    {
        internal uint Width;
        internal uint Height;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigRegion
    {
        internal int Left;
        internal int Top;
        internal int Right;
        internal int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigVideoSignalInfo
    {
        internal ulong PixelRate;
        internal DisplayConfigRational HorizontalSyncFrequency;
        internal DisplayConfigRational VerticalSyncFrequency;
        internal DisplayConfigSize ActiveSize;
        internal DisplayConfigSize TotalSize;
        internal uint VideoStandard;
        internal uint ScanLineOrdering;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigTargetMode
    {
        internal DisplayConfigVideoSignalInfo TargetVideoSignalInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigSourceMode
    {
        internal uint Width;
        internal uint Height;
        internal uint PixelFormat;
        internal DisplayConfigPoint Position;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigDesktopImageInfo
    {
        internal DisplayConfigPoint PathSourceSize;
        internal DisplayConfigRegion DesktopImageRegion;
        internal DisplayConfigRegion DesktopImageClip;
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct DisplayConfigModeUnion
    {
        [FieldOffset(0)] internal DisplayConfigTargetMode TargetMode;
        [FieldOffset(0)] internal DisplayConfigSourceMode SourceMode;
        [FieldOffset(0)] internal DisplayConfigDesktopImageInfo DesktopImageInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigModeInfo
    {
        internal uint InfoType;
        internal uint Id;
        internal DisplayConfigLuid AdapterId;
        internal DisplayConfigModeUnion Mode;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct DisplayConfigDeviceInfoHeader
    {
        internal uint Type;
        internal uint Size;
        internal DisplayConfigLuid AdapterId;
        internal uint Id;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct DisplayConfigSourceDeviceName
    {
        internal DisplayConfigDeviceInfoHeader Header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] internal string ViewGdiDeviceName;

        internal static DisplayConfigSourceDeviceName Create(DisplayConfigLuid adapterId, uint id)
        {
            DisplayConfigSourceDeviceName value = new DisplayConfigSourceDeviceName();
            value.Header.Type = 1;
            value.Header.Size = (uint)Marshal.SizeOf(typeof(DisplayConfigSourceDeviceName));
            value.Header.AdapterId = adapterId;
            value.Header.Id = id;
            return value;
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct DisplayConfigTargetDeviceName
    {
        internal DisplayConfigDeviceInfoHeader Header;
        internal uint Flags;
        internal uint OutputTechnology;
        internal ushort EdidManufactureId;
        internal ushort EdidProductCodeId;
        internal uint ConnectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] internal string MonitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string MonitorDevicePath;

        internal static DisplayConfigTargetDeviceName Empty { get { return new DisplayConfigTargetDeviceName(); } }

        internal static DisplayConfigTargetDeviceName Create(DisplayConfigLuid adapterId, uint id)
        {
            DisplayConfigTargetDeviceName value = new DisplayConfigTargetDeviceName();
            value.Header.Type = 2;
            value.Header.Size = (uint)Marshal.SizeOf(typeof(DisplayConfigTargetDeviceName));
            value.Header.AdapterId = adapterId;
            value.Header.Id = id;
            return value;
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct DisplayConfigAdapterName
    {
        internal DisplayConfigDeviceInfoHeader Header;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string AdapterDevicePath;

        internal static DisplayConfigAdapterName Empty { get { return new DisplayConfigAdapterName(); } }

        internal static DisplayConfigAdapterName Create(DisplayConfigLuid adapterId)
        {
            DisplayConfigAdapterName value = new DisplayConfigAdapterName();
            value.Header.Type = 4;
            value.Header.Size = (uint)Marshal.SizeOf(typeof(DisplayConfigAdapterName));
            value.Header.AdapterId = adapterId;
            value.Header.Id = 0;
            return value;
        }
    }
}
