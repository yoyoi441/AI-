import Foundation
import CoreServices

/// Recursively watches a log directory with one FSEvents stream.
///
/// The previous kqueue implementation kept one file descriptor open for every folder
/// and every JSONL file. A long-lived Claude/Codex installation can contain thousands
/// of transcripts, which exhausted the per-process descriptor limit during launch and
/// caused unrelated operations (network pipes and even system UI resources) to fail.
/// FSEvents watches the whole subtree without holding each file open.
final class FileSystemWatcher {
    private let queue = DispatchQueue(label: "com.yoyoi441.TokenMihariban.fswatch")
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pendingRefresh: DispatchWorkItem?

    init(rootDirectory: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        )
        stream = FSEventStreamCreate(
            nil,
            tokenMiharibanFSEventCallback,
            &context,
            [rootDirectory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)
        }
    }

    fileprivate func fileSystemDidChange() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pendingRefresh = work
        queue.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    deinit {
        pendingRefresh?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
        }
    }
}

private let tokenMiharibanFSEventCallback: FSEventStreamCallback = {
    _, info, _, _, _, _ in
    guard let info else { return }
    Unmanaged<FileSystemWatcher>.fromOpaque(info).takeUnretainedValue().fileSystemDidChange()
}
