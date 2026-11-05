import Darwin
import Foundation

extension BridgeService {
    /// Copies existing managed workspaces and shared-memory documents into the
    /// currently configured user root. Source data is never removed or replaced.
    public func prepareWorkspaceRootMigration(memorySourceRoots: [URL]) async throws -> [SessionRecord] {
        guard store.workspaceRootURL != nil else {
            throw AgentBridgeError.invalidInput("尚未設定工作區資料根目錄；請在 App 選擇資料夾，或先執行 `agentbridge workspace set /absolute/path/to/root`。")
        }
        let fileManager = FileManager.default
        try AuditStore.createPrivateDirectory(store.workspacesURL, fileManager: fileManager)
        let sessions = try store.loadSessions()
        guard !sessions.contains(where: { $0.status == .running }) else {
            throw AgentBridgeError.sessionMismatch("工作階段仍在執行；請先停止所有工作階段，再變更資料根目錄。")
        }
        for var discussion in try discussionStore.list() where discussion.status.isInFlight {
            let lease = try store.acquireRunLease(for: discussion.id)
            defer { withExtendedLifetime(lease) {} }
            try recoverStaleDiscussionRun(&discussion)
        }
        guard try discussionStore.list().allSatisfy({ !$0.status.isInFlight }) else {
            throw AgentBridgeError.sessionMismatch("討論仍在執行；請先完成或停止所有討論，再變更資料根目錄。")
        }

        var migratedSessions: [SessionRecord] = []
        for session in sessions {
            let source = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
            let destination = store.workspacesURL.appendingPathComponent(session.id.uuidString.lowercased(), isDirectory: true)
            guard source.path != destination.path else { continue }
            var sourceMetadata = stat()
            if lstat(source.path, &sourceMetadata) != 0 {
                if errno == ENOENT { continue }
                throw AgentBridgeError.sessionMismatch("無法安全檢查既有隔離工作區；資料根目錄未變更。")
            }
            guard (sourceMetadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.sessionMismatch("既有隔離工作區不是一般資料夾；資料根目錄未變更。")
            }

            try await workspaceManager.validateWorkspace(for: session, accessMode: session.policy.accessMode)
            var destinationMetadata = stat()
            if lstat(destination.path, &destinationMetadata) == 0 {
                guard try directoriesAreEquivalent(source, destination) else {
                    throw AgentBridgeError.persistence("目標資料根目錄已存在不同內容的工作區 \(session.id.uuidString.lowercased())；來源保持不變，請選擇空資料夾或自行處理衝突。")
                }
            } else if errno != ENOENT {
                throw AgentBridgeError.persistence("無法安全檢查目標隔離工作區；來源保持不變。")
            } else {
                let staging = store.workspacesURL.appendingPathComponent(
                    ".migration-\(session.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
                    isDirectory: true
                )
                do {
                    try fileManager.copyItem(at: source, to: staging)
                    guard chmod(staging.path, mode_t(0o700)) == 0 else {
                        throw AgentBridgeError.persistence("無法保護複製的隔離工作區。")
                    }
                    try fileManager.moveItem(at: staging, to: destination)
                } catch {
                    try? fileManager.removeItem(at: staging)
                    if let error = error as? AgentBridgeError { throw error }
                    throw AgentBridgeError.persistence("無法複製現有隔離工作區；來源資料保持不變。")
                }
            }

            var migrated = session
            migrated.workspacePath = destination.path
            migrated.updatedAt = Date()
            try await workspaceManager.validateWorkspace(for: migrated, accessMode: migrated.policy.accessMode)
            migratedSessions.append(migrated)
        }

        try copySharedMemoryDocuments(to: store.sharedMemoryURL, from: memorySourceRoots)
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
                throw AgentBridgeError.persistence("無法安全讀取舊的共享記憶資料夾。")
            }
            guard (rootMetadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.persistence("舊的共享記憶資料夾不是一般資料夾；來源資料保持不變。")
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
                        throw AgentBridgeError.persistence("目標資料根目錄已有不同內容的共享記憶檔 \(name)；來源保持不變，請選擇空資料夾或自行處理衝突。")
                    }
                    continue
                }
                guard errno == ENOENT else {
                    throw AgentBridgeError.persistence("無法安全檢查目標共享記憶檔。")
                }
                try writeNewMemoryDocument(sourceData, to: destination)
            }
        }
    }

    private func copyDiscussionRecords(from sourceRoots: [URL]) throws {
        guard let destinationRoot = store.workspaceRootURL else {
            throw AgentBridgeError.invalidInput("尚未設定工作區資料根目錄；無法複製討論記錄。")
        }
        let destinationPath = destinationRoot.standardizedFileURL.path
        let uniqueSources = Dictionary(grouping: sourceRoots.map(\.standardizedFileURL), by: \.path)
            .compactMap { $0.value.first }
        for sourceRoot in uniqueSources where sourceRoot.path != discussionStore.rootURL.path {
            var metadata = stat()
            if lstat(sourceRoot.path, &metadata) != 0 {
                if errno == ENOENT { continue }
                throw AgentBridgeError.persistence("無法安全檢查舊的討論資料夾；來源資料保持不變。")
            }
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.persistence("舊的討論資料夾不是一般資料夾；來源資料保持不變。")
            }
            let source = try DiscussionStore(rootURL: sourceRoot)
            let records = try source.list()
            guard records.allSatisfy({ !$0.status.isInFlight }) else {
                throw AgentBridgeError.sessionMismatch("舊工作區仍有執行中的討論；來源資料保持不變。")
            }
            for original in records {
                var migrated = original
                migrated.dataRootPath = destinationPath
                if let existing = try discussionStore.record(id: migrated.id) {
                    guard existing == migrated else {
                        throw AgentBridgeError.persistence("目標資料根目錄已有不同內容的討論記錄 \(migrated.id.uuidString.lowercased())；來源保持不變，請先處理衝突。")
                    }
                } else {
                    _ = try discussionStore.create(migrated)
                }
            }
        }
    }

    private func copyTaskBoardRecords(from sourceRoots: [URL]) throws {
        guard let destinationRoot = store.workspaceRootURL else {
            throw AgentBridgeError.invalidInput("尚未設定工作區資料根目錄；無法複製任務看板。")
        }
        let destinationPath = destinationRoot.standardizedFileURL.appendingPathComponent("task-board", isDirectory: true).path
        let uniqueSources = Dictionary(grouping: sourceRoots.map(\.standardizedFileURL), by: \.path)
            .compactMap { $0.value.first }
        for sourceRoot in uniqueSources where sourceRoot.path != destinationPath {
            var metadata = stat()
            if lstat(sourceRoot.path, &metadata) != 0 {
                if errno == ENOENT { continue }
                throw AgentBridgeError.persistence("無法安全檢查舊的任務看板資料夾；來源資料保持不變。")
            }
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.persistence("舊的任務看板資料夾不是一般資料夾；來源資料保持不變。")
            }
            let records = try ParallelTaskBoard(rootURL: sourceRoot).list()
            do {
                try parallelTaskBoard.importTasks(records)
            } catch {
                throw AgentBridgeError.persistence("目標資料根目錄已有不同內容的任務看板記錄；來源保持不變，請先處理衝突。")
            }
        }
    }

    private func readMemoryDocument(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AgentBridgeError.persistence("無法安全讀取共享記憶文件；來源資料保持不變。")
        }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= off_t(SharedMemoryStore.maximumStoredBytes + 1_024) else {
            throw AgentBridgeError.persistence("共享記憶文件不是有效的一般檔案；來源資料保持不變。")
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
                throw AgentBridgeError.persistence("無法讀取共享記憶文件；來源資料保持不變。")
            }
            guard data.count + count <= SharedMemoryStore.maximumStoredBytes + 1_024 else {
                throw AgentBridgeError.persistence("共享記憶文件超過大小上限；來源資料保持不變。")
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
            throw AgentBridgeError.persistence("無法安全複製共享記憶文件；來源資料保持不變。")
        }
        let directoryDescriptor = open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw AgentBridgeError.persistence("無法安全開啟共享記憶資料夾；來源資料保持不變。")
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
            throw AgentBridgeError.persistence("無法安全建立共享記憶暫存文件；來源資料保持不變。")
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
            throw AgentBridgeError.persistence("無法保護共享記憶暫存文件。")
        }
        temporaryIdentity = (metadata.st_dev, metadata.st_ino)
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("無法保護共享記憶暫存文件。")
        }

        try Self.writeAll(data, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw AgentBridgeError.persistence("無法同步共享記憶暫存文件。")
        }

        guard linkat(directoryDescriptor, temporaryName, directoryDescriptor, destinationName, 0) == 0 else {
            if errno == EEXIST, try readMemoryDocument(url) == data { return }
            throw AgentBridgeError.persistence("無法安全發佈共享記憶文件；來源資料保持不變。")
        }
        publishedDestination = true

        var publishedMetadata = stat()
        guard fstatat(directoryDescriptor, destinationName, &publishedMetadata, AT_SYMLINK_NOFOLLOW) == 0,
              (publishedMetadata.st_mode & S_IFMT) == S_IFREG,
              publishedMetadata.st_dev == metadata.st_dev,
              publishedMetadata.st_ino == metadata.st_ino else {
            throw AgentBridgeError.persistence("無法驗證已發佈的共享記憶文件；來源資料保持不變。")
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw AgentBridgeError.persistence("無法同步共享記憶資料夾。")
        }
        guard unlinkat(directoryDescriptor, temporaryName, 0) == 0 else {
            throw AgentBridgeError.persistence("無法清理共享記憶暫存文件。")
        }
        guard fsync(directoryDescriptor) == 0 else {
            throw AgentBridgeError.persistence("無法同步共享記憶資料夾。")
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
