using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using MonitorTools.Engine;

internal static class EngineWorkerTests
{
    private sealed class SetResult
    {
        internal bool Accepted;
        internal int Error;
        internal Exception Exception;
        internal SetResult(bool accepted, int error) { Accepted = accepted; Error = error; }
        internal SetResult(Exception error) { Exception = error; }
    }

    private sealed class WriteCall
    {
        internal IntPtr Handle;
        internal byte Code;
        internal uint Value;
    }

    private sealed class FakeBackend : IMonitorBackend
    {
        internal readonly List<MonitorRecord> Monitors = new List<MonitorRecord>();
        internal readonly Dictionary<string, KeyValuePair<uint, uint>> Ranges = new Dictionary<string, KeyValuePair<uint, uint>>();
        internal readonly Dictionary<string, Queue<SetResult>> SetPlans = new Dictionary<string, Queue<SetResult>>();
        internal readonly List<WriteCall> Writes = new List<WriteCall>();
        internal readonly List<IntPtr> Destroyed = new List<IntPtr>();
        internal bool IncludeCapabilities;
        internal bool IncludeCurrentInput;
        internal bool EnumerationCompleted;

        public IList<MonitorRecord> Enumerate(bool includeCapabilities, bool includeCurrentInput)
        {
            IncludeCapabilities = includeCapabilities;
            IncludeCurrentInput = includeCurrentInput;
            List<MonitorRecord> copy = Monitors.Select(Clone).ToList();
            EnumerationCompleted = true;
            return copy;
        }

        public bool TryGetVcp(IntPtr handle, byte code, out uint current, out uint maximum)
        {
            KeyValuePair<uint, uint> range;
            if (Ranges.TryGetValue(Key(handle, code), out range))
            {
                current = range.Key;
                maximum = range.Value;
                return true;
            }
            current = 0;
            maximum = 0;
            return false;
        }

        public bool TrySetVcp(IntPtr handle, byte code, uint value, out int nativeError)
        {
            Assert(EnumerationCompleted, "Writes must occur only after the complete inventory is acquired.");
            Writes.Add(new WriteCall { Handle = handle, Code = code, Value = value });
            Queue<SetResult> plan;
            SetResult result = SetPlans.TryGetValue(Key(handle, code), out plan) && plan.Count > 0
                ? plan.Dequeue() : new SetResult(true, 0);
            if (result.Exception != null) throw result.Exception;
            nativeError = result.Error;
            return result.Accepted;
        }

        public void Destroy(IntPtr handle) { Destroyed.Add(handle); }

        internal void Range(IntPtr handle, byte code, uint current, uint maximum)
        {
            Ranges[Key(handle, code)] = new KeyValuePair<uint, uint>(current, maximum);
        }

        internal void Plan(IntPtr handle, byte code, params SetResult[] results)
        {
            SetPlans[Key(handle, code)] = new Queue<SetResult>(results);
        }

        private static string Key(IntPtr handle, byte code) { return handle.ToInt64() + ":" + code; }

        private static MonitorRecord Clone(MonitorRecord source)
        {
            return new MonitorRecord {
                Index = source.Index,
                Position = source.Position,
                StableId = source.StableId,
                IdentityStatus = source.IdentityStatus,
                Manufacturer = source.Manufacturer,
                ProductCode = source.ProductCode,
                Model = source.Model,
                Serial = source.Serial,
                DevicePath = source.DevicePath,
                DisplayDevice = source.DisplayDevice,
                Description = source.Description,
                MonitorLeft = source.MonitorLeft,
                MonitorTop = source.MonitorTop,
                MonitorRight = source.MonitorRight,
                MonitorBottom = source.MonitorBottom,
                Handle = source.Handle,
                Capabilities = source.Capabilities,
                AdvertisedInputs = source.AdvertisedInputs,
                CurrentInputCode = source.CurrentInputCode,
                CurrentInputHex = source.CurrentInputHex,
                CurrentInputName = source.CurrentInputName,
                Topology = source.Topology
            };
        }
    }

    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static string testRoot;

    private static void Assert(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static MonitorRecord Monitor(int index, string stableId, int left)
    {
        return new MonitorRecord {
            Index = index,
            StableId = stableId,
            IdentityStatus = "edid-serial",
            Model = "Test Panel " + index,
            Serial = "SERIAL" + index,
            DevicePath = "path-" + index,
            DisplayDevice = @"\\.\DISPLAY" + index,
            Description = "Physical Monitor " + index,
            MonitorLeft = left,
            MonitorTop = 0,
            MonitorRight = left + 1920,
            MonitorBottom = 1080,
            Handle = new IntPtr(index),
            AdvertisedInputs = new string[0]
        };
    }

    private static Dictionary<string, object> Request(string action)
    {
        return new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase) { { "action", action } };
    }

