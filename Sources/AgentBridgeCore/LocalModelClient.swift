import Foundation

public struct LocalModelUsage: Equatable, Sendable {
    /// Provider-reported token values are kept separate from byte estimates.
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let estimatedInputTokens: Int

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, estimatedInputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.estimatedInputTokens = estimatedInputTokens
    }
}

public struct LocalModelResponse: Equatable, Sendable {
    public let text: String
    public let usage: LocalModelUsage

    public init(text: String, usage: LocalModelUsage) {
        self.text = text
        self.usage = usage
    }
}

/// Direct HTTP access to an explicitly selected loopback model server.
/// Requests never use provider CLIs, credentials, URL caches, cookies, or
/// redirects. The server must still report the chosen model as local.
public final class LocalModelClient: @unchecked Sendable {
    public static let maximumResponseBytes = 2 * 1_024 * 1_024
    public static let requestTimeout: TimeInterval = 300
    public static let defaultDailyRunLimit = 200
    public static let defaultSessionRunLimit = 50

    private let sessionFactory: @Sendable () -> URLSession

    public init() {
        self.sessionFactory = { Self.makeSession() }
    }

    /// Validates persisted endpoint/settings structure without making a network request.
    public static func validateSettings(_ settings: LocalModelSettings) throws {
        try settings.validate()
        _ = try endpointURL(settings: settings, suffix: settings.backend == .ollama ? "/api/tags" : "/v1/models")
    }

    init(sessionFactory: @escaping @Sendable () -> URLSession) {
        self.sessionFactory = sessionFactory
    }

    public func models(settings: LocalModelSettings) async throws -> [LocalModelDescriptor] {
        try settings.validate()
        let endpoint = try Self.endpointURL(settings: settings, suffix: settings.backend == .ollama ? "/api/tags" : "/v1/models")
        var request = URLRequest(url: endpoint, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = sessionFactory()
        defer { session.invalidateAndCancel() }

        do {
            let data = try await withTaskCancellationHandler {
                try await Self.readModelList(request: request, session: session)
            } onCancel: {
                session.invalidateAndCancel()
            }
            return try Self.parseModels(data, backend: settings.backend)
        } catch is CancellationError {
            throw AgentBridgeError.processCancelled
        } catch let error as URLError where error.code == .cancelled {
            throw AgentBridgeError.processCancelled
        } catch let error as AgentBridgeError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AgentBridgeError.processTimedOut
        } catch {
            throw AgentBridgeError.providerFailed(.local, "無法連線到指定的本機模型端點：\(OutputRedactor.redact(error.localizedDescription))")
        }
    }

    public func testConnection(settings: LocalModelSettings) async throws -> Bool {
        _ = try await models(settings: settings)
        return true
    }

