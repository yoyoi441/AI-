using System;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using TokenMihariban.Logic;
using TokenMihariban.Models;
using TokenMihariban.Sync;
using TokenMihariban.Updates;
using Brushes = System.Windows.Media.Brushes;
using Button = System.Windows.Controls.Button;
using CheckBox = System.Windows.Controls.CheckBox;
using Color = System.Windows.Media.Color;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Orientation = System.Windows.Controls.Orientation;
using RadioButton = System.Windows.Controls.RadioButton;
using TextBox = System.Windows.Controls.TextBox;

namespace TokenMihariban.UI;

/// <summary>
/// Settings window for local display, targets, and export — built procedurally in
/// code-behind, same style as PopupWindow, rather than a large static XAML tree.
/// </summary>
public partial class SettingsWindow : Window
{
    private readonly App _app;
    private AppLanguage Lang => AppLanguageExtensions.FromStorageValue(AppSettings.Shared.GetString("appLanguage"));

    public SettingsWindow(App app)
    {
        _app = app;
        InitializeComponent();
        Rebuild();
    }

    private void Rebuild()
    {
        var lang = Lang;
        Tabs.Items.Clear();
        Tabs.Items.Add(new TabItem { Header = L.String("generalTab", lang), Content = BuildGeneralTab() });
        Tabs.Items.Add(new TabItem { Header = L.String("appearanceTab", lang), Content = BuildAppearanceTab() });
        Tabs.Items.Add(new TabItem { Header = L.String("displayItemsTab", lang), Content = BuildDisplayItemsTab() });
        Tabs.Items.Add(new TabItem { Header = L.String("tokenTargetTab", lang), Content = BuildTokenTargetTab() });
        Tabs.Items.Add(new TabItem { Header = L.String("deviceSyncTab", lang), Content = BuildSyncTab() });
        Tabs.Items.Add(new TabItem { Header = L.String("exportTab", lang), Content = BuildExportTab() });
    }

    // MARK: - Shared helpers

    private static ScrollViewer Scroll(StackPanel content) => new() { Content = content, Padding = new Thickness(14), VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

    private static TextBlock SectionHeader(string text) => new() { Text = text, FontWeight = FontWeights.Bold, FontSize = 12, Margin = new Thickness(0, 16, 0, 6) };
    private static TextBlock FooterNote(string text) => new() { Text = text, FontSize = 11, Opacity = 0.65, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) };

    private static CheckBox Toggle(string label, bool initial, Action<bool> onChange)
    {
        var box = new CheckBox { Content = label, IsChecked = initial, Margin = new Thickness(0, 4, 0, 4) };
        box.Checked += (_, _) => onChange(true);
        box.Unchecked += (_, _) => onChange(false);
        return box;
    }

    /// <summary>Commits on focus-loss (not per keystroke) — the same fix applied on the Mac/iOS/Android settings screens, so typing a new target's in-progress digits doesn't briefly read as "exceeded" and fire a notification before you've finished typing.</summary>
    private static TextBox NumberField(string placeholder, double initial, Action<double> onCommit)
    {
        var box = new TextBox
        {
            Text = initial > 0 ? initial.ToString("0", CultureInfo.InvariantCulture) : "",
            Margin = new Thickness(0, 4, 0, 4),
            Padding = new Thickness(4)
        };
        if (box.Text.Length == 0) SetPlaceholder(box, placeholder);
        box.GotFocus += (_, _) => ClearPlaceholder(box, placeholder);
        box.LostFocus += (_, _) =>
        {
            var text = box.Text.Trim();
            var value = double.TryParse(text, NumberStyles.Number, CultureInfo.InvariantCulture, out var v) ? v : 0;
            onCommit(value);
            if (text.Length == 0) SetPlaceholder(box, placeholder);
        };
        return box;
    }

    private static void SetPlaceholder(TextBox box, string placeholder)
    {
        box.Text = placeholder;
        box.Foreground = Brushes.Gray;
        box.Tag = "placeholder";
    }

