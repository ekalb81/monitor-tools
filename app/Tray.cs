using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

internal static class TrayProgram
{
    [STAThread]
    private static int Main()
    {
        bool created;
        using (Mutex singleInstance = new Mutex(true, "Local\\MonitorTools.Tray", out created))
        {
            if (!created) return 0;
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            using (TrayApplication tray = new TrayApplication()) Application.Run(tray);
        }
        return 0;
    }
}

internal sealed class TrayApplication : ApplicationContext
{
    private readonly string root = Directory.GetParent(AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar)).FullName;
    private readonly JavaScriptSerializer json = new JavaScriptSerializer();
    private readonly NotifyIcon icon = new NotifyIcon();
    private readonly HotkeyWindow hotkeys = new HotkeyWindow();
    private readonly Control dispatcher = new Control();
    private readonly System.Windows.Forms.Timer rescanTimer = new System.Windows.Forms.Timer();
    private readonly WorkerClient worker;
    private Dictionary<string, object> config = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
    private List<Dictionary<string, object>> inventory = new List<Dictionary<string, object>>();
    private string configPath;
    private string recent = "No operations yet.";
    private bool commandRunning;
    private string pendingProfile;
    private string pendingMonitorId;
    private bool scanRunning;
    private bool scanPending;
    private bool scanNotifyPending;
    private bool exiting;
    private bool settingsRunning;
    private bool diagnosticsRunning;

    internal TrayApplication()
    {
        dispatcher.CreateControl();
        worker = new WorkerClient(root);
        configPath = ResolveConfigPath();
        icon.Icon = SystemIcons.Application;
        icon.Text = "Monitor Tools";
        icon.Visible = true;
        icon.DoubleClick += delegate { ShowEditor(); };
        hotkeys.Pressed += delegate(string profile) { RunProfile(profile, null); };
        hotkeys.RegistrationFailed += HotkeyRegistrationFailed;
        rescanTimer.Interval = 1500;
        rescanTimer.Tick += delegate { rescanTimer.Stop(); RefreshInventory(false); };
        SystemEvents.DisplaySettingsChanged += DisplayChanged;
        SystemEvents.PowerModeChanged += PowerChanged;
        LoadConfig();
        BuildMenu();
        RefreshInventory(false);
    }

    private string ResolveConfigPath()
    {
        string pointer = Path.Combine(root, "config-path.txt");
        if (File.Exists(pointer))
        {
            string value = File.ReadAllText(pointer).Trim();
            if (!String.IsNullOrWhiteSpace(value))
                return Path.IsPathRooted(value) ? value : Path.GetFullPath(Path.Combine(root, value));
        }
        return Path.Combine(root, "monitor-profiles.json");
    }

    private void LoadConfig()
    {
        try
        {
            config = File.Exists(configPath)
                ? json.Deserialize<Dictionary<string, object>>(File.ReadAllText(configPath, Encoding.UTF8))
                : new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            if (config == null) config = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            RegisterHotkeys();
        }
        catch (Exception error)
        {
            recent = "Configuration error: " + error.Message;
            icon.ShowBalloonTip(5000, "Monitor Tools", recent, ToolTipIcon.Error);
        }
    }

    private static Dictionary<string, object> ObjectMap(object value)
    {
        return value as Dictionary<string, object>;
    }

    private Dictionary<string, object> Profiles()
    {
        Dictionary<string, object> profiles;
        object value;
        return config.TryGetValue("profiles", out value) && (profiles = ObjectMap(value)) != null
            ? profiles : new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
    }

    private Dictionary<string, object> ConfiguredMonitors()
    {
        Dictionary<string, object> monitors;
        object value;
        return config.TryGetValue("monitors", out value) && (monitors = ObjectMap(value)) != null
            ? monitors : new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
    }

    private Dictionary<string, string> HotkeyMap()
    {
        Dictionary<string, object> values = null;
        object direct;
        if (config.TryGetValue("hotkeys", out direct)) values = ObjectMap(direct);
        object settingsValue;
        Dictionary<string, object> settings;
        if (values == null && config.TryGetValue("settings", out settingsValue) && (settings = ObjectMap(settingsValue)) != null)
        {
            object nested;
            if (settings.TryGetValue("hotkeys", out nested)) values = ObjectMap(nested);
        }
        Dictionary<string, string> result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (values != null) foreach (KeyValuePair<string, object> pair in values) result[pair.Key] = Convert.ToString(pair.Value);
        return result;
    }

    private void RegisterHotkeys()
    {
        hotkeys.Replace(HotkeyMap());
    }

    private void HotkeyRegistrationFailed(List<HotkeyFailure> failures)
    {
        List<string> details = new List<string>();
        foreach (HotkeyFailure failure in failures)
        {
            if (failure.Invalid) details.Add(failure.Hotkey + " (invalid)");
            else
            {
                string attempts = failure.Attempts == 1 ? "1 attempt" : failure.Attempts + " attempts";
                details.Add(failure.Hotkey + " (Win32 " + failure.NativeError + ": " +
                    new Win32Exception(failure.NativeError).Message + "; " + attempts + ")");
            }
        }
        recent = "Hotkey unavailable: " + String.Join(", ", details.ToArray()) +
            ". Close the app holding the key and restart Monitor Tools, or edit the hotkey from the tray menu.";
        string keys = Truncate(String.Join(", ", failures.Select(failure => failure.Hotkey +
            (failure.Invalid ? " (invalid)" : " (error " + failure.NativeError + ")")).ToArray()), 90);
        string guidance = "Hotkeys unavailable: " + keys +
            ". Close the app using them, or open Profiles and hotkeys and save to retry.";
        icon.ShowBalloonTip(8000, "Monitor Tools hotkey conflict", guidance, ToolTipIcon.Warning);
        BuildMenu();
    }

    private string MonitorLabel(string stableId)
    {
        Dictionary<string, object> monitors = ConfiguredMonitors();
        object itemValue;
        Dictionary<string, object> item;
        object label;
        if (monitors.TryGetValue(stableId, out itemValue) && (item = ObjectMap(itemValue)) != null && item.TryGetValue("label", out label))
            return Convert.ToString(label);
        Dictionary<string, object> live = inventory.FirstOrDefault(delegate(Dictionary<string, object> candidate) {
            object id; return candidate.TryGetValue("StableId", out id) && String.Equals(Convert.ToString(id), stableId, StringComparison.OrdinalIgnoreCase);
        });
        if (live != null)
        {
            object position; object model;
            live.TryGetValue("Position", out position); live.TryGetValue("Model", out model);
            return Convert.ToString(position) + (model == null ? "" : " — " + Convert.ToString(model));
        }
        return stableId;
    }

    private void BuildMenu()
    {
        ContextMenuStrip menu = new ContextMenuStrip();
        ToolStripMenuItem heading = new ToolStripMenuItem("Monitor Tools") { Enabled = false };
        menu.Items.Add(heading);
        foreach (KeyValuePair<string, object> profile in Profiles().OrderBy(delegate(KeyValuePair<string, object> pair) { return pair.Key; }))
        {
            string name = profile.Key;
            ToolStripMenuItem item = new ToolStripMenuItem(ProfileDisplayName(name));
            item.Click += delegate { RunProfile(name, null); };
            item.Enabled = !settingsRunning;
            menu.Items.Add(item);
        }
        menu.Items.Add(new ToolStripSeparator());
        ToolStripMenuItem monitorsMenu = new ToolStripMenuItem("One monitor");
        Dictionary<string, object> monitors = ConfiguredMonitors();
        foreach (string stableId in monitors.Keys.OrderBy(delegate(string id) { return MonitorLabel(id); }))
        {
            ToolStripMenuItem monitorMenu = new ToolStripMenuItem(MonitorLabel(stableId));
            foreach (KeyValuePair<string, object> profile in Profiles())
            {
                Dictionary<string, object> assignments = ObjectMap(profile.Value);
                if (assignments == null || !assignments.ContainsKey(stableId)) continue;
                string capturedProfile = profile.Key;
                string capturedId = stableId;
                ToolStripMenuItem profileItem = new ToolStripMenuItem(ProfileDisplayName(capturedProfile));
                profileItem.Click += delegate { RunProfile(capturedProfile, capturedId); };
                profileItem.Enabled = !settingsRunning;
                monitorMenu.DropDownItems.Add(profileItem);
            }
            monitorsMenu.DropDownItems.Add(monitorMenu);
        }
        monitorsMenu.Enabled = monitorsMenu.DropDownItems.Count > 0 && !settingsRunning;
        menu.Items.Add(monitorsMenu);
        menu.Items.Add(new ToolStripSeparator());
        ToolStripMenuItem recentItem = new ToolStripMenuItem("Recent: " + Truncate(recent, 90)) { Enabled = false };
        menu.Items.Add(recentItem);
        ToolStripMenuItem refresh = new ToolStripMenuItem("Rescan displays");
        refresh.Click += delegate { RefreshInventory(true); };
        refresh.Enabled = true;
        menu.Items.Add(refresh);
        ToolStripMenuItem editor = new ToolStripMenuItem("Edit profiles and hotkeys...");
        editor.Click += delegate { ShowEditor(); };
        editor.Enabled = !commandRunning && !settingsRunning;
        menu.Items.Add(editor);
        ToolStripMenuItem diagnostics = new ToolStripMenuItem("Export diagnostics...");
        diagnostics.Click += delegate { ExportDiagnostics(); };
        diagnostics.Enabled = !diagnosticsRunning;
        menu.Items.Add(diagnostics);
        menu.Items.Add(new ToolStripSeparator());
        ToolStripMenuItem exit = new ToolStripMenuItem("Exit");
        exit.Click += delegate { ExitThread(); };
        menu.Items.Add(exit);
        ContextMenuStrip old = icon.ContextMenuStrip;
        icon.ContextMenuStrip = menu;
        if (old != null) old.Dispose();
    }

    private string ProfileDisplayName(string profile)
    {
        object computersValue;
        Dictionary<string, object> computers;
        object friendly;
        if (config.TryGetValue("computers", out computersValue) && (computers = ObjectMap(computersValue)) != null &&
            computers.TryGetValue(profile, out friendly) && !String.IsNullOrWhiteSpace(Convert.ToString(friendly))) return Convert.ToString(friendly);
        return profile;
    }

    private static string Truncate(string value, int length)
    {
        value = (value ?? "").Replace('\r', ' ').Replace('\n', ' ').Trim();
        return value.Length <= length ? value : value.Substring(0, length - 1) + "…";
    }

    private async void RunProfile(string profile, string monitorId)
    {
        if (exiting) return;
        if (settingsRunning)
        {
            pendingProfile = profile; pendingMonitorId = monitorId;
            recent = "Queued " + ProfileDisplayName(profile) + "; it will run after profiles are saved.";
            BuildMenu(); return;
        }
        if (commandRunning)
        {
            pendingProfile = profile; pendingMonitorId = monitorId;
            recent = "Queued " + ProfileDisplayName(profile) + "; it will run after the active operation.";
            BuildMenu(); return;
        }
        commandRunning = true;
        bool refreshAfter = false;
        recent = "Switching " + ProfileDisplayName(profile) + (monitorId == null ? "" : " on " + MonitorLabel(monitorId)) + "...";
        BuildMenu();
        try
        {
            Dictionary<string, object> request = new Dictionary<string, object>();
            request["action"] = "profile";
            request["profile"] = profile;
            if (monitorId != null) request["monitorId"] = monitorId;
            string output = await worker.InvokeAsync(request, 120000);
            if (exiting) return;
            refreshAfter = true;
            recent = "Completed " + ProfileDisplayName(profile) + ": " + Truncate(output, 180);
            icon.ShowBalloonTip(3500, "Monitor Tools", "Profile completed. Open the tray menu for details.", ToolTipIcon.Info);
        }
        catch (Exception error)
        {
            if (exiting) return;
            WorkerRequestException workerError = error as WorkerRequestException;
            refreshAfter = workerError != null;
            pendingProfile = null; pendingMonitorId = null;
            recent = "Failed: " + error.Message + (workerError != null && !String.IsNullOrWhiteSpace(workerError.Payload)
                ? " Results: " + Truncate(workerError.Payload, 180) : "");
            icon.ShowBalloonTip(6000, "Monitor Tools", Truncate(recent, 240), ToolTipIcon.Error);
        }
        finally
        {
            commandRunning = false;
            if (!exiting)
            {
                BuildMenu();
                if (pendingProfile != null)
                {
                    string nextProfile = pendingProfile, nextMonitor = pendingMonitorId;
                    pendingProfile = null; pendingMonitorId = null;
                    RunProfile(nextProfile, nextMonitor);
                }
                if (refreshAfter) QueueInventoryRefresh(false);
            }
        }
    }

    private async void RefreshInventory(bool notify)
    {
        if (exiting) return;
        if (scanRunning)
        {
            scanPending = true;
            scanNotifyPending = scanNotifyPending || notify;
            return;
        }
        scanRunning = true;
        try
        {
            Dictionary<string, object> request = new Dictionary<string, object>();
            request["action"] = "list";
            string output = await worker.InvokeAsync(request, 60000);
            if (exiting) return;
            inventory = DeserializeRows(output);
            if (notify)
            {
                recent = "Found " + inventory.Count + " DDC/CI monitor" + (inventory.Count == 1 ? "." : "s.");
                icon.ShowBalloonTip(2500, "Monitor Tools", recent, ToolTipIcon.Info);
            }
            BuildMenu();
        }
        catch (Exception error)
        {
            if (exiting) return;
            recent = "Rescan failed: " + error.Message;
            BuildMenu();
            if (notify) icon.ShowBalloonTip(5000, "Monitor Tools", Truncate(recent, 240), ToolTipIcon.Warning);
        }
        finally
        {
            scanRunning = false;
            if (!exiting && scanPending)
            {
                bool notifyNext = scanNotifyPending;
                scanPending = false; scanNotifyPending = false;
                RefreshInventory(notifyNext);
            }
        }
    }

    private void QueueInventoryRefresh(bool notify)
    {
        if (exiting) return;
        if (scanRunning)
        {
            scanPending = true;
            scanNotifyPending = scanNotifyPending || notify;
        }
        else RefreshInventory(notify);
    }

    private List<Dictionary<string, object>> DeserializeRows(string output)
    {
        string value = output.Trim();
        if (value.StartsWith("[")) return json.Deserialize<List<Dictionary<string, object>>>(value) ?? new List<Dictionary<string, object>>();
        Dictionary<string, object> one = json.Deserialize<Dictionary<string, object>>(value);
        return one == null ? new List<Dictionary<string, object>>() : new List<Dictionary<string, object>> { one };
    }

    private async void ShowEditor()
    {
        if (exiting || settingsRunning) return;
        using (ProfileEditor editor = new ProfileEditor(config, MonitorLabel, HotkeyMap()))
        {
            if (editor.ShowDialog() != DialogResult.OK) return;
            settingsRunning = true; BuildMenu();
            bool saved = false;
            try
            {
                Dictionary<string, object> request = new Dictionary<string, object>();
                request["action"] = "saveConfig";
                request["config"] = editor.Result;
                await worker.InvokeAsync(request, 30000);
                if (exiting) return;
                saved = true;
                LoadConfig();
                recent = "Profiles and hotkeys saved.";
                BuildMenu();
            }
            catch (Exception error) { if (!exiting) MessageBox.Show(error.Message, "Monitor Tools", MessageBoxButtons.OK, MessageBoxIcon.Error); }
            finally
            {
                settingsRunning = false;
                if (!exiting)
                {
                    BuildMenu();
                    if (!saved) { pendingProfile = null; pendingMonitorId = null; }
                    else if (pendingProfile != null)
                    {
                        string nextProfile = pendingProfile, nextMonitor = pendingMonitorId;
                        pendingProfile = null; pendingMonitorId = null;
                        RunProfile(nextProfile, nextMonitor);
                    }
                }
            }
        }
    }

    private async void ExportDiagnostics()
    {
        if (exiting || diagnosticsRunning) return;
        using (SaveFileDialog dialog = new SaveFileDialog())
        {
            dialog.Title = "Export Monitor Tools diagnostics";
            dialog.Filter = "JSON document (*.json)|*.json";
            dialog.FileName = "monitor-tools-diagnostics-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".json";
            if (dialog.ShowDialog() != DialogResult.OK) return;
            diagnosticsRunning = true; BuildMenu();
            try
            {
                bool includeCapabilities = MessageBox.Show("Include a slower DDC/CI capabilities query? Monitor capability reports can be inaccurate.", "Diagnostics detail", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
                Dictionary<string, object> request = new Dictionary<string, object>();
                request["action"] = "diagnostics";
                request["outputPath"] = dialog.FileName;
                request["includeCapabilities"] = includeCapabilities;
                await worker.InvokeAsync(request, 120000);
                if (exiting) return;
                recent = "Diagnostics saved to " + dialog.FileName;
                BuildMenu();
            }
            catch (Exception error) { if (!exiting) MessageBox.Show(error.Message, "Monitor Tools", MessageBoxButtons.OK, MessageBoxIcon.Error); }
            finally { diagnosticsRunning = false; if (!exiting) BuildMenu(); }
        }
    }

    private void DisplayChanged(object sender, EventArgs e) { ScheduleRescan(); }
    private void PowerChanged(object sender, PowerModeChangedEventArgs e) { if (e.Mode == PowerModes.Resume) ScheduleRescan(); }
    private void ScheduleRescan()
    {
        if (exiting || dispatcher.IsDisposed) return;
        if (dispatcher.InvokeRequired) { dispatcher.BeginInvoke(new Action(ScheduleRescan)); return; }
        rescanTimer.Stop(); rescanTimer.Start();
    }

    protected override void ExitThreadCore()
    {
        exiting = true;
        pendingProfile = null; pendingMonitorId = null; scanPending = false;
        SystemEvents.DisplaySettingsChanged -= DisplayChanged;
        SystemEvents.PowerModeChanged -= PowerChanged;
        rescanTimer.Dispose();
        worker.Dispose();
        hotkeys.Dispose();
        dispatcher.Dispose();
        icon.Visible = false;
        icon.Dispose();
        base.ExitThreadCore();
    }
}

