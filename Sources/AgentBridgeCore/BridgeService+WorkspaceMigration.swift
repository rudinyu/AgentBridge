import Darwin
import Foundation

extension BridgeService {
    /// Copies existing managed workspaces and shared-memory documents into the
    /// currently configured user root. Source data is never removed or replaced.
    public func prepareWorkspaceRootMigration(memorySourceRoots: [URL]) async throws -> [SessionRecord] {
        guard store.workspaceRootURL != nil else {
            throw AgentBridgeError.invalidInput("No workspace data root is set. Choose a folder in the app, or run `agentbridge workspace set /absolute/path/to/root` first.")
        }
        let fileManager = FileManager.default
        try AuditStore.createPrivateDirectory(store.workspacesURL, fileManager: fileManager)
        try recoverInterruptedSessions()
        let sessions = try store.loadSessions()
        guard !sessions.contains(where: { $0.status == .running }) else {
            throw AgentBridgeError.sessionMismatch("A session is still running. Stop all sessions before changing the data root.")
        }
        for var discussion in try discussionStore.list() where discussion.status.isInFlight {
            let lease = try store.acquireRunLease(for: discussion.id)
            defer { withExtendedLifetime(lease) {} }
            try recoverStaleDiscussionRun(&discussion)
        }
        guard try discussionStore.list().allSatisfy({ !$0.status.isInFlight }) else {
            throw AgentBridgeError.sessionMismatch("A discussion is still running; finish or stop all discussions before changing the data root.")
        }

        var migratedSessions: [SessionRecord] = []
        for session in sessions {
            let source = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
            let destination = store.workspacesURL.appendingPathComponent(session.id.uuidString.lowercased(), isDirectory: true)
            guard source.path != destination.path else { continue }
            var sourceMetadata = stat()
            if lstat(source.path, &sourceMetadata) != 0 {
                if errno == ENOENT { continue }
                throw AgentBridgeError.sessionMismatch("Could not safely inspect an existing isolated workspace; the data root was not changed.")
            }
            guard (sourceMetadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.sessionMismatch("An existing isolated workspace is not a regular folder; the data root was not changed.")
            }

            try await workspaceManager.validateWorkspace(for: session, accessMode: session.policy.accessMode)
            var destinationMetadata = stat()
            if lstat(destination.path, &destinationMetadata) == 0 {
                guard try directoriesAreEquivalent(source, destination) else {
                    throw AgentBridgeError.persistence("The destination data root already contains a different workspace \(session.id.uuidString.lowercased()); the source is unchanged. Choose an empty folder or resolve the conflict yourself.")
                }
            } else if errno != ENOENT {
                throw AgentBridgeError.persistence("Could not safely inspect a destination isolated workspace; the source remains unchanged.")
            } else {
                let staging = store.workspacesURL.appendingPathComponent(
                    ".migration-\(session.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
                do {
                    try fileManager.copyItem(at: source, to: staging)
                    guard chmod(staging.path, mode_t(0o700)) == 0 else {
                        throw AgentBridgeError.persistence("Could not secure the copied isolated workspace.")
                    }
                    try fileManager.moveItem(at: staging, to: destination)
                } catch {
                    try? fileManager.removeItem(at: staging)
                    if let error = error as? AgentBridgeError { throw error }
                    throw AgentBridgeError.persistence("Could not copy an existing isolated workspace; source data remains unchanged.")
                }
            }

            var migrated = session
            migrated.workspacePath = destination.path
            migrated.updatedAt = Date()
            try await workspaceManager.validateWorkspace(for: migrated, accessMode: migrated.policy.accessMode)
            migratedSessions.append(migrated)
        }

        try copySharedMemoryDocuments(to: store.sharedMemoryURL, from: memorySourceRoots)
        if let destinationRoot = store.workspaceRootURL {
            let handoffSourceRoots = memorySourceRoots.map { $0.standardizedFileURL.deletingLastPathComponent() }
            for sourceRoot in Dictionary(grouping: handoffSourceRoots, by: \.path).compactMap({ $0.value.first }) {
                try ProjectHandoffMarkdownStore.copyHistories(from: sourceRoot, to: destinationRoot)
            }
        }
        let discussionSourceRoots = memorySourceRoots.map {
            $0.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("discussions", isDirectory: true)
        }
        try copyDiscussionRecords(from: discussionSourceRoots)
        try copyTaskBoardRecords(from: memorySourceRoots.map {
            $0.standardizedFileURL.deletingLastPathComponent().appendingPathComponent("task-board", isDirectory: true)
        })
        return migratedSessions
    }

    private func copySharedMemoryDocuments(to destinationRoot: URL, from sourceRoots: [URL]) throws {
        let fileManager = FileManager.default
        try AuditStore.createPrivateDirectory(destinationRoot, fileManager: fileManager)
        let documentPattern = try NSRegularExpression(pattern: "^[0-9a-f]{64}\\.json$")
        let uniqueSources = Dictionary(grouping: sourceRoots.map(\.standardizedFileURL), by: \.path)
            .compactMap { $0.value.first }

        for sourceRoot in uniqueSources where sourceRoot.path != destinationRoot.standardizedFileURL.path {
            var rootMetadata = stat()
            guard lstat(sourceRoot.path, &rootMetadata) == 0 else {
                if errno == ENOENT { continue }
                throw AgentBridgeError.persistence("Could not safely read the old shared memory folder.")
            }
            guard (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.persistence("The old shared memory folder is not a regular folder; source data remains unchanged.")
            }

            let names = try fileManager.contentsOfDirectory(atPath: sourceRoot.path).sorted()
            for name in names {
                let range = NSRange(name.startIndex..<name.endIndex, in: name)
                guard documentPattern.firstMatch(in: name, range: range) != nil else { continue }
                let source = sourceRoot.appendingPathComponent(name)
                let destination = destinationRoot.appendingPathComponent(name)
                let sourceData = try readMemoryDocument(source)

                var destinationMetadata = stat()
                if lstat(destination.path, &destinationMetadata) == 0 {
                    guard (destinationMetadata.st_mode & S_IFMT) == S_IFREG,
                          try readMemoryDocument(destination) == sourceData else {
                        throw AgentBridgeError.persistence("The destination data root already contains a different shared memory file \(name); the source is unchanged. Choose an empty folder or resolve the conflict yourself.")
                    }
                    continue
                }
                guard errno == ENOENT else {
                    throw AgentBridgeError.persistence("Could not safely inspect the destination shared memory file.")
                }
                try writeNewMemoryDocument(sourceData, to: destination)
            }
        }
    }

    private func copyDiscussionRecords(from sourceRoots: [URL]) throws {
        guard let destinationRoot = store.workspaceRootURL else {
            throw AgentBridgeError.invalidInput("No workspace data root is configured; cannot copy discussion records.")
        }
        let destinationPath = destinationRoot.standardizedFileURL.path
        let uniqueSources = Dictionary(grouping: sourceRoots.map(\.standardizedFileURL), by: \.path)
            .compactMap { $0.value.first }
        for sourceRoot in uniqueSources where sourceRoot.path != discussionStore.rootURL.path {
            var metadata = stat()
            if lstat(sourceRoot.path, &metadata) != 0 {
                if errno == ENOENT { continue }
                throw AgentBridgeError.persistence("Could not safely inspect the old discussions folder; source data is unchanged.")
            }
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.persistence("The old discussions folder is not a regular folder; source data is unchanged.")
            }
            let source = try DiscussionStore(rootURL: sourceRoot)
            let records = try source.list()
            guard records.allSatisfy({ !$0.status.isInFlight }) else {
                throw AgentBridgeError.sessionMismatch("The old workspace still has running discussions; source data is unchanged.")
            }
            for original in records {
                var migrated = original
                migrated.dataRootPath = destinationPath
                if let existing = try discussionStore.record(id: migrated.id) {
                    guard existing == migrated else {
                        throw AgentBridgeError.persistence("The destination data root already has a different discussion record \(migrated.id.uuidString.lowercased()); the source is unchanged. Resolve the conflict first.")
                    }
                } else {
                    _ = try discussionStore.create(migrated)
                }
            }
        }
    }

