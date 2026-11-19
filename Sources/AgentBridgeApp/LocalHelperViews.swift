import AgentBridgeCore
import SwiftUI

/// The helper's master switch and task switches, under the Local model settings.
struct LocalHelperSettingsSection: View {
    @Bindable var model: AppModel

    private var helper: LocalHelperModel { model.localHelper }

    private static let tasks: [(task: LocalHelperTask, title: String)] = [
        (.commitText, "Commit and pull request text"),
        (.explainFailure, "Explain a failed verification"),
        (.handoffSummary, "Handoff summary"),
        (.changeSummary, "Summarize changes")
    ]

    var body: some View {
        GroupBox(model.localized("Local model helper")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(model.localized("Local model helper"), isOn: Binding(
                    get: { model.settings.localHelper.enabled },
                    set: { helper.setEnabled($0) }
                ))
                .disabled(helper.isChangingSwitch)
                Text(model.localized("Lets the Local model above draft text in Codex and Claude work. Every result is a draft: nothing is applied, saved or sent. Turning the helper on runs the connection test on the saved Local settings."))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Self.tasks, id: \.task) { item in
                    Toggle(model.localized(item.title), isOn: Binding(
                        get: { model.settings.localHelper.isTaskOn(item.task) },
                        set: { helper.setTask(item.task, on: $0) }
                    ))
                    .font(.caption)
                    .padding(.leading, 14)
                }
                Text(model.localized("Turning on a task is the consent for its requests. They go only to the loopback model and count against the Local limits. They do not need shared-memory consent, because nothing they send or return is written to shared memory, project memory, handoff files or provider history."))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if helper.isChangingSwitch {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(model.localized("Testing the local model connection…")).font(.caption2)
                    }
                }
                if let error = helper.switchError {
                    Label(model.localized(error), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Finds Ollama, opens it, and downloads a model, each only from a click.
struct OllamaSetupSection: View {
    @Bindable var model: AppModel

    private var helper: LocalHelperModel { model.localHelper }

    var body: some View {
        DisclosureGroup(model.localized("Guided Ollama setup")) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Button(model.localized("Check Ollama setup")) { helper.checkSetup() }
                        .disabled(helper.isCheckingSetup || helper.isPulling)
                    if helper.isCheckingSetup { ProgressView().controlSize(.small) }
                }
                if let status = helper.setupStatus {
                    statusView(status)
                } else {
                    Text(model.localized("Checks whether Ollama is installed and whether its server answers at the loopback endpoint. Nothing is installed, started or downloaded without a click."))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = helper.setupMessage {
                    Text(model.localized(message))
                        .font(.caption2).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func statusView(_ status: OllamaSetupStatus) -> some View {
        switch status.state {
        case .notInstalled:
            Label(model.localized("Ollama is not installed."), systemImage: "xmark.circle")
            Button(model.localized("Open the Ollama download page")) { helper.openDownloadPage() }
            Text(model.localized("Install Ollama from its official page yourself, then check again."))
                .font(.caption2).foregroundStyle(.secondary)
        case .installedNotRunning:
            Label(model.localized("Ollama is installed but its server does not answer."), systemImage: "pause.circle")
            if status.appBundlePath != nil {
                Button(model.localized("Start Ollama")) { helper.startOllama() }
                Text(model.localized("Opens the Ollama app, which runs on its own, not inside AgentBridge."))
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text(model.localized("Start the server in Terminal with this command, then check again:"))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(verbatim: "ollama serve").font(.caption.monospaced()).textSelection(.enabled)
            }
        case .running:
            Label(model.localizedFormat("Ollama is running at %@.", status.endpoint), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            if !status.installedModels.isEmpty {
                Text(model.localizedFormat("Installed models: %@", status.installedModels.joined(separator: ", ")))
                    .font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            pullControls(status)
        }
    }

    @ViewBuilder
    private func pullControls(_ status: OllamaSetupStatus) -> some View {
        Text(model.localizedFormat(
            "This Mac has %@ GB of memory. Recommended code model: %@ (about %@ GB to download). You can type any other model name.",
            String(status.physicalMemoryGiB),
            status.recommendation.model,
            String(format: "%.1f", status.recommendation.approximateDownloadGB)
        ))
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
            TextField(model.localized("Model name"), text: Bindable(helper).pullModelName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
                .disabled(helper.isPulling)
            if helper.isPulling {
                Button(model.localized("Cancel download")) { helper.cancelPull() }
            } else {
                Button(model.localized("Download model")) { helper.pullModel() }
                    .disabled(helper.pullModelName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        if helper.isPulling {
            if let percent = helper.pullProgress?.percent {
                ProgressView(value: Double(percent), total: 100)
            } else {
                ProgressView().controlSize(.small)
            }
            if let progress = helper.pullProgress {
                Text(verbatim: progress.status).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        Text(model.localized("Runs `ollama pull` with this name. Afterwards the Local settings use Ollama and this model, and the connection test runs."))
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// What a helper request would send, loaded only when expanded. Loading sends nothing.
struct LocalHelperPreviewDisclosure: View {
    @Bindable var model: AppModel
    let task: LocalHelperTask
    let session: SessionRecord
    @State private var isExpanded = false
    @State private var preview: LocalHelperPreview?
    @State private var error: String?

    var body: some View {
        DisclosureGroup(model.localized("What will be sent"), isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 4) {
                if let preview {
                    content(preview)
                } else if let error {
                    Text(model.localized(error)).font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption2)
        .onChange(of: isExpanded) { _, expanded in
            guard expanded else { return }
            preview = nil
            error = nil
            Task { @MainActor in
                do { preview = try await model.localHelper.preview(task, session: session) }
                catch { self.error = error.localizedDescription }
            }
        }
    }

    @ViewBuilder
    private func content(_ preview: LocalHelperPreview) -> some View {
        Text(model.localizedFormat("%@ of %@ bytes of the input budget, estimated from the context window; not a tokenizer count.", String(preview.promptBytes), String(preview.budgetBytes)))
            .foregroundStyle(.secondary)
        ForEach(preview.parts, id: \.label) { part in
            Text(verbatim: "\(model.localized(part.label)): \(part.bytes) B").foregroundStyle(.secondary)
        }
        ForEach(preview.files, id: \.path) { file in
            Text(verbatim: "\(file.path) · \(file.isBinary ? model.localized("binary") : model.localizedFormat("%@ of %@ diff bytes", String(file.sentPatchBytes), String(file.patchBytes)))")
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
        }
        ForEach(preview.truncationNotes, id: \.self) { note in
            Label(model.localized(note), systemImage: "scissors").foregroundStyle(.orange)
        }
        ScrollView {
            Text(verbatim: preview.prompt)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 160)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
    }
}

/// The small notes after a request: why the existing text was kept, what was left out.
struct LocalHelperNotes: View {
    @Bindable var model: AppModel
    let task: LocalHelperTask

    var body: some View {
        ForEach(model.localHelper.notes[task] ?? [], id: \.self) { note in
            Label(model.localized(note), systemImage: "info.circle")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The button that starts a task, with a progress indicator and Cancel while it runs.
struct LocalHelperRunButton: View {
    @Bindable var model: AppModel
    let task: LocalHelperTask
    let title: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(model.localized(title), action: action)
                .disabled(disabled || model.localHelper.isRunning(task))
            if model.localHelper.isRunning(task) {
                ProgressView().controlSize(.small)
                Button(model.localized("Cancel")) { model.localHelper.cancel(task) }
            }
        }
    }
}
