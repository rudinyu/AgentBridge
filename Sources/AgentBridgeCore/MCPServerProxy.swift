import CoreFoundation
import Darwin
import Foundation

/// A reviewed, ticket-bound JSON-RPC stdio endpoint for native MCP clients.
/// Provider CLIs should be configured with this executable and the private
/// ticket only; the reviewed server is launched behind this boundary.
public enum MCPServerProxy {
    public static func run(ticketURL: URL) async throws {
        let executablePath = CommandLine.arguments.first.map {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
        } ?? ""
        let signals = ProxySignalMonitor()
        defer { withExtendedLifetime(signals) {} }
        let cancellation = signals.cancellation
        try await withTaskCancellationHandler {
            try serve(
                ticketURL: ticketURL,
                inputDescriptor: STDIN_FILENO,
                outputDescriptor: STDOUT_FILENO,
                executablePath: executablePath,
                baseEnvironment: ProcessInfo.processInfo.environment,
                cancellationFlag: cancellation
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Test seam for exercising the actual protocol endpoint with pipes.
    static func serve(
        ticketURL: URL,
        inputDescriptor: Int32,
        outputDescriptor: Int32,
        executablePath: String,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        cancellationFlag: CancellationFlag = CancellationFlag(),
        watchesCancellationFile: Bool = true
    ) throws {
        let ticket = try MCPProxyTicketFile.read(from: ticketURL)
        var receiptCount = 0
        var receiptStatus: MCPProxyReceiptStatus = .started
        var receiptFailure: MCPProxyFailureCode?

        func persistReceipt() throws {
            let receipt = try MCPProxyReceipt(
                ticket: ticket,
                status: receiptStatus,
                toolCallCount: receiptCount,
                failureCode: receiptFailure
            )
            try MCPProxyReceiptFile.write(receipt, to: URL(fileURLWithPath: ticket.receiptPath, isDirectory: false))
        }

        try persistReceipt()
        let runtimeState = ProxyRuntimeState()
        var connection: MCPStdioConnection?
        var privateHome: URL?
        var lineReader: MCPProxyLineReader?
        var liveMonitor: MCPProxyLiveMonitor?
        var desktopPolicy: MacControlProxyPolicy?

        defer {
            liveMonitor?.stop()
            lineReader?.stop()
            connection?.close()
            if let privateHome { try? FileManager.default.removeItem(at: privateHome) }
        }

        do {
            do { try ticket.validate() }
            catch { throw MCPProxyRuntimeError.failure(.ticketInvalid) }
            try validateProxyExecutable(ticket: ticket, actualPath: executablePath)
            let store = try ActiveExtensionRuntimeStore(rootURL: URL(fileURLWithPath: ticket.runtimeStoreRootPath, isDirectory: true))
            try validateLiveTicket(ticket: ticket, store: store, includeDigests: true)

            let home = try createPrivateHome(ticketURL: ticketURL, ticketID: ticket.ticketID)
            privateHome = home
            let cancellation = cancellationFlag
            let monitor = MCPProxyLiveMonitor(
                ticket: ticket,
                store: store,
                cancellation: cancellation,
                state: runtimeState,
                watchesCancellationFile: watchesCancellationFile
            )
            liveMonitor = monitor
            monitor.start()

            // The reviewed ticket counts provider-visible calls. MacControl
            // performs at most three bounded preflight helper calls for one
            // provider call, so the persistent backend gets a separate 4x
            // ceiling that also covers the requested action itself.
            let connectionCallLimit = min(
                128,
                ticket.maximumToolCallsPerRun * (ticket.macControlAccessMode == nil ? 1 : 4)
            )
            let configuration = try makeRuntimeConfiguration(ticket: ticket, connectionCallLimit: connectionCallLimit)
            let environment = MCPRuntimeEnvironment.probeEnvironment(base: baseEnvironment, privateDirectory: home)
            let client = try MCPStdioConnection(
                configuration: configuration,
                environment: environment,
                cancellation: cancellation,
                createsProcessGroup: false,
                maximumToolCallsPerRun: connectionCallLimit
            )
            connection = client

            let reader = try MCPProxyLineReader(descriptor: inputDescriptor, cancellation: cancellation)
            lineReader = reader
            let writerMaximum = min(
                48 * 1_024 * 1_024,
                ticket.maximumTotalToolResponseBytes
                    + 2 * 1_024 * 1_024
                    + ticket.maximumToolCallsPerRun * 64 * 1_024
            )
            let writer = try MCPProxyLineWriter(descriptor: outputDescriptor, maximumTotalBytes: writerMaximum)
            var protocolState = ProxyProtocolState(ticket: ticket, connection: client)

            while true {
                if let failure = runtimeState.failureCode {
                    throw MCPProxyRuntimeError.failure(failure)
                }
                if cancellation.isCancelled {
                    throw MCPProxyRuntimeError.failure(.cancelled)
                }
                switch reader.nextEvent(timeout: 0.15) {
                case .timeout:
                    continue
                case .eof:
                    if let failure = runtimeState.failureCode {
                        throw MCPProxyRuntimeError.failure(failure)
                    }
                    if cancellation.isCancelled {
                        throw MCPProxyRuntimeError.failure(.cancelled)
                    }
                    guard protocolState.hasInitialized else {
                        throw MCPProxyRuntimeError.failure(.handshakeFailed)
                    }
                    return
                case .failure(let code):
                    throw MCPProxyRuntimeError.failure(code)
                case .line(let line):
                    reader.beginProcessing()
                    do {
                        let response = try protocolState.handle(
                            line,
                            store: store,
                            runtimeState: runtimeState,
                            cancellation: cancellation,
                            desktopPolicy: &desktopPolicy,
                            onSuccessfulInitialize: {
                                receiptStatus = .initialized
                                try persistReceipt()
                            },
                            onSuccessfulToolCall: {
                                receiptCount += 1
                                receiptStatus = .initialized
                                try persistReceipt()
                            }
                        )
                        if let response {
                            try writer.write(response, maximumBytes: protocolState.maximumOutgoingLineBytes)
                        }
                        reader.endProcessing()
                    } catch let error as MCPProxyRuntimeError {
                        reader.endProcessing()
                        throw error
                    } catch {
                        reader.endProcessing()
                        throw MCPProxyRuntimeError.failure(.toolResponseInvalid)
                    }
                }
            }
        } catch let error as MCPProxyRuntimeError {
            receiptFailure = error.code
            receiptStatus = .failed
            try? persistReceipt()
            writeProxyDiagnostic(error.code)
            throw error
        } catch {
            let code = classifySetupFailure(error)
            receiptFailure = code
            receiptStatus = .failed
            try? persistReceipt()
            writeProxyDiagnostic(code)
            throw MCPProxyRuntimeError.failure(code)
        }
    }

    private static func validateProxyExecutable(ticket: MCPProxyTicket, actualPath: String) throws {
        let ticketPath = URL(fileURLWithPath: ticket.proxyExecutablePath).standardizedFileURL.path
        guard !actualPath.isEmpty,
              URL(fileURLWithPath: actualPath).standardizedFileURL.path == ticketPath else {
            throw MCPProxyRuntimeError.failure(.executableChanged)
        }
        let digest: String
        do { digest = try MCPExecutableValidation.digestExecutable(at: ticketPath) }
        catch { throw MCPProxyRuntimeError.failure(.executableChanged) }
        guard digest == ticket.proxyExecutableDigest else {
            throw MCPProxyRuntimeError.failure(.executableChanged)
        }
    }

    fileprivate static func validateLiveTicket(
        ticket: MCPProxyTicket,
        store: ActiveExtensionRuntimeStore,
        includeDigests: Bool
    ) throws {
        do { try ticket.validate() }
        catch { throw MCPProxyRuntimeError.failure(.ticketInvalid) }
        do {
            try store.validateProxyTicket(ticket)
        } catch {
            throw MCPProxyRuntimeError.failure(.grantRevoked)
        }
        do {
            try MCPEntrypointIntegrity.validate(ticket.serverEntrypointPins, workspacePath: ticket.workspacePath)
        } catch {
            throw MCPProxyRuntimeError.failure(.entrypointChanged)
        }
        guard includeDigests else { return }
        let serverDigest: String
        let proxyDigest: String
        do {
            serverDigest = try MCPExecutableValidation.digestExecutable(at: ticket.serverExecutablePath)
            proxyDigest = try MCPExecutableValidation.digestExecutable(at: ticket.proxyExecutablePath)
        } catch {
            throw MCPProxyRuntimeError.failure(.executableChanged)
        }
        guard serverDigest == ticket.serverExecutableDigest,
              proxyDigest == ticket.proxyExecutableDigest else {
            throw MCPProxyRuntimeError.failure(.executableChanged)
        }
        if case .macControlProxy(let helperPath, let helperDigest, let proxyPath, let proxyDigest, _, _) = ticket.launchConfiguration {
            guard helperPath == ticket.serverExecutablePath,
                  helperDigest == ticket.serverExecutableDigest,
                  proxyPath == ticket.proxyExecutablePath,
                  proxyDigest == ticket.proxyExecutableDigest,
                  serverDigest == helperDigest else {
                throw MCPProxyRuntimeError.failure(.executableChanged)
            }
        }
    }

    private static func makeRuntimeConfiguration(ticket: MCPProxyTicket, connectionCallLimit: Int) throws -> ActiveMCPConfiguration {
        let manifest = try MCPRuntimeImportManifest(
            id: ticket.extensionID,
            name: "AgentBridge proxy runtime",
            version: "1",
            summary: "Ticket-bound MCP server connection",
            command: ticket.serverExecutablePath,
            args: ticket.serverArguments,
            allowedTools: ticket.allowedTools,
            startupTimeoutSeconds: ticket.startupTimeoutSeconds,
            toolTimeoutSeconds: ticket.toolTimeoutSeconds,
            maximumToolCallsPerRun: connectionCallLimit,
            maximumToolResponseBytes: ticket.maximumToolResponseBytes,
            maximumTotalToolResponseBytes: ticket.maximumTotalToolResponseBytes
        )
        return try ActiveMCPConfiguration(
            manifest: manifest,
            sourceReference: "private-proxy-ticket",
            resolvedExecutablePath: ticket.serverExecutablePath,
            executableDigest: ticket.serverExecutableDigest,
            launchConfiguration: ticket.macControlAccessMode == nil ? ticket.launchConfiguration : .stdio,
            entrypointPins: ticket.serverEntrypointPins
        )
    }

    private static func createPrivateHome(ticketURL: URL, ticketID: UUID) throws -> URL {
        let directory = ticketURL.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent("proxy-home-\(ticketID.uuidString.lowercased())", isDirectory: true)
        guard mkdir(directory.path, mode_t(0o700)) == 0 else {
            throw AgentBridgeError.persistence("Could not create the private MCP proxy runtime directory.")
        }
        let descriptor = directory.path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            _ = rmdir(directory.path)
            throw AgentBridgeError.persistence("The private MCP proxy runtime directory is unavailable.")
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              metadata.st_uid == getuid(), fchmod(descriptor, mode_t(0o700)) == 0 else {
            _ = rmdir(directory.path)
            throw AgentBridgeError.persistence("The private MCP proxy runtime directory failed access checks.")
        }
        return directory
    }

    private static func classifySetupFailure(_ error: Error) -> MCPProxyFailureCode {
        if let runtimeError = error as? ActiveExtensionRuntimeError {
            if case .invalidConfiguration = runtimeError { return .executableChanged }
        }
        return .handshakeFailed
    }

    private static func writeProxyDiagnostic(_ code: MCPProxyFailureCode) {
        let message = "AgentBridge MCP proxy stopped (\(code.rawValue)).\n"
        let bytes = Array(message.utf8)
        _ = bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return -1 }
            return Darwin.write(STDERR_FILENO, base, buffer.count)
        }
    }
}

private struct ProxyProtocolState {
    private static let supportedProtocolVersions: Set<String> = [
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"
    ]
    private static let maximumRequestLineBytes = 64 * 1_024
    private static let maximumToolListBytes = 1 * 1_024 * 1_024