    private static void ClearPlaceholder(TextBox box, string placeholder)
    {
        if ((string?)box.Tag == "placeholder")
        {
            box.Text = "";
            box.ClearValue(TextBox.ForegroundProperty);
            box.Tag = null;
        }
    }

    // MARK: - General

    private UIElement BuildGeneralTab()
    {
        var lang = Lang;
        var settings = AppSettings.Shared;
        var stack = new StackPanel();

        stack.Children.Add(SectionHeader(L.String("launchHeader", lang)));
        stack.Children.Add(Toggle(L.String("launchAtLogin", lang), LaunchAtLogin.IsEnabled, enabled => LaunchAtLogin.SetEnabled(enabled)));
        stack.Children.Add(FooterNote(L.String("launchAtLoginNote", lang)));

        stack.Children.Add(SectionHeader(L.String("rescanHeader", lang)));
        var intervalLabel = new TextBlock { Text = L.String("rescanIntervalFormat", lang, (int)_app.Monitor.RefreshIntervalSeconds) };
        stack.Children.Add(intervalLabel);
        var slider = new Slider { Minimum = 30, Maximum = 600, Value = _app.Monitor.RefreshIntervalSeconds, TickFrequency = 30, IsSnapToTickEnabled = true, Margin = new Thickness(0, 4, 0, 4) };
        slider.ValueChanged += (_, args) =>
        {
            _app.Monitor.RefreshIntervalSeconds = args.NewValue;
            intervalLabel.Text = L.String("rescanIntervalFormat", lang, (int)args.NewValue);
        };
        stack.Children.Add(slider);
        stack.Children.Add(FooterNote(L.String("rescanNote", lang)));

        stack.Children.Add(SectionHeader(L.String("updatesHeader", lang)));
        stack.Children.Add(new TextBlock { Text = L.String("currentVersionFormat", lang, UpdateService.CurrentVersion.ToString(3)), Opacity = 0.75 });
        var automaticUpdateCheckEnabled = settings.HasKey("automaticUpdateCheckEnabled")
            ? settings.GetBool("automaticUpdateCheckEnabled", true)
            : true;
        stack.Children.Add(Toggle(L.String("automaticUpdateCheck", lang), automaticUpdateCheckEnabled,
            enabled => settings.SetBool("automaticUpdateCheckEnabled", enabled)));
        stack.Children.Add(FooterNote(L.String("automaticUpdateCheckNote", lang)));
        var updateStatus = new TextBlock { Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
        var updateButton = new Button { Content = L.String("checkForUpdates", lang), Padding = new Thickness(10, 4, 10, 4), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 6, 0, 0) };
        updateButton.Click += async (_, _) =>
        {
            updateButton.IsEnabled = false;
            updateStatus.Text = L.String("checkingForUpdates", lang);
            try
            {
                var release = await UpdateService.CheckAsync();
                if (release is null)
                {
                    updateStatus.Text = L.String("upToDate", lang);
                    return;
                }

                var answer = System.Windows.MessageBox.Show(
                    L.String("updateAvailableFormat", lang, release.Version.ToString(3)) + "\n\n" + L.String("updateRestartNote", lang),
                    L.String("updateDialogTitle", lang),
                    MessageBoxButton.YesNo,
                    MessageBoxImage.Information);
                if (answer != MessageBoxResult.Yes)
                {
                    updateStatus.Text = "";
                    return;
                }

                updateStatus.Text = L.String("downloadingUpdate", lang);
                var installer = await UpdateService.DownloadInstallerAsync(release);
                UpdateService.StartInstaller(installer);
                _app.ShutdownApp();
            }
            catch (Exception ex)
            {
                updateStatus.Text = L.String("updateFailedFormat", lang, ex.Message);
            }
            finally
            {
                updateButton.IsEnabled = true;
            }
        };
        stack.Children.Add(updateButton);
        stack.Children.Add(updateStatus);

        stack.Children.Add(SectionHeader(L.String("languageHeader", lang)));
        var languagePanel = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var candidate in new[] { AppLanguage.Japanese, AppLanguage.English })
        {
            var radio = new RadioButton { Content = candidate.DisplayName(), GroupName = "language", IsChecked = candidate == lang, Margin = new Thickness(0, 0, 16, 0) };
            radio.Checked += (_, _) =>
            {
                settings.SetString("appLanguage", candidate.ToStorageValue());
                _app.Monitor.Refresh();
                Rebuild();
            };
            languagePanel.Children.Add(radio);
        }
        stack.Children.Add(languagePanel);

