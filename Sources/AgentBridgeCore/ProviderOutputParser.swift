import CoreFoundation
import Darwin
import Foundation

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
        var tokenUsage: TokenUsage?
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
                // Codex's input total includes the cached part.
                if let usage = event["usage"] as? [String: Any],
                   let input = tokenCount(usage["input_tokens"]),
                   let output = tokenCount(usage["output_tokens"]) {
                    let cached = min(input, tokenCount(usage["cached_input_tokens"]) ?? 0)
                    tokenUsage = TokenUsage(inputTokens: input - cached, cachedInputTokens: cached, outputTokens: output)
                }
            case "turn.failed", "error", "turn_error":
                throw AgentBridgeError.providerFailed(.codex, "The service reported that the session failed.")
            default:
                if event["error"] != nil { throw AgentBridgeError.providerFailed(.codex, "The service reported an error.") }
            }
        }
        guard completed, !finalText.isEmpty else { throw AgentBridgeError.unsupportedProviderOutput(.codex) }
        return ProviderOutput(text: finalText, providerSessionID: sessionID, tokenUsage: tokenUsage)
    }

    private static func parseClaude(_ text: String) throws -> ProviderOutput {
        var finalText = ""
        var sessionID: String?
        var actualCostUSD: Double?
        var tokenUsage: TokenUsage?
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
                if let usage = event["usage"] as? [String: Any],
                   let input = tokenCount(usage["input_tokens"]),
                   let output = tokenCount(usage["output_tokens"]) {
                    tokenUsage = TokenUsage(
                        inputTokens: input,
                        cachedInputTokens: tokenCount(usage["cache_read_input_tokens"]) ?? 0,
                        cacheWriteTokens: tokenCount(usage["cache_creation_input_tokens"]) ?? 0,
                        outputTokens: output
                    )
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
        return ProviderOutput(text: finalText, providerSessionID: sessionID, actualCostUSD: actualCostUSD, tokenUsage: tokenUsage)
    }

    /// Token counts only inform the usage dashboard, so a malformed one is left
    /// out instead of failing a run that otherwise succeeded.
    private static func tokenCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue >= 0, number.doubleValue <= Double(Int32.max),
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }
}