    let ticket: MCPProxyTicket
    let connection: MCPStdioConnection
    private var didInitialize = false
    private var didReceiveInitializedNotification = false
    private var availableTools = Set<String>()
    private var filteredToolList: [String: Any]?
    private var toolCallCount = 0
    private var totalToolResponseBytes = 0

    init(ticket: MCPProxyTicket, connection: MCPStdioConnection) {
        self.ticket = ticket
        self.connection = connection
    }

    var maximumOutgoingLineBytes: Int {
        max(ticket.maximumToolResponseBytes + 64 * 1_024, Self.maximumToolListBytes + 64 * 1_024)
    }

    var hasInitialized: Bool { didInitialize }

    mutating func handle(
        _ line: Data,
        store: ActiveExtensionRuntimeStore,
        runtimeState: ProxyRuntimeState,
        cancellation: CancellationFlag,
        desktopPolicy: inout MacControlProxyPolicy?,
        onSuccessfulInitialize: () throws -> Void,
        onSuccessfulToolCall: () throws -> Void
    ) throws -> Data? {
        guard line.count <= Self.maximumRequestLineBytes else {
            throw MCPProxyRuntimeError.failure(.toolCallRejected)
        }
        guard let message = try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed]) as? [String: Any] else {
            return try Self.errorResponse(id: NSNull(), code: -32700, message: "Invalid JSON-RPC message.")
        }
        guard message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String,
              !method.isEmpty, method.utf8.count <= 128,
              !method.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return try Self.errorResponse(id: Self.validRequestID(message["id"]) ? message["id"]! : NSNull(), code: -32600, message: "Invalid JSON-RPC request.")
        }
        let hasID = message.keys.contains("id")
        let id = message["id"]
        if hasID && !Self.validRequestID(id) {
            return try Self.errorResponse(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request ID.")
        }
        let params: [String: Any]
        if let rawParams = message["params"] {
            guard let object = rawParams as? [String: Any] else {
                return try Self.errorResponse(id: hasID ? id ?? NSNull() : NSNull(), code: -32602, message: "Request parameters must be an object.")
            }
            params = object
        } else {
            params = [:]
        }

        if !hasID {
            guard didInitialize else {
                throw MCPProxyRuntimeError.failure(.handshakeFailed)
            }
            if method == "notifications/initialized", didInitialize {
                didReceiveInitializedNotification = true
            }
            return nil
        }

        guard let id else {
            return try Self.errorResponse(id: NSNull(), code: -32600, message: "Invalid JSON-RPC request ID.")
        }
        if method == "initialize" {
            guard !didInitialize,
                  let protocolVersion = params["protocolVersion"] as? String,
                  Self.supportedProtocolVersions.contains(protocolVersion),
                  params["capabilities"] is [String: Any],
                  params["clientInfo"] is [String: Any] else {
                return try Self.errorResponse(id: id, code: -32600, message: "Invalid or repeated initialize request.")
            }
            do {
                let names = try connection.initializeAndListTools()
                availableTools = Set(names)
                guard Set(ticket.allowedTools).isSubset(of: availableTools) else {
                    throw MCPProxyRuntimeError.failure(.handshakeFailed)
                }
                let definitions = try connection.listToolDefinitions()
                guard definitions.count <= MCPServerInspection.maximumToolDefinitionsBytes,
                      let definitionsJSON = String(data: definitions, encoding: .utf8),
                      MCPServerInspection.isValidToolDefinitionsJSON(definitionsJSON, toolNames: names),
                      MCPServerInspection.makeDigest(
                        configurationDigest: ticket.configurationDigest,
                        toolNames: names,
                        toolDefinitionsJSON: definitionsJSON
                      ) == ticket.serverInspectionDigest,
                      let root = try JSONSerialization.jsonObject(with: definitions) as? [String: Any],
                      let tools = root["tools"] as? [[String: Any]] else {
                    throw MCPProxyRuntimeError.failure(.handshakeFailed)
                }
                let filtered = tools.filter { tool in
                    guard let name = tool["name"] as? String else { return false }
                    return ticket.allowedTools.contains(name)
                }
                guard filtered.count == ticket.allowedTools.count else {
                    throw MCPProxyRuntimeError.failure(.handshakeFailed)
                }
                let list = ["tools": filtered.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }] as [String: Any]
                let listData = try JSONSerialization.data(withJSONObject: list, options: [.sortedKeys, .fragmentsAllowed])
                guard listData.count <= Self.maximumToolListBytes else {
                    throw MCPProxyRuntimeError.failure(.handshakeFailed)
                }
                filteredToolList = list
                didInitialize = true
                try onSuccessfulInitialize()
                return try Self.successResponse(id: id, result: [
                    "protocolVersion": protocolVersion,
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "AgentBridge MCP proxy", "version": "0.8.0"]
                ])
            } catch let error as MCPProxyRuntimeError {
                throw error
            } catch {
                if let failure = runtimeState.failureCode {
                    throw MCPProxyRuntimeError.failure(failure)
                }
                if cancellation.isCancelled { throw MCPProxyRuntimeError.failure(.cancelled) }
                throw MCPProxyRuntimeError.failure(.handshakeFailed)
            }
        }

        guard didInitialize, didReceiveInitializedNotification else {
            return try Self.errorResponse(id: id, code: -32002, message: "Initialize the MCP connection first.")
        }

        switch method {
        case "ping":
            return try Self.successResponse(id: id, result: [:])
        case "tools/list":
            if let cursor = params["cursor"] as? String, !cursor.isEmpty {
                return try Self.errorResponse(id: id, code: -32602, message: "Tool-list pagination is not available.")
            }
            guard let filteredToolList else { throw MCPProxyRuntimeError.failure(.handshakeFailed) }
            return try Self.successResponse(id: id, result: filteredToolList)
        case "tools/call":
            try MCPServerProxy.validateLiveTicket(ticket: ticket, store: store, includeDigests: true)
            guard let name = params["name"] as? String,
                  ticket.allowedTools.contains(name), availableTools.contains(name) else {
                return try Self.errorResponse(id: id, code: -32602, message: "The requested tool is not available.")
            }
            guard toolCallCount < ticket.maximumToolCallsPerRun else {
                throw MCPProxyRuntimeError.failure(.toolCallRejected)
            }
            guard let arguments = params["arguments"] as? [String: Any] else {
                return try Self.errorResponse(id: id, code: -32602, message: "Tool arguments must be a JSON object.")
            }
            let argumentsJSON = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys, .fragmentsAllowed])
            guard argumentsJSON.count <= Self.maximumRequestLineBytes else {
                throw MCPProxyRuntimeError.failure(.toolCallRejected)
            }

            do {
                let resultData: Data
                if case .macControlProxy = ticket.launchConfiguration {
                    if desktopPolicy == nil { desktopPolicy = try MacControlProxyPolicy(ticket: ticket) }
                    resultData = try desktopPolicy!.call(name: name, argumentsJSON: argumentsJSON) { backendName, backendArguments in
                        try connection.callTool(name: backendName, argumentsJSON: backendArguments)
                    }
                } else {
                    resultData = try connection.callTool(name: name, argumentsJSON: argumentsJSON)
                }
                try Task.checkCancellation()
                if cancellation.isCancelled || runtimeState.failureCode != nil {
                    throw MCPProxyRuntimeError.failure(runtimeState.failureCode ?? .cancelled)
                }
                guard resultData.count <= ticket.maximumToolResponseBytes,
                      totalToolResponseBytes + resultData.count <= ticket.maximumTotalToolResponseBytes,
                      let result = try JSONSerialization.jsonObject(with: resultData, options: [.fragmentsAllowed]) as? [String: Any] else {
                    throw MCPProxyRuntimeError.failure(.toolResponseInvalid)
                }
                toolCallCount += 1
                totalToolResponseBytes += resultData.count
                try onSuccessfulToolCall()
                return try Self.successResponse(id: id, result: result)
            } catch let error as MacControlProxyPolicyError {
                return try Self.errorResponse(id: id, code: -32000, message: error.localizedDescription)
            } catch let error as MCPProxyRuntimeError {
                throw error
            } catch {
                if let failure = runtimeState.failureCode {
                    throw MCPProxyRuntimeError.failure(failure)
                }
                if cancellation.isCancelled { throw MCPProxyRuntimeError.failure(.cancelled) }
                let code = Self.classifyCallFailure(error)
                throw MCPProxyRuntimeError.failure(code)
            }
        default:
            return try Self.errorResponse(id: id, code: -32601, message: "Method not found.")
        }
    }

    private static func validRequestID(_ value: Any?) -> Bool {
        if let string = value as? String {
            return !string.isEmpty && string.utf8.count <= 128
                && !string.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
        return number.doubleValue.isFinite
    }

    private static func successResponse(id: Any, result: [String: Any]) throws -> Data {
        try Self.encodeResponse(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func errorResponse(id: Any, code: Int, message: String) throws -> Data {
        try Self.encodeResponse(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func encodeResponse(_ response: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys, .fragmentsAllowed])
        data.append(10)
        return data
    }

    private static func classifyCallFailure(_ error: Error) -> MCPProxyFailureCode {
        let description = (error as? LocalizedError)?.errorDescription ?? ""
        if description.localizedCaseInsensitiveContains("timed out") || description.localizedCaseInsensitiveContains("timeout") { return .timedOut }
        if description.localizedCaseInsensitiveContains("cancelled") { return .cancelled }
        if description.localizedCaseInsensitiveContains("tool-call limit") { return .toolCallRejected }
        return .toolResponseInvalid
    }
}

private final class ProxyRuntimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var currentFailureCode: MCPProxyFailureCode?

    var failureCode: MCPProxyFailureCode? {
        lock.lock()
        defer { lock.unlock() }
        return currentFailureCode
    }

    func fail(_ code: MCPProxyFailureCode) {
        lock.lock()
        if currentFailureCode == nil { currentFailureCode = code }
        lock.unlock()
    }
}

private final class MCPProxyLiveMonitor: @unchecked Sendable {
    private let ticket: MCPProxyTicket
    private let store: ActiveExtensionRuntimeStore
    private let cancellation: CancellationFlag
    private let state: ProxyRuntimeState
    private let watchesCancellationFile: Bool
    private let queue = DispatchQueue(label: "com.agentbridge.mcp-proxy-monitor")
    private var timer: DispatchSourceTimer?
    private var lastStoreCheck = Date.distantPast

    init(ticket: MCPProxyTicket, store: ActiveExtensionRuntimeStore, cancellation: CancellationFlag, state: ProxyRuntimeState, watchesCancellationFile: Bool) {
        self.ticket = ticket
        self.store = store
        self.cancellation = cancellation
        self.state = state
        self.watchesCancellationFile = watchesCancellationFile
    }

    func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(250))
        source.setEventHandler { [weak self] in self?.check() }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func check() {
        guard !cancellation.isCancelled, state.failureCode == nil else { return }
        do {
            try ticket.validate()
        } catch {
            state.fail(.ticketInvalid)
            cancellation.cancel()
            return
        }
        if watchesCancellationFile, Self.cancellationRequested(at: ticket.cancellationRequestPath) {
            state.fail(.cancelled)
            cancellation.cancel()
            return
        }
        if Date().timeIntervalSince(lastStoreCheck) >= 1 {
            lastStoreCheck = Date()
            do {
                try store.validateProxyTicket(ticket)
            } catch {
                state.fail(.grantRevoked)
                cancellation.cancel()
            }
        }
    }

    private static func cancellationRequested(at path: String) -> Bool {
        var metadata = stat()
        if lstat(path, &metadata) != 0 { return errno != ENOENT }
        guard (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              (metadata.st_mode & 0o077) == 0,
              metadata.st_size <= 4_096 else { return true }
        return true
    }
}

private final class ProxySignalMonitor {
    let cancellation = CancellationFlag()
    private var sources: [DispatchSourceSignal] = []

    init() {
        // Let the bounded stdio writer handle a disconnected client through
        // EPIPE so the proxy can record its terminal receipt and clean up.
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        for signalValue in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            _ = Darwin.signal(signalValue, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalValue, queue: .global())
            source.setEventHandler { [cancellation] in cancellation.cancel() }
            source.resume()
            sources.append(source)
        }
    }
}

