import CryptoKit
import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case local
}

public enum LocalModelBackend: String, Codable, CaseIterable, Sendable {
    case ollama
    case openAICompatible
}

/// Connection settings for a model server running on this Mac. The endpoint is
/// validated again at every use and is never sent to a cloud provider.
public struct LocalModelSettings: Codable, Equatable, Sendable {
    public var backend: LocalModelBackend
    public var endpoint: String
    public var model: String
    public var contextWindowTokens: Int
    public var maxOutputTokens: Int

    public init(
        backend: LocalModelBackend = .ollama,
        endpoint: String = "http://127.0.0.1:11434",
        model: String = "",
        contextWindowTokens: Int = 8_192,
        maxOutputTokens: Int = 1_024
    ) {
        self.backend = backend
        self.endpoint = endpoint
        self.model = model
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = maxOutputTokens
    }

    public func validate() throws {
        guard endpoint.utf8.count <= 2_048, !endpoint.contains("\0"),
              model.utf8.count <= 256, !model.contains("\0"),
              (1_024...131_072).contains(contextWindowTokens),
              (1...32_768).contains(maxOutputTokens),
              contextWindowTokens - maxOutputTokens > 512 else {
            throw AgentBridgeError.invalidInput("Local model settings are invalid. Check the endpoint, model name, context window, and output limit.")
        }
    }
}

public struct LocalModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let contextWindowTokens: Int?

    public init(id: String, name: String, contextWindowTokens: Int? = nil) {
        self.id = id
        self.name = name
        self.contextWindowTokens = contextWindowTokens
    }
}

/// A deterministic view of the exact historical context prepared for one
/// request. A nil prompt means the compressor refused to send it safely.
public struct ContextCompressionPreview: Equatable, Sendable {
    public let compressedPrompt: String?
    public let report: ContextCompressionReport
    public let sections: [ContextCompressionSection]
    /// This digest is informational so callers can detect a stale preview; it
    /// is not an authorization token and never bypasses a compression refusal.
    public let previewDigest: String

    public var requiresReview: Bool { report.refusalReason != nil }

    public init(compressedContext: CompressedContext, stalenessToken: String = "") {
        self.compressedPrompt = compressedContext.prompt
        self.report = compressedContext.report
        self.sections = compressedContext.sections
        let payload = [stalenessToken, compressedContext.prompt ?? "<refused>", compressedContext.report.readableLabel]
            .map { "\($0.utf8.count):\($0)" }
            .joined()
        self.previewDigest = SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
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
    case isolatedChanges
}

public struct BridgeSettings: Codable, Equatable, Sendable {
    public var defaultProvider: AgentProvider
    public var usageMode: UsageMode
    public var codexBinaryPath: String?
    public var claudeBinaryPath: String?
    public var localModel: LocalModelSettings

    public init(
        defaultProvider: AgentProvider = .codex,
        usageMode: UsageMode = .subscription,
        codexBinaryPath: String? = nil,
        claudeBinaryPath: String? = nil,
        localModel: LocalModelSettings = LocalModelSettings()
    ) {
        self.defaultProvider = defaultProvider
        self.usageMode = usageMode
        self.codexBinaryPath = codexBinaryPath
        self.claudeBinaryPath = claudeBinaryPath
        self.localModel = localModel
    }

    public func binaryPath(for provider: AgentProvider) -> String? {
        switch provider {
        case .codex: codexBinaryPath
        case .claude: claudeBinaryPath
        case .local: nil
        }
    }

    public mutating func setBinaryPath(_ path: String?, for provider: AgentProvider) {
        switch provider {
        case .codex: codexBinaryPath = path
        case .claude: claudeBinaryPath = path
        case .local: break
        }
    }

