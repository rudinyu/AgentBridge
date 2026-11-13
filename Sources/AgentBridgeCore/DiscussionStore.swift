import Darwin
import Foundation

/// Stores bounded app-owned discussion transcripts separately from Git sessions
/// and provider-native conversation files.
public final class DiscussionStore: @unchecked Sendable {
    public static let maximumDiscussions = 64
    public static let maximumTurnsPerDiscussion = 256
    public static let maximumTurnsPerHandoff = 40
    public static let maximumHandoffsPerDiscussion = 4
    public static let maximumTextBytes = 64 * 1_024
    public static let maximumRecordBytes = 4 * 1_024 * 1_024

    public let rootURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let lock = NSLock()

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/"), !rootURL.path.contains("\0") else {
            throw AgentBridgeError.invalidInput("Discussion storage requires an absolute local path.")
        }
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        do {
            try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        } catch {
            throw AgentBridgeError.persistence("Could not create discussion storage.")
        }
        let directoryDescriptor = Self.openDirectory(self.rootURL.path)
        guard directoryDescriptor >= 0 else {
            throw AgentBridgeError.persistence("Discussion storage is unavailable or is a symbolic link.")
        }
        defer { _ = close(directoryDescriptor) }
        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid(),
              fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
            throw AgentBridgeError.persistence("Could not secure discussion storage.")
        }
        let lockDescriptor = Self.lockFileName.withCString {
            openat(directoryDescriptor, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard lockDescriptor >= 0 else {
            throw AgentBridgeError.persistence("Could not create the discussion-storage lock.")
        }
        defer { _ = close(lockDescriptor) }
        var lockInfo = stat()
        guard fstat(lockDescriptor, &lockInfo) == 0,
              (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              lockInfo.st_uid == getuid(),
              lockInfo.st_nlink == 1,
              fchmod(lockDescriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("Discussion-storage lock is not a private regular file.")
        }
    }

    public func list() throws -> [DiscussionRecord] {
        try withLockedDirectory(exclusive: false) { directoryDescriptor in
            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: rootURL.path)
            } catch {
                throw AgentBridgeError.persistence("Could not list discussion storage.")
            }
            let recordNames = names.filter { Self.recordID(from: $0) != nil }
            guard recordNames.count <= Self.maximumDiscussions else {
                throw AgentBridgeError.persistence("Discussion storage contains more records than the configured limit.")
            }
            return try recordNames.compactMap { name in
                guard let id = Self.recordID(from: name) else { return nil }
                return try readRecord(id: id, directoryDescriptor: directoryDescriptor)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    public func record(id: UUID) throws -> DiscussionRecord? {
        try withLockedDirectory(exclusive: false) { directoryDescriptor in
            try readRecord(id: id, directoryDescriptor: directoryDescriptor)
        }
    }

    @discardableResult
    public func create(_ record: DiscussionRecord) throws -> DiscussionRecord {
        let normalized = try Self.normalized(record)
        try withLockedDirectory(exclusive: true) { directoryDescriptor in
            let name = Self.filename(for: normalized.id)
            var existingInfo = stat()
            guard fstatat(directoryDescriptor, name, &existingInfo, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                throw AgentBridgeError.persistence("A discussion with this identifier already exists.")
            }
            let count = try Self.recordCount(fileManager: fileManager, rootPath: rootURL.path)
            guard count < Self.maximumDiscussions else {
                throw AgentBridgeError.persistence("Discussion storage has reached its record limit.")
            }
            try writeRecord(normalized, directoryDescriptor: directoryDescriptor)
        }
        return normalized
    }

    @discardableResult
    public func save(_ record: DiscussionRecord) throws -> DiscussionRecord {
        let normalized = try Self.normalized(record)
        try withLockedDirectory(exclusive: true) { directoryDescriptor in
            let name = Self.filename(for: normalized.id)
            var existingInfo = stat()
            if fstatat(directoryDescriptor, name, &existingInfo, AT_SYMLINK_NOFOLLOW) == 0 {
                guard (existingInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), existingInfo.st_uid == getuid() else {
                    throw AgentBridgeError.persistence("Discussion record is not a private regular file.")
                }
            } else if errno == ENOENT {
                let count = try Self.recordCount(fileManager: fileManager, rootPath: rootURL.path)
                guard count < Self.maximumDiscussions else {
                    throw AgentBridgeError.persistence("Discussion storage has reached its record limit.")
                }
            } else {
                throw AgentBridgeError.persistence("Could not inspect discussion record.")
            }
            try writeRecord(normalized, directoryDescriptor: directoryDescriptor)
        }
        return normalized
    }

    /// Deletes the record of `id`. Returns false when there is none.
    @discardableResult
    public func remove(id: UUID) throws -> Bool {
        try withLockedDirectory(exclusive: true) { directoryDescriptor in
            let name = Self.filename(for: id)
            var info = stat()
            guard fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                guard errno == ENOENT else { throw AgentBridgeError.persistence("Could not inspect discussion record.") }
                return false
            }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_uid == getuid() else {
                throw AgentBridgeError.persistence("Discussion record is not a private regular file.")
            }
            guard unlinkat(directoryDescriptor, name, 0) == 0 else {
                throw AgentBridgeError.persistence("Could not remove the discussion record.")
            }
            guard fsync(directoryDescriptor) == 0 else { throw AgentBridgeError.persistence("Could not sync discussion storage.") }
            return true
        }
    }

    /// Leaves room for the bounded assistant response before provider I/O, so
    /// a successful response cannot force old transcript text out of storage.
    func ensureRunCompletionFits(_ record: DiscussionRecord) throws {
        let normalized = try Self.normalized(record)
        let data: Data
        do { data = try encoder.encode(normalized) }
        catch { throw AgentBridgeError.persistence("Could not estimate discussion completion storage.") }
        let worstCaseAssistantReserve = Self.maximumTextBytes * 6 + 2_048
        guard data.count <= Self.maximumRecordBytes - worstCaseAssistantReserve else {
            throw AgentBridgeError.persistence("Discussion storage is full; the original transcript is kept. Start a new discussion and send again.")
        }
    }

    private func readRecord(id: UUID, directoryDescriptor: Int32) throws -> DiscussionRecord? {
        let name = Self.filename(for: id)
        let descriptor = name.withCString { openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw AgentBridgeError.persistence("Discussion record is unavailable or is a symbolic link.")
        }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= Self.maximumRecordBytes else {
            throw AgentBridgeError.persistence("Discussion record is not a bounded private regular file.")
        }
        var data = Data()
        let chunkSize = 64 * 1_024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let amount = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if amount == 0 { break }
            guard amount > 0, data.count + amount <= Self.maximumRecordBytes else {
                throw AgentBridgeError.persistence("Discussion record could not be read within its size limit.")
            }
            data.append(contentsOf: buffer.prefix(amount))
        }
        do {
            let record = try decoder.decode(DiscussionRecord.self, from: data)
            guard record.id == id else { throw AgentBridgeError.persistence("Discussion record identity is invalid.") }
            try Self.validatePersisted(record)
            return record
        } catch let error as AgentBridgeError {
            throw error
        } catch {
            throw AgentBridgeError.persistence("Discussion record is malformed.")
        }
    }

    private func writeRecord(_ record: DiscussionRecord, directoryDescriptor: Int32) throws {
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw AgentBridgeError.persistence("Could not encode discussion record.")
        }
        guard data.count <= Self.maximumRecordBytes else {
            throw AgentBridgeError.persistence("Discussion record exceeds its storage limit.")
        }
        let destinationName = Self.filename(for: record.id)
        var destinationInfo = stat()
        if fstatat(directoryDescriptor, destinationName, &destinationInfo, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (destinationInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  destinationInfo.st_uid == getuid(), destinationInfo.st_nlink == 1 else {
                throw AgentBridgeError.persistence("Discussion record is not a private regular file.")
            }
        } else if errno != ENOENT {
            throw AgentBridgeError.persistence("Could not inspect discussion destination.")
        }

        let temporaryName = ".\(record.id.uuidString.lowercased()).\(UUID().uuidString.lowercased()).tmp"
        let descriptor = temporaryName.withCString {
            openat(directoryDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw AgentBridgeError.persistence("Could not create a discussion record safely.") }
        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary {
                temporaryName.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
            }
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("Temporary discussion file is not private.")
        }
        try Self.writeAll(data, descriptor: descriptor)
        guard fsync(descriptor) == 0 else { throw AgentBridgeError.persistence("Could not sync discussion record.") }
        guard renameat(directoryDescriptor, temporaryName, directoryDescriptor, destinationName) == 0 else {
            throw AgentBridgeError.persistence("Could not replace discussion record safely.")
        }
        shouldRemoveTemporary = false
        guard fsync(directoryDescriptor) == 0 else { throw AgentBridgeError.persistence("Could not sync discussion storage.") }
    }

    private func withLockedDirectory<T>(exclusive: Bool, _ operation: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let directoryDescriptor = Self.openDirectory(rootURL.path)
        guard directoryDescriptor >= 0 else { throw AgentBridgeError.persistence("Discussion storage is unavailable.") }
        defer { _ = close(directoryDescriptor) }
        return try PrivateLockFile.withLock(
            named: Self.lockFileName,
            in: directoryDescriptor,
            create: false,
            exclusive: exclusive,
            error: { failure in
                switch failure {
                case .unavailable: AgentBridgeError.persistence("Discussion-storage lock is unavailable.")
                case .notPrivateFile: AgentBridgeError.persistence("Discussion-storage lock is invalid.")
                case .lockFailed: AgentBridgeError.persistence("Could not lock discussion storage.")
                }
            }
        ) { try operation(directoryDescriptor) }
    }

    private static func normalized(_ input: DiscussionRecord) throws -> DiscussionRecord {
        guard input.revision > 0, input.dataRootPath.hasPrefix("/"),
              input.dataRootPath.utf8.count <= 4_096, !input.dataRootPath.contains("\0"),
              input.turns.count <= maximumTurnsPerDiscussion,
              input.handoffs.count <= maximumHandoffsPerDiscussion,
              input.linkedSessionIDs.count <= 64,
              input.usageProfileIDs.count <= 128,
              Set(input.turns.map(\.id)).count == input.turns.count,
              Set(input.handoffs.map(\.id)).count == input.handoffs.count,
              input.handoffs.allSatisfy({
                  $0.discussionID == input.id
                    && $0.discussionRevision > 0
                    && $0.discussionRevision <= input.revision
                    && $0.destinationPath.hasPrefix("/")
                    && $0.hasValidDigest()
                    && $0.selectedTurns.count <= maximumTurnsPerHandoff
              }) else {
            throw AgentBridgeError.invalidInput("Discussion record exceeds its bounds or contains invalid identity data.")
        }
        var record = input
        record.turns = try record.turns.map { turn in
            DiscussionTurn(
                id: turn.id,
                timestamp: turn.timestamp,
                provider: turn.provider,
                accountProfileID: turn.accountProfileID,
                sourceSharedMemoryConsent: turn.sourceSharedMemoryConsent,
                isShareable: turn.isShareable,
                userText: try redactedWithoutTruncation(turn.userText),
                assistantText: try turn.assistantText.map(redactedWithoutTruncation)
            )
        }
        record.handoffs = try record.handoffs.map { handoff in
            DiscussionProjectHandoff(
                id: handoff.id,
                discussionID: handoff.discussionID,
                discussionRevision: handoff.discussionRevision,
                destinationPath: handoff.destinationPath,
                mode: handoff.mode,
                targetProvider: handoff.targetProvider,
                targetProfileID: handoff.targetProfileID,
                accessMode: handoff.accessMode,
                expectedRepositoryCommit: handoff.expectedRepositoryCommit,
                selectedTurns: try handoff.selectedTurns.map { turn in
                    DiscussionHandoffTurn(
                        id: turn.id,
                        timestamp: turn.timestamp,
                        provider: turn.provider,
                        sourceAccountProfileID: turn.sourceAccountProfileID,
                        userText: try redactedWithoutTruncation(turn.userText),
                        assistantText: try redactedWithoutTruncation(turn.assistantText)
                    )
                },
                consumedSessionID: handoff.consumedSessionID
            )
        }
        guard record.handoffs.allSatisfy({ $0.hasValidDigest() }) else {
            throw AgentBridgeError.invalidInput("Discussion project handoff digest is invalid.")
        }
        return record
    }

    private static func validatePersisted(_ record: DiscussionRecord) throws {
        guard record.revision > 0,
              record.dataRootPath.hasPrefix("/"),
              record.dataRootPath.utf8.count <= 4_096,
              record.turns.count <= maximumTurnsPerDiscussion,
              record.handoffs.count <= maximumHandoffsPerDiscussion,
              record.usageProfileIDs.count <= 128,
              Set(record.turns.map(\.id)).count == record.turns.count,
              Set(record.linkedSessionIDs).count == record.linkedSessionIDs.count,
              record.handoffs.allSatisfy({
                  $0.discussionID == record.id
                    && $0.discussionRevision > 0
                    && $0.discussionRevision <= record.revision
                    && $0.destinationPath.hasPrefix("/")
                    && $0.hasValidDigest()
                    && $0.selectedTurns.count <= maximumTurnsPerHandoff
              }),
              record.turns.allSatisfy({
                  $0.userText.utf8.count <= maximumTextBytes
                    && ($0.assistantText?.utf8.count ?? 0) <= maximumTextBytes
                    && OutputRedactor.redact($0.userText) == $0.userText
                    && ($0.assistantText.map { OutputRedactor.redact($0) } == $0.assistantText)
              }),
              record.handoffs.allSatisfy({
                  $0.hasValidDigest()
                    && $0.selectedTurns.count <= maximumTurnsPerHandoff
                    && $0.selectedTurns.allSatisfy {
                        $0.userText.utf8.count <= maximumTextBytes
                            && $0.assistantText.utf8.count <= maximumTextBytes
                            && OutputRedactor.redact($0.userText) == $0.userText
                            && OutputRedactor.redact($0.assistantText) == $0.assistantText
                    }
              }) else {
            throw AgentBridgeError.persistence("Discussion record failed validation.")
        }
    }

    private static func redactedWithoutTruncation(_ text: String) throws -> String {
        let redacted = OutputRedactor.redact(text)
        guard redacted.utf8.count <= maximumTextBytes else {
            throw AgentBridgeError.invalidInput("Discussion text exceeds the \(maximumTextBytes)-byte per-message storage limit; the original text was not shortened.")
        }
        return redacted
    }

    private static func recordCount(fileManager: FileManager, rootPath: String) throws -> Int {
        let names: [String]
        do { names = try fileManager.contentsOfDirectory(atPath: rootPath) }
        catch { throw AgentBridgeError.persistence("Could not inspect discussion storage.") }
        let count = names.filter { recordID(from: $0) != nil }.count
        guard count <= maximumDiscussions else {
            throw AgentBridgeError.persistence("Discussion storage contains more records than the configured limit.")
        }
        return count
    }

    private static func recordID(from filename: String) -> UUID? {
        guard filename.hasSuffix(".json") else { return nil }
        let stem = String(filename.dropLast(".json".count))
        guard let id = UUID(uuidString: stem), filename == Self.filename(for: id) else { return nil }
        return id
    }

    private static func filename(for id: UUID) -> String { "\(id.uuidString.lowercased()).json" }
    private static let lockFileName = ".lock"

    private static func openDirectory(_ path: String) -> Int32 {
        path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let amount = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                guard amount > 0 else { throw AgentBridgeError.persistence("Could not write discussion record.") }
                offset += amount
            }
        }
    }
}
