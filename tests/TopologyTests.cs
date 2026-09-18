using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using MonitorTools.Engine;

internal static class TopologyTests
{
    private sealed class FakeNative : IDisplayTopologyNative
    {
        internal readonly List<int> QueryResults = new List<int>();
        internal readonly List<int> BufferResults = new List<int>();
        internal DisplayConfigPathInfo[] ReturnedPaths = new DisplayConfigPathInfo[0];
        internal int BufferStatus;
        internal int SourceStatus;
        internal int TargetStatus;
        internal int AdapterStatus;
        internal int BufferCalls;
        internal int QueryCalls;

        public int GetDisplayConfigBufferSizes(uint flags, out uint pathCount, out uint modeCount)
        {
            int call = BufferCalls++;
            pathCount = (uint)ReturnedPaths.Length;
            modeCount = pathCount == 0 ? 0u : 1u;
            return call < BufferResults.Count ? BufferResults[call] : BufferStatus;
        }

        public int QueryDisplayConfig(uint flags, ref uint pathCount, DisplayConfigPathInfo[] paths,
            ref uint modeCount, DisplayConfigModeInfo[] modes)
        {
            int call = QueryCalls++;
            int result = call < QueryResults.Count ? QueryResults[call] : 0;
            if (result != 0) return result;
            pathCount = (uint)ReturnedPaths.Length;
            for (int index = 0; index < ReturnedPaths.Length; index++) paths[index] = ReturnedPaths[index];
            return 0;
        }

        public int GetSourceName(ref DisplayConfigSourceDeviceName source)
        {
            if (SourceStatus != 0) return SourceStatus;
            source.ViewGdiDeviceName = @"\\.\DISPLAY" + (source.Header.Id + 1);
            return 0;
        }

        public int GetTargetName(ref DisplayConfigTargetDeviceName target)
        {
            if (TargetStatus != 0) return TargetStatus;
            target.MonitorFriendlyDeviceName = "Monitor " + target.Header.Id;
            target.MonitorDevicePath = @"\\?\DISPLAY#TARGET" + target.Header.Id;
            return 0;
        }

        public int GetAdapterName(ref DisplayConfigAdapterName adapter)
        {
            if (AdapterStatus != 0) return AdapterStatus;
            adapter.AdapterDevicePath = @"\\?\PCI#ADAPTER" + adapter.Header.AdapterId.LowPart;
            return 0;
        }
    }

    private static DisplayConfigPathInfo Path(uint sourceLow, int sourceHigh, uint sourceId,
        uint targetLow, int targetHigh, uint targetId)
    {
        DisplayConfigPathInfo path = new DisplayConfigPathInfo();
        path.SourceInfo.AdapterId.LowPart = sourceLow;
        path.SourceInfo.AdapterId.HighPart = sourceHigh;
        path.SourceInfo.Id = sourceId;
        path.TargetInfo.AdapterId.LowPart = targetLow;
        path.TargetInfo.AdapterId.HighPart = targetHigh;
        path.TargetInfo.Id = targetId;
        path.TargetInfo.TargetAvailable = true;
        path.Flags = 1;
        return path;
    }

    private static void Equal<T>(T actual, T expected, string message)
    {
        if (!EqualityComparer<T>.Default.Equals(actual, expected))
            throw new InvalidOperationException(message + " Expected '" + expected + "', received '" + actual + "'.");
    }

    private static void Layout()
    {
        Equal(Marshal.SizeOf(typeof(DisplayConfigLuid)), 8, "LUID size");
        Equal(Marshal.SizeOf(typeof(DisplayConfigPathSourceInfo)), 20, "source path size");
        Equal(Marshal.SizeOf(typeof(DisplayConfigPathTargetInfo)), 48, "target path size");
        Equal(Marshal.SizeOf(typeof(DisplayConfigPathInfo)), 72, "path size");
        Equal(Marshal.SizeOf(typeof(DisplayConfigModeInfo)), 64, "mode size");
        Equal(Marshal.SizeOf(typeof(DisplayConfigDeviceInfoHeader)), 20, "device header size");
        Equal(Marshal.SizeOf(typeof(DisplayConfigSourceDeviceName)), 84, "source name size");
        Equal(Marshal.SizeOf(typeof(DisplayConfigTargetDeviceName)), 420, "target name size");
        Equal(Marshal.SizeOf(typeof(DisplayConfigAdapterName)), 276, "adapter name size");
    }