    private enum CodingKeys: String, CodingKey {
        case defaultProvider
        case usageMode
        case codexBinaryPath
        case claudeBinaryPath
        case localModel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        defaultProvider = try values.decodeIfPresent(AgentProvider.self, forKey: .defaultProvider) ?? .codex
        usageMode = try values.decodeIfPresent(UsageMode.self, forKey: .usageMode) ?? .subscription
        codexBinaryPath = try values.decodeIfPresent(String.self, forKey: .codexBinaryPath)
        claudeBinaryPath = try values.decodeIfPresent(String.self, forKey: .claudeBinaryPath)
        localModel = try values.decodeIfPresent(LocalModelSettings.self, forKey: .localModel) ?? LocalModelSettings()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(defaultProvider, forKey: .defaultProvider)
        try values.encode(usageMode, forKey: .usageMode)
        try values.encodeIfPresent(codexBinaryPath, forKey: .codexBinaryPath)
        try values.encodeIfPresent(claudeBinaryPath, forKey: .claudeBinaryPath)
        try values.encode(localModel, forKey: .localModel)
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
    public var workspacePath: String
    public let snapshotCommit: String
    public let sourceWasDirty: Bool
    public var providerSessionID: String?
    public let accountProfileID: UUID?
    public var status: SessionStatus
    public let policy: SessionPolicy
    public var changePlan: ChangePlan?
    public var approvedChangePlanDigest: String?
    public var lastChangeRunAt: Date?
    public var verificationPassed: Bool?
    public var verificationDiffDigest: String?
    public var verificationCompletedAt: Date?
    public var changesAcceptedAt: Date?

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
        accountProfileID: UUID? = nil,
        changePlan: ChangePlan? = nil,
        approvedChangePlanDigest: String? = nil,
        lastChangeRunAt: Date? = nil,
        verificationPassed: Bool? = nil,
        verificationDiffDigest: String? = nil,
        verificationCompletedAt: Date? = nil,
        changesAcceptedAt: Date? = nil
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
        self.changePlan = changePlan
        self.approvedChangePlanDigest = approvedChangePlanDigest
        self.lastChangeRunAt = lastChangeRunAt
        self.verificationPassed = verificationPassed
        self.verificationDiffDigest = verificationDiffDigest
        self.verificationCompletedAt = verificationCompletedAt
        self.changesAcceptedAt = changesAcceptedAt
    }
}

/// A reviewable description of the work allowed in one isolated change run.
/// Approval is stored separately on the session so callers cannot create an
/// already-approved plan by constructing this value themselves.
public struct ChangePlan: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let createdAt: Date
    public let title: String
    public let summary: String
    public let steps: [String]

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        createdAt: Date = Date(),
        title: String,
        summary: String,
        steps: [String]
    ) {
        self.id = id
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.title = title
        self.summary = summary
        self.steps = steps
    }

    /// A stable token binds approval to this exact plan and session.
    public var reviewDigest: String {
        let fields = [id.uuidString.lowercased(), sessionID.uuidString.lowercased(), title, summary] + steps
        let payload = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// Normalizes the editable app fields with the same rules used when saving a
/// plan, then checks whether they still describe the saved plan being reviewed.
public struct ChangePlanDraft: Equatable, Sendable {
    public let title: String
    public let summary: String
    public let steps: [String]

    public init(title: String, summary: String, stepsText: String) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.steps = stepsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public func matches(_ plan: ChangePlan) -> Bool {
        title == plan.title && summary == plan.summary && steps == plan.steps
    }
}

public enum ChangeFileStatus: String, Codable, Sendable {
    case modified
    case added
    case deleted
    case untracked
    case typeChanged
    case unknown
}

public struct ChangeFileDiff: Codable, Equatable, Sendable {
    public let path: String
    public let status: ChangeFileStatus
    public let patch: String
    public let isBinary: Bool
    /// `patch` is empty because it is too long to show. The change is still in
    /// `WorkspaceChangeDiff.patch`, which is what gets verified, exported and applied.
    public let isTooLargeToDisplay: Bool
    /// `patch` shows replacement characters for text that is not UTF-8. The original
    /// bytes are still in `WorkspaceChangeDiff.patch`.
    public let hasUndecodableText: Bool

    public init(
        path: String,
        status: ChangeFileStatus,
        patch: String,
        isBinary: Bool,
        isTooLargeToDisplay: Bool = false,
        hasUndecodableText: Bool = false
    ) {
        self.path = path
        self.status = status
        self.patch = patch
        self.isBinary = isBinary
        self.isTooLargeToDisplay = isTooLargeToDisplay
        self.hasUndecodableText = hasUndecodableText
    }
}

public struct WorkspaceChangeDiff: Equatable, Sendable {
    public let baseCommit: String
    public let files: [ChangeFileDiff]
    public let patch: Data

    public init(baseCommit: String, files: [ChangeFileDiff], patch: Data) {
        self.baseCommit = baseCommit
        self.files = files
        self.patch = patch
    }

    public var digest: String {
        SHA256.hash(data: patch).map { String(format: "%02x", $0) }.joined()
    }

    /// Files a reviewer cannot read in full from `ChangeFileDiff.patch`.
    public var partiallyShownFiles: [ChangeFileDiff] {
        files.filter { $0.isTooLargeToDisplay || $0.hasUndecodableText }
    }
}

public struct BranchApplyResult: Equatable, Sendable {
    public let branchName: String
    public let worktreePath: String
    public let changedFileCount: Int

    public init(branchName: String, worktreePath: String, changedFileCount: Int) {
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.changedFileCount = changedFileCount
    }
}

public struct VerificationCommand: Equatable, Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let workingDirectoryPath: String

    public init(executablePath: String, arguments: [String], workingDirectoryPath: String) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectoryPath = workingDirectoryPath
    }
}

