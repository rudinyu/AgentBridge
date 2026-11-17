import AgentBridgeCore
import SwiftUI

/// What the App shows for a Codex or Claude model and reasoning effort.
enum ModelChoicePresentation {
    /// "gpt-x · high", or "CLI default" when nothing was chosen. The CLI picks its
    /// default model itself, so the App never names one.
    static func label(model: String?, reasoningEffort: String?, language: AppLanguage) -> String {
        ProviderModelOptions.label(
            model: model,
            reasoningEffort: reasoningEffort,
            cliDefaultText: AppLocalization.display("CLI default", language: language)
        )
    }

    /// The effort picker's choices: "" stands for the CLI default and comes first.
    static func effortChoices(for provider: AgentProvider) -> [String] {
        [""] + ProviderModelOptions.effortLevels(for: provider)
    }

    /// Keeps what the user typed, apart from treating a blank field as no choice;
    /// the service trims and checks the name when the session is created.
    static func choice(_ current: ProviderModelChoice, model text: String) -> ProviderModelChoice {
        let model = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
        return ProviderModelChoice(model: model, reasoningEffort: current.reasoningEffort)
    }

    static func choice(_ current: ProviderModelChoice, effort: String) -> ProviderModelChoice {
        ProviderModelChoice(model: current.model, reasoningEffort: effort.isEmpty ? nil : effort)
    }
}

/// A free-text model field with a few suggestions, and an effort picker that
/// starts with "CLI default".
struct ModelChoiceFields: View {
    let model: AppModel
    let provider: AgentProvider
    @Binding var choice: ProviderModelChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Model", text: Binding(
                    get: { choice.model ?? "" },
                    set: { choice = ModelChoicePresentation.choice(choice, model: $0) }
                ), prompt: Text("CLI default"))
                .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(ProviderModelOptions.suggestedModels(for: provider), id: \.self) { name in
                        Button(name) { choice = ModelChoicePresentation.choice(choice, model: name) }
                    }
                    Divider()
                    Button("Use the CLI default model") { choice = ModelChoicePresentation.choice(choice, model: "") }
                } label: {
                    Image(systemName: "list.bullet")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(model.localized("Suggested model names. Any name the CLI accepts can be typed."))
            }
            Picker("Reasoning effort", selection: Binding(
                get: { choice.reasoningEffort ?? "" },
                set: { choice = ModelChoicePresentation.choice(choice, effort: $0) }
            )) {
                ForEach(ModelChoicePresentation.effortChoices(for: provider), id: \.self) { level in
                    if level.isEmpty {
                        Text("CLI default").tag(level)
                    } else {
                        Text(verbatim: level).tag(level)
                    }
                }
            }
        }
        .font(.caption)
    }
}
