import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class LocalModelClientTests: XCTestCase {
    func testOpenAICompatibleEndpointsNormalizeRootTrailingV1AndCustomPrefix() async throws {
        let modelList = Data(#"{"data":[{"id":"local-chat"}]}"#.utf8)
        let server = try LoopbackHTTPServer { _ in .json(modelList) }
        defer { server.stop() }

        let endpoints = [
            "http://127.0.0.1:\(server.port)": "/v1/models",
            "http://127.0.0.1:\(server.port)/": "/v1/models",
            "http://127.0.0.1:\(server.port)/v1/": "/v1/models",
            "http://127.0.0.1:\(server.port)/proxy": "/proxy/v1/models",
            "http://127.0.0.1:\(server.port)/proxy/v1/": "/proxy/v1/models",
            "http://127.0.0.1:\(server.port)/v1/v1": "/v1/models"
        ]
        let client = makeClient()

        var expectedCount = 0
        for (endpoint, expectedPath) in endpoints {
            var settings = openAISettings(server: server, model: "local-chat")
            settings.endpoint = endpoint
            _ = try await client.models(settings: settings)
            expectedCount += 1
            guard server.waitForRequestCount(expectedCount) else {
                return XCTFail("The server did not receive request \(expectedCount).")
            }
            let request = server.requests[expectedCount - 1]
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.path, expectedPath, "Endpoint: \(endpoint)")
        }

        XCTAssertEqual(server.requests.count, endpoints.count)
    }

    func testOllamaAPIEndpointPrefixIsNotDuplicated() async throws {
        let modelList = Data(#"{"models":[{"name":"qwen2.5:7b"}]}"#.utf8)
        let server = try LoopbackHTTPServer { _ in .json(modelList) }
        defer { server.stop() }
        let client = makeClient()

        for prefix in ["", "/", "/api", "/api/"] {
            var settings = ollamaSettings(server: server, model: "qwen2.5:7b")
            settings.endpoint = "http://127.0.0.1:\(server.port)\(prefix)"
            _ = try await client.models(settings: settings)
        }

        XCTAssertEqual(server.requests.map(\.path), Array(repeating: "/api/tags", count: 4))
    }

    func testEndpointValidationAllowsIPv6LoopbackAndRejectsUnsafeURLs() {
        for endpoint in [
            "http://[::1]:1234",
            "http://[::1]:1234/v1",
            "http://127.0.0.1:1234/proxy/v1/"
        ] {
            var settings = LocalModelSettings(backend: .openAICompatible, endpoint: endpoint, model: "local-chat")
            XCTAssertNoThrow(try LocalModelClient.validateSettings(settings), "Rejected loopback endpoint: \(endpoint)")
            settings.backend = .ollama
            XCTAssertNoThrow(try LocalModelClient.validateSettings(settings), "Rejected loopback endpoint: \(endpoint)")
        }

        for endpoint in [
            "https://127.0.0.1:1234",
            "http://localhost:1234",
            "http://192.168.1.25:1234",
            "http://user:password@127.0.0.1:1234",
            "http://127.0.0.1:1234?model=remote",
            "http://127.0.0.1:1234/#fragment",
            "http://127.0.0.1:1234/%2e%2e/private",
            "http://127.0.0.1:1234/proxy//v1",
            "http://127.0.0.1:1234/proxy\\v1"
        ] {
            let settings = LocalModelSettings(backend: .openAICompatible, endpoint: endpoint, model: "local-chat")
            XCTAssertThrowsError(try LocalModelClient.validateSettings(settings), "Accepted unsafe endpoint: \(endpoint)")
        }
    }

    func testOllamaNDJSONCompletesWithOptionalUsageAndNeverSendsCredentialOrCookieHeaders() async throws {
        let modelList = Data(#"{"models":[{"name":"qwen2.5:7b","model":"qwen2.5:7b"}]}"#.utf8)
        let stream = Data([
            #"{"model":"qwen2.5:7b","message":{"role":"assistant","content":"Hello"},"done":false}"#,
            #"{"model":"qwen2.5:7b","message":{"role":"assistant","content":"!"},"done":false}"#,
            #"{"model":"qwen2.5:7b","prompt_eval_count":12,"eval_count":2,"done":true,"done_reason":"stop"}"#
        ].joined(separator: "\n").appending("\n").utf8)
        let server = try LoopbackHTTPServer { request in
            request.method == "GET"
                ? .json(modelList, headers: ["Set-Cookie": "server-session=must-not-return; Path=/"])
                : .stream(stream, contentType: "application/x-ndjson")
        }
        defer { server.stop() }
        let prompt = "Keep this prompt local."
        let response = try await LocalModelClient().generate(
            settings: ollamaSettings(server: server, model: "qwen2.5:7b"),
            prompt: prompt,
            cancellationRequestURL: nil
        )

        XCTAssertEqual(response.text, "Hello!")
        XCTAssertEqual(response.usage.inputTokens, 12)
        XCTAssertEqual(response.usage.outputTokens, 2)
        XCTAssertEqual(response.usage.estimatedInputTokens, max(1, (prompt.utf8.count + 1) / 2))

        let requests = server.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "POST"])
        XCTAssertEqual(requests.map(\.path), ["/api/tags", "/api/chat"])
        for request in requests {
            XCTAssertNil(request.headers["authorization"])
            XCTAssertNil(request.headers["proxy-authorization"])
            XCTAssertNil(request.headers["proxy-connection"])
            XCTAssertNil(request.headers["cookie"])
            XCTAssertNil(request.headers["cookie2"])
        }
        XCTAssertEqual(requests[0].headers["accept"], "application/json")
        XCTAssertEqual(requests[1].headers["content-type"], "application/json")
        let body = try XCTUnwrap(requests[1].jsonBody)
        XCTAssertEqual(body["model"] as? String, "qwen2.5:7b")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, prompt)
        let options = try XCTUnwrap(body["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 8_192)
        XCTAssertEqual(options["num_predict"] as? Int, 1_024)
    }

    func testOpenAICompatibleSSERequiresFinishReasonBeforeDoneAndReportsProviderUsage() async throws {
        let modelList = Data(#"{"data":[{"id":"local-chat","context_length":4096}]}"#.utf8)
        let stream = Data([
            #"data: {"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            #"data: {"choices":[],"usage":{"prompt_tokens":19,"completion_tokens":2}}"#,
            "data: [DONE]"
        ].joined(separator: "\n\n").appending("\n\n").utf8)
        let server = try LoopbackHTTPServer { request in
            request.method == "GET"
                ? .json(modelList)
                : .stream(stream, contentType: "text/event-stream")
        }
        defer { server.stop() }
        let prompt = "Explain this."
        var settings = openAISettings(server: server, model: "local-chat")
        settings.contextWindowTokens = 4_096
        let response = try await makeClient().generate(
            settings: settings,
            prompt: prompt,
            cancellationRequestURL: nil
        )

        XCTAssertEqual(response.text, "Hello world")
        XCTAssertEqual(response.usage.inputTokens, 19)
        XCTAssertEqual(response.usage.outputTokens, 2)
        XCTAssertEqual(server.requests.map(\.path), ["/v1/models", "/v1/chat/completions"])
        let body = try XCTUnwrap(server.requests.last?.jsonBody)
        XCTAssertEqual(body["model"] as? String, "local-chat")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_tokens"] as? Int, 1_024)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, prompt)
    }

    func testOllamaContextSettingAboveReportedModelWindowRefusesBeforePost() async throws {
        let modelList = Data(#"{"models":[{"model":"qwen2.5:7b","name":"qwen2.5:7b","details":{"context_length":4096}}]}"#.utf8)
        let responseBody = Data(#"{"message":{"content":"should not be requested"},"done":true,"done_reason":"stop"}"#.appending("\n").utf8)
        let server = try LoopbackHTTPServer { request in
            request.method == "GET" ? .json(modelList) : .stream(responseBody)
        }
        defer { server.stop() }
        let oversizedSettings = LocalModelSettings(
            backend: .ollama,
            endpoint: "http://127.0.0.1:\(server.port)",
            model: "qwen2.5:7b",
            contextWindowTokens: 8_192,
            maxOutputTokens: 1_024
        )

        do {
            _ = try await makeClient().generate(
                settings: oversizedSettings,
                prompt: "A small prompt is enough to test the configured window.",
                cancellationRequestURL: nil
            )
            XCTFail("The client accepted a configured context larger than the model-reported window.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput(let message) = error else {
                return XCTFail("Unexpected context-window error: \(error)")
            }
            XCTAssertTrue(message.contains("4096"))
            XCTAssertTrue(message.contains("8192"))
            XCTAssertTrue(message.lowercased().contains("context"))
        }
        XCTAssertEqual(server.requests.map(\.method), ["GET"])
        XCTAssertFalse(server.requests.contains { $0.method == "POST" })

        let supportedSettings = LocalModelSettings(
            backend: .ollama,
            endpoint: "http://127.0.0.1:\(server.port)",
            model: "qwen2.5:7b",
            contextWindowTokens: 4_096,
            maxOutputTokens: 1_024
        )
        let supportedResponse = try await makeClient().generate(
            settings: supportedSettings,
            prompt: "Use a context setting within the reported model window.",
            cancellationRequestURL: nil
        )
        XCTAssertEqual(supportedResponse.text, "should not be requested")
        let requests = server.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET", "POST"])
        let body = try XCTUnwrap(requests.last?.jsonBody)
        let options = try XCTUnwrap(body["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 4_096)
        XCTAssertEqual(options["num_predict"] as? Int, 1_024)
    }

    func testMissingProviderUsageStaysUnknownAndOnlyByteEstimateIsReported() async throws {
        let modelList = Data(#"{"models":[{"name":"qwen2.5:7b"}]}"#.utf8)
        let stream = Data(#"{"message":{"content":"Answer"},"done":true,"done_reason":"stop"}"#.appending("\n").utf8)
        let server = try LoopbackHTTPServer { request in
            request.method == "GET" ? .json(modelList) : .stream(stream)
        }
        defer { server.stop() }
        let prompt = "Estimate this input."
        let response = try await makeClient().generate(
            settings: ollamaSettings(server: server, model: "qwen2.5:7b"),
            prompt: prompt,
            cancellationRequestURL: nil
        )

        XCTAssertEqual(response.text, "Answer")
        XCTAssertNil(response.usage.inputTokens)
        XCTAssertNil(response.usage.outputTokens)
        XCTAssertEqual(response.usage.estimatedInputTokens, max(1, (prompt.utf8.count + 1) / 2))
    }

    func testRedirectIsRejectedWithoutFollowingLocation() async throws {
        let server = try LoopbackHTTPServer { _ in
            .response(status: 302, headers: ["Location": "/redirect-target"], body: Data("redirected".utf8))
        }
        defer { server.stop() }

        do {
            _ = try await makeClient().models(settings: ollamaSettings(server: server, model: "qwen2.5:7b"))
            XCTFail("The local model client followed or accepted an HTTP redirect.")
        } catch let error as AgentBridgeError {
            guard case .providerFailed(.local, _) = error else {
                return XCTFail("Unexpected redirect error: \(error)")
            }
        }

        XCTAssertEqual(server.requests.map(\.path), ["/api/tags"])
    }

    func testCloudModelTagsAndRemoteMetadataAreRejectedBeforePromptPost() async throws {
        let emptyServer = try LoopbackHTTPServer { _ in .json(Data(#"{"models":[]}"#.utf8)) }
        defer { emptyServer.stop() }
        do {
            _ = try await makeClient().generate(
                settings: ollamaSettings(server: emptyServer, model: "qwen2.5:cloud"),
                prompt: "Do not leave this machine.",
                cancellationRequestURL: nil
            )
            XCTFail("A cloud-tagged model was accepted.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else { return XCTFail("Unexpected cloud tag error: \(error)") }
        }
        XCTAssertTrue(emptyServer.requests.isEmpty, "A cloud-tagged model must be rejected before any request.")

        let remoteList = Data(#"{"data":[{"id":"local-chat","remote":true}]}"#.utf8)
        let remoteServer = try LoopbackHTTPServer { _ in .json(remoteList) }
        defer { remoteServer.stop() }
        do {
            _ = try await makeClient().generate(
                settings: openAISettings(server: remoteServer, model: "local-chat"),
                prompt: "This prompt must not be posted.",
                cancellationRequestURL: nil
            )
            XCTFail("A model marked remote by the server was accepted.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else { return XCTFail("Unexpected remote metadata error: \(error)") }
        }
        XCTAssertEqual(remoteServer.requests.map(\.method), ["GET"], "Remote metadata must stop before the prompt POST.")
        XCTAssertFalse(remoteServer.requests.contains { $0.method == "POST" })
    }

    func testOllamaErrorInvalidJSONMissingCompletionLengthAndToolCallsFail() async throws {
        let cases: [(String, Data)] = [
            ("error object", Data(#"{"error":"model failed"}"#.utf8)),
            ("invalid JSON", Data("not-json\n".utf8)),
            ("missing done marker", Data(#"{"message":{"content":"partial"},"done":false}"#.utf8)),
            ("length completion", Data(#"{"message":{"content":"partial"},"done":true,"done_reason":"length"}"#.utf8)),
            ("tool call", Data(#"{"message":{"tool_calls":[{"function":{"name":"run"}}]},"done":false}"#.utf8))
        ]
        for (label, payload) in cases {
            try await assertGenerationFails(
                label: label,
                backend: .ollama,
                modelList: Data(#"{"models":[{"name":"qwen2.5:7b"}]}"#.utf8),
                stream: payload
            )
        }
    }

    func testOpenAICompatibleErrorMissingFinishReasonLengthAndToolCallsFail() async throws {
        let modelList = Data(#"{"data":[{"id":"local-chat"}]}"#.utf8)
        let cases: [(String, Data)] = [
            ("error event", Data(#"data: {"error":{"message":"failed"}}"#.utf8)),
            ("invalid JSON", Data("data: not-json\n\n".utf8)),
            ("missing finish reason", Data("data: [DONE]\n\n".utf8)),
            ("length finish reason", Data(#"data: {"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":"length"}]}"#.utf8)),
            ("tool call", Data(#"data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0}]},"finish_reason":null}]}"#.utf8))
        ]
        for (label, payload) in cases {
            try await assertGenerationFails(
                label: label,
                backend: .openAICompatible,
                modelList: modelList,
                stream: payload
            )
        }
    }

    func testOutputAndRawResponseBoundsRejectPartialResults() async throws {
        let modelList = Data(#"{"models":[{"name":"qwen2.5:7b"}]}"#.utf8)
        let outputStream = Data([
            #"{"message":{"content":"123456"},"done":false}"#,
            #"{"done":true,"done_reason":"stop"}"#
        ].joined(separator: "\n").appending("\n").utf8)
        let server = try LoopbackHTTPServer { request in
            request.method == "GET" ? .json(modelList) : .stream(outputStream)
        }
        defer { server.stop() }

        do {
            _ = try await makeClient().generate(
                settings: ollamaSettings(server: server, model: "qwen2.5:7b"),
                prompt: "Bound the output.",
                cancellationRequestURL: nil,
                maximumOutputBytes: 5
            )
            XCTFail("A response above the configured output cap was accepted.")
        } catch let error as AgentBridgeError {
            guard case .providerFailed(.local, _) = error else { return XCTFail("Unexpected output bound error: \(error)") }
        }

        let invalidCapServer = try LoopbackHTTPServer { _ in .json(modelList) }
        defer { invalidCapServer.stop() }
        do {
            _ = try await makeClient().generate(
                settings: ollamaSettings(server: invalidCapServer, model: "qwen2.5:7b"),
                prompt: "Reject an invalid cap.",
                cancellationRequestURL: nil,
                maximumOutputBytes: 0
            )
            XCTFail("A zero output cap was accepted.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else { return XCTFail("Unexpected invalid cap error: \(error)") }
        }
        XCTAssertTrue(invalidCapServer.requests.isEmpty)

        let oversizedStream = Data(repeating: 0x0A, count: LocalModelClient.maximumResponseBytes + 1)
        let rawLimitServer = try LoopbackHTTPServer { request in
            request.method == "GET" ? .json(modelList) : .stream(oversizedStream)
        }
        defer { rawLimitServer.stop() }
        do {
            _ = try await makeClient().generate(
                settings: ollamaSettings(server: rawLimitServer, model: "qwen2.5:7b"),
                prompt: "Reject oversized transport data.",
                cancellationRequestURL: nil
            )
            XCTFail("A stream above the raw response cap was accepted.")
        } catch let error as AgentBridgeError {
            guard case .providerFailed(.local, _) = error else { return XCTFail("Unexpected raw response bound error: \(error)") }
        }
    }

    func testTaskCancellationDuringModelDiscoveryDoesNotPostPrompt() async throws {
        let gate = StallGate()
        let server = try LoopbackHTTPServer { request in
            request.method == "GET"
                ? .stalled(Data(#"{"models":["#.utf8), declaredLength: 256, gate: gate)
                : .json(Data(#"{"unexpected":true}"#.utf8))
        }
        defer { server.stop() }
        let task = Task {
            try await makeClient().generate(
                settings: ollamaSettings(server: server, model: "qwen2.5:7b"),
                prompt: "This prompt must not be sent.",
                cancellationRequestURL: nil
            )
        }

        XCTAssertTrue(gate.waitUntilStarted(), "The fake server did not stall the model-list response.")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation while model discovery was stalled.")
        } catch let error as AgentBridgeError {
            XCTAssertEqual(error, .processCancelled)
        }
        XCTAssertEqual(server.requests.map(\.method), ["GET"])
        XCTAssertFalse(server.requests.contains { $0.method == "POST" })
    }

    func testCancellationFlagStopsStalledChatBodyWithoutReturningPartialText() async throws {
        let gate = StallGate()
        let server = try serverStallingChatBody(gate: gate)
        defer { server.stop() }
        let cancellation = CancellationFlag()
        let task = Task {
            try await makeClient().generate(
                settings: ollamaSettings(server: server, model: "qwen2.5:7b"),
                prompt: "Do not return partial output.",
                cancellationRequestURL: nil,
                cancellation: cancellation
            )
        }

        XCTAssertTrue(gate.waitUntilStarted(), "The fake server did not stall the chat body.")
        cancellation.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation while the chat response body was stalled.")
        } catch let error as AgentBridgeError {
            XCTAssertEqual(error, .processCancelled)
        }
        XCTAssertEqual(server.requests.map(\.method), ["GET", "POST"])
        gate.release()
    }

    func testCancellationRequestFileDuringModelDiscoveryPreventsPromptPost() async throws {
        let gate = StallGate()
        let server = try LoopbackHTTPServer { request in
            request.method == "GET"
                ? .stalled(Data(#"{"models":["#.utf8), declaredLength: 256, gate: gate)
                : .json(Data(#"{"unexpected":true}"#.utf8))
        }
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentBridge-local-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cancellationURL = root.appendingPathComponent("cancel.request")
        let task = Task {
            try await makeClient().generate(
                settings: ollamaSettings(server: server, model: "qwen2.5:7b"),
                prompt: "Do not post this prompt.",
                cancellationRequestURL: cancellationURL
            )
        }

        XCTAssertTrue(gate.waitUntilStarted(), "The fake server did not stall model discovery.")
        try Data("cancel".utf8).write(to: cancellationURL)
        do {
            _ = try await task.value
            XCTFail("Expected the cancellation request file to cancel model discovery.")
        } catch let error as AgentBridgeError {
            XCTAssertEqual(error, .processCancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancellationURL.path), "The cancellation request should be consumed.")
        XCTAssertEqual(server.requests.map(\.method), ["GET"])
        XCTAssertFalse(server.requests.contains { $0.method == "POST" })
    }

    func testCancellationRequestFileDuringStalledChatDoesNotReturnPartialText() async throws {
        let gate = StallGate()
        let server = try serverStallingChatBody(gate: gate)
        defer { server.stop() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentBridge-local-chat-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cancellationURL = root.appendingPathComponent("cancel.request")
        let task = Task {
            try await makeClient().generate(
                settings: ollamaSettings(server: server, model: "qwen2.5:7b"),
                prompt: "Do not return partial text.",
                cancellationRequestURL: cancellationURL
            )
        }

        XCTAssertTrue(gate.waitUntilStarted(), "The fake server did not stall the chat response.")
        try Data("cancel".utf8).write(to: cancellationURL)
        do {
            _ = try await task.value
            XCTFail("Expected the cancellation request file to cancel the chat request.")
        } catch let error as AgentBridgeError {
            XCTAssertEqual(error, .processCancelled)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancellationURL.path), "The cancellation request should be consumed.")
        XCTAssertEqual(server.requests.map(\.method), ["GET", "POST"])
        gate.release()
    }

    private func assertGenerationFails(
        label: String,
        backend: LocalModelBackend,
        modelList: Data,
        stream: Data
    ) async throws {
        let server = try LoopbackHTTPServer { request in
            request.method == "GET"
                ? .json(modelList)
                : .stream(stream, contentType: backend == .ollama ? "application/x-ndjson" : "text/event-stream")
        }
        defer { server.stop() }
        let settings = backend == .ollama
            ? ollamaSettings(server: server, model: "qwen2.5:7b")
            : openAISettings(server: server, model: "local-chat")
        do {
            _ = try await makeClient().generate(settings: settings, prompt: "Test \(label).", cancellationRequestURL: nil)
            XCTFail("Accepted invalid stream case: \(label)")
        } catch let error as AgentBridgeError {
            guard case .providerFailed(.local, _) = error else {
                return XCTFail("Unexpected error for \(label): \(error)")
            }
        }
        XCTAssertEqual(server.requests.map(\.method), ["GET", "POST"], "\(label)")
    }

    private func serverStallingChatBody(gate: StallGate) throws -> LoopbackHTTPServer {
        let modelList = Data(#"{"models":[{"name":"qwen2.5:7b"}]}"#.utf8)
        return try LoopbackHTTPServer { request in
            request.method == "GET"
                ? .json(modelList)
                : .stalled(
                    Data(#"{"message":{"content":"partial"},"done":false}"#.utf8),
                    declaredLength: 512,
                    gate: gate
                )
        }
    }

    private func makeClient() -> LocalModelClient {
        LocalModelClient(sessionFactory: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 10
            configuration.timeoutIntervalForResource = 10
            return URLSession(configuration: configuration)
        })
    }

    private func ollamaSettings(server: LoopbackHTTPServer, model: String) -> LocalModelSettings {
        LocalModelSettings(backend: .ollama, endpoint: "http://127.0.0.1:\(server.port)", model: model)
    }

    private func openAISettings(server: LoopbackHTTPServer, model: String) -> LocalModelSettings {
        LocalModelSettings(backend: .openAICompatible, endpoint: "http://127.0.0.1:\(server.port)", model: model)
    }
}

struct CapturedHTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var jsonBody: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}

struct StubHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    let declaredContentLength: Int?
    let stallGate: StallGate?

    static func json(_ body: Data, headers: [String: String] = [:]) -> StubHTTPResponse {
        StubHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"].merging(headers) { _, new in new },
            body: body,
            declaredContentLength: nil,
            stallGate: nil
        )
    }

    static func stream(_ body: Data, contentType: String = "application/x-ndjson") -> StubHTTPResponse {
        StubHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": contentType],
            body: body,
            declaredContentLength: nil,
            stallGate: nil
        )
    }

    static func response(status: Int, headers: [String: String], body: Data) -> StubHTTPResponse {
        StubHTTPResponse(statusCode: status, headers: headers, body: body, declaredContentLength: nil, stallGate: nil)
    }

    static func stalled(_ prefix: Data, declaredLength: Int, gate: StallGate) -> StubHTTPResponse {
        StubHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/x-ndjson"],
            body: prefix,
            declaredContentLength: declaredLength,
            stallGate: gate
        )
    }
}

final class StallGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var released = false

    func markStarted() {
        condition.lock()
        started = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilStarted(timeout: TimeInterval = 5) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !started {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    func waitUntilReleased() {
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// A small HTTP/1.1 server bound only to 127.0.0.1. It uses real sockets so
/// URLSession cancellation, streaming, and redirect behavior traverse TCP.
final class LoopbackHTTPServer: @unchecked Sendable {
    private let listener: Int32
    private let handler: @Sendable (CapturedHTTPRequest) -> StubHTTPResponse
    private let queue = DispatchQueue(label: "AgentBridge.LocalModelClientTests.LoopbackHTTPServer")
    private let condition = NSCondition()
    private var stopped = false
    private var activeConnections = Set<Int32>()
    private var gates: [StallGate] = []
    private var capturedRequests: [CapturedHTTPRequest] = []
    let port: UInt16

    var requests: [CapturedHTTPRequest] {
        condition.lock()
        defer { condition.unlock() }
        return capturedRequests
    }

    init(handler: @escaping @Sendable (CapturedHTTPRequest) -> StubHTTPResponse) throws {
        self.handler = handler
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Self.socketError("socket") }
        listener = descriptor

        var reuseAddress: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuseAddress, socklen_t(MemoryLayout<Int32>.size))
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0x7f000001).bigEndian)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(descriptor)
            throw Self.socketError("bind")
        }
        guard Darwin.listen(descriptor, 16) == 0 else {
            Darwin.close(descriptor)
            throw Self.socketError("listen")
        }

        var boundAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &addressLength)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw Self.socketError("getsockname")
        }
        port = UInt16(bigEndian: boundAddress.sin_port)
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func waitForRequestCount(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while capturedRequests.count < count {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    func stop() {
        condition.lock()
        guard !stopped else {
            condition.unlock()
            return
        }
        stopped = true
        let connections = Array(activeConnections)
        let activeGates = gates
        condition.broadcast()
        condition.unlock()

        _ = Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        for descriptor in connections { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
        for gate in activeGates { gate.release() }
    }

    private func acceptLoop() {
        while true {
            condition.lock()
            let shouldStop = stopped
            condition.unlock()
            if shouldStop { return }

            var peer = sockaddr()
            var peerLength = socklen_t(MemoryLayout<sockaddr>.size)
            let client = Darwin.accept(listener, &peer, &peerLength)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            condition.lock()
            activeConnections.insert(client)
            let shouldHandle = !stopped
            condition.unlock()
            guard shouldHandle else {
                _ = Darwin.shutdown(client, SHUT_RDWR)
                Darwin.close(client)
                return
            }
            serve(client)
            condition.lock()
            activeConnections.remove(client)
            condition.unlock()
            Darwin.close(client)
        }
    }

    private func serve(_ client: Int32) {
        guard let request = readRequest(client) else { return }
        condition.lock()
        capturedRequests.append(request)
        condition.broadcast()
        condition.unlock()

        let response = handler(request)
        let reason = Self.reasonPhrase(response.statusCode)
        var headers = response.headers
        headers["Content-Length"] = String(response.declaredContentLength ?? response.body.count)
        headers["Connection"] = "close"
        let headerText = (["HTTP/1.1 \(response.statusCode) \(reason)"] + headers
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { "\($0.key): \($0.value)" } + ["", ""]).joined(separator: "\r\n")
        guard Self.sendAll(Data(headerText.utf8), to: client), Self.sendAll(response.body, to: client) else { return }
        if let gate = response.stallGate {
            condition.lock()
            gates.append(gate)
            condition.unlock()
            gate.markStarted()
            gate.waitUntilReleased()
        }
    }

    private func readRequest(_ client: Int32) -> CapturedHTTPRequest? {
        let terminator = Data([0x0D, 0x0A, 0x0D, 0x0A])
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        var headerRange: Range<Data.Index>?
        while headerRange == nil {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(client, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            guard count > 0 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 65_536 else { return nil }
            headerRange = data.range(of: terminator)
        }
        guard let headerRange,
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard (0...3 * 1_024 * 1_024).contains(contentLength) else { return nil }
        var body = Data(data[headerRange.upperBound...])
        while body.count < contentLength {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(client, rawBuffer.baseAddress, rawBuffer.count, 0)
            }
            guard count > 0 else { return nil }
            body.append(contentsOf: buffer.prefix(count))
            if body.count > contentLength {
                body = Data(body.prefix(contentLength))
            }
        }
        return CapturedHTTPRequest(method: String(requestParts[0]), path: String(requestParts[1]), headers: headers, body: Data(body.prefix(contentLength)))
    }

    private static func sendAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var sent = 0
            while sent < rawBuffer.count {
                let count = Darwin.send(descriptor, baseAddress.advanced(by: sent), rawBuffer.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private static func reasonPhrase(_ statusCode: Int) -> String {
        switch statusCode {
        case 200: "OK"
        case 302: "Found"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default: "Response"
        }
    }

    private static func socketError(_ operation: String) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(operation) failed"])
    }
}
