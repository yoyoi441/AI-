using System;
using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading.Tasks;

namespace TokenMihariban.Updates;

internal sealed record AppRelease(Version Version, string Tag, string PageUrl, string? InstallerUrl, string? Sha256, string Notes);

internal static class UpdateService
{
    private const string LatestReleaseApi = "https://api.github.com/repos/yoyoi441/AI-/releases/latest";
    private const string ExpectedAssetName = "TokenMiharibanSetup.exe";
    private static readonly HttpClient Client = CreateClient();

    public static Version CurrentVersion => Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 1, 0);

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("TokenMihariban-Windows/0.1");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    public static async Task<AppRelease?> CheckAsync()
    {
        using var response = await Client.GetAsync(LatestReleaseApi).ConfigureAwait(false);
        if ((int)response.StatusCode == 404) return null;
        response.EnsureSuccessStatusCode();

        await using var stream = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
        using var document = await JsonDocument.ParseAsync(stream).ConfigureAwait(false);
        var root = document.RootElement;
        var tag = root.GetProperty("tag_name").GetString() ?? "";
        if (!TryParseVersion(tag, out var version) || version <= CurrentVersion) return null;

        var pageUrl = root.GetProperty("html_url").GetString() ?? "https://github.com/yoyoi441/AI-/releases";
        var notes = root.TryGetProperty("body", out var body) ? body.GetString() ?? "" : "";
        string? installerUrl = null;
        string? sha256 = null;
        if (root.TryGetProperty("assets", out var assets))
        {
            foreach (var asset in assets.EnumerateArray())
            {
                if (!string.Equals(asset.GetProperty("name").GetString(), ExpectedAssetName, StringComparison.OrdinalIgnoreCase)) continue;
                installerUrl = asset.GetProperty("browser_download_url").GetString();
                if (asset.TryGetProperty("digest", out var digestElement))
                {
                    var digest = digestElement.GetString();
                    if (digest?.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) == true) sha256 = digest[7..];
                }
                break;
            }
        }
        return new AppRelease(version, tag, pageUrl, installerUrl, sha256, notes);
    }

    public static async Task<string> DownloadInstallerAsync(AppRelease release)
    {
        if (release.InstallerUrl is null) throw new InvalidOperationException("Installer asset is missing.");
        if (!Uri.TryCreate(release.InstallerUrl, UriKind.Absolute, out var uri) ||
            uri.Scheme != Uri.UriSchemeHttps || !uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException("Unexpected update download URL.");
        }

        var updateDirectory = Path.Combine(Path.GetTempPath(), "TokenMihariban", "updates", release.Tag);
        Directory.CreateDirectory(updateDirectory);
        var destination = Path.Combine(updateDirectory, ExpectedAssetName);
        using var response = await Client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead).ConfigureAwait(false);
        response.EnsureSuccessStatusCode();
        await using var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
        await using var output = File.Create(destination);
        await input.CopyToAsync(output).ConfigureAwait(false);
        await output.FlushAsync().ConfigureAwait(false);
        output.Close();
        if (release.Sha256 is { Length: > 0 })
        {
            await using var verifyStream = File.OpenRead(destination);
            var actual = Convert.ToHexString(await SHA256.HashDataAsync(verifyStream).ConfigureAwait(false)).ToLowerInvariant();
            if (!actual.Equals(release.Sha256, StringComparison.OrdinalIgnoreCase))
            {
                File.Delete(destination);
                throw new InvalidOperationException("Downloaded installer checksum did not match the GitHub release.");
            }
        }
        return destination;
    }

    public static void StartInstaller(string path)
    {
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    private static bool TryParseVersion(string tag, out Version version)
    {
        var normalized = tag.Trim().TrimStart('v', 'V');
        var separator = normalized.IndexOfAny(new[] { '-', '+' });
        if (separator >= 0) normalized = normalized[..separator];
        return Version.TryParse(normalized, out version!);
    }
}
