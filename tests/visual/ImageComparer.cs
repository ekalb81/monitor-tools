using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

internal static class ImageComparer
{
    private const int PerChannelDelta = 20;
    private const int NeighborRadius = 1;
    private const double GlobalChangedRatioLimit = 0.001;
    private const double MaxTileRatioLimit = 0.05;
    private const int TileSize = 32;

    private sealed class Report
    {
        internal bool Passed;
        internal int Width;
        internal int Height;
        internal int ActualWidth;
        internal int ActualHeight;
        internal long ChangedPixels;
        internal double ChangedRatio;
        internal double MaxTileRatio;
        internal string Reason;
    }

    private static int Main(string[] args)
    {
        if (args.Length != 4)
        {
            Console.Error.WriteLine("Usage: ImageComparer.exe <expected.png> <actual.png> <diff.png> <report.json>");
            return 2;
        }

        string expectedPath = args[0];
        string actualPath = args[1];
        string diffPath = args[2];
        string reportPath = args[3];
        Report report = new Report { Reason = "Comparison did not run." };
        try
        {
            EnsureParentDirectory(diffPath);
            EnsureParentDirectory(reportPath);
            using (Bitmap expected = LoadArgb(expectedPath))
            using (Bitmap actual = LoadArgb(actualPath))
            {
                report.Width = expected.Width;
                report.Height = expected.Height;
                report.ActualWidth = actual.Width;
                report.ActualHeight = actual.Height;
                if (expected.Width != actual.Width || expected.Height != actual.Height)
                {
                    report.Passed = false;
                    report.ChangedPixels = Math.Max((long)expected.Width * expected.Height, (long)actual.Width * actual.Height);
                    report.ChangedRatio = 1.0;
                    report.MaxTileRatio = 1.0;
                    report.Reason = String.Format(CultureInfo.InvariantCulture,
                        "Dimensions differ: expected {0}x{1}, actual {2}x{3}.",
                        expected.Width, expected.Height, actual.Width, actual.Height);
                    WriteDimensionDiff(expected, actual, diffPath);
                    WriteReport(reportPath, report);
                    return 1;
                }

                byte[] expectedBytes = ReadPixels(expected);
                byte[] actualBytes = ReadPixels(actual);
                bool[] changed = Compare(expectedBytes, actualBytes, expected.Width, expected.Height);
                long changedPixels = 0;
                for (int i = 0; i < changed.Length; i++) if (changed[i]) changedPixels++;
                report.ChangedPixels = changedPixels;
                report.ChangedRatio = changed.Length == 0 ? 0 : (double)changedPixels / changed.Length;
                report.MaxTileRatio = GetMaximumTileRatio(changed, expected.Width, expected.Height);
                report.Passed = report.ChangedRatio <= GlobalChangedRatioLimit && report.MaxTileRatio <= MaxTileRatioLimit;
                report.Reason = report.Passed
                    ? "Images match within the documented tolerances."
                    : String.Format(CultureInfo.InvariantCulture,
                        "Pixel differences exceed tolerance: changed ratio {0:0.00000000}, maximum tile ratio {1:0.00000000}.",
                        report.ChangedRatio, report.MaxTileRatio);
                WriteDiff(actualBytes, changed, actual.Width, actual.Height, diffPath);
                WriteReport(reportPath, report);
                return report.Passed ? 0 : 1;
            }
        }
        catch (Exception error)
        {
            report.Passed = false;
            report.Reason = "Tool error: " + error.Message;
            try { WriteReport(reportPath, report); }
            catch (Exception reportError) { Console.Error.WriteLine("Could not write report: " + reportError.Message); }
            Console.Error.WriteLine(report.Reason);
            return 2;
        }
    }

    private static Bitmap LoadArgb(string path)
    {
        using (Image source = Image.FromFile(path))
        {
            Bitmap converted = new Bitmap(source.Width, source.Height, PixelFormat.Format32bppArgb);
            converted.SetResolution(source.HorizontalResolution, source.VerticalResolution);
            using (Graphics graphics = Graphics.FromImage(converted))
            {
                graphics.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                graphics.DrawImageUnscaled(source, 0, 0);
            }
            return converted;
        }
    }