private final class MCPProxyLineReader: @unchecked Sendable {
    private static let maximumLineBytes = 64 * 1_024
    private static let maximumQueuedBytes = 2 * 1_024 * 1_024
    private static let maximumQueuedLines = 32

    private let descriptor: Int32
    private let cancellation: CancellationFlag
    private let condition = NSCondition()
    private var queuedLines: [Data] = []
    private var queuedBytes = 0
    private var eof = false
    private var failure: MCPProxyFailureCode?
    private var stopped = false
    private var processingRequest = false
    private let originalFlags: Int32

    init(descriptor: Int32, cancellation: CancellationFlag) throws {
        self.descriptor = descriptor
        self.cancellation = cancellation
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw MCPProxyRuntimeError.failure(.handshakeFailed)
        }
        originalFlags = flags
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.readLoop() }
    }

    func nextEvent(timeout: TimeInterval) -> MCPProxyLineEvent {
        condition.lock()
        defer { condition.unlock() }
        if queuedLines.isEmpty, !eof, failure == nil, !stopped {
            _ = condition.wait(until: Date().addingTimeInterval(timeout))
        }
        if !queuedLines.isEmpty {
            let line = queuedLines.removeFirst()
            queuedBytes -= line.count
            return .line(line)
        }
        if let failure { return .failure(failure) }
        if eof || stopped { return .eof }
        return .timeout
    }

    func beginProcessing() {
        condition.lock()
        processingRequest = true
        condition.unlock()
    }

    func endProcessing() {
        condition.lock()
        processingRequest = false
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
        _ = fcntl(descriptor, F_SETFL, originalFlags)
    }

    private func readLoop() {
        var partial = Data()
        var bytes = [UInt8](repeating: 0, count: 8 * 1_024)
        while !cancellation.isCancelled {
            condition.lock()
            let shouldStop = stopped || eof || failure != nil
            condition.unlock()
            if shouldStop { return }

            var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let ready = poll(&item, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                finish(with: .toolCallRejected)
                return
            }
            if ready == 0 { continue }
            if item.revents & Int16(POLLERR | POLLNVAL) != 0 {
                finish(with: .toolCallRejected)
                return
            }
            let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.read(descriptor, base, buffer.count)
            }
            if count == 0 {
                if !partial.isEmpty { enqueue(partial); partial.removeAll(keepingCapacity: false) }
                finishEOF()
                return
            }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                finish(with: .toolCallRejected)
                return
            }
            for byte in bytes.prefix(count) {
                if byte == 10 {
                    enqueue(partial)
                    partial.removeAll(keepingCapacity: true)
                } else {
                    partial.append(byte)
                    if partial.count > Self.maximumLineBytes {
                        finish(with: .toolCallRejected)
                        return
                    }
                }
            }
        }
        finishEOF()
    }

    private func enqueue(_ line: Data) {
        condition.lock()
        defer { condition.unlock() }
        guard !stopped, failure == nil else { return }
        guard queuedLines.count < Self.maximumQueuedLines,
              queuedBytes + line.count <= Self.maximumQueuedBytes else {
            failure = .toolCallRejected
            cancellation.cancel()
            condition.broadcast()
            return
        }
        queuedLines.append(line)
        queuedBytes += line.count
        condition.signal()
    }

    private func finish(with code: MCPProxyFailureCode) {
        condition.lock()
        failure = code
        condition.broadcast()
        condition.unlock()
        cancellation.cancel()
    }

    private func finishEOF() {
        condition.lock()
        eof = true
        let shouldCancel = processingRequest && queuedLines.isEmpty
        if shouldCancel { failure = .cancelled }
        condition.broadcast()
        condition.unlock()
        if shouldCancel { cancellation.cancel() }
    }
}

