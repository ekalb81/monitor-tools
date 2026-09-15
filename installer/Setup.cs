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
        string staging = Path.Combine(Path.GetTempPath(), "monitor-tools-setup-" + Guid.NewGuid().ToString("N"));
        bool verify = args.Length == 1 && args[0] == "--verify-package";
        try
        {
            Directory.CreateDirectory(staging);
            using (Stream payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("MonitorTools.Payload.zip"))
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
            foreach (string required in new[] { "Install.ps1", "Run-Profile.ps1", "Switch-MonitorInput.ps1", "Detect-Monitors.ps1", "README.md" })
                if (!File.Exists(Path.Combine(staging, required))) throw new InvalidDataException("Missing " + required);
            if (verify) return 0;

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            bool renderPreview = args.Length == 2 && args[0] == "--render-preview";
            using (SetupWindow window = new SetupWindow(staging, renderPreview))
            {
                if (renderPreview)
                {
                    window.PreparePreview();
                    window.ShowInTaskbar = false;
                    window.Opacity = 0;
                    window.Show();
                    Application.DoEvents();
                    using (Bitmap bitmap = new Bitmap(window.Width, window.Height))
                    {
                        window.DrawToBitmap(bitmap, new Rectangle(Point.Empty, bitmap.Size));
                        bitmap.Save(args[1]);
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
            if (Path.GetFullPath(staging).StartsWith(tempRoot, StringComparison.OrdinalIgnoreCase) &&
                Regex.IsMatch(Path.GetFileName(staging), "^monitor-tools-setup-[0-9a-f]{32}$"))
            {
                try { Directory.Delete(staging, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
        }
    }
}

internal sealed class MonitorRow
{
    internal string Position;
    internal ComboBox ThisInput;
    internal ComboBox OtherInput;
}

internal sealed class SetupWindow : Form
{
    private readonly string staging;
    private readonly string destination = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Monitor Tools", "app");
    private readonly JavaScriptSerializer json = new JavaScriptSerializer();
    private readonly List<MonitorRow> rows = new List<MonitorRow>();
    private readonly TableLayoutPanel table = new TableLayoutPanel();
    private readonly Label status = new Label();
    private readonly CheckBox hotkeys = new CheckBox();
    private readonly Button install = new Button();
    private readonly Button refresh = new Button();
    private readonly Button openFolder = new Button();
    private bool busy;
    private bool finished;
    private readonly bool preview;
    private static readonly string[] InputLabels = { "DisplayPort 1", "HDMI 1", "HDMI 2", "HDMI (Samsung 0x05)", "DisplayPort 2", "DVI 1", "DVI 2", "VGA 1" };
    private static readonly string[] InputValues = { "displayport1", "hdmi1", "hdmi2", "0x05", "displayport2", "dvi1", "dvi2", "vga1" };

    protected override bool ShowWithoutActivation { get { return preview; } }

    internal SetupWindow(string stagingDirectory, bool renderPreview = false)
    {
        staging = stagingDirectory;
        preview = renderPreview;
        Text = "Monitor Tools Setup";
        ClientSize = new Size(860, 620);
        MinimumSize = new Size(820, 630);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 10);
        BackColor = Color.White;
        AutoScaleMode = AutoScaleMode.Font;

        Label heading = new Label { Text = "Set up Monitor Tools", Location = new Point(24, 20), Size = new Size(790, 42), Font = new Font("Segoe UI", 21, FontStyle.Bold) };
        Controls.Add(heading);
        Controls.Add(new Label { Text = "Choose the monitor port connected to each computer.\nThis PC is the computer running setup. Your keyboard and mouse stay connected where they are.", Location = new Point(26, 70), Size = new Size(800, 52), Anchor = AnchorStyles.Top | AnchorStyles.Left | AnchorStyles.Right });

        Panel monitorPanel = new Panel { Location = new Point(24, 132), Size = new Size(812, 230), AutoScroll = true, BorderStyle = BorderStyle.FixedSingle, Anchor = AnchorStyles.Top | AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right };
        table.Dock = DockStyle.Top;
        table.AutoSize = true;
        table.ColumnCount = 3;
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 40));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 30));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 30));
        monitorPanel.Controls.Add(table);
        Controls.Add(monitorPanel);
        ResetTable();

        hotkeys.Text = "Install hotkeys: Ctrl+Alt+1 for this PC, Ctrl+Alt+2 for the other PC";
        hotkeys.Checked = true;
        hotkeys.SetBounds(26, 378, 800, 30);
        hotkeys.Anchor = AnchorStyles.Bottom | AnchorStyles.Left;
        Controls.Add(hotkeys);
        Controls.Add(new Label { Text = "Setup will not switch your monitors. Test the return path before switching all screens.\nInstalls for your account; no administrator access required.", Location = new Point(26, 413), Size = new Size(800, 48), Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right });
        status.SetBounds(26, 470, 800, 78);
        status.Anchor = AnchorStyles.Bottom | AnchorStyles.Left | AnchorStyles.Right;
        status.Text = "Detecting monitors...";
        Controls.Add(status);

        refresh.Text = "Refresh monitors";
        refresh.SetBounds(24, 564, 155, 36);
        refresh.Anchor = AnchorStyles.Bottom | AnchorStyles.Left;
        refresh.Click += async delegate { await Detect(); };
        Controls.Add(refresh);
        openFolder.Text = "Open installed folder";
        openFolder.SetBounds(195, 564, 180, 36);
        openFolder.Anchor = AnchorStyles.Bottom | AnchorStyles.Left;
        openFolder.Visible = false;
        openFolder.Click += delegate { Process.Start(new ProcessStartInfo(destination) { UseShellExecute = true }); };
        Controls.Add(openFolder);
        install.Text = "Install";
        install.SetBounds(676, 564, 160, 36);
        install.Anchor = AnchorStyles.Bottom | AnchorStyles.Right;
        install.Click += async delegate { if (finished) Close(); else await Install(); };
        Controls.Add(install);
        Shown += async delegate { if (!preview) await Detect(); };
        FormClosing += delegate(object sender, FormClosingEventArgs e) { if (busy) e.Cancel = true; };
    }

    private void ResetTable()
    {
        foreach (Control control in table.Controls.Cast<Control>().ToArray()) control.Dispose();
        table.Controls.Clear();
        table.RowStyles.Clear();
        table.RowCount = 1;
        table.RowStyles.Add(new RowStyle(SizeType.Absolute, 38));
        string[] titles = { "Monitor", "This PC", "Other PC" };
        for (int i = 0; i < titles.Length; i++)
            table.Controls.Add(new Label { Text = titles[i], Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, Margin = new Padding(12, 0, 6, 0), Font = new Font(Font, FontStyle.Bold) }, i, 0);
        rows.Clear();
    }

    private void SetBusy(bool value)
    {
        busy = value;
        install.Enabled = !value && rows.Count > 0;
        refresh.Enabled = !value;
        hotkeys.Enabled = !value;
        table.Enabled = !value;
        UseWaitCursor = value;
    }

    private static string Quote(string value) { return "\"" + value.Replace("\"", "\\\"") + "\""; }

    private string RunScript(string name, string arguments)
    {
        string executable = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");
        ProcessStartInfo start = new ProcessStartInfo(executable,
            "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(Path.Combine(staging, name)) + " " + arguments);
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        start.StandardOutputEncoding = Encoding.UTF8;
        start.WorkingDirectory = staging;
        using (Process process = Process.Start(start))
        {
            Task<string> output = process.StandardOutput.ReadToEndAsync();
            Task<string> errors = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(120000))
            {
                process.Kill();
                throw new TimeoutException("The operation timed out. Check monitor connections and try again.");
            }
            Task.WaitAll(output, errors);
            if (process.ExitCode != 0) throw new InvalidOperationException(errors.Result.Trim() + "\n" + output.Result.Trim());
            return output.Result;
        }
    }

    private async Task Detect()
    {
        SetBusy(true);
        status.Text = "Detecting monitors. This may take a moment...";
        try
        {
            string result = await Task.Run(() => RunScript("Detect-Monitors.ps1", ""));
            List<Dictionary<string, object>> monitors = json.Deserialize<List<Dictionary<string, object>>>(result);
            Dictionary<string, object> existing = null;
            string config = Path.Combine(destination, "monitor-profiles.json");
            bool invalidExisting = false;
            if (File.Exists(config))
            {
                try { existing = json.Deserialize<Dictionary<string, object>>(File.ReadAllText(config)); }
                catch (Exception) { invalidExisting = true; }
            }
            ResetTable();
            foreach (Dictionary<string, object> monitor in monitors)
                AddRow(Convert.ToString(monitor["Position"]), Convert.ToString(monitor["Description"]), existing);
            status.Text = invalidExisting ? "Saved profiles could not be read. Choose inputs again; the old file will be backed up." :
                "Destination: " + destination + "\nExisting input choices are prefilled when available. Replaced profiles are backed up.";
        }
        catch (Exception error)
        {
            ResetTable();
            status.Text = "Could not detect monitors. Check connections and DDC/CI settings, then refresh.";
            MessageBox.Show(this, error.Message, "Monitor detection", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally { SetBusy(false); }
    }

    private ComboBox InputBox(string existing)
    {
        ComboBox box = new ComboBox { Dock = DockStyle.Top, Margin = new Padding(10, 12, 12, 8), DropDownStyle = ComboBoxStyle.DropDown };
        box.Items.AddRange(InputLabels);
        int index = Array.IndexOf(InputValues, existing);
        box.Text = index >= 0 ? InputLabels[index] : existing ?? "";
        return box;
    }

    private string ExistingInput(Dictionary<string, object> config, string profile, string position)
    {
        if (config == null || !config.ContainsKey("profiles")) return null;
        Dictionary<string, object> profiles = config["profiles"] as Dictionary<string, object>;
        if (profiles == null || !profiles.ContainsKey(profile)) return null;
        Dictionary<string, object> inputs = profiles[profile] as Dictionary<string, object>;
        return inputs != null && inputs.ContainsKey(position) ? Convert.ToString(inputs[position]) : null;
    }

    private void AddRow(string position, string description, Dictionary<string, object> existing)
    {
        int number = table.RowCount++;
        table.RowStyles.Add(new RowStyle(SizeType.Absolute, 68));
        table.Controls.Add(new Label { Text = position + "\n" + description, Dock = DockStyle.Fill, Margin = new Padding(12, 10, 6, 4), AutoEllipsis = true }, 0, number);
        MonitorRow row = new MonitorRow { Position = position, ThisInput = InputBox(ExistingInput(existing, "this-pc", position)), OtherInput = InputBox(ExistingInput(existing, "other-pc", position)) };
        table.Controls.Add(row.ThisInput, 1, number);
        table.Controls.Add(row.OtherInput, 2, number);
        rows.Add(row);
    }

    private string ReadInput(ComboBox box, string monitor)
    {
        string text = box.Text.Trim();
        int index = Array.FindIndex(InputLabels, item => string.Equals(item, text, StringComparison.OrdinalIgnoreCase));
        if (index >= 0) return InputValues[index];
        string normalized = text.ToLowerInvariant();
        int rawCode;
        if (int.TryParse(normalized, out rawCode) && rawCode >= 0 && rawCode <= 255) return normalized;
        Dictionary<string, string> aliases = new Dictionary<string, string> {
            { "dp1", "displayport1" }, { "dp2", "displayport2" },
            { "displayport", "displayport1" }, { "hdmi", "hdmi1" }
        };
        if (aliases.ContainsKey(normalized)) return aliases[normalized];
        if (InputValues.Contains(normalized) || Regex.IsMatch(normalized, "^0x[0-9a-f]{1,2}$")) return normalized;
        throw new InvalidOperationException("Choose both input ports for " + monitor + ". Advanced users may type a verified hex code such as 0x05.");
    }

    private async Task Install()
    {
        try
        {
            Dictionary<string, string> thisPc = new Dictionary<string, string>();
            Dictionary<string, string> otherPc = new Dictionary<string, string>();
            foreach (MonitorRow row in rows)
            {
                thisPc.Add(row.Position, ReadInput(row.ThisInput, row.Position));
                otherPc.Add(row.Position, ReadInput(row.OtherInput, row.Position));
            }
            string configPath = Path.Combine(staging, "chosen-profiles.json");
            File.WriteAllText(configPath, json.Serialize(new { profiles = new Dictionary<string, object> { { "this-pc", thisPc }, { "other-pc", otherPc } } }));
            bool enableHotkeys = hotkeys.Checked;
            SetBusy(true);
            status.Text = "Validating profiles and installing...";
            await Task.Run(() => RunScript("Install.ps1", "-Unattended -ConfigurationFile " + Quote(configPath) +
                " -InstallDirectory " + Quote(destination) + (enableHotkeys ? " -EnableHotkeys" : "")));
            string installedSetup = Path.Combine(destination, "Setup.exe");
            string currentSetup = Assembly.GetExecutingAssembly().Location;
            if (!string.Equals(currentSetup, installedSetup, StringComparison.OrdinalIgnoreCase)) File.Copy(currentSetup, installedSetup, true);
            finished = true;
            status.Text = "Installed successfully. " + (enableHotkeys ? "Ctrl+Alt+1 selects this PC; Ctrl+Alt+2 selects the other PC." : "Use This-PC.cmd and Other-PC.cmd in the installed folder.") +
                "\nTest one monitor in both directions first. You can close setup and delete the download.";
            openFolder.Visible = true;
            install.Text = "Finish";
        }
        catch (Exception error)
        {
            status.Text = "Setup could not finish. Your existing profiles are preserved or backed up. Correct the error and retry.";
            MessageBox.Show(this, error.Message, "Setup error", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            SetBusy(false);
            if (finished) { table.Enabled = false; refresh.Enabled = false; hotkeys.Enabled = false; }
        }
    }

    internal void PreparePreview()
    {
        AddRow("left", "Samsung G60SD", null);
        AddRow("center", "Samsung G60SD", null);
        AddRow("right", "Samsung G60SD", null);
        foreach (MonitorRow row in rows) { row.ThisInput.Text = "DisplayPort 1"; row.OtherInput.Text = "HDMI 1"; }
        status.Text = "Destination: " + destination + "\nExisting input choices are prefilled when available. Replaced profiles are backed up.";
        SetBusy(false);
    }
}
