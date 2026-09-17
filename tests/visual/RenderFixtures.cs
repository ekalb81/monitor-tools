// Renders the actual compiled WinForms classes with synthetic data. No application
// entry point, tray host, PowerShell bridge, registry, or monitor API is invoked.
using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

internal static class RenderFixtures
{
    private const BindingFlags Members = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic;
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static Assembly setup, tray;
    private static string output;
    private static readonly List<object> results = new List<object>();
    [DllImport("shcore.dll")] private static extern int SetProcessDpiAwareness(int awareness);

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 3) { Console.Error.WriteLine("RenderFixtures <Setup.exe> <MonitorTools.exe> <output-directory>"); return 2; }
        try
        {
            int dpiResult = SetProcessDpiAwareness(0); // Fixed logical 96 DPI without changing the desktop setting.
            if (dpiResult < 0) Marshal.ThrowExceptionForHR(dpiResult);
            if (SystemInformation.HighContrast) throw new InvalidOperationException("The classic baseline profile requires high contrast to be off.");
            Thread.CurrentThread.CurrentCulture = CultureInfo.GetCultureInfo("en-US");
            Thread.CurrentThread.CurrentUICulture = CultureInfo.GetCultureInfo("en-US");
            Application.SetCompatibleTextRenderingDefault(false);
            Application.VisualStyleState = System.Windows.Forms.VisualStyles.VisualStyleState.NoneEnabled;
            setup = Assembly.LoadFrom(Path.GetFullPath(args[0]));
            tray = Assembly.LoadFrom(Path.GetFullPath(args[1]));
            output = Path.GetFullPath(args[2]); Directory.CreateDirectory(output);
            Run("setup-default", delegate { return Setup("default"); });
            Run("setup-verified", delegate { return Setup("verified"); });
            Run("setup-failure", delegate { return Setup("failure"); });
            Run("setup-busy", delegate { return Setup("busy"); });
            Run("setup-compact", delegate { return Setup("compact"); });
            Run("setup-scroll", delegate { return Setup("scroll"); });
            Run("editor-default", delegate { return Editor("default"); });
            Run("editor-compact", delegate { return Editor("compact"); });
            Run("editor-edited", delegate { return Editor("edited"); });
            File.WriteAllText(Path.Combine(output, "fixtures.json"), Json.Serialize(new {
                renderProfile = "classic-96dpi", os = Environment.OSVersion.VersionString,
                framework = Environment.Version.ToString(), culture = CultureInfo.CurrentCulture.Name,
                fontSmoothing = SystemInformation.IsFontSmoothingEnabled,
                fontSmoothingType = SystemInformation.FontSmoothingType,
                controlColor = SystemColors.Control.ToArgb(),
                fixtures = results
            }));
            return results.Cast<Dictionary<string, object>>().Any(r => !Convert.ToBoolean(r["passed"])) ? 1 : 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); return 2; }
    }

    private sealed class Fixture
    {
        internal Form Window;
        internal readonly List<string> Errors = new List<string>();
        internal Action AfterCapture;
    }

    private static object Field(object target, string name)
    {
        FieldInfo field = target.GetType().GetField(name, Members);
        if (field == null) throw new MissingFieldException(target.GetType().Name, name);
        return field.GetValue(target);
    }

    private static object Call(object target, string name, params object[] values)
    {
        MethodInfo method = target.GetType().GetMethod(name, Members);
        if (method == null) throw new MissingMethodException(target.GetType().Name, name);
        return method.Invoke(target, values);
    }

    private static void Set(object target, string name, object value)
    {
        FieldInfo field = target.GetType().GetField(name, Members);
        if (field == null) throw new MissingFieldException(target.GetType().Name, name);
        field.SetValue(target, value);
    }

    private static void Expect(Fixture fixture, bool condition, string message)
    {
        if (!condition) fixture.Errors.Add(message);
    }

    private static void Prepare(Form window, bool compact)
    {
        // Capture client content only: OS window borders are outside the product.
        Size chrome = new Size(window.Width - window.ClientSize.Width, window.Height - window.ClientSize.Height);
        Size minimumClient = new Size(window.MinimumSize.Width - chrome.Width, window.MinimumSize.Height - chrome.Height);
        Size target = compact ? minimumClient : window.ClientSize;
        window.FormBorderStyle = FormBorderStyle.None;
        window.MinimumSize = Size.Empty;
        window.ClientSize = target;
        window.StartPosition = FormStartPosition.Manual;
        window.Location = new Point(-30000, -30000);
        window.ShowInTaskbar = false;
        window.Opacity = 0;
        window.Show();
        window.PerformLayout();
        Application.DoEvents();
        using (Graphics graphics = window.CreateGraphics())
            if (Math.Abs(graphics.DpiX - 96) > 0.1) throw new InvalidOperationException("Visual fixtures require logical 96 DPI.");
        if (window.Font.Name != "Segoe UI") throw new InvalidOperationException("Segoe UI must be installed for visual fixtures.");
    }

    private static Fixture Setup(string state)
    {
        Type type = setup.GetType("SetupWindow", true);
        // Empty staging path makes unintended detection/installation fail closed.
        string staging = Path.Combine(output, "no-hardware-staging"); Directory.CreateDirectory(staging);
        Form window = (Form)Activator.CreateInstance(type, Members, null, new object[] { staging, true }, CultureInfo.InvariantCulture);
        Fixture fixture = new Fixture { Window = window };
        Call(window, "PreparePreview");
        IList rows = (IList)Field(window, "rows");
        if (state == "scroll")
        {
            for (int i = 4; i <= 6; i++)
            {
                Dictionary<string, object> monitor = new Dictionary<string, object> {
                    { "Position", "position-" + i }, { "StableId", "id-extra-" + i },
                    { "IdentityStatus", "connection-fallback" }, { "Model", "External Display " + i },
                    { "Serial", "fixture-" + i }, { "DevicePath", "fixture-path-" + i },
                    { "MonitorLeft", 0 }, { "MonitorTop", 0 }, { "MonitorRight", 1920 }, { "MonitorBottom", 1080 }
                };
                Call(window, "AddRow", monitor, null);
                object row = rows[rows.Count - 1];
                ((ComboBox)Field(row, "ThisInput")).Text = "DisplayPort 1";
                ((ComboBox)Field(row, "OtherInput")).Text = "HDMI 1";
            }
        }
        if (state == "verified" || state == "failure")
        {
            foreach (object row in rows)
            {
                Set(row, "CalibrationStatus", "verified");
                Call(window, "UpdateCalibrationLabel", row);
            }
            if (state == "failure")
            {
                Set(rows[rows.Count - 1], "CalibrationStatus", "failed");
                Call(window, "UpdateCalibrationLabel", rows[rows.Count - 1]);
                ((Label)Field(window, "status")).Text = "The right monitor did not return. Use its physical input selector, then check the selected ports.";
            }
            else ((Label)Field(window, "status")).Text = "Each monitor switched away and returned. You can now test all three together.";
        }
        Call(window, "SetBusy", state == "busy");
        if (state == "busy") ((Label)Field(window, "status")).Text = "Testing center. Waiting for the return attempt...";
        Prepare(window, state == "compact");
        if (state == "scroll")
        {
            TableLayoutPanel table = (TableLayoutPanel)Field(window, "table");
            Panel panel = (Panel)table.Parent;
            Expect(fixture, panel.VerticalScroll.Visible, "Six monitors must produce a vertical scrollbar.");
            panel.AutoScrollPosition = new Point(0, table.Height);
            Application.DoEvents();
            Expect(fixture, panel.AutoScrollPosition.Y < 0, "Scrolling must expose the remaining monitor rows.");
        }
        Button testAll = (Button)Field(window, "testAll");
        Expect(fixture, testAll.Enabled == (state == "verified"), "Full-desk test availability must reflect individual verification.");
        Expect(fixture, ((Button)Field(window, "install")).Enabled == (state != "busy"), "Install must be disabled during a return test.");
        Expect(fixture, ((TextBox)Field(window, "thisName")).Enabled == (state != "busy"), "Computer names must be locked during a return test.");
        return fixture;
    }

    private static Fixture Editor(string state)
    {
        Dictionary<string, object> config = Json.Deserialize<Dictionary<string, object>>(@"{
            'schemaVersion':2,
            'monitors':{'id-left':{'label':'Left'},'id-center':{'label':'Center'},'id-right':{'label':'Right'}},
            'profiles':{
                'personal':{'id-left':'0x05','id-center':'displayport1','id-right':'0x05'},
                'split-desk':{'id-left':'displayport1','id-center':{'input':'displayport1','brightness':35,'volume':20},'id-right':'displayport1'}
            },
            'hotkeys':{'personal':'Ctrl+Alt+1','split-desk':'Ctrl+Alt+3'}
        }".Replace('\'', '"'));
        Dictionary<string, string> labels = new Dictionary<string, string> { { "id-left", "Left Samsung" }, { "id-center", "Center Samsung" }, { "id-right", "Right Samsung" } };
        Func<string, string> labeler = delegate(string id) { return labels[id]; };
        Dictionary<string, string> hotkeys = new Dictionary<string, string> { { "personal", "Ctrl+Alt+1" }, { "split-desk", "Ctrl+Alt+3" } };
        Type type = tray.GetType("ProfileEditor", true);
        Form window = (Form)Activator.CreateInstance(type, Members, null, new object[] { config, labeler, hotkeys }, CultureInfo.InvariantCulture);
        Fixture fixture = new Fixture { Window = window };
        Prepare(window, state == "compact");
        DataGridView grid = (DataGridView)Field(window, "grid");
        Expect(fixture, grid.Rows.Count == 7, "The editor must display six assignments plus its new row.");
        if (state == "edited")
        {
            DataGridViewRow editedRow = grid.Rows.Cast<DataGridViewRow>().Single(row =>
                Convert.ToString(row.Cells[0].Value) == "split-desk" && Convert.ToString(row.Cells[1].Value) == "Center Samsung");
            grid.CurrentCell = editedRow.Cells[3];
            Expect(fixture, grid.BeginEdit(false), "Brightness cell must enter edit mode.");
            TextBox edit = grid.EditingControl as TextBox;
            if (edit == null) throw new InvalidOperationException("Expected the production grid text editor.");
            edit.Text = "42";
            Expect(fixture, grid.EndEdit(), "Brightness edit must commit.");
            Expect(fixture, Convert.ToString(editedRow.Cells[3].Value) == "42", "The committed brightness must be visible.");
            fixture.AfterCapture = delegate {
                Button save = Descendants(window).OfType<Button>().Single(b => b.Text == "Save");
                save.PerformClick();
                Dictionary<string, object> saved = (Dictionary<string, object>)type.GetProperty("Result", Members).GetValue(window, null);
                if (saved == null) { fixture.Errors.Add("Saving the edited grid did not return configuration."); return; }
                Dictionary<string, object> profiles = (Dictionary<string, object>)saved["profiles"];
                Dictionary<string, object> scene = (Dictionary<string, object>)((Dictionary<string, object>)profiles["split-desk"])["id-center"];
                Expect(fixture, Convert.ToInt32(scene["brightness"]) == 42 && Convert.ToInt32(scene["volume"]) == 20,
                    "Save must persist edited brightness and preserve the scene volume.");
            };
        }
        grid.ClearSelection(); grid.CurrentCell = null;
        window.ActiveControl = null;
        Application.DoEvents();
        return fixture;
    }

    private static IEnumerable<Control> Descendants(Control parent)
    {
        foreach (Control control in parent.Controls)
        {
            yield return control;
            foreach (Control child in Descendants(control)) yield return child;
        }
    }

    private static Rectangle BoundsInForm(Control control, Form window)
    {
        return window.RectangleToClient(control.RectangleToScreen(control.ClientRectangle));
    }

    private static ScrollableControl ScrollParent(Control control)
    {
        for (Control parent = control.Parent; parent != null && !(parent is Form); parent = parent.Parent)
        {
            ScrollableControl scroll = parent as ScrollableControl;
            if (scroll != null && scroll.AutoScroll) return scroll;
        }
        return null;
    }

    private static List<object> InspectLayout(Fixture fixture)
    {
        Form window = fixture.Window;
        List<object> layout = new List<object>();
        foreach (Control control in Descendants(window))
        {
            if (!control.Visible) continue;
            Rectangle bounds = BoundsInForm(control, window);
            layout.Add(new { type = control.GetType().Name, text = control.Text, enabled = control.Enabled,
                x = bounds.X, y = bounds.Y, width = bounds.Width, height = bounds.Height });
            bool interactive = control is Button || control is TextBox || control is ComboBox || control is CheckBox;
            ScrollableControl scroll = ScrollParent(control);
            if (scroll != null)
            {
                // Vertical clipping is intentional, but visible row controls must still fit horizontally.
                Rectangle viewport = BoundsInForm(scroll, window);
                if (interactive && bounds.Bottom > viewport.Top && bounds.Top < viewport.Bottom &&
                    (bounds.Left < viewport.Left || bounds.Right > viewport.Right))
                    fixture.Errors.Add("Scrollable control is clipped horizontally: " + control.Text);
                continue;
            }
            if (interactive && !window.ClientRectangle.Contains(bounds)) fixture.Errors.Add(control.GetType().Name + " is clipped: " + control.Text);
            Label label = control as Label;
            if (label != null && !label.AutoEllipsis && !String.IsNullOrWhiteSpace(label.Text))
            {
                Rectangle visible = Rectangle.Intersect(bounds, window.ClientRectangle);
                int width = Math.Max(1, visible.Width - label.Padding.Horizontal);
                Size required = TextRenderer.MeasureText(label.Text, label.Font, new Size(width, Int32.MaxValue), TextFormatFlags.WordBreak);
                if (required.Height > visible.Height - label.Padding.Vertical + 2) fixture.Errors.Add("Label text is clipped: " + label.Text);
            }
            DataGridView grid = control as DataGridView;
            if (grid != null)
            {
                foreach (DataGridViewColumn column in grid.Columns)
                {
                    Size required = TextRenderer.MeasureText(column.HeaderText, grid.Font, new Size(Math.Max(1, column.Width - 12), Int32.MaxValue), TextFormatFlags.WordBreak);
                    if (required.Height > grid.ColumnHeadersHeight - 4) fixture.Errors.Add("Grid heading is clipped: " + column.HeaderText);
                }
            }
        }
        // Top-level filled panels must not cover instructional labels or action rows.
        Control[] siblings = window.Controls.Cast<Control>().Where(c => c.Visible).ToArray();
        for (int i = 0; i < siblings.Length; i++)
            for (int j = i + 1; j < siblings.Length; j++)
                if (Rectangle.Intersect(siblings[i].Bounds, siblings[j].Bounds).Width > 2 && Rectangle.Intersect(siblings[i].Bounds, siblings[j].Bounds).Height > 2)
                    fixture.Errors.Add("Top-level controls overlap: " + siblings[i].GetType().Name + " / " + siblings[j].GetType().Name);
        return layout;
    }

    private static void Run(string name, Func<Fixture> create)
    {
        Fixture fixture = null;
        List<string> errors = new List<string>();
        int width = 0, height = 0;
        try
        {
            fixture = create();
            List<object> layout = InspectLayout(fixture);
            width = fixture.Window.ClientSize.Width; height = fixture.Window.ClientSize.Height;
            using (Bitmap image = new Bitmap(width, height, PixelFormat.Format32bppArgb))
            {
                image.SetResolution(96, 96);
                fixture.Window.DrawToBitmap(image, new Rectangle(0, 0, width, height));
                image.Save(Path.Combine(output, name + ".png"), ImageFormat.Png);
            }
            File.WriteAllText(Path.Combine(output, name + ".layout.json"), Json.Serialize(layout));
            if (fixture.AfterCapture != null) fixture.AfterCapture();
            errors.AddRange(fixture.Errors);
        }
        catch (Exception error) { errors.Add(error.ToString()); }
        finally { if (fixture != null && fixture.Window != null) { SetBusyForClose(fixture.Window); fixture.Window.Dispose(); } }
        results.Add(new Dictionary<string, object> { { "name", name }, { "passed", errors.Count == 0 }, { "width", width }, { "height", height }, { "errors", errors } });
        Console.WriteLine((errors.Count == 0 ? "PASS: " : "FAIL: ") + name + (errors.Count > 0 ? " - " + String.Join(" | ", errors.ToArray()) : ""));
    }

    private static void SetBusyForClose(Form window)
    {
        FieldInfo field = window.GetType().GetField("busy", Members);
        if (field != null) field.SetValue(window, false);
    }
}