    private func copyTaskBoardRecords(from sourceRoots: [URL]) throws {
        guard let destinationRoot = store.workspaceRootURL else {
            throw AgentBridgeError.invalidInput("No workspace data root is configured; cannot copy the task board.")
        }
        let destinationPath = destinationRoot.standardizedFileURL.appendingPathComponent("task-board", isDirectory: true).path
        let uniqueSources = Dictionary(grouping: sourceRoots.map(\.standardizedFileURL), by: \.path)
            .compactMap { $0.value.first }
        for sourceRoot in uniqueSources where sourceRoot.path != destinationPath {
            var metadata = stat()
            if lstat(sourceRoot.path, &metadata) != 0 {
                if errno == ENOENT { continue }
                throw AgentBridgeError.persistence("Could not safely inspect the old task-board folder; source data is unchanged.")
            }
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.persistence("The old task-board folder is not a regular folder; source data is unchanged.")
            }
            let records = try ParallelTaskBoard(rootURL: sourceRoot).list()
            do {
                try parallelTaskBoard.importTasks(records)
            } catch {
                throw AgentBridgeError.persistence("The destination data root already has different task-board records; the source is unchanged. Resolve the conflict first.")
            }
        }
    }

    private func readMemoryDocument(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AgentBridgeError.persistence("Could not safely read a shared memory document; source data remains unchanged.")
        }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= off_t(SharedMemoryStore.maximumStoredBytes + 1_024) else {
            throw AgentBridgeError.persistence("A shared memory document is not a valid regular file; source data remains unchanged.")
        }
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentBridgeError.persistence("Could not read a shared memory document; source data remains unchanged.")
            }
            guard data.count + count <= SharedMemoryStore.maximumStoredBytes + 1_024 else {
                throw AgentBridgeError.persistence("A shared memory document exceeds its size limit; source data remains unchanged.")
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func writeNewMemoryDocument(_ data: Data, to url: URL) throws {
        let directoryURL = url.deletingLastPathComponent()
        let destinationName = url.lastPathComponent
        guard !destinationName.isEmpty, destinationName != ".", destinationName != "..",
              !destinationName.contains("/") else {
            throw AgentBridgeError.persistence("Could not safely copy a shared memory document; source data remains unchanged.")
        }
        let directoryDescriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw AgentBridgeError.persistence("Could not safely open the shared-memory folder; source data is unchanged.")
        }
        defer { _ = close(directoryDescriptor) }

        let temporaryName = ".agentbridge-migration-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = openat(
            directoryDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw AgentBridgeError.persistence("Could not safely create a temporary shared-memory document; source data is unchanged.")
        }

        var temporaryIdentity: (device: dev_t, inode: ino_t)?
        var publishedDestination = false
        defer {
            if let temporaryIdentity {
                if publishedDestination {
                    Self.removeMigrationFile(
                        named: destinationName,
                        from: directoryDescriptor,
                        matching: temporaryIdentity
                    )
                }
                Self.removeMigrationFile(
                    named: temporaryName,
                    from: directoryDescriptor,
                    matching: temporaryIdentity
                )
            } else {
                // The name was created with O_EXCL in the private shared-memory directory.
                _ = unlinkat(directoryDescriptor, temporaryName, 0)
            }
            _ = close(descriptor)
        }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw AgentBridgeError.persistence("Could not protect the temporary shared-memory document.")
        }
        temporaryIdentity = (metadata.st_dev, metadata.st_ino)
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("Could not protect the temporary shared-memory document.")
        }

        try Self.writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw AgentBridgeError.persistence("Could not sync the temporary shared-memory document.")
        }

        guard linkat(directoryDescriptor, temporaryName, directoryDescriptor, destinationName, 0) == 0 else {
            if errno == EEXIST, try readMemoryDocument(url) == data { return }
            throw AgentBridgeError.persistence("Could not safely publish the shared-memory document; source data is unchanged.")
        }
        publishedDestination = true

        var publishedMetadata = stat()
        guard fstatat(directoryDescriptor, destinationName, &publishedMetadata, AT_SYMLINK_NOFOLLOW) == 0,
              (publishedMetadata.st_mode & S_IFMT) == S_IFREG,
              publishedMetadata.st_dev == metadata.st_dev,
              publishedMetadata.st_ino == metadata.st_ino else {
            throw AgentBridgeError.persistence("Could not verify the published shared-memory document; source data is unchanged.")
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw AgentBridgeError.persistence("Could not sync the shared-memory folder.")
        }
        guard unlinkat(directoryDescriptor, temporaryName, 0) == 0 else {
            throw AgentBridgeError.persistence("Could not clean up the temporary shared-memory document.")
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw AgentBridgeError.persistence("Could not sync the shared-memory folder.")
        }
        publishedDestination = false
    }

    private static func removeMigrationFile(
        named name: String,
        from directoryDescriptor: Int32,
        matching identity: (device: dev_t, inode: ino_t)
    ) {
        var metadata = stat()
        guard fstatat(directoryDescriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_dev == identity.device,
              metadata.st_ino == identity.inode else { return }
        _ = unlinkat(directoryDescriptor, name, 0)
    }

    private func directoriesAreEquivalent(_ source: URL, _ destination: URL) throws -> Bool {
        var sourceMetadata = stat()
        var destinationMetadata = stat()
        guard lstat(source.path, &sourceMetadata) == 0,
              lstat(destination.path, &destinationMetadata) == 0,
              (sourceMetadata.st_mode & S_IFMT) == (destinationMetadata.st_mode & S_IFMT) else { return false }

        switch sourceMetadata.st_mode & S_IFMT {
        case S_IFDIR:
            let fileManager = FileManager.default
            let sourceNames = try fileManager.contentsOfDirectory(atPath: source.path).sorted()
            let destinationNames = try fileManager.contentsOfDirectory(atPath: destination.path).sorted()
            guard sourceNames == destinationNames else { return false }
            for name in sourceNames {
                guard try directoriesAreEquivalent(source.appendingPathComponent(name), destination.appendingPathComponent(name)) else {
                    return false
                }
            }
            return true
        case S_IFREG:
            guard sourceMetadata.st_size == destinationMetadata.st_size else { return false }
            return FileManager.default.contentsEqual(atPath: source.path, andPath: destination.path)
        case S_IFLNK:
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: source.path))
                == (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path))
        default:
            return false
        }
    }
}
