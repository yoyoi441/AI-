using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TokenMihariban.Models;
using TokenMihariban.Sync;
using Button = System.Windows.Controls.Button;
using Color = System.Windows.Media.Color;
using Orientation = System.Windows.Controls.Orientation;

namespace TokenMihariban.UI;

/// <summary>
/// The tray "dropdown" — Windows equivalent of the Mac menu bar popup / mobile main
/// screen. Content is rebuilt from scratch on every <see cref="Refresh"/> call rather
/// than data-bound, matching the "just recompute and redraw" style used throughout this
/// app (and the other platforms) instead of a full MVVM layer — simple and always
/// correct, at the cost of some redundant work on a low-frequency-updating popup.
/// </summary>
public partial class PopupWindow : Window
{
    private readonly App _app;

    public PopupWindow(App app)
    {
        _app = app;
        InitializeComponent();
        Rebuild();
        Deactivated += (_, _) => HidePopup();
    }

    public void HidePopup() => Hide();

    public void ShowNearCursor(System.Drawing.Point cursorPos)
    {
        Left = -10000;
        Top = -10000;
        Show();
        Dispatcher.BeginInvoke(new Action(() =>
        {
            var screen = System.Windows.Forms.Screen.FromPoint(cursorPos);
            var wa = screen.WorkingArea;
            var source = PresentationSource.FromVisual(this);
            var toDevice = source?.CompositionTarget?.TransformToDevice;
            var dpiX = toDevice.HasValue && toDevice.Value.M11 != 0 ? 1.0 / toDevice.Value.M11 : 1.0;
            var dpiY = toDevice.HasValue && toDevice.Value.M22 != 0 ? 1.0 / toDevice.Value.M22 : 1.0;

            var waLeft = wa.Left * dpiX;
            var waRight = wa.Right * dpiX;
            var waBottom = wa.Bottom * dpiY;

            var x = cursorPos.X * dpiX - ActualWidth / 2;
            var y = waBottom - ActualHeight - 8;

            if (x < waLeft) x = waLeft + 8;
            if (x + ActualWidth > waRight) x = waRight - ActualWidth - 8;

            Left = x;
            Top = y;
            Activate();
        }), System.Windows.Threading.DispatcherPriority.ContextIdle);
    }

    public void Refresh()
    {
        if (!IsVisible) return;
        Rebuild();
    }

    private static AppLanguage Lang() => AppLanguageExtensions.FromStorageValue(AppSettings.Shared.GetString("appLanguage"));

    private void Rebuild()
    {
        var lang = Lang();
        var settings = AppSettings.Shared;
        var monitor = _app.Monitor;
        RootPanel.Children.Clear();

        // Header
        var header = new Grid();
        header.ColumnDefinitions.Add(new ColumnDefinition());
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        header.Children.Add(new TextBlock { Text = "トークン見張り番", FontSize = 16, FontWeight = FontWeights.Bold, VerticalAlignment = VerticalAlignment.Center });

        var refreshButton = new Button { Content = "↻", Width = 28, Height = 28, Margin = new Thickness(4, 0, 0, 0), ToolTip = L.String("refresh", lang) };
        refreshButton.Click += (_, _) => monitor.Refresh();
        Grid.SetColumn(refreshButton, 1);

        var settingsButton = new Button { Content = "⚙", Width = 28, Height = 28, Margin = new Thickness(4, 0, 0, 0), ToolTip = L.String("settingsEllipsis", lang) };
        settingsButton.Click += (_, _) => _app.ShowSettings();
        Grid.SetColumn(settingsButton, 2);

        header.Children.Add(refreshButton);
        header.Children.Add(settingsButton);
        RootPanel.Children.Add(header);
        RootPanel.Children.Add(new Separator { Margin = new Thickness(0, 10, 0, 10) });

        var showClaude = settings.HasKey("showClaudeProvider") ? settings.GetBool("showClaudeProvider", true) : true;
        var showCodex = settings.HasKey("showCodexProvider") ? settings.GetBool("showCodexProvider", true) : true;

        var overview = BuildProviderOverview(monitor.Snapshot, monitor.CodexSnapshot, settings, showClaude, showCodex);
        if (overview is not null)
        {
            RootPanel.Children.Add(overview);
            RootPanel.Children.Add(new Separator { Margin = new Thickness(0, 8, 0, 10) });
        }

        if (showClaude) RootPanel.Children.Add(BuildClaudeCard(monitor.Snapshot, settings, lang));
        if (showClaude && showCodex) RootPanel.Children.Add(new Border { Height = 12 });
        if (showCodex) RootPanel.Children.Add(BuildCodexCard(monitor.CodexSnapshot, settings, lang));
    }

