import Darwin
import Foundation
import AgentBridgeCore

/// The local model helper and the guided Ollama setup from the command line.
extension AgentBridgeCLI {
    private static let helperTaskFlags: [(flag: String, task: LocalHelperTask, name: String)] = [
        ("--commit-text", .commitText, "Commit and PR text"),
        ("--explain-failure", .explainFailure, "Explain a failed verification"),
        ("--handoff", .handoffSummary, "Handoff summary"),
        ("--change-summary", .changeSummary, "Summarize changes")
    ]

    /// `local helper show|on|off [task flags]`: with task flags, on and off switch
    /// those tasks; without them, the master switch.
    static func localHelperCommand(_ arguments: [String], service: BridgeService) async throws {
        let usage = "Usage: agentbridge local helper show|on|off [--commit-text] [--explain-failure] [--handoff] [--change-summary]"
        guard arguments.count >= 2 else { throw AgentBridgeError.invalidInput(usage) }
        let action = arguments[1]
        var tasks: [LocalHelperTask] = []
        for flag in arguments.dropFirst(2) {
            guard let task = helperTaskFlags.first(where: { $0.flag == flag })?.task else {
                throw AgentBridgeError.invalidInput("Unknown local helper option \(flag). \(usage)")
            }
            if !tasks.contains(task) { tasks.append(task) }
        }
        switch action {
        case "show":
            guard tasks.isEmpty else { throw AgentBridgeError.invalidInput(usage) }
        case "on", "off":
            let on = action == "on"
            if tasks.isEmpty {
                try await service.setLocalHelperEnabled(on)
            } else {
                for task in tasks { try service.setLocalHelperTask(task, on: on) }
            }
        default:
            throw AgentBridgeError.invalidInput(usage)
        }
        let helper = try service.localHelperSettings()
        print("Local model helper: \(helper.enabled ? "on" : "off")")
        for item in helperTaskFlags {
            print("  \(item.name) (\(item.flag)): \(helper.isTaskOn(item.task) ? "on" : "off")")
        }
        print("The helper sends only to the configured loopback model, counts against the Local limits, and never applies, saves or sends what it drafts. Turning a task on is the consent for its requests; shared-memory consent is not needed because nothing is written to shared memory.")
    }