public struct VerificationResult: Equatable, Sendable {
    public let command: VerificationCommand?
    public let exitCode: Int32?
    public let durationSeconds: Double
    public let standardOutput: String
    public let standardError: String
    public let wasCancelled: Bool
    public let timedOut: Bool
    public let workspaceChangedDuringVerification: Bool
    public let skippedReason: String?

    public init(
        command: VerificationCommand?,
        exitCode: Int32?,
        durationSeconds: Double,
        standardOutput: String,
        standardError: String,
        wasCancelled: Bool,
        timedOut: Bool,
        workspaceChangedDuringVerification: Bool = false,
        skippedReason: String? = nil
    ) {
        self.command = command
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.standardOutput = OutputRedactor.redact(standardOutput)
        self.standardError = OutputRedactor.redact(standardError)
        self.wasCancelled = wasCancelled
        self.timedOut = timedOut
        self.workspaceChangedDuringVerification = workspaceChangedDuringVerification
        self.skippedReason = skippedReason
    }

    public var succeeded: Bool {
        command != nil && exitCode == 0 && !wasCancelled && !timedOut && !workspaceChangedDuringVerification && skippedReason == nil
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
    case changePlanRequired
    case invalidChangePlan(String)
    case sourceBaseConflict(expected: String, actual: String)
    case verificationRequired
    case verificationCommandRejected(String)
    case processTimedOut
    case processCancelled
    case processLaunchFailed(String)
    case persistence(String)
    case git(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message): message
        case .missingExecutable(let provider): "Could not find \(provider.rawValue) CLI. Specify its executable path in Settings."
        case .unsupportedAPIUsage: "AgentBridge 0.5.0 does not support this paid API operation. No model service was called."
        case .unauthenticated(let provider, let reason): "\(provider.rawValue)  has no confirmed subscription sign-in: \(reason)"
        case .unsupportedProviderOutput(let provider): "\(provider.rawValue)  CLI returned an output format that could not be confirmed as successful."
        case .providerFailed(let provider, let reason): "\(provider.rawValue) run failed: \(reason)"
        case .sessionNotFound(let id): "Could not find session \(id.uuidString)."
        case .sessionMismatch(let message): message
        case .workspaceChanged: "The isolated workspace has changed. Create a new session to pin the new commit."
        case .changePlanRequired: "Review and approve the current work plan before starting isolated changes."
        case .invalidChangePlan(let message): "Invalid work plan: \(message)"
        case .sourceBaseConflict(let expected, let actual): "The source repository has changed, so this change cannot be applied. Session base: \(expected.prefix(12)); current source version: \(actual.prefix(12))."
        case .verificationRequired: "Complete workspace verification successfully before applying or accepting changes."
        case .verificationCommandRejected(let message): "Verification command rejected: \(message)"
        case .processTimedOut: "The run timed out and the child process was stopped."
        case .processCancelled: "The run was cancelled."
        case .processLaunchFailed(let message): "Could not launch the child process: \(message)"
        case .persistence(let message): "Could not save session data: \(message)"
        case .git(let message): "Could not create the isolated Git workspace: \(message)"
        }
    }
}

public enum RuntimePaths {
    public static func applicationSupportRoot(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("AgentBridge", isDirectory: true)
    }
}
