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

public enum ProviderCommandBuilder {
    /// Builds a disposable Codex conversation outside any Git project. The
    /// working directory is an empty AgentBridge-owned directory, and no MCP
    /// servers, project instructions, Skills, or resume ID are supplied.
    public static func codexDiscussionArguments(workspacePath: String) -> [String] {
        [
            "--no-daemon",
            "--disable", "hooks", "--disable", "plugins", "--disable", "apps",
            "--disable", "skill_mcp_dependency_install", "--disable", "in_app_browser",
            "--sandbox", "read-only", "--cd", workspacePath, "exec",
            "--skip-git-repo-check", "--ephemeral",
            "--json", "--ignore-user-config", "--ignore-rules",
            "-c", "forced_login_method=\"chatgpt\"",
            "-c", "model_provider=\"openai\"",
            "-c", "features.shell_tool=false",
            "-c", "features.multi_agent=false",
            "-c", "features.goals=false",
            "-c", "features.memories=false",
            "-c", "features.remote_plugin=false",
            "-c", "web_search=\"disabled\"",
            "-c", "history.persistence=\"none\"",
            "-"
        ]
    }

    /// Builds a Claude subscription conversation without persistent vendor
    /// history or any built-in, MCP, browser, or slash-command tools.
    public static func claudeDiscussionArguments() -> [String] {
        [
            "--print", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-mode", "dontAsk", "--permission-prompts", "none", "--restricted", "--safe-mode",
            "--setting-sources", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
            "--disable-slash-commands", "--no-chrome",
            "--settings", "{\"disableAllHooks\":true,\"apiKeyHelper\":\"\",\"forceLoginMethod\":\"claudeai\"}",
            "--tools", "", "--no-session-persistence", "--input-format", "text"
        ]
    }

    public static func codexRunArguments(
        workspacePath: String,
        resumeID: String? = nil,
        ephemeral: Bool = false,
        activeMCPServers: [MCPServerCommandConfiguration] = [],
        mcpWorkingDirectory: String? = nil,
        mcpEnvironment: [String: String] = [:]
    ) throws -> [String] {
        var arguments = [
            "--no-daemon",
            "--disable", "hooks", "--disable", "plugins", "--disable", "apps",
            "--disable", "skill_mcp_dependency_install", "--disable", "in_app_browser",
            "--sandbox", "read-only", "--cd", workspacePath, "exec"
        ]
        if ephemeral { arguments.append("--ephemeral") }
        if let resumeID {
            try validateResumeID(resumeID)
            arguments += ["resume", resumeID]
        }
        arguments += [
            "--json", "--ignore-user-config", "--ignore-rules",
            "-c", "forced_login_method=\"chatgpt\"",
            "-c", "model_provider=\"openai\""
        ]
        let extensionArguments = try codexMCPArguments(
            servers: activeMCPServers,
            projectWorkspacePath: workspacePath,
            workingDirectory: mcpWorkingDirectory ?? workspacePath,
            environment: mcpEnvironment
        )
        arguments += extensionArguments
        arguments.append("-")
        return arguments
    }

    /// Runs headless Codex with scoped `workspace-write` access after AgentBridge
    /// plan approval. Runtime escalation is unavailable, so restricted commands fail closed.
    public static func codexChangeArguments(
        workspacePath: String,
        resumeID: String? = nil,
        activeMCPServers: [MCPServerCommandConfiguration] = [],
        mcpWorkingDirectory: String? = nil,
        mcpEnvironment: [String: String] = [:]
    ) throws -> [String] {
        var arguments = [
            "--no-daemon",
            "--disable", "hooks", "--disable", "plugins", "--disable", "apps",
            "--disable", "skill_mcp_dependency_install", "--disable", "in_app_browser",
            "--sandbox", "workspace-write", "--cd", workspacePath, "exec"
        ]
        if let resumeID {
            try validateResumeID(resumeID)
            arguments += ["resume", resumeID]
        }
        arguments += [
            "--json", "--ignore-user-config", "--ignore-rules",
            "-c", "forced_login_method=\"chatgpt\"",
            "-c", "model_provider=\"openai\""
        ]
        arguments += try codexMCPArguments(
            servers: activeMCPServers,
            projectWorkspacePath: workspacePath,
            workingDirectory: mcpWorkingDirectory ?? workspacePath,
            environment: mcpEnvironment
        )
        arguments.append("-")
        return arguments
    }