        stack.Children.Add(SectionHeader(""));
        stack.Children.Add(Toggle(L.String("notificationsToggle", lang), settings.HasKey("notificationsEnabled") ? settings.GetBool("notificationsEnabled", true) : true,
            enabled => settings.SetBool("notificationsEnabled", enabled)));
        stack.Children.Add(FooterNote(L.String("notificationsNote", lang)));

        return Scroll(stack);
    }

    // MARK: - Device sync

    private UIElement BuildSyncTab()
    {
        var lang = Lang;
        var stack = new StackPanel();
        stack.Children.Add(SectionHeader(L.String("deviceSyncHeader", lang)));

        if (!_app.Monitor.IsDeviceSyncAvailable)
        {
            stack.Children.Add(new TextBlock { Text = L.String("syncUnavailable", lang), Foreground = Brushes.DarkOrange, TextWrapping = TextWrapping.Wrap });
            stack.Children.Add(FooterNote(L.String("syncUnavailableNote", lang)));
            return Scroll(stack);
        }

        if (_app.Monitor.SyncPairingCode is { } code)
        {
            var codeRow = new StackPanel { Orientation = Orientation.Horizontal };
            codeRow.Children.Add(new TextBlock { Text = code, FontSize = 23, FontWeight = FontWeights.Bold, FontFamily = new System.Windows.Media.FontFamily("Consolas"), VerticalAlignment = VerticalAlignment.Center });
            var copyButton = new Button { Content = L.String("copy", lang), Margin = new Thickness(12, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
            copyButton.Click += (_, _) =>
            {
                System.Windows.Clipboard.SetText(code);
                copyButton.Content = L.String("copied", lang);
            };
            codeRow.Children.Add(copyButton);
            stack.Children.Add(codeRow);
            stack.Children.Add(FooterNote(L.String("pairingCodeNoteWindows", lang)));

            var syncNow = new Button { Content = L.String("syncNow", lang), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 16, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
            var status = new TextBlock { Opacity = 0.7, Margin = new Thickness(0, 6, 0, 0) };
            syncNow.Click += async (_, _) =>
            {
                syncNow.IsEnabled = false;
                status.Text = L.String("syncing", lang);
                var succeeded = await _app.Monitor.SyncNowAsync();
                status.Text = L.String(succeeded ? "syncComplete" : "syncFailed", lang);
                syncNow.IsEnabled = true;
            };
            stack.Children.Add(syncNow);
            stack.Children.Add(status);

            var unpair = new Button { Content = L.String("unpairWindows", lang), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 18, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
            unpair.Click += async (_, _) =>
            {
                unpair.IsEnabled = false;
                await _app.Monitor.UnpairSyncAsync();
                Rebuild();
            };
            stack.Children.Add(unpair);
        }
        else
        {
            var create = new Button { Content = L.String("createNewCode", lang), HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(10, 4, 10, 4) };
            var createStatus = new TextBlock { Opacity = 0.7, Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap };
            create.Click += async (_, _) =>
            {
                create.IsEnabled = false;
                createStatus.Text = L.String("pairingConnecting", lang);
                var code = await _app.Monitor.CreateSyncPairingCodeAsync();
                if (code is not null) Rebuild();
                else
                {
                    createStatus.Text = L.String("pairingFailed", lang);
                    create.IsEnabled = true;
                }
            };
            stack.Children.Add(create);
            stack.Children.Add(createStatus);
            stack.Children.Add(FooterNote(L.String("createNewCodeNote", lang)));

            stack.Children.Add(SectionHeader(L.String("joinExistingHeader", lang)));
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            var input = new TextBox { Width = 220, MaxLength = 19, CharacterCasing = System.Windows.Controls.CharacterCasing.Upper, Padding = new Thickness(5), FontFamily = new System.Windows.Media.FontFamily("Consolas") };
            var connect = new Button { Content = L.String("connect", lang), Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
            var validation = new TextBlock { Foreground = Brushes.DarkOrange, Margin = new Thickness(0, 6, 0, 0), TextWrapping = TextWrapping.Wrap };
            connect.Click += async (_, _) =>
            {
                if (FirestoreSyncService.NormalizePairingCode(input.Text) is null)
                {
                    validation.Text = L.String("invalidPairingCode", lang);
                    return;
                }
                connect.IsEnabled = false;
                input.IsEnabled = false;
                validation.Text = L.String("pairingConnecting", lang);
                if (await _app.Monitor.JoinSyncPairingCodeAsync(input.Text)) Rebuild();
                else
                {
                    validation.Text = L.String("pairingFailed", lang);
                    connect.IsEnabled = true;
                    input.IsEnabled = true;
                }
            };
            row.Children.Add(input);
            row.Children.Add(connect);
            stack.Children.Add(row);
            stack.Children.Add(validation);
            stack.Children.Add(FooterNote(L.String("enterCodeNoteWindows", lang)));
        }

        stack.Children.Add(SectionHeader(L.String("syncPrivacyHeader", lang)));
        stack.Children.Add(FooterNote(L.String("syncPrivacyNote", lang)));
        return Scroll(stack);
    }

    // MARK: - Appearance

    private UIElement BuildAppearanceTab()
    {
        var lang = Lang;
        var settings = AppSettings.Shared;
        var stack = new StackPanel();

        stack.Children.Add(SectionHeader(L.String("styleHeader", lang)));
        var stylePanel = new StackPanel { Orientation = Orientation.Horizontal };
        var currentStyle = GaugeDisplayStyleExtensions.FromStorageValue(settings.GetString("gaugeStyle"));
        foreach (var style in new[] { GaugeDisplayStyle.Ring, GaugeDisplayStyle.Bar })
        {
            var radio = new RadioButton { Content = style.Label(lang), GroupName = "gaugeStyle", IsChecked = style == currentStyle, Margin = new Thickness(0, 0, 16, 0) };
            radio.Checked += (_, _) =>
            {
                settings.SetString("gaugeStyle", style.ToStorageValue());
                _app.Monitor.Refresh();
            };
            stylePanel.Children.Add(radio);
        }
        stack.Children.Add(stylePanel);
        stack.Children.Add(FooterNote(L.String("styleAppliesNote", lang)));

        stack.Children.Add(SectionHeader(L.String("colorHeader", lang)));
        stack.Children.Add(ColorRow(L.String("claudeColorLabel", lang), "gaugeColorHex", "#3B82F6"));
        stack.Children.Add(ColorRow(L.String("codexColorLabel", lang), "codexColorHex", "#22C55E"));
        stack.Children.Add(Toggle(L.String("gradientToggle", lang), settings.HasKey("gaugeUseGradient") ? settings.GetBool("gaugeUseGradient", true) : true,
            enabled => { settings.SetBool("gaugeUseGradient", enabled); _app.Monitor.Refresh(); }));
        stack.Children.Add(FooterNote(L.String("colorFooterNote", lang)));

        stack.Children.Add(SectionHeader(L.String("menuBarMetricHeader", lang)));
        var metricPanel = new StackPanel { Orientation = Orientation.Horizontal };
        var currentMetric = GaugeMetricExtensions.FromStorageValue(settings.GetString("menuBarMetric"));
        foreach (var metric in new[] { GaugeMetric.TimeRemaining, GaugeMetric.TokenUsage })
        {
            var radio = new RadioButton { Content = metric.Label(lang), GroupName = "menuBarMetric", IsChecked = metric == currentMetric, Margin = new Thickness(0, 0, 16, 0) };
            radio.Checked += (_, _) => { settings.SetString("menuBarMetric", metric.ToStorageValue()); _app.Monitor.Refresh(); };
            metricPanel.Children.Add(radio);
        }
        stack.Children.Add(metricPanel);
        stack.Children.Add(FooterNote(L.String("menuBarMetricNote", lang)));

        return Scroll(stack);
    }

    private UIElement ColorRow(string label, string key, string defaultHex)
    {
        var settings = AppSettings.Shared;
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
        var swatch = new Border { Width = 22, Height = 22, CornerRadius = new CornerRadius(11), Margin = new Thickness(0, 0, 8, 0) };
        var hex = settings.GetString(key) ?? defaultHex;
        swatch.Background = new SolidColorBrush(GaugeControls.ParseColor(hex, Colors.Gray));

        var button = new Button { Content = label, Padding = new Thickness(8, 2, 8, 2) };
        button.Click += (_, _) =>
        {
            using var dialog = new System.Windows.Forms.ColorDialog();
            var current = GaugeControls.ParseColor(settings.GetString(key) ?? defaultHex, Colors.Gray);
            dialog.Color = System.Drawing.Color.FromArgb(current.R, current.G, current.B);
            if (dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK)
            {
                var c = dialog.Color;
                var newHex = $"#{c.R:X2}{c.G:X2}{c.B:X2}";
                settings.SetString(key, newHex);
                swatch.Background = new SolidColorBrush(Color.FromRgb(c.R, c.G, c.B));
                _app.Monitor.Refresh();
            }
        };

        row.Children.Add(swatch);
        row.Children.Add(button);
        return row;
    }

    // MARK: - Display Items

    private UIElement BuildDisplayItemsTab()
    {
        var lang = Lang;
        var settings = AppSettings.Shared;
        var stack = new StackPanel();

        stack.Children.Add(SectionHeader(L.String("providersHeader", lang)));
        stack.Children.Add(Toggle(L.String("showClaudeProviderToggle", lang), settings.HasKey("showClaudeProvider") ? settings.GetBool("showClaudeProvider", true) : true,
            v => settings.SetBool("showClaudeProvider", v)));
        stack.Children.Add(Toggle(L.String("showCodexProviderToggle", lang), settings.HasKey("showCodexProvider") ? settings.GetBool("showCodexProvider", true) : true,
            v => settings.SetBool("showCodexProvider", v)));
        stack.Children.Add(FooterNote(L.String("providersNote", lang)));

        stack.Children.Add(SectionHeader(L.String("displayItemsHeaderMac", lang)));
        void Item(string key, string labelKey, bool defaultValue = true)
        {
            stack.Children.Add(Toggle(L.String(labelKey, lang), settings.HasKey(key) ? settings.GetBool(key, defaultValue) : defaultValue,
                v => settings.SetBool(key, v)));
        }
        Item("showTimeGauge", "itemTimeGauge");
        Item("showTokenGauge", "itemTokenGauge");
        Item("showTodaySummary", "itemTodaySummary");
        Item("showEstimatedCost", "itemEstimatedCost", defaultValue: false);
        stack.Children.Add(FooterNote(L.String("estimatedCostExplainer", lang)));
        Item("showModelBreakdown", "itemModelBreakdown");
        Item("showProjectBreakdown", "itemProjectBreakdown");
        Item("showHourlyChart", "itemHourlyChart");
        Item("showLast7Days", "itemLast7Days");
        stack.Children.Add(FooterNote(L.String("displayItemsFooterMac", lang)));

        return Scroll(stack);
    }

    // MARK: - Token Target

    private UIElement BuildTokenTargetTab()
    {
        var lang = Lang;
        var settings = AppSettings.Shared;
        var stack = new StackPanel();

        stack.Children.Add(SectionHeader(L.String("tokenTargetHeaderMac", lang)));
        stack.Children.Add(NumberField(L.String("tokenTargetPlaceholderMac", lang), settings.GetDouble("manualBlockTokenTarget"),
            v => { settings.SetDouble("manualBlockTokenTarget", v); _app.Monitor.Refresh(); }));
        stack.Children.Add(FooterNote(L.String("tokenTargetNoteMac", lang)));
        stack.Children.Add(FooterNote(L.String("tokenTargetFooterCodexNote", lang)));

        stack.Children.Add(SectionHeader(L.String("dailyTargetSectionHeader", lang)));
        var dailyEnabled = settings.GetBool("dailyTargetEnabled", false);
        var dailyFieldsPanel = new StackPanel { Visibility = dailyEnabled ? Visibility.Visible : Visibility.Collapsed };
        stack.Children.Add(Toggle(L.String("dailyTargetEnabledToggle", lang), dailyEnabled, v =>
        {
            settings.SetBool("dailyTargetEnabled", v);
            dailyFieldsPanel.Visibility = v ? Visibility.Visible : Visibility.Collapsed;
            _app.Monitor.Refresh();
        }));
        dailyFieldsPanel.Children.Add(NumberField(L.String("claudeDailyTargetPlaceholder", lang), settings.GetDouble("claudeDailyTokenTarget"), v => { settings.SetDouble("claudeDailyTokenTarget", v); _app.Monitor.Refresh(); }));
        dailyFieldsPanel.Children.Add(NumberField(L.String("codexDailyTargetPlaceholder", lang), settings.GetDouble("codexDailyTokenTarget"), v => { settings.SetDouble("codexDailyTokenTarget", v); _app.Monitor.Refresh(); }));
        dailyFieldsPanel.Children.Add(FooterNote(L.String("dailyTargetNote", lang)));
        stack.Children.Add(dailyFieldsPanel);

        stack.Children.Add(SectionHeader(L.String("customWindowSectionHeader", lang)));
        var windowEnabled = settings.GetBool("windowTargetEnabled", false);
        var windowFieldsPanel = new StackPanel { Visibility = windowEnabled ? Visibility.Visible : Visibility.Collapsed };
        stack.Children.Add(Toggle(L.String("windowTargetEnabledToggle", lang), windowEnabled, v =>
        {
            settings.SetBool("windowTargetEnabled", v);
            windowFieldsPanel.Visibility = v ? Visibility.Visible : Visibility.Collapsed;
            _app.Monitor.Refresh();
        }));

        var timeRow = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
        var startMinute = settings.HasKey("customWindowStartMinute") ? settings.GetInt("customWindowStartMinute", DailyTimeWindow.Default.StartMinute) : DailyTimeWindow.Default.StartMinute;
        var endMinute = settings.HasKey("customWindowEndMinute") ? settings.GetInt("customWindowEndMinute", DailyTimeWindow.Default.EndMinute) : DailyTimeWindow.Default.EndMinute;
        timeRow.Children.Add(new TextBlock { Text = L.String("customWindowStartLabel", lang), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 4, 0) });
        timeRow.Children.Add(TimeField(startMinute, m => { settings.SetInt("customWindowStartMinute", m); _app.Monitor.Refresh(); }));
        timeRow.Children.Add(new TextBlock { Text = L.String("customWindowEndLabel", lang), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(16, 0, 4, 0) });
        timeRow.Children.Add(TimeField(endMinute, m => { settings.SetInt("customWindowEndMinute", m); _app.Monitor.Refresh(); }));
        windowFieldsPanel.Children.Add(timeRow);

        windowFieldsPanel.Children.Add(NumberField(L.String("claudeWindowTargetPlaceholder", lang), settings.GetDouble("claudeWindowTokenTarget"), v => { settings.SetDouble("claudeWindowTokenTarget", v); _app.Monitor.Refresh(); }));
        windowFieldsPanel.Children.Add(NumberField(L.String("codexWindowTargetPlaceholder", lang), settings.GetDouble("codexWindowTokenTarget"), v => { settings.SetDouble("codexWindowTokenTarget", v); _app.Monitor.Refresh(); }));
        windowFieldsPanel.Children.Add(FooterNote(L.String("customWindowNote", lang)));
        stack.Children.Add(windowFieldsPanel);

        return Scroll(stack);
    }

    /// <summary>A simple "HH:mm" text field for the custom-window start/end time — commits on focus-loss, same as the number fields.</summary>
    private static TextBox TimeField(int initialMinute, Action<int> onCommit)
    {
        var box = new TextBox { Text = $"{initialMinute / 60:D2}:{initialMinute % 60:D2}", Width = 60, Padding = new Thickness(4) };
        box.LostFocus += (_, _) =>
        {
            var parts = box.Text.Split(':');
            if (parts.Length == 2 && int.TryParse(parts[0], out var h) && int.TryParse(parts[1], out var m) && h is >= 0 and < 24 && m is >= 0 and < 60)
            {
                onCommit(h * 60 + m);
            }
            else
            {
                box.Text = $"{initialMinute / 60:D2}:{initialMinute % 60:D2}";
            }
        };
        return box;
    }

    // MARK: - Export

    private UIElement BuildExportTab()
    {
        var lang = Lang;
        var stack = new StackPanel();

        stack.Children.Add(SectionHeader(L.String("exportHeader", lang)));

        var startPicker = new DatePicker { SelectedDate = DateTime.Today.AddDays(-30), Margin = new Thickness(0, 4, 0, 4) };
        var endPicker = new DatePicker { SelectedDate = DateTime.Today, Margin = new Thickness(0, 4, 0, 4) };

        stack.Children.Add(new TextBlock { Text = L.String("exportStartDateLabel", lang) });
        stack.Children.Add(startPicker);
        stack.Children.Add(new TextBlock { Text = L.String("exportEndDateLabel", lang), Margin = new Thickness(0, 8, 0, 0) });
        stack.Children.Add(endPicker);

        stack.Children.Add(new TextBlock { Text = L.String("exportFormatLabel", lang), Margin = new Thickness(0, 8, 0, 0) });
        var formatPanel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 4) };
        var csvRadio = new RadioButton { Content = "CSV", GroupName = "exportFormat", IsChecked = true, Margin = new Thickness(0, 0, 16, 0) };
        var jsonRadio = new RadioButton { Content = "JSON", GroupName = "exportFormat" };
        formatPanel.Children.Add(csvRadio);
        formatPanel.Children.Add(jsonRadio);
        stack.Children.Add(formatPanel);

        var statusText = new TextBlock { FontSize = 11, Opacity = 0.65, Margin = new Thickness(0, 8, 0, 0), TextWrapping = TextWrapping.Wrap };

        var exportButton = new Button { Content = L.String("exportButton", lang), Padding = new Thickness(8, 4, 8, 4), HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 12, 0, 0) };
        exportButton.Click += (_, _) =>
        {
            var start = (startPicker.SelectedDate ?? DateTime.Today.AddDays(-30)).Date;
            var end = (endPicker.SelectedDate ?? DateTime.Today).Date.AddDays(1);
            var rows = _app.Monitor.ExportRows(start, end);
            var isCsv = csvRadio.IsChecked == true;

            var dialog = new Microsoft.Win32.SaveFileDialog
            {
                FileName = $"token-mihariban-{DateTime.Now:yyyy-MM-dd}.{(isCsv ? "csv" : "json")}",
                Filter = isCsv ? "CSV (*.csv)|*.csv" : "JSON (*.json)|*.json"
            };
            if (dialog.ShowDialog() != true) return;

            try
            {
                var content = isCsv ? UsageExporter.Csv(rows) : UsageExporter.Json(rows);
                System.IO.File.WriteAllText(dialog.FileName, content);
                statusText.Text = L.String("exportSucceededFormat", lang, rows.Count);
            }
            catch
            {
                statusText.Text = L.String("exportFailed", lang);
            }
        };
        stack.Children.Add(exportButton);
        stack.Children.Add(statusText);

        stack.Children.Add(FooterNote(L.String("exportNote", lang)));

        return Scroll(stack);
    }
}
