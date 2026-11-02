import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class MCPServerProxyTests: XCTestCase {
    func testEndpointNegotiatesFiltersRejectsAndPreservesImageBlocks() async throws {
        let fixture = try ProxyTicketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&inputPipe), 0)
        XCTAssertEqual(pipe(&outputPipe), 0)
        defer {
            for descriptor in inputPipe + outputPipe where descriptor >= 0 { _ = close(descriptor) }
        }

        let inputReadDescriptor = inputPipe[0]
        let outputWriteDescriptor = outputPipe[1]
        let run = Task.detached {
            try MCPServerProxy.serve(
                ticketURL: fixture.ticketURL,
                inputDescriptor: inputReadDescriptor,
                outputDescriptor: outputWriteDescriptor,
                executablePath: fixture.configuration.executablePath,
                baseEnvironment: ["PATH": "/usr/bin:/bin", "USER": NSUserName()],
                watchesCancellationFile: false
            )
        }
        let requests = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"offline-test","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#,
            #"{"jsonrpc":"2.0","id":"list","method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"hidden","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"image_echo","arguments":{}}}"#
        ].joined(separator: "\n") + "\n"
        try writeAll(Data(requests.utf8), to: inputPipe[1])
        _ = close(inputPipe[1])
        inputPipe[1] = -1

        var reader = TestLineReader(descriptor: outputPipe[0])
        let responses = try (0..<4).map { _ in
            try XCTUnwrap(reader.readLine(timeout: 10), "Proxy response did not arrive.")
        }
        try await run.value

        let decoded = try responses.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        let initialize = try XCTUnwrap(decoded.first(where: { ($0["id"] as? NSNumber)?.intValue == 1 }))
        let initializeResult = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(initializeResult["protocolVersion"] as? String, "2025-11-25")
        XCTAssertEqual(Array((initializeResult["capabilities"] as? [String: Any] ?? [:]).keys), ["tools"])

        let list = try XCTUnwrap(decoded.first(where: { $0["id"] as? String == "list" }))
        let listedNames = ((list["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? [])
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(listedNames, ["echo", "image_echo", "oversize", "slow"])

        let rejection = try XCTUnwrap(decoded.first(where: { ($0["id"] as? NSNumber)?.intValue == 2 }))
        XCTAssertNotNil(rejection["error"])
        let image = try XCTUnwrap(decoded.first(where: { ($0["id"] as? NSNumber)?.intValue == 3 }))
        let imageResult = try XCTUnwrap(image["result"] as? [String: Any])
        let content = try XCTUnwrap(imageResult["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "image")
        XCTAssertEqual(content.first?["data"] as? String, "AQIDBA==")

        let invoked = try String(contentsOf: fixture.invocationLog, encoding: .utf8)
        XCTAssertEqual(invoked, "image_echo\n")
        let receipt = try MCPProxyReceiptFile.read(from: fixture.receiptURL)
        XCTAssertEqual(receipt.status, .initialized)
        XCTAssertEqual(receipt.toolCallCount, 1)
        XCTAssertNil(receipt.failureCode)
    }

    func testProxyRejectsExpiredTicketAndWritesFailureReceipt() throws {
        let fixture = try ProxyTicketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var ticketObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.ticketURL)) as? [String: Any])
        ticketObject["createdAt"] = Date().addingTimeInterval(-30).timeIntervalSince1970 * 1_000
        ticketObject["expiresAt"] = Date().addingTimeInterval(-1).timeIntervalSince1970 * 1_000
        try JSONSerialization.data(withJSONObject: ticketObject, options: [.sortedKeys, .withoutEscapingSlashes])
            .write(to: fixture.ticketURL, options: .atomic)
        XCTAssertEqual(chmod(fixture.ticketURL.path, 0o600), 0)

        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&inputPipe), 0)
        XCTAssertEqual(pipe(&outputPipe), 0)
        defer {
            for descriptor in inputPipe + outputPipe where descriptor >= 0 { _ = close(descriptor) }
        }
        XCTAssertThrowsError(try MCPServerProxy.serve(
            ticketURL: fixture.ticketURL,
            inputDescriptor: inputPipe[0],
            outputDescriptor: outputPipe[1],
            executablePath: fixture.configuration.executablePath,
            watchesCancellationFile: false
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receiptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.invocationLog.path))
    }

    func testPrivateReceiptRoundTripsInTicketDirectory() throws {
        let fixture = try ProxyTicketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let receipt = try MCPProxyReceipt(ticket: fixture.ticket, status: .started)
        try MCPProxyReceiptFile.write(receipt, to: fixture.receiptURL)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.receiptURL.path),
            "receipt=\(fixture.receiptURL.path), standardized=\(fixture.receiptURL.standardizedFileURL.path), ticket=\(fixture.ticket.receiptPath)"
        )
        let stored = try MCPProxyReceiptFile.read(from: fixture.receiptURL)
        XCTAssertEqual(stored.ticketID, receipt.ticketID)
        XCTAssertEqual(stored.extensionID, receipt.extensionID)
        XCTAssertEqual(stored.configurationDigest, receipt.configurationDigest)
        XCTAssertEqual(stored.status, receipt.status)
        XCTAssertEqual(stored.toolCallCount, receipt.toolCallCount)
        XCTAssertEqual(stored.failureCode, receipt.failureCode)
        XCTAssertLessThan(abs(stored.updatedAt.timeIntervalSince(receipt.updatedAt)), 0.001)
    }

    func testProxyRejectsRevokedGrantBeforeLaunchingBackend() throws {
        let fixture = try ProxyTicketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertTrue(try fixture.store.disable(
            extensionID: fixture.configuration.extensionID,
            projectID: fixture.projectID,
            provider: .codex,
            profileID: fixture.profileID,
            disabledBy: "offline proxy test"
        ))

        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&inputPipe), 0)
        XCTAssertEqual(pipe(&outputPipe), 0)
        defer {
            for descriptor in inputPipe + outputPipe where descriptor >= 0 { _ = close(descriptor) }
        }
        XCTAssertThrowsError(try MCPServerProxy.serve(
            ticketURL: fixture.ticketURL,
            inputDescriptor: inputPipe[0],
            outputDescriptor: outputPipe[1],
            executablePath: fixture.configuration.executablePath,
            watchesCancellationFile: false
        ))

        let receipt = try MCPProxyReceiptFile.read(from: fixture.receiptURL)
        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.failureCode, .grantRevoked)
        XCTAssertEqual(receipt.toolCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.invocationLog.path))
    }

    func testProxyCancelsOnPrivateCancellationFile() throws {
        let fixture = try ProxyTicketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cancelPath = fixture.ticket.cancellationRequestPath
        try Data("cancel".utf8).write(to: URL(fileURLWithPath: cancelPath))
        XCTAssertEqual(chmod(cancelPath, 0o600), 0)

        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&inputPipe), 0)
        XCTAssertEqual(pipe(&outputPipe), 0)
        defer {
            for descriptor in inputPipe + outputPipe where descriptor >= 0 { _ = close(descriptor) }
        }
        XCTAssertThrowsError(try MCPServerProxy.serve(
            ticketURL: fixture.ticketURL,
            inputDescriptor: inputPipe[0],
            outputDescriptor: outputPipe[1],
            executablePath: fixture.configuration.executablePath
        ))

        let receipt = try MCPProxyReceiptFile.read(from: fixture.receiptURL)
        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.failureCode, .cancelled)
        XCTAssertEqual(receipt.toolCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.invocationLog.path))
    }

    func testProxyStopsAnInitializedSessionWhenGrantIsRevoked() async throws {
        let fixture = try ProxyTicketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&inputPipe), 0)
        XCTAssertEqual(pipe(&outputPipe), 0)
        defer {
            for descriptor in inputPipe + outputPipe where descriptor >= 0 { _ = close(descriptor) }
        }

        let run = Task.detached {
            try MCPServerProxy.serve(
                ticketURL: fixture.ticketURL,
                inputDescriptor: inputPipe[0],
                outputDescriptor: outputPipe[1],
                executablePath: fixture.configuration.executablePath,
                baseEnvironment: ["PATH": "/usr/bin:/bin", "USER": NSUserName()],
                watchesCancellationFile: false
            )
        }
        try writeAll(Data((#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"offline-test","version":"1"}}}"# + "\n").utf8), to: inputPipe[1])
        var reader = TestLineReader(descriptor: outputPipe[0])
        XCTAssertNotNil(try reader.readLine(timeout: 10), "The proxy did not initialize before revocation.")
        try writeAll(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#.utf8) + Data([10]), to: inputPipe[1])
        XCTAssertTrue(try fixture.store.disable(
            extensionID: fixture.configuration.extensionID,
            projectID: fixture.projectID,
            provider: .codex,
            profileID: fixture.profileID,
            disabledBy: "offline proxy test"
        ))

        do {
            try await run.value
            XCTFail("A proxy connection remained active after its grant was revoked.")
        } catch {
            // The private receipt carries the stable, sanitized failure code.
        }
        _ = close(inputPipe[1])
        inputPipe[1] = -1
        let receipt = try MCPProxyReceiptFile.read(from: fixture.receiptURL)
        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.failureCode, .grantRevoked)
        XCTAssertEqual(receipt.toolCallCount, 0)
    }

    func testOversizedAndTimedOutToolCallsFailWithBoundedReceipts() async throws {
        try await assertFailureCall(toolName: "oversize", expected: .toolResponseInvalid)
        try await assertFailureCall(toolName: "slow", expected: .timedOut)
    }

    private func assertFailureCall(toolName: String, expected: MCPProxyFailureCode) async throws {
        let fixture = try ProxyTicketFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&inputPipe), 0)
        XCTAssertEqual(pipe(&outputPipe), 0)
        defer {
            for descriptor in inputPipe + outputPipe where descriptor >= 0 { _ = close(descriptor) }
        }

        let run = Task.detached {
            try MCPServerProxy.serve(
                ticketURL: fixture.ticketURL,
                inputDescriptor: inputPipe[0],
                outputDescriptor: outputPipe[1],
                executablePath: fixture.configuration.executablePath,
                baseEnvironment: ["PATH": "/usr/bin:/bin", "USER": NSUserName()],
                watchesCancellationFile: false
            )
        }
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"offline-test","version":"1"}}}"#
        try writeAll(Data((initialize + "\n").utf8), to: inputPipe[1])
        var reader = TestLineReader(descriptor: outputPipe[0])
        XCTAssertNotNil(try reader.readLine(timeout: 10), "The proxy did not initialize before the tool call.")
        let initialized = #"{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}"#
        let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"\#(toolName)","arguments":{}}}"#
        try writeAll(Data((initialized + "\n" + call + "\n").utf8), to: inputPipe[1])

        do {
            try await run.value
            XCTFail("The \(toolName) call unexpectedly returned successfully.")
        } catch {
            // The private receipt carries the stable, sanitized failure code.
        }
        _ = close(inputPipe[1])
        inputPipe[1] = -1

        let receipt = try MCPProxyReceiptFile.read(from: fixture.receiptURL)
        XCTAssertEqual(receipt.status, .failed)
        XCTAssertEqual(receipt.failureCode, expected)
        XCTAssertEqual(receipt.toolCallCount, 0)
        XCTAssertEqual(try String(contentsOf: fixture.invocationLog, encoding: .utf8), "\(toolName)\n")
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                offset += count
            }
        }
    }

    private struct TestLineReader {
        let descriptor: Int32
        var buffered = Data()

        mutating func readLine(timeout: TimeInterval) throws -> Data? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let newline = buffered.firstIndex(of: 10) {
                    let result = Data(buffered[..<newline])
                    buffered.removeSubrange(...newline)
                    return result
                }
                var item = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let remaining = Int32(max(1.0, min(1_000.0, deadline.timeIntervalSinceNow * 1_000)))
                let ready = poll(&item, 1, remaining)
                if ready < 0, errno == EINTR { continue }
                if ready <= 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 8 * 1_024)
                let count = bytes.withUnsafeMutableBytes { buffer -> Int in
                    guard let base = buffer.baseAddress else { return 0 }
                    return Darwin.read(descriptor, base, buffer.count)
                }
                if count < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) { continue }
                if count <= 0 { return nil }
                buffered.append(contentsOf: bytes.prefix(count))
                guard buffered.count <= 4 * 1_024 * 1_024 else {
                    throw NSError(domain: "MCPServerProxyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Proxy output exceeded the test bound."])
                }
            }
            return nil
        }
    }
}