private enum MCPProxyLineEvent {
    case line(Data)
    case timeout
    case eof
    case failure(MCPProxyFailureCode)
}

private final class MCPProxyLineWriter {
    private let descriptor: Int32
    private let originalFlags: Int32
    private var totalBytes = 0
    private let maximumTotalBytes: Int

    init(descriptor: Int32, maximumTotalBytes: Int) throws {
        guard (1...48 * 1_024 * 1_024).contains(maximumTotalBytes) else {
            throw MCPProxyRuntimeError.failure(.toolResponseInvalid)
        }
        self.descriptor = descriptor
        self.maximumTotalBytes = maximumTotalBytes
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw MCPProxyRuntimeError.failure(.handshakeFailed)
        }
        originalFlags = flags
    }

    deinit { _ = fcntl(descriptor, F_SETFL, originalFlags) }

    func write(_ data: Data, maximumBytes: Int) throws {
        guard data.count <= maximumBytes, totalBytes + data.count <= maximumTotalBytes else {
            throw MCPProxyRuntimeError.failure(.toolResponseInvalid)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
        var offset = 0
        while offset < data.count {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw MCPProxyRuntimeError.failure(.timedOut)
            }
            let amount = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if amount > 0 {
                offset += amount
                continue
            }
            if amount < 0, errno == EINTR { continue }
            if amount < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                throw MCPProxyRuntimeError.failure(.cancelled)
            }
            var item = pollfd(fd: descriptor, events: Int16(POLLOUT | POLLERR | POLLHUP), revents: 0)
            _ = poll(&item, 1, 100)
            if item.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                throw MCPProxyRuntimeError.failure(.cancelled)
            }
        }
        totalBytes += data.count
    }
}

private struct MCPProxyRuntimeError: Error {
    let code: MCPProxyFailureCode
    init(failure code: MCPProxyFailureCode) { self.code = code }

    static func failure(_ code: MCPProxyFailureCode) -> MCPProxyRuntimeError {
        MCPProxyRuntimeError(failure: code)
    }
}
