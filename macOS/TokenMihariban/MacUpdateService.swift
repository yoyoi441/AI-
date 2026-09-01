import AppKit
import CryptoKit
import Foundation

struct MacAppRelease: Sendable {
    let version: String
    let tag: String
    let downloadURL: URL
    let sha256: String?
}

enum MacUpdateError: LocalizedError {
    case invalidRelease
    case missingAsset
    case invalidDownloadURL
    case checksumMismatch
    case invalidApplication
    case destinationNotWritable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRelease: return "リリース情報を読み取れませんでした。"
        case .missingAsset: return "Mac版の更新ファイルが見つかりません。"
        case .invalidDownloadURL: return "更新ファイルのURLが正しくありません。"
        case .checksumMismatch: return "更新ファイルの検証に失敗しました。"
        case .invalidApplication: return "更新ファイルにトークン見張り番が含まれていません。"
        case .destinationNotWritable: return "現在のアプリの保存場所へ書き込めません。アプリをユーザーのApplicationsフォルダへ移動してからお試しください。"
        case .commandFailed(let message): return message
        }
    }
}

enum MacUpdateService {
    static let repositoryReleasesURL = URL(string: "https://github.com/yoyoi441/AI-/releases")!
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/yoyoi441/AI-/releases/latest")!
    private static let expectedAssetName = "TokenMihariban-macOS.zip"
    private static let expectedBundleIdentifier = "com.yoyoi441.TokenMihariban"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func checkForUpdate() async throws -> MacAppRelease? {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("TokenMihariban-macOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MacUpdateError.invalidRelease
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = normalizedVersion(release.tagName)
        guard compareVersions(version, currentVersion) == .orderedDescending else { return nil }
        guard let asset = release.assets.first(where: { $0.name == expectedAssetName }) else {
            throw MacUpdateError.missingAsset
        }
        guard let url = URL(string: asset.browserDownloadURL), url.scheme == "https", url.host == "github.com" else {
            throw MacUpdateError.invalidDownloadURL
        }
        let digest = asset.digest?.hasPrefix("sha256:") == true ? String(asset.digest!.dropFirst(7)) : nil
        return MacAppRelease(version: version, tag: release.tagName, downloadURL: url, sha256: digest)
    }

    @MainActor
    static func downloadAndInstall(_ release: MacAppRelease) async throws {
        let fm = FileManager.default
        let updateRoot = fm.temporaryDirectory
            .appendingPathComponent("TokenMihariban", isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
            .appendingPathComponent(release.tag, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: updateRoot, withIntermediateDirectories: true)

        let (downloadedURL, response) = try await URLSession.shared.download(from: release.downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MacUpdateError.invalidRelease
        }
        let archiveURL = updateRoot.appendingPathComponent(expectedAssetName)
        try fm.moveItem(at: downloadedURL, to: archiveURL)
        if let expected = release.sha256, try sha256(of: archiveURL) != expected.lowercased() {
            throw MacUpdateError.checksumMismatch
        }

        let extractedURL = updateRoot.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractedURL, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractedURL.path])

        let replacementURL = extractedURL.appendingPathComponent("TokenMihariban.app", isDirectory: true)
        guard let replacementBundle = Bundle(url: replacementURL),
              replacementBundle.bundleIdentifier == expectedBundleIdentifier else {
            throw MacUpdateError.invalidApplication
        }

        let currentURL = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let parentURL = currentURL.deletingLastPathComponent()
        guard currentURL.pathExtension == "app", fm.isWritableFile(atPath: parentURL.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([replacementURL])
            throw MacUpdateError.destinationNotWritable
        }

        let updaterURL = updateRoot.appendingPathComponent("install-update.zsh")
        try updaterScript.write(to: updaterURL, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: updaterURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [updaterURL.path, currentURL.path, replacementURL.path, String(ProcessInfo.processInfo.processIdentifier)]
        try process.run()
        NSApp.terminate(nil)
    }

    private static let updaterScript = """
    #!/bin/zsh
    set -eu
    target="$1"
    replacement="$2"
    app_pid="$3"
    backup="${target}.previous"
    while kill -0 "$app_pid" 2>/dev/null; do sleep 0.2; done
    /bin/rm -rf "$backup"
    /bin/mv "$target" "$backup"
    if /bin/mv "$replacement" "$target"; then
      /usr/bin/open "$target"
      /bin/rm -rf "$backup"
    else
      /bin/mv "$backup" "$target"
      /usr/bin/open "$target"
      exit 1
    fi
    """

    private static func run(_ executable: String, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardError = errorPipe
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let message = String(data: data, encoding: .utf8) ?? "更新ファイルを展開できませんでした。"
                    continuation.resume(throwing: MacUpdateError.commandFailed(message))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizedVersion(_ tag: String) -> String {
        String(tag.trimmingCharacters(in: .whitespacesAndNewlines).drop(while: { $0 == "v" || $0 == "V" }))
            .split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? tag
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: .numeric)
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let assets: [GitHubAsset]
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", assets }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String
        let digest: String?
        enum CodingKeys: String, CodingKey {
            case name, digest
            case browserDownloadURL = "browser_download_url"
        }
    }
}