internal sealed class HotkeyWindow : NativeWindow, IDisposable
{
    private const int WmHotkey = 0x0312;
    private const uint ModAlt = 0x0001;
    private const uint ModControl = 0x0002;
    private const uint ModShift = 0x0004;
    private const uint ModWin = 0x0008;
    private readonly HotkeyRegistrationManager registrationManager;
    internal event Action<string> Pressed;
    internal event Action<List<HotkeyFailure>> RegistrationFailed
    {
        add { registrationManager.RegistrationFailed += value; }
        remove { registrationManager.RegistrationFailed -= value; }
    }

    internal HotkeyWindow()
    {
        CreateHandle(new CreateParams());
        registrationManager = new HotkeyRegistrationManager(
            new NativeHotkeyRegistrationBackend(Handle), new WinFormsHotkeyRetryScheduler(), TryParse, 10, 1000);
    }

    internal void Replace(Dictionary<string, string> values)
    {
        registrationManager.Replace(values);
    }

    private static bool TryParse(string value, out uint modifiers, out uint key)
    {
        modifiers = 0; key = 0;
        bool hasBaseKey = false;
        string[] parts = value.ToUpperInvariant().Replace(" ", "").Split('+');
        foreach (string part in parts)
        {
            if (part == "CTRL" || part == "CONTROL") modifiers |= ModControl;
            else if (part == "ALT") modifiers |= ModAlt;
            else if (part == "SHIFT") modifiers |= ModShift;
            else if (part == "WIN" || part == "WINDOWS") modifiers |= ModWin;
            else
            {
                if (hasBaseKey) return false;
                if (part.Length == 1 && Char.IsDigit(part[0])) key = (uint)Keys.D0 + (uint)(part[0] - '0');
                else if (part.Length == 1 && part[0] >= 'A' && part[0] <= 'Z') key = (uint)Keys.A + (uint)(part[0] - 'A');
                else
                {
                    Keys parsed;
                    string[] named = { "ENTER", "ESCAPE", "SPACE", "TAB", "BACK", "DELETE", "INSERT", "HOME", "END", "PAGEUP", "PAGEDOWN", "UP", "DOWN", "LEFT", "RIGHT" };
                    bool functionKey = Regex.IsMatch(part, "^F(?:[1-9]|1[0-9]|2[0-4])$");
                    if ((!functionKey && !named.Contains(part)) || !Enum.TryParse<Keys>(part, true, out parsed)) return false;
                    key = (uint)parsed;
                }
                hasBaseKey = true;
            }
        }
        return hasBaseKey && key != 0 && modifiers != 0;
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == WmHotkey)
        {
            string profile;
            if (registrationManager.TryGetProfile(message.WParam.ToInt32(), out profile) && Pressed != null) Pressed(profile);
        }
        base.WndProc(ref message);
    }

    public void Dispose()
    {
        registrationManager.Dispose();
        DestroyHandle();
    }
}

