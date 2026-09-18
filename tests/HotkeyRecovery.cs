using System;
using System.Collections.Generic;
using System.Linq;

internal static class HotkeyRecoveryTests
{
    private sealed class RegistrationResult
    {
        internal readonly bool Success;
        internal readonly int Error;
        internal RegistrationResult(bool success, int error) { Success = success; Error = error; }
    }

    private sealed class FakeBackend : IHotkeyRegistrationBackend
    {
        internal readonly Dictionary<uint, Queue<RegistrationResult>> Plans = new Dictionary<uint, Queue<RegistrationResult>>();
        internal readonly Dictionary<uint, int> Calls = new Dictionary<uint, int>();
        internal readonly Dictionary<int, uint> Held = new Dictionary<int, uint>();
        internal readonly List<int> Unregistered = new List<int>();

        internal void Plan(uint key, params RegistrationResult[] results)
        {
            Plans[key] = new Queue<RegistrationResult>(results);
        }

        public bool Register(int id, uint modifiers, uint key, out int nativeError)
        {
            Calls[key] = Calls.ContainsKey(key) ? Calls[key] + 1 : 1;
            Queue<RegistrationResult> plan;
            RegistrationResult result = Plans.TryGetValue(key, out plan) && plan.Count > 0
                ? plan.Dequeue() : new RegistrationResult(true, 0);
            nativeError = result.Error;
            if (result.Success) Held[id] = key;
            return result.Success;
        }

        public void Unregister(int id)
        {
            Unregistered.Add(id);
            Held.Remove(id);
        }
    }

    private sealed class ManualScheduler : IHotkeyRetryScheduler
    {
        internal Action Current;
        internal int ScheduleCount;
        internal int CancelCount;
        internal bool Disposed;

        public void Schedule(int delayMilliseconds, Action callback)
        {
            Assert(delayMilliseconds > 0, "Retry delay must be positive.");
            Current = callback;
            ScheduleCount++;
        }

        public void Cancel()
        {
            Current = null;
            CancelCount++;
        }

        internal void Fire()
        {
            Action callback = Current;
            Assert(callback != null, "Expected a pending retry callback.");
            Current = null;
            callback();
        }

        public void Dispose() { Disposed = true; Current = null; }
    }

    private static RegistrationResult Ok() { return new RegistrationResult(true, 0); }
    private static RegistrationResult Conflict() { return new RegistrationResult(false, 1409); }

    private static bool Parse(string value, out uint modifiers, out uint key)
    {
        modifiers = 2;
        key = 0;
        if (String.IsNullOrWhiteSpace(value) || !value.StartsWith("HK", StringComparison.Ordinal)) return false;
        return UInt32.TryParse(value.Substring(2), out key) && key > 0;
    }

