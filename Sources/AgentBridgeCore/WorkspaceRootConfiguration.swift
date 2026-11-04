import Darwin
import Foundation

public struct WorkspaceRootConfiguration: Equatable, Sendable {
    public let selectedRootURL: URL
    public let priorRootURLs: [URL]

    public var managedRootURLs: [URL] {
        Self.uniqueURLs([selectedRootURL] + priorRootURLs)
    }

    fileprivate init(selectedRootURL: URL, priorRootURLs: [URL]) {
        let normalizedSelectedRoot = selectedRootURL.standardizedFileURL
        self.selectedRootURL = normalizedSelectedRoot
        self.priorRootURLs = Self.uniqueURLs(priorRootURLs.map(\.standardizedFileURL))
            .filter { $0.path != normalizedSelectedRoot.path }
    }

    fileprivate static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

private struct WorkspaceRootFile: Codable {
    let version: Int
    let selectedRootPath: String
    let priorRootPaths: [String]
}

public enum WorkspaceRootConfigurationStore {
    private static let fileName = "workspace-root.json"
    private static let maximumFileSize = 64 * 1_024

    public static func load(
        privateRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> WorkspaceRootConfiguration? {
        let fileURL = privateRootURL.appendingPathComponent(fileName)
        var metadata = stat()
        guard lstat(fileURL.path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw AgentBridgeError.persistence("無法安全讀取工作區資料根目錄設定。")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumFileSize else {
            throw AgentBridgeError.persistence("工作區資料根目錄設定不是有效的一般檔案。")
        }
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AgentBridgeError.persistence("無法安全讀取工作區資料根目錄設定。")
        }
        defer { _ = close(descriptor) }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFREG,
              openedMetadata.st_size >= 0,
              openedMetadata.st_size <= maximumFileSize,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("無法保護工作區資料根目錄設定。")
        }
        do {
            var data = Data()
            data.reserveCapacity(Int(openedMetadata.st_size))
            var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes in
                    read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AgentBridgeError.persistence("無法安全讀取工作區資料根目錄設定。")
                }
                guard data.count + count <= maximumFileSize else {
                    throw AgentBridgeError.persistence("工作區資料根目錄設定超過大小上限。")
                }
                data.append(contentsOf: buffer.prefix(count))
            }
            let stored = try JSONDecoder().decode(WorkspaceRootFile.self, from: data)
            guard stored.version == 1,
                  let selected = validatedStoredPath(stored.selectedRootPath) else {
                throw AgentBridgeError.persistence("工作區資料根目錄設定格式錯誤。")
            }
            let prior = stored.priorRootPaths.compactMap(validatedStoredPath)
            return WorkspaceRootConfiguration(selectedRootURL: selected, priorRootURLs: prior)
        } catch let error as AgentBridgeError {
            throw error
        } catch {
            throw AgentBridgeError.persistence("工作區資料根目錄設定格式錯誤。")
        }
    }

    @discardableResult
    public static func save(
        selectedRootURL: URL,
        priorRootURLs: [URL],
        privateRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> WorkspaceRootConfiguration {
        let selected = selectedRootURL.standardizedFileURL
        guard let selectedPath = validatedStoredPath(selected.path) else {
            throw AgentBridgeError.invalidInput("工作區資料根目錄必須是有效的絕對路徑。")
        }
        try AuditStore.createPrivateDirectory(privateRootURL, fileManager: fileManager)
        let fileURL = privateRootURL.appendingPathComponent(fileName)
        var metadata = stat()
        if lstat(fileURL.path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFREG else {
                throw AgentBridgeError.persistence("工作區資料根目錄設定不是一般檔案。")
            }
        } else if errno != ENOENT {
            throw AgentBridgeError.persistence("無法安全更新工作區資料根目錄設定。")
        }
        let configuration = WorkspaceRootConfiguration(
            selectedRootURL: selectedPath,
            priorRootURLs: priorRootURLs.compactMap { validatedStoredPath($0.standardizedFileURL.path) }
        )
        let stored = WorkspaceRootFile(
            version: 1,
            selectedRootPath: configuration.selectedRootURL.path,
            priorRootPaths: configuration.priorRootURLs.map(\.path)
        )
        do {
            let data = try JSONEncoder.workspaceRootEncoder.encode(stored)
            guard data.count <= maximumFileSize else {
                throw AgentBridgeError.persistence("工作區資料根目錄設定超過大小上限。")
            }
            try data.write(to: fileURL, options: .atomic)
            let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw AgentBridgeError.persistence("無法保護工作區資料根目錄設定。") }
            defer { _ = close(descriptor) }
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw AgentBridgeError.persistence("無法保護工作區資料根目錄設定。")
            }
            return configuration
        } catch let error as AgentBridgeError {
            throw error
        } catch {
            throw AgentBridgeError.persistence("無法儲存工作區資料根目錄設定。")
        }
    }

    private static func validatedStoredPath(_ path: String) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\0"),
              !URL(fileURLWithPath: path).pathComponents.contains("..") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard url.path == path else { return nil }
        return url
    }
}