private final class ProxyTicketFixture {
    var root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    var ticketURL = FileManager.default.temporaryDirectory.appendingPathComponent("ticket")
    var receiptURL = FileManager.default.temporaryDirectory.appendingPathComponent("receipt")
    var invocationLog = FileManager.default.temporaryDirectory.appendingPathComponent("invocations")
    var pythonPath = ""
    var configuration: ActiveMCPConfiguration!
    var store: ActiveExtensionRuntimeStore!
    var ticket: MCPProxyTicket!
    let profileID = AccountProfile.defaultID(for: .codex)
    let projectID = "proxy-test-project"
    var workspacePath = ""
    var extensionFingerprint = ""
    var inspectionDigest = ""
    var grantReviewedDigest = ""
    let sessionID = UUID()

    init() throws {
        root = try makeProxyTestRoot("AgentBridge-MCPProxy")
        let ticketDirectory = root.appendingPathComponent("tickets", isDirectory: true)
        try FileManager.default.createDirectory(at: ticketDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(ticketDirectory.path, 0o700), 0)
        ticketURL = ticketDirectory.appendingPathComponent("proxy-ticket.json")
        receiptURL = root.appendingPathComponent("proxy-receipt.json")
        invocationLog = root.appendingPathComponent("backend-invocations.log")
        workspacePath = root.appendingPathComponent("workspace", isDirectory: true).path
        extensionFingerprint = String(repeating: "a", count: 64)

        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        guard let interpreter = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("A local Python 3 interpreter is required for the offline proxy fixture.")
        }
        pythonPath = interpreter
        let resolved = try MCPExecutableValidation.resolveAndDigest(interpreter)
        let manifest = try MCPRuntimeImportManifest(
            id: "proxy.fixture",
            name: "Offline proxy fixture",
            version: "1",
            summary: "A local stdio test server",
            command: resolved.path,
            args: ["-u", "-c", FakeProxyServer.program(markerPath: invocationLog.path)],
            allowedTools: ["echo", "image_echo", "oversize", "slow"],
            startupTimeoutSeconds: 5,
            toolTimeoutSeconds: 2,
            maximumToolCallsPerRun: 4,
            maximumToolResponseBytes: 64 * 1_024,
            maximumTotalToolResponseBytes: 128 * 1_024
        )
        configuration = try ActiveMCPConfiguration(
            manifest: manifest,
            sourceReference: "offline proxy fixture",
            resolvedExecutablePath: resolved.path,
            executableDigest: resolved.digest
        )
        store = try ActiveExtensionRuntimeStore(rootURL: root.appendingPathComponent("active-extensions", isDirectory: true))
        try store.importMCP(configuration)