    private static void MapsActivePaths()
    {
        FakeNative native = new FakeNative();
        native.ReturnedPaths = new[] {
            Path(0x89ABCDEF, unchecked((int)0xFEDCBA98), 0, 0x76543210, unchecked((int)0x01234567), 7),
            Path(2, 1, 1, 2, 1, 9)
        };
        Dictionary<string, TopologyInfo> result = DisplayTopology.Read(native);
        Equal(result.Count, 2, "mapped display count");
        TopologyInfo first = result[@"\\.\DISPLAY1"];
        Equal(first.DisplayDevice, @"\\.\DISPLAY1", "GDI source name");
        Equal(first.SourceAdapterLuid, "0xFEDCBA98:0x89ABCDEF", "source LUID");
        Equal(first.SourceId, 0u, "source id");
        Equal(first.TargetAdapterLuid, "0x01234567:0x76543210", "target LUID");
        Equal(first.TargetId, 7u, "target id");
        Equal(first.MonitorFriendlyName, "Monitor 7", "friendly monitor name");
        Equal(first.MonitorDevicePath, @"\\?\DISPLAY#TARGET7", "monitor device path");
        Equal(first.SourceAdapterDevicePath, @"\\?\PCI#ADAPTER2309737967", "source adapter path");
        Equal(first.TargetAdapterDevicePath, @"\\?\PCI#ADAPTER1985229328", "target adapter path");
    }

    private static void RetriesBufferRace()
    {
        FakeNative native = new FakeNative();
        native.ReturnedPaths = new[] { Path(1, 0, 0, 1, 0, 2) };
        native.BufferResults.Add(122);
        native.BufferResults.Add(0);
        native.QueryResults.Add(122);
        native.QueryResults.Add(0);
        Dictionary<string, TopologyInfo> result = DisplayTopology.Read(native);
        Equal(result.Count, 1, "retry result");
        Equal(native.BufferCalls, 3, "buffer sizing retry count");
        Equal(native.QueryCalls, 2, "query retry count");

        FakeNative unstable = new FakeNative();
        unstable.ReturnedPaths = native.ReturnedPaths;
        unstable.QueryResults.Add(122);
        unstable.QueryResults.Add(122);
        unstable.QueryResults.Add(122);
        Equal(DisplayTopology.Read(unstable).Count, 0, "bounded retry returns empty");
        Equal(unstable.QueryCalls, 3, "bounded query attempts");
    }

    private static void GracefulFailuresAndClones()
    {
        FakeNative unavailable = new FakeNative();
        unavailable.ReturnedPaths = new[] { Path(1, 0, 0, 1, 0, 1) };
        unavailable.BufferStatus = 50;
        Equal(DisplayTopology.Read(unavailable).Count, 0, "unsupported topology");

        FakeNative missingSource = new FakeNative();
        missingSource.ReturnedPaths = unavailable.ReturnedPaths;
        missingSource.SourceStatus = 31;
        Equal(DisplayTopology.Read(missingSource).Count, 0, "source name is required");

        FakeNative optionalNames = new FakeNative();
        optionalNames.ReturnedPaths = unavailable.ReturnedPaths;
        optionalNames.TargetStatus = 31;
        optionalNames.AdapterStatus = 31;
        TopologyInfo partial = DisplayTopology.Read(optionalNames)[@"\\.\DISPLAY1"];
        Equal(partial.MonitorDevicePath, String.Empty, "target failure is additive");
        Equal(partial.SourceAdapterDevicePath, String.Empty, "source adapter failure is additive");
        Equal(partial.TargetAdapterDevicePath, String.Empty, "target adapter failure is additive");

        FakeNative clone = new FakeNative();
        clone.ReturnedPaths = new[] { Path(1, 0, 0, 1, 0, 10), Path(1, 0, 0, 1, 0, 11) };
        Dictionary<string, TopologyInfo> clones = DisplayTopology.Read(clone);
        Equal(clones.Count, 0, "ambiguous clone source is omitted");
    }

    private static int Main()
    {
        Layout();
        MapsActivePaths();
        RetriesBufferRace();
        GracefulFailuresAndClones();
        Console.WriteLine("PASS: topology ABI, mapping, bounded buffer retries, and graceful failures");
        return 0;
    }
}