internal sealed class HotkeyFailure
{
    internal readonly string Hotkey;
    internal readonly int NativeError;
    internal readonly int Attempts;
    internal readonly bool Invalid;

    internal HotkeyFailure(string hotkey, int nativeError, int attempts, bool invalid)
    {
        Hotkey = hotkey;
        NativeError = nativeError;
        Attempts = attempts;
        Invalid = invalid;
    }
}

internal delegate bool HotkeyParser(string value, out uint modifiers, out uint key);

internal interface IHotkeyRegistrationBackend
{
    bool Register(int id, uint modifiers, uint key, out int nativeError);
    void Unregister(int id);
}

internal interface IHotkeyRetryScheduler : IDisposable
{
    void Schedule(int delayMilliseconds, Action callback);
    void Cancel();
}

internal sealed class NativeHotkeyRegistrationBackend : IHotkeyRegistrationBackend
{
    private readonly IntPtr window;

    [DllImport("user32.dll", SetLastError = true)] private static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] private static extern bool UnregisterHotKey(IntPtr window, int id);

    internal NativeHotkeyRegistrationBackend(IntPtr windowHandle) { window = windowHandle; }

    public bool Register(int id, uint modifiers, uint key, out int nativeError)
    {
        bool registered = RegisterHotKey(window, id, modifiers, key);
        nativeError = registered ? 0 : Marshal.GetLastWin32Error();
        return registered;
    }

    public void Unregister(int id) { UnregisterHotKey(window, id); }
}