    public func generate(
        settings: LocalModelSettings,
        prompt: String,
        cancellationRequestURL: URL?,
        cancellation: CancellationFlag = CancellationFlag(),
        maximumOutputBytes: Int = LocalModelClient.maximumResponseBytes,
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> LocalModelResponse {
        try settings.validate()
        guard (1...Self.maximumResponseBytes).contains(maximumOutputBytes) else {
            throw AgentBridgeError.invalidInput("本機模型回覆大小上限無效。")
        }
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("請先選擇要使用的本機模型。")
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= Self.maximumResponseBytes else {
            throw AgentBridgeError.invalidInput("本機模型提示不可空白，且最多 2 MiB。")
        }
        try Self.requireLocalModelName(settings.model)

        let request = try Self.chatRequest(settings: settings, prompt: prompt)
        let session = sessionFactory()
        defer { session.invalidateAndCancel() }
        let estimatedInputTokens = max(1, (prompt.utf8.count + 1) / 2)
        let deadline = Date().addingTimeInterval(Self.requestTimeout)
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: LocalModelResponse.self) { group in
                    group.addTask {
                        let listURL = try Self.endpointURL(
                            settings: settings,
                            suffix: settings.backend == .ollama ? "/api/tags" : "/v1/models"
                        )
                        var listRequest = URLRequest(url: listURL, timeoutInterval: Self.requestTimeout)
                        listRequest.httpMethod = "GET"
                        listRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                        let data = try await Self.readModelList(request: listRequest, session: session)
                        let availableModels = try Self.parseModels(data, backend: settings.backend)
                        guard let selectedModel = availableModels.first(where: { $0.id == settings.model || $0.name == settings.model }) else {
                            throw AgentBridgeError.invalidInput("指定的本機模型不在伺服器提供的本機模型清單中。")
                        }
                        try Self.requireLocalModelName(selectedModel.id)
                        try Self.requireLocalModelName(selectedModel.name)
                        if let reportedContextWindow = selectedModel.contextWindowTokens,
                           settings.contextWindowTokens > reportedContextWindow {
                            throw AgentBridgeError.invalidInput(
                                "所選模型回報的上下文視窗為 \(reportedContextWindow) tokens，低於目前設定的 \(settings.contextWindowTokens) tokens；請調低本機模型上下文設定後重試。"
                            )
                        }
                        return try await Self.readStream(
                            request: request,
                            session: session,
                            backend: settings.backend,
                            estimatedInputTokens: estimatedInputTokens,
                            maximumOutputBytes: maximumOutputBytes,
                            onProgress: onProgress
                        )
                    }
                    group.addTask {
                        try await Self.pollCancellation(
                            cancellation: cancellation,
                            cancellationRequestURL: cancellationRequestURL,
                            deadline: deadline
                        )
                    }
                    defer {
                        group.cancelAll()
                        session.invalidateAndCancel()
                    }
                    guard let result = try await group.next() else {
                        throw AgentBridgeError.providerFailed(.local, "本機模型沒有回傳結果。")
                    }
                    return result
                }
            } onCancel: {
                cancellation.cancel()
                session.invalidateAndCancel()
            }
        } catch is CancellationError {
            throw AgentBridgeError.processCancelled
        } catch let error as URLError where error.code == .cancelled {
            throw AgentBridgeError.processCancelled
        } catch let error as AgentBridgeError {
            throw error
        } catch let error as URLError where error.code == .timedOut {
            throw AgentBridgeError.processTimedOut
        } catch {
            throw AgentBridgeError.providerFailed(.local, "本機模型連線失敗：\(OutputRedactor.redact(error.localizedDescription))")
        }
    }

    private static func readStream(
        request: URLRequest,
        session: URLSession,
        backend: LocalModelBackend,
        estimatedInputTokens: Int,
        maximumOutputBytes: Int,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws -> LocalModelResponse {
        let (bytes, response) = try await session.bytes(for: request, delegate: LocalModelNoRedirectDelegate())
        guard let http = response as? HTTPURLResponse else {
            throw AgentBridgeError.providerFailed(.local, "本機模型伺服器回應格式無效。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw httpError(statusCode: http.statusCode)
        }

        var line: [UInt8] = []
        var totalBytes = 0
        var outputBytes = 0
        var output = ""
        var inputTokens: Int?
        var outputTokens: Int?
        var completed = false
        var openAIFinishReasonAccepted = false
        var lastProgressAt = Date.distantPast

        func consumeLine(_ line: [UInt8]) throws {
            guard !line.isEmpty else { return }
            let lineBytes = line.last == 0x0D ? Array(line.dropLast()) : line
            let data = Data(lineBytes)
            guard let text = String(data: data, encoding: .utf8) else {
                throw AgentBridgeError.providerFailed(.local, "本機模型串流包含無效的 UTF-8。")
            }
            switch backend {
            case .ollama:
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AgentBridgeError.providerFailed(.local, "Ollama 串流包含無效的 JSON。")
                }
                guard !containsRemoteMetadata(object) else {
                    throw AgentBridgeError.providerFailed(.local, "Ollama 回報模型使用遠端或雲端執行；本機模式已停止回覆。")
                }
                if let message = object["message"] as? [String: Any], let chunk = message["content"] as? String {
                    try append(chunk, to: &output, bytes: &outputBytes, maximumBytes: maximumOutputBytes)
                    emitProgressIfNeeded(onProgress, lastEmittedAt: &lastProgressAt)
                }
                if let count = object["prompt_eval_count"] as? Int, count >= 0 { inputTokens = count }
                if let count = object["eval_count"] as? Int, count >= 0 { outputTokens = count }
                if object["error"] != nil {
                    throw AgentBridgeError.providerFailed(.local, "Ollama 回報模型執行錯誤；未接受部分回覆。")
                }
                if let message = object["message"] as? [String: Any],
                   message["tool_calls"] != nil || message["function_call"] != nil {
                    throw AgentBridgeError.providerFailed(.local, "本機模型要求呼叫工具；本機聊天目前只接受純文字回覆。")
                }
                if object["done"] as? Bool == true {
                    if let reason = object["done_reason"] as? String,
                       !["stop", "eos_token", "end_turn"].contains(reason.lowercased()) {
                        throw AgentBridgeError.providerFailed(.local, "Ollama 回覆未正常完成；不會儲存不完整內容。")
                    }
                    completed = true
                }
            case .openAICompatible:
                guard text.hasPrefix("data:") else { return }
                let payload = text.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" {
                    guard openAIFinishReasonAccepted else {
                        throw AgentBridgeError.providerFailed(.local, "OpenAI 相容串流在提供正常完成原因前結束。")
                    }
                    completed = true
                    return
                }
                guard let payloadData = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                    throw AgentBridgeError.providerFailed(.local, "OpenAI 相容串流包含無效的 JSON。")
                }
                if object["error"] != nil {
                    throw AgentBridgeError.providerFailed(.local, "OpenAI 相容伺服器回報模型執行錯誤；未接受部分回覆。")
                }
                if let usage = object["usage"] as? [String: Any] {
                    if let count = usage["prompt_tokens"] as? Int, count >= 0 { inputTokens = count }
                    if let count = usage["completion_tokens"] as? Int, count >= 0 { outputTokens = count }
                }
                guard let choices = object["choices"] as? [[String: Any]] else {
                    if object["usage"] != nil { return }
                    throw AgentBridgeError.providerFailed(.local, "OpenAI 相容串流缺少 choices 陣列。")
                }
                if choices.isEmpty {
                    guard object["usage"] != nil else {
                        throw AgentBridgeError.providerFailed(.local, "OpenAI 相容串流沒有候選回覆。")
                    }
                    return
                }
                guard choices.count == 1, let choice = choices.first,
                      (choice["index"] as? Int ?? 0) == 0 else {
                    throw AgentBridgeError.providerFailed(.local, "OpenAI 相容串流回傳多個或不明候選回覆；本機模式無法安全判定。")
                }
                if choice["error"] != nil {
                    throw AgentBridgeError.providerFailed(.local, "OpenAI 相容串流回報候選回覆錯誤。")
                }
                let delta = choice["delta"] as? [String: Any]
                let message = choice["message"] as? [String: Any]
                if delta?["tool_calls"] != nil || delta?["function_call"] != nil
                    || message?["tool_calls"] != nil || message?["function_call"] != nil {
                    throw AgentBridgeError.providerFailed(.local, "本機模型要求呼叫工具；本機聊天目前只接受純文字回覆。")
                }
                if let finishReason = choice["finish_reason"] as? String {
                    guard ["stop", "eos_token", "end_turn"].contains(finishReason.lowercased()) else {
                        throw AgentBridgeError.providerFailed(.local, "OpenAI 相容回覆未正常完成；不會儲存不完整內容。")
                    }
                    openAIFinishReasonAccepted = true
                }
                if let delta, let chunk = delta["content"] as? String {
                    try append(chunk, to: &output, bytes: &outputBytes, maximumBytes: maximumOutputBytes)
                    emitProgressIfNeeded(onProgress, lastEmittedAt: &lastProgressAt)
                }
                if let message, let chunk = message["content"] as? String {
                    try append(chunk, to: &output, bytes: &outputBytes, maximumBytes: maximumOutputBytes)
                }
            }
        }

        for try await byte in bytes {
            totalBytes += 1
            guard totalBytes <= maximumResponseBytes else {
                throw AgentBridgeError.providerFailed(.local, "本機模型回應超過 2 MiB 上限。")
            }
            if byte == 0x0A {
                try consumeLine(line)
                line.removeAll(keepingCapacity: true)
                if completed { break }
            } else {
                guard line.count < 1_048_576 else {
                    throw AgentBridgeError.providerFailed(.local, "本機模型串流單行超過 1 MiB 上限。")
                }
                line.append(byte)
            }
        }
        if !completed, !line.isEmpty {
            try consumeLine(line)
        }
        guard completed else {
            throw AgentBridgeError.providerFailed(.local, "本機模型串流提前結束，未收到完成標記；不會接受不完整回覆。")
        }
        guard !output.isEmpty else {
            throw AgentBridgeError.providerFailed(.local, "本機模型完成串流但沒有回覆文字。")
        }
        onProgress?("本機模型已完成回覆。")
        return LocalModelResponse(
            text: OutputRedactor.redact(output),
            usage: LocalModelUsage(inputTokens: inputTokens, outputTokens: outputTokens, estimatedInputTokens: estimatedInputTokens)
        )
    }

    private static func readModelList(request: URLRequest, session: URLSession) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request, delegate: LocalModelNoRedirectDelegate())
        guard let http = response as? HTTPURLResponse else {
            throw AgentBridgeError.providerFailed(.local, "本機模型伺服器回應格式無效。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw httpError(statusCode: http.statusCode)
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else {
                throw AgentBridgeError.providerFailed(.local, "本機模型清單超過 1 MiB 上限。")
            }
            data.append(byte)
        }
        return data
    }

    private static func append(
        _ chunk: String,
        to output: inout String,
        bytes: inout Int,
        maximumBytes: Int
    ) throws {
        let count = chunk.utf8.count
        guard count <= maximumBytes - bytes else {
            throw AgentBridgeError.providerFailed(.local, "本機模型文字回應超過設定的大小上限；未接受不完整回覆。")
        }
        output += chunk
        bytes += count
    }

    private static func emitProgressIfNeeded(
        _ callback: (@Sendable (String) -> Void)?,
        lastEmittedAt: inout Date
    ) {
        guard let callback, Date().timeIntervalSince(lastEmittedAt) >= 1 else { return }
        lastEmittedAt = Date()
        callback("本機模型正在撰寫回覆。")
    }

    private static func pollCancellation(
        cancellation: CancellationFlag,
        cancellationRequestURL: URL?,
        deadline: Date
    ) async throws -> LocalModelResponse {
        while !Task.isCancelled {
            if cancellation.isCancelled {
                throw AgentBridgeError.processCancelled
            }
            if let cancellationRequestURL, FileManager.default.fileExists(atPath: cancellationRequestURL.path) {
                try? FileManager.default.removeItem(at: cancellationRequestURL)
                throw AgentBridgeError.processCancelled
            }
            guard Date() < deadline else { throw AgentBridgeError.processTimedOut }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CancellationError()
    }

    private static func chatRequest(settings: LocalModelSettings, prompt: String) throws -> URLRequest {
        let url = try endpointURL(
            settings: settings,
            suffix: settings.backend == .ollama ? "/api/chat" : "/v1/chat/completions"
        )
        var request = URLRequest(url: url, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body: [String: Any]
        switch settings.backend {
        case .ollama:
            body = [
                "model": settings.model,
                "messages": [["role": "user", "content": prompt]],
                "stream": true,
                "options": ["num_ctx": settings.contextWindowTokens, "num_predict": settings.maxOutputTokens]
            ]
        case .openAICompatible:
            body = [
                "model": settings.model,
                "messages": [["role": "user", "content": prompt]],
                "stream": true,
                "max_tokens": settings.maxOutputTokens
            ]
        }
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        } catch {
            throw AgentBridgeError.invalidInput("無法編碼本機模型要求。")
        }
        return request
    }

    private static func endpointURL(settings: LocalModelSettings, suffix: String) throws -> URL {
        guard var components = URLComponents(string: settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let rawHost = components.host?.lowercased(),
              ["127.0.0.1", "::1"].contains(rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))),
              components.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw AgentBridgeError.invalidInput("本機模型端點只能使用沒有帳密、查詢或片段的 http://127.0.0.1 或 http://[::1] 位址。")
        }
        let path = components.percentEncodedPath
        guard path.isEmpty || path == "/" || (
            path.hasPrefix("/") && !path.contains("%") && !path.contains("\\")
                && !path.contains("//")
                && path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." }
                && path.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/").contains($0) }
        ) else {
            throw AgentBridgeError.invalidInput("本機模型端點路徑含有不安全或無效的字元。")
        }
        let prefix = path == "/" ? "" : path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var prefixSegments = prefix.split(separator: "/").map(String.init)
        var route = suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if settings.backend == .openAICompatible, route.hasPrefix("v1/") {
            // Keep one terminal /v1 whether the user entered a server root,
            // /v1, a trailing slash, or a custom prefix such as /proxy/v1.
            while prefixSegments.count > 1,
                  prefixSegments.suffix(2).map({ $0.lowercased() }) == ["v1", "v1"] {
                prefixSegments.removeLast()
            }
            if prefixSegments.last?.lowercased() == "v1" {
                route.removeFirst("v1/".count)
            }
        } else if settings.backend == .ollama, prefixSegments.last?.lowercased() == "api",
                  route.hasPrefix("api/") {
            route.removeFirst("api/".count)
        }
        let normalizedPrefix = prefixSegments.joined(separator: "/")
        components.path = "/" + ([normalizedPrefix, route]
            .filter { !$0.isEmpty }
            .joined(separator: "/"))
        components.percentEncodedPath = components.path
        guard let url = components.url else {
            throw AgentBridgeError.invalidInput("本機模型端點格式無效。")
        }
        return url
    }

    private static func parseModels(_ data: Data, backend: LocalModelBackend) throws -> [LocalModelDescriptor] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil else {
            throw AgentBridgeError.providerFailed(.local, "本機模型清單格式無效。")
        }
        let records: [[String: Any]]
        switch backend {
        case .ollama:
            guard let values = object["models"] as? [[String: Any]] else {
                throw AgentBridgeError.providerFailed(.local, "Ollama 模型清單缺少 models 陣列。")
            }
            records = values
        case .openAICompatible:
            guard let values = object["data"] as? [[String: Any]] else {
                throw AgentBridgeError.providerFailed(.local, "OpenAI 相容模型清單缺少 data 陣列。")
            }
            records = values
        }
        guard records.count <= 2_048 else {
            throw AgentBridgeError.providerFailed(.local, "本機模型清單超過 2048 個項目。")
        }
        var result: [LocalModelDescriptor] = []
        var seen: Set<String> = []
        for item in records {
            guard !containsRemoteMetadata(item) else { continue }
            let id: String
            let name: String
            if backend == .ollama {
                id = item["model"] as? String ?? item["name"] as? String ?? ""
                name = item["name"] as? String ?? id
            } else {
                id = item["id"] as? String ?? ""
                name = item["name"] as? String ?? id
            }
            guard !id.isEmpty, id.utf8.count <= 256, !seen.contains(id),
                  !isRemoteModelTag(id), !isRemoteModelTag(name) else { continue }
            seen.insert(id)
            let context = findContextWindow(in: item)
            result.append(LocalModelDescriptor(id: id, name: name, contextWindowTokens: context))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func findContextWindow(in value: Any) -> Int? {
        guard let dictionary = value as? [String: Any] else { return nil }
        for key in ["context_length", "max_context_length", "context_window", "num_ctx", "contextWindowTokens"] {
            if let number = dictionary[key] as? NSNumber, number.intValue > 0, number.intValue <= 1_000_000 {
                return number.intValue
            }
        }
        for nested in dictionary.values {
            if let found = findContextWindow(in: nested) { return found }
        }
        return nil
    }

    private static func containsRemoteMetadata(_ value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            for (key, nested) in dictionary {
                let lower = key.lowercased()
                if ["remote", "is_remote", "cloud", "hosted", "is_hosted"].contains(lower), isTruthyRemoteMarker(nested) {
                    return true
                }
                if lower.contains("remote_url") || lower.contains("cloud_url") || lower.contains("hosted_url") {
                    if nested is String, !(nested as? String ?? "").isEmpty { return true }
                }
                if ["remote_model", "remote_host", "cloud_model", "cloud_host", "hosted_model", "hosted_host"].contains(lower),
                   isTruthyRemoteMarker(nested) { return true }
                if containsRemoteMetadata(nested) { return true }
            }
        } else if let values = value as? [Any] {
            return values.contains(where: containsRemoteMetadata)
        }
        return false
    }

    private static func isTruthyRemoteMarker(_ value: Any) -> Bool {
        if let boolean = value as? Bool { return boolean }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !normalized.isEmpty && !["false", "0", "none", "null", "local", "localhost"].contains(normalized)
        }
        return false
    }

    private static func isRemoteModelTag(_ value: String) -> Bool {
        let normalized = value.lowercased()
        let components = normalized.split { !$0.isLetter && !$0.isNumber }
        return components.contains(where: { ["cloud", "hosted", "remote"].contains(String($0)) })
            || normalized.contains("ollama.com")
    }

    private static func requireLocalModelName(_ value: String) throws {
        guard !isRemoteModelTag(value) else {
            throw AgentBridgeError.invalidInput("此模型標籤表示雲端、託管或遠端模型；本機模式拒絕使用它。")
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 256,
              !value.contains("\0") else {
            throw AgentBridgeError.invalidInput("本機模型名稱無效。")
        }
    }

    private static func httpError(statusCode: Int) -> AgentBridgeError {
        .providerFailed(.local, "本機模型伺服器回傳 HTTP \(statusCode)；未接受錯誤回應內容。")
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

private final class LocalModelNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
