using System;
using System.IO;
using Microsoft.Win32;

namespace TokenMihariban.UI;

/// <summary>
/// Per-user "start automatically at login" via the standard unelevated
/// <c>HKCU\...\CurrentVersion\Run</c> registry key — the Windows equivalent of macOS's
/// <c>SMAppService.mainApp</c> used by the Mac app's General settings tab. No admin
/// rights needed since this is HKEY_CURRENT_USER, not HKEY_LOCAL_MACHINE.
/// </summary>
internal static class LaunchAtLogin
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "TokenMihariban";

    public static bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
            return key?.GetValue(ValueName) is not null;
        }
    }

    public static void SetEnabled(bool enabled)
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true)
            ?? Registry.CurrentUser.CreateSubKey(RunKeyPath);
        if (enabled)
        {
            var exePath = Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "TokenMihariban.exe");
            key.SetValue(ValueName, $"\"{exePath}\"");
        }
        else
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }
}
