import Darwin
import Foundation

public final class BridgeService: @unchecked Sendable {
    public let store: AuditStore
    public let workspaceManager: WorkspaceManager
    let runner: SafeProcessRunner
    let adapter: ProviderAdapter
    let localModelClient = LocalModelClient()
    let baseEnvironment: [String: String]
    let monthlyAPILimitUSD: Double
    let spendLedgers = SpendLedgerRegistry()
    let accountProfileStore: AccountProfileStore
    let sharedMemoryStore: SharedMemoryStore
    let projectMemoryStore: ProjectMemoryStore
    let discussionStore: DiscussionStore
    let parallelTaskBoard: ParallelTaskBoard
    let extensionPolicyStore: ExtensionPolicyStore
    let activeExtensionRuntimeStore: ActiveExtensionRuntimeStore
    let usageControlStore: UsageControlStore
    let runtimeProxyExecutableURL: URL?

    public init(
        store: AuditStore,
        runner: SafeProcessRunner = SafeProcessRunner(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        monthlyAPILimitUSD: Double = 140,
        runtimeProxyExecutableURL: URL? = nil
    ) throws {
        guard let workspaceRootURL = store.workspaceRootURL else {
            throw AgentBridgeError.invalidInput("No workspace data root is set. Choose a folder in the app, or run `agentbridge workspace set /absolute/path/to/root` first.")
        }
        self.store = store
        self.runner = runner
        self.runtimeProxyExecutableURL = runtimeProxyExecutableURL
        self.adapter = ProviderAdapter(runner: runner)
        self.baseEnvironment = baseEnvironment
        self.workspaceManager = WorkspaceManager(store: store, runner: runner, baseEnvironment: baseEnvironment)
        self.monthlyAPILimitUSD = monthlyAPILimitUSD
        self.accountProfileStore = try AccountProfileStore(rootURL: store.rootURL)
        self.sharedMemoryStore = try SharedMemoryStore(rootURL: store.sharedMemoryURL)
        self.projectMemoryStore = try ProjectMemoryStore(
            rootURL: store.sharedMemoryURL.appendingPathComponent("project-handoffs", isDirectory: true)
        )
        self.discussionStore = try DiscussionStore(
            rootURL: workspaceRootURL.appendingPathComponent("discussions", isDirectory: true)
        )
        let userDataRoot = workspaceRootURL
        self.parallelTaskBoard = try ParallelTaskBoard(
            rootURL: userDataRoot.appendingPathComponent("task-board", isDirectory: true)
        )
        // Extension grants and execution consent stay in private app data;
        // earlier releases kept them in the user root, so import once.
        self.extensionPolicyStore = try ExtensionPolicyStore(
            rootURL: store.rootURL.appendingPathComponent("extension-policy", isDirectory: true)
        )
        try extensionPolicyStore.importLegacyDocument(
            from: userDataRoot.appendingPathComponent("extension-policy", isDirectory: true)
        )
        self.activeExtensionRuntimeStore = try ActiveExtensionRuntimeStore(
            rootURL: store.rootURL.appendingPathComponent("extension-runtime", isDirectory: true)
        )
        try activeExtensionRuntimeStore.importLegacyDocument(
            from: userDataRoot.appendingPathComponent("extension-runtime", isDirectory: true)
        )
        self.usageControlStore = try UsageControlStore(rootURL: store.rootURL)
    }

    public func settings() throws -> BridgeSettings { try store.loadSettings() }
    public func saveSettings(_ settings: BridgeSettings) throws {
        try LocalModelClient.validateSettings(settings.localModel)
        try store.saveSettings(settings)
    }
    public func localModels(settings: LocalModelSettings? = nil) async throws -> [LocalModelDescriptor] {
        let localSettings = try settings ?? store.loadSettings().localModel
        return try await localModelClient.models(settings: localSettings)
    }

    @discardableResult
    public func testLocalModelConnection(settings: LocalModelSettings? = nil) async throws -> Bool {
        let localSettings = try settings ?? store.loadSettings().localModel
        return try await localModelClient.testConnection(settings: localSettings)
    }
    public func sessions() throws -> [SessionRecord] { try store.loadSessions() }
    public func events(sessionID: UUID) throws -> [AuditEvent] { try store.events(sessionID: sessionID) }

    public func taskRecords(sessionID: UUID? = nil) throws -> [ParallelTaskRecord] {
        try parallelTaskBoard.list(sessionID: sessionID)
    }

    public func updateTaskProgress(taskID: UUID, summary: String) throws -> ParallelTaskRecord {
        try parallelTaskBoard.updateProgress(taskID: taskID, summary: OutputRedactor.redact(summary))
    }

    @discardableResult
    public func createTaskRecord(sessionID: UUID, progressSummary: String = "Queued; provider process has not started.") throws -> ParallelTaskRecord {
        _ = try loadSession(sessionID)
        return try parallelTaskBoard.create(sessionID: sessionID, progressSummary: OutputRedactor.redact(progressSummary))
    }

    @discardableResult
    public func transitionTaskRecord(taskID: UUID, to status: ParallelTaskStatus) throws -> ParallelTaskRecord {
        try parallelTaskBoard.transition(taskID: taskID, to: status)
    }

    @discardableResult
    public func setTaskApproval(taskID: UUID, to approval: ParallelTaskApprovalState) throws -> ParallelTaskRecord {
        try parallelTaskBoard.setApproval(taskID: taskID, to: approval)
    }

    @discardableResult
    public func addTaskReference(taskID: UUID, kind: ParallelTaskReferenceKind, value: String) throws -> ParallelTaskRecord {
        try parallelTaskBoard.addReference(taskID: taskID, kind: kind, value: OutputRedactor.redact(value))
    }

    public func cancel(sessionID: UUID) throws { try store.requestCancellation(for: sessionID) }

    public func accountProfiles(provider: AgentProvider) throws -> [AccountProfile] {
        try accountProfileStore.profiles(provider: provider)
    }

    public func selectedAccountProfile(provider: AgentProvider) throws -> AccountProfile {
        try accountProfileStore.selected(provider: provider)
    }

    public func createAccountProfile(name: String, provider: AgentProvider, allowsSharedMemory: Bool = true) throws -> AccountProfile {
        try accountProfileStore.create(name: name, provider: provider, allowsSharedMemory: allowsSharedMemory)
    }

    public func selectAccountProfile(id: UUID, provider: AgentProvider) throws {
        try accountProfileStore.select(id: id, provider: provider)
    }

    public func setAccountSharedMemoryAllowed(id: UUID, allowed: Bool) throws {
        try accountProfileStore.setSharedMemoryAllowed(id: id, allowed: allowed)
    }

    public func accountProfile(id: UUID) throws -> AccountProfile {
        for provider in AgentProvider.allCases {
            if let profile = try accountProfileStore.profiles(provider: provider).first(where: { $0.id == id }) {
                return profile
            }
        }
        throw AccountProfileError.profileNotFound(id)
    }

    public func createSession(
        sourcePath: String,
        provider: AgentProvider,
        accessMode: AccessMode = .readOnly,
        snapshotCommit: String? = nil,
        accountProfileID: UUID? = nil
    ) async throws -> SessionRecord {
        guard try store.loadSettings().usageMode != .api || provider == .claude || provider == .local else {
            throw AgentBridgeError.sessionMismatch("API mode supports Claude only. Switch to subscription sign-in mode to use Codex.")
        }
        guard provider != .local || accessMode == .readOnly else {
            throw AgentBridgeError.sessionMismatch("Local models currently support only read-only project sessions; no workspace was created.")
        }
        let selectedProfile: AccountProfile
        if let accountProfileID {
            selectedProfile = try accountProfile(id: accountProfileID)
            guard selectedProfile.provider == provider else {
                throw AccountProfileError.providerMismatch(accountProfileID, provider)
            }
        } else {
            selectedProfile = try accountProfileStore.selected(provider: provider)
        }
        return try await workspaceManager.createSnapshot(
            sourcePath: sourcePath,
            provider: provider,
            accessMode: accessMode,
            accountProfileID: selectedProfile.id,
            snapshotCommit: snapshotCommit
        )
    }

    func loadSession(_ id: UUID) throws -> SessionRecord {
        guard let session = try store.session(id: id) else { throw AgentBridgeError.sessionNotFound(id) }
        return session
    }

    func makePrivateTemporaryDirectory(label: String) throws -> URL {
        let url = store.rootURL.appendingPathComponent("tmp/\(label)", isDirectory: true)
        try AuditStore.createPrivateDirectory(url)
        return url
    }

    func makeFreshPrivateTemporaryDirectory(label: String) throws -> URL {
        let root = store.rootURL.appendingPathComponent("tmp", isDirectory: true)
        try AuditStore.createPrivateDirectory(root)
        let url = root.appendingPathComponent("\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        guard mkdir(url.path, mode_t(0o700)) == 0 else {
            throw AgentBridgeError.persistence("Could not create a new private usage TUI working directory.")
        }
        guard chmod(url.path, mode_t(0o700)) == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw AgentBridgeError.persistence("Could not set permissions on the usage TUI working directory.")
        }
        return url
    }

    func safeProviderSessionID(_ value: String?) -> String? {
        guard let value, value.count <= 200, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }
}

final class ProgressEmitter: @unchecked Sendable {
    private let sessionID: UUID
    private let store: AuditStore
    private let callback: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var previous: String?

    init(sessionID: UUID, store: AuditStore, callback: (@Sendable (String) -> Void)?) {
        self.sessionID = sessionID
        self.store = store
        self.callback = callback
    }

    func emit(_ message: String) {
        lock.lock()
        let isNew = previous != message
        previous = message
        lock.unlock()
        guard isNew else { return }
        try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.progress", message: message))
        callback?(message)
    }
}
