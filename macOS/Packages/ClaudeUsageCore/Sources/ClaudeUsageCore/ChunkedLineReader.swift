import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads a file line-by-line in small bounded chunks, instead of loading the whole file
/// into memory as a single `Data`/`String` pair before splitting it into lines.
///
/// Both `JSONLParser` and `CodexJSONLParser` used to do the latter: read everything from
/// the resume offset to EOF in one `readDataToEndOfFile()` call, then convert that whole
/// span to a `String` before enumerating lines. That's fine for the small, frequent
/// incremental reads that happen while the app is running, but a *fresh launch* resumes
/// from offset 0 and re-parses full history — and some logs get large (Codex rollout
/// files in particular can run into the hundreds of MB for one file). Materializing a
/// 450MB file as Data-then-String at once meant that single file alone could account for
/// close to a gigabyte of transient memory, which is what was driving this app's RSS into
/// the gigabytes shortly after launch.
///
/// This reads via the raw POSIX `read(2)` into a single reused `[UInt8]` buffer rather
/// than `FileHandle.read(upToCount:)` deliberately: an earlier version built on
/// `FileHandle`/`Data` still left the process holding onto roughly one full chunk's worth
/// of memory *per chunk ever read* — every `Data` `FileHandle` handed back stayed live
/// somewhere in Foundation's own bookkeeping regardless of what this code did with it
/// (copying the bytes elsewhere didn't help), so a large file read in many chunks ended
/// up pinning memory proportional to the *whole file*, defeating the point of chunking.
/// Plain `[UInt8]`/`Array` has none of `Data`/`NSData`'s bridging or caching behavior, so
/// there's nothing left implicitly holding a chunk alive once this function is done with
/// it — the working set stays bounded to one chunk's worth of bytes, as intended.
enum ChunkedLineReader {
    static let defaultChunkSize = 1 << 20 // 1 MB

    /// Invokes `body` once per complete line (one ending in `\n`) found from `byteOffset`
    /// onward. A trailing partial line — still being appended to by the process that owns
    /// the file — is left unread, exactly as the whole-file version did, so it's never
    /// split across two calls. Returns the byte offset to resume from next time.
    static func forEachLine(
        at url: URL,
        fromByteOffset byteOffset: UInt64,
        chunkSize: Int = defaultChunkSize,
        body: (String) -> Void
    ) throws -> UInt64 {
        // `FileHandle` is used only to open/seek/close (its own variadic-free API for
        // those); the actual reading below goes straight through the POSIX `read(2)`
        // syscall on its file descriptor rather than `FileHandle.read(upToCount:)` — see
        // the type-level doc comment for why.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: byteOffset)
        let fd = handle.fileDescriptor

        let newline: UInt8 = 0x0A
        var offset = byteOffset
        var pending: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        readLoop: while true {
            let bytesRead = buffer.withUnsafeMutableBytes { raw -> Int in
                read(fd, raw.baseAddress, chunkSize)
            }
            guard bytesRead > 0 else { break readLoop }

            pending.append(contentsOf: buffer[0..<bytesRead])

            while let newlineIndex = pending.firstIndex(of: newline) {
                autoreleasepool {
                    let line = String(decoding: pending[pending.startIndex..<newlineIndex], as: UTF8.self)
                    body(line)
                }
                offset += UInt64(newlineIndex - pending.startIndex + 1)
                pending.removeSubrange(pending.startIndex...newlineIndex)
            }
        }

        return offset
    }
}
