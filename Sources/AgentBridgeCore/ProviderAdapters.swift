import CoreFoundation
import Darwin
import Foundation

public struct AuthAssessment: Equatable, Sendable {
    public let provider: AgentProvider
    public let confirmedSubscription: Bool
    public let message: String
    public let accountLabel: String?
    public let planName: String?
    public let localEndpointReachable: Bool?

    public init(
        provider: AgentProvider,
        confirmedSubscription: Bool,
        message: String,
        accountLabel: String? = nil,
        planName: String? = nil,
        localEndpointReachable: Bool? = nil
    ) {
        self.provider = provider
        self.confirmedSubscription = confirmedSubscription
        self.message = message
        self.accountLabel = accountLabel
        self.planName = planName
        self.localEndpointReachable = localEndpointReachable
    }
}

public struct ProviderInvocation: Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectoryURL: URL
    public let standardInput: Data
    public let timeout: TimeInterval

    public init(executableURL: URL, arguments: [String], environment: [String: String], workingDirectoryURL: URL, standardInput: Data, timeout: TimeInterval) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectoryURL = workingDirectoryURL
        self.standardInput = standardInput
        self.timeout = timeout
    }
}

public enum RuntimeEnvironment {
    private static let standardPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let allowedKeys: Set<String> = ["HOME", "USER", "PATH", "TMPDIR", "LANG", "TERM", "CODEX_HOME", "CLAUDE_CONFIG_DIR"]

    public static func sanitized(
        base: [String: String],
        provider: AgentProvider,
        privateTemporaryDirectory: URL,
        apiKey: String? = nil
    ) -> [String: String] {
        var result: [String: String] = [:]
        if let home = base["HOME"], home.hasPrefix("/") { result["HOME"] = home }
        if let user = base["USER"], !user.isEmpty { result["USER"] = user }
        else { result["USER"] = NSUserName() }
        if let language = base["LANG"], language.count <= 64 { result["LANG"] = language }
        result["TERM"] = "dumb"
        result["TMPDIR"] = privateTemporaryDirectory.path
        result["PATH"] = standardPath
        switch provider {
        case .codex:
            if let codexHome = base["CODEX_HOME"], codexHome.hasPrefix("/"), !codexHome.contains("\0") {
                result["CODEX_HOME"] = codexHome
            }
        case .claude:
            if let configDirectory = base["CLAUDE_CONFIG_DIR"], configDirectory.hasPrefix("/"), !configDirectory.contains("\0") {
                result["CLAUDE_CONFIG_DIR"] = configDirectory
            }
        case .local:
            break
        }
        result = result.filter { allowedKeys.contains($0.key) }
        if provider == .claude, let apiKey, !apiKey.isEmpty, !apiKey.contains("\0") {
            result["ANTHROPIC_API_KEY"] = apiKey
        }
        return result
    }

    public static func resolveExecutable(
        provider: AgentProvider,
        configuredPath: String?,
        searchPath: String = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    ) throws -> URL {
        guard provider != .local else {
            throw AgentBridgeError.sessionMismatch("Local models use a direct local HTTP connection and do not launch a CLI.")
        }
        let expected = provider.rawValue
        if let configuredPath, !configuredPath.isEmpty {
            let url = URL(fileURLWithPath: configuredPath).standardizedFileURL
            guard url.lastPathComponent == expected, FileManager.default.isExecutableFile(atPath: url.path) else {
                throw AgentBridgeError.invalidInput("\(expected) executable path must point to an executable \(expected) file.")
            }
            return url
        }
        for directory in searchPath.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent(expected)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        throw AgentBridgeError.missingExecutable(provider)
    }
}