internal sealed class WinFormsHotkeyRetryScheduler : IHotkeyRetryScheduler
{
    private readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
    private Action callback;

    internal WinFormsHotkeyRetryScheduler()
    {
        timer.Tick += delegate
        {
            timer.Stop();
            Action pending = callback;
            callback = null;
            if (pending != null) pending();
        };
    }

    public void Schedule(int delayMilliseconds, Action scheduledCallback)
    {
        Cancel();
        callback = scheduledCallback;
        timer.Interval = delayMilliseconds;
        timer.Start();
    }

    public void Cancel()
    {
        timer.Stop();
        callback = null;
    }

    public void Dispose()
    {
        Cancel();
        timer.Dispose();
    }
}

internal sealed class HotkeyRegistrationManager : IDisposable
{
    private const uint ModNoRepeat = 0x4000;
    private const int ErrorHotkeyAlreadyRegistered = 1409;

    private sealed class PendingRegistration
    {
        internal int Id;
        internal string Profile;
        internal string Hotkey;
        internal uint Modifiers;
        internal uint Key;
        internal int Attempts;
        internal int LastError;
    }

    private readonly IHotkeyRegistrationBackend backend;
    private readonly IHotkeyRetryScheduler scheduler;
    private readonly HotkeyParser parser;
    private readonly int maxAttempts;
    private readonly int retryDelayMilliseconds;
    private readonly Dictionary<int, string> registrations = new Dictionary<int, string>();
    private readonly Dictionary<int, PendingRegistration> pending = new Dictionary<int, PendingRegistration>();
    private int generation;
    private bool disposed;

