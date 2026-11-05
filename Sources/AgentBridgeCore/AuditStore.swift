import Darwin
import Foundation

public final class AuditStore: @unchecked Sendable {
    public let rootURL: URL
    public let workspaceRootURL: URL?
    public let workspacesURL: URL
    public let sharedMemoryURL: URL
    public let managedWorkspaceRootURLs: [URL]
    private let sessionsURL: URL
    private let eventsURL: URL
    private let settingsURL: URL
    private let storeLockURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()
    private let maxFileSize = 10 * 1_024 * 1_024

    public convenience init(rootURL: URL, fileManager: FileManager = .default) throws {
        try self.init(
            rootURL: rootURL,
            workspaceRootURL: rootURL,
            managedWorkspaceRoots: [],
            fileManager: fileManager
        )
    }

    public init(
        rootURL: URL,
        workspaceRootURL: URL?,
        managedWorkspaceRoots: [URL],
        fileManager: FileManager = .default
    ) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.workspaceRootURL = workspaceRootURL?.standardizedFileURL
        self.fileManager = fileManager
        let workspaceRoots = (workspaceRootURL.map { [$0] } ?? []) + managedWorkspaceRoots + [rootURL]
        var seenRoots = Set<String>()
        self.managedWorkspaceRootURLs = workspaceRoots.filter { seenRoots.insert($0.path).inserted }
        self.workspacesURL = (workspaceRootURL ?? rootURL).standardizedFileURL.appendingPathComponent("workspaces", isDirectory: true)
        self.sharedMemoryURL = (workspaceRootURL ?? rootURL).standardizedFileURL.appendingPathComponent("shared-memory", isDirectory: true)
        self.sessionsURL = self.rootURL.appendingPathComponent("sessions.jsonl")
        self.eventsURL = self.rootURL.appendingPathComponent("events", isDirectory: true)
        self.settingsURL = self.rootURL.appendingPathComponent("settings.json")
        self.storeLockURL = self.rootURL.appendingPathComponent(".store.lock")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601