    static func localSetupCheck(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("Usage: agentbridge local setup-check") }
        let status = await service.ollamaSetupStatus()
        print("Ollama command: \(status.executablePath ?? "not found")")
        print("Ollama app: \(status.appBundlePath ?? "not found")")
        print("Server at \(status.endpoint): \(status.serverRunning ? "running" : "not answering")")
        if status.serverRunning {
            print("Installed models: \(status.installedModels.isEmpty ? "none" : status.installedModels.joined(separator: ", "))")
        }
        let recommendation = status.recommendation
        print("This Mac has \(status.physicalMemoryGiB) GB of memory. Recommended code model: \(recommendation.model) (about \(String(format: "%.1f", recommendation.approximateDownloadGB)) GB download). Any other model name works too.")
        switch status.state {
        case .notInstalled:
            print("Next: install Ollama from \(OllamaSetup.downloadPageURL.absoluteString), then run this check again.")
        case .installedNotRunning:
            print(status.appBundlePath != nil
                ? "Next: open the Ollama app, or run `ollama serve` in Terminal."
                : "Next: run `ollama serve` in Terminal.")
        case .running:
            print("Next: run `agentbridge local pull \(recommendation.model) --confirm` to download the model, or choose one already installed with `agentbridge local configure`.")
        }
    }

    /// Downloads a model only with `--confirm`, then saves it as the Local model
    /// and runs the connection test.
    static func localPull(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count == 3, arguments[2] == "--confirm" else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge local pull MODEL --confirm")
        }
        let model = arguments[1]
        _ = try OllamaSetup.pullArguments(model: model)
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        print("Running `ollama pull \(model)`. Press Control-C to cancel.")
        try await service.pullOllamaModel(model, cancellation: cancellation) { progress in
            let percent = progress.percent.map { " \($0)%" } ?? ""
            FileHandle.standardError.write(Data("• \(progress.status)\(percent)\n".utf8))
        }
        var settings = try service.settings()
        if settings.localModel.backend != .ollama {
            settings.localModel.backend = .ollama
            settings.localModel.endpoint = LocalModelSettings().endpoint
        }
        settings.localModel.model = model
        try service.saveSettings(settings)
        print("Downloaded \(model) and saved it as the Local model (Ollama, \(settings.localModel.endpoint)).")
        _ = try await service.testLocalModelConnection(settings: settings.localModel)
        print("Local model connection succeeded: \(model) · \(settings.localModel.endpoint)")
    }

    // MARK: Changes

    /// `changes explain SESSION-ID [--exit-code N] [--command LABEL] [--preview] < output.txt`.
    /// The failed verification's output comes from standard input; AgentBridge
    /// does not keep verification output.
    static func changesExplain(_ arguments: [String], service: BridgeService) async throws {
        let usage = "Usage: agentbridge changes explain SESSION-ID [--exit-code N] [--command LABEL] [--preview] < verification-output.txt"
        guard arguments.count >= 2, let sessionID = UUID(uuidString: arguments[1]) else {
            throw AgentBridgeError.invalidInput(usage)
        }
        var exitCode: Int32?
        var label = ".codex/ci.sh"
        var previewOnly = false
        var index = 2
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            switch option {
            case "--preview": previewOnly = true
            case "--exit-code":
                let value = try nextOptionValue(option, arguments: arguments, index: &index)
                guard let parsed = Int32(value) else { throw AgentBridgeError.invalidInput("--exit-code needs an integer.") }
                exitCode = parsed
            case "--command":
                label = try nextOptionValue(option, arguments: arguments, index: &index)
            default:
                throw AgentBridgeError.invalidInput("Unknown changes explain option \(option). \(usage)")
            }
        }
        let output = try readBoundedStandardInput(maximumBytes: 2 * 1_024 * 1_024, label: "Verification output")
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("Pipe the failed verification's output to standard input, for example `agentbridge changes verify SESSION-ID 2>&1 | agentbridge changes explain SESSION-ID --exit-code 1`.")
        }
        let failure = LocalHelperVerificationFailure(commandLabel: label, exitCode: exitCode, output: output)
        if previewOnly {
            printLocalHelperPreview(try await service.localHelperFailurePreview(sessionID: sessionID, failure: failure))
            return
        }
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        let outcome = try await service.explainVerificationFailureWithLocalModel(sessionID: sessionID, failure: failure, cancellation: cancellation)
        printLocalHelperText(outcome, heading: "The local model's explanation (a draft; not saved):")
    }

    /// `changes summarize SESSION-ID [--preview]`.
    static func changesSummarize(_ arguments: [String], service: BridgeService) async throws {
        guard (arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--preview")),
              let sessionID = UUID(uuidString: arguments[1]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge changes summarize SESSION-ID [--preview]")
        }
        if arguments.count == 3 {
            printLocalHelperPreview(try await service.localHelperChangeSummaryPreview(sessionID: sessionID))
            return
        }
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        let outcome = try await service.summarizeChangesWithLocalModel(sessionID: sessionID, cancellation: cancellation)
        printLocalHelperText(outcome, heading: "The local model's summary (its opinion, not a verification; not saved):")
    }

    private static func printLocalHelperText(_ outcome: LocalHelperOutcome<String>, heading: String) {
        for note in outcome.preview?.truncationNotes ?? [] { print(note) }
        guard let text = outcome.draft else {
            print("No answer. \(outcome.fallbackReason ?? "")")
            return
        }
        print(heading)
        print(text)
    }

    static func printLocalHelperPreview(_ preview: LocalHelperPreview) {
        print("What would be sent to the local model (nothing was sent):")
        print("Bytes: \(preview.promptBytes) of a \(preview.budgetBytes)-byte input budget (estimated from the context window; not a tokenizer count).")
        for part in preview.parts { print("  \(part.label): \(part.bytes) bytes") }
        if !preview.files.isEmpty {
            print("Files (\(preview.files.count)):")
            for file in preview.files {
                let sent = file.sentPatchBytes == 0 ? "diff not sent" : "\(file.sentPatchBytes) of \(file.patchBytes) diff bytes sent"
                print("  \(file.path) · \(file.status) · \(file.isBinary ? "binary" : sent)")
            }
        }
        for note in preview.truncationNotes { print(note) }
        print("\n--- Text to be sent ---\n\(preview.prompt)--- End of text ---")
    }
}