        let definitions = FakeProxyServer.toolDefinitions
        let names = definitions.compactMap { $0["name"] as? String }.sorted()
        let definitionsData = try JSONSerialization.data(
            withJSONObject: ["tools": definitions.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }],
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
        let definitionsJSON = try XCTUnwrap(String(data: definitionsData, encoding: .utf8))
        inspectionDigest = MCPServerInspection.makeDigest(
            configurationDigest: configuration.configurationDigest,
            toolNames: names,
            toolDefinitionsJSON: definitionsJSON
        )
        try store.recordInspection(MCPServerInspection(
            extensionID: configuration.extensionID,
            configurationDigest: configuration.configurationDigest,
            toolNames: names,
            toolDefinitionsJSON: definitionsJSON,
            inspectionDigest: inspectionDigest,
            diagnostics: ["offline fixture"],
            inspectedAt: Date()
        ))
        let review = try store.preview(
            extensionID: configuration.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID
        )
        let grant = try store.enable(
            extensionID: configuration.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            reviewedDigest: review.reviewedDigest,
            explicitExecutionConsent: true,
            grantedBy: "offline proxy test"
        )
        grantReviewedDigest = grant.reviewedDigest
        let invocation = try store.invocation(
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            workspacePath: workspacePath,
            selectedExtensionIDs: [configuration.extensionID]
        )
        extensionFingerprint = invocation.fingerprint
        try store.validateAndBind(sessionID: sessionID, invocation: invocation)