    internal event Action<List<HotkeyFailure>> RegistrationFailed;

    internal HotkeyRegistrationManager(IHotkeyRegistrationBackend registrationBackend,
        IHotkeyRetryScheduler retryScheduler, HotkeyParser hotkeyParser, int attempts, int retryDelay)
    {
        if (registrationBackend == null) throw new ArgumentNullException("registrationBackend");
        if (retryScheduler == null) throw new ArgumentNullException("retryScheduler");
        if (hotkeyParser == null) throw new ArgumentNullException("hotkeyParser");
        if (attempts < 1) throw new ArgumentOutOfRangeException("attempts");
        if (retryDelay < 1) throw new ArgumentOutOfRangeException("retryDelay");
        backend = registrationBackend;
        scheduler = retryScheduler;
        parser = hotkeyParser;
        maxAttempts = attempts;
        retryDelayMilliseconds = retryDelay;
    }

    internal void Replace(Dictionary<string, string> values)
    {
        if (disposed) throw new ObjectDisposedException("HotkeyRegistrationManager");
        if (values == null) throw new ArgumentNullException("values");
        generation++;
        scheduler.Cancel();
        foreach (int id in registrations.Keys.ToArray()) backend.Unregister(id);
        registrations.Clear();
        pending.Clear();

        List<HotkeyFailure> failures = new List<HotkeyFailure>();
        int next = 1;
        foreach (KeyValuePair<string, string> pair in values)
        {
            if (String.IsNullOrWhiteSpace(pair.Value)) continue;
            int id = next++;
            uint modifiers; uint key;
            if (!parser(pair.Value, out modifiers, out key))
            {
                failures.Add(new HotkeyFailure(pair.Value, 0, 0, true));
                continue;
            }
            PendingRegistration item = new PendingRegistration {
                Id = id, Profile = pair.Key, Hotkey = pair.Value,
                Modifiers = modifiers | ModNoRepeat, Key = key, Attempts = 1
            };
            int nativeError;
            if (backend.Register(item.Id, item.Modifiers, item.Key, out nativeError)) registrations[item.Id] = item.Profile;
            else
            {
                item.LastError = nativeError;
                if (nativeError == ErrorHotkeyAlreadyRegistered && item.Attempts < maxAttempts) pending[item.Id] = item;
                else failures.Add(ToFailure(item));
            }
        }
        NotifyFailures(failures);
        ScheduleRetry();
    }

