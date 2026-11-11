import Darwin
import Foundation

public struct ProjectHandoffMarkdownDocument: Equatable, Sendable {
    public let fileURL: URL
    public let markdown: String
    public let latestEntry: String
    public let suggestedPrompt: String

    public init(fileURL: URL, markdown: String, latestEntry: String, suggestedPrompt: String) {
        self.fileURL = fileURL
        self.markdown = markdown
        self.latestEntry = latestEntry
        self.suggestedPrompt = suggestedPrompt
    }
}

/// Keeps explicit continuation notes outside source repositories. Files are
/// grouped by canonical repository identity and pinned commit; each append
/// preserves prior entries and publishes a redacted Markdown snapshot atomically.
public final class ProjectHandoffMarkdownStore: @unchecked Sendable {
    public static let maximumEntryBytes = 16 * 1_024
    public static let maximumHistoryBytes = 512 * 1_024

    private static let directoryName = "handoffs"
    private static let lockFileName = ".lock"
    private static let entryHeaderPrefix = "<!-- AgentBridge handoff entry v1; UTF-8 bytes: "

    private struct ParsedEntry {
        let markdown: String
        let suggestedPrompt: String
    }

    private let rootPath: String
    private let rootDescriptor: Int32
    private let lock = NSLock()

    public init(dataRootURL: URL) throws {
        let dataRoot = dataRootURL.standardizedFileURL
        guard dataRoot.isFileURL, dataRoot.path.hasPrefix("/"), !dataRoot.path.contains("\0") else {
            throw AgentBridgeError.invalidInput("Project handoffs require an absolute workspace data root.")
        }
        let dataRootDescriptor = Self.openDirectoryChain(dataRoot.path)
        guard dataRootDescriptor >= 0 else {
            throw AgentBridgeError.persistence("The configured workspace data root is unavailable or contains a symbolic link.")
        }
        defer { _ = close(dataRootDescriptor) }

        var rootInfo = stat()
        guard fstat(dataRootDescriptor, &rootInfo) == 0,
              (rootInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              rootInfo.st_uid == getuid() else {
            throw AgentBridgeError.persistence("The configured workspace data root is not a directory owned by this user.")
        }

        let createResult = Self.directoryName.withCString { mkdirat(dataRootDescriptor, $0, mode_t(0o700)) }
        guard createResult == 0 || errno == EEXIST else {
            throw AgentBridgeError.persistence("Could not create the private project-handoffs directory.")
        }
        let handoffsDescriptor = Self.directoryName.withCString {
            openat(dataRootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard handoffsDescriptor >= 0 else {
            throw AgentBridgeError.persistence("The project-handoffs directory is unavailable or is a symbolic link.")
        }
        var shouldCloseHandoffsDescriptor = true
        defer { if shouldCloseHandoffsDescriptor { _ = close(handoffsDescriptor) } }

        var handoffsInfo = stat()
        guard fstat(handoffsDescriptor, &handoffsInfo) == 0,
              (handoffsInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              handoffsInfo.st_uid == getuid(),
              fchmod(handoffsDescriptor, mode_t(0o700)) == 0 else {
            throw AgentBridgeError.persistence("Could not secure the project-handoffs directory.")
        }
        try PrivateLockFile.withLock(
            named: Self.lockFileName,
            in: handoffsDescriptor,
            create: true,
            error: { _ in AgentBridgeError.persistence("Could not secure the project-handoffs lock.") },
            { }
        )

        self.rootPath = dataRoot.appendingPathComponent(Self.directoryName, isDirectory: true).path
        self.rootDescriptor = handoffsDescriptor
        shouldCloseHandoffsDescriptor = false
    }

    deinit {
        _ = close(rootDescriptor)
    }

    public func append(
        scope: SharedMemoryScope,
        sourceProvider: String,
        sourceAccount: String,
        sourceProfileID: UUID,
        sourceLocalModel: String?,
        targetProvider: String,
        targetAccount: String,
        targetProfileID: UUID,
        targetLocalModel: String?,
        done: String,
        nextStep: String,
        suggestedPrompt: String,
        createdAt: Date = Date()
    ) throws -> ProjectHandoffMarkdownDocument {
        let repository = try ProjectMemoryRepositoryScope(repositoryPath: scope.repositoryPath)
        guard repository.repositoryPath == scope.repositoryPath else {
            throw AgentBridgeError.invalidInput("A project handoff requires a canonical repository and valid pinned commit.")
        }
        let commit = try Self.canonicalCommit(scope.snapshotCommit)
        let canonicalScope = try SharedMemoryScope(repositoryPath: repository.repositoryPath, snapshotCommit: commit)

        let redactedDone = Self.redact(done)
        let redactedNextStep = Self.redact(nextStep)
        let redactedSuggestedPrompt = Self.redact(suggestedPrompt)
        guard !redactedDone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !redactedNextStep.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !redactedSuggestedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("Project handoff fields cannot be empty.")
        }
        guard !redactedDone.contains("\0"), !redactedNextStep.contains("\0"), !redactedSuggestedPrompt.contains("\0") else {
            throw AgentBridgeError.invalidInput("Project handoff text cannot contain NUL characters.")
        }

        let entry = Self.makeEntry(
            scope: canonicalScope,
            sourceProvider: Self.redactLine(sourceProvider),
            sourceAccount: Self.redactLine(sourceAccount),
            sourceProfileID: sourceProfileID,
            sourceLocalModel: sourceLocalModel.map(Self.redactLine),
            targetProvider: Self.redactLine(targetProvider),
            targetAccount: Self.redactLine(targetAccount),
            targetProfileID: targetProfileID,
            targetLocalModel: targetLocalModel.map(Self.redactLine),
            done: redactedDone,
            nextStep: redactedNextStep,
            suggestedPrompt: redactedSuggestedPrompt,
            createdAt: createdAt
        )
        let entryData = Data(entry.utf8)
        guard !entryData.isEmpty, entryData.count <= Self.maximumEntryBytes else {
            throw AgentBridgeError.invalidInput("The redacted handoff exceeds the 16 KiB entry limit; nothing was saved.")
        }

        let destinationURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(repository.key, isDirectory: true)
            .appendingPathComponent(commit + ".md")
            .standardizedFileURL
        let destinationPath = destinationURL.path
        guard !Self.isInside(destinationPath, directory: repository.repositoryPath) else {
            throw AgentBridgeError.persistence("The configured workspace data root places handoffs inside the source repository; choose a data root outside the repository.")
        }

        return try withLockedRepository(repository.key) { repositoryDescriptor in
            let existing = try Self.readDocument(named: commit + ".md", from: repositoryDescriptor)
            var combined = existing
            combined.append(contentsOf: Self.wrappedEntry(entryData, promptByteCount: redactedSuggestedPrompt.utf8.count))
            guard combined.count <= Self.maximumHistoryBytes else {
                throw AgentBridgeError.persistence("Project handoff history reached its 512 KiB limit; existing entries were preserved.")
            }
            try Self.writeAtomically(combined, named: commit + ".md", in: repositoryDescriptor)
            let persisted = try Self.readDocument(named: commit + ".md", from: repositoryDescriptor)
            guard persisted == combined,
                  let parsed = Self.latestEntry(in: persisted),
                  parsed.markdown == entry,
                  parsed.suggestedPrompt == redactedSuggestedPrompt else {
                throw AgentBridgeError.persistence("The saved project handoff could not be verified after writing.")
            }
            guard let fullText = String(data: persisted, encoding: .utf8) else {
                throw AgentBridgeError.persistence("The saved project handoff is not valid UTF-8 Markdown.")
            }
            return ProjectHandoffMarkdownDocument(
                fileURL: destinationURL,
                markdown: fullText,
                latestEntry: parsed.markdown,
                suggestedPrompt: parsed.suggestedPrompt
            )
        }
    }

    public func load(scope: SharedMemoryScope) throws -> ProjectHandoffMarkdownDocument? {
        let repository = try ProjectMemoryRepositoryScope(repositoryPath: scope.repositoryPath)
        guard repository.repositoryPath == scope.repositoryPath else {
            throw AgentBridgeError.invalidInput("Project handoff requires a canonical repository path.")
        }
        let commit = try Self.canonicalCommit(scope.snapshotCommit)
        let filename = commit + ".md"
        let destinationURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(repository.key, isDirectory: true)
            .appendingPathComponent(filename)
            .standardizedFileURL
        guard !Self.isInside(destinationURL.path, directory: repository.repositoryPath) else {
            throw AgentBridgeError.persistence("Project handoff storage must remain outside the source repository.")
        }
        return try withLockedRepository(repository.key) { repositoryDescriptor in
            let data = try Self.readDocument(named: filename, from: repositoryDescriptor)
            guard !data.isEmpty else { return nil }
            guard let markdown = String(data: data, encoding: .utf8),
                  let parsed = Self.latestEntry(in: data) else {
                throw AgentBridgeError.persistence("Project handoff history is malformed or not valid UTF-8.")
            }
            return ProjectHandoffMarkdownDocument(
                fileURL: destinationURL,
                markdown: markdown,
                latestEntry: parsed.markdown,
                suggestedPrompt: parsed.suggestedPrompt
            )
        }
    }

    /// Removes the history for exactly one canonical repository and pinned
    /// commit. The unlink is serialized with append/load and is atomic at the
    /// directory entry; callers should refresh their loaded document afterward.
    public func clear(scope: SharedMemoryScope) throws {
        let repository = try ProjectMemoryRepositoryScope(repositoryPath: scope.repositoryPath)
        guard repository.repositoryPath == scope.repositoryPath else {
            throw AgentBridgeError.invalidInput("Project handoff clearing requires a canonical repository and valid pinned commit.")
        }
        let filename = try Self.canonicalCommit(scope.snapshotCommit) + ".md"
        let destinationURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(repository.key, isDirectory: true)
            .appendingPathComponent(filename)
            .standardizedFileURL
        guard !Self.isInside(destinationURL.path, directory: repository.repositoryPath) else {
            throw AgentBridgeError.persistence("Project handoff storage must remain outside the source repository.")
        }
        try withLockedRepository(repository.key) { directoryDescriptor in
            let existing = try Self.readDocument(named: filename, from: directoryDescriptor)
            guard !existing.isEmpty else { return }
            guard filename.withCString({ unlinkat(directoryDescriptor, $0, 0) }) == 0 else {
                throw AgentBridgeError.persistence("Could not atomically clear the saved project handoff.")
            }
            guard fsync(directoryDescriptor) == 0 else {
                throw AgentBridgeError.persistence("The project handoff was removed, but its directory update could not be flushed.")
            }
        }
    }

    /// Copies valid per-repository/commit histories into another configured
    /// data root. Conflicting destination histories stop migration; source data
    /// is never removed or overwritten.
    public static func copyHistories(from sourceDataRootURL: URL, to destinationDataRootURL: URL) throws {
        let sourceDataRoot = sourceDataRootURL.standardizedFileURL
        let destinationDataRoot = destinationDataRootURL.standardizedFileURL
        guard sourceDataRoot.isFileURL, destinationDataRoot.isFileURL,
              sourceDataRoot.path.hasPrefix("/"), destinationDataRoot.path.hasPrefix("/") else {
            throw AgentBridgeError.invalidInput("Project handoff migration requires absolute workspace data roots.")
        }
        guard sourceDataRoot.path != destinationDataRoot.path else { return }
        let sourceHandoffsURL = sourceDataRoot.appendingPathComponent(Self.directoryName, isDirectory: true)
        var sourceInfo = stat()
        if lstat(sourceHandoffsURL.path, &sourceInfo) != 0 {
            if errno == ENOENT { return }
            throw AgentBridgeError.persistence("Could not inspect the source project-handoffs directory safely.")
        }
        guard (sourceInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR), sourceInfo.st_uid == getuid() else {
            throw AgentBridgeError.persistence("The source project-handoffs path is not a directory owned by this user.")
        }
        let sourceRootDescriptor = openDirectoryChain(sourceDataRoot.path)
        guard sourceRootDescriptor >= 0 else {
            throw AgentBridgeError.persistence("Could not safely open the source workspace data root.")
        }
        defer { _ = close(sourceRootDescriptor) }
        let sourceDescriptor = Self.directoryName.withCString {
            openat(sourceRootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sourceDescriptor >= 0 else {
            throw AgentBridgeError.persistence("The source project-handoffs directory is unavailable or is a symbolic link.")
        }
        defer { _ = close(sourceDescriptor) }
        var handoffsInfo = stat()
        guard fstat(sourceDescriptor, &handoffsInfo) == 0,
              (handoffsInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              handoffsInfo.st_uid == getuid(),
              fchmod(sourceDescriptor, mode_t(0o700)) == 0 else {
            throw AgentBridgeError.persistence("The source project-handoffs directory is not a private user-owned directory.")
        }

        let destinationStore = try ProjectHandoffMarkdownStore(dataRootURL: destinationDataRoot)
        try PrivateLockFile.withLock(
            named: Self.lockFileName,
            in: sourceDescriptor,
            create: false,
            error: { _ in AgentBridgeError.persistence("Could not lock source project-handoff history for migration safely.") }
        ) {
            let sourceRepositoryNames = try FileManager.default.contentsOfDirectory(atPath: sourceHandoffsURL.path)
            for repositoryKey in sourceRepositoryNames where repositoryKey.count == 64 && repositoryKey.utf8.allSatisfy(isHex) {
                let repositoryDescriptor = repositoryKey.withCString {
                    openat(sourceDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard repositoryDescriptor >= 0 else {
                    throw AgentBridgeError.persistence("A source project-handoff scope is unavailable or is a symbolic link.")
                }
                defer { _ = close(repositoryDescriptor) }
                var repositoryInfo = stat()
                guard fstat(repositoryDescriptor, &repositoryInfo) == 0,
                      (repositoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                      repositoryInfo.st_uid == getuid(),
                      fchmod(repositoryDescriptor, mode_t(0o700)) == 0 else {
                    throw AgentBridgeError.persistence("A source project-handoff scope is not a user-owned directory.")
                }
                let sourceRepositoryURL = sourceHandoffsURL.appendingPathComponent(repositoryKey, isDirectory: true)
                let sourceFiles = try FileManager.default.contentsOfDirectory(atPath: sourceRepositoryURL.path)
                for filename in sourceFiles where isValidHandoffFilename(filename) {
                    let history = try readDocument(named: filename, from: repositoryDescriptor)
                    guard !history.isEmpty, latestEntry(in: history) != nil else {
                        throw AgentBridgeError.persistence("A source project handoff is empty or malformed; migration stopped without removing source data.")
                    }
                    try destinationStore.withLockedRepository(repositoryKey) { destinationDescriptor in
                        let existing = try readDocument(named: filename, from: destinationDescriptor)
                        if !existing.isEmpty {
                            guard existing == history else {
                                throw AgentBridgeError.persistence("The destination already has different project-handoff history for \(repositoryKey)/\(filename); source data was left unchanged.")
                            }
                            return
                        }
                        try writeAtomically(history, named: filename, in: destinationDescriptor)
                        guard try readDocument(named: filename, from: destinationDescriptor) == history else {
                            throw AgentBridgeError.persistence("Could not verify migrated project-handoff history; source data was left unchanged.")
                        }
                    }
                }
            }
        }
    }

    private func withLockedRepository<T>(_ repositoryKey: String, _ body: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try PrivateLockFile.withLock(
            named: Self.lockFileName,
            in: rootDescriptor,
            create: false,
            error: { _ in AgentBridgeError.persistence("Could not lock project handoff storage safely.") }
        ) {
            let createResult = repositoryKey.withCString { mkdirat(rootDescriptor, $0, mode_t(0o700)) }
            guard createResult == 0 || errno == EEXIST else {
                throw AgentBridgeError.persistence("Could not create the private project handoff scope.")
            }
            let descriptor = repositoryKey.withCString {
                openat(rootDescriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard descriptor >= 0 else {
                throw AgentBridgeError.persistence("Project handoff scope is unavailable or is a symbolic link.")
            }
            defer { _ = close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  metadata.st_uid == getuid(),
                  fchmod(descriptor, mode_t(0o700)) == 0 else {
                throw AgentBridgeError.persistence("Project handoff scope is not a private directory owned by this user.")
            }
            return try body(descriptor)
        }
    }

    private static func readDocument(named name: String, from directoryDescriptor: Int32) throws -> Data {
        var before = stat()
        if fstatat(directoryDescriptor, name, &before, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return Data() }
            throw AgentBridgeError.persistence("Could not inspect the project handoff file safely.")
        }
        let descriptor = name.withCString { openat(directoryDescriptor, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else {
            throw AgentBridgeError.persistence("Project handoff file is unavailable or is a symbolic link.")
        }
        defer { _ = close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              (opened.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              opened.st_uid == getuid(), opened.st_nlink == 1,
              opened.st_size >= 0, opened.st_size <= off_t(Self.maximumHistoryBytes),
              Self.sameFile(before, opened), fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("Project handoff file is not a bounded private regular file.")
        }
        var data = Data()
        data.reserveCapacity(Int(opened.st_size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, min(bytes.count, Self.maximumHistoryBytes - data.count + 1))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentBridgeError.persistence("Could not read project handoff file.")
            }
            if count == 0 { break }
            guard data.count + count <= Self.maximumHistoryBytes else {
                throw AgentBridgeError.persistence("Project handoff history exceeds its size limit.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              Self.sameFile(opened, after), after.st_size == off_t(data.count) else {
            throw AgentBridgeError.persistence("Project handoff file changed while it was being read.")
        }
        if !data.isEmpty, latestEntry(in: data) == nil {
            throw AgentBridgeError.persistence("Project handoff history failed its entry integrity checks.")
        }
        return data
    }

    private static func writeAtomically(_ data: Data, named name: String, in directoryDescriptor: Int32) throws {
        var existing = stat()
        if fstatat(directoryDescriptor, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (existing.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
                  existing.st_uid == getuid(), existing.st_nlink == 1 else {
                throw AgentBridgeError.persistence("Project handoff destination is not a private regular file.")
            }
        } else if errno != ENOENT {
            throw AgentBridgeError.persistence("Could not inspect the project handoff destination.")
        }
        let temporaryName = ".handoff-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = temporaryName.withCString {
            openat(directoryDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw AgentBridgeError.persistence("Could not create a private temporary project handoff.")
        }
        var shouldRemove = true
        defer {
            _ = close(descriptor)
            if shouldRemove { temporaryName.withCString { _ = unlinkat(directoryDescriptor, $0, 0) } }
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("Could not secure the temporary project handoff.")
        }
        try writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw AgentBridgeError.persistence("Could not flush the temporary project handoff.")
        }
        let result = temporaryName.withCString { source in
            name.withCString { destination in renameat(directoryDescriptor, source, directoryDescriptor, destination) }
        }
        guard result == 0 else {
            throw AgentBridgeError.persistence("Could not atomically publish the project handoff.")
        }
        shouldRemove = false
        guard fsync(directoryDescriptor) == 0 else {
            throw AgentBridgeError.persistence("Could not flush project handoff storage.")
        }
    }

    private static func wrappedEntry(_ entry: Data, promptByteCount: Int) -> Data {
        var data = Data((entryHeaderPrefix + String(entry.count) + "; suggested prompt bytes: " + String(promptByteCount) + " -->\n").utf8)
        data.append(entry)
        data.append(0x0A)
        return data
    }

    private static func latestEntry(in data: Data) -> ParsedEntry? {
        let bytes = Array(data)
        var offset = 0
        var latest: ParsedEntry?
        while offset < bytes.count {
            guard let headerEnd = bytes[offset...].firstIndex(of: 0x0A),
                  let header = String(bytes: bytes[offset..<headerEnd], encoding: .utf8) else { return nil }
            guard header.hasPrefix(entryHeaderPrefix), header.hasSuffix(" -->") else { return nil }
            let countAndPromptBytes = header.dropFirst(entryHeaderPrefix.count).dropLast(4)
            let parts = countAndPromptBytes.components(separatedBy: "; suggested prompt bytes: ")
            guard parts.count == 2,
                  let byteCount = Int(parts[0]), byteCount >= 0,
                  let promptByteCount = Int(parts[1]), promptByteCount >= 0,
                  promptByteCount <= byteCount else { return nil }
            let bodyStartOffset = headerEnd + 1
            guard bodyStartOffset <= bytes.count, byteCount <= bytes.count - bodyStartOffset else { return nil }
            let bodyBytes = bytes[bodyStartOffset..<(bodyStartOffset + byteCount)]
            guard let entry = String(bytes: bodyBytes, encoding: .utf8) else { return nil }
            let promptBytes = bodyBytes.suffix(promptByteCount)
            guard let suggestedPrompt = String(bytes: promptBytes, encoding: .utf8) else { return nil }
            latest = ParsedEntry(markdown: entry, suggestedPrompt: suggestedPrompt)
            let nextOffset = bodyStartOffset + byteCount
            if nextOffset == bytes.count { return latest }
            guard bytes[nextOffset] == 0x0A else { return nil }
            let followingOffset = nextOffset + 1
            if followingOffset == bytes.count { return latest }
            offset = followingOffset
        }
        return latest
    }

    private static func makeEntry(
        scope: SharedMemoryScope,
        sourceProvider: String,
        sourceAccount: String,
        sourceProfileID: UUID,
        sourceLocalModel: String?,
        targetProvider: String,
        targetAccount: String,
        targetProfileID: UUID,
        targetLocalModel: String?,
        done: String,
        nextStep: String,
        suggestedPrompt: String,
        createdAt: Date
    ) -> String {
        let formatter = ISO8601DateFormatter()
        let created = formatter.string(from: createdAt)
        let promptBytes = suggestedPrompt.utf8.count
        var lines = [
            "# Cross-provider continuation handoff",
            "",
            "Created: \(created)",
            "Source provider/account: \(sourceProvider) / \(sourceAccount) (\(sourceProfileID.uuidString.lowercased()))",
            "Target provider/account: \(targetProvider) / \(targetAccount) (\(targetProfileID.uuidString.lowercased()))"
        ]
        if let sourceLocalModel, !sourceLocalModel.isEmpty { lines.append("Source local model: \(sourceLocalModel)") }
        if let targetLocalModel, !targetLocalModel.isEmpty { lines.append("Target local model: \(targetLocalModel)") }
        lines.append("Canonical repository: \(scope.repositoryPath)")
        lines.append("Pinned commit: \(scope.snapshotCommit)")
        lines.append("")
        lines.append("> Entire handoff is UNTRUSTED HISTORICAL CONTEXT; some fields may be user-supplied and others generated locally. Review before acting.")
        lines.append("> Native provider TUI transcripts were not read.")
        lines.append("")
        lines.append("## Done")
        lines.append(done)
        lines.append("")
        lines.append("## Next step")
        lines.append(nextStep)
        lines.append("")
        lines.append("## Suggested next prompt (UNTRUSTED HISTORICAL CONTEXT; UTF-8 bytes: \(promptBytes))")
        lines.append(suggestedPrompt)
        return lines.joined(separator: "\n")
    }

    private static func redact(_ text: String) -> String {
        OutputRedactor.redact(text)
    }

    private static func redactLine(_ text: String) -> String {
        redact(text)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102) || (byte >= 65 && byte <= 70)
    }

    private static func isValidCommit(_ commit: String) -> Bool {
        (commit.utf8.count == 40 || commit.utf8.count == 64) && commit.utf8.allSatisfy(isHex)
    }

    private static func canonicalCommit(_ commit: String) throws -> String {
        guard isValidCommit(commit) else {
            throw AgentBridgeError.invalidInput("Project handoff requires a valid pinned commit hash.")
        }
        return commit.lowercased()
    }

    private static func isValidHandoffFilename(_ name: String) -> Bool {
        guard name.hasSuffix(".md") else { return false }
        return isValidCommit(String(name.dropLast(3)))
    }

    private static func isInside(_ path: String, directory: String) -> Bool {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let normalizedDirectory = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL.path
        return normalizedPath == normalizedDirectory || normalizedPath.hasPrefix(normalizedDirectory.hasSuffix("/") ? normalizedDirectory : normalizedDirectory + "/")
    }

    private static func openDirectoryChain(_ path: String) -> Int32 {
        guard path.hasPrefix("/"), !path.contains("\0") else { return -1 }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return -1 }
        for component in path.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            guard component != ".", component != ".." else { _ = close(descriptor); return -1 }
            let child = component.withCString { openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard child >= 0 else { _ = close(descriptor); return -1 }
            _ = close(descriptor)
            descriptor = child
        }
        return descriptor
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let amount = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw AgentBridgeError.persistence("Could not write project handoff history.")
                }
                guard amount > 0 else { throw AgentBridgeError.persistence("Project handoff write did not complete.") }
                offset += amount
            }
        }
    }
}
