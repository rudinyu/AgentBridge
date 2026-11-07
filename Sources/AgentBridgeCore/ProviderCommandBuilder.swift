import CoreFoundation
import Darwin
import Foundation

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
    /// tools. Deliberately leaves slash commands enabled for /usage. Claude refuses
    /// `--no-session-persistence` outside `--print`, so what the session leaves is
    /// purged when it closes instead.
    public static func claudeUsageArguments() -> [String] {
        [
            "--restricted", "--safe-mode", "--setting-sources", "",
            "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
            "--no-chrome",
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