public enum AuthStatusClassifier {
    public static func codex(stdout: Data, stderr: Data, exitCode: Int32) -> AuthAssessment {
        guard exitCode == 0 else {
            return AuthAssessment(provider: .codex, confirmedSubscription: false, message: "Sign-in status could not be confirmed. Check sign-in in the official CLI.")
        }
        guard let status = String(data: stdout + stderr, encoding: .utf8)?.lowercased() else {
            return AuthAssessment(provider: .codex, confirmedSubscription: false, message: "The sign-in status format could not be confirmed.")
        }
        if status.contains("api key") || status.contains("api_key") || status.contains("api-key") {
            return AuthAssessment(provider: .codex, confirmedSubscription: false, message: "API key sign-in was detected. This version accepts ChatGPT subscription sign-in only.")
        }
        if status.contains("logged in using chatgpt") || status.contains("logged in with chatgpt") || status.contains("authenticated with chatgpt") {
            return AuthAssessment(provider: .codex, confirmedSubscription: true, message: "ChatGPT subscription sign-in was confirmed.")
        }
        return AuthAssessment(provider: .codex, confirmedSubscription: false, message: "The sign-in method could not be identified. The run will not start for safety.")
    }

    public static func claude(stdout: Data, stderr: Data, exitCode: Int32) -> AuthAssessment {
        guard exitCode == 0 else {
            return AuthAssessment(provider: .claude, confirmedSubscription: false, message: "Sign-in status could not be confirmed. Check sign-in in the official CLI.")
        }
        let parsed = [stdout, stderr].compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }.first
        guard let json = parsed,
              let loggedIn = json["loggedIn"] as? Bool, loggedIn,
              let method = json["authMethod"] as? String,
              let rawPlan = json["subscriptionType"] as? String,
              let plan = safeStatusValue(rawPlan) else {
            return AuthAssessment(provider: .claude, confirmedSubscription: false, message: "The sign-in method or subscription plan could not be confirmed.")
        }
        guard method.lowercased() == "claude.ai" else {
            return AuthAssessment(provider: .claude, confirmedSubscription: false, message: "The current sign-in is not a claude.ai subscription.")
        }
        let accountLabel = safeStatusValue(json["email"] as? String)
        return AuthAssessment(
            provider: .claude,
            confirmedSubscription: true,
            message: "Claude subscription sign-in confirmed (\(plan)).",
            accountLabel: accountLabel,
            planName: plan
        )
    }

    private static func safeStatusValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...160).contains(trimmed.count),
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return OutputRedactor.redact(trimmed)
    }
}

public final class ProviderAdapter: Sendable {
    private let runner: SafeProcessRunner

    public init(runner: SafeProcessRunner = SafeProcessRunner()) {
        self.runner = runner
    }

    public func checkAuthentication(
        provider: AgentProvider,
        executableURL: URL,
        environment: [String: String],
        temporaryDirectory: URL
    ) async throws -> AuthAssessment {
        guard provider != .local else {
            return AuthAssessment(
                provider: .local,
                confirmedSubscription: false,
                message: "Local models have no subscription sign-in status; test the local server connection."
            )
        }
        let arguments: [String]
        switch provider {
        case .codex:
            arguments = ["login", "status"]
        case .claude:
            arguments = [
                "--restricted", "--safe-mode", "--setting-sources", "",
                "--settings", "{\"disableAllHooks\":true,\"apiKeyHelper\":\"\",\"forceLoginMethod\":\"claudeai\"}",
                "auth", "status", "--json"
            ]
        case .local:
            return AuthAssessment(provider: .local, confirmedSubscription: false, message: "Local models do not read CLI sign-in status.")
        }
        let spec = ProcessSpec(executableURL: executableURL, arguments: arguments, environment: environment, workingDirectoryURL: URL(fileURLWithPath: temporaryDirectory.path, isDirectory: true), standardInput: Data(), timeout: 12, outputLimit: 64_000)
        let result = try await runner.run(spec)
        guard !result.wasCancelled, !result.timedOut, !result.outputWasTruncated else {
            return AuthAssessment(provider: provider, confirmedSubscription: false, message: "Sign-in status could not be confirmed. Check sign-in in the official CLI.")
        }
        switch provider {
        case .codex:
            return AuthStatusClassifier.codex(stdout: result.standardOutput, stderr: result.standardError, exitCode: result.exitCode)
        case .claude:
            return AuthStatusClassifier.claude(stdout: result.standardOutput, stderr: result.standardError, exitCode: result.exitCode)
        case .local:
            return AuthAssessment(provider: .local, confirmedSubscription: false, message: "Local models do not use subscription sign-in.")
        }
    }