    public static func claudeReadOnlyArguments(
        workspacePath: String,
        sessionID: UUID,
        resumeID: String? = nil,
        stateless: Bool = false,
        activeMCPServers: [MCPServerCommandConfiguration] = [],
        mcpWorkingDirectory: String? = nil,
        mcpEnvironment: [String: String] = [:]
    ) throws -> [String] {
        let mcpConfiguration = try claudeMCPConfiguration(
            servers: activeMCPServers,
            workingDirectory: mcpWorkingDirectory ?? workspacePath,
            environment: mcpEnvironment
        )
        let mcpToolNames = try claudeMCPToolNames(activeMCPServers)
        let builtInTools = ["Read", "Glob", "Grep"]
        var arguments = [
            "--print", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-mode", "dontAsk", "--permission-prompts", "none",
            "--restricted"
        ]
        if activeMCPServers.isEmpty { arguments.append("--safe-mode") }
        arguments += [
            "--setting-sources", "",
            "--strict-mcp-config", "--mcp-config", mcpConfiguration,
            "--disable-slash-commands", "--no-chrome",
            "--settings", "{\"disableAllHooks\":true,\"apiKeyHelper\":\"\",\"forceLoginMethod\":\"claudeai\"}",
            "--tools", builtInTools.joined(separator: ","), "--add-dir", workspacePath,
            "--input-format", "text"
        ]
        if stateless { arguments.append("--no-session-persistence") }
        if !mcpToolNames.isEmpty { arguments += ["--allowedTools"] + mcpToolNames }
        if stateless {
            // The application-owned compressed transcript is the complete
            // context for this invocation. Do not create or resume vendor history.
        } else if let resumeID {
            try validateResumeID(resumeID)
            arguments += ["--resume", resumeID]
        } else {
            arguments += ["--session-id", sessionID.uuidString.lowercased()]
        }
        return arguments
    }

    /// Allows file-editing tools after AgentBridge has recorded plan approval.
    /// MCP access, when explicitly enabled, is limited by the per-run proxy ticket.
    public static func claudeChangeArguments(
        workspacePath: String,
        sessionID: UUID,
        resumeID: String? = nil,
        activeMCPServers: [MCPServerCommandConfiguration] = [],
        mcpWorkingDirectory: String? = nil,
        mcpEnvironment: [String: String] = [:]
    ) throws -> [String] {
        let mcpConfiguration = try claudeMCPConfiguration(
            servers: activeMCPServers,
            workingDirectory: mcpWorkingDirectory ?? workspacePath,
            environment: mcpEnvironment
        )
        let mcpToolNames = try claudeMCPToolNames(activeMCPServers)
        let builtInTools = ["Read", "Glob", "Grep", "Edit", "Write"]
        var arguments = [
            "--print", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-mode", "acceptEdits", "--permission-prompts", "none",
            "--restricted"
        ]
        if activeMCPServers.isEmpty { arguments.append("--safe-mode") }
        arguments += [
            "--setting-sources", "",
            "--strict-mcp-config", "--mcp-config", mcpConfiguration,
            "--disable-slash-commands", "--no-chrome",
            "--settings", "{\"disableAllHooks\":true,\"apiKeyHelper\":\"\",\"forceLoginMethod\":\"claudeai\"}",
            "--tools", builtInTools.joined(separator: ","), "--add-dir", workspacePath,
            "--input-format", "text"
        ]
        if !mcpToolNames.isEmpty { arguments += ["--allowedTools"] + mcpToolNames }
        if let resumeID {
            try validateResumeID(resumeID)
            arguments += ["--resume", resumeID]
        } else {
            arguments += ["--session-id", sessionID.uuidString.lowercased()]
        }
        return arguments
    }

