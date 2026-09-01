using Microsoft.Win32;

namespace TokenMihariban.UI;

internal static class SystemTheme
{
    /// <summary>Whether the taskbar (and tray) is currently in dark mode, so icon glyphs/text can pick a readable color.</summary>
    public static bool IsDarkTaskbar()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            var value = key?.GetValue("SystemUsesLightTheme");
            return value is int i && i == 0;
        }
        catch
        {
            return false;
        }
    }
}