    private static string Config(string profileJson)
    {
        string path = Path.Combine(testRoot, Guid.NewGuid().ToString("N") + ".json");
        File.WriteAllText(path, "{\"schemaVersion\":2,\"profiles\":{\"other-pc\":" + profileJson + "}}", new UTF8Encoding(false));
        return path;
    }

    private static Dictionary<string, object> ProfileResponse(MonitorEngine engine, string config, string monitorId)
    {
        Dictionary<string, object> request = Request("profile");
        request["profile"] = "other-pc";
        if (monitorId != null) request["monitorId"] = monitorId;
        return Json.Deserialize<Dictionary<string, object>>(engine.Execute(request, config));
    }

    private static object[] Results(Dictionary<string, object> response)
    {
        return ((IEnumerable)response["Results"]).Cast<object>().ToArray();
    }

    private static void StableIdentityAndRawInputArePreserved()
    {
        Assert(MonitorEngine.GetStableId("sam|1234|serial") == "id-a23a3e062e70ea200ab7", "Stable IDs must retain the script SHA-256 format.");
        Assert(MonitorEngine.GetPrimaryInputName(5) == "0x05", "Vendor input 0x05 must remain a raw code.");
        string legacyPath = MonitorIdentityReader.SelectLegacyDevicePath("enum-path", "display", "topology-path-a");
        string changedTopologyPath = MonitorIdentityReader.SelectLegacyDevicePath("enum-path", "display", "topology-path-b");
        Assert(legacyPath == "enum-path" && changedTopologyPath == legacyPath,
            "Topology metadata must not change the legacy connection-fallback identity material.");
        string hardware;
        string instance;
        Assert(MonitorIdentityReader.ParseDeviceInterface(@"\\?\DISPLAY#SAM1234#ABC&1#{guid}", out hardware, out instance), "A display interface path should parse.");
        Assert(hardware == "SAM1234" && instance == "ABC&1", "EDID lookup must use the exact hardware and instance components.");

        byte[] edid = new byte[128];
        int manufacturer = (19 << 10) | (1 << 5) | 13;
        edid[8] = (byte)(manufacturer >> 8); edid[9] = (byte)manufacturer;
        edid[10] = 0x34; edid[11] = 0x12;
        edid[54 + 3] = 0xFF;
        byte[] serial = Encoding.ASCII.GetBytes("EXACT-SERIAL ");
        Array.Copy(serial, 0, edid, 59, serial.Length);
        MonitorIdentity identity = MonitorIdentityReader.DecodeEdid(edid, "exact-path", "display", "fallback");
        Assert(identity.Manufacturer == "SAM" && identity.ProductCode == "1234" && identity.Serial == "EXACT-SERIAL",
            "EDID manufacturer, product, and descriptor serial should decode exactly.");
        Assert(identity.IdentityStatus == "edid-serial" && identity.StableMaterial == "sam|1234|exact-serial", "A serial identity should not include the volatile display name.");

        FakeBackend backend = new FakeBackend();
        backend.Monitors.Add(Monitor(1, "id-raw", 0));
        List<int> delays = new List<int>();
        MonitorEngine engine = new MonitorEngine(backend, delays.Add);
        Dictionary<string, object> response = ProfileResponse(engine, Config("{\"id-raw\":\"0x05\"}"), null);
        Assert((bool)response["Success"], "A raw input profile should succeed.");
        Assert(backend.Writes.Count == 1 && backend.Writes[0].Code == 0x60 && backend.Writes[0].Value == 0x05,
            "Input 0x05 must reach VCP 0x60 unchanged.");
        Dictionary<string, object> result = (Dictionary<string, object>)Results(response)[0];
        Assert((bool)result["ApiAccepted"] && !(bool)result["PhysicalVerified"], "API acceptance must not claim physical verification.");
    }

    private static void LightweightListAvoidsOptionalReads()
    {
        FakeBackend backend = new FakeBackend();
        backend.Monitors.Add(Monitor(1, "id-list", 0));
        MonitorEngine engine = new MonitorEngine(backend, delegate(int ignored) { });
        object[] rows = Json.Deserialize<object[]>(engine.Execute(Request("list"), null));
        Assert(rows.Length == 1 && !backend.IncludeCapabilities && !backend.IncludeCurrentInput,
            "Default list must not request capabilities or current input.");
        Assert(backend.Writes.Count == 0 && backend.Destroyed.SequenceEqual(new[] { new IntPtr(1) }), "List must only enumerate and clean up handles.");

        FakeBackend detailed = new FakeBackend();
        detailed.Monitors.Add(Monitor(1, "id-list", 0));
        Dictionary<string, object> request = Request("list");
        request["includeCapabilities"] = true;
        request["includeCurrentInput"] = true;
        new MonitorEngine(detailed, delegate(int ignored) { }).Execute(request, null);
        Assert(detailed.IncludeCapabilities && detailed.IncludeCurrentInput, "Optional diagnostics reads should be explicitly forwarded.");
    }