    public static func codexInteractiveArguments(
        workspacePath: String,
        resumeID: String? = nil,
        contextFilePath: String? = nil
    ) throws -> [String] {
        var arguments = [
            "--no-daemon",
            "--disable", "hooks", "--disable", "plugins", "--disable", "apps",
            "--disable", "skill_mcp_dependency_install", "--disable", "in_app_browser",
            "--sandbox", "read-only", "--ask-for-approval", "on-request", "--cd", workspacePath,
            "-c", "forced_login_method=\"chatgpt\"",
            "-c", "model_provider=\"openai\""
        ]
        if let contextFilePath {
            let contents = try contextFileContents(at: contextFilePath)
            arguments += ["-c", "developer_instructions=\(tomlBasicString(contents))"]
        }
        if let resumeID {
            try validateResumeID(resumeID)
            arguments += ["resume", resumeID]
        }
        return arguments
    }

    /// Starts the native Codex TUI in an empty directory with read-only
    /// permissions. No prompt or subcommand is supplied so slash commands
    /// remain available for user invocation.
    public static func codexUsageArguments(workingDirectory: String) throws -> [String] {
        try validateWorkingDirectory(workingDirectory)
        return [
            "--no-daemon",
            "--disable", "hooks", "--disable", "plugins", "--disable", "apps",
            "--disable", "skill_mcp_dependency_install", "--disable", "in_app_browser",
            "--sandbox", "read-only", "--ask-for-approval", "never", "--cd", workingDirectory,
            "-c", "forced_login_method=\"chatgpt\"",
            "-c", "model_provider=\"openai\""
        ]
    }

    /// Starts Claude Code's native TUI without loading user customizations or
    /// tools. Deliberately leaves slash commands enabled for /usage.
    public static func claudeUsageArguments() -> [String] {
        [
            "--restricted", "--safe-mode", "--setting-sources", "",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
            "--no-chrome", "--no-session-persistence",
            "--settings", "{\"disableAllHooks\":true,\"apiKeyHelper\":\"\",\"forceLoginMethod\":\"claudeai\"}",
            "--permission-mode", "plan", "--tools", ""
        ]
    }

    private static func validateWorkingDirectory(_ value: String) throws {
        guard value.hasPrefix("/"), !value.contains("\0"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentBridgeError.invalidInput("Usage TUI working directory is invalid.")
        }
    }