    public func runReadOnly(
        provider: AgentProvider,
        session: SessionRecord,
        prompt: String,
        executableURL: URL,
        environment: [String: String],
        cancellationRequestURL: URL?,
        apiBudgetUSD: Double? = nil,
        stateless: Bool = false,
        mcpServerCommands: [MCPServerCommandConfiguration] = [],
        onProgress: (@Sendable (String) -> Void)? = nil,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> (ProcessResult, ProviderOutput) {
        let resumeID = stateless ? nil : session.providerSessionID
        let activeMCPServers = mcpServerCommands
        let mcpEnvironment = activeMCPServers.isEmpty ? [:] : MCPRuntimeEnvironment.nativeServerEnvironment(
            provider: provider,
            privateDirectory: mcpPrivateDirectory(from: environment, fallback: session.workspacePath)
        )
        let arguments: [String]
        if let apiBudgetUSD {
            guard provider == .claude, resumeID == nil else {
                throw AgentBridgeError.sessionMismatch("API mode currently supports only new Claude sessions.")
            }
            arguments = try ProviderCommandBuilder.claudeAPIArguments(
                workspacePath: session.workspacePath,
                budgetUSD: apiBudgetUSD,
                activeMCPServers: activeMCPServers,
                mcpWorkingDirectory: session.workspacePath,
                mcpEnvironment: mcpEnvironment
            )
        } else {
            switch provider {
            case .codex:
                arguments = try ProviderCommandBuilder.codexRunArguments(
                    workspacePath: session.workspacePath,
                    resumeID: resumeID,
                    ephemeral: stateless,
                    activeMCPServers: activeMCPServers,
                    mcpWorkingDirectory: session.workspacePath,
                    mcpEnvironment: mcpEnvironment
                )
            case .claude:
                arguments = try ProviderCommandBuilder.claudeReadOnlyArguments(
                    workspacePath: session.workspacePath,
                    sessionID: session.id,
                    resumeID: resumeID,
                    stateless: stateless,
                    activeMCPServers: activeMCPServers,
                    mcpWorkingDirectory: session.workspacePath,
                    mcpEnvironment: mcpEnvironment
                )
            case .local:
                throw AgentBridgeError.sessionMismatch("Local models do not run through a CLI, MCP or project tools.")
            }
        }
        let lineHandler: (@Sendable (String) -> Void)?
        if let onProgress {
            lineHandler = { @Sendable line in
                if let message = ProviderOutputParser.progressMessage(provider: provider, jsonLine: line) { onProgress(message) }
            }
        } else {
            lineHandler = nil
        }
        let spec = ProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectoryURL: URL(fileURLWithPath: session.workspacePath, isDirectory: true),
            standardInput: Data(prompt.utf8),
            timeout: 300,
            outputLimit: 1_048_576,
            cancellationRequestURL: cancellationRequestURL,
            standardOutputLineHandler: lineHandler
        )
        let result = try await runner.run(spec, cancellation: cancellation)
        if result.timedOut { throw AgentBridgeError.processTimedOut }
        if result.wasCancelled { throw AgentBridgeError.processCancelled }
        guard result.exitCode == 0 else { throw AgentBridgeError.providerFailed(provider, "CLI exit code \(result.exitCode).") }
        let parsed = try ProviderOutputParser.parse(provider: provider, data: result.standardOutput, truncated: result.outputWasTruncated)
        let output = stateless
            ? ProviderOutput(text: parsed.text, providerSessionID: nil, actualCostUSD: parsed.actualCostUSD)
            : parsed
        return (result, output)
    }

