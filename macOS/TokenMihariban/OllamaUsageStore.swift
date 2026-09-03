import Foundation
import ClaudeUsageCore

final class OllamaUsageStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("TokenMihariban", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("ollama-usage.jsonl")
    }

    func load() -> [OllamaUsageEvent] {
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(OllamaUsageEvent.self, from: data)
        }
    }

    func append(_ event: OllamaUsageEvent) {
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { }
    }
}
