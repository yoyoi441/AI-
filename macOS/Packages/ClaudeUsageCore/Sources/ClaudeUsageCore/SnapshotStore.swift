import Foundation

/// Shares the computed `UsageSnapshot` between the main app (which parses the logs)
/// and the widget extension (which is sandboxed and only ever reads this file) via
/// an App Group container.
public enum SnapshotStore {
    public static let appGroupIdentifier = "group.com.yoyoi441.TokenMihariban"

    public enum SnapshotStoreError: Error {
        case appGroupContainerUnavailable
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private static var snapshotURL: URL? {
        containerURL?.appendingPathComponent("usage-snapshot.json")
    }

    private static var codexSnapshotURL: URL? {
        containerURL?.appendingPathComponent("codex-snapshot.json")
    }

    private static var languageURL: URL? {
        containerURL?.appendingPathComponent("app-language.txt")
    }

    private static var widgetProviderURL: URL? {
        containerURL?.appendingPathComponent("widget-provider.txt")
    }

    private static var widgetMetricURL: URL? {
        containerURL?.appendingPathComponent("widget-metric.txt")
    }

    public static func writeSnapshot(_ snapshot: UsageSnapshot) throws {
        guard let url = snapshotURL else { throw SnapshotStoreError.appGroupContainerUnavailable }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public static func readSnapshot() -> UsageSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    public static func writeCodexSnapshot(_ snapshot: CodexSnapshot) throws {
        guard let url = codexSnapshotURL else { throw SnapshotStoreError.appGroupContainerUnavailable }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    public static func readCodexSnapshot() -> CodexSnapshot? {
        guard let url = codexSnapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexSnapshot.self, from: data)
    }

    /// Plain text file (not JSON, not UserDefaults) so the widget extension — a
    /// separate sandboxed process — can pick up the language the main app is
    /// currently set to without needing an App Group UserDefaults suite (see the
    /// note on `GaugeAppearance` for why that combination is avoided here).
    public static func writeLanguage(_ language: AppLanguage) throws {
        guard let url = languageURL else { throw SnapshotStoreError.appGroupContainerUnavailable }
        try language.rawValue.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func readLanguage() -> AppLanguage {
        guard let url = languageURL, let raw = try? String(contentsOf: url, encoding: .utf8) else { return .japanese }
        return AppLanguage(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .japanese
    }

    /// What the small iOS home screen widget shows — same App-Group-file mechanism as
    /// `writeLanguage`/`readLanguage` above, and for the same reason (no UserDefaults
    /// suite shared between app and widget extension here).
    public static func writeWidgetProvider(_ provider: WidgetProvider) throws {
        guard let url = widgetProviderURL else { throw SnapshotStoreError.appGroupContainerUnavailable }
        try provider.rawValue.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func readWidgetProvider() -> WidgetProvider {
        guard let url = widgetProviderURL, let raw = try? String(contentsOf: url, encoding: .utf8) else { return .claude }
        return WidgetProvider(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .claude
    }

    public static func writeWidgetMetric(_ metric: GaugeMetric) throws {
        guard let url = widgetMetricURL else { throw SnapshotStoreError.appGroupContainerUnavailable }
        try metric.rawValue.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func readWidgetMetric() -> GaugeMetric {
        guard let url = widgetMetricURL, let raw = try? String(contentsOf: url, encoding: .utf8) else { return .timeRemaining }
        return GaugeMetric(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .timeRemaining
    }
}