    public func runDiscussion(
        provider: AgentProvider,
        discussionWorkspaceURL: URL,
        prompt: String,
        executableURL: URL,
        environment: [String: String],
        cancellationRequestURL: URL?,
        onProgress: (@Sendable (String) -> Void)? = nil,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> (ProcessResult, ProviderOutput) {
        let arguments: [String]
        switch provider {
        case .codex:
            arguments = ProviderCommandBuilder.codexDiscussionArguments(workspacePath: discussionWorkspaceURL.path)
        case .claude:
            arguments = ProviderCommandBuilder.claudeDiscussionArguments()
        case .local:
            throw AgentBridgeError.sessionMismatch("Local models use a direct local HTTP connection and do not launch a CLI.")
        }
        let lineHandler: (@Sendable (String) -> Void)?
        if let onProgress {
            lineHandler = { @Sendable line in
                if let message = ProviderOutputParser.progressMessage(provider: provider, jsonLine: line) {
                    onProgress(message)
                }
            }
        } else {
            lineHandler = nil
        }
        let spec = ProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectoryURL: discussionWorkspaceURL,
            standardInput: Data(prompt.utf8),
            timeout: 300,
            outputLimit: 1_048_576,
            cancellationRequestURL: cancellationRequestURL,
            standardOutputLineHandler: lineHandler
        )
        let result = try await runner.run(spec, cancellation: cancellation)
        if result.timedOut { throw AgentBridgeError.processTimedOut }
        if result.wasCancelled { throw AgentBridgeError.processCancelled }
        guard result.exitCode == 0 else { throw AgentBridgeError.providerFailed(provider, "CLI exit code \(result.exitCode).") }
        return (result, try ProviderOutputParser.parse(provider: provider, data: result.standardOutput, truncated: result.outputWasTruncated))
    }

    public func runChanges(
        provider: AgentProvider,
        session: SessionRecord,
        prompt: String,
        executableURL: URL,
        environment: [String: String],
        cancellationRequestURL: URL?,
        mcpServerCommands: [MCPServerCommandConfiguration] = [],
        onProgress: (@Sendable (String) -> Void)? = nil,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> (ProcessResult, ProviderOutput) {
        let activeMCPServers = mcpServerCommands
        let mcpEnvironment = activeMCPServers.isEmpty ? [:] : MCPRuntimeEnvironment.nativeServerEnvironment(
            provider: provider,
            privateDirectory: mcpPrivateDirectory(from: environment, fallback: session.workspacePath)
        )
        let arguments: [String]
        switch provider {
        case .codex:
            arguments = try ProviderCommandBuilder.codexChangeArguments(
                workspacePath: session.workspacePath,
                resumeID: session.providerSessionID,
                activeMCPServers: activeMCPServers,
                mcpWorkingDirectory: session.workspacePath,
                mcpEnvironment: mcpEnvironment
            )
        case .claude:
            arguments = try ProviderCommandBuilder.claudeChangeArguments(
                workspacePath: session.workspacePath,
                sessionID: session.id,
                resumeID: session.providerSessionID,
                activeMCPServers: activeMCPServers,
                mcpWorkingDirectory: session.workspacePath,
                mcpEnvironment: mcpEnvironment
            )
        case .local:
            throw AgentBridgeError.sessionMismatch("Local models do not support isolated changes.")
        }
        let lineHandler: (@Sendable (String) -> Void)?
        if let onProgress {
            lineHandler = { @Sendable line in
                if let message = ProviderOutputParser.progressMessage(provider: provider, jsonLine: line) {
                    onProgress(message)
                }
            }
        } else {
            lineHandler = nil
        }
        let spec = ProcessSpec(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectoryURL: URL(fileURLWithPath: session.workspacePath, isDirectory: true),
            standardInput: Data(prompt.utf8),
            timeout: 900,
            outputLimit: 1_048_576,
            cancellationRequestURL: cancellationRequestURL,
            standardOutputLineHandler: lineHandler
        )
        let result = try await runner.run(spec, cancellation: cancellation)
        if result.timedOut { throw AgentBridgeError.processTimedOut }
        if result.wasCancelled { throw AgentBridgeError.processCancelled }
        guard result.exitCode == 0 else {
            throw AgentBridgeError.providerFailed(provider, "CLI exit code \(result.exitCode).")
        }
        return (result, try ProviderOutputParser.parse(provider: provider, data: result.standardOutput, truncated: result.outputWasTruncated))
    }

    private func mcpPrivateDirectory(from environment: [String: String], fallback: String) -> URL {
        if let path = environment["TMPDIR"], path.hasPrefix("/"), !path.contains("\0") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: fallback, isDirectory: true)
    }