        ticket = try makeTicket(expiresAt: Date().addingTimeInterval(120))
        receiptURL = URL(fileURLWithPath: ticket.receiptPath, isDirectory: false)
        try MCPProxyTicketFile.write(ticket, to: ticketURL)
    }

    func makeTicket(expiresAt: Date) throws -> MCPProxyTicket {
        let executable = try MCPExecutableValidation.resolveAndDigest(pythonPath)
        return try MCPProxyTicket(
            sessionID: sessionID,
            extensionID: configuration.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            configurationDigest: configuration.configurationDigest,
            reviewedDigest: grantReviewedDigest,
            serverInspectionDigest: inspectionDigest,
            sessionExtensionFingerprint: extensionFingerprint,
            runtimeStoreRootPath: store.rootURL.path,
            workspacePath: workspacePath,
            cancellationRequestPath: root.appendingPathComponent("cancel-\(sessionID.uuidString.lowercased()).request").path,
            receiptPath: receiptURL.path,
            proxyExecutablePath: executable.path,
            proxyExecutableDigest: executable.digest,
            serverExecutablePath: configuration.executablePath,
            serverExecutableDigest: configuration.executableDigest,
            serverArguments: configuration.arguments,
            serverEntrypointPins: configuration.entrypointPins,
            allowedTools: configuration.allowedTools,
            startupTimeoutSeconds: configuration.startupTimeoutSeconds,
            toolTimeoutSeconds: configuration.toolTimeoutSeconds,
            maximumToolCallsPerRun: 4,
            maximumToolResponseBytes: configuration.maximumToolResponseBytes,
            maximumTotalToolResponseBytes: configuration.maximumTotalToolResponseBytes,
            launchConfiguration: configuration.launchConfiguration,
            expiresAt: expiresAt
        )
    }
}

