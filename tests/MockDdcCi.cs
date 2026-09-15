using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

// In-memory replacement for the native boundary. Never calls Windows monitor APIs.
public static class MockDdcCiForTests
{
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        public string szPhysicalMonitorDescription;
    }

    public delegate bool MonitorEnumProc(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);
    public static int MonitorCount;
    public static string Capabilities;
    public static int FailWriteOn;
    public static readonly List<int> Acquired = new List<int>();
    public static readonly List<int> Released = new List<int>();
    public static readonly List<string> Writes = new List<string>();
    public static readonly List<int> Saves = new List<int>();

    public static void Reset(int count)
    {
        MonitorCount = count;
        Capabilities = "vcp(60(0F 11))";
        FailWriteOn = 0;
        Acquired.Clear();
        Released.Clear();
        Writes.Clear();
        Saves.Clear();
    }

    public static bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorEnumProc callback, IntPtr data)
    {
        for (int i = 1; i <= MonitorCount; i++)
            if (!callback((IntPtr)i, dc, clip, data)) return false;
        return true;
    }

    public static bool GetMonitorInfo(IntPtr monitor, ref MONITORINFOEX info)
    {
        info.rcMonitor.Left = (int)monitor * 100;
        info.szDevice = "MockDisplay" + monitor;
        return true;
    }

    public static bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr monitor, out uint count)
    {
        count = 1;
        return true;
    }

    public static bool GetPhysicalMonitorsFromHMONITOR(IntPtr monitor, uint count, PHYSICAL_MONITOR[] monitors)
    {
        monitors[0].hPhysicalMonitor = monitor;
        monitors[0].szPhysicalMonitorDescription = "MockMonitor" + monitor;
        Acquired.Add((int)monitor);
        return true;
    }

    public static bool DestroyPhysicalMonitor(IntPtr monitor)
    {
        Released.Add((int)monitor);
        return true;
    }

    public static bool GetCapabilitiesStringLength(IntPtr monitor, out uint length)
    {
        length = (uint)Capabilities.Length + 1;
        return true;
    }

    public static bool CapabilitiesRequestAndCapabilitiesReply(IntPtr monitor, StringBuilder buffer, uint length)
    {
        buffer.Append(Capabilities);
        return true;
    }

    public static bool GetVCPFeatureAndVCPFeatureReply(IntPtr monitor, byte code, out uint type, out uint current, out uint maximum)
    {
        type = 0;
        current = 15;
        maximum = 255;
        return true;
    }

    public static bool SetVCPFeature(IntPtr monitor, byte code, uint value)
    {
        if ((int)monitor == FailWriteOn) return false;
        Writes.Add(monitor + ":" + code + ":" + value);
        return true;
    }

    public static bool SaveCurrentSettings(IntPtr monitor)
    {
        Saves.Add((int)monitor);
        return true;
    }
}
