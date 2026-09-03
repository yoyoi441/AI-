using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Forms;
using TokenMihariban.Models;
using TokenMihariban.Sync;
using TokenMihariban.UI;
using TokenMihariban.Updates;
using Application = System.Windows.Application;
using MouseButtons = System.Windows.Forms.MouseButtons;

namespace TokenMihariban;

/// <summary>
/// Entry point: owns the tray icon, the monitor, and the two windows (popup + settings)
/// — the Windows equivalent of the Mac app's <c>TokenMiharibanApp</c> (MenuBarExtra +
/// Settings scene). <see cref="Application.ShutdownMode"/> is <c>OnExplicitShutdown</c>
/// (set in App.xaml) since this app has no main window to keep it alive by default.
/// </summary>
public partial class App : Application
{
    private Mutex? _singleInstanceMutex;
    private NotifyIcon? _notifyIcon;
    private System.Drawing.Icon? _currentTrayIcon;
    private UsageMonitor? _monitor;
    private PopupWindow? _popupWindow;
    private SettingsWindow? _settingsWindow;

    public UsageMonitor Monitor => _monitor!;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstanceMutex = new Mutex(true, "TokenMihariban_SingleInstance_9F3A1C", out var createdNew);
        if (!createdNew)
        {
            var lang = CurrentLanguage();
            System.Windows.MessageBox.Show(
                L.String("alreadyRunningMessage", lang),
                L.String("alreadyRunningTitle", lang),
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            Shutdown();
            return;
        }

        _monitor = new UsageMonitor();

        _notifyIcon = new NotifyIcon
        {
            Visible = true,
            Text = "トークン見張り番"
        };
        _monitor.AttachTrayIcon(_notifyIcon);

        BuildContextMenu();

        _notifyIcon.MouseClick += (_, args) =>
        {
            if (args.Button == MouseButtons.Left) TogglePopup();
        };

        _monitor.SnapshotUpdated += (_, _) => Dispatcher.Invoke(OnSnapshotUpdated);
        OnSnapshotUpdated();
        _ = CheckForUpdatesAtLaunchAsync();
    }

    private async Task CheckForUpdatesAtLaunchAsync()
    {
        var settings = AppSettings.Shared;
        var enabled = settings.HasKey("automaticUpdateCheckEnabled")
            ? settings.GetBool("automaticUpdateCheckEnabled", true)
            : true;
        if (!enabled) return;

        await Task.Delay(TimeSpan.FromSeconds(5));
        AppRelease? release;
        try
        {
            release = await UpdateService.CheckAsync();
        }
        catch
        {
            // Automatic checks stay silent when offline. Manual checks still show errors.
            return;
        }
        if (release is null) return;

        var lang = CurrentLanguage();
        var answer = System.Windows.MessageBox.Show(
            L.String("updateAvailableFormat", lang, release.Version.ToString(3)) + "\n\n" + L.String("updateRestartNote", lang),
            L.String("updateDialogTitle", lang),
            MessageBoxButton.YesNo,
            MessageBoxImage.Information);
        if (answer != MessageBoxResult.Yes) return;

        try
        {
            var installer = await UpdateService.DownloadInstallerAsync(release);
            UpdateService.StartInstaller(installer);
            ShutdownApp();
        }
        catch (Exception ex)
        {
            System.Windows.MessageBox.Show(
                L.String("updateFailedFormat", lang, ex.Message),
                L.String("updateDialogTitle", lang),
                MessageBoxButton.OK,
                MessageBoxImage.Error);
        }
    }

    private void BuildContextMenu()
    {
        var lang = CurrentLanguage();
        var menu = new ContextMenuStrip();

        var refreshItem = new ToolStripMenuItem(L.String("refresh", lang));
        refreshItem.Click += (_, _) => _monitor!.Refresh();

        var settingsItem = new ToolStripMenuItem(L.String("settingsEllipsis", lang));
        settingsItem.Click += (_, _) => ShowSettings();

        var quitItem = new ToolStripMenuItem(L.String("quit", lang));
        quitItem.Click += (_, _) => ShutdownApp();

        menu.Items.Add(refreshItem);
        menu.Items.Add(settingsItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(quitItem);
        // Rebuilt on every open so a language change (no restart required) is reflected immediately.
        menu.Opening += (_, _) => RefreshMenuText(menu);

        _notifyIcon!.ContextMenuStrip = menu;
    }

    private void RefreshMenuText(ContextMenuStrip menu)
    {
        var lang = CurrentLanguage();
        if (menu.Items.Count < 4) return;
        menu.Items[0].Text = L.String("refresh", lang);
        menu.Items[1].Text = L.String("settingsEllipsis", lang);
        menu.Items[3].Text = L.String("quit", lang);
    }

    private static AppLanguage CurrentLanguage() => AppLanguageExtensions.FromStorageValue(AppSettings.Shared.GetString("appLanguage"));

    private void OnSnapshotUpdated()
    {
        UpdateTrayIcon();
        _popupWindow?.Refresh();
    }

    private void UpdateTrayIcon()
    {
        if (_monitor is null || _notifyIcon is null) return;
        var settings = AppSettings.Shared;
        var metric = GaugeMetricExtensions.FromStorageValue(settings.GetString("menuBarMetric"));
        var showClaude = settings.HasKey("showClaudeProvider") ? settings.GetBool("showClaudeProvider", true) : true;
        var showCodex = settings.HasKey("showCodexProvider") ? settings.GetBool("showCodexProvider", true) : true;

        var newIcon = TrayIconRenderer.Render(
            _monitor.Snapshot,
            _monitor.CodexSnapshot,
            metric,
            _monitor.Snapshot.Appearance.Style,
            showClaude,
            showCodex,
            SystemTheme.IsDarkTaskbar()
        );

        var previousIcon = _currentTrayIcon;
        _notifyIcon.Icon = newIcon;
        _currentTrayIcon = newIcon;
        if (previousIcon is not null) TrayIconRenderer.Destroy(previousIcon);
    }

    private void TogglePopup()
    {
        if (_popupWindow is { IsVisible: true })
        {
            _popupWindow.HidePopup();
            return;
        }

        _popupWindow ??= new PopupWindow(this);
        _popupWindow.Refresh();
        _popupWindow.ShowNearCursor(System.Windows.Forms.Cursor.Position);
    }

    public void ShowSettings()
    {
        if (_settingsWindow is null)
        {
            _settingsWindow = new SettingsWindow(this);
            _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        }
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    public void ShutdownApp()
    {
        _monitor?.Dispose();
        if (_currentTrayIcon is not null) TrayIconRenderer.Destroy(_currentTrayIcon);
        _notifyIcon?.Dispose();
        _singleInstanceMutex?.ReleaseMutex();
        Shutdown();
    }
}