    private static void TransientWritesRetryWithBounds()
    {
        FakeBackend backend = new FakeBackend();
        backend.Monitors.Add(Monitor(1, "id-retry", 0));
        backend.Plan(new IntPtr(1), 0x60, new SetResult(false, 121), new SetResult(false, 170), new SetResult(true, 0));
        List<int> delays = new List<int>();
        Dictionary<string, object> response = ProfileResponse(new MonitorEngine(backend, delays.Add), Config("{\"id-retry\":\"hdmi1\"}"), null);
        Assert((bool)response["Success"] && backend.Writes.Count == 3, "Transient failures should retry through success.");
        Assert(delays.SequenceEqual(new[] { 100, 250 }), "Retries must use the bounded 100/250 ms delays.");
        Dictionary<string, object> result = (Dictionary<string, object>)Results(response)[0];
        Assert(Convert.ToInt32(result["AttemptCount"], CultureInfo.InvariantCulture) == 3, "Attempt count should include retries.");

        FakeBackend permanent = new FakeBackend();
        permanent.Monitors.Add(Monitor(1, "id-stop", 0));
        permanent.Plan(new IntPtr(1), 0x60, new SetResult(false, 5), new SetResult(true, 0));
        Dictionary<string, object> failed = ProfileResponse(new MonitorEngine(permanent, delegate(int ignored) { }), Config("{\"id-stop\":\"hdmi1\"}"), null);
        Assert(!(bool)failed["Success"] && permanent.Writes.Count == 1, "A non-transient error must fail without retrying.");
    }

    private static void AmbiguityFailsClosedAndCleansUp()
    {
        FakeBackend backend = new FakeBackend();
        backend.Monitors.Add(Monitor(1, "id-duplicate", 0));
        backend.Monitors.Add(Monitor(2, "id-duplicate", 1920));
        Dictionary<string, object> response = ProfileResponse(new MonitorEngine(backend, delegate(int ignored) { }),
            Config("{\"all\":\"hdmi1\"}"), null);
        Assert(!(bool)response["Success"] && backend.Writes.Count == 0, "An all-monitor plan must reject ambiguous physical identities.");
        Assert(backend.Destroyed.Count == 2, "Every acquired physical handle must be cleaned up on ambiguity.");
        Assert(Convert.ToString(response["Error"]).IndexOf("ambiguous", StringComparison.OrdinalIgnoreCase) >= 0, "The ambiguity should be actionable.");
    }

    private static void EntirePlanIsValidatedBeforeWrites()
    {
        FakeBackend backend = new FakeBackend();
        backend.Monitors.Add(Monitor(1, "id-one", 0));
        backend.Monitors.Add(Monitor(2, "id-two", 1920));
        string config = Config("{\"id-one\":\"hdmi1\",\"id-two\":{\"brightness\":50}}");
        Dictionary<string, object> response = ProfileResponse(new MonitorEngine(backend, delegate(int ignored) { }), config, null);
        Assert(!(bool)response["Success"] && backend.Writes.Count == 0, "A bad late range must prevent every write in the plan.");
        Assert(backend.Destroyed.Count == 2, "Prevalidation failures must still close all handles.");

        FakeBackend invalid = new FakeBackend();
        invalid.Monitors.Add(Monitor(1, "id-one", 0));
        invalid.Monitors.Add(Monitor(2, "id-two", 1920));
        response = ProfileResponse(new MonitorEngine(invalid, delegate(int ignored) { }),
            Config("{\"id-one\":\"hdmi1\",\"id-two\":\"not-an-input\"}"), null);
        Assert(!(bool)response["Success"] && invalid.Writes.Count == 0, "A bad late input must prevent every write in the plan.");

        FakeBackend unused = new FakeBackend();
        unused.Monitors.Add(Monitor(1, "id-one", 0));
        string invalidUnused = Path.Combine(testRoot, Guid.NewGuid().ToString("N") + ".json");
        File.WriteAllText(invalidUnused,
            "{\"schemaVersion\":2,\"profiles\":{\"other-pc\":{\"id-one\":\"hdmi1\",\"id-missing\":\"0x100\"}}}",
            new UTF8Encoding(false));
        response = ProfileResponse(new MonitorEngine(unused, delegate(int ignored) { }), invalidUnused, "id-one");
        Assert(!(bool)response["Success"] && unused.Writes.Count == 0,
            "The complete configuration must validate before a selected-monitor filter skips unused assignments.");
    }