    private static FrameworkElement? BuildProviderOverview(
        UsageSnapshot claude,
        CodexSnapshot codex,
        AppSettings settings,
        bool showClaude,
        bool showCodex)
    {
        var metric = GaugeMetricExtensions.FromStorageValue(settings.GetString("menuBarMetric"));
        var useGradient = settings.HasKey("gaugeUseGradient") ? settings.GetBool("gaugeUseGradient", true) : true;
        var rings = new System.Collections.Generic.List<FrameworkElement>();

        if (showClaude && claude.CurrentBlock is { } block)
        {
            var color = GaugeControls.ParseColor(claude.Appearance.ColorHex, Colors.DodgerBlue);
            var fraction = metric == GaugeMetric.TokenUsage && claude.ReferenceTokens is { } reference && reference > 0
                ? Math.Min(1.0, (double)block.TotalTokens / reference)
                : TimeFraction(block.Start, block.End);
            rings.Add(GaugeControls.Ring(fraction, color, useGradient, $"{Math.Round(fraction * 100)}%", "Claude Code", 76));
        }

        if (showCodex && codex.PrimaryWindow is { } primary)
        {
            var color = GaugeControls.ParseColor(codex.ColorHex, Colors.LimeGreen);
            var fraction = metric == GaugeMetric.TokenUsage
                ? primary.Fraction
                : TimeFraction(primary.ResetsAt, primary.WindowMinutes);
            rings.Add(GaugeControls.Ring(fraction, color, useGradient, $"{Math.Round(fraction * 100)}%", "Codex", 76));
        }

        return rings.Count == 0 ? null : WrapGauges(rings, isRing: true);
    }