    private static byte[] ReadPixels(Bitmap bitmap)
    {
        Rectangle bounds = new Rectangle(0, 0, bitmap.Width, bitmap.Height);
        BitmapData data = bitmap.LockBits(bounds, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try
        {
            int rowBytes = checked(bitmap.Width * 4);
            byte[] packed = new byte[checked(rowBytes * bitmap.Height)];
            if (data.Stride == rowBytes)
            {
                Marshal.Copy(data.Scan0, packed, 0, packed.Length);
            }
            else
            {
                byte[] row = new byte[Math.Abs(data.Stride)];
                for (int y = 0; y < bitmap.Height; y++)
                {
                    IntPtr source = IntPtr.Add(data.Scan0, y * data.Stride);
                    Marshal.Copy(source, row, 0, row.Length);
                    Buffer.BlockCopy(row, 0, packed, y * rowBytes, rowBytes);
                }
            }
            return packed;
        }
        finally { bitmap.UnlockBits(data); }
    }

    private static bool[] Compare(byte[] expected, byte[] actual, int width, int height)
    {
        bool[] changed = new bool[checked(width * height)];
        for (int y = 0; y < height; y++)
        {
            for (int x = 0; x < width; x++)
            {
                int pixel = y * width + x;
                bool expectedMatched = HasNearbyMatch(expected, actual, width, height, x, y);
                bool actualMatched = HasNearbyMatch(actual, expected, width, height, x, y);
                changed[pixel] = !expectedMatched || !actualMatched;
            }
        }
        return changed;
    }

    private static bool HasNearbyMatch(byte[] source, byte[] candidate, int width, int height, int x, int y)
    {
        int sourceOffset = (y * width + x) * 4;
        int minimumY = Math.Max(0, y - NeighborRadius);
        int maximumY = Math.Min(height - 1, y + NeighborRadius);
        int minimumX = Math.Max(0, x - NeighborRadius);
        int maximumX = Math.Min(width - 1, x + NeighborRadius);
        for (int candidateY = minimumY; candidateY <= maximumY; candidateY++)
        {
            for (int candidateX = minimumX; candidateX <= maximumX; candidateX++)
            {
                int candidateOffset = (candidateY * width + candidateX) * 4;
                if (ChannelsMatch(source, sourceOffset, candidate, candidateOffset)) return true;
            }
        }
        return false;
    }

    private static bool ChannelsMatch(byte[] first, int firstOffset, byte[] second, int secondOffset)
    {
        return Math.Abs(first[firstOffset] - second[secondOffset]) <= PerChannelDelta &&
            Math.Abs(first[firstOffset + 1] - second[secondOffset + 1]) <= PerChannelDelta &&
            Math.Abs(first[firstOffset + 2] - second[secondOffset + 2]) <= PerChannelDelta &&
            Math.Abs(first[firstOffset + 3] - second[secondOffset + 3]) <= PerChannelDelta;
    }

    private static double GetMaximumTileRatio(bool[] changed, int width, int height)
    {
        double maximum = 0;
        for (int top = 0; top < height; top += TileSize)
        {
            int tileHeight = Math.Min(TileSize, height - top);
            for (int left = 0; left < width; left += TileSize)
            {
                int tileWidth = Math.Min(TileSize, width - left);
                int count = 0;
                for (int y = top; y < top + tileHeight; y++)
                    for (int x = left; x < left + tileWidth; x++)
                        if (changed[y * width + x]) count++;
                maximum = Math.Max(maximum, (double)count / (tileWidth * tileHeight));
            }
        }
        return maximum;
    }

    private static void WriteDiff(byte[] actual, bool[] changed, int width, int height, string path)
    {
        byte[] output = new byte[actual.Length];
        for (int pixel = 0; pixel < changed.Length; pixel++)
        {
            int offset = pixel * 4;
            if (changed[pixel])
            {
                output[offset] = 255;
                output[offset + 1] = 0;
                output[offset + 2] = 255;
                output[offset + 3] = 255;
            }
            else
            {
                output[offset] = (byte)(actual[offset] * 35 / 100);
                output[offset + 1] = (byte)(actual[offset + 1] * 35 / 100);
                output[offset + 2] = (byte)(actual[offset + 2] * 35 / 100);
                output[offset + 3] = 255;
            }
        }
        WriteBitmap(output, width, height, path);
    }

    private static void WriteDimensionDiff(Bitmap expected, Bitmap actual, string path)
    {
        int width = Math.Max(expected.Width, actual.Width);
        int height = Math.Max(expected.Height, actual.Height);
        using (Bitmap diff = new Bitmap(width, height, PixelFormat.Format32bppArgb))
        using (Graphics graphics = Graphics.FromImage(diff))
        using (ImageAttributes attributes = new ImageAttributes())
        using (Pen marker = new Pen(Color.Magenta, 3))
        {
            graphics.Clear(Color.Magenta);
            ColorMatrix matrix = new ColorMatrix { Matrix00 = 0.35f, Matrix11 = 0.35f, Matrix22 = 0.35f, Matrix33 = 1f, Matrix44 = 1f };
            attributes.SetColorMatrix(matrix);
            graphics.DrawImage(actual, new Rectangle(0, 0, actual.Width, actual.Height), 0, 0, actual.Width, actual.Height, GraphicsUnit.Pixel, attributes);
            graphics.DrawRectangle(marker, 1, 1, Math.Max(1, actual.Width - 3), Math.Max(1, actual.Height - 3));
            diff.Save(path, ImageFormat.Png);
        }
    }

    private static void WriteBitmap(byte[] pixels, int width, int height, string path)
    {
        using (Bitmap bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb))
        {
            Rectangle bounds = new Rectangle(0, 0, width, height);
            BitmapData data = bitmap.LockBits(bounds, ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
            try
            {
                int rowBytes = checked(width * 4);
                if (data.Stride == rowBytes) Marshal.Copy(pixels, 0, data.Scan0, pixels.Length);
                else
                    for (int y = 0; y < height; y++)
                        Marshal.Copy(pixels, y * rowBytes, IntPtr.Add(data.Scan0, y * data.Stride), rowBytes);
            }
            finally { bitmap.UnlockBits(data); }
            bitmap.Save(path, ImageFormat.Png);
        }
    }

    private static void WriteReport(string path, Report report)
    {
        string json = String.Format(CultureInfo.InvariantCulture,
            "{{\n  \"passed\": {0},\n  \"width\": {1},\n  \"height\": {2},\n  \"actualWidth\": {3},\n  \"actualHeight\": {4},\n  \"changedPixels\": {5},\n  \"changedRatio\": {6:0.00000000},\n  \"maxTileRatio\": {7:0.00000000},\n  \"tolerances\": {{\n    \"perChannelDelta\": {8},\n    \"nearestNeighborRadius\": {9},\n    \"globalChangedRatio\": {10:0.00000000},\n    \"tileSize\": {11},\n    \"maxTileRatio\": {12:0.00000000}\n  }},\n  \"reason\": \"{13}\"\n}}\n",
            report.Passed ? "true" : "false", report.Width, report.Height, report.ActualWidth, report.ActualHeight,
            report.ChangedPixels, report.ChangedRatio, report.MaxTileRatio, PerChannelDelta, NeighborRadius,
            GlobalChangedRatioLimit, TileSize, MaxTileRatioLimit, EscapeJson(report.Reason));
        File.WriteAllText(path, json, new UTF8Encoding(false));
    }

    private static string EscapeJson(string value)
    {
        if (value == null) return String.Empty;
        StringBuilder escaped = new StringBuilder(value.Length + 16);
        foreach (char character in value)
        {
            switch (character)
            {
                case '\\': escaped.Append("\\\\"); break;
                case '"': escaped.Append("\\\""); break;
                case '\r': escaped.Append("\\r"); break;
                case '\n': escaped.Append("\\n"); break;
                case '\t': escaped.Append("\\t"); break;
                default:
                    if (character < 32) escaped.Append("\\u" + ((int)character).ToString("x4", CultureInfo.InvariantCulture));
                    else escaped.Append(character);
                    break;
            }
        }
        return escaped.ToString();
    }

    private static void EnsureParentDirectory(string path)
    {
        string fullPath = Path.GetFullPath(path);
        string directory = Path.GetDirectoryName(fullPath);
        if (!String.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
    }
}
