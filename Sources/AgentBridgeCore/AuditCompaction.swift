import Darwin
import Foundation

/// Rewrites the session index and a session's audit file so neither can grow until
/// it hits its size limit. Both rewrites replace the file atomically, so a crash
/// leaves either the old file or the new one, never a half-written one. Callers
/// hold the store's exclusive lock.
enum AuditCompaction {
    /// How much of a bulky `run.output` message is kept once a newer output exists.
    static let keptOutputCharacters = 1_024
    static let trimmedOutputNotice = "… [older output trimmed to keep the audit file within its size limit]"

    /// What identifies a version of a file well enough to know whether another
    /// process changed it: its inode, size and modification time.
    struct FileSignature: Equatable {
        let inode: UInt64
        let size: Int
        let seconds: Int
        let nanoseconds: Int
    }

    static func signature(of url: URL) -> FileSignature? {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return nil }
        return FileSignature(
            inode: UInt64(metadata.st_ino),
            size: Int(metadata.st_size),
            seconds: Int(metadata.st_mtimespec.tv_sec),
            nanoseconds: Int(metadata.st_mtimespec.tv_nsec)
        )
    }

    /// The newest record of each session, oldest first. A record wins over an
    /// earlier one with the same or an older `updatedAt`, as when the index is read.
    static func latestSessions(in data: Data, decoder: JSONDecoder) -> [UUID: SessionRecord] {
        var latest: [UUID: SessionRecord] = [:]
        for line in data.split(separator: 0x0A) {
            guard let session = try? decoder.decode(SessionRecord.self, from: Data(line)) else { continue }
            if (latest[session.id]?.updatedAt ?? .distantPast) <= session.updatedAt {
                latest[session.id] = session
            }
        }
        return latest
    }

    /// Replaces the session index with one line per session.
    static func compactSessionIndex(at url: URL, decoder: JSONDecoder, encoder: JSONEncoder) throws {
        let data = try Data(contentsOf: url)
        let latest = latestSessions(in: data, decoder: decoder)
        var output = Data()
        for session in latest.values.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            output.append(try encoder.encode(session))
            output.append(0x0A)
        }
        try replaceAtomically(url, with: output)
    }

    /// Shortens the text of every `run.output` event except the newest one. Every
    /// event is kept, because the local usage counters read their kinds and
    /// timestamps. Lines that need no change are written back byte for byte.
    /// Returns how many bytes the file shrank by.
    @discardableResult
    static func trimOldOutputs(inEventsAt url: URL, decoder: JSONDecoder, encoder: JSONEncoder) throws -> Int {
        let data = try Data(contentsOf: url)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        var lastOutputIndex: Int?
        for (index, line) in lines.enumerated() {
            if let event = try? decoder.decode(AuditEvent.self, from: line), event.kind == "run.output" { lastOutputIndex = index }
        }
        var output = Data()
        for (index, line) in lines.enumerated() {
            if index != lastOutputIndex,
               let event = try? decoder.decode(AuditEvent.self, from: line),
               event.kind == "run.output",
               event.message.count > keptOutputCharacters + trimmedOutputNotice.count {
                let trimmed = AuditEvent(
                    id: event.id,
                    timestamp: event.timestamp,
                    sessionID: event.sessionID,
                    kind: event.kind,
                    message: String(event.message.prefix(keptOutputCharacters)) + trimmedOutputNotice
                )
                output.append(try encoder.encode(trimmed))
            } else {
                output.append(line)
            }
            output.append(0x0A)
        }
        guard output.count < data.count else { return 0 }
        try replaceAtomically(url, with: output)
        return data.count - output.count
    }

    /// Writes `data` to a private temporary file next to `url`, flushes it, and
    /// renames it over `url`.
    static func replaceAtomically(_ url: URL, with data: Data) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).compact-\(UUID().uuidString.lowercased())")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AgentBridgeError.persistence("Could not compact the audit file.") }
        var committed = false
        defer {
            _ = close(descriptor)
            if !committed { unlink(temporary.path) }
        }
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes in
                write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw AgentBridgeError.persistence("Could not compact the audit file.")
            }
            offset += written
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            throw AgentBridgeError.persistence("Could not compact the audit file.")
        }
        committed = true
    }
}