    private static Border Card(UIElement content)
    {
        return new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(18, 128, 128, 128)),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(14),
            Child = content
        };
    }

    private FrameworkElement BuildClaudeCard(UsageSnapshot snapshot, AppSettings settings, AppLanguage lang)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = "Claude Code", FontSize = 14, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 8) });

        var color = GaugeControls.ParseColor(snapshot.Appearance.ColorHex, Colors.DodgerBlue);
        var useGradient = snapshot.Appearance.UseGradient;
        var isRing = snapshot.Appearance.Style == GaugeDisplayStyle.Ring;

        var showTimeGauge = settings.HasKey("showTimeGauge") ? settings.GetBool("showTimeGauge", true) : true;
        var showTokenGauge = settings.HasKey("showTokenGauge") ? settings.GetBool("showTokenGauge", true) : true;

        if (showTimeGauge || showTokenGauge)
        {
            if (snapshot.CurrentBlock is { } block)
            {
                var items = new System.Collections.Generic.List<FrameworkElement>();
                if (showTimeGauge)
                {
                    var fraction = TimeFraction(block.Start, block.End);
                    items.Add(isRing
                        ? GaugeControls.Ring(fraction, color, useGradient, CompactRemaining(block.End), L.String("time", lang))
                        : GaugeControls.Bar(fraction, color, useGradient, L.String("time", lang), CompactRemaining(block.End)));
                }
                if (showTokenGauge)
                {
                    if (snapshot.ReferenceTokens is { } reference && reference > 0)
                    {
                        var fraction = Math.Min(1.0, (double)block.TotalTokens / reference);
                        var gaugeColor = fraction > 0.85 ? Colors.Red : color;
                        var valueText = $"{FormatTokens(block.TotalTokens)} / {FormatTokens(reference)}";
                        items.Add(isRing
                            ? GaugeControls.Ring(fraction, gaugeColor, useGradient, $"{Math.Round(fraction * 100)}%", valueText)
                            : GaugeControls.Bar(fraction, gaugeColor, useGradient, L.String("tokenLabel", lang), valueText));
                    }
                }
                stack.Children.Add(WrapGauges(items, isRing));

                if (showTokenGauge && snapshot.ReferenceTokens is { } refTokens && refTokens > 0)
                {
                    var note = snapshot.ReferenceIsLowConfidence
                        ? L.String("tokenEstimateLowConfidenceNoteFormat", lang, snapshot.HistoricalBlockCount)
                        : L.String("tokenEstimateNote", lang);
                    stack.Children.Add(new TextBlock { Text = note, FontSize = 10, Opacity = 0.65, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) });
                }
            }
            else
            {
                stack.Children.Add(new TextBlock { Text = L.String("noActiveBlock", lang), Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
            }
        }

        AddAlertGauges(stack, snapshot.TodayTotalTokens, snapshot.HourlyTokensToday, settings, color, isRing, useGradient, lang, isCodex: false);

        AddSummary(
            stack, settings, lang, snapshot.TodayTotalTokens,
            settings.HasKey("showEstimatedCost") && settings.GetBool("showEstimatedCost", false) ? snapshot.TodayEstimatedCostUSD : (double?)null,
            snapshot.TodayModelBreakdown, snapshot.TodayByProject, snapshot.HasUnpricedModelToday
        );

        var showHourlyChart = settings.HasKey("showHourlyChart") ? settings.GetBool("showHourlyChart", true) : true;
        if (showHourlyChart && snapshot.HourlyTokensToday.Count > 0)
        {
            stack.Children.Add(new TextBlock { Text = L.String("hourlyChartTitle", lang), FontSize = 12, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 10, 0, 4) });
            stack.Children.Add(SimpleBarChart.Build(snapshot.HourlyTokensToday.Select(p => (double)p.Tokens).ToList(), color));
        }

        var showLast7Days = settings.HasKey("showLast7Days") ? settings.GetBool("showLast7Days", true) : true;
        if (showLast7Days)
        {
            stack.Children.Add(new TextBlock { Text = L.String("last7DaysFormat", lang, FormatTokens(snapshot.Last7DaysTotalTokens)), FontSize = 11, Opacity = 0.65, Margin = new Thickness(0, 8, 0, 0) });
        }

        return Card(stack);
    }

    private FrameworkElement BuildCodexCard(CodexSnapshot snapshot, AppSettings settings, AppLanguage lang)
    {
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = "Codex", FontSize = 14, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 8) });

        var color = GaugeControls.ParseColor(snapshot.ColorHex, Colors.LimeGreen);
        var isRing = GaugeDisplayStyleExtensions.FromStorageValue(AppSettings.Shared.GetString("gaugeStyle")) == GaugeDisplayStyle.Ring;
        var useGradient = AppSettings.Shared.HasKey("gaugeUseGradient") ? AppSettings.Shared.GetBool("gaugeUseGradient", true) : true;

        var showTimeGauge = settings.HasKey("showTimeGauge") ? settings.GetBool("showTimeGauge", true) : true;
        var showTokenGauge = settings.HasKey("showTokenGauge") ? settings.GetBool("showTokenGauge", true) : true;

        if (showTimeGauge || showTokenGauge)
        {
            var windows = new[] { snapshot.PrimaryWindow, snapshot.SecondaryWindow }.Where(w => w is not null).Select(w => w!).ToList();
            if (windows.Count == 0)
            {
                stack.Children.Add(new TextBlock { Text = L.String("codexNoData", lang), Opacity = 0.7, TextWrapping = TextWrapping.Wrap });
            }
            else
            {
                var items = new System.Collections.Generic.List<FrameworkElement>();
                foreach (var window in windows)
                {
                    var caption = window.WindowMinutes >= 1440
                        ? L.String("perDaysFormat", lang, window.WindowMinutes / 1440)
                        : L.String("perHoursFormat", lang, window.WindowMinutes / 60);
                    var gaugeColor = window.Fraction > 0.85 ? Colors.Red : color;
                    items.Add(isRing
                        ? GaugeControls.Ring(window.Fraction, gaugeColor, useGradient, $"{Math.Round(window.UsedPercent)}%", $"{caption}\n{CompactRemaining(window.ResetsAt)}")
                        : GaugeControls.Bar(window.Fraction, gaugeColor, useGradient, caption, $"{Math.Round(window.UsedPercent)}% ・ {CompactRemaining(window.ResetsAt)}"));
                }
                stack.Children.Add(WrapGauges(items, isRing));
            }
        }

        AddAlertGauges(stack, snapshot.TodayTotalTokens, snapshot.HourlyTokensToday, settings, color, isRing, useGradient, lang, isCodex: true);

        AddSummary(stack, settings, lang, snapshot.TodayTotalTokens, null, snapshot.TodayModelBreakdown, snapshot.TodayByProject, hasUnpricedModel: false);

        var showHourlyChart = settings.HasKey("showHourlyChart") ? settings.GetBool("showHourlyChart", true) : true;
        if (showHourlyChart && snapshot.HourlyTokensToday.Count > 0)
        {
            stack.Children.Add(new TextBlock { Text = L.String("hourlyChartTitle", lang), FontSize = 12, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 10, 0, 4) });
            stack.Children.Add(SimpleBarChart.Build(snapshot.HourlyTokensToday.Select(p => (double)p.Tokens).ToList(), color));
        }

        var showLast7Days = settings.HasKey("showLast7Days") ? settings.GetBool("showLast7Days", true) : true;
        if (showLast7Days)
        {
            stack.Children.Add(new TextBlock { Text = L.String("last7DaysFormat", lang, FormatTokens(snapshot.Last7DaysTotalTokens)), FontSize = 11, Opacity = 0.65, Margin = new Thickness(0, 8, 0, 0) });
        }

        return Card(stack);
    }

    private void AddAlertGauges(StackPanel stack, long todayTotal, System.Collections.Generic.IReadOnlyList<HourlyUsagePoint> hourly, AppSettings settings, Color color, bool isRing, bool useGradient, AppLanguage lang, bool isCodex)
    {
        var dailyEnabled = settings.GetBool("dailyTargetEnabled", false);
        var windowEnabled = settings.GetBool("windowTargetEnabled", false);
        var dailyTarget = dailyEnabled ? settings.GetDouble(isCodex ? "codexDailyTokenTarget" : "claudeDailyTokenTarget") : 0;
        var windowTarget = windowEnabled ? settings.GetDouble(isCodex ? "codexWindowTokenTarget" : "claudeWindowTokenTarget") : 0;
        if (dailyTarget <= 0 && windowTarget <= 0) return;

        var window = new DailyTimeWindow(
            settings.HasKey("customWindowStartMinute") ? settings.GetInt("customWindowStartMinute", DailyTimeWindow.Default.StartMinute) : DailyTimeWindow.Default.StartMinute,
            settings.HasKey("customWindowEndMinute") ? settings.GetInt("customWindowEndMinute", DailyTimeWindow.Default.EndMinute) : DailyTimeWindow.Default.EndMinute);

        var items = new System.Collections.Generic.List<FrameworkElement>();
        if (dailyTarget > 0)
        {
            var fraction = Math.Min(1.0, todayTotal / dailyTarget);
            var gaugeColor = fraction >= 1.0 ? Colors.Red : color;
            var valueText = $"{FormatTokens(todayTotal)} / {FormatTokens((long)dailyTarget)}";
            items.Add(isRing
                ? GaugeControls.Ring(fraction, gaugeColor, useGradient, $"{Math.Round(fraction * 100)}%", $"{L.String("dailyTargetGaugeCaption", lang)}\n{valueText}")
                : GaugeControls.Bar(fraction, gaugeColor, useGradient, L.String("dailyTargetGaugeCaption", lang), valueText));
        }
        if (windowTarget > 0)
        {
            var windowTotal = hourly.TokensInWindow(window);
            var fraction = Math.Min(1.0, windowTotal / windowTarget);
            var gaugeColor = fraction >= 1.0 ? Colors.Red : color;
            var valueText = $"{FormatTokens(windowTotal)} / {FormatTokens((long)windowTarget)}";
            var caption = L.String("customWindowGaugeCaptionFormat", lang, window.RangeText());
            items.Add(isRing
                ? GaugeControls.Ring(fraction, gaugeColor, useGradient, $"{Math.Round(fraction * 100)}%", $"{caption}\n{valueText}")
                : GaugeControls.Bar(fraction, gaugeColor, useGradient, caption, valueText));
        }
        stack.Children.Add(WrapGauges(items, isRing));
    }

    private static void AddSummary(
        StackPanel stack, AppSettings settings, AppLanguage lang, long total, double? cost,
        System.Collections.Generic.IReadOnlyList<ModelBreakdown> breakdown,
        System.Collections.Generic.IReadOnlyList<ProjectUsageEntry> byProject, bool hasUnpricedModel)
    {
        var showTodaySummary = settings.HasKey("showTodaySummary") ? settings.GetBool("showTodaySummary", true) : true;
        var showModelBreakdown = settings.HasKey("showModelBreakdown") ? settings.GetBool("showModelBreakdown", true) : true;
        var showProjectBreakdown = settings.HasKey("showProjectBreakdown") ? settings.GetBool("showProjectBreakdown", true) : true;
        if (!showTodaySummary && !showModelBreakdown && !showProjectBreakdown && cost is null) return;

        var summary = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        summary.Children.Add(new TextBlock { Text = L.String("today", lang), FontSize = 12, FontWeight = FontWeights.Bold });
        if (showTodaySummary)
        {
            summary.Children.Add(new TextBlock { Text = L.String("totalTokensFormat", lang, FormatTokens(total)), FontSize = 12, Margin = new Thickness(0, 2, 0, 0) });
        }
        if (cost is { } c)
        {
            summary.Children.Add(new TextBlock { Text = L.String("estimatedCostFormat", lang, "$" + c.ToString("F2", CultureInfo.InvariantCulture)), FontSize = 11, Opacity = 0.65 });
            if (hasUnpricedModel)
            {
                summary.Children.Add(new TextBlock { Text = L.String("unpricedModelWarning", lang), FontSize = 10, Opacity = 0.65, TextWrapping = TextWrapping.Wrap });
            }
        }
        if (showModelBreakdown)
        {
            foreach (var entry in breakdown)
            {
                var sum = entry.InputTokens + entry.OutputTokens + entry.CacheCreationTokens + entry.CacheReadTokens;
                summary.Children.Add(new TextBlock { Text = L.String("modelBreakdownLineFormat", lang, entry.Model, FormatTokens(sum)), FontSize = 11, Opacity = 0.65 });
            }
        }
        if (showProjectBreakdown && byProject.Count > 0)
        {
            var topEntries = byProject.Take(5).ToList();
            summary.Children.Add(new TextBlock { Text = L.String("projectBreakdownHeader", lang), FontSize = 11, FontWeight = FontWeights.SemiBold, Opacity = 0.65, Margin = new Thickness(0, 4, 0, 0) });
            foreach (var entry in topEntries)
            {
                summary.Children.Add(new TextBlock { Text = L.String("modelBreakdownLineFormat", lang, entry.DisplayName, FormatTokens(entry.Tokens)), FontSize = 11, Opacity = 0.65 });
            }
            if (byProject.Count > topEntries.Count)
            {
                summary.Children.Add(new TextBlock { Text = L.String("moreProjectsFormat", lang, byProject.Count - topEntries.Count), FontSize = 10, Opacity = 0.65 });
            }
        }
        stack.Children.Add(summary);
    }

    private static FrameworkElement WrapGauges(System.Collections.Generic.List<FrameworkElement> items, bool isRing)
    {
        if (items.Count == 0) return new StackPanel();
        if (isRing)
        {
            var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
            foreach (var item in items) wrap.Children.Add(item);
            return wrap;
        }
        var stack = new StackPanel();
        foreach (var item in items) stack.Children.Add(item);
        return stack;
    }

    private static double TimeFraction(DateTime start, DateTime end)
    {
        var total = (end - start).TotalSeconds;
        var remaining = Math.Max(0, (end - DateTime.UtcNow).TotalSeconds);
        return total > 0 ? Math.Clamp((total - remaining) / total, 0, 1) : 0;
    }

    private static double TimeFraction(DateTime resetsAt, long windowMinutes)
    {
        var totalSeconds = windowMinutes * 60.0;
        var remainingSeconds = Math.Max(0, (resetsAt - DateTime.UtcNow).TotalSeconds);
        return totalSeconds > 0 ? Math.Clamp((totalSeconds - remainingSeconds) / totalSeconds, 0, 1) : 0;
    }

    private static string CompactRemaining(DateTime until)
    {
        var remaining = TimeSpan.FromSeconds(Math.Max(0, (until - DateTime.UtcNow).TotalSeconds));
        var hours = (int)remaining.TotalHours;
        var minutes = remaining.Minutes;
        return hours > 0 ? $"{hours}h{minutes}m" : $"{minutes}m";
    }

    private static string FormatTokens(long count) => count.ToString("N0", CultureInfo.InvariantCulture);
}
