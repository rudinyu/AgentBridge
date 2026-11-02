import CryptoKit
import Darwin
import Foundation

enum MCPExecutableValidation {
    static let maximumExecutableBytes: off_t = 256 * 1_024 * 1_024

    static func resolveAndDigest(_ path: String) throws -> (path: String, digest: String) {
        let original = try ActiveExtensionValidation.absoluteExecutablePath(path)
        var resolvedBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard original.withCString({ realpath($0, &resolvedBuffer) }) != nil else { throw invalidExecutable() }
        let resolved = String(cString: resolvedBuffer)
        let digest = try digestExecutable(at: resolved)
        return (resolved, digest)
    }

    static func digestExecutable(at path: String) throws -> String {
        guard let preservedPath = ActiveExtensionValidation.preservedAbsolutePath(path) else { throw invalidExecutable() }
        let components = preservedPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let fileName = components.last, !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw ActiveExtensionRuntimeError.invalidConfiguration("MCP command path is invalid.")
        }

        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw invalidExecutable() }
        defer { _ = close(directory) }
        for component in components.dropLast() {
            let child = component.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
            guard child >= 0 else { throw invalidExecutable() }
            _ = close(directory)
            directory = child
        }

        let descriptor = fileName.withCString { openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw invalidExecutable() }
        defer { _ = close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              (before.st_mode & 0o111) != 0,
              before.st_size > 0,
              before.st_size <= maximumExecutableBytes else {
            throw invalidExecutable()
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
        var total = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw invalidExecutable()
            }
            if count == 0 { break }
            total += count
            guard total <= maximumExecutableBytes else { throw invalidExecutable() }
            hasher.update(data: Data(buffer.prefix(count)))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              (after.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              sameFile(before, after),
              after.st_size == off_t(total),
              FileManager.default.isExecutableFile(atPath: path) else {
            throw ActiveExtensionRuntimeError.invalidConfiguration("MCP command changed while its executable digest was checked.")
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func invalidExecutable() -> ActiveExtensionRuntimeError {
        .invalidConfiguration("MCP command must resolve to a regular, executable, non-symlink file no larger than 256 MiB.")
    }
}

enum MCPRuntimeEnvironment {
    private static let serverPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    static func probeEnvironment(base: [String: String], privateDirectory: URL) -> [String: String] {
        var environment: [String: String] = [
            "HOME": privateDirectory.path,
            "TMPDIR": privateDirectory.path,
            "PATH": serverPath,
            "TERM": "dumb",
            "USER": base["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? NSUserName()
        ]
        if let language = base["LANG"], language.utf8.count <= 64,
           !language.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            environment["LANG"] = language
        }
        return environment
    }

    /// Native CLI config env fields override the provider process's account
    /// homes and known API-key variables for the server child. It does not
    /// create an OS sandbox; the explicit activation warning remains required.
    static func nativeServerEnvironment(
        provider: AgentProvider,
        privateDirectory: URL,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = probeEnvironment(base: base, privateDirectory: privateDirectory)
        environment["CODEX_HOME"] = privateDirectory.path
        environment["CLAUDE_CONFIG_DIR"] = privateDirectory.path
        for key in [
            "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY",
            "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "GITHUB_TOKEN", "GH_TOKEN"
        ] {
            environment[key] = ""
        }
        if provider == .codex { environment["CODEX_HOME"] = privateDirectory.path }
        if provider == .claude { environment["CLAUDE_CONFIG_DIR"] = privateDirectory.path }
        return environment
    }
}

enum MCPServerIdentifier {
    static func make(extensionID: String) -> String {
        let digest = SHA256.hash(data: Data(extensionID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "ab_" + String(digest.prefix(16))
    }
}

struct MCPToolCallReply: Equatable {
    let isError: Bool
    let text: [String]
}

enum MCPStdioRuntime {
    static func inspect(
        configuration: ActiveMCPConfiguration,
        baseEnvironment: [String: String],
        privateDirectory: URL,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> MCPServerInspection {
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                let connection = try MCPStdioConnection(configuration: configuration, environment: MCPRuntimeEnvironment.probeEnvironment(base: baseEnvironment, privateDirectory: privateDirectory), cancellation: cancellation, createsProcessGroup: true)
                defer { connection.close() }
                let names = try connection.initializeAndListTools()
                let definitionsData = try connection.listToolDefinitions()
                guard definitionsData.count <= MCPServerInspection.maximumToolDefinitionsBytes,
                      let toolDefinitionsJSON = String(data: definitionsData, encoding: .utf8) else {
                    throw MCPProbeError.responseTooLarge
                }
                let inspectionDigest = MCPServerInspection.makeDigest(configurationDigest: configuration.configurationDigest, toolNames: names, toolDefinitionsJSON: toolDefinitionsJSON)
                return MCPServerInspection(
                    extensionID: configuration.extensionID,
                    configurationDigest: configuration.configurationDigest,
                    toolNames: names,
                    toolDefinitionsJSON: toolDefinitionsJSON,
                    inspectionDigest: inspectionDigest,
                    diagnostics: ["MCP initialize succeeded.", "tools/list succeeded; no tool was called."],
                    inspectedAt: Date()
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func callToolForTesting(
        configuration: ActiveMCPConfiguration,
        environment: [String: String],
        privateDirectory: URL,
        toolName: String,
        arguments: [String: Any],
        cancellation: CancellationFlag = CancellationFlag()
    ) throws -> MCPToolCallReply {
        guard configuration.allowedTools.contains(toolName), ActiveExtensionValidation.isToolName(toolName) else {
            throw ActiveExtensionRuntimeError.invalidConfiguration("The requested MCP test tool is outside the exact allowlist.")
        }
        let connection = try MCPStdioConnection(configuration: configuration, environment: MCPRuntimeEnvironment.probeEnvironment(base: environment, privateDirectory: privateDirectory), cancellation: cancellation, createsProcessGroup: true)
        defer { connection.close() }
        let names = try connection.initializeAndListTools()
        guard names.contains(toolName) else { throw ActiveExtensionRuntimeError.inspectionMismatch(configuration.extensionID) }
        let argumentsData = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .fragmentsAllowed])
        let resultData = try connection.callTool(name: toolName, argumentsJSON: argumentsData)
        let result = try JSONSerialization.jsonObject(with: resultData, options: [.fragmentsAllowed]) as? [String: Any] ?? [:]
        let isError = result["isError"] as? Bool ?? false
        let content = result["content"] as? [[String: Any]] ?? []
        let text = content.compactMap { item -> String? in
            guard item["type"] as? String == "text", let value = item["text"] as? String else { return nil }
            return value
        }
        return MCPToolCallReply(isError: isError, text: text)
    }
}

/// A bounded MCP stdio client. It can be held for a session so stateful helpers
/// (such as screenshot or pointer state) are not restarted between tool calls.
public final class MCPStdioConnection {
    private static let maximumRequestOrStartupLineBytes = 1 * 1_024 * 1_024
    private static let maximumJSONEnvelopeBytes = 64 * 1_024
    private static let maximumOutputBytes = 40 * 1_024 * 1_024
    private static let maximumToolCount = 512
    private static let maximumPages = 16

    private let configuration: ActiveMCPConfiguration
    private let environment: [String: String]
    private let cancellation: CancellationFlag
    private let createsProcessGroup: Bool
    private var processID: pid_t = 0
    private var inputFD: Int32 = -1
    private var outputFD: Int32 = -1
    private var errorFD: Int32 = -1
    private var pendingOutput = Data()
    private var pendingMessages: [[String: Any]] = []
    private var totalOutputBytes = 0
    private var currentResponseLineLimit = MCPStdioConnection.maximumRequestOrStartupLineBytes
    private var nextRequestID = 1
    private var started = false
    private var stopped = false
    private var initialized = false
    private var listedToolNames: [String] = []
    private var listedToolDefinitions: [[String: Any]] = []
    private var toolCallCount = 0
    private var totalToolResponseBytes = 0
    private let maximumToolCallsPerRun: Int
    private let maximumToolResponseBytes: Int
    private let maximumTotalToolResponseBytes: Int

    public init(
        configuration: ActiveMCPConfiguration,
        environment: [String: String],
        cancellation: CancellationFlag = CancellationFlag(),
        createsProcessGroup: Bool = false,
        maximumToolCallsPerRun: Int? = nil,
        maximumToolResponseBytes: Int? = nil,
        maximumTotalToolResponseBytes: Int? = nil
    ) throws {
        self.configuration = configuration
        self.environment = environment
        self.cancellation = cancellation
        self.createsProcessGroup = createsProcessGroup
        let calls = maximumToolCallsPerRun ?? configuration.maximumToolCallsPerRun
        let oneResponse = maximumToolResponseBytes ?? configuration.maximumToolResponseBytes
        let totalResponses = maximumTotalToolResponseBytes ?? configuration.maximumTotalToolResponseBytes
        guard (1...configuration.maximumToolCallsPerRun).contains(calls),
              (64 * 1_024...configuration.maximumToolResponseBytes).contains(oneResponse),
              (oneResponse...configuration.maximumTotalToolResponseBytes).contains(totalResponses) else {
            throw ActiveExtensionRuntimeError.invalidConfiguration("MCP runtime limits may not exceed the reviewed configuration.")
        }
        self.maximumToolCallsPerRun = calls
        self.maximumToolResponseBytes = oneResponse
        self.maximumTotalToolResponseBytes = totalResponses
    }

    deinit { stop(force: true) }

    public func initializeAndListTools() throws -> [String] {
        if initialized { return listedToolNames }
        try start()
        do {
            try initialize()
            var cursor: String?
            var seenCursors = Set<String>()
            var names: [String] = []
            var seenNames = Set<String>()
            var definitions: [[String: Any]] = []
            for _ in 0..<Self.maximumPages {
                var params: [String: Any] = [:]
                if let cursor { params["cursor"] = cursor }
                let result = try request("tools/list", params: params, timeout: TimeInterval(configuration.startupTimeoutSeconds))
                guard let tools = result["tools"] as? [[String: Any]], tools.count <= Self.maximumToolCount else {
                    throw MCPProbeError.invalidResponse
                }
                for tool in tools {
                    guard let name = tool["name"] as? String,
                          ActiveExtensionValidation.isToolName(name), seenNames.insert(name).inserted else {
                        throw MCPProbeError.invalidResponse
                    }
                    names.append(name)
                    definitions.append(tool)
                    guard names.count <= Self.maximumToolCount else { throw MCPProbeError.responseTooLarge }
                }
                guard let next = result["nextCursor"] as? String else {
                    listedToolNames = names.sorted()
                    listedToolDefinitions = definitions.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
                    initialized = true
                    return listedToolNames
                }
                guard !next.isEmpty, next.utf8.count <= 2_048,
                      !next.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      seenCursors.insert(next).inserted else { throw MCPProbeError.invalidResponse }
                cursor = next
                guard names.count < Self.maximumToolCount else { throw MCPProbeError.responseTooLarge }
                guard seenCursors.count < Self.maximumPages else { throw MCPProbeError.paginationLimit }
            }
            throw MCPProbeError.paginationLimit
        } catch {
            stop(force: true)
            throw error
        }
    }

    public func listTools() throws -> [String] { try initializeAndListTools() }

    /// Returns the bounded MCP tool definitions as JSON for a filtering proxy.
    /// The proxy must still remove every name outside the exact reviewed allowlist.
    public func listToolDefinitions() throws -> Data {
        _ = try initializeAndListTools()
        return try JSONSerialization.data(withJSONObject: ["tools": listedToolDefinitions], options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    public func callTool(name toolName: String, argumentsJSON: Data) throws -> Data {
        let toolNames = try initializeAndListTools()
        guard configuration.allowedTools.contains(toolName), toolNames.contains(toolName),
              let arguments = try JSONSerialization.jsonObject(with: argumentsJSON, options: [.fragmentsAllowed]) as? [String: Any] else {
            throw MCPProbeError.invalidResponse
        }
        guard toolCallCount < maximumToolCallsPerRun else { throw MCPProbeError.toolCallLimit }
        toolCallCount += 1
        let result = try request("tools/call", params: ["name": toolName, "arguments": arguments], timeout: TimeInterval(configuration.toolTimeoutSeconds))
        guard JSONSerialization.isValidJSONObject(result) else { throw MCPProbeError.invalidResponse }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .fragmentsAllowed])
        guard data.count <= maximumToolResponseBytes,
              totalToolResponseBytes + data.count <= maximumTotalToolResponseBytes else {
            throw MCPProbeError.responseTooLarge
        }
        totalToolResponseBytes += data.count
        return data
    }

    public func close() {
        stop(force: false)
    }

    /// Returns the parent and child ends of an input socketpair. SO_NOSIGPIPE
    /// is set only on the parent writer so an MCP server closing stdin cannot
    /// deliver SIGPIPE to the AgentBridge host process.
    static func makeInputSocketPair() throws -> [Int32] {
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw MCPProbeError.launchFailed }
        var noSignal: Int32 = 1
        guard setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            _ = Darwin.close(pair[0])
            _ = Darwin.close(pair[1])
            throw MCPProbeError.launchFailed
        }
        return pair
    }

    private func initialize() throws {
        let response = try request("initialize", params: [
            "protocolVersion": "2025-03-26",
            "capabilities": [:] as [String: String],
            "clientInfo": ["name": "AgentBridge", "version": "0.8.0"]
        ], timeout: TimeInterval(configuration.startupTimeoutSeconds))
        guard response["protocolVersion"] is String, response["capabilities"] is [String: Any] else {
            throw MCPProbeError.invalidResponse
        }
        try notify("notifications/initialized", params: [:])
    }

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        let requestID = nextRequestID
        nextRequestID += 1
        let message: [String: Any] = ["jsonrpc": "2.0", "id": requestID, "method": method, "params": params]
        let previousLimit = currentResponseLineLimit
        currentResponseLineLimit = method == "tools/call"
            ? maximumToolResponseBytes + Self.maximumJSONEnvelopeBytes
            : Self.maximumRequestOrStartupLineBytes
        defer { currentResponseLineLimit = previousLimit }
        try send(message, timeout: min(timeout, 120))
        return try awaitResponse(id: requestID, timeout: min(timeout, 120))
    }

    private func notify(_ method: String, params: [String: Any]) throws {
        try send(["jsonrpc": "2.0", "method": method, "params": params], timeout: TimeInterval(configuration.startupTimeoutSeconds))
    }

    private func start() throws {
        guard !started else { return }
        let currentDigest = try MCPExecutableValidation.digestExecutable(at: configuration.executablePath)
        guard currentDigest == configuration.executableDigest else {
            throw ActiveExtensionRuntimeError.invalidConfiguration("The MCP executable changed after it was imported and reviewed.")
        }
        var outputPipe = [Int32](repeating: -1, count: 2)
        var errorPipe = [Int32](repeating: -1, count: 2)
        var inputPair = [Int32](repeating: -1, count: 2)
        guard pipe(&outputPipe) == 0, pipe(&errorPipe) == 0 else {
            closeAll(outputPipe + errorPipe + inputPair)
            throw MCPProbeError.launchFailed
        }
        do { inputPair = try Self.makeInputSocketPair() }
        catch {
            closeAll(outputPipe + errorPipe + inputPair)
            throw error
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closeAll(outputPipe + errorPipe + inputPair)
            throw MCPProbeError.launchFailed
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        _ = posix_spawn_file_actions_adddup2(&actions, inputPair[1], STDIN_FILENO)
        _ = posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        _ = posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO)
        for fd in [inputPair[0], inputPair[1], outputPipe[0], outputPipe[1], errorPipe[0], errorPipe[1]] {
            _ = posix_spawn_file_actions_addclose(&actions, fd)
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            closeAll(outputPipe + errorPipe + inputPair)
            throw MCPProbeError.launchFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var signals = sigset_t()
        var emptyMask = sigset_t()
        sigemptyset(&signals)
        for signal in [SIGINT, SIGTERM, SIGPIPE, SIGQUIT, SIGHUP] { sigaddset(&signals, Int32(signal)) }
        sigemptyset(&emptyMask)
        var spawnFlags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        if createsProcessGroup { spawnFlags |= Int16(POSIX_SPAWN_SETPGROUP) }
        _ = posix_spawnattr_setflags(&attributes, spawnFlags)
        if createsProcessGroup { _ = posix_spawnattr_setpgroup(&attributes, 0) }
        _ = posix_spawnattr_setsigdefault(&attributes, &signals)
        _ = posix_spawnattr_setsigmask(&attributes, &emptyMask)

        let allArguments = [configuration.executablePath] + configuration.arguments
        var argv = allArguments.map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }
        let environmentItems = environment.keys.sorted().map { "\($0)=\(environment[$0] ?? "")" }
        var envp = environmentItems.map { strdup($0) }
        envp.append(nil)
        defer { envp.forEach { free($0) } }

        let spawnResult = configuration.executablePath.withCString { executable in
            argv.withUnsafeMutableBufferPointer { arguments in
                envp.withUnsafeMutableBufferPointer { environment in
                    posix_spawn(&processID, executable, &actions, &attributes, arguments.baseAddress!, environment.baseAddress!)
                }
            }
        }
        guard spawnResult == 0 else {
            closeAll(outputPipe + errorPipe + inputPair)
            throw MCPProbeError.launchFailed
        }
        _ = Darwin.close(inputPair[1]); inputPair[1] = -1
        _ = Darwin.close(outputPipe[1]); outputPipe[1] = -1
        _ = Darwin.close(errorPipe[1]); errorPipe[1] = -1
        inputFD = inputPair[0]; inputPair[0] = -1
        outputFD = outputPipe[0]; outputPipe[0] = -1
        errorFD = errorPipe[0]; errorPipe[0] = -1
        for fd in [inputFD, outputFD, errorFD] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        started = true
    }

    private func send(_ message: [String: Any], timeout: TimeInterval) throws {
        guard JSONSerialization.isValidJSONObject(message) else { throw MCPProbeError.invalidRequest }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys, .fragmentsAllowed])
        data.append(10)
        var offset = 0
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while offset < data.count {
            try checkStatus(deadline: deadline)
            var descriptors = [
                pollfd(fd: inputFD, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0),
                pollfd(fd: outputFD, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: errorFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            ]
            _ = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 50) }
            try drainIfReady(descriptors)
            if descriptors[0].revents & Int16(POLLOUT) != 0 {
                let amount = data.withUnsafeBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                    return Darwin.write(inputFD, baseAddress.advanced(by: offset), min(16_384, data.count - offset))
                }
                if amount < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    throw MCPProbeError.processExited
                }
                guard amount > 0 else { throw MCPProbeError.processExited }
                offset += amount
            } else if descriptors[0].revents & Int16(POLLHUP | POLLERR) != 0 {
                throw MCPProbeError.processExited
            }
        }
    }

    private func awaitResponse(id: Int, timeout: TimeInterval) throws -> [String: Any] {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while true {
            try checkStatus(deadline: deadline)
            if !pendingMessages.isEmpty {
                let message = pendingMessages.removeFirst()
                guard message["jsonrpc"] as? String == "2.0" else { throw MCPProbeError.invalidResponse }
                if let method = message["method"] as? String {
                    if let requestID = message["id"] {
                        try send(["jsonrpc": "2.0", "id": requestID, "error": ["code": -32601, "message": "Client capability is not available."]], timeout: TimeInterval(configuration.startupTimeoutSeconds))
                    }
                    if method.hasPrefix("sampling/") || method.hasPrefix("roots/") || method.hasPrefix("elicitation/") {
                        continue
                    }
                    continue
                }
                guard (message["id"] as? NSNumber)?.intValue == id else { throw MCPProbeError.invalidResponse }
                if message["error"] != nil { throw MCPProbeError.remoteError }
                guard let result = message["result"] as? [String: Any] else { throw MCPProbeError.invalidResponse }
                return result
            }
            var descriptors = [
                pollfd(fd: outputFD, events: Int16(POLLIN | POLLHUP), revents: 0),
                pollfd(fd: errorFD, events: Int16(POLLIN | POLLHUP), revents: 0)
            ]
            _ = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, nfds_t($0.count), 50) }
            try drainIfReady(descriptors)
            if descriptors.contains(where: { $0.fd == outputFD && ($0.revents & Int16(POLLHUP)) != 0 }) {
                if pendingOutput.isEmpty { throw MCPProbeError.processExited }
            }
        }
    }

    private func drainIfReady(_ descriptors: [pollfd]) throws {
        for item in descriptors where item.revents != 0 {
            if item.fd == outputFD, item.revents & Int16(POLLIN | POLLHUP) != 0 {
                try drainOutput()
            } else if item.fd == errorFD, item.revents & Int16(POLLIN | POLLHUP) != 0 {
                drainError()
            }
        }
    }

    private func drainOutput() throws {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = bytes.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(outputFD, baseAddress, rawBuffer.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                throw MCPProbeError.processExited
            }
            if count == 0 { return }
            totalOutputBytes += count
            guard totalOutputBytes <= Self.maximumOutputBytes else { throw MCPProbeError.responseTooLarge }
            pendingOutput.append(contentsOf: bytes.prefix(count))
            while let newline = pendingOutput.firstIndex(of: 10) {
                let line = Data(pendingOutput[..<newline])
                pendingOutput.removeSubrange(...newline)
                guard line.count <= currentResponseLineLimit,
                      let message = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) as? [String: Any] else {
                    throw MCPProbeError.invalidResponse
                }
                pendingMessages.append(message)
            }
            guard pendingOutput.count <= currentResponseLineLimit else { throw MCPProbeError.responseTooLarge }
        }
    }

    private func drainError() {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while Darwin.read(errorFD, &buffer, buffer.count) > 0 {}
    }

    private func checkStatus(deadline: UInt64) throws {
        if cancellation.isCancelled { throw MCPProbeError.cancelled }
        guard DispatchTime.now().uptimeNanoseconds < deadline else { throw MCPProbeError.timedOut }
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG | WNOWAIT)
        if result == processID { throw MCPProbeError.processExited }
    }

    private func stop(force: Bool) {
        guard started, !stopped else { return }
        stopped = true
        if inputFD >= 0 { _ = shutdown(inputFD, SHUT_WR); _ = Darwin.close(inputFD); inputFD = -1 }
        let target = createsProcessGroup ? -processID : processID
        _ = kill(target, SIGTERM)
        let deadline = DispatchTime.now().uptimeNanoseconds + 500_000_000
        var status: Int32 = 0
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID { processID = 0; break }
            usleep(10_000)
        }
        if processID != 0 {
            _ = kill(createsProcessGroup ? -processID : processID, SIGKILL)
            _ = waitpid(processID, &status, 0)
            processID = 0
        }
        for fd in [outputFD, errorFD] where fd >= 0 { _ = Darwin.close(fd) }
        outputFD = -1
        errorFD = -1
    }

    private func closeAll(_ descriptors: [Int32]) {
        for descriptor in descriptors where descriptor >= 0 { _ = Darwin.close(descriptor) }
    }
}

private enum MCPProbeError: Error, LocalizedError {
    case launchFailed
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case paginationLimit
    case remoteError
    case processExited
    case timedOut
    case cancelled
    case toolCallLimit

    var errorDescription: String? {
        switch self {
        case .launchFailed: "MCP server could not be started."
        case .invalidRequest: "MCP request could not be encoded."
        case .invalidResponse: "MCP server returned an invalid or unsupported response."
        case .responseTooLarge: "MCP server response exceeded the bounded output limit."
        case .paginationLimit: "MCP tools/list pagination exceeded the supported limit."
        case .remoteError: "MCP server rejected a protocol request."
        case .processExited: "MCP server exited before completing the protocol request."
        case .timedOut: "MCP server did not respond before the configured timeout."
        case .cancelled: "MCP server test was cancelled."
        case .toolCallLimit: "MCP server exceeded the approved per-run tool-call limit."
        }
    }
}
