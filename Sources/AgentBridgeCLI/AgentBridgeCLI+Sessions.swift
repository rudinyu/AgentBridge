import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func settingsCommand(_ arguments: [String], service: BridgeService) throws {
        guard let subcommand = arguments.first else { throw AgentBridgeError.invalidInput("Specify settings show, usage, binary or model.") }
        switch subcommand {
        case "show":
            let settings = try service.settings()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            print(String(decoding: data, as: UTF8.self))
        case "usage":
            guard arguments.count == 2, let mode = UsageMode(rawValue: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge settings usage subscription|api")
            }
            var settings = try service.settings()
            settings.usageMode = mode
            try service.saveSettings(settings)
            print("Usage mode set: \(mode.rawValue). API runs still need a one-run budget and explicit confirmation.")
        case "binary":
            guard arguments.count == 3,
                  let provider = AgentProvider(rawValue: arguments[1]),
                  provider != .local else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge settings binary codex|claude /absolute/path/to/cli|auto")
            }
            var settings = try service.settings()
            let path = arguments[2] == "auto" ? nil : arguments[2]
            settings.setBinaryPath(path, for: provider)
            try service.saveSettings(settings)
            print("Updated the \(provider.rawValue) CLI path.")
        case "model":
            // Defaults for new sessions and chats only; existing ones keep theirs.
            guard arguments.count >= 2,
                  let provider = AgentProvider(rawValue: arguments[1]),
                  provider != .local else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge settings model codex|claude [--model NAME] [--effort LEVEL]")
            }
            var model: String?
            var effort: String?
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                switch option {
                case "--model": model = try nextOptionValue(option, arguments: arguments, index: &index)
                case "--effort": effort = try nextOptionValue(option, arguments: arguments, index: &index)
                default: throw AgentBridgeError.invalidInput("Usage: agentbridge settings model codex|claude [--model NAME] [--effort LEVEL]")
                }
            }
            var settings = try service.settings()
            settings.setModelDefaults(try ProviderModelChoice(model: model, reasoningEffort: effort).validated(for: provider), for: provider)
            try service.saveSettings(settings)
            let saved = try service.settings().modelDefaults(for: provider)
            print("New \(provider.rawValue) sessions and chats will use: \(modelLabel(model: saved.model, reasoningEffort: saved.reasoningEffort)). Existing sessions keep their own.")
        default:
            throw AgentBridgeError.invalidInput("Unknown settings subcommand.")
        }
    }

    static func listSessions(service: BridgeService) throws {
        let sessions = try service.sessions()
        if sessions.isEmpty { print("No Sessions Yet."); return }
        for session in sessions {
            let mode: String
            switch session.policy.accessMode {
            case .readOnly: mode = "read-only"
            case .interactiveManualApproval: mode = "interactive, manual approval"
            case .isolatedChanges: mode = "isolated changes (plan approval)"
            }
            let model = session.provider == .local ? "" : "  \(modelLabel(model: session.model, reasoningEffort: session.reasoningEffort))"
            print("\(session.id.uuidString.lowercased())  \(session.provider.rawValue)  \(mode)  \(session.status.rawValue)  \(session.snapshotCommit.prefix(12))\(model)")
            print("  \(session.workspacePath)")
        }
    }

    static func sessionCommand(_ arguments: [String], service: BridgeService) async throws {
        if arguments.first == "remove" { return try await removeSessionCommand(Array(arguments.dropFirst()), service: service) }
        guard arguments.first == "create" else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge session create --provider codex|claude|local --repo PATH [--interactive|--changes] [--model NAME] [--effort LEVEL]\n       agentbridge session create --like SESSION-ID [--model NAME] [--effort LEVEL] [--latest-commit] [--profile PROFILE-ID]\n       agentbridge session remove SESSION-ID [--confirm]")
        }
        if arguments.contains("--like") { return try await createSessionLikeCommand(Array(arguments.dropFirst()), service: service) }
        var provider: AgentProvider?
        var repoPath: String?
        var interactive = false
        var isolatedChanges = false
        var model: String?
        var effort: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--provider":
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("--provider needs a value.") }
                provider = AgentProvider(rawValue: arguments[index])
            case "--repo":
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("--repo needs a value.") }
                repoPath = arguments[index]
            case "--interactive":
                interactive = true
            case "--changes":
                isolatedChanges = true
            case "--model":
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("--model needs a value.") }
                model = arguments[index]
            case "--effort":
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("--effort needs a value.") }
                effort = arguments[index]
            default:
                throw AgentBridgeError.invalidInput("Unknown session create option \(arguments[index]).")
            }
            index += 1
        }
        guard let provider, let repoPath else { throw AgentBridgeError.invalidInput("Specify --provider and --repo.") }
        guard !(interactive && isolatedChanges) else { throw AgentBridgeError.invalidInput("--interactive and --changes are mutually exclusive.") }
        if provider == .local && (interactive || isolatedChanges) {
            throw AgentBridgeError.invalidInput("Local project chat only supports read-only sessions.")
        }
        if provider != .local, isolatedChanges, try service.settings().usageMode != .subscription {
            throw AgentBridgeError.sessionMismatch("Isolated changes support only the official CLI subscription sign-in; Claude API supports read-only sessions only.")
        }
        let access: AccessMode = isolatedChanges ? .isolatedChanges : (interactive ? .interactiveManualApproval : .readOnly)
        let session = try await service.createSession(
            sourcePath: repoPath,
            provider: provider,
            accessMode: access,
            modelChoice: requestedModelChoice(model: model, effort: effort, provider: provider, service: service)
        )
        printCreatedSession(session)
    }

    /// Prints a new session the way `session create` always has.
    static func printCreatedSession(_ session: SessionRecord) {
        let provider = session.provider
        print("Created an isolated session: \(session.id.uuidString.lowercased())")
        if provider != .local {
            print("Model: \(modelLabel(model: session.model, reasoningEffort: session.reasoningEffort))")
        }
        print("Workspace: \(session.workspacePath)")
        print("Pinned commit: \(session.snapshotCommit)")
        if session.sourceWasDirty { print("The source has uncommitted changes; they were not copied into the workspace.") }
        if session.policy.accessMode == .interactiveManualApproval {
            let profileID = session.accountProfileID?.uuidString.lowercased() ?? AccountProfile.defaultID(for: provider).uuidString.lowercased()
            print("Interactive mode must run in Terminal: agentbridge interactive \(session.id.uuidString.lowercased()) --profile \(profileID)")
        }
        if session.policy.accessMode == .isolatedChanges {
            print("Created an isolated changes session. Read-only remains the default; nothing is written until you create and explicitly approve a work plan.")
        }
    }

    /// `session create --like SESSION-ID`: a new session with the source's
    /// provider, repository, access mode, account and model, unless overridden.
    static func createSessionLikeCommand(_ arguments: [String], service: BridgeService) async throws {
        let parsed = try SessionLikeArguments.parse(arguments)
        // A missing --model or --effort keeps the source's; an empty value means
        // the CLI default, as with `session create`.
        let source = try service.sessionCopySource(parsed.sourceSessionID)
        let result = try await service.createSession(
            like: parsed.sourceSessionID,
            modelChoice: parsed.modelChoice(source: source),
            accountProfileID: parsed.profileID,
            commit: parsed.commit
        )
        printCreatedSession(result.session)
        if result.copiedChangePlan != nil {
            print("Copied the change plan; approve it again before running.")
        }
        if let error = result.changePlanCopyError {
            throw AgentBridgeError.invalidChangePlan(error)
        }
    }

    /// Shows what removing the session deletes; with `--confirm`, removes it.
    /// When removal may lose work, `--discard-unsaved-work` is needed as well, so
    /// a script that passes `--confirm` cannot delete work nobody reviewed.
    static func removeSessionCommand(_ arguments: [String], service: BridgeService) async throws {
        let usage = "Usage: agentbridge session remove SESSION-ID [--confirm [--discard-unsaved-work]]"
        guard let first = arguments.first, let sessionID = UUID(uuidString: first) else {
            throw AgentBridgeError.invalidInput(usage)
        }
        let options = Set(arguments.dropFirst())
        guard options.isSubset(of: ["--confirm", "--discard-unsaved-work"]), options.count == arguments.count - 1,
              !options.contains("--discard-unsaved-work") || options.contains("--confirm") else {
            throw AgentBridgeError.invalidInput(usage)
        }
        let preview = try await service.sessionRemovalPreview(sessionID: sessionID)
        print("Workspace to delete: \(preview.workspacePath)")
        if !preview.workspaceExists { print("The workspace folder no longer exists.") }
        for problem in preview.inspectionProblems { print(problem) }
        if !preview.unsavedReferences.isEmpty {
            print("Branches, tags, notes or stash entries whose commits exist only in this workspace: \(preview.unsavedReferences.joined(separator: ", "))")
        }
        func list(_ title: String, _ paths: [String], total: Int) {
            guard total > 0 else { return }
            print("\(title) (\(total)):")
            for path in paths { print("  \(path)") }
            if total > paths.count { print("  …and \(total - paths.count) more.") }
        }
        list("Files that differ from what the source repository has", preview.changedPaths, total: preview.changedPathCount)
        list("Ignored files and folders, which Git does not keep", preview.ignoredPaths, total: preview.ignoredPathCount)
        print(preview.mayLoseWork
            ? "Anything listed here is lost. Removal cannot be undone."
            : "Nothing in the workspace is missing from the source repository.")
        guard options.contains("--confirm") else {
            print("Nothing was removed. Run again with --confirm to remove the session.")
            return
        }
        guard !preview.mayLoseWork || options.contains("--discard-unsaved-work") else {
            print("Nothing was removed. To delete the work listed above, add --discard-unsaved-work.")
            return
        }
        try await service.removeSession(sessionID: sessionID, reviewed: preview)
        print("Removed the session and deleted its isolated workspace. Its audit events and usage records are kept.")
    }

    static func runCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let first = arguments.first, let sessionID = UUID(uuidString: first) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge run SESSION-ID [--api-budget USD --confirm-api-spend --api-key-env ANTHROPIC_API_KEY]; the prompt is read from standard input.")
        }
        var budget: Double?
        var confirmed = false
        var keyEnvironmentName: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--api-budget":
                index += 1
                guard index < arguments.count, let value = Double(arguments[index]), value.isFinite else {
                    throw AgentBridgeError.invalidInput("--api-budget needs a valid amount.")
                }
                budget = value
            case "--confirm-api-spend":
                confirmed = true
            case "--api-key-env":
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("--api-key-env needs an environment variable name.") }
                keyEnvironmentName = arguments[index]
            default:
                throw AgentBridgeError.invalidInput("Unknown run option \(arguments[index]).")
            }
            index += 1
        }
        let apiRequest: APIUsageRequest?
        if budget != nil || confirmed || keyEnvironmentName != nil {
            guard let budget, confirmed, keyEnvironmentName == "ANTHROPIC_API_KEY" else {
                throw AgentBridgeError.invalidInput("API mode needs --api-budget, --confirm-api-spend and --api-key-env ANTHROPIC_API_KEY together.")
            }
            guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
                throw AgentBridgeError.invalidInput("ANTHROPIC_API_KEY was not found; the key value is never passed as a command-line argument.")
            }
            apiRequest = APIUsageRequest(requestedBudgetUSD: budget, explicitlyAuthorized: true, apiKey: key)
            FileHandle.standardError.write(Data(String(format: "• Reserves US$%.2f (twice this run's budget) before launch; the difference is released when the actual cost is settled.\n", budget * 2).utf8))
        } else {
            apiRequest = nil
        }
        let prompt = try readPromptFromStandardInput(maximumBytes: 256_000)
        let cancellation = CancellationFlag()
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global(qos: .userInitiated))
        interrupt.setEventHandler { cancellation.cancel() }
        interrupt.resume()
        defer { interrupt.cancel() }
        let output = try await service.runReadOnly(sessionID: sessionID, prompt: prompt, apiRequest: apiRequest, cancellation: cancellation) { progress in
            FileHandle.standardError.write(Data("• \(progress)\n".utf8))
        }
        FileHandle.standardOutput.write(Data((output.text + "\n").utf8))
        if apiRequest != nil {
            if let cost = output.actualCostUSD {
                FileHandle.standardError.write(Data(String(format: "Provider-reported cost: US$%.4f\n", cost).utf8))
            } else {
                FileHandle.standardError.write(Data("The provider did not report an actual cost; the reserved budget is not returned.\n".utf8))
            }
        }
    }

    static func interactiveCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let first = arguments.first, let sessionID = UUID(uuidString: first) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge interactive SESSION-ID [--profile PROFILE-ID]")
        }
        var profileID: UUID?
        var index = 1
        while index < arguments.count {
            guard arguments[index] == "--profile", index + 1 < arguments.count,
                  let parsedID = UUID(uuidString: arguments[index + 1]), profileID == nil else {
                throw AgentBridgeError.invalidInput("Interactive mode accepts exactly one valid --profile PROFILE-ID.")
            }
            profileID = parsedID
            index += 2
        }
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        _ = try await service.runInteractive(sessionID: sessionID, profileID: profileID, cancellation: cancellation)
    }

    /// In the user's own terminal, `usage-tui` runs behind `UsageTerminalProxy` so the
    /// limits it shows still reach the App's usage card. The App reads its embedded
    /// terminal itself and passes `--in-app`; the proxy's inner run passes
    /// `--attached-terminal`. Either runs the TUI directly.
    static func usageTUICommand(_ arguments: [String], service: BridgeService) async throws {
        let mode = arguments.count == 5 ? arguments[4] : nil
        guard arguments.count == 4 || mode == "--in-app" || mode == UsageTerminalProxy.attachedTerminalFlag,
              arguments[0] == "--provider",
              let provider = AgentProvider(rawValue: arguments[1]),
              provider != .local,
              arguments[2] == "--profile",
              let profileID = UUID(uuidString: arguments[3]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge usage-tui --provider codex|claude --profile PROFILE-ID")
        }
        if mode == nil {
            let profile = try service.accountProfile(id: profileID)
            guard profile.provider == provider else { throw AccountProfileError.providerMismatch(profileID, provider) }
            let status = try UsageTerminalProxy.run(provider: provider, profile: profile, service: service)
            if status != 0 { exit(status) }
            return
        }
        if mode == UsageTerminalProxy.attachedTerminalFlag {
            try UsageTerminalProxy.attachToTerminal()
        }
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        _ = try await service.runUsageTUI(provider: provider, profileID: profileID, cancellation: cancellation)
    }

    /// Convert terminal and app shutdown signals into a cooperative runner
    /// cancellation so SafeProcessRunner can terminate the provider's process
    /// group and wait for its bounded cleanup path.
    static func makeCancellationSignalSources(_ cancellation: CancellationFlag) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM, SIGHUP].map { signalNumber in
            _ = signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { cancellation.cancel() }
            source.resume()
            return source
        }
    }

    static func cancelCommand(_ arguments: [String], service: BridgeService) throws {
        guard arguments.count == 1, let sessionID = UUID(uuidString: arguments[0]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge cancel SESSION-ID")
        }
        try service.cancel(sessionID: sessionID)
        print("Cancellation requested; the running process will exit once it receives the signal.")
    }

    static func showEvents(_ arguments: [String], service: BridgeService) throws {
        guard arguments.count == 1, let sessionID = UUID(uuidString: arguments[0]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge events SESSION-ID")
        }
        for event in try service.events(sessionID: sessionID) {
            let formatter = ISO8601DateFormatter()
            print("\(formatter.string(from: event.timestamp)) [\(event.kind)] \(event.message)")
        }
    }
}
