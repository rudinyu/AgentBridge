import AgentBridgeCore
import SwiftUI

/// Asks for the Skill ID, name and summary after a SKILL.md was chosen. The
/// fields start from the file (see `SkillImportDraft.prefill`) and stay editable.
struct SkillImportSheet: View {
    @Bindable var model: AppModel
    @State var draft: SkillImportDraft
    var onImported: (ActiveSkillSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Skill")
                .font(.title3.weight(.semibold))
            Text(draft.fileURL.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Form {
                TextField("Skill ID", text: $draft.skillID)
                TextField("Skill name", text: $draft.name)
                TextField("Summary (optional)", text: $draft.summary)
            }
            .textFieldStyle(.roundedBorder)
            Text("Skill imports snapshot only SKILL.md instruction text, capped at 64 KiB. Referenced scripts, hooks, installers, and dependencies are never run.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let localError {
                Label(model.localized(localError), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import") { importSkill() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed(draft.skillID).isEmpty || trimmed(draft.name).isEmpty || !model.canStartAutonomousWorkflow)
            }
        }
        .padding(18)
        .frame(width: 520)
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func importSkill() {
        let url = draft.fileURL
        do {
            let id = trimmed(draft.skillID)
            let name = trimmed(draft.name)
            guard !id.isEmpty, !name.isEmpty else {
                throw AgentBridgeError.invalidInput("Enter a Skill ID and display name before importing.")
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let descriptor = try ExtensionDescriptor(
                id: id,
                kind: .skill,
                name: name,
                version: "1",
                summary: trimmed(draft.summary)
            )
            let snapshot = try model.extensions.importSkillRuntime(descriptor: descriptor, sourceReference: url.path, skillFileURL: url)
            onImported(snapshot)
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }
}