    private static Dictionary<string, string> Values(params string[] hotkeys)
    {
        Dictionary<string, string> values = new Dictionary<string, string>();
        for (int i = 0; i < hotkeys.Length; i++) values["profile-" + i] = hotkeys[i];
        return values;
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static int Calls(FakeBackend backend, uint key)
    {
        int count;
        return backend.Calls.TryGetValue(key, out count) ? count : 0;
    }

    private static void TransientConflictRecovers()
    {
        FakeBackend backend = new FakeBackend();
        ManualScheduler scheduler = new ManualScheduler();
        backend.Plan(1, Conflict(), Ok());
        List<HotkeyFailure> failures = new List<HotkeyFailure>();
        using (HotkeyRegistrationManager manager = new HotkeyRegistrationManager(backend, scheduler, Parse, 10, 1000))
        {
            manager.RegistrationFailed += delegate(List<HotkeyFailure> items) { failures.AddRange(items); };
            manager.Replace(Values("HK1"));
            Assert(backend.Held.Count == 0 && scheduler.Current != null, "A transient conflict should schedule recovery.");
            scheduler.Fire();
            Assert(backend.Held.Values.Contains((uint)1), "The retried key should become registered.");
            Assert(failures.Count == 0, "A recovered conflict must not be reported.");
            Assert(Calls(backend, 1) == 2 && scheduler.Current == null, "Recovery should stop after success.");
        }
    }

    private static void PersistentConflictReportsNativeError()
    {
        FakeBackend backend = new FakeBackend();
        ManualScheduler scheduler = new ManualScheduler();
        backend.Plan(2, Conflict(), Conflict(), Conflict());
        List<HotkeyFailure> failures = new List<HotkeyFailure>();
        using (HotkeyRegistrationManager manager = new HotkeyRegistrationManager(backend, scheduler, Parse, 3, 1))
        {
            manager.RegistrationFailed += delegate(List<HotkeyFailure> items) { failures.AddRange(items); };
            manager.Replace(Values("HK2"));
            Assert(failures.Count == 0, "A conflict must stay quiet while retries remain.");
            scheduler.Fire();
            Assert(failures.Count == 0, "A conflict must stay quiet before the final attempt.");
            scheduler.Fire();
            Assert(failures.Count == 1, "A persistent conflict should be reported once.");
            Assert(failures[0].NativeError == 1409 && failures[0].Attempts == 3,
                "The failure must preserve the native error and attempt count.");
            Assert(scheduler.Current == null, "Persistent failure should stop retrying at the bound.");
        }
    }

    private static void SuccessfulKeysStayRegisteredDuringRecovery()
    {
        FakeBackend backend = new FakeBackend();
        ManualScheduler scheduler = new ManualScheduler();
        backend.Plan(3, Ok());
        backend.Plan(4, Conflict(), Conflict(), Ok());
        using (HotkeyRegistrationManager manager = new HotkeyRegistrationManager(backend, scheduler, Parse, 5, 1))
        {
            manager.Replace(Values("HK3", "HK4"));
            Assert(backend.Held.Values.Contains((uint)3), "The successful key should be held immediately.");
            scheduler.Fire();
            Assert(backend.Held.Values.Contains((uint)3), "Retrying another key must not release a successful registration.");
            Assert(backend.Unregistered.Count == 0 && Calls(backend, 3) == 1,
                "Successful registrations must not be unregistered or retried.");
            scheduler.Fire();
            Assert(backend.Held.Values.Contains((uint)3) && backend.Held.Values.Contains((uint)4),
                "Both registrations should remain held after recovery.");
        }
    }

    private static void ReplacementCancelsOldRecovery()
    {
        FakeBackend backend = new FakeBackend();
        ManualScheduler scheduler = new ManualScheduler();
        backend.Plan(5, Conflict(), Ok());
        using (HotkeyRegistrationManager manager = new HotkeyRegistrationManager(backend, scheduler, Parse, 5, 1))
        {
            manager.Replace(Values("HK5"));
            Action stale = scheduler.Current;
            Assert(stale != null, "The old configuration should have a retry pending.");
            manager.Replace(Values("HK6"));
            Assert(backend.Held.Values.SequenceEqual(new[] { (uint)6 }), "Replacement should register only the new configuration.");
            int oldCalls = Calls(backend, 5);
            stale();
            Assert(Calls(backend, 5) == oldCalls, "A canceled callback must not retry the old configuration.");
            Assert(backend.Held.Values.SequenceEqual(new[] { (uint)6 }), "A stale callback must not disturb the replacement.");
        }
    }

    private static void DisposalCancelsAndReleases()
    {
        FakeBackend backend = new FakeBackend();
        ManualScheduler scheduler = new ManualScheduler();
        backend.Plan(7, Ok());
        backend.Plan(8, Conflict(), Ok());
        HotkeyRegistrationManager manager = new HotkeyRegistrationManager(backend, scheduler, Parse, 5, 1);
        manager.Replace(Values("HK7", "HK8"));
        Action stale = scheduler.Current;
        manager.Dispose();
        Assert(scheduler.Disposed && backend.Held.Count == 0, "Disposal must cancel scheduling and release registered keys.");
        int pendingCalls = Calls(backend, 8);
        stale();
        Assert(Calls(backend, 8) == pendingCalls, "A callback after disposal must be inert.");
        bool threw = false;
        try { manager.Replace(Values("HK9")); } catch (ObjectDisposedException) { threw = true; }
        Assert(threw, "A disposed manager must reject replacement.");
    }

    private static void InvalidAndNonTransientFailuresDoNotRetry()
    {
        FakeBackend backend = new FakeBackend();
        ManualScheduler scheduler = new ManualScheduler();
        backend.Plan(10, new RegistrationResult(false, 87));
        List<HotkeyFailure> failures = new List<HotkeyFailure>();
        using (HotkeyRegistrationManager manager = new HotkeyRegistrationManager(backend, scheduler, Parse, 5, 1))
        {
            manager.RegistrationFailed += delegate(List<HotkeyFailure> items) { failures.AddRange(items); };
            manager.Replace(Values("invalid", "HK10"));
            Assert(failures.Count == 2 && failures.Any(delegate(HotkeyFailure item) { return item.Invalid; }),
                "Invalid and non-transient failures should be reported immediately.");
            Assert(failures.Any(delegate(HotkeyFailure item) { return item.NativeError == 87 && item.Attempts == 1; }),
                "A non-transient native failure should retain its error.");
            Assert(scheduler.Current == null, "Non-transient failures must not schedule retries.");
        }
    }

    internal static int Main()
    {
        try
        {
            TransientConflictRecovers();
            PersistentConflictReportsNativeError();
            SuccessfulKeysStayRegisteredDuringRecovery();
            ReplacementCancelsOldRecovery();
            DisposalCancelsAndReleases();
            InvalidAndNonTransientFailuresDoNotRetry();
            Console.WriteLine("PASS: hotkey recovery is bounded, preserves successful registrations, and cancels stale work.");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }
}
