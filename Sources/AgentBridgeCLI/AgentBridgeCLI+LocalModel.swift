import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func localModelCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge local settings|configure|models|test|preview discussion|project …")
        }
        switch action {
        case "settings", "current":
            guard arguments.count == 1 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge local settings")
            }
            let bridgeSettings = try service.settings()
            let profile = try service.selectedAccountProfile(provider: .local)
            let local = bridgeSettings.localModel
            print("Mode: Local model (uses no API key or subscription usage)")
            print("Local account: \(profile.name) · \(profile.id.uuidString.lowercased())")
            print("Shared memory: \(profile.allowsSharedMemory ? "allowed" : "not allowed")")
            print("Backend: \(localBackendName(local.backend))")
            print("Endpoint: \(local.endpoint)")
            print("Model: \(local.model.isEmpty ? "not set" : local.model)")
            print("Context window: \(local.contextWindowTokens) tokens")
            print("Output reserve: \(local.maxOutputTokens) tokens")
        case "configure":
            guard arguments.count > 1 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge local configure --backend ollama|openai-compatible --endpoint URL --model NAME [--context-window TOKENS] [--max-output TOKENS]")
            }
            var bridgeSettings = try service.settings()
            var local = bridgeSettings.localModel
            var seen = Set<String>()
            var index = 1
            while index < arguments.count {
                let option = arguments[index]
                guard seen.insert(option).inserted else {
                    throw AgentBridgeError.invalidInput("\(option) cannot be repeated.")
                }
                index += 1
                switch option {
                case "--backend":
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    switch value {
                    case "ollama": local.backend = .ollama
                    case "openai-compatible": local.backend = .openAICompatible
                    default: throw AgentBridgeError.invalidInput("--backend must be ollama or openai-compatible.")
                    }
                case "--endpoint":
                    local.endpoint = try nextOptionValue(option, arguments: arguments, index: &index)
                case "--model":
                    local.model = try nextOptionValue(option, arguments: arguments, index: &index)
                case "--context-window":
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let parsed = Int(value), parsed > 0 else {
                        throw AgentBridgeError.invalidInput("--context-window must be a positive token count.")
                    }
                    local.contextWindowTokens = parsed
                case "--max-output":
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let parsed = Int(value), parsed > 0 else {
                        throw AgentBridgeError.invalidInput("--max-output must be a positive token count.")
                    }
                    local.maxOutputTokens = parsed
                case "--api-key", "--api-key-env":
                    throw AgentBridgeError.invalidInput("Local models do not use API keys. This option is unsupported.")
                default:
                    throw AgentBridgeError.invalidInput("Unknown local configure option \(option).")
                }
            }
            guard (1_024...131_072).contains(local.contextWindowTokens),
                  (1...32_768).contains(local.maxOutputTokens),
                  local.contextWindowTokens - local.maxOutputTokens > 512 else {
                throw AgentBridgeError.invalidInput("The context window must be 1,024–131,072 tokens, the output reserve must be 1–32,768 tokens, and at least 513 tokens must remain beyond the output reserve for input and a safety margin.")
            }
            bridgeSettings.localModel = local
            try service.saveSettings(bridgeSettings)
            print("Saved the local model settings. AgentBridge never starts a service, downloads a model or switches to a cloud service on its own.")
            print("Run `agentbridge local test` to test the connection explicitly, or `agentbridge local models` to refresh the model list.")
        case "models":
            guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("Usage: agentbridge local models") }
            let settings = try service.settings().localModel
            let models = try await service.localModels(settings: settings)
            if models.isEmpty {
                print("This endpoint has no available models: \(settings.endpoint)")
                print("Start Ollama or LM Studio yourself and prepare a model in that app first; AgentBridge does not download models or start services.")
                return
            }
            for model in models {
                let context = model.contextWindowTokens.map { " · context \($0)" } ?? ""
                print("\(model.id) · \(model.name)\(context)")
            }
        case "test":
            guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("Usage: agentbridge local test") }
            let settings = try service.settings().localModel
            let ready = try await service.testLocalModelConnection(settings: settings)
            if ready {
                print("Local model connection succeeded: \(settings.model) · \(settings.endpoint)")
            } else {
                print("The local model is not ready: \(settings.endpoint). Make sure you started the local service and chose an available model.")
            }
        case "preview":
            guard arguments.count == 3 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge local preview discussion CHAT-ID|project SESSION-ID < prompt.txt")
            }
            let target = arguments[1]
            guard let id = UUID(uuidString: arguments[2]) else {
                throw AgentBridgeError.invalidInput("The preview needs a valid chat or session UUID.")
            }
            let promptLimit = target == "project" ? 256 * 1_024 : DiscussionStore.maximumTextBytes
            let prompt = try readPromptFromStandardInput(maximumBytes: promptLimit)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentBridgeError.invalidInput("The prompt cannot be empty.")
            }
            let settings = try service.settings().localModel
            let preview: ContextCompressionPreview
            switch target {
            case "discussion":
                preview = try service.previewDiscussionContext(id: id, currentPrompt: prompt, settings: settings)
            case "project":
                preview = try service.previewProjectContext(sessionID: id, currentPrompt: prompt, settings: settings)
            default:
                throw AgentBridgeError.invalidInput("The preview target must be discussion or project.")
            }
            printContextCompressionPreview(preview, settings: settings)
        default:
            throw AgentBridgeError.invalidInput("Unknown local subcommand \(action). Usage: agentbridge local settings|configure|models|test|preview …")
        }
    }

    static func localBackendName(_ backend: LocalModelBackend) -> String {
        switch backend {
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    static func printContextCompressionPreview(_ preview: ContextCompressionPreview, settings: LocalModelSettings) {
        let report = preview.report
        let estimatedTokens = Int((Double(report.sentBytes) / 2.0).rounded(.up))
        let estimatedBudget = max(0, settings.contextWindowTokens - settings.maxOutputTokens - 512)
        print("Local context preview")
        print("Bytes (original / to be sent): \(report.originalInputBytes) / \(report.sentBytes)")
        print("Input estimated from UTF-8 bytes: about \(estimatedTokens) tokens; this is not an exact tokenizer count.")
        print("Estimated input budget: about \(estimatedBudget) tokens (\(settings.maxOutputTokens) reserved for output, plus a 512-token safety margin); this is a byte-based estimate, not an exact tokenizer count.")
        print("Turns: source \(report.originalTurnCount) · recent verbatim \(report.recentVerbatimCount) · omitted \(report.omittedTurnCount) · history excerpt sources \(report.excerptSourceIDs.count)")
        if report.refusalReason != nil {
            print("Needs adjusting before it can be sent: the full current prompt, pinned notes and protected history cannot safely fit the available budget. Shorten the prompt or notes, or raise the local model's context window; no request will be sent.")
        } else if preview.requiresReview {
            print("The context needs adjusting before it can be sent; edit the prompt or change the budget settings first.")
        } else {
            print(report.compressionApplied
                ? "Applied safe, readable context compression automatically."
                : "The full context was kept; no compression was needed.")
        }
        print("Preview digest (only for checking staleness, not an approval token): \(preview.previewDigest)")
        if let compressedPrompt = preview.compressedPrompt {
            print("\n--- Context to be sent ---\n\(compressedPrompt)\n--- End of context ---")
        } else {
            print("\nNo provider prompt was assembled; sending is blocked until the context can be represented safely.")
            for section in preview.sections {
                print("\n--- \(section.title) ---")
                if !section.sourceIDs.isEmpty { print("Sources: \(section.sourceIDs.joined(separator: ", "))") }
                print(section.text)
            }
            if preview.sections.isEmpty, let refusalReason = report.refusalReason {
                print("Protected context: \(refusalReason)")
            }
        }
    }
}