    internal bool TryGetProfile(int id, out string profile) { return registrations.TryGetValue(id, out profile); }

    private void ScheduleRetry()
    {
        if (pending.Count == 0 || disposed) return;
        int scheduledGeneration = generation;
        scheduler.Schedule(retryDelayMilliseconds, delegate { Retry(scheduledGeneration); });
    }

    private void Retry(int scheduledGeneration)
    {
        if (disposed || scheduledGeneration != generation) return;
        List<HotkeyFailure> failures = new List<HotkeyFailure>();
        foreach (KeyValuePair<int, PendingRegistration> pair in pending.ToArray())
        {
            PendingRegistration item = pair.Value;
            item.Attempts++;
            int nativeError;
            if (backend.Register(item.Id, item.Modifiers, item.Key, out nativeError))
            {
                registrations[item.Id] = item.Profile;
                pending.Remove(item.Id);
            }
            else
            {
                item.LastError = nativeError;
                if (nativeError != ErrorHotkeyAlreadyRegistered || item.Attempts >= maxAttempts)
                {
                    pending.Remove(item.Id);
                    failures.Add(ToFailure(item));
                }
            }
        }
        NotifyFailures(failures);
        ScheduleRetry();
    }

    private static HotkeyFailure ToFailure(PendingRegistration item)
    {
        return new HotkeyFailure(item.Hotkey, item.LastError, item.Attempts, false);
    }

    private void NotifyFailures(List<HotkeyFailure> failures)
    {
        if (failures.Count > 0 && RegistrationFailed != null) RegistrationFailed(failures);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        generation++;
        scheduler.Cancel();
        foreach (int id in registrations.Keys.ToArray()) backend.Unregister(id);
        registrations.Clear();
        pending.Clear();
        scheduler.Dispose();
    }
}

internal sealed class ProfileEditor : Form
{
    private readonly JavaScriptSerializer json = new JavaScriptSerializer();
    private readonly DataGridView grid = new DataGridView();
    private readonly Dictionary<string, object> original;
    private readonly Func<string, string> monitorLabel;
    private readonly Dictionary<string, string> labelToId = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
    internal Dictionary<string, object> Result { get; private set; }