    private static void SceneValuesNormalizeAndPartialResultsSurvive()
    {
        FakeBackend backend = new FakeBackend();
        backend.Monitors.Add(Monitor(1, "id-scene", 0));
        backend.Range(new IntPtr(1), 0x10, 0, 1000);
        backend.Range(new IntPtr(1), 0x62, 0, 255);
        Dictionary<string, object> response = ProfileResponse(new MonitorEngine(backend, delegate(int ignored) { }),
            Config("{\"id-scene\":{\"brightness\":33,\"volume\":50}}"), null);
        Assert((bool)response["Success"] && backend.Writes.Count == 2, "A brightness/volume scene should produce two operations.");
        Assert(backend.Writes[0].Code == 0x10 && backend.Writes[0].Value == 330, "Brightness should normalize against the reported maximum.");
        Assert(backend.Writes[1].Code == 0x62 && backend.Writes[1].Value == 128, "Volume should use midpoint-to-even normalization.");

        FakeBackend partial = new FakeBackend();
        partial.Monitors.Add(Monitor(1, "id-partial", 0));
        partial.Range(new IntPtr(1), 0x10, 0, 100);
        partial.Plan(new IntPtr(1), 0x60, new SetResult(false, 5));
        response = ProfileResponse(new MonitorEngine(partial, delegate(int ignored) { }),
            Config("{\"id-partial\":{\"input\":\"hdmi1\",\"brightness\":40}}"), null);
        Assert(!(bool)response["Success"] && Results(response).Length == 2 && partial.Writes.Count == 2,
            "All prevalidated operations should run and preserve partial results.");
        Dictionary<string, object> second = (Dictionary<string, object>)Results(response)[1];
        Assert((bool)second["ApiAccepted"], "A later successful operation must remain visible after an earlier failure.");

        FakeBackend exceptional = new FakeBackend();
        exceptional.Monitors.Add(Monitor(1, "id-exception", 0));
        exceptional.Range(new IntPtr(1), 0x10, 0, 100);
        exceptional.Plan(new IntPtr(1), 0x10, new SetResult(new InvalidOperationException("simulated driver exception")));
        response = ProfileResponse(new MonitorEngine(exceptional, delegate(int ignored) { }),
            Config("{\"id-exception\":{\"input\":\"hdmi1\",\"brightness\":40}}"), null);
        Assert(!(bool)response["Success"] && Results(response).Length == 2,
            "A backend exception must preserve earlier accepted results and produce a failed row.");
        Dictionary<string, object> first = (Dictionary<string, object>)Results(response)[0];
        second = (Dictionary<string, object>)Results(response)[1];
        Assert((bool)first["ApiAccepted"] && !(bool)second["ApiAccepted"] &&
            Convert.ToString(second["Error"]).Contains("simulated driver exception"),
            "Backend exception details should be attached to only the failed operation.");
    }

    private static void FilterSkipsMissingUnrelatedTargets()
    {
        FakeBackend backend = new FakeBackend();
        backend.Monitors.Add(Monitor(1, "id-selected", 0));
        string config = Config("{\"id-selected\":\"hdmi1\",\"id-not-connected\":\"displayport1\"}");
        Dictionary<string, object> response = ProfileResponse(new MonitorEngine(backend, delegate(int ignored) { }), config, "id-selected");
        Assert((bool)response["Success"] && backend.Writes.Count == 1, "A selected-monitor retry must ignore unrelated missing targets.");
    }

    internal static int Main()
    {
        testRoot = Path.Combine(Path.GetTempPath(), "monitor-tools-compiled-engine-" + Guid.NewGuid().ToString("N"));
        try
        {
            Directory.CreateDirectory(testRoot);
            StableIdentityAndRawInputArePreserved();
            LightweightListAvoidsOptionalReads();
            TransientWritesRetryWithBounds();
            AmbiguityFailsClosedAndCleansUp();
            EntirePlanIsValidatedBeforeWrites();
            SceneValuesNormalizeAndPartialResultsSurvive();
            FilterSkipsMissingUnrelatedTargets();
            Console.WriteLine("PASS: compiled engine identity, planning, retries, results, and cleanup.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
        finally
        {
            try { if (Directory.Exists(testRoot)) Directory.Delete(testRoot, true); } catch { }
        }
    }
}
