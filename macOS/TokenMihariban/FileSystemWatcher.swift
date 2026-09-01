import Foundation

/// Watches `~/.claude/projects` (and everything under it) for changes using kqueue-based
/// `DispatchSource` file descriptors, so new Claude Code activity is picked up within
/// roughly a second — instead of waiting for the next timed poll.
///
/// `DispatchSource` only reports events on the exact path it's watching, and a write to
/// an existing file doesn't touch its parent directory's own change event. So this
/// watches every directory (for new subdirectories/files appearing) and every `.jsonl`
/// file (for appended lines) individually, growing the watch set as new entries appear.
final class FileSystemWatcher {
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private let queue = DispatchQueue(label: "com.yoyoi441.TokenMihariban.fswatch")
    private let onChange: () -> Void

    init(rootDirectory: URL, onChange: @escaping () -> Void) {
        self.onChange = onChange
        queue.async { [weak self] in
            self?.watch(directory: rootDirectory)
        }
    }

    deinit {
        sources.values.forEach { $0.cancel() }
    }

    private func watch(directory: URL) {
        guard sources[directory.path] == nil else { return }
        addWatcher(for: directory, eventMask: [.write]) { [weak self] in
            self?.rescan(directory: directory)
        }
        rescan(directory: directory)
    }

    private func rescan(directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for entry in entries {
            guard sources[entry.path] == nil else { continue }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                watch(directory: entry)
            } else if entry.pathExtension == "jsonl" {
                addWatcher(for: entry, eventMask: [.write, .extend]) { [weak self] in
                    self?.onChange()
                }
            }
        }
    }

    private func addWatcher(for url: URL, eventMask: DispatchSource.FileSystemEvent, handler: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: eventMask, queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        sources[url.path] = source
    }
}