    internal ProfileEditor(Dictionary<string, object> source, Func<string, string> labeler, Dictionary<string, string> hotkeys)
    {
        original = json.Deserialize<Dictionary<string, object>>(json.Serialize(source));
        monitorLabel = labeler;
        Text = "Profiles and hotkeys";
        ClientSize = new Size(900, 450);
        MinimumSize = new Size(760, 380);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9);
        Controls.Add(new Label { Text = "One row per monitor assignment. Leave Input, Brightness, and Volume empty to keep that monitor unchanged.", Dock = DockStyle.Top, Height = 50, Padding = new Padding(8, 10, 4, 4) });
        grid.Dock = DockStyle.Fill;
        grid.AllowUserToAddRows = true;
        grid.AllowUserToDeleteRows = true;
        grid.AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill;
        grid.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.AutoSize;
        grid.Columns.Add("Profile", "Profile name");
        DataGridViewComboBoxColumn monitorColumn = new DataGridViewComboBoxColumn { Name = "Monitor", HeaderText = "Monitor", FlatStyle = FlatStyle.Flat };
        DataGridViewComboBoxColumn inputColumn = new DataGridViewComboBoxColumn { Name = "Input", HeaderText = "Input (optional)", FlatStyle = FlatStyle.Flat };
        inputColumn.Items.AddRange("", "displayport1", "displayport2", "hdmi1", "hdmi2", "0x05", "dvi1", "dvi2", "vga1");
        grid.Columns.Add(monitorColumn); grid.Columns.Add(inputColumn);
        grid.Columns.Add("Brightness", "Brightness 0-100"); grid.Columns.Add("Volume", "Volume 0-100"); grid.Columns.Add("Hotkey", "Hotkey (profile)");
        grid.Columns[0].FillWeight = 20; grid.Columns[1].FillWeight = 24; grid.Columns[2].FillWeight = 18;
        grid.Columns[3].FillWeight = 13; grid.Columns[4].FillWeight = 13; grid.Columns[5].FillWeight = 18;
        Controls.Add(grid);
        FlowLayoutPanel buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 48, FlowDirection = FlowDirection.RightToLeft, Padding = new Padding(8) };
        Button save = new Button { Text = "Save", DialogResult = DialogResult.None, Width = 95 };
        Button cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Width = 95 };
        save.Click += SaveClicked;
        buttons.Controls.Add(save); buttons.Controls.Add(cancel);
        Controls.Add(buttons);
        // Fill must be laid out after the top instructions and bottom actions.
        grid.BringToFront();
        CancelButton = cancel;

        Dictionary<string, object> profiles = MapValue(original, "profiles");
        Dictionary<string, object> monitors = MapValue(original, "monitors");
        HashSet<string> allMonitorIds = new HashSet<string>(monitors.Keys, StringComparer.OrdinalIgnoreCase);
        foreach (object profileValue in profiles.Values)
        {
            Dictionary<string, object> assignments = profileValue as Dictionary<string, object>;
            if (assignments != null) foreach (string id in assignments.Keys) allMonitorIds.Add(id);
        }
        Dictionary<string, string> idToLabel = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        Dictionary<string, int> labelCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        foreach (string id in allMonitorIds)
        {
            string baseLabel = monitorLabel(id);
            labelCounts[baseLabel] = labelCounts.ContainsKey(baseLabel) ? labelCounts[baseLabel] + 1 : 1;
        }
        monitorColumn.Items.Add("");
        foreach (string id in allMonitorIds)
        {
            string baseLabel = monitorLabel(id);
            string label = labelCounts[baseLabel] > 1 ? baseLabel + " [" + id + "]" : baseLabel;
            idToLabel[id] = label; labelToId[label] = id; labelToId[id] = id; monitorColumn.Items.Add(label);
        }
        foreach (KeyValuePair<string, object> profile in profiles)
        {
            Dictionary<string, object> assignments = profile.Value as Dictionary<string, object>;
            string hotkey; hotkeys.TryGetValue(profile.Key, out hotkey);
            IEnumerable<string> rowIds = assignments != null && assignments.Count > 0 ? assignments.Keys :
                (allMonitorIds.Count > 0 ? allMonitorIds.Take(1) : new[] { "" });
            bool first = true;
            foreach (string id in rowIds)
            {
                object assignment = assignments != null && assignments.ContainsKey(id) ? assignments[id] : null;
                Dictionary<string, object> scene = assignment as Dictionary<string, object>;
                string input = scene == null ? Convert.ToString(assignment) : SceneValue(scene, "input");
                DataGridViewComboBoxColumn inputChoices = (DataGridViewComboBoxColumn)grid.Columns[2];
                if (!String.IsNullOrWhiteSpace(input) && !inputChoices.Items.Contains(input)) inputChoices.Items.Add(input);
                grid.Rows.Add(profile.Key, idToLabel.ContainsKey(id) ? idToLabel[id] : id, input,
                    scene == null ? "" : SceneValue(scene, "brightness"), scene == null ? "" : SceneValue(scene, "volume"), first ? hotkey ?? "" : "");
                first = false;
            }
        }
    }

    private static Dictionary<string, object> MapValue(Dictionary<string, object> parent, string key)
    {
        object value;
        Dictionary<string, object> map;
        return parent.TryGetValue(key, out value) && (map = value as Dictionary<string, object>) != null
            ? map : new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
    }

    private static string SceneValue(Dictionary<string, object> scene, string key)
    {
        object value; return scene != null && scene.TryGetValue(key, out value) ? Convert.ToString(value) : "";
    }

    private void SaveClicked(object sender, EventArgs e)
    {
        try
        {
            Dictionary<string, object> profiles = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, object> hotkeyValues = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            foreach (DataGridViewRow row in grid.Rows)
            {
                if (row.IsNewRow) continue;
                string name = Convert.ToString(row.Cells[0].Value).Trim();
                if (name.Length == 0) continue;
                if (!Regex.IsMatch(name, "^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$")) throw new InvalidOperationException("Profile names use 1-64 letters, digits, hyphens, or underscores.");
                Dictionary<string, object> assignments;
                if (!profiles.ContainsKey(name)) { assignments = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase); profiles[name] = assignments; }
                else assignments = (Dictionary<string, object>)profiles[name];
                string monitor = Convert.ToString(row.Cells[1].Value).Trim(), input = Convert.ToString(row.Cells[2].Value).Trim();
                string brightness = Convert.ToString(row.Cells[3].Value).Trim(), volume = Convert.ToString(row.Cells[4].Value).Trim();
                string hotkey = Convert.ToString(row.Cells[5].Value).Trim();
                if (hotkey.Length > 0)
                {
                    if (hotkeyValues.ContainsKey(name) && !String.Equals(Convert.ToString(hotkeyValues[name]), hotkey, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Use one hotkey per profile.");
                    hotkeyValues[name] = hotkey;
                }
                if (monitor.Length == 0 || (input.Length == 0 && brightness.Length == 0 && volume.Length == 0)) continue;
                string stableId;
                if (!labelToId.TryGetValue(monitor, out stableId))
                    throw new InvalidOperationException("Unknown monitor '" + monitor + "'.");
                if (assignments.ContainsKey(stableId)) throw new InvalidOperationException("Each profile may assign a monitor only once.");
                int percentage;
                if (brightness.Length > 0 && (!Int32.TryParse(brightness, out percentage) || percentage < 0 || percentage > 100)) throw new InvalidOperationException("Brightness must be 0-100.");
                if (volume.Length > 0 && (!Int32.TryParse(volume, out percentage) || percentage < 0 || percentage > 100)) throw new InvalidOperationException("Volume must be 0-100.");
                if (brightness.Length == 0 && volume.Length == 0) assignments[stableId] = input;
                else
                {
                    Dictionary<string, object> scene = new Dictionary<string, object>();
                    if (input.Length > 0) scene["input"] = input;
                    if (brightness.Length > 0) scene["brightness"] = Int32.Parse(brightness);
                    if (volume.Length > 0) scene["volume"] = Int32.Parse(volume);
                    assignments[stableId] = scene;
                }
            }
            if (profiles.Count == 0) throw new InvalidOperationException("Add at least one profile.");
            original["profiles"] = profiles;
            Dictionary<string, object> settings = MapValue(original, "settings");
            settings["hotkeys"] = hotkeyValues;
            original["settings"] = settings;
            original["hotkeys"] = hotkeyValues;
            InvalidateCalibrations(profiles);
            Result = original;
            DialogResult = DialogResult.OK;
            Close();
        }
        catch (Exception error) { MessageBox.Show(this, error.Message, "Profiles", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
    }

    private static string ProfileInput(Dictionary<string, object> profiles, string profileName, string monitorId)
    {
        object profileValue, assignment;
        Dictionary<string, object> profile;
        if (!profiles.TryGetValue(profileName, out profileValue) || (profile = profileValue as Dictionary<string, object>) == null || !profile.TryGetValue(monitorId, out assignment)) return null;
        Dictionary<string, object> scene = assignment as Dictionary<string, object>;
        return scene == null ? Convert.ToString(assignment) : SceneValue(scene, "input");
    }

    private void InvalidateCalibrations(Dictionary<string, object> profiles)
    {
        Dictionary<string, object> monitors = MapValue(original, "monitors");
        foreach (KeyValuePair<string, object> monitorPair in monitors)
        {
            Dictionary<string, object> monitor = monitorPair.Value as Dictionary<string, object>;
            if (monitor == null) continue;
            object calibrationValue;
            Dictionary<string, object> calibration;
            if (!monitor.TryGetValue("calibration", out calibrationValue) || (calibration = calibrationValue as Dictionary<string, object>) == null) continue;
            string thisInput = ProfileInput(profiles, "this-pc", monitorPair.Key);
            string otherInput = ProfileInput(profiles, "other-pc", monitorPair.Key);
            if (!String.Equals(SceneValue(calibration, "thisInput"), thisInput, StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(SceneValue(calibration, "otherInput"), otherInput, StringComparison.OrdinalIgnoreCase))
            {
                calibration["status"] = "untested"; calibration["verifiedAt"] = null;
                calibration["thisInput"] = thisInput; calibration["otherInput"] = otherInput;
            }
        }
        Dictionary<string, object> full = MapValue(original, "profileCalibration");
        full["status"] = "untested"; full["verifiedAt"] = null; original["profileCalibration"] = full;
    }
}
