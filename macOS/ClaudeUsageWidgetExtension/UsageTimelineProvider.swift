import WidgetKit
import ClaudeUsageCore

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot
    let codexSnapshot: CodexSnapshot
    let language: AppLanguage
}

/// Only ever reads the snapshots the main app already computed and wrote to the
/// App Group container — the widget extension is sandboxed and never parses the
/// Claude Code / Codex CLI logs itself, to stay within WidgetKit's tight time/memory
/// budget.
struct UsageTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .empty, codexSnapshot: .empty, language: .japanese)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = currentEntry()
        // The main app calls WidgetCenter.reloadAllTimelines() after every poll for
        // near-immediate updates while it's running; this periodic reload is the
        // fallback for whenever it isn't.
        let timeline = Timeline(entries: [entry], policy: .after(entry.date.addingTimeInterval(15 * 60)))
        completion(timeline)
    }

    private func currentEntry() -> UsageEntry {
        UsageEntry(
            date: Date(),
            snapshot: SnapshotStore.readSnapshot() ?? .empty,
            codexSnapshot: SnapshotStore.readCodexSnapshot() ?? .empty,
            language: SnapshotStore.readLanguage()
        )
    }
}
