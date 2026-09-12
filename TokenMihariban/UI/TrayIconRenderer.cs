using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using TokenMihariban.Models;
// The WPF SDK (UseWPF=true) implicitly brings in System.Windows.Media and
// System.Windows.Shapes project-wide, both of which also define Color/Pen/Rectangle —
// this file is pure GDI+ (tray icons are System.Drawing.Icon, not WPF), so pin these
// names to System.Drawing explicitly rather than leaving them ambiguous.
using Brush = System.Drawing.Brush;
using Color = System.Drawing.Color;
using Pen = System.Drawing.Pen;
using Point = System.Drawing.Point;
using Rectangle = System.Drawing.Rectangle;

namespace TokenMihariban.UI;

/// <summary>
/// Renders the tray icon: a small ring/bar per visible provider, showing either time
/// remaining or token usage (per Settings), same idea as the Mac menu bar icon. Windows
/// has room for only one small square icon, so when both providers have data it shows
/// the higher usage value. The popup still shows both providers in full.
/// </summary>
internal static class TrayIconRenderer
{
    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);

    /// <summary>
    /// <see cref="Bitmap.GetHicon"/> allocates a native GDI icon handle that .NET does
    /// not own or free automatically — <see cref="Icon.FromHandle"/> just wraps it.
    /// Refreshing the tray icon periodically without this would leak a GDI handle every
    /// time, eventually exhausting the process's GDI object quota. Call this on the
    /// *previous* icon only after a new one has been assigned to the NotifyIcon.
    /// </summary>
    public static void Destroy(Icon icon)
    {
        DestroyIcon(icon.Handle);
        icon.Dispose();
    }

    private sealed record ProviderSpec(double Fraction, Color Color, string CenterText);

    public static Icon Render(UsageSnapshot snapshot, CodexSnapshot codexSnapshot, OllamaSnapshot ollamaSnapshot, AIToolSnapshot aiToolSnapshot, GaugeMetric metric, GaugeDisplayStyle style, bool showClaude, bool showCodex, bool showOllama, bool showAITools, bool isDarkTaskbar)
    {
        var specs = new List<ProviderSpec>();

        if (showClaude && snapshot.CurrentBlock is { } block)
        {
            var color = ParseColor(snapshot.Appearance.ColorHex, Color.DodgerBlue);
            double fraction;
            if (metric == GaugeMetric.TimeRemaining)
            {
                fraction = TimeFraction(block.Start, block.End);
            }
            else if (snapshot.ReferenceTokens is { } reference && reference > 0)
            {
                fraction = Math.Min(1, (double)block.TotalTokens / reference);
            }
            else
            {
                fraction = TimeFraction(block.Start, block.End);
            }
            specs.Add(new ProviderSpec(fraction, color, ((int)Math.Round(fraction * 100)).ToString()));
        }

        if (showCodex && codexSnapshot.PrimaryWindow is { } primary)
        {
            var color = ParseColor(codexSnapshot.ColorHex, Color.LimeGreen);
            double fraction = metric == GaugeMetric.TimeRemaining
                ? TimeFraction(primary.ResetsAt, primary.WindowMinutes)
                : primary.Fraction;
            var centerText = metric == GaugeMetric.TimeRemaining
                ? ((int)Math.Round(fraction * 100)).ToString()
                : ((int)Math.Round(primary.UsedPercent)).ToString();
            specs.Add(new ProviderSpec(fraction, color, centerText));
        }

        if (showOllama && ollamaSnapshot.TargetFraction is { } ollamaFraction)
        {
            var color = ParseColor(ollamaSnapshot.ColorHex, Color.DarkOrange);
            specs.Add(new ProviderSpec(ollamaFraction, color, ((int)Math.Round(ollamaFraction * 100)).ToString()));
        }
        if (showAITools && aiToolSnapshot.TodayTotalTokens > 0)
        {
            var color = ParseColor(aiToolSnapshot.ColorHex, Color.MediumPurple);
            var fraction = aiToolSnapshot.TargetFraction ?? 1;
            specs.Add(new ProviderSpec(fraction, color, aiToolSnapshot.TargetFraction is null ? CompactTokens(aiToolSnapshot.TodayTotalTokens) : ((int)Math.Round(fraction * 100)).ToString()));
        }

        const int canvasSize = 32;
        using var bitmap = new Bitmap(canvasSize, canvasSize);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);

            if (specs.Count == 0)
            {
                DrawIdleGlyph(g, canvasSize, isDarkTaskbar);
            }
            else
            {
                var visibleSpec = specs.MaxBy(spec => spec.Fraction)!;
                DrawGauge(g, visibleSpec, new Rectangle(1, 1, canvasSize - 2, canvasSize - 2), style, isDarkTaskbar);
            }
        }

        var hIcon = bitmap.GetHicon();
        return Icon.FromHandle(hIcon);
    }

    private static void DrawGauge(Graphics g, ProviderSpec spec, Rectangle bounds, GaugeDisplayStyle style, bool isDarkTaskbar)
    {
        var textColor = isDarkTaskbar ? Color.White : Color.Black;
        var trackColor = Color.FromArgb(90, 128, 128, 128);

        if (style == GaugeDisplayStyle.Ring)
        {
            const float lineWidth = 3f;
            var ringRect = new RectangleF(bounds.X + lineWidth, bounds.Y + lineWidth, bounds.Width - lineWidth * 2, bounds.Height - lineWidth * 2);
            using var trackPen = new Pen(trackColor, lineWidth);
            g.DrawEllipse(trackPen, ringRect);

            var sweep = 360f * (float)Math.Max(0.02, spec.Fraction);
            using var arcPen = new Pen(spec.Color, lineWidth) { StartCap = LineCap.Round, EndCap = LineCap.Round };
            g.DrawArc(arcPen, ringRect, -90, sweep);
        }
        else
        {
            var barHeight = Math.Max(3, bounds.Height / 3);
            var barRect = new Rectangle(bounds.X, bounds.Y + (bounds.Height - barHeight) / 2, bounds.Width, barHeight);
            using var trackBrush = new SolidBrush(trackColor);
            FillRoundedRect(g, trackBrush, barRect, barHeight / 2f);

            var filledWidth = Math.Max(2, (int)(bounds.Width * spec.Fraction));
            using var fillBrush = new SolidBrush(spec.Color);
            FillRoundedRect(g, fillBrush, new Rectangle(barRect.X, barRect.Y, filledWidth, barRect.Height), barHeight / 2f);
        }

        var fontSize = spec.CenterText.Length >= 3 ? 8f : 10f;
        using var font = new Font(FontFamily.GenericSansSerif, fontSize, FontStyle.Bold, GraphicsUnit.Pixel);
        using var textBrush = new SolidBrush(textColor);
        using var format = new StringFormat
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center
        };
        g.DrawString(spec.CenterText, font, textBrush, bounds, format);
    }

    private static void FillRoundedRect(Graphics g, Brush brush, Rectangle rect, float radius)
    {
        using var path = new GraphicsPath();
        var d = radius * 2;
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        g.FillPath(brush, path);
    }

    private static void DrawIdleGlyph(Graphics g, int canvasSize, bool isDarkTaskbar)
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico");
        if (File.Exists(iconPath))
        {
            using var icon = new Icon(iconPath);
            using var image = icon.ToBitmap();
            g.DrawImage(image, new Rectangle(0, 0, canvasSize, canvasSize));
            return;
        }

        using var pen = new Pen(isDarkTaskbar ? Color.White : Color.Black, 2f);
        var inset = canvasSize / 4;
        g.DrawEllipse(pen, inset, inset, canvasSize - inset * 2, canvasSize - inset * 2);
    }

    private static Color ParseColor(string hex, Color fallback)
    {
        var sanitized = hex.TrimStart('#');
        if (sanitized.Length != 6 || !int.TryParse(sanitized, System.Globalization.NumberStyles.HexNumber, null, out var rgb)) return fallback;
        return Color.FromArgb((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
    }

    private static string CompactTokens(long count) => count switch
    {
        >= 1_000_000 => (count / 1_000_000d).ToString("0.#") + "M",
        >= 1_000 => (count / 1_000d).ToString("0.#") + "K",
        _ => count.ToString()
    };

    private static double TimeFraction(DateTime start, DateTime end)
    {
        var total = (end - start).TotalSeconds;
        var remaining = Math.Max(0, (end - DateTime.UtcNow).TotalSeconds);
        return total > 0 ? Math.Clamp((total - remaining) / total, 0, 1) : 0;
    }

    private static double TimeFraction(DateTime resetsAt, double windowMinutes)
    {
        var total = windowMinutes * 60;
        var remaining = Math.Max(0, (resetsAt - DateTime.UtcNow).TotalSeconds);
        return total > 0 ? Math.Clamp((total - remaining) / total, 0, 1) : 0;
    }
}