        try Self.createPrivateDirectory(self.rootURL, fileManager: fileManager)
        if let workspaceRootURL {
            try Self.requireDirectory(workspaceRootURL.standardizedFileURL)
            try Self.createPrivateDirectory(workspacesURL, fileManager: fileManager)
        }
        try Self.createPrivateDirectory(eventsURL, fileManager: fileManager)
        try Self.secureExistingFile(sessionsURL, fileManager: fileManager)
        try Self.secureExistingFile(storeLockURL, fileManager: fileManager)
    }

    public func loadSettings() throws -> BridgeSettings {
        try withStoreLock(exclusive: false) {
            guard fileManager.fileExists(atPath: settingsURL.path) else { return BridgeSettings() }
            try Self.requireRegularFile(settingsURL)
            let attributes = try fileManager.attributesOfItem(atPath: settingsURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 256_000 else {
                throw AgentBridgeError.persistence("The settings file exceeds the size limit.")
            }
            do {
                return try decoder.decode(BridgeSettings.self, from: Data(contentsOf: settingsURL))
            } catch {
                throw AgentBridgeError.persistence("The settings file is malformed.")
            }
        }
    }

    public func saveSettings(_ settings: BridgeSettings) throws {
        try withStoreLock(exclusive: true) {
            if fileManager.fileExists(atPath: settingsURL.path) { try Self.requireRegularFile(settingsURL) }
            do {
                let data = try encoder.encode(settings)
                try data.write(to: settingsURL, options: .atomic)
                try Self.setPrivateFilePermissions(settingsURL, fileManager: fileManager)
            } catch let error as AgentBridgeError {
                throw error
            } catch {
                throw AgentBridgeError.persistence("Could not write the settings file.")
            }
        }
    }

    public func saveSession(_ session: SessionRecord) throws {
        try withStoreLock(exclusive: true) {
            do {
                let data = try encoder.encode(session)
                try Self.appendJSONLine(data, to: sessionsURL, fileManager: fileManager, maximumSize: maxFileSize)
            } catch let error as AgentBridgeError {
                throw error
            } catch {
                throw AgentBridgeError.persistence("Could not write the session index.")
            }
        }
    }

    /// Appends several session records in one write, so a root migration
    /// repoints its sessions together or not at all.
    public func saveSessions(_ sessions: [SessionRecord]) throws {
        guard !sessions.isEmpty else { return }
        try withStoreLock(exclusive: true) {
            do {
                var data = Data()
                for (index, session) in sessions.enumerated() {
                    if index > 0 { data.append(0x0A) }
                    data.append(try encoder.encode(session))
                }
                try Self.appendJSONLine(data, to: sessionsURL, fileManager: fileManager, maximumSize: maxFileSize)
            } catch let error as AgentBridgeError {
                throw error
            } catch {
                throw AgentBridgeError.persistence("Could not write the session index.")
            }
        }
    }

    public func loadSessions() throws -> [SessionRecord] {
        try withStoreLock(exclusive: false) {
            try Self.requireRegularFile(sessionsURL)
            let attributes = try fileManager.attributesOfItem(atPath: sessionsURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= maxFileSize else {
                throw AgentBridgeError.persistence("The session index exceeds the size limit.")
            }
            guard let data = try? Data(contentsOf: sessionsURL) else { return [] }
            var latest: [UUID: SessionRecord] = [:]
            for line in data.split(separator: 0x0A) {
                guard let session = try? decoder.decode(SessionRecord.self, from: Data(line)) else { continue }
                if (latest[session.id]?.updatedAt ?? .distantPast) <= session.updatedAt {
                    latest[session.id] = session
                }
            }
            return latest.values.sorted { $0.updatedAt > $1.updatedAt }
        }
    }

    public func session(id: UUID) throws -> SessionRecord? {
        try loadSessions().first(where: { $0.id == id })
    }

    public func appendEvent(_ event: AuditEvent) throws {
        try withStoreLock(exclusive: true) {
            let path = eventsURL.appendingPathComponent("\(event.sessionID.uuidString.lowercased()).jsonl")
            do {
                let data = try encoder.encode(event)
                try Self.appendJSONLine(data, to: path, fileManager: fileManager, maximumSize: maxFileSize)
            } catch let error as AgentBridgeError {
                throw error
            } catch {
                throw AgentBridgeError.persistence("Could not write the audit event.")
            }
        }
    }

    public func events(sessionID: UUID) throws -> [AuditEvent] {
        try withStoreLock(exclusive: false) {
            let path = eventsURL.appendingPathComponent("\(sessionID.uuidString.lowercased()).jsonl")
            guard fileManager.fileExists(atPath: path.path) else { return [] }
            try Self.requireRegularFile(path)
            let attributes = try fileManager.attributesOfItem(atPath: path.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= maxFileSize else {
                throw AgentBridgeError.persistence("The audit file exceeds the size limit.")
            }
            guard let data = try? Data(contentsOf: path) else { return [] }
            return data.split(separator: 0x0A).compactMap { try? decoder.decode(AuditEvent.self, from: Data($0)) }
        }
    }

    public func cancellationRequestURL(for sessionID: UUID) -> URL {
        rootURL.appendingPathComponent("cancel-\(sessionID.uuidString.lowercased()).request")
    }

    public func requestCancellation(for sessionID: UUID) throws {
        guard let session = try session(id: sessionID), session.status == .running else {
            throw AgentBridgeError.sessionMismatch("This session has no running process.")
        }
        try requestCancellation(forRunID: sessionID)
    }

    /// Requests cancellation for any AgentBridge-managed run ID. Discussion
    /// runs share the existing cancellation channel without pretending to be
    /// Git-backed `SessionRecord`s.
    public func requestCancellation(forRunID runID: UUID) throws {
        do {
            let requestURL = cancellationRequestURL(for: runID)
            try Data("cancel".utf8).write(to: requestURL, options: .atomic)
            try Self.setPrivateFilePermissions(requestURL, fileManager: fileManager)
        } catch {
            throw AgentBridgeError.persistence("Could not create the cancellation request.")
        }
    }

    public func consumeCancellationRequest(for sessionID: UUID) -> Bool {
        let url = cancellationRequestURL(for: sessionID)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        try? fileManager.removeItem(at: url)
        return true
    }

    public func acquireRunLease(for sessionID: UUID) throws -> SessionRunLease {
        let url = rootURL.appendingPathComponent("session-\(sessionID.uuidString.lowercased()).run.lock")
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AgentBridgeError.persistence("Could not lock the session.") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            _ = close(descriptor)
            throw AgentBridgeError.persistence("The session lock file is not a secure regular file.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            _ = close(descriptor)
            throw AgentBridgeError.sessionMismatch("This session is already running in another window or terminal.")
        }
        return SessionRunLease(descriptor: descriptor)
    }

    public static func createPrivateDirectory(_ url: URL, fileManager: FileManager = .default) throws {
        do {
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            try requireDirectory(url)
            guard chmod(url.path, mode_t(0o700)) == 0 else { throw AgentBridgeError.persistence("Could not set directory permissions.") }
        } catch {
            if let error = error as? AgentBridgeError { throw error }
            throw AgentBridgeError.persistence("Could not create a private directory.")
        }
    }

    private static func secureExistingFile(_ url: URL, fileManager: FileManager) throws {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw AgentBridgeError.persistence("Could not safely open the data file.") }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("The data file is not a secure regular file.")
        }
    }

    private static func setPrivateFilePermissions(_ url: URL, fileManager: FileManager) throws {
        do {
            try requireRegularFile(url)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw AgentBridgeError.persistence("Could not set private file permissions.")
        }
    }

    private static func appendJSONLine(_ data: Data, to url: URL, fileManager: FileManager, maximumSize: Int) throws {
        if fileManager.fileExists(atPath: url.path) { try requireRegularFile(url) }
        let oldSize = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard oldSize + data.count + 1 <= maximumSize else {
            throw AgentBridgeError.persistence("The audit file has reached its size limit.")
        }
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw AgentBridgeError.persistence("Could not create the audit file.")
            }
        }
        try setPrivateFilePermissions(url, fileManager: fileManager)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data + Data([0x0A]))
    }

    private func withStoreLock<T>(exclusive: Bool, _ operation: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try PrivateLockFile.withLock(at: storeLockURL, exclusive: exclusive, error: { failure in
            switch failure {
            case .unavailable: AgentBridgeError.persistence("Could not open the data lock file.")
            case .notPrivateFile: AgentBridgeError.persistence("The data lock file is not a secure regular file.")
            case .lockFailed: AgentBridgeError.persistence("Could not lock the data file.")
            }
        }, operation)
    }

    private static func requireDirectory(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw AgentBridgeError.persistence("The directory path cannot be a symlink or a non-directory.")
        }
    }

    private static func requireRegularFile(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
            throw AgentBridgeError.persistence("The data file path cannot be a symlink or a non-regular file.")
        }
    }

}

public final class SessionRunLease: @unchecked Sendable {
    private let descriptor: Int32
    fileprivate init(descriptor: Int32) { self.descriptor = descriptor }
    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }
}