    private static func validatedContextFilePath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentBridgeError.invalidInput("Shared-memory context path is invalid.")
        }
        return path
    }

    private static func contextFileContents(at path: String) throws -> String {
        let validatedPath = try validatedContextFilePath(path)
        let descriptor = validatedPath.withCString { open($0, O_RDONLY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw AgentBridgeError.invalidInput("Shared-memory context file is unavailable or unsafe.")
        }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              (metadata.st_mode & 0o077) == 0,
              metadata.st_size >= 0,
              metadata.st_size <= 64 * 1_024 else {
            throw AgentBridgeError.invalidInput("Shared-memory context file must be a private, bounded regular file.")
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 8 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentBridgeError.invalidInput("Shared-memory context file could not be read.")
            }
            if count == 0 { break }
            guard data.count + count <= 64 * 1_024 else {
                throw AgentBridgeError.invalidInput("Shared-memory context file exceeds the size limit.")
            }
            data.append(contentsOf: buffer[0..<count])
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw AgentBridgeError.invalidInput("Shared-memory context file must contain UTF-8 text.")
        }
        return contents
    }

    /// Encode a TOML basic string for Codex's `-c key=value` override.
    private static func tomlBasicString(_ value: String) -> String {
        var encoded = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: encoded += "\\\""
            case 0x5C: encoded += "\\\\"
            case 0x08: encoded += "\\b"
            case 0x09: encoded += "\\t"
            case 0x0A: encoded += "\\n"
            case 0x0C: encoded += "\\f"
            case 0x0D: encoded += "\\r"
            case 0x00...0x1F, 0x7F...0x9F:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                encoded += "\\u" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
            default:
                encoded.unicodeScalars.append(scalar)
            }
        }
        encoded += "\""
        return encoded
    }

    public static func claudeInteractiveArguments(
        workspacePath: String,
        sessionID: UUID,
        resumeID: String? = nil,
        contextFilePath: String? = nil
    ) throws -> [String] {
        var arguments = [
            "--restricted", "--safe-mode", "--setting-sources", "",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
            "--disable-slash-commands", "--no-chrome",
            "--settings", "{\"disableAllHooks\":true,\"apiKeyHelper\":\"\",\"forceLoginMethod\":\"claudeai\"}",
            "--permission-mode", "manual", "--tools", "Read,Glob,Grep,Edit,Write,Bash",
            "--add-dir", workspacePath
        ]
        if let contextFilePath {
            arguments += ["--append-system-prompt-file", try validatedContextFilePath(contextFilePath)]
        }
        if let resumeID {
            try validateResumeID(resumeID)
            arguments += ["--resume", resumeID]
        } else {
            arguments += ["--session-id", sessionID.uuidString.lowercased()]
        }
        return arguments
    }

    private static func validateResumeID(_ value: String) throws {
        guard UUID(uuidString: value) != nil else {
            throw AgentBridgeError.sessionMismatch("The provider session ID format is invalid. Resume was rejected to prevent argument injection.")
        }
    }

    public static func claudeAPIArguments(
        workspacePath: String,
        budgetUSD: Double,
        activeMCPServers: [MCPServerCommandConfiguration] = [],
        mcpWorkingDirectory: String? = nil,
        mcpEnvironment: [String: String] = [:]
    ) throws -> [String] {
        let cents = (budgetUSD * 100).rounded()
        guard budgetUSD.isFinite, budgetUSD >= 0.01, budgetUSD <= 140, abs((cents / 100) - budgetUSD) < 0.000_000_1 else {
            throw AgentBridgeError.invalidInput("The Claude API per-run cap must be between US$0.01 and US$140 with at most two decimal places.")
        }
        let formattedBudget = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), budgetUSD)
        let mcpConfiguration = try claudeMCPConfiguration(
            servers: activeMCPServers,
            workingDirectory: mcpWorkingDirectory ?? workspacePath,
            environment: mcpEnvironment
        )
        let mcpToolNames = try claudeMCPToolNames(activeMCPServers)
        let builtInTools = ["Read", "Glob", "Grep"]
        var arguments = [
            "--print", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--permission-mode", "dontAsk", "--permission-prompts", "none",
            "--restricted"
        ]
        if activeMCPServers.isEmpty { arguments.append("--safe-mode") }
        arguments += [
            "--setting-sources", "",
            "--strict-mcp-config", "--mcp-config", mcpConfiguration,
            "--disable-slash-commands", "--no-chrome",
            "--settings", "{\"disableAllHooks\":true,\"apiKeyHelper\":\"\",\"forceLoginMethod\":\"console\"}",
            "--tools", builtInTools.joined(separator: ","), "--add-dir", workspacePath,
            "--input-format", "text", "--no-session-persistence",
            "--max-budget-usd", formattedBudget, "--max-turns", "3"
        ]
        if !mcpToolNames.isEmpty { arguments += ["--allowedTools"] + mcpToolNames }
        return arguments
    }

    private static func codexMCPArguments(
        servers: [MCPServerCommandConfiguration],
        projectWorkspacePath: String,
        workingDirectory: String,
        environment: [String: String]
    ) throws -> [String] {
        guard servers.count <= 16 else { throw AgentBridgeError.invalidInput("At most 16 MCP servers can be enabled in one session.") }
        guard isSafeAbsolutePath(projectWorkspacePath) else {
            throw AgentBridgeError.invalidInput("Codex project workspace must be an absolute path for managed MCP isolation.")
        }

        // `--ignore-user-config` skips CODEX_HOME/config.toml but trusted
        // project `.codex/config.toml` files can still add MCP servers. Mark
        // this exact workspace untrusted for the invocation so its project
        // configuration layer is not loaded. This override is needed even
        // when no AgentBridge MCP server is selected.
        var arguments = [
            "-c", "projects.\(tomlBasicString(projectWorkspacePath)).trust_level=\"untrusted\""
        ]
        guard !servers.isEmpty else { return arguments }
        guard isSafeAbsolutePath(workingDirectory) else {
            throw AgentBridgeError.invalidInput("MCP working directory must be an absolute path.")
        }
        guard environment.allSatisfy({ isEnvironmentKey($0.key) && !$0.value.contains("\0") }) else {
            throw AgentBridgeError.invalidInput("MCP server environment contains an invalid key or value.")
        }
        let serverIDs = servers.map(\.serverID)
        guard Set(serverIDs).count == serverIDs.count else {
            throw AgentBridgeError.invalidInput("MCP server IDs must be unique.")
        }
        let serverTables = servers.map { server in
            let fields: [(String, String)] = [
                ("command", tomlBasicString(server.commandPath)),
                ("args", tomlArray(server.arguments)),
                ("cwd", tomlBasicString(workingDirectory)),
                ("env", tomlInlineTable(environment)),
                ("enabled_tools", tomlArray(server.allowedTools)),
                ("required", "true"),
                ("startup_timeout_sec", String(server.startupTimeoutSeconds)),
                ("tool_timeout_sec", String(server.toolTimeoutSeconds))
            ]
            return "\(server.serverID) = { " + fields.map { "\($0.0) = \($0.1)" }.joined(separator: ", ") + " }"
        }
        let serverTable = "{ " + serverTables.joined(separator: ", ") + " }"
        arguments += ["-c", "mcp_servers=\(serverTable)"]
        return arguments
    }

    private static func claudeMCPConfiguration(
        servers: [MCPServerCommandConfiguration],
        workingDirectory: String,
        environment: [String: String]
    ) throws -> String {
        guard servers.count <= 16 else { throw AgentBridgeError.invalidInput("At most 16 MCP servers can be enabled in one session.") }
        guard servers.isEmpty || isSafeAbsolutePath(workingDirectory) else {
            throw AgentBridgeError.invalidInput("MCP working directory must be an absolute path.")
        }
        guard environment.allSatisfy({ isEnvironmentKey($0.key) && !$0.value.contains("\0") }) else {
            throw AgentBridgeError.invalidInput("MCP server environment contains an invalid key or value.")
        }
        var mcpServers: [String: Any] = [:]
        for server in servers {
            guard mcpServers[server.serverID] == nil else { throw AgentBridgeError.invalidInput("MCP server IDs must be unique.") }
            mcpServers[server.serverID] = [
                "type": "stdio",
                "command": server.commandPath,
                "args": server.arguments,
                "cwd": workingDirectory,
                "env": environment,
                "timeout": server.toolTimeoutSeconds * 1_000
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["mcpServers": mcpServers], options: [.sortedKeys, .withoutEscapingSlashes])
        guard let json = String(data: data, encoding: .utf8), json.utf8.count <= 128 * 1_024 else {
            throw AgentBridgeError.invalidInput("Active MCP configuration exceeds its inline size limit.")
        }
        return json
    }

    private static func claudeMCPToolNames(_ servers: [MCPServerCommandConfiguration]) throws -> [String] {
        let names = servers.sorted { $0.extensionID < $1.extensionID }.flatMap { server in
            server.allowedTools.sorted().map { "mcp__\(server.serverID)__\($0)" }
        }
        guard names.allSatisfy({ $0.utf8.count <= 128 }) else {
            throw AgentBridgeError.invalidInput("A fully qualified Claude MCP tool name exceeds Claude's 128-character limit.")
        }
        return names
    }

    private static func tomlArray(_ values: [String]) -> String {
        "[" + values.map(tomlBasicString).joined(separator: ", ") + "]"
    }

    private static func tomlInlineTable(_ values: [String: String]) -> String {
        "{ " + values.keys.sorted().map { "\($0) = \(tomlBasicString(values[$0] ?? ""))" }.joined(separator: ", ") + " }"
    }

    private static func isEnvironmentKey(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    private static func isSafeAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

public enum ProviderOutputParser {
    public static func progressMessage(provider: AgentProvider, jsonLine: String) -> String? {
        guard let data = jsonLine.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return nil }
        switch provider {
        case .codex:
            switch type {
            case "thread.started": return "Codex started working."
            case "turn.started": return "Codex is processing the request."
            case "item.started": return "Codex is inspecting the workspace."
            case "turn.completed": return "Codex completed the response."
            case "turn.failed", "error", "turn_error": return "Codex reported a run error."
            default: return nil
            }
        case .claude:
            switch type {
            case "system": return "Claude started the interaction."
            case "stream_event":
                guard let body = event["event"] as? [String: Any], let eventType = body["type"] as? String else { return nil }
                if eventType == "content_block_delta",
                   let delta = body["delta"] as? [String: Any], delta["type"] as? String == "text_delta" {
                    return "Claude is writing a response."
                }
                if eventType == "content_block_start",
                   let block = body["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                    return "Claude is using a restricted tool."
                }
                return nil
            case "result": return "Claude completed the response."
            case "error": return "Claude reported a run error."
            default: return nil
            }
        case .local:
            return nil
        }
    }

    public static func parse(provider: AgentProvider, data: Data, truncated: Bool = false) throws -> ProviderOutput {
        guard !truncated, let text = String(data: data, encoding: .utf8) else {
            throw AgentBridgeError.unsupportedProviderOutput(provider)
        }
        switch provider {
        case .codex: return try parseCodex(text)
        case .claude: return try parseClaude(text)
        case .local: throw AgentBridgeError.unsupportedProviderOutput(.local)
        }
    }

    private static func parseCodex(_ text: String) throws -> ProviderOutput {
        var finalText = ""
        var sessionID: String?
        var completed = false
        for line in text.split(whereSeparator: \Character.isNewline) {
            if completed { throw AgentBridgeError.unsupportedProviderOutput(.codex) }
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else {
                throw AgentBridgeError.unsupportedProviderOutput(.codex)
            }
            switch type {
            case "thread.started":
                sessionID = event["thread_id"] as? String
            case "item.completed":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let message = item["text"] as? String {
                    finalText += message
                }
            case "turn.completed":
                completed = true
            case "turn.failed", "error", "turn_error":
                throw AgentBridgeError.providerFailed(.codex, "The service reported that the session failed.")
            default:
                if event["error"] != nil { throw AgentBridgeError.providerFailed(.codex, "The service reported an error.") }
            }
        }
        guard completed, !finalText.isEmpty else { throw AgentBridgeError.unsupportedProviderOutput(.codex) }
        return ProviderOutput(text: finalText, providerSessionID: sessionID)
    }

    private static func parseClaude(_ text: String) throws -> ProviderOutput {
        var finalText = ""
        var sessionID: String?
        var actualCostUSD: Double?
        var succeeded = false
        for line in text.split(whereSeparator: \Character.isNewline) {
            if succeeded { throw AgentBridgeError.unsupportedProviderOutput(.claude) }
            guard let data = String(line).data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = event["type"] as? String else {
                throw AgentBridgeError.unsupportedProviderOutput(.claude)
            }
            if let candidate = event["session_id"] as? String { sessionID = candidate }
            switch type {
            case "result":
                if event["is_error"] as? Bool == true {
                    throw AgentBridgeError.providerFailed(.claude, "The service reported a session error.")
                }
                let subtype = event["subtype"] as? String
                guard subtype == "success" else { throw AgentBridgeError.providerFailed(.claude, "The service reported that the session failed.") }
                succeeded = true
                if let result = event["result"] as? String { finalText = result }
                if let rawCost = event["total_cost_usd"] {
                    guard let cost = rawCost as? NSNumber,
                          CFGetTypeID(cost) != CFBooleanGetTypeID(),
                          cost.doubleValue.isFinite, cost.doubleValue >= 0 else {
                        throw AgentBridgeError.providerFailed(.claude, "The service returned an unconfirmed charge. The budget remains reserved, and the run will not be marked successful.")
                    }
                    actualCostUSD = cost.doubleValue
                }
            case "stream_event":
                if let eventBody = event["event"] as? [String: Any],
                   let delta = eventBody["delta"] as? [String: Any],
                   delta["type"] as? String == "text_delta",
                   let fragment = delta["text"] as? String {
                    finalText += fragment
                }
            case "error":
                throw AgentBridgeError.providerFailed(.claude, "The service reported an error.")
            case "system":
                if let subtype = event["subtype"] as? String, subtype.lowercased().contains("error") {
                    throw AgentBridgeError.providerFailed(.claude, "The service reported an error.")
                }
            default:
                break
            }
        }
        guard succeeded, !finalText.isEmpty else { throw AgentBridgeError.unsupportedProviderOutput(.claude) }
        return ProviderOutput(text: finalText, providerSessionID: sessionID, actualCostUSD: actualCostUSD)
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
