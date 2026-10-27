import CryptoKit
import Darwin
import Foundation

/// A repository identity for project memory. Commit hashes are deliberately
/// excluded from the key so handoffs for different commits remain searchable
/// under the same repository.
public struct ProjectMemoryRepositoryScope: Codable, Hashable, Sendable {
    public let key: String
    public let repositoryPath: String

    public init(repositoryPath: String) throws {
        guard repositoryPath.hasPrefix("/"), !repositoryPath.contains("\0") else {
            throw AgentBridgeError.invalidInput("Project memory requires an absolute repository path.")
        }

        let canonicalPath = URL(fileURLWithPath: repositoryPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard canonicalPath.hasPrefix("/"), canonicalPath.utf8.count <= ProjectMemoryStore.maximumRepositoryPathBytes else {
            throw AgentBridgeError.invalidInput("Project memory repository path is invalid or too long.")
        }

        self.repositoryPath = canonicalPath
        self.key = Self.makeKey(for: canonicalPath)
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case repositoryPath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedKey = try container.decode(String.self, forKey: .key)
        let decodedPath = try container.decode(String.self, forKey: .repositoryPath)
        let validated = try ProjectMemoryRepositoryScope(repositoryPath: decodedPath)
        guard decodedKey == validated.key, decodedPath == validated.repositoryPath else {
            throw DecodingError.dataCorruptedError(forKey: .key, in: container, debugDescription: "Project memory repository identity is invalid.")
        }
        self = validated
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(repositoryPath, forKey: .repositoryPath)
    }

    private static func makeKey(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One explicitly selected source memory turn copied into a commit handoff.
public struct ProjectMemoryHandoffTurn: Codable, Identifiable, Sendable {
    public let id: UUID
    public let provider: AgentProvider
    public let timestamp: Date
    public let userText: String
    public let assistantText: String
    public let wasTruncated: Bool

    fileprivate init(source: SharedMemoryTurn, userText: String, assistantText: String, wasTruncated: Bool) {
        self.id = source.id
        self.provider = source.provider
        self.timestamp = source.timestamp
        self.userText = userText
        self.assistantText = assistantText
        self.wasTruncated = wasTruncated
    }
}

/// A handoff summary retains source and target commits, and the provider/account
/// that explicitly initiated the carry-forward.
public struct ProjectMemoryHandoff: Codable, Identifiable, Sendable {
    public let id: UUID
    public let sourceCommit: String
    public let targetCommit: String
    public let provider: AgentProvider
    public let accountProfileID: UUID?
    public let createdAt: Date
    public let turns: [ProjectMemoryHandoffTurn]
    /// Nil means notes were not selected; an empty string means selected notes
    /// were empty in the source snapshot.
    public let notes: String?
    public let wasTruncated: Bool

    fileprivate init(
        id: UUID = UUID(),
        sourceCommit: String,
        targetCommit: String,
        provider: AgentProvider,
        accountProfileID: UUID?,
        createdAt: Date = Date(),
        turns: [ProjectMemoryHandoffTurn],
        notes: String?,
        wasTruncated: Bool
    ) {
        self.id = id
        self.sourceCommit = sourceCommit
        self.targetCommit = targetCommit
        self.provider = provider
        self.accountProfileID = accountProfileID
        self.createdAt = createdAt
        self.turns = turns
        self.notes = notes
        self.wasTruncated = wasTruncated
    }
}

/// Stores only app-owned memory explicitly selected for carry-forward. It does
/// not read provider transcript files or merge commit scopes automatically.
public final class ProjectMemoryStore: @unchecked Sendable {
    public static let maximumStoredBytes = 2 * 1_024 * 1_024
    public static let maximumStoredHandoffs = 96
    public static let maximumStoredRepositories = 64
    public static let maximumHandoffsPerRepository = 24
    public static let maximumTurnsPerHandoff = 40
    public static let maximumRepositoryPathBytes = 4_096

    private static let schemaVersion = 1
    private static let lockFileName = ".lock"
    private static let documentFileName = "handoffs.json"
    private static let maximumTextBytes = 8 * 1_024
    private static let maximumNotesBytes = 12 * 1_024
    private static let truncationMarker = "\n…[truncated]…\n"

    private let rootPath: String
    private let lock = NSLock()

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        let standardizedRootURL = rootURL.standardizedFileURL
        self.rootPath = standardizedRootURL.path
        do {
            try fileManager.createDirectory(at: standardizedRootURL, withIntermediateDirectories: true)
        } catch {
            throw Self.persistenceError("Could not create project-memory storage.")
        }

        let directoryDescriptor = Self.openDirectory(path: self.rootPath)
        guard directoryDescriptor >= 0 else {
            throw Self.persistenceError("Project-memory storage is unavailable or is a symbolic link.")
        }
        defer { _ = close(directoryDescriptor) }
        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid(),
              fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
            throw Self.persistenceError("Could not secure project-memory storage.")
        }

        let lockDescriptor = Self.lockFileName.withCString {
            openat(directoryDescriptor, $0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard lockDescriptor >= 0 else {
            throw Self.persistenceError("Could not create the project-memory lock.")
        }
        defer { _ = close(lockDescriptor) }
        var lockInfo = stat()
        guard fstat(lockDescriptor, &lockInfo) == 0,
              (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              lockInfo.st_uid == getuid(),
              lockInfo.st_nlink == 1,
              fchmod(lockDescriptor, mode_t(0o600)) == 0 else {
            throw Self.persistenceError("Project-memory lock is not a private regular file.")
        }
    }

    /// Copies only the requested turns and, when selected, the source notes.
    /// Missing or duplicate selected turn IDs fail closed instead of silently
    /// producing an incomplete handoff.
    @discardableResult
    public func carryForward(
        source: SharedMemorySnapshot,
        targetCommit: String,
        selectedTurnIDs: Set<UUID>,
        includeNotes: Bool,
        provider: AgentProvider,
        accountProfileID: UUID? = nil,
        knownSecrets: [String] = []
    ) throws -> ProjectMemoryHandoff {
        let repository = try ProjectMemoryRepositoryScope(repositoryPath: source.scope.repositoryPath)
        let normalizedTargetCommit = targetCommit.lowercased()
        guard Self.isValidCommit(normalizedTargetCommit) else {
            throw AgentBridgeError.invalidInput("Project-memory handoffs require a 40- or 64-character Git commit hash.")
        }
        guard selectedTurnIDs.count <= Self.maximumTurnsPerHandoff else {
            throw AgentBridgeError.invalidInput("A project-memory handoff can include at most \(Self.maximumTurnsPerHandoff) selected turns.")
        }
        guard knownSecrets.count <= 100,
              knownSecrets.allSatisfy({ $0.utf8.count <= 4_096 }) else {
            throw AgentBridgeError.invalidInput("The project-memory secret-redaction list is too large.")
        }
        guard !selectedTurnIDs.isEmpty || includeNotes else {
            throw AgentBridgeError.invalidInput("Select at least one memory turn or the project notes to carry forward.")
        }

        let selectedTurns = source.turns.filter { selectedTurnIDs.contains($0.id) }
        guard selectedTurns.count == selectedTurnIDs.count,
              Set(selectedTurns.map(\.id)).count == selectedTurnIDs.count else {
            throw AgentBridgeError.invalidInput("One or more selected memory turns do not exist in the source commit scope.")
        }

        var wasTruncated = source.wasTruncated
        let handoffTurns = selectedTurns.map { turn -> ProjectMemoryHandoffTurn in
            let userText = Self.redact(turn.userText, knownSecrets: knownSecrets)
            let assistantText = Self.redact(turn.assistantText, knownSecrets: knownSecrets)
            let boundedUserText = Self.boundedText(userText, maximumBytes: Self.maximumTextBytes)
            let boundedAssistantText = Self.boundedText(assistantText, maximumBytes: Self.maximumTextBytes)
            let truncated = boundedUserText != userText || boundedAssistantText != assistantText
            wasTruncated = wasTruncated || truncated
            return ProjectMemoryHandoffTurn(
                source: turn,
                userText: boundedUserText,
                assistantText: boundedAssistantText,
                wasTruncated: truncated
            )
        }

        var storedNotes: String?
        if includeNotes {
            let redactedNotes = Self.redact(source.notes, knownSecrets: knownSecrets)
            let boundedNotes = Self.boundedText(redactedNotes, maximumBytes: Self.maximumNotesBytes)
            wasTruncated = wasTruncated || boundedNotes != redactedNotes
            storedNotes = boundedNotes
        }

        let handoff = ProjectMemoryHandoff(
            sourceCommit: source.scope.snapshotCommit,
            targetCommit: normalizedTargetCommit,
            provider: provider,
            accountProfileID: accountProfileID,
            turns: handoffTurns,
            notes: storedNotes,
            wasTruncated: wasTruncated
        )

        try withLockedDirectory { directoryDescriptor in
            var document = try readDocument(directoryDescriptor: directoryDescriptor)
            if let repositoryIndex = document.repositories.firstIndex(where: { $0.key == repository.key }) {
                document.repositories[repositoryIndex].handoffs.append(handoff)
            } else {
                document.repositories.append(StoredRepository(key: repository.key, handoffs: [handoff]))
            }

            Self.enforceRetention(&document, keeping: handoff.id)
            while try Self.encode(document).count > Self.maximumStoredBytes {
                guard Self.removeOldestHandoff(from: &document, excluding: handoff.id) else {
                    throw Self.persistenceError("The selected project-memory handoff exceeds the storage limit.")
                }
            }
            try writeDocument(document, directoryDescriptor: directoryDescriptor)
        }
        return handoff
    }

    /// Lists the most recent handoffs for a canonical repository path.
    public func list(repositoryPath: String) throws -> [ProjectMemoryHandoff] {
        let repository = try ProjectMemoryRepositoryScope(repositoryPath: repositoryPath)
        return try withLockedDirectory { directoryDescriptor in
            let document = try readDocument(directoryDescriptor: directoryDescriptor)
            guard let stored = document.repositories.first(where: { $0.key == repository.key }) else { return [] }
            return stored.handoffs.sorted(by: Self.newerFirst)
        }
    }

    /// Searches selected memory text and provenance within one repository.
    public func search(repositoryPath: String, query: String) throws -> [ProjectMemoryHandoff] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw AgentBridgeError.invalidInput("Project-memory search text cannot be empty.")
        }
        let repository = try ProjectMemoryRepositoryScope(repositoryPath: repositoryPath)
        return try withLockedDirectory { directoryDescriptor in
            let document = try readDocument(directoryDescriptor: directoryDescriptor)
            guard let stored = document.repositories.first(where: { $0.key == repository.key }) else { return [] }
            return stored.handoffs
                .filter { Self.matches($0, query: normalizedQuery) }
                .sorted(by: Self.newerFirst)
        }
    }

    private struct StoreDocument: Codable {
        var schemaVersion: Int
        var repositories: [StoredRepository]

        init(repositories: [StoredRepository] = []) {
            self.schemaVersion = ProjectMemoryStore.schemaVersion
            self.repositories = repositories
        }
    }

    private struct StoredRepository: Codable {
        let key: String
        var handoffs: [ProjectMemoryHandoff]
    }

    private func withLockedDirectory<T>(_ operation: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let directoryDescriptor = Self.openDirectory(path: rootPath)
        guard directoryDescriptor >= 0 else {
            throw Self.persistenceError("Project-memory storage is unavailable or is a symbolic link.")
        }
        defer { _ = close(directoryDescriptor) }

        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == getuid(),
              fchmod(directoryDescriptor, mode_t(0o700)) == 0 else {
            throw Self.persistenceError("Project-memory storage directory failed integrity checks.")
        }

        let lockDescriptor = Self.lockFileName.withCString {
            openat(directoryDescriptor, $0, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        }
        guard lockDescriptor >= 0 else {
            throw Self.persistenceError("Could not safely open the project-memory lock.")
        }
        defer { _ = close(lockDescriptor) }
        var lockInfo = stat()
        guard fstat(lockDescriptor, &lockInfo) == 0,
              (lockInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              lockInfo.st_uid == getuid(),
              lockInfo.st_nlink == 1,
              fchmod(lockDescriptor, mode_t(0o600)) == 0 else {
            throw Self.persistenceError("Project-memory lock failed integrity checks.")
        }
        guard flock(lockDescriptor, LOCK_EX) == 0 else {
            throw Self.persistenceError("Could not lock project-memory storage.")
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }
        return try operation(directoryDescriptor)
    }

    private func readDocument(directoryDescriptor: Int32) throws -> StoreDocument {
        let descriptor = Self.documentFileName.withCString {
            openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0 {
            if errno == ENOENT { return StoreDocument() }
            throw Self.persistenceError("Could not safely open project-memory data.")
        }
        defer { _ = close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= off_t(Self.maximumStoredBytes),
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw Self.persistenceError("Project-memory data is not a bounded private regular file.")
        }

        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.persistenceError("Could not read project-memory data.")
            }
            guard data.count + count <= Self.maximumStoredBytes else {
                throw Self.persistenceError("Project-memory data exceeds the storage limit.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }

        do {
            let document = try Self.makeDecoder().decode(StoreDocument.self, from: data)
            try Self.validate(document)
            guard try Self.encode(document).count <= Self.maximumStoredBytes else {
                throw Self.persistenceError("Project-memory data exceeds the storage limit.")
            }
            return document
        } catch let error as AgentBridgeError {
            throw error
        } catch {
            throw Self.persistenceError("Project-memory data is corrupt and was left unchanged.")
        }
    }

    private func writeDocument(_ document: StoreDocument, directoryDescriptor: Int32) throws {
        try Self.validate(document)
        let data = try Self.encode(document)
        guard data.count <= Self.maximumStoredBytes else {
            throw Self.persistenceError("Project-memory data exceeds the storage limit.")
        }

        var currentInfo = stat()
        let existingStatus = Self.documentFileName.withCString {
            fstatat(directoryDescriptor, $0, &currentInfo, AT_SYMLINK_NOFOLLOW)
        }
        if existingStatus == 0 {
            guard (currentInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  currentInfo.st_uid == getuid(),
                  currentInfo.st_nlink == 1 else {
                throw Self.persistenceError("Project-memory destination is not a private regular file.")
            }
        } else if errno != ENOENT {
            throw Self.persistenceError("Could not inspect the project-memory destination.")
        }

        let temporaryName = ".handoffs.\(UUID().uuidString).tmp"
        let temporaryDescriptor = temporaryName.withCString {
            openat(directoryDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard temporaryDescriptor >= 0 else {
            throw Self.persistenceError("Could not create a private project-memory file.")
        }
        var shouldRemoveTemporary = true
        defer {
            _ = close(temporaryDescriptor)
            if shouldRemoveTemporary {
                temporaryName.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
            }
        }

        guard fchmod(temporaryDescriptor, mode_t(0o600)) == 0,
              Self.writeAll(data, to: temporaryDescriptor),
              fsync(temporaryDescriptor) == 0 else {
            throw Self.persistenceError("Could not write project-memory data.")
        }
        let renameResult = temporaryName.withCString { temporary in
            Self.documentFileName.withCString { destination in
                renameat(directoryDescriptor, temporary, directoryDescriptor, destination)
            }
        }
        guard renameResult == 0 else {
            throw Self.persistenceError("Could not atomically save project-memory data.")
        }
        shouldRemoveTemporary = false
        guard fsync(directoryDescriptor) == 0 else {
            throw Self.persistenceError("Could not flush project-memory storage.")
        }
    }

    private static func validate(_ document: StoreDocument) throws {
        guard document.schemaVersion == schemaVersion,
              document.repositories.count <= maximumStoredRepositories,
              Set(document.repositories.map(\.key)).count == document.repositories.count,
              document.repositories.allSatisfy({ isValidRepositoryKey($0.key) }) else {
            throw persistenceError("Project-memory data failed repository integrity checks.")
        }
        let handoffs = document.repositories.flatMap(\.handoffs)
        guard handoffs.count <= maximumStoredHandoffs,
              Set(handoffs.map(\.id)).count == handoffs.count else {
            throw persistenceError("Project-memory data failed handoff integrity checks.")
        }
        for repository in document.repositories {
            guard repository.handoffs.count <= maximumHandoffsPerRepository,
                  Set(repository.handoffs.map(\.id)).count == repository.handoffs.count else {
                throw persistenceError("Project-memory repository data failed integrity checks.")
            }
            for handoff in repository.handoffs {
                guard isValidCommit(handoff.sourceCommit),
                      isValidCommit(handoff.targetCommit),
                      handoff.turns.count <= maximumTurnsPerHandoff,
                      Set(handoff.turns.map(\.id)).count == handoff.turns.count,
                      handoff.turns.allSatisfy({
                          $0.userText.utf8.count <= maximumTextBytes &&
                              $0.assistantText.utf8.count <= maximumTextBytes
                      }),
                      handoff.notes == nil || handoff.notes!.utf8.count <= maximumNotesBytes else {
                    throw persistenceError("Project-memory handoff data failed integrity checks.")
                }
            }
        }
    }

    private static func enforceRetention(_ document: inout StoreDocument, keeping handoffID: UUID) {
        while let index = document.repositories.firstIndex(where: { $0.handoffs.count > maximumHandoffsPerRepository }) {
            guard removeOldestHandoff(from: &document, inRepository: index, excluding: handoffID) else { break }
        }
        while document.repositories.count > maximumStoredRepositories {
            let candidates = document.repositories.enumerated().filter {
                !$0.element.handoffs.contains(where: { $0.id == handoffID })
            }
            guard let oldest = candidates.min(by: {
                let leftDate = oldestDate(in: $0.element)
                let rightDate = oldestDate(in: $1.element)
                if leftDate != rightDate { return leftDate < rightDate }
                return $0.element.key < $1.element.key
            }) else { break }
            document.repositories.remove(at: oldest.offset)
        }
        while document.repositories.flatMap(\.handoffs).count > maximumStoredHandoffs {
            guard removeOldestHandoff(from: &document, excluding: handoffID) else { break }
        }
        document.repositories.removeAll(where: { $0.handoffs.isEmpty })
    }

    @discardableResult
    private static func removeOldestHandoff(from document: inout StoreDocument, excluding excludedID: UUID) -> Bool {
        let candidates: [(Int, Int, ProjectMemoryHandoff)] = document.repositories.enumerated().flatMap { repositoryIndex, repository in
            repository.handoffs.enumerated().compactMap { handoffIndex, handoff -> (Int, Int, ProjectMemoryHandoff)? in
                guard handoff.id != excludedID else { return nil }
                return (repositoryIndex, handoffIndex, handoff)
            }
        }
        guard let oldest = candidates.min(by: {
            if $0.2.createdAt != $1.2.createdAt { return $0.2.createdAt < $1.2.createdAt }
            return $0.2.id.uuidString < $1.2.id.uuidString
        }) else { return false }
        document.repositories[oldest.0].handoffs.remove(at: oldest.1)
        document.repositories.removeAll(where: { $0.handoffs.isEmpty })
        return true
    }

    @discardableResult
    private static func removeOldestHandoff(from document: inout StoreDocument, inRepository repositoryIndex: Int, excluding excludedID: UUID) -> Bool {
        guard let index = document.repositories[repositoryIndex].handoffs.indices
            .filter({ document.repositories[repositoryIndex].handoffs[$0].id != excludedID })
            .min(by: {
                let lhs = document.repositories[repositoryIndex].handoffs[$0]
                let rhs = document.repositories[repositoryIndex].handoffs[$1]
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }) else { return false }
        document.repositories[repositoryIndex].handoffs.remove(at: index)
        return true
    }

    private static func oldestDate(in repository: StoredRepository) -> Date {
        repository.handoffs.map(\.createdAt).min() ?? .distantFuture
    }

    private static func matches(_ handoff: ProjectMemoryHandoff, query: String) -> Bool {
        let provenance = [
            handoff.sourceCommit,
            handoff.targetCommit,
            handoff.provider.rawValue,
            handoff.accountProfileID?.uuidString ?? ""
        ].joined(separator: "\n")
        if provenance.localizedCaseInsensitiveContains(query) { return true }
        if handoff.notes?.localizedCaseInsensitiveContains(query) == true { return true }
        return handoff.turns.contains {
            $0.provider.rawValue.localizedCaseInsensitiveContains(query) ||
                $0.userText.localizedCaseInsensitiveContains(query) ||
                $0.assistantText.localizedCaseInsensitiveContains(query)
        }
    }

    private static func newerFirst(_ lhs: ProjectMemoryHandoff, _ rhs: ProjectMemoryHandoff) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private static func redact(_ text: String, knownSecrets: [String]) -> String {
        let genericRedactions = OutputRedactor.redact(text)
        return OutputRedactor.redact(genericRedactions, knownSecrets: knownSecrets)
    }

    private static func boundedText(_ text: String, maximumBytes: Int) -> String {
        guard text.utf8.count > maximumBytes else { return text }
        let markerBytes = truncationMarker.utf8.count
        let prefixBudget = max(0, maximumBytes - markerBytes)
        var prefix = ""
        var usedBytes = 0
        for character in text {
            let characterBytes = String(character).utf8.count
            guard usedBytes + characterBytes <= prefixBudget else { break }
            prefix.append(character)
            usedBytes += characterBytes
        }
        return prefix + truncationMarker
    }

    private static func isValidCommit(_ commit: String) -> Bool {
        (commit.utf8.count == 40 || commit.utf8.count == 64) && commit.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func isValidRepositoryKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func encode(_ document: StoreDocument) throws -> Data {
        do {
            return try makeEncoder().encode(document)
        } catch {
            throw persistenceError("Could not encode project-memory data.")
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func openDirectory(path: String) -> Int32 {
        path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func persistenceError(_ message: String) -> AgentBridgeError {
        .persistence(message)
    }
}
