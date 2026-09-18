using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 0 && TryHandoffInstalledUi()) return 0;
        string staging = Path.Combine(Path.GetTempPath(), "monitor-tools-setup-" + Guid.NewGuid().ToString("N"));
        bool verify = args.Length == 1 && args[0] == "--verify-package";
        bool repair = (args.Length == 1 && args[0] == "--repair") || (args.Length == 2 && args[0] == "--repair-target");
        bool uiWorker = args.Length == 2 && args[0] == "--ui-target";
        try
        {
            Directory.CreateDirectory(staging);
            using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("MonitorTools.Payload.zip"))
            {
                if (payload == null) throw new InvalidDataException("Setup payload is missing.");
                using (ZipArchive archive = new ZipArchive(payload, ZipArchiveMode.Read))
                {
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        string target = Path.GetFullPath(Path.Combine(staging, entry.FullName));
                        if (!target.StartsWith(staging + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                            throw new InvalidDataException("Invalid file path in setup package.");
                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        entry.ExtractToFile(target);
                    }
                }
            }
            foreach (string required in new[] { "Install.ps1", "Run-Profile.ps1", "Switch-MonitorInput.ps1", "Detect-Monitors.ps1", "README.md",
                "MonitorTools.Common.ps1", "Export-Diagnostics.ps1", "Repair.ps1", "Uninstall.ps1", "VERSION", "monitor-compatibility.json",
                Path.Combine("app", "MonitorTools.exe"), Path.Combine("app", "MonitorTools.Worker.exe"), Path.Combine("app", "Invoke-TrayCommand.ps1") })
                if (!File.Exists(Path.Combine(staging, required))) throw new InvalidDataException("Missing " + required);
            if (verify) return 0;
            File.Copy(Assembly.GetExecutingAssembly().Location, Path.Combine(staging, "Setup.exe"), true);
            if (repair) return SetupWindow.Repair(staging, args.Length == 2 ? args[1] : Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location));

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            bool renderPreview = args.Length == 2 && args[0] == "--render-preview";
            using (SetupWindow window = new SetupWindow(staging, renderPreview, uiWorker ? args[1] : null))
            {
                if (renderPreview)
                {
                    window.PreparePreview(); window.ShowInTaskbar = false; window.Opacity = 0; window.Show(); Application.DoEvents();
                    using (Bitmap bitmap = new Bitmap(window.Width, window.Height))
                    {
                        window.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size)); bitmap.Save(args[1]);
                    }
                    return 0;
                }
                Application.Run(window);
            }
            return 0;
        }
        catch (Exception error)
        {
            if (!verify) MessageBox.Show(error.Message, "Monitor Tools Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            string tempRoot = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            if (Path.GetFullPath(staging).StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase) && Regex.IsMatch(Path.GetFileName(staging), "^monitor-tools-setup-[0-9a-f]{32}$"))
            {
                try { Directory.Delete(staging, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }
    }

    private static bool TryHandoffInstalledUi()
    {
        string executable = Assembly.GetExecutingAssembly().Location;
        string installDirectory = Path.GetDirectoryName(executable);
        string manifestPath = Path.Combine(installDirectory, "install-manifest.json");
        if (!File.Exists(manifestPath)) return false;
        try
        {
            Dictionary<string, object> manifest = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(manifestPath));
            object product;
            if (manifest == null || !manifest.TryGetValue("product", out product) || !String.Equals(Convert.ToString(product), "Monitor Tools", StringComparison.Ordinal)) return false;
            string tempRoot = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
            foreach (string stale in Directory.GetDirectories(tempRoot, "monitor-tools-ui-worker-*"))
            {
                string resolved = Path.GetFullPath(stale);
                if (resolved.StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase) && Regex.IsMatch(Path.GetFileName(resolved), "^monitor-tools-ui-worker-[0-9a-f]{32}$"))
                    try { Directory.Delete(resolved, true); } catch { }
            }
            string workerDirectory = Path.Combine(tempRoot, "monitor-tools-ui-worker-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(workerDirectory);
            string worker = Path.Combine(workerDirectory, "Setup.exe");
            File.Copy(executable, worker, false);
            Process.Start(new ProcessStartInfo(worker, "--ui-target " + SetupWindow.Quote(installDirectory)) { UseShellExecute = false, WorkingDirectory = workerDirectory });
            return true;
        }
        catch (Exception error)
        {
            MessageBox.Show("Setup could not start its update worker. " + error.Message, "Monitor Tools Setup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return true;
        }
    }
}

internal sealed class MonitorRow
{
    internal string Position;
    internal string StableId;
    internal string IdentityStatus;
    internal string Model;
    internal string Serial;
    internal string DevicePath;
    internal Dictionary<string, string> CandidateInputs;
    internal int Left, Top, Right, Bottom;
    internal ComboBox ThisInput, OtherInput;
    internal TextBox LabelBox;
    internal Label CalibrationLabel;
    internal Button TestButton;
    internal string CalibrationStatus = "untested";
    internal string VerifiedAt;
    internal bool Bound, Loading;
}

internal sealed class SetupWindow : Form
{
    private readonly string staging;
    private readonly string destination;
    private readonly JavaScriptSerializer json = new JavaScriptSerializer();
    private readonly List<MonitorRow> rows = new List<MonitorRow>();
    private readonly TableLayoutPanel table = new TableLayoutPanel();
    private readonly Label status = new Label();
    private readonly CheckBox hotkeys = new CheckBox();
    private readonly CheckBox startAtLogin = new CheckBox();
    private readonly TextBox thisName = new TextBox();
    private readonly TextBox otherName = new TextBox();
    private readonly Button install = new Button();
    private readonly Button refresh = new Button();
    private readonly Button testAll = new Button();
    private readonly Button openFolder = new Button();
    private Dictionary<string, object> existing;
    private string existingConfigPath;
    private string profileCalibrationStatus = "untested";
    private string profileCalibrationVerifiedAt;
    private bool busy, finished;
    private readonly bool preview;
    private static readonly string[] InputLabels = { "DisplayPort 1", "HDMI 1", "HDMI 2", "DisplayPort 2", "DVI 1", "DVI 2", "VGA 1" };
    private static readonly string[] InputValues = { "displayport1", "hdmi1", "hdmi2", "displayport2", "dvi1", "dvi2", "vga1" };

    protected override bool ShowWithoutActivation { get { return preview; } }

    internal SetupWindow(string stagingDirectory, bool renderPreview = false) : this(stagingDirectory, renderPreview, null) { }

    internal SetupWindow(string stagingDirectory, bool renderPreview, string installDirectory)
    {
        staging = stagingDirectory; preview = renderPreview;
        destination = String.IsNullOrWhiteSpace(installDirectory)
            ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Monitor Tools", "app")
            : ValidateInstallTarget(installDirectory);
        Text = "Monitor Tools Setup"; ClientSize = new Size(980, 720); MinimumSize = new Size(900, 680);
        StartPosition = FormStartPosition.CenterScreen; Font = new Font("Segoe UI", 9.5f); BackColor = Color.White; AutoScaleMode = AutoScaleMode.Font;
        Controls.Add(new Label { Text = "Set up Monitor Tools", Location = new Point(24, 16), Size = new Size(900, 40), Font = new Font("Segoe UI", 20, FontStyle.Bold) });
        Controls.Add(new Label { Text = "Name both computers, choose each monitor input, then verify the return path one monitor at a time.", Location = new Point(26, 60), Size = new Size(920, 24) });
        Controls.Add(new Label { Text = "This computer", Location = new Point(26, 93), Size = new Size(110, 24) });
        thisName.SetBounds(138, 90, 230, 28); thisName.Text = Environment.MachineName; Controls.Add(thisName);
        Controls.Add(new Label { Text = "Other computer", Location = new Point(395, 93), Size = new Size(115, 24) });
        otherName.SetBounds(510, 90, 230, 28); otherName.Text = "Other PC"; Controls.Add(otherName);

        Panel monitorPanel = new Panel { Location = new Point(24, 130), Size = new Size(932, 355), AutoScroll = true, BorderStyle = BorderStyle.FixedSingle, Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right };
        table.Dock = DockStyle.Top; table.AutoSize = true; table.ColumnCount = 5;
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 29)); table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 22)); table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 22));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 13)); table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 14));
        monitorPanel.Controls.Add(table); Controls.Add(monitorPanel); ResetTable();

        hotkeys.Text = "Enable tray hotkeys (defaults: Ctrl+Alt+1 / Ctrl+Alt+2)"; hotkeys.Checked = true; hotkeys.SetBounds(26, 503, 440, 28); hotkeys.Anchor = AnchorStyles.Bottom | AnchorStyles.Left; Controls.Add(hotkeys);
        startAtLogin.Text = "Start Monitor Tools when I sign in"; startAtLogin.Checked = true; startAtLogin.SetBounds(490, 503, 360, 28); startAtLogin.Anchor = AnchorStyles.Bottom | AnchorStyles.Left; Controls.Add(startAtLogin);
        Controls.Add(new Label { Text = "Testing temporarily changes one screen and attempts to return it after five seconds. Keep the monitor controls available.", Location = new Point(26, 535), Size = new Size(920, 24), Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right });
        status.SetBounds(26, 565, 920, 72); status.Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right; status.Text = "Detecting monitors..."; Controls.Add(status);

        refresh.Text = "Refresh monitors"; refresh.SetBounds(24, 666, 145, 34); refresh.Anchor = AnchorStyles.Bottom | AnchorStyles.Left; refresh.Click += async delegate { await Detect(); }; Controls.Add(refresh);
        testAll.Text = "Test all together"; testAll.SetBounds(178, 666, 155, 34); testAll.Anchor = AnchorStyles.Bottom | AnchorStyles.Left; testAll.Click += async delegate { await TestFullProfile(); }; Controls.Add(testAll);
        openFolder.Text = "Open installed folder"; openFolder.SetBounds(342, 666, 175, 34); openFolder.Anchor = AnchorStyles.Bottom | AnchorStyles.Left; openFolder.Visible = false;
        openFolder.Click += delegate { Process.Start(new ProcessStartInfo(destination) { UseShellExecute = true }); }; Controls.Add(openFolder);
        install.Text = "Install"; install.SetBounds(796, 666, 160, 34); install.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
        install.Click += async delegate { if (finished) Close(); else await Install(); }; Controls.Add(install);
        Shown += async delegate { if (!preview) await Detect(); };
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy) e.Cancel = true; };
    }

    internal static int Repair(string staging, string installDirectory)
    {
        installDirectory = ValidateInstallTarget(installDirectory);
        string pointer = Path.Combine(installDirectory, "config-path.txt");
        if (!File.Exists(pointer)) throw new InvalidOperationException("Repair target is missing config-path.txt.");
        string config = File.ReadAllText(pointer).Trim();
        if (!Path.IsPathRooted(config)) throw new InvalidOperationException("Repair configuration path must be absolute.");
        config = Path.GetFullPath(config);
        if (!File.Exists(config)) throw new InvalidOperationException("Repair could not find the installed configuration.");
        RunPowerShell(staging, "Install.ps1", "-Unattended -ConfigurationFile " + Quote(config) + " -InstallDirectory " + Quote(installDirectory) + " -PreserveRegistration", 180000);
        return 0;
    }

    private static string ValidateInstallTarget(string installDirectory)
    {
        if (!Path.IsPathRooted(installDirectory)) throw new InvalidOperationException("The installed setup target must be an absolute path.");
        installDirectory = Path.GetFullPath(installDirectory).TrimEnd(Path.DirectorySeparatorChar);
        string manifestPath = Path.Combine(installDirectory, "install-manifest.json");
        if (!File.Exists(manifestPath)) throw new InvalidOperationException("Setup target is not a recognized Monitor Tools installation.");
        Dictionary<string, object> manifest = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(File.ReadAllText(manifestPath));
        object product;
        if (manifest == null || !manifest.TryGetValue("product", out product) || !String.Equals(Convert.ToString(product), "Monitor Tools", StringComparison.Ordinal))
            throw new InvalidOperationException("Setup target has an invalid Monitor Tools manifest.");
        return installDirectory;
    }

    private void ResetTable()
    {
        foreach (Control control in table.Controls.Cast<Control>().ToArray()) control.Dispose();
        table.Controls.Clear(); table.RowStyles.Clear(); rows.Clear(); table.RowCount = 1; table.RowStyles.Add(new RowStyle(SizeType.Absolute, 36));
        string[] titles = { "Monitor", "This computer", "Other computer", "Return test", "Status" };
        for (int i = 0; i < titles.Length; i++) table.Controls.Add(new Label { Text = titles[i], Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Margin = new Padding(9, 0, 5, 0), Font = new Font(Font, FontStyle.Bold) }, i, 0);
    }

    private void SetBusy(bool value)
    {
        busy = value; install.Enabled = !value && rows.Count > 0; refresh.Enabled = !value; testAll.Enabled = !value && rows.Count > 0 && rows.All(delegate(MonitorRow row) { return row.CalibrationStatus == "verified"; });
        hotkeys.Enabled = !value; startAtLogin.Enabled = !value; thisName.Enabled = !value; otherName.Enabled = !value; table.Enabled = !value; UseWaitCursor = value;
    }

    internal static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }
    private static string RunPowerShell(string workingDirectory, string name, string arguments, int timeout)
    {
        string executable = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        ProcessStartInfo start = new ProcessStartInfo(executable, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(Path.Combine(workingDirectory, name)) + " " + arguments);
        start.UseShellExecute = false; start.CreateNoWindow = true; start.RedirectStandardOutput = true; start.RedirectStandardError = true; start.StandardOutputEncoding = Encoding.UTF8; start.WorkingDirectory = workingDirectory;
        using (Process process = Process.Start(start))
        {
            Task<string> output = process.StandardOutput.ReadToEndAsync(); Task<string> errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(timeout)) { process.Kill(); throw new TimeoutException("The operation timed out. If a return test was running, use the monitor controls to confirm the input."); }
            Task.WaitAll(output, errors);
            if (process.ExitCode != 0) throw new InvalidOperationException((errors.Result + "\n" + output.Result).Trim());
            return output.Result;
        }
    }
    private string RunScript(string name, string arguments) { return RunPowerShell(staging, name, arguments, 180000); }

    private string ResolveExistingConfig()
    {
        string pointer = Path.Combine(destination, "config-path.txt");
        if (File.Exists(pointer)) { string value = File.ReadAllText(pointer).Trim(); if (value.Length > 0) return Path.IsPathRooted(value) ? value : Path.GetFullPath(Path.Combine(destination, value)); }
        string legacy = Path.Combine(destination, "monitor-profiles.json");
        if (File.Exists(legacy)) return legacy;
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Monitor Tools", "data", "monitor-profiles.json");
    }

    private async Task Detect()
    {
        SetBusy(true); status.Text = "Detecting monitors. This may take a moment...";
        try
        {
            string result = await Task.Run(delegate { return RunScript("Detect-Monitors.ps1", ""); });
            List<Dictionary<string, object>> monitors = json.Deserialize<List<Dictionary<string, object>>>(result);
            existingConfigPath = ResolveExistingConfig(); existing = null; bool invalidExisting = false;
            if (File.Exists(existingConfigPath))
            {
                try
                {
                    existing = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(existingConfigPath));
                    object schema; if (existing != null && existing.TryGetValue("schemaVersion", out schema) && Convert.ToInt32(schema) > 2) throw new InvalidDataException("This configuration was created by a newer Monitor Tools version.");
                }
                catch (InvalidDataException) { throw; }
                catch { invalidExisting = true; existing = null; }
            }
            profileCalibrationStatus = "untested"; profileCalibrationVerifiedAt = null;
            if (existing != null)
            {
                object fullValue; Dictionary<string, object> full;
                if (existing.TryGetValue("profileCalibration", out fullValue) && (full = Map(fullValue)) != null)
                { profileCalibrationStatus = GetString(full, "status"); profileCalibrationVerifiedAt = GetString(full, "verifiedAt"); }
            }
            LoadComputerNames(); ResetTable(); foreach (Dictionary<string, object> monitor in monitors) AddRow(monitor, existing);
            if (rows.Any(delegate(MonitorRow row) { return row.CalibrationStatus != "verified"; })) { profileCalibrationStatus = "untested"; profileCalibrationVerifiedAt = null; }
            status.Text = invalidExisting ? "Saved profiles could not be read. Choose inputs again; the old file will be backed up." : "Use Identify to match each physical display. A verified result belongs to this monitor and these two input choices.";
        }
        catch (Exception error)
        {
            ResetTable(); status.Text = "Could not detect monitors. Check connections and DDC/CI settings, then refresh.";
            MessageBox.Show(this, error.Message, "Monitor detection", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally { SetBusy(false); }
    }

    private static Dictionary<string, object> Map(object value) { return value as Dictionary<string, object>; }
    private void LoadComputerNames()
    {
        if (existing == null) return;
        object value, name; Dictionary<string, object> computers;
        if (existing.TryGetValue("computers", out value) && (computers = Map(value)) != null)
        {
            if (computers.TryGetValue("this-pc", out name)) thisName.Text = Convert.ToString(name);
            if (computers.TryGetValue("other-pc", out name)) otherName.Text = Convert.ToString(name);
        }
        Dictionary<string, object> existingHotkeys;
        hotkeys.Checked = existing.TryGetValue("hotkeys", out value) && (existingHotkeys = Map(value)) != null && existingHotkeys.Count > 0;
        Dictionary<string, object> settings;
        if (existing.TryGetValue("settings", out value) && (settings = Map(value)) != null && settings.TryGetValue("startAtLogin", out name)) startAtLogin.Checked = Convert.ToBoolean(name);
    }
    private ComboBox InputBox(string saved, Dictionary<string, string> candidates)
    {
        ComboBox box = new ComboBox { Dock = DockStyle.Top, Margin = new Padding(7, 15, 7, 8), DropDownStyle = ComboBoxStyle.DropDown };
        box.Items.AddRange(InputLabels);
        foreach (KeyValuePair<string, string> candidate in candidates) box.Items.Add("Candidate: " + candidate.Key + " [" + candidate.Value + "]");
        int index = Array.IndexOf(InputValues, saved);
        KeyValuePair<string, string> matching = candidates.FirstOrDefault(delegate(KeyValuePair<string, string> pair) { return String.Equals(pair.Value, saved, StringComparison.OrdinalIgnoreCase); });
        box.Text = index >= 0 ? InputLabels[index] : !String.IsNullOrWhiteSpace(matching.Key) ? "Candidate: " + matching.Key + " [" + matching.Value + "]" : saved ?? "";
        return box;
    }

    private static Dictionary<string, string> CandidateInputs(Dictionary<string, object> monitor)
    {
        Dictionary<string, string> result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        object value; Dictionary<string, object> candidates;
        if (monitor.TryGetValue("CandidateInputs", out value) && (candidates = Map(value)) != null)
            foreach (KeyValuePair<string, object> pair in candidates) result[pair.Key] = Convert.ToString(pair.Value);
        return result;
    }
    private string ExistingInput(Dictionary<string, object> config, string profile, string stableId, string position)
    {
        if (config == null) return null;
        object versionValue; int version = config.TryGetValue("schemaVersion", out versionValue) ? Convert.ToInt32(versionValue) : 1;
        object profilesValue, profileValue, input; Dictionary<string, object> profiles, inputs;
        if (!config.TryGetValue("profiles", out profilesValue) || (profiles = Map(profilesValue)) == null || !profiles.TryGetValue(profile, out profileValue) || (inputs = Map(profileValue)) == null) return null;
        if (inputs.TryGetValue(stableId, out input)) return InputFromScene(input);
        if (version < 2 && inputs.TryGetValue(position, out input)) return InputFromScene(input);
        return null;
    }
    private static string InputFromScene(object value)
    {
        Dictionary<string, object> scene = Map(value); object input; return scene != null && scene.TryGetValue("input", out input) ? Convert.ToString(input) : Convert.ToString(value);
    }
    private Dictionary<string, object> ExistingMonitor(Dictionary<string, object> config, string stableId)
    {
        if (config == null) return null;
        object monitorsValue, monitorValue; Dictionary<string, object> monitors;
        return config.TryGetValue("monitors", out monitorsValue) && (monitors = Map(monitorsValue)) != null && monitors.TryGetValue(stableId, out monitorValue) ? Map(monitorValue) : null;
    }

    private void AddRow(Dictionary<string, object> monitor, Dictionary<string, object> saved)
    {
        string position = GetString(monitor, "Position"), stableId = GetString(monitor, "StableId"), identity = GetString(monitor, "IdentityStatus"), model = GetString(monitor, "Model");
        if (String.IsNullOrWhiteSpace(model)) model = GetString(monitor, "Description");
        Dictionary<string, object> savedMonitor = ExistingMonitor(saved, stableId); string label = savedMonitor == null ? position : GetString(savedMonitor, "label"); if (String.IsNullOrWhiteSpace(label)) label = position;
        int number = table.RowCount++; table.RowStyles.Add(new RowStyle(SizeType.Absolute, 82));
        Dictionary<string, string> candidates = CandidateInputs(monitor);
        Panel monitorPanel = new Panel { Dock = DockStyle.Fill, Margin = new Padding(8, 7, 4, 3) };
        TextBox labelBox = new TextBox { Text = label, Dock = DockStyle.Top, BorderStyle = BorderStyle.FixedSingle };
        Label monitorLabel = new Label { Text = model + (candidates.Count > 0 ? " • candidate mappings" : ""), Dock = DockStyle.Fill, AutoEllipsis = true, ForeColor = candidates.Count > 0 ? Color.DarkBlue : Color.Black };
        Button identify = new Button { Text = identity == "ambiguous" ? "Identity help" : "Identify", Dock = DockStyle.Bottom, Height = 25 };
        monitorPanel.Controls.Add(monitorLabel); monitorPanel.Controls.Add(labelBox); monitorPanel.Controls.Add(identify); table.Controls.Add(monitorPanel, 0, number);

        MonitorRow row = new MonitorRow { Position = position, StableId = stableId, IdentityStatus = identity, Model = model, Serial = GetString(monitor, "Serial"), DevicePath = GetString(monitor, "DevicePath"),
            Left = GetInt(monitor, "MonitorLeft"), Top = GetInt(monitor, "MonitorTop"), Right = GetInt(monitor, "MonitorRight"), Bottom = GetInt(monitor, "MonitorBottom"), Bound = identity != "ambiguous", Loading = true, LabelBox = labelBox, CandidateInputs = candidates };
        row.ThisInput = InputBox(ExistingInput(saved, "this-pc", stableId, position), candidates); row.OtherInput = InputBox(ExistingInput(saved, "other-pc", stableId, position), candidates);
        row.TestButton = new Button { Text = "Test", Dock = DockStyle.Top, Margin = new Padding(7, 14, 7, 5), Height = 29 };
        row.CalibrationLabel = new Label { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Margin = new Padding(5, 8, 5, 5) };
        LoadCalibration(row, savedMonitor); UpdateCalibrationLabel(row);
        row.ThisInput.TextChanged += delegate { InvalidateCalibration(row); }; row.OtherInput.TextChanged += delegate { InvalidateCalibration(row); };
        row.TestButton.Click += async delegate { await TestMonitor(row); };
        identify.Click += delegate { Identify(row); OfferRebind(row); };
        table.Controls.Add(row.ThisInput, 1, number); table.Controls.Add(row.OtherInput, 2, number); table.Controls.Add(row.TestButton, 3, number); table.Controls.Add(row.CalibrationLabel, 4, number);
        rows.Add(row); row.Loading = false;
    }

    private static string GetString(Dictionary<string, object> value, string key) { object item; return value != null && value.TryGetValue(key, out item) ? Convert.ToString(item) : ""; }
    private static int GetInt(Dictionary<string, object> value, string key) { object item; return value != null && value.TryGetValue(key, out item) && item != null ? Convert.ToInt32(item) : 0; }
    private void LoadCalibration(MonitorRow row, Dictionary<string, object> savedMonitor)
    {
        if (savedMonitor == null) return;
        if (!String.Equals(GetString(savedMonitor, "identityStatus"), row.IdentityStatus, StringComparison.OrdinalIgnoreCase) ||
            !String.Equals(GetString(savedMonitor, "devicePath"), row.DevicePath, StringComparison.OrdinalIgnoreCase)) return;
        object value; Dictionary<string, object> calibration;
        if (!savedMonitor.TryGetValue("calibration", out value) || (calibration = Map(value)) == null) return;
        string currentThis = ExistingInput(existing, "this-pc", row.StableId, row.Position), currentOther = ExistingInput(existing, "other-pc", row.StableId, row.Position);
        if (String.Equals(GetString(calibration, "thisInput"), currentThis, StringComparison.OrdinalIgnoreCase) && String.Equals(GetString(calibration, "otherInput"), currentOther, StringComparison.OrdinalIgnoreCase))
        { row.CalibrationStatus = GetString(calibration, "status"); row.VerifiedAt = GetString(calibration, "verifiedAt"); }
    }
    private void InvalidateCalibration(MonitorRow row) { if (row.Loading) return; row.CalibrationStatus = "untested"; row.VerifiedAt = null; profileCalibrationStatus = "untested"; profileCalibrationVerifiedAt = null; UpdateCalibrationLabel(row); SetBusy(false); }
    private void UpdateCalibrationLabel(MonitorRow row)
    {
        if (!row.Bound) { row.CalibrationLabel.Text = "Rebind required"; row.CalibrationLabel.ForeColor = Color.DarkOrange; return; }
        string value = String.IsNullOrWhiteSpace(row.CalibrationStatus) ? "untested" : row.CalibrationStatus;
        row.CalibrationLabel.Text = Char.ToUpperInvariant(value[0]) + value.Substring(1); row.CalibrationLabel.ForeColor = value == "verified" ? Color.DarkGreen : value == "failed" ? Color.DarkRed : Color.DimGray;
    }

    private void Identify(MonitorRow row)
    {
        Rectangle bounds = Rectangle.FromLTRB(row.Left, row.Top, row.Right, row.Bottom);
        if (bounds.Width <= 0 || bounds.Height <= 0) { MessageBox.Show(this, "Windows did not report bounds for this display.", "Identify", MessageBoxButtons.OK, MessageBoxIcon.Information); return; }
        Form overlay = new Form { FormBorderStyle = FormBorderStyle.None, StartPosition = FormStartPosition.Manual, Bounds = bounds, TopMost = true, ShowInTaskbar = false, BackColor = Color.Magenta, TransparencyKey = Color.Magenta };
        Label label = new Label { Text = row.Position.ToUpperInvariant() + "\n" + row.Model, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = Color.White, BackColor = Color.FromArgb(220, 20, 90, 180), Font = new Font("Segoe UI", 34, FontStyle.Bold), Margin = new Padding(18) };
        overlay.Controls.Add(label); System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer { Interval = 2200 };
        timer.Tick += delegate { timer.Stop(); timer.Dispose(); overlay.Close(); overlay.Dispose(); }; overlay.Show(); timer.Start();
    }

    private void OfferRebind(MonitorRow row)
    {
        if (row.IdentityStatus == "ambiguous")
        {
            MessageBox.Show(this, "Windows reported the same fallback identity for more than one display. Reconnect the displays to distinct ports or expose EDID serial numbers, then refresh. Setup will not guess which saved monitor this is.", "Ambiguous monitor identity", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }
        if (existing == null || ExistingMonitor(existing, row.StableId) != null) return;
        object schema; if (!existing.TryGetValue("schemaVersion", out schema) || Convert.ToInt32(schema) < 2) return;
        object monitorsValue; Dictionary<string, object> savedMonitors;
        if (!existing.TryGetValue("monitors", out monitorsValue) || (savedMonitors = Map(monitorsValue)) == null) return;
        HashSet<string> detected = new HashSet<string>(rows.Select(delegate(MonitorRow item) { return item.StableId; }), StringComparer.OrdinalIgnoreCase);
        List<string> missing = savedMonitors.Keys.Where(delegate(string id) { return !detected.Contains(id); }).ToList();
        if (missing.Count == 0) return;
        string selected = missing.Count == 1 ? missing[0] : ChooseSavedMonitor(missing);
        if (selected == null) return;
        DialogResult replace = MessageBox.Show(this, "Replace saved monitor '" + SavedMonitorLabel(savedMonitors, selected) + "' with the display you just identified? Its calibration will be reset.", "Replace saved monitor", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
        if (replace != DialogResult.Yes) return;
        RemapSavedMonitor(selected, row.StableId);
        row.CalibrationStatus = "untested"; row.VerifiedAt = null; UpdateCalibrationLabel(row);
        status.Text = "Saved monitor mapping replaced explicitly. Re-test both input directions.";
    }

    private string SavedMonitorLabel(Dictionary<string, object> monitors, string id)
    {
        object value; Dictionary<string, object> monitor;
        return monitors.TryGetValue(id, out value) && (monitor = Map(value)) != null && !String.IsNullOrWhiteSpace(GetString(monitor, "label")) ? GetString(monitor, "label") : id;
    }

    private string ChooseSavedMonitor(List<string> ids)
    {
        Form dialog = new Form { Text = "Choose saved monitor", ClientSize = new Size(430, 125), StartPosition = FormStartPosition.CenterParent, FormBorderStyle = FormBorderStyle.FixedDialog, MinimizeBox = false, MaximizeBox = false };
        ComboBox choices = new ComboBox { Left = 16, Top = 18, Width = 395, DropDownStyle = ComboBoxStyle.DropDownList };
        object monitorsValue; Dictionary<string, object> monitors = existing.TryGetValue("monitors", out monitorsValue) ? Map(monitorsValue) : null;
        foreach (string id in ids) choices.Items.Add(SavedMonitorLabel(monitors, id) + " [" + id + "]");
        if (choices.Items.Count > 0) choices.SelectedIndex = 0;
        Button ok = new Button { Text = "Replace", Left = 230, Top = 70, Width = 85, DialogResult = DialogResult.OK };
        Button cancel = new Button { Text = "Cancel", Left = 326, Top = 70, Width = 85, DialogResult = DialogResult.Cancel };
        dialog.Controls.Add(choices); dialog.Controls.Add(ok); dialog.Controls.Add(cancel); dialog.AcceptButton = ok; dialog.CancelButton = cancel;
        DialogResult result = dialog.ShowDialog(this); int index = choices.SelectedIndex; dialog.Dispose(); return result == DialogResult.OK && index >= 0 ? ids[index] : null;
    }

    private void RemapSavedMonitor(string oldId, string newId)
    {
        object value; Dictionary<string, object> monitors, profiles;
        if (existing.TryGetValue("monitors", out value) && (monitors = Map(value)) != null && monitors.ContainsKey(oldId))
        {
            Dictionary<string, object> monitor = Map(monitors[oldId]) ?? new Dictionary<string, object>();
            monitor["calibration"] = new Dictionary<string, object> { { "status", "untested" }, { "verifiedAt", null } };
            monitors.Remove(oldId); monitors[newId] = monitor;
        }
        if (existing.TryGetValue("profiles", out value) && (profiles = Map(value)) != null)
        {
            foreach (object profileValue in profiles.Values)
            {
                Dictionary<string, object> assignments = Map(profileValue);
                if (assignments != null && assignments.ContainsKey(oldId)) { object assignment = assignments[oldId]; assignments.Remove(oldId); assignments[newId] = assignment; }
            }
        }
    }

    private async Task TestMonitor(MonitorRow row)
    {
        string thisInput, otherInput;
        try { thisInput = ReadInput(row.ThisInput, row.Position); otherInput = ReadInput(row.OtherInput, row.Position); }
        catch (Exception error) { MessageBox.Show(this, error.Message, "Return test", MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
        if (!row.Bound) { MessageBox.Show(this, "This monitor has an ambiguous identity. Resolve it and refresh before testing.", "Return test", MessageBoxButtons.OK, MessageBoxIcon.Warning); return; }
        DialogResult ready = MessageBox.Show(this, "Before continuing, confirm this monitor is currently showing " + thisName.Text.Trim() + " using the return input '" + thisInput + "'.\n\nSetup will switch it to '" + otherInput + "' and attempt to return after five seconds.", "Confirm the known return input", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
        if (ready != DialogResult.Yes) return;
        profileCalibrationStatus = "untested"; profileCalibrationVerifiedAt = null;
        SetBusy(true); status.Text = "Testing " + row.Position + ". Wait for both transitions and do not close setup...";
        try
        {
            string arguments = "-TestMonitor " + Quote(row.StableId) + " -TestInput " + Quote(otherInput) + " -ReturnInput " + Quote(thisInput) + " -ReturnAfterSeconds 5 -PassThru";
            await Task.Run(delegate { RunScript("Switch-MonitorInput.ps1", arguments); });
            DialogResult worked = MessageBox.Show(this, "Did this monitor show " + otherName.Text.Trim() + " and then return to " + thisName.Text.Trim() + "?", "Confirm both transitions", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            row.CalibrationStatus = worked == DialogResult.Yes ? "verified" : "failed"; row.VerifiedAt = worked == DialogResult.Yes ? DateTime.UtcNow.ToString("o") : null;
            status.Text = worked == DialogResult.Yes ? "Return path verified for " + row.Position + "." : "The test was marked failed. Correct the ports or input codes before using a full profile.";
        }
        catch (Exception error)
        {
            row.CalibrationStatus = "failed"; row.VerifiedAt = null; status.Text = "The return test failed. Use the monitor controls if the picture did not return.";
            MessageBox.Show(this, error.Message, "Return test", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally { UpdateCalibrationLabel(row); SetBusy(false); }
    }

    private async Task TestFullProfile()
    {
        if (!rows.All(delegate(MonitorRow row) { return row.CalibrationStatus == "verified"; }))
        {
            MessageBox.Show(this, "Verify each monitor individually before testing all displays together.", "Full profile test", MessageBoxButtons.OK, MessageBoxIcon.Information); return;
        }
        DialogResult ready = MessageBox.Show(this, "Confirm every monitor is currently showing " + thisName.Text.Trim() + ". Setup will switch all displays to " + otherName.Text.Trim() + " and attempt to return after five seconds.", "Confirm full-profile baseline", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
        if (ready != DialogResult.Yes) return;
        string temporary = Path.Combine(staging, "full-profile-test-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            File.WriteAllText(temporary, json.Serialize(BuildConfiguration()), new UTF8Encoding(false));
            SetBusy(true); status.Text = "Testing all displays together. Wait for the automatic return...";
            string arguments = "-TestProfile other-pc -ReturnProfile this-pc -ConfigPath " + Quote(temporary) + " -ReturnAfterSeconds 5 -PassThru";
            await Task.Run(delegate { RunScript("Switch-MonitorInput.ps1", arguments); });
            DialogResult worked = MessageBox.Show(this, "Did all configured monitors show " + otherName.Text.Trim() + " and then return to " + thisName.Text.Trim() + "?", "Confirm complete profile", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            profileCalibrationStatus = worked == DialogResult.Yes ? "verified" : "failed";
            profileCalibrationVerifiedAt = worked == DialogResult.Yes ? DateTime.UtcNow.ToString("o") : null;
            status.Text = worked == DialogResult.Yes ? "Both complete profiles are visually verified." : "The complete profile test was marked failed. Individual monitor results are unchanged.";
        }
        catch (Exception error)
        {
            profileCalibrationStatus = "failed"; profileCalibrationVerifiedAt = null;
            status.Text = "The complete-profile return test failed. Use the monitor controls if any picture did not return.";
            MessageBox.Show(this, error.Message, "Full profile test", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch { } SetBusy(false); }
    }

    private string ReadInput(ComboBox box, string monitor)
    {
        string text = box.Text.Trim(); int index = Array.FindIndex(InputLabels, delegate(string item) { return String.Equals(item, text, StringComparison.OrdinalIgnoreCase); });
        if (index >= 0) return InputValues[index];
        Match candidate = Regex.Match(text, "^Candidate: .+ \\[(?<code>[^\\]]+)\\]$", RegexOptions.IgnoreCase);
        if (candidate.Success) return candidate.Groups["code"].Value.Trim().ToLowerInvariant();
        if (String.Equals(text, "HDMI (Samsung 0x05)", StringComparison.OrdinalIgnoreCase)) return "0x05";
        string normalized = text.ToLowerInvariant(); int rawCode;
        if (Int32.TryParse(normalized, out rawCode) && rawCode >= 0 && rawCode <= 255) return normalized;
        Dictionary<string, string> aliases = new Dictionary<string, string> { { "dp1", "displayport1" }, { "dp2", "displayport2" }, { "displayport", "displayport1" }, { "hdmi", "hdmi1" } };
        if (aliases.ContainsKey(normalized)) return aliases[normalized];
        if (InputValues.Contains(normalized) || Regex.IsMatch(normalized, "^0x[0-9a-f]{1,2}$")) return normalized;
        throw new InvalidOperationException("Choose both input ports for " + monitor + ". Advanced users may type a verified hex code such as 0x05.");
    }

    private static object WithUpdatedInput(object existingAssignment, string input)
    {
        Dictionary<string, object> scene = Map(existingAssignment);
        if (scene == null) return input;
        Dictionary<string, object> updated = new Dictionary<string, object>(scene, StringComparer.OrdinalIgnoreCase);
        updated["input"] = input;
        return updated;
    }

    private Dictionary<string, object> BuildConfiguration()
    {
        Dictionary<string, object> result = existing == null ? new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase) : json.Deserialize<Dictionary<string, object>>(json.Serialize(existing));
        result["schemaVersion"] = 2; result["computers"] = new Dictionary<string, object> { { "this-pc", thisName.Text.Trim() }, { "other-pc", otherName.Text.Trim() } };
        Dictionary<string, object> profiles, monitors; object value;
        if (!result.TryGetValue("profiles", out value) || (profiles = Map(value)) == null) profiles = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        if (!result.TryGetValue("monitors", out value) || (monitors = Map(value)) == null) monitors = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        Dictionary<string, object> oldThis = profiles.ContainsKey("this-pc") ? Map(profiles["this-pc"]) : null;
        Dictionary<string, object> oldOther = profiles.ContainsKey("other-pc") ? Map(profiles["other-pc"]) : null;
        Dictionary<string, object> thisProfile = new Dictionary<string, object>(), otherProfile = new Dictionary<string, object>();
        foreach (MonitorRow row in rows)
        {
            if (!row.Bound) throw new InvalidOperationException("Identify and bind " + row.Position + " before installing. Its hardware identity is ambiguous.");
            string thisInput = ReadInput(row.ThisInput, row.Position), otherInput = ReadInput(row.OtherInput, row.Position);
            object priorThis = null, priorOther = null;
            if (oldThis != null) oldThis.TryGetValue(row.StableId, out priorThis);
            if (oldOther != null) oldOther.TryGetValue(row.StableId, out priorOther);
            thisProfile[row.StableId] = WithUpdatedInput(priorThis, thisInput); otherProfile[row.StableId] = WithUpdatedInput(priorOther, otherInput);
            Dictionary<string, object> monitor = ExistingMonitor(result, row.StableId) ?? new Dictionary<string, object>();
            monitor["label"] = String.IsNullOrWhiteSpace(row.LabelBox.Text) ? row.Position : row.LabelBox.Text.Trim();
            monitor["identityStatus"] = row.IdentityStatus; monitor["model"] = row.Model; monitor["serial"] = row.Serial; monitor["devicePath"] = row.DevicePath;
            monitor["calibration"] = new Dictionary<string, object> { { "status", row.CalibrationStatus }, { "thisInput", thisInput }, { "otherInput", otherInput }, { "verifiedAt", row.VerifiedAt } };
            monitors[row.StableId] = monitor;
        }
        profiles["this-pc"] = thisProfile; profiles["other-pc"] = otherProfile; result["profiles"] = profiles; result["monitors"] = monitors;
        Dictionary<string, object> configuredHotkeys = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        if (result.TryGetValue("hotkeys", out value) && Map(value) != null)
            foreach (KeyValuePair<string, object> pair in Map(value)) configuredHotkeys[pair.Key] = pair.Value;
        if (hotkeys.Checked)
        {
            if (!configuredHotkeys.ContainsKey("this-pc")) configuredHotkeys["this-pc"] = "Ctrl+Alt+1";
            if (!configuredHotkeys.ContainsKey("other-pc")) configuredHotkeys["other-pc"] = "Ctrl+Alt+2";
        }
        else configuredHotkeys.Clear();
        result["hotkeys"] = configuredHotkeys;
        Dictionary<string, object> settings;
        if (!result.TryGetValue("settings", out value) || (settings = Map(value)) == null) settings = new Dictionary<string, object>();
        settings["startAtLogin"] = startAtLogin.Checked; result["settings"] = settings;
        result["profileCalibration"] = new Dictionary<string, object> { { "status", profileCalibrationStatus }, { "thisProfile", "this-pc" }, { "testProfile", "other-pc" }, { "verifiedAt", profileCalibrationVerifiedAt } };
        return result;
    }

    private async Task Install()
    {
        try
        {
            if (String.IsNullOrWhiteSpace(thisName.Text) || String.IsNullOrWhiteSpace(otherName.Text)) throw new InvalidOperationException("Enter a name for both computers.");
            Dictionary<string, object> configuration = BuildConfiguration(); string configPath = Path.Combine(staging, "chosen-profiles.json");
            File.WriteAllText(configPath, json.Serialize(configuration), new UTF8Encoding(false));
            SetBusy(true); status.Text = "Validating profiles and installing...";
            string arguments = "-Unattended -ConfigurationFile " + Quote(configPath) + " -InstallDirectory " + Quote(destination) + (hotkeys.Checked ? " -EnableHotkeys" : "") + (startAtLogin.Checked ? " -StartAtLogin" : "");
            await Task.Run(delegate { RunScript("Install.ps1", arguments); });
            string tray = Path.Combine(destination, "app", "MonitorTools.exe"); if (File.Exists(tray)) Process.Start(new ProcessStartInfo(tray) { UseShellExecute = true, WorkingDirectory = destination });
            finished = true; status.Text = "Installed successfully. Use the Monitor Tools tray icon for profiles, individual screens, hotkeys, and diagnostics."; openFolder.Visible = true; install.Text = "Finish";
        }
        catch (Exception error)
        {
            status.Text = "Setup could not finish. Existing profiles remain available or are backed up. Correct the error and retry.";
            MessageBox.Show(this, error.Message, "Setup error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally { SetBusy(false); if (finished) { table.Enabled = false; refresh.Enabled = false; testAll.Enabled = false; hotkeys.Enabled = false; startAtLogin.Enabled = false; } }
    }

    internal void PreparePreview()
    {
        existing = null;
        foreach (Dictionary<string, object> monitor in new[] { PreviewMonitor("left", "id-left", -1920, 0, 0, 1080), PreviewMonitor("center", "id-center", 0, 0, 1920, 1080), PreviewMonitor("right", "id-right", 1920, 0, 3840, 1080) }) AddRow(monitor, null);
        foreach (MonitorRow row in rows) { row.Loading = true; row.ThisInput.Text = "DisplayPort 1"; row.OtherInput.Text = "Candidate: HDMI (tested G60SD variant) [0x05]"; row.Loading = false; }
        thisName.Text = "Twingo"; otherName.Text = "Work"; status.Text = "Use Identify to match each physical display. Test each return path before switching a complete profile."; SetBusy(false);
    }
    private static Dictionary<string, object> PreviewMonitor(string position, string id, int left, int top, int right, int bottom)
    {
        return new Dictionary<string, object> { { "Position", position }, { "StableId", id }, { "IdentityStatus", "edid-serial" }, { "Model", "Samsung Odyssey G60SD" }, { "Serial", "preview" }, { "DevicePath", "preview" },
            { "CandidateInputs", new Dictionary<string, object> { { "HDMI (tested G60SD variant)", "0x05" }, { "DisplayPort 1", "0x0F" } } },
            { "MonitorLeft", left }, { "MonitorTop", top }, { "MonitorRight", right }, { "MonitorBottom", bottom } };
    }
}
