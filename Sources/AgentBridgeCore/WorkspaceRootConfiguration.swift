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

/// Recognizes data roots inside folders that a cloud service syncs. Such a
/// root still works, but its transcripts, shared memory and workspace copies
/// leave this Mac, and `flock` only coordinates processes on one Mac, so the
/// App and CLI warn instead of refusing it.
public enum WorkspaceRootSyncCheck {
    private static let homeFolders = [
        ("Dropbox", "Dropbox"), ("Google Drive", "Google Drive"), ("OneDrive", "OneDrive"), ("Box", "Box")
    ]

    /// The name of the service syncing `rootURL`, or nil for a local folder.
    public static func syncedServiceName(
        for rootURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let path = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let home = homeDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        func isInside(_ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }

        if isInside(home + "/Library/Mobile Documents") { return "iCloud Drive" }
        let cloudStorage = home + "/Library/CloudStorage"
        if path.hasPrefix(cloudStorage + "/"),
           let folder = path.dropFirst(cloudStorage.count + 1).split(separator: "/").first {
            // File Provider folders are named like "Dropbox" or "OneDrive-Personal".
            let service = folder.split(separator: "-").first.map(String.init) ?? String(folder)
            return service == "GoogleDrive" ? "Google Drive" : service
        }
        if let first = path.hasPrefix(home + "/") ? path.dropFirst(home.count + 1).split(separator: "/").first : nil {
            for (prefix, name) in homeFolders where first == prefix || first.hasPrefix(prefix + " ") {
                return name
            }
        }
        // iCloud "Desktop & Documents Folders" keeps the usual paths.
        if (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true {
            return "iCloud Drive"
        }
        return nil
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
            throw AgentBridgeError.persistence("Could not safely read the workspace data root setting.")
        }
        guard (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0,
              metadata.st_size <= maximumFileSize else {
            throw AgentBridgeError.persistence("The workspace data root setting is not a valid regular file.")
        }
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw AgentBridgeError.persistence("Could not safely read the workspace data root setting.")
        }
        defer { _ = close(descriptor) }
        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFREG,
              openedMetadata.st_size >= 0,
              openedMetadata.st_size <= maximumFileSize,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("Could not secure the workspace data root setting.")
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
                    throw AgentBridgeError.persistence("Could not safely read the workspace data root setting.")
                }
                guard data.count + count <= maximumFileSize else {
                    throw AgentBridgeError.persistence("The workspace data root setting exceeds its size limit.")
                }
                data.append(contentsOf: buffer.prefix(count))
            }
            let stored = try JSONDecoder().decode(WorkspaceRootFile.self, from: data)
            guard stored.version == 1,
                  let selected = validatedStoredPath(stored.selectedRootPath) else {
                throw AgentBridgeError.persistence("The workspace data root setting is invalid.")
            }
            let prior = stored.priorRootPaths.compactMap(validatedStoredPath)
            return WorkspaceRootConfiguration(selectedRootURL: selected, priorRootURLs: prior)
        } catch let error as AgentBridgeError {
            throw error
        } catch {
            throw AgentBridgeError.persistence("The workspace data root setting is invalid.")
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
            throw AgentBridgeError.invalidInput("The workspace data root must be a valid absolute path.")
        }
        try AuditStore.createPrivateDirectory(privateRootURL, fileManager: fileManager)
        let fileURL = privateRootURL.appendingPathComponent(fileName)
        var metadata = stat()
        if lstat(fileURL.path, &metadata) == 0 {
            guard (metadata.st_mode & S_IFMT) == S_IFREG else {
                throw AgentBridgeError.persistence("The workspace data root setting is not a regular file.")
            }
        } else if errno != ENOENT {
            throw AgentBridgeError.persistence("Could not safely update the workspace data root setting.")
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
                throw AgentBridgeError.persistence("The workspace data root setting exceeds its size limit.")
            }
            try data.write(to: fileURL, options: .atomic)
            let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw AgentBridgeError.persistence("Could not secure the workspace data root setting.") }
            defer { _ = close(descriptor) }
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw AgentBridgeError.persistence("Could not secure the workspace data root setting.")
            }
            return configuration
        } catch let error as AgentBridgeError {
            throw error
        } catch {
            throw AgentBridgeError.persistence("Could not save the workspace data root setting.")
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
        let isResuming = existing?.selectedRootURL.path == selectedRoot.path

        let migrationStore = try AuditStore(
            rootURL: privateRoot,
            workspaceRootURL: selectedRoot,
            managedWorkspaceRoots: priorRoots + [privateRoot],
            fileManager: fileManager
        )
        if isResuming {
            // Selecting the current root again finishes a migration that
            // stopped after saving the root but before repointing every
            // session; with nothing left over it changes nothing.
            let workspaces = migrationStore.workspacesURL.standardizedFileURL.path + "/"
            let leftover = try migrationStore.loadSessions().contains { session in
                let path = URL(fileURLWithPath: session.workspacePath).standardizedFileURL.path
                return !path.hasPrefix(workspaces) && FileManager.default.fileExists(atPath: path)
            }
            guard leftover else { return selectedRoot }
        }
        let migrationService = try BridgeService(store: migrationStore)
        // Memory, discussions and the task board are copied before the root
        // is saved, so a resumed migration only has workspaces left to copy.
        let sourceMemoryRoots = isResuming ? [] : [
            (existing?.selectedRootURL ?? privateRoot).appendingPathComponent("shared-memory", isDirectory: true)
        ]
        let migratedSessions = try await migrationService.prepareWorkspaceRootMigration(memorySourceRoots: sourceMemoryRoots)

        // The root is saved first: until the sessions are repointed they keep
        // using their intact copies in the prior root, which stays managed.
        if !isResuming {
            _ = try WorkspaceRootConfigurationStore.save(
                selectedRootURL: selectedRoot,
                priorRootURLs: priorRoots,
                privateRootURL: privateRoot,
                fileManager: fileManager
            )
        }
        try migrationStore.saveSessions(migratedSessions)
        return selectedRoot
    }

    /// Folders AgentBridge manages inside a data root, including the
    /// legacy extension folders that may remain in earlier roots.
    private static let managedStorageNames = [
        "workspaces", "shared-memory", "handoffs", "discussions", "task-board", "extension-policy", "extension-runtime"
    ]

    public static func validateConfiguredRoot(_ rootURL: URL, privateRootURL: URL) throws -> URL {
        let root = rootURL.standardizedFileURL
        guard root.path.hasPrefix("/"), root.path != "/" else {
            throw AgentBridgeError.persistence("The saved workspace data root path is invalid. Choose another folder in the app or run `agentbridge workspace set /absolute/path/to/root`.")
        }
        guard root.path != privateRootURL.standardizedFileURL.path,
              !root.path.hasPrefix(privateRootURL.standardizedFileURL.path + "/") else {
            throw AgentBridgeError.persistence("The workspace data root cannot be inside AgentBridge's private settings folder.")
        }
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              root.resolvingSymlinksInPath().standardizedFileURL.path == root.path else {
            throw AgentBridgeError.persistence("The selected workspace data root is missing or has become a symbolic link. Choose another folder in the app or run `agentbridge workspace set /absolute/path/to/root`.")
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
            throw AgentBridgeError.invalidInput("Choose a local workspace data root using an absolute path.")
        }
        let requested = requestedRootURL.standardizedFileURL
        var metadata = stat()
        let requestedRootExists = lstat(requested.path, &metadata) == 0
        if requestedRootExists {
            guard (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.invalidInput("The workspace data root must be a regular folder, not a symbolic link.")
            }
        } else if errno != ENOENT {
            throw AgentBridgeError.persistence("Could not safely inspect the selected workspace data root.")
        }

        let preflightCanonical = requested.resolvingSymlinksInPath().standardizedFileURL
        if try isInsideGitRepository(preflightCanonical) {
            throw AgentBridgeError.invalidInput("The workspace data root cannot be inside a Git repository.")
        }
        if !requestedRootExists {
            do { try fileManager.createDirectory(at: requested, withIntermediateDirectories: true) }
            catch { throw AgentBridgeError.persistence("Could not create the selected workspace data root.") }
        }

        let canonical = requested.resolvingSymlinksInPath().standardizedFileURL
        if try isInsideGitRepository(canonical) {
            throw AgentBridgeError.invalidInput("The workspace data root cannot be inside a Git repository.")
        }
        guard canonical.path != "/",
              canonical.path != privateRootURL.standardizedFileURL.path,
              !canonical.path.hasPrefix(privateRootURL.standardizedFileURL.path + "/") else {
            throw AgentBridgeError.invalidInput("The workspace data root cannot be the disk root or AgentBridge's private settings folder.")
        }
        let isInsideManagedStorage = managedWorkspaceRoots.contains { root in
            managedStorageNames.contains { name in
                let storage = root.standardizedFileURL.appendingPathComponent(name, isDirectory: true).path
                return canonical.path == storage || canonical.path.hasPrefix(storage + "/")
            }
        }
        guard !isInsideManagedStorage else {
            throw AgentBridgeError.invalidInput("The workspace data root cannot be inside AgentBridge-managed workspace, shared-memory, handoff, discussion or task-board folders.")
        }
        var canonicalMetadata = stat()
        guard lstat(canonical.path, &canonicalMetadata) == 0,
              (canonicalMetadata.st_mode & S_IFMT) == S_IFDIR else {
            throw AgentBridgeError.invalidInput("The workspace data root must be a regular folder.")
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
                throw AgentBridgeError.persistence("Could not safely check the Git status of the selected workspace data root.")
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
            throw AgentBridgeError.persistence("Could not safely create the workspace data root lock file.")
        }

        var metadata = stat()
        guard fstat(lockDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              fchmod(lockDescriptor, mode_t(0o600)) == 0 else {
            _ = close(lockDescriptor)
            throw AgentBridgeError.persistence("The workspace data root lock is not a safe private regular file.")
        }

        while flock(lockDescriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            _ = close(lockDescriptor)
            throw AgentBridgeError.persistence("Could not lock the workspace data root setting.")
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
            throw AgentBridgeError.invalidInput("No workspace data root is set. Choose a folder in the app, or run `agentbridge workspace set /absolute/path/to/root` first.")
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