func canonicalExistingProxyTestDirectory(_ url: URL) throws -> URL {
    guard let canonicalPath = url.path.withCString({ realpath($0, nil) }) else {
        throw NSError(domain: "MCPProxyTests", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "The proxy test directory could not be resolved safely."])
    }
    defer { free(canonicalPath) }
    return URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
}

func makeProxyTestRoot(_ name: String) throws -> URL {
    let sourceURL = URL(fileURLWithPath: #filePath)
    let repositoryRoot = try canonicalExistingProxyTestDirectory(
        sourceURL.deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    )
    let fixtureParent = repositoryRoot.appendingPathComponent("build/proxy-test-fixtures", isDirectory: true)
    try FileManager.default.createDirectory(at: fixtureParent, withIntermediateDirectories: true)
    let requestedRoot = fixtureParent.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: requestedRoot, withIntermediateDirectories: true)
    guard chmod(requestedRoot.path, 0o700) == 0 else {
        throw NSError(domain: "MCPProxyTests", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "Could not secure the proxy test directory."])
    }
    return try canonicalExistingProxyTestDirectory(requestedRoot)
}

private enum FakeProxyServer {
    static let toolDefinitions: [[String: Any]] = [
        ["name": "echo", "description": "Echo text", "inputSchema": ["type": "object", "properties": ["text": ["type": "string"]]]],
        ["name": "hidden", "description": "Never exposed by the proxy", "inputSchema": ["type": "object"]],
        ["name": "image_echo", "description": "Return one image block", "inputSchema": ["type": "object"]],
        ["name": "oversize", "description": "Return an oversized result", "inputSchema": ["type": "object"]],
        ["name": "slow", "description": "Wait beyond the proxy timeout", "inputSchema": ["type": "object"]]
    ]

    static func program(markerPath: String) -> String {
        let definitions = try! JSONSerialization.data(withJSONObject: toolDefinitions, options: [.sortedKeys, .withoutEscapingSlashes])
        let encodedDefinitions = definitions.base64EncodedString()
        let encodedMarker = Data(markerPath.utf8).base64EncodedString()
        return #"""
# coding: utf-8
import base64, json, sys
tools = json.loads(base64.b64decode("\#(encodedDefinitions)"))
marker = base64.b64decode("\#(encodedMarker)").decode()
for line in sys.stdin:
    try:
        request = json.loads(line)
    except Exception:
        continue
    method = request.get("method")
    request_id = request.get("id")
    if request_id is None:
        continue
    if method == "initialize":
        result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "offline fixture", "version": "1"}}
    elif method == "tools/list":
        result = {"tools": tools}
    elif method == "tools/call":
        name = request.get("params", {}).get("name", "")
        with open(marker, "a", encoding="utf-8") as output:
            output.write(name + "\n")
        if name == "image_echo":
            result = {"content": [{"type": "image", "data": "AQIDBA==", "mimeType": "image/png"}], "isError": False}
        elif name == "oversize":
            result = {"content": [{"type": "text", "text": "x" * 100000}], "isError": False}
        elif name == "slow":
            import time
            time.sleep(5)
            result = {"content": [{"type": "text", "text": "late"}], "isError": False}
        else:
            result = {"content": [{"type": "text", "text": "echo"}], "isError": False}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "unsupported"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}, separators=(",", ":")), flush=True)
"""#
    }
}