public enum WorkspaceRootCoordinator {
    @discardableResult
    public static func changeRoot(
        to requestedRootURL: URL,
        privateRootURL: URL,
        fileManager: FileManager = .default
    ) async throws -> URL {
        let privateRoot = privateRootURL.standardizedFileURL
        let changeLease = try WorkspaceRootChangeLease(privateRootURL: privateRoot, fileManager: fileManager)
        defer { changeLease.release() }

        let existing = try WorkspaceRootConfigurationStore.load(privateRootURL: privateRoot, fileManager: fileManager)
        let priorRoots = existing?.managedRootURLs ?? []
        let selectedRoot = try prepareSelectedRoot(
            requestedRootURL,
            privateRootURL: privateRoot,
            managedWorkspaceRoots: priorRoots + [privateRoot],
            fileManager: fileManager
        )
        if existing?.selectedRootURL.path == selectedRoot.path { return selectedRoot }

        let migrationStore = try AuditStore(
            rootURL: privateRoot,
            workspaceRootURL: selectedRoot,
            managedWorkspaceRoots: priorRoots + [privateRoot],
            fileManager: fileManager
        )
        let migrationService = try BridgeService(store: migrationStore)
        let sourceMemoryRoot = (existing?.selectedRootURL ?? privateRoot)
            .appendingPathComponent("shared-memory", isDirectory: true)
        let migratedSessions = try await migrationService.prepareWorkspaceRootMigration(memorySourceRoots: [sourceMemoryRoot])

        _ = try WorkspaceRootConfigurationStore.save(
            selectedRootURL: selectedRoot,
            priorRootURLs: priorRoots,
            privateRootURL: privateRoot,
            fileManager: fileManager
        )
        for session in migratedSessions { try migrationStore.saveSession(session) }
        return selectedRoot
    }

    /// Folders AgentBridge manages inside a data root, including the
    /// legacy extension folders that may remain in earlier roots.
    private static let managedStorageNames = [
        "workspaces", "shared-memory", "discussions", "task-board", "extension-policy", "extension-runtime"
    ]

    public static func validateConfiguredRoot(_ rootURL: URL, privateRootURL: URL) throws -> URL {
        let root = rootURL.standardizedFileURL
        guard root.path.hasPrefix("/"), root.path != "/" else {
            throw AgentBridgeError.persistence("已儲存的工作區資料根目錄路徑無效；請使用 App 或 `agentbridge workspace set /absolute/path/to/root` 重新選擇。")
        }
        guard root.path != privateRootURL.standardizedFileURL.path,
              !root.path.hasPrefix(privateRootURL.standardizedFileURL.path + "/") else {
            throw AgentBridgeError.persistence("工作區資料根目錄不能位於 AgentBridge 私人設定資料夾內。")
        }
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              root.resolvingSymlinksInPath().standardizedFileURL.path == root.path else {
            throw AgentBridgeError.persistence("已選取的工作區資料根目錄不存在，或已變成符號連結；請在 App 或執行 `agentbridge workspace set /absolute/path/to/root` 重新選擇。")
        }
        return root
    }

    private static func prepareSelectedRoot(
        _ requestedRootURL: URL,
        privateRootURL: URL,
        managedWorkspaceRoots: [URL],
        fileManager: FileManager
    ) throws -> URL {
        guard requestedRootURL.isFileURL,
              requestedRootURL.path.hasPrefix("/"),
              !requestedRootURL.path.contains("\0"),
              !requestedRootURL.pathComponents.contains("..") else {
            throw AgentBridgeError.invalidInput("請選擇絕對路徑的本機工作區資料根目錄。")
        }
        let requested = requestedRootURL.standardizedFileURL
        var metadata = stat()
        let requestedRootExists = lstat(requested.path, &metadata) == 0
        if requestedRootExists {
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.invalidInput("工作區資料根目錄必須是一般資料夾，不能是符號連結。")
            }
        } else if errno != ENOENT {
            throw AgentBridgeError.persistence("無法安全檢查所選的工作區資料根目錄。")
        }

        let preflightCanonical = requested.resolvingSymlinksInPath().standardizedFileURL
        if try isInsideGitRepository(preflightCanonical) {
            throw AgentBridgeError.invalidInput("工作區資料根目錄不能位於 Git 儲存庫內。")
        }
        if !requestedRootExists {
            do { try fileManager.createDirectory(at: requested, withIntermediateDirectories: true) }
            catch { throw AgentBridgeError.persistence("無法建立所選的工作區資料根目錄。") }
        }

