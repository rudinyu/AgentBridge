import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
}

public enum UsageMode: String, Codable, CaseIterable, Sendable {
    case subscription
    case api
}

public enum SessionStatus: String, Codable, Sendable {
    case created
    case running
    case completed
    case failed
    case cancelled
}

public enum AccessMode: String, Codable, Sendable {
    case readOnly
    case interactiveManualApproval
}

public struct BridgeSettings: Codable, Equatable, Sendable {
    public var defaultProvider: AgentProvider
    public var usageMode: UsageMode
    public var codexBinaryPath: String?
    public var claudeBinaryPath: String?

    public init(
        defaultProvider: AgentProvider = .codex,
        usageMode: UsageMode = .subscription,
        codexBinaryPath: String? = nil,
        claudeBinaryPath: String? = nil
    ) {
        self.defaultProvider = defaultProvider
        self.usageMode = usageMode
        self.codexBinaryPath = codexBinaryPath
        self.claudeBinaryPath = claudeBinaryPath
    }

    public func binaryPath(for provider: AgentProvider) -> String? {
        switch provider {
        case .codex: codexBinaryPath
        case .claude: claudeBinaryPath
        }
    }

    public mutating func setBinaryPath(_ path: String?, for provider: AgentProvider) {
        switch provider {
        case .codex: codexBinaryPath = path
        case .claude: claudeBinaryPath = path
        }
    }
}

public struct SessionPolicy: Codable, Equatable, Sendable {
    public let accessMode: AccessMode
    public let workspaceReadOnly: Bool
    public let apiModeAllowed: Bool

    public init(accessMode: AccessMode = .readOnly, workspaceReadOnly: Bool = true, apiModeAllowed: Bool = false) {
        self.accessMode = accessMode
        self.workspaceReadOnly = workspaceReadOnly
        self.apiModeAllowed = apiModeAllowed
    }
}

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public let provider: AgentProvider
    public let sourceRepositoryPath: String
    public let workspacePath: String
    public let snapshotCommit: String
    public let sourceWasDirty: Bool
    public var providerSessionID: String?
    public let accountProfileID: UUID?
    public var status: SessionStatus
    public let policy: SessionPolicy

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        provider: AgentProvider,
        sourceRepositoryPath: String,
        workspacePath: String,
        snapshotCommit: String,
        sourceWasDirty: Bool,
        providerSessionID: String? = nil,
        status: SessionStatus = .created,
        policy: SessionPolicy = SessionPolicy(),
        accountProfileID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.provider = provider
        self.sourceRepositoryPath = sourceRepositoryPath
        self.workspacePath = workspacePath
        self.snapshotCommit = snapshotCommit
        self.sourceWasDirty = sourceWasDirty
        self.providerSessionID = providerSessionID
        self.accountProfileID = accountProfileID
        self.status = status
        self.policy = policy
    }
}

public struct AuditEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let sessionID: UUID
    public let kind: String
    public let message: String

    public init(id: UUID = UUID(), timestamp: Date = Date(), sessionID: UUID, kind: String, message: String) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.kind = kind
        self.message = OutputRedactor.redact(message)
    }
}

public struct ProviderOutput: Equatable, Sendable {
    public let text: String
    public let providerSessionID: String?
    public let actualCostUSD: Double?

    public init(text: String, providerSessionID: String?, actualCostUSD: Double? = nil) {
        self.text = OutputRedactor.redact(text)
        self.providerSessionID = providerSessionID
        self.actualCostUSD = actualCostUSD
    }
}

public struct APIUsageRequest: Sendable {
    public let requestedBudgetUSD: Double
    public let explicitlyAuthorized: Bool
    public let apiKey: String

    public init(requestedBudgetUSD: Double, explicitlyAuthorized: Bool, apiKey: String) {
        self.requestedBudgetUSD = requestedBudgetUSD
        self.explicitlyAuthorized = explicitlyAuthorized
        self.apiKey = apiKey
    }
}

public enum AgentBridgeError: Error, LocalizedError, Equatable {
    case invalidInput(String)
    case missingExecutable(AgentProvider)
    case unsupportedAPIUsage
    case unauthenticated(AgentProvider, String)
    case unsupportedProviderOutput(AgentProvider)
    case providerFailed(AgentProvider, String)
    case sessionNotFound(UUID)
    case sessionMismatch(String)
    case workspaceChanged
    case processTimedOut
    case processCancelled
    case processLaunchFailed(String)
    case persistence(String)
    case git(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        case .missingExecutable(let provider): "找不到 \(provider.rawValue) CLI，請在設定中指定執行檔路徑。"
        case .unsupportedAPIUsage: "AgentBridge 0.4.0 不支援這項 API 付費操作；本次未呼叫模型服務。"
        case .unauthenticated(let provider, let reason): "\(provider.rawValue) 沒有可確認的訂閱登入：\(reason)"
        case .unsupportedProviderOutput(let provider): "\(provider.rawValue) CLI 回傳無法確認成功的輸出格式。"
        case .providerFailed(let provider, let reason): "\(provider.rawValue) 執行失敗：\(reason)"
        case .sessionNotFound(let id): "找不到工作階段 \(id.uuidString)。"
        case .sessionMismatch(let message): message
        case .workspaceChanged: "隔離工作區已改變。請建立新的工作階段以固定新的提交版本。"
        case .processTimedOut: "執行逾時，已停止子程序。"
        case .processCancelled: "執行已取消。"
        case .processLaunchFailed(let message): "無法啟動子程序：\(message)"
        case .persistence(let message): "無法保存工作階段資料：\(message)"
        case .git(let message): "建立 Git 隔離工作區失敗：\(message)"
        }
    }
}

public enum RuntimePaths {
    public static func applicationSupportRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("AgentBridge", isDirectory: true)
    }
}
