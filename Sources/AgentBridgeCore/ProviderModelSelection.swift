import Foundation

/// A model and reasoning effort for Codex or Claude. Either may be nil, which
/// means the provider CLI's own default; AgentBridge never guesses what that is.
/// A session or chat keeps the choice it was created with, like its account.
public struct ProviderModelChoice: Codable, Equatable, Hashable, Sendable {
    public let model: String?
    public let reasoningEffort: String?

    public static let cliDefault = ProviderModelChoice()

    public init(model: String? = nil, reasoningEffort: String? = nil) {
        self.model = model
        self.reasoningEffort = reasoningEffort
    }

    public var isCLIDefault: Bool { model == nil && reasoningEffort == nil }

    /// Trims the model, treats blank values as "CLI default", and checks both
    /// values against what the provider accepts.
    public func validated(for provider: AgentProvider) throws -> ProviderModelChoice {
        let model = try ProviderModelOptions.validatedModel(model)
        let effort = try ProviderModelOptions.validatedEffort(reasoningEffort, provider: provider)
        if provider == .local, model != nil || effort != nil {
            throw AgentBridgeError.invalidInput("Local models are chosen in Local Model Settings; a model or reasoning effort cannot be set here.")
        }
        return ProviderModelChoice(model: model, reasoningEffort: effort)
    }
}

public enum ProviderModelOptions {
    public static let maximumModelBytes = 128

    /// Effort levels each CLI accepts. Claude lists its levels in `claude --help`
    /// (2.1.311). Codex 0.169.0 has no help text for them, so these are the levels
    /// its bundled model catalog (`codex debug models --bundled`) offers across its
    /// listed models; a model that lacks a level makes the CLI fail the run.
    public static func effortLevels(for provider: AgentProvider) -> [String] {
        switch provider {
        case .codex: ["low", "medium", "high", "xhigh", "max", "ultra"]
        case .claude: ["low", "medium", "high", "xhigh", "max"]
        case .local: []
        }
    }

    /// A few names to start from. The field stays free text, because model names
    /// change and AgentBridge cannot reliably list what an account can use.
    public static func suggestedModels(for provider: AgentProvider) -> [String] {
        switch provider {
        case .codex: ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"]
        case .claude: ["fable", "opus", "sonnet"]
        case .local: []
        }
    }

    public static func supportsModelChoice(_ provider: AgentProvider) -> Bool {
        provider == .codex || provider == .claude
    }

    /// Returns the trimmed model name, or nil when it is blank. The name goes to
    /// the CLI as its own argument, so it must not look like an option.
    public static func validatedModel(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isValidModelName(trimmed) else {
            throw AgentBridgeError.invalidInput("A model name must be at most 128 bytes of letters, digits and . - _ : / @ [ ], and must not start with -.")
        }
        return trimmed
    }

    public static func isValidModelName(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= maximumModelBytes, !value.hasPrefix("-") else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a"..."z", "A"..."Z", "0"..."9", ".", "-", "_", ":", "/", "@", "[", "]": true
            default: false
            }
        }
    }

    /// Returns the effort, or nil when it is blank; anything else must be one of
    /// the provider's levels.
    public static func validatedEffort(_ value: String?, provider: AgentProvider) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let levels = effortLevels(for: provider)
        guard levels.contains(trimmed) else {
            let allowed = levels.isEmpty ? "none" : levels.joined(separator: ", ")
            throw AgentBridgeError.invalidInput("Reasoning effort \(trimmed) is not available for \(provider.rawValue). Choose one of: \(allowed).")
        }
        return trimmed
    }

    /// The short label shown beside a session's provider and account, such as
    /// "gpt-x · high". Without a model it says "CLI default" rather than naming
    /// one, because the CLI decides.
    public static func label(model: String?, reasoningEffort: String?, cliDefaultText: String = "CLI default") -> String {
        let modelPart = model ?? cliDefaultText
        guard let reasoningEffort else { return modelPart }
        return "\(modelPart) · \(reasoningEffort)"
    }
}

public extension SessionRecord {
    var modelChoice: ProviderModelChoice { ProviderModelChoice(model: model, reasoningEffort: reasoningEffort) }
}

public extension DiscussionRecord {
    var modelChoice: ProviderModelChoice { ProviderModelChoice(model: model, reasoningEffort: reasoningEffort) }
}

public extension AutonomousRoleBinding {
    var modelChoice: ProviderModelChoice { ProviderModelChoice(model: model, reasoningEffort: reasoningEffort) }
}