        let canonical = requested.resolvingSymlinksInPath().standardizedFileURL
        if try isInsideGitRepository(canonical) {
            throw AgentBridgeError.invalidInput("工作區資料根目錄不能位於 Git 儲存庫內。")
        }
        guard canonical.path != "/",
              canonical.path != privateRootURL.standardizedFileURL.path,
              !canonical.path.hasPrefix(privateRootURL.standardizedFileURL.path + "/") else {
            throw AgentBridgeError.invalidInput("工作區資料根目錄不能是磁碟根目錄或 AgentBridge 私人設定資料夾。")
        }
        let isInsideManagedStorage = managedWorkspaceRoots.contains { root in
            managedStorageNames.contains { name in
                let storage = root.standardizedFileURL.appendingPathComponent(name, isDirectory: true).path
                return canonical.path == storage || canonical.path.hasPrefix(storage + "/")
            }
        }
        guard !isInsideManagedStorage else {
            throw AgentBridgeError.invalidInput("工作區資料根目錄不能位於 AgentBridge 管理的工作區、共用記憶、討論或任務看板資料夾內。")
        }
        var canonicalMetadata = stat()
        guard lstat(canonical.path, &canonicalMetadata) == 0,
              (canonicalMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw AgentBridgeError.invalidInput("工作區資料根目錄必須是一般資料夾。")
        }
        return canonical
    }

    private static func isInsideGitRepository(_ root: URL) throws -> Bool {
        var directory = root.standardizedFileURL
        while true {
            let gitMetadataURL = directory.appendingPathComponent(".git", isDirectory: false)
            var metadata = stat()
            let result = stat(gitMetadataURL.path, &metadata)
            if result == 0 {
                let type = metadata.st_mode & S_IFMT
                // A .git directory marks a regular repository; a .git file is the
                // pointer used by linked worktrees.
                if type == S_IFDIR || type == S_IFREG { return true }
            } else if errno != ENOENT && errno != ENOTDIR {
                throw AgentBridgeError.persistence("無法安全檢查所選工作區資料根目錄的 Git 狀態。")
            }
            if directory.path == "/" { return false }
            directory.deleteLastPathComponent()
        }
    }
}

private final class WorkspaceRootChangeLease: @unchecked Sendable {
    private var descriptor: Int32?

    init(privateRootURL: URL, fileManager: FileManager) throws {
        try AuditStore.createPrivateDirectory(privateRootURL, fileManager: fileManager)
        let lockURL = privateRootURL.appendingPathComponent(".workspace-root.lock")
        let lockDescriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard lockDescriptor >= 0 else {
            throw AgentBridgeError.persistence("無法安全建立工作區資料根目錄鎖定檔。")
        }

        var metadata = stat()
        guard fstat(lockDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              fchmod(lockDescriptor, mode_t(0o600)) == 0 else {
            _ = close(lockDescriptor)
            throw AgentBridgeError.persistence("工作區資料根目錄鎖定檔不是安全的私有一般檔案。")
        }

        while flock(lockDescriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            _ = close(lockDescriptor)
            throw AgentBridgeError.persistence("無法鎖定工作區資料根目錄設定。")
        }
        self.descriptor = lockDescriptor
    }

    func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    deinit { release() }
}

public extension RuntimePaths {
    static func workspaceRootConfiguration(fileManager: FileManager = .default) throws -> WorkspaceRootConfiguration? {
        let privateRoot = try applicationSupportRoot(fileManager: fileManager)
        return try WorkspaceRootConfigurationStore.load(privateRootURL: privateRoot, fileManager: fileManager)
    }

    static func requireWorkspaceRoot(fileManager: FileManager = .default) throws -> URL {
        let privateRoot = try applicationSupportRoot(fileManager: fileManager)
        guard let configuration = try WorkspaceRootConfigurationStore.load(privateRootURL: privateRoot, fileManager: fileManager) else {
            throw AgentBridgeError.invalidInput("尚未設定工作區資料根目錄；請在 App 選擇資料夾，或先執行 `agentbridge workspace set /absolute/path/to/root`。")
        }
        return try WorkspaceRootCoordinator.validateConfiguredRoot(configuration.selectedRootURL, privateRootURL: privateRoot)
    }

    static func makeAuditStore(fileManager: FileManager = .default) throws -> AuditStore {
        let privateRoot = try applicationSupportRoot(fileManager: fileManager)
        let configuration = try WorkspaceRootConfigurationStore.load(privateRootURL: privateRoot, fileManager: fileManager)
        let workspaceRoot: URL?
        if let configuration {
            workspaceRoot = try WorkspaceRootCoordinator.validateConfiguredRoot(configuration.selectedRootURL, privateRootURL: privateRoot)
        } else {
            workspaceRoot = nil
        }
        return try AuditStore(
            rootURL: privateRoot,
            workspaceRootURL: workspaceRoot,
            managedWorkspaceRoots: (configuration?.managedRootURLs ?? []) + [privateRoot],
            fileManager: fileManager
        )
    }
}

private extension JSONEncoder {
    static var workspaceRootEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