    public func runInteractiveClaude(
        session: SessionRecord,
        executableURL: URL,
        environment: [String: String],
        cancellationRequestURL: URL?,
        contextFilePath: String? = nil,
        cancellation: CancellationFlag = CancellationFlag(),
        onLaunched: (@Sendable () -> Bool)? = nil
    ) async throws -> ProcessResult {
        try await runInteractive(
            provider: .claude,
            session: session,
            executableURL: executableURL,
            environment: environment,
            cancellationRequestURL: cancellationRequestURL,
            contextFilePath: contextFilePath,
            cancellation: cancellation,
            onLaunched: onLaunched
        )
    }

    public func runInteractive(
        provider: AgentProvider,
        session: SessionRecord,
        executableURL: URL,
        environment: [String: String],
        cancellationRequestURL: URL?,
        contextFilePath: String? = nil,
        cancellation: CancellationFlag = CancellationFlag(),
        onLaunched: (@Sendable () -> Bool)? = nil
    ) async throws -> ProcessResult {
        let arguments: [String]
        switch provider {
        case .codex:
            arguments = try ProviderCommandBuilder.codexInteractiveArguments(
                workspacePath: session.workspacePath,
                resumeID: session.providerSessionID,
                contextFilePath: contextFilePath
            )
        case .claude:
            arguments = try ProviderCommandBuilder.claudeInteractiveArguments(
                workspacePath: session.workspacePath,
                sessionID: session.id,
                resumeID: session.providerSessionID,
                contextFilePath: contextFilePath
            )
        case .local:
            throw AgentBridgeError.sessionMismatch("Local models do not support the native interactive terminal.")
        }
        let result = try await runner.runInteractive(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectoryURL: URL(fileURLWithPath: session.workspacePath, isDirectory: true),
            cancellationRequestURL: cancellationRequestURL,
            cancellation: cancellation,
            onLaunched: onLaunched
        )
        if result.wasCancelled { throw AgentBridgeError.processCancelled }
        guard result.exitCode == 0 else { throw AgentBridgeError.providerFailed(provider, "Interactive CLI exit code \(result.exitCode).") }
        return result
    }

    public func runUsageTUI(
        provider: AgentProvider,
        executableURL: URL,
        environment: [String: String],
        workingDirectoryURL: URL,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> ProcessResult {
        let arguments: [String]
        switch provider {
        case .codex:
            arguments = try ProviderCommandBuilder.codexUsageArguments(workingDirectory: workingDirectoryURL.path)
        case .claude:
            arguments = ProviderCommandBuilder.claudeUsageArguments()
        case .local:
            throw AgentBridgeError.sessionMismatch("Local models have no subscription usage terminal.")
        }
        let result = try await runner.runInteractive(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            workingDirectoryURL: workingDirectoryURL,
            cancellationRequestURL: nil,
            cancellation: cancellation
        )
        if result.wasCancelled { throw AgentBridgeError.processCancelled }
        guard result.exitCode == 0 else {
            throw AgentBridgeError.providerFailed(provider, "Interactive usage CLI exit code \(result.exitCode).")
        }
        return result
    }
}
