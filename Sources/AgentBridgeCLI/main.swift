import Darwin
import Foundation
import AgentBridgeCore

@main
enum AgentBridgeCLI {
    private static let version = "0.11.0"

    static func main() async {
        do {
            try await dispatch(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("Error: \(OutputRedactor.redact(error.localizedDescription))\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func dispatch(_ arguments: [String]) async throws {
        guard let command = arguments.first else { printHelp(); return }
        if ["help", "--help", "-h"].contains(command) { printHelp(); return }
        if command == "version" || command == "--version" { print("AgentBridge \(version)"); return }
        if command == "mcp-proxy" || command == "mac-control-proxy" {
            try await internalMCPProxyCommand(Array(arguments.dropFirst()))
            return
        }
        if command == "chat" &&
            (arguments.count == 1 || (arguments.count == 2 && ["help", "--help", "-h"].contains(arguments[1]))) {
            printChatHelp()
            return
        }
        if command == "workspace" {
            try await workspaceCommand(Array(arguments.dropFirst()))
            return
        }

        _ = try RuntimePaths.requireWorkspaceRoot()
        let store = try RuntimePaths.makeAuditStore()
        let service = try BridgeService(store: store)

        switch command {
        case "doctor":
            try await doctor(service: service)
        case "settings":
            try settingsCommand(Array(arguments.dropFirst()), service: service)
        case "local":
            try await localModelCommand(Array(arguments.dropFirst()), service: service)
        case "profiles":
            try profilesCommand(Array(arguments.dropFirst()), service: service)
        case "profile-login":
            try await profileLoginCommand(Array(arguments.dropFirst()), service: service)
        case "memory":
            try memoryCommand(Array(arguments.dropFirst()), service: service)
        case "extensions":
            try await extensionsCommand(Array(arguments.dropFirst()), service: service)
        case "sessions":
            try listSessions(service: service)
        case "session":
            try await sessionCommand(Array(arguments.dropFirst()), service: service)
        case "changes":
            try await changesCommand(Array(arguments.dropFirst()), service: service)
        case "tasks":
            try tasksCommand(Array(arguments.dropFirst()), service: service)
        case "autonomous":
            try await autonomousCommand(Array(arguments.dropFirst()), service: service)
        case "run":
            try await runCommand(Array(arguments.dropFirst()), service: service)
        case "interactive":
            try await interactiveCommand(Array(arguments.dropFirst()), service: service)
        case "usage-tui":
            try await usageTUICommand(Array(arguments.dropFirst()), service: service)
        case "cancel":
            try cancelCommand(Array(arguments.dropFirst()), service: service)
        case "chat":
            try await chatCommand(Array(arguments.dropFirst()), service: service)
        case "events":
            try showEvents(Array(arguments.dropFirst()), service: service)
        case "budget":
            try budgetCommand(Array(arguments.dropFirst()), service: service)
        default:
            throw AgentBridgeError.invalidInput("Unknown command \(command). Run `agentbridge help` for usage.")
        }
    }

    /// Internal provider-facing endpoint. It accepts only a private ticket path;
    /// raw MCP commands, helper paths, tools, and target scopes never arrive in argv.
    private static func internalMCPProxyCommand(_ arguments: [String]) async throws {
        guard arguments.count == 2,
              arguments[0] == "--ticket",
              arguments[1].hasPrefix("/"),
              !arguments[1].contains("\0") else {
            throw AgentBridgeError.invalidInput("This internal proxy accepts only --ticket /absolute/path/to/private-ticket.json.")
        }
        try await MCPServerProxy.run(ticketURL: URL(fileURLWithPath: arguments[1]))
    }

    private static func printCLICompatibility(_ report: CLICompatibilityReport) {
        switch report.versionStatus {
        case .matchesTested:
            print("  CLI version: \(report.version ?? "?") (same as the version AgentBridge was verified with)")
        case .newerThanTested:
            print("  CLI version: \(report.version ?? "?") (newer than the verified \(report.testedVersion); if something misbehaves, please report it first)")
        case .olderThanTested:
            print("  Warning: CLI version \(report.version ?? "?") is older than the verified \(report.testedVersion); some features may not work.")
        case .unreadable:
            print("  Warning: could not read the CLI version; AgentBridge was verified with \(report.testedVersion).")
        }
        if !report.flagsWereChecked {
            print("  Warning: could not read the CLI help, so the required flags were not confirmed.")
        }
        if !report.missingFlags.isEmpty {
            print("  Warning: the CLI help does not list flags AgentBridge depends on: \(report.missingFlags.joined(separator: " ")). Related runs will fail closed; update AgentBridge or go back to the verified version.")
        }
    }

    private static func doctor(service: BridgeService) async throws {
        print("AgentBridge \(version)")
        let settings = try service.settings()
        if settings.defaultProvider == .local {
            print("Current default: Local model (uses no API key or subscription usage)")
        } else {
            print("Sign-in mode: \(settings.usageMode == .subscription ? "official CLI subscription sign-in" : "Claude API (each run needs a one-run budget and confirmation)")")
        }
        for provider in AgentProvider.allCases {
            if provider == .local {
                let profile = try service.selectedAccountProfile(provider: .local)
                print("local (\(profile.name)): \(settings.localModel.backend.rawValue) · \(settings.localModel.model.isEmpty ? "no model selected yet" : settings.localModel.model)")
                print("  Endpoint: \(settings.localModel.endpoint)")
                print("  Local model status is not checked by doctor; run `agentbridge local test` explicitly.")
                continue
            }
            do {
                let executable = try RuntimeEnvironment.resolveExecutable(provider: provider, configuredPath: settings.binaryPath(for: provider))
                let profile = try service.selectedAccountProfile(provider: provider)
                let assessment = try await service.checkAuthentication(provider: provider, profileID: profile.id)
                print("\(provider.rawValue) (\(profile.name)): \(executable.path)")
                if let accountLabel = assessment.accountLabel { print("  Account: \(accountLabel)") }
                if let planName = assessment.planName { print("  Plan: \(planName)") }
                print("  \(assessment.message)")
                if let report = try await service.cliCompatibility(provider: provider, profileID: profile.id) {
                    printCLICompatibility(report)
                }
            } catch let error as AgentBridgeError {
                if case .missingExecutable = error { print("\(provider.rawValue): Could not find CLI") }
                else { print("\(provider.rawValue): \(error.localizedDescription)") }
            }
        }
        if settings.defaultProvider == .claude && settings.usageMode == .api {
            do {
                let snapshot = try service.budgetSnapshot()
                print(String(format: "Claude API monthly ledger (UTC month): used US$%.2f, reserved US$%.2f, available US$%.2f.", snapshot.usedUSD, snapshot.reservedUSD, snapshot.availableUSD))
            } catch UsageControlError.apiMonthlyLimitRequired {
                print("The selected Claude account has no local monthly API limit yet; API runs stay disabled until one is set.")
            }
        }
    }

    private static func workspaceCommand(_ arguments: [String]) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge workspace show|set /absolute/path/to/root")
        }
        switch action {
        case "show":
            guard arguments.count == 1 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge workspace show")
            }
            let privateRoot = try RuntimePaths.applicationSupportRoot()
            if let configuration = try WorkspaceRootConfigurationStore.load(privateRootURL: privateRoot) {
                print(configuration.selectedRootURL.path)
                printSyncedRootWarning(configuration.selectedRootURL)
            } else {
                print("No workspace data root is set. Choose a folder in the App, or run: agentbridge workspace set /absolute/path/to/root")
            }
        case "set":
            guard arguments.count == 2 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge workspace set /absolute/path/to/root")
            }
            guard arguments[1].hasPrefix("/") else {
                throw AgentBridgeError.invalidInput("Provide an absolute path, for example `agentbridge workspace set /Users/you/AgentBridgeData`.")
            }
            let requested = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let privateRoot = try RuntimePaths.applicationSupportRoot()
            let selected = try await WorkspaceRootCoordinator.changeRoot(to: requested, privateRootURL: privateRoot)
            print("Workspace data root set: \(selected.path)")
            printSyncedRootWarning(selected)
        default:
            throw AgentBridgeError.invalidInput("Unknown workspace subcommand; usage: agentbridge workspace show|set /absolute/path/to/root")
        }
    }

    private static func printSyncedRootWarning(_ root: URL) {
        guard let service = WorkspaceRootSyncCheck.syncedServiceName(for: root) else { return }
        FileHandle.standardError.write(Data("Note: this folder is in a \(service) synced location. Chat transcripts, shared memory and workspace copies will leave this Mac; file locks only protect this Mac, so using several Macs at once can cause conflicts. Prefer a local folder that is not synced.\n".utf8))
    }

    private static func chatCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else { printChatHelp(); return }
        switch action {
        case "help", "--help", "-h":
            guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("Usage: agentbridge chat help") }
            printChatHelp()
        case "new":
            var provider: AgentProvider?
            var profileID: UUID?
            var index = 1
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                switch option {
                case "--provider":
                    guard provider == nil else { throw AgentBridgeError.invalidInput("--provider cannot be repeated.") }
                    provider = try parseProvider(nextOptionValue(option, arguments: arguments, index: &index))
                case "--profile":
                    guard profileID == nil else { throw AgentBridgeError.invalidInput("--profile cannot be repeated.") }
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let parsed = UUID(uuidString: value) else { throw AgentBridgeError.invalidInput("--profile needs a valid profile UUID.") }
                    profileID = parsed
                default:
                    throw AgentBridgeError.invalidInput("Unknown chat new option \(option).")
                }
            }
            guard let provider else { throw AgentBridgeError.invalidInput("Usage: agentbridge chat new --provider codex|claude|local [--profile PROFILE-ID]") }
            let resolvedProfileID: UUID
            if let profileID {
                resolvedProfileID = profileID
            } else {
                resolvedProfileID = try service.selectedAccountProfile(provider: provider).id
            }
            let discussion = try service.createDiscussion(provider: provider, accountProfileID: resolvedProfileID)
            print("Created chat: \(discussion.id.uuidString.lowercased())")
            print("Provider: \(discussion.provider.rawValue) · profile: \(discussion.accountProfileID.uuidString.lowercased())")
            print("Data root: \(discussion.dataRootPath)")
            print("This chat does not need a Git repository; a destination is only needed when you create or link a project.")
        case "list":
            guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("Usage: agentbridge chat list") }
            let discussions = try service.discussions()
            if discussions.isEmpty { print("No chats yet."); return }
            for discussion in discussions {
                print("\(discussion.id.uuidString.lowercased())  \(discussion.provider.rawValue)  \(discussion.status.rawValue)  turns=\(discussion.turns.count)  linked=\(discussion.linkedSessionIDs.count)")
                print("  Profile: \(discussion.accountProfileID.uuidString.lowercased()) · updated: \(discussion.updatedAt)")
            }
        case "show":
            guard arguments.count == 2, let discussionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge chat show CHAT-ID")
            }
            let discussion = try service.discussion(id: discussionID)
            print("Chat: \(discussion.id.uuidString.lowercased())")
            print("Status: \(discussion.status.rawValue) · Revision: \(discussion.revision)")
            print("Target: \(discussion.provider.rawValue) · profile: \(discussion.accountProfileID.uuidString.lowercased())")
            print("Created: \(discussion.createdAt) · updated: \(discussion.updatedAt)")
            if discussion.transcriptWasTruncated { print("Note: the saved conversation was shortened to fit the storage limit.") }
            if !discussion.linkedSessionIDs.isEmpty {
                print("Linked sessions: \(discussion.linkedSessionIDs.map { $0.uuidString.lowercased() }.joined(separator: ", "))")
            }
            for turn in discussion.turns {
                print("\n[turn \(turn.id.uuidString.lowercased()) · \(turn.provider.rawValue) · \(turn.timestamp)]")
                print("Share flag: \(turn.isShareable ? "allowed" : "excluded") · source account consent: \(turn.sourceSharedMemoryConsent ? "yes" : "no") · a handoff still needs the target account's consent")
                print("User (full text): \(String(reflecting: OutputRedactor.redact(turn.userText)))")
                if let assistantText = turn.assistantText {
                    print("Assistant (full text): \(String(reflecting: OutputRedactor.redact(assistantText)))")
                } else {
                    print("Assistant: no completed reply yet.")
                }
            }
        case "target":
            guard arguments.count >= 2, let discussionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge chat target CHAT-ID --provider codex|claude|local --profile PROFILE-ID")
            }
            var provider: AgentProvider?
            var profileID: UUID?
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                switch option {
                case "--provider":
                    guard provider == nil else { throw AgentBridgeError.invalidInput("--provider cannot be repeated.") }
                    provider = try parseProvider(nextOptionValue(option, arguments: arguments, index: &index))
                case "--profile":
                    guard profileID == nil else { throw AgentBridgeError.invalidInput("--profile cannot be repeated.") }
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let parsed = UUID(uuidString: value) else { throw AgentBridgeError.invalidInput("--profile needs a valid profile UUID.") }
                    profileID = parsed
                default:
                    throw AgentBridgeError.invalidInput("Unknown chat target option \(option).")
                }
            }
            guard let provider, let profileID else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge chat target CHAT-ID --provider codex|claude|local --profile PROFILE-ID")
            }
            let discussion = try service.setDiscussionTarget(id: discussionID, provider: provider, accountProfileID: profileID)
            print("Updated chat target: \(discussion.provider.rawValue) · \(discussion.accountProfileID.uuidString.lowercased())")
        case "send":
            guard arguments.count >= 2, let discussionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge chat send CHAT-ID [--share|--no-share] < prompt.txt")
            }
            var isShareable = true
            var sharingOptionWasSet = false
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                guard !sharingOptionWasSet, (option == "--share" || option == "--no-share") else {
                    throw AgentBridgeError.invalidInput("chat send accepts --share or --no-share only once; the prompt must be read from standard input.")
                }
                sharingOptionWasSet = true
                isShareable = option == "--share"
                index += 1
            }
            let prompt = try readPromptFromStandardInput(maximumBytes: DiscussionStore.maximumTextBytes)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentBridgeError.invalidInput("The prompt cannot be empty.")
            }
            let cancellation = CancellationFlag()
            let signalSources = makeCancellationSignalSources(cancellation)
            defer { signalSources.forEach { $0.cancel() } }
            let output = try await service.sendDiscussionMessage(
                id: discussionID,
                prompt: prompt,
                isShareable: isShareable,
                cancellation: cancellation
            ) { progress in
                FileHandle.standardError.write(Data("• \(OutputRedactor.redact(progress))\n".utf8))
            }
            FileHandle.standardOutput.write(Data((OutputRedactor.redact(output.text) + "\n").utf8))
        case "cancel":
            guard arguments.count == 2, let discussionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge chat cancel CHAT-ID")
            }
            try service.cancelDiscussion(id: discussionID)
            print("Chat cancellation requested: \(discussionID.uuidString.lowercased())")
        case "project":
            try await chatProjectCommand(Array(arguments.dropFirst()), service: service)
        default:
            throw AgentBridgeError.invalidInput("Unknown chat subcommand \(action). Run `agentbridge chat help` for usage.")
        }
    }

    private static func chatProjectCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge chat project preview|apply ...")
        }
        switch action {
        case "preview":
            guard arguments.count >= 2, let discussionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge chat project preview CHAT-ID --mode new|existing --path /absolute/path --provider codex|claude|local --profile PROFILE-ID [--access read-only|changes] [--turn TURN-ID ... | --no-context]")
            }
            var mode: DiscussionProjectMode?
            var destinationPath: String?
            var provider: AgentProvider?
            var profileID: UUID?
            var accessMode: AccessMode = .readOnly
            var accessModeWasSet = false
            var selectedTurnIDs: Set<UUID>?
            var noContext = false
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                switch option {
                case "--mode":
                    guard mode == nil else { throw AgentBridgeError.invalidInput("--mode cannot be repeated.") }
                    switch try nextOptionValue(option, arguments: arguments, index: &index) {
                    case "new": mode = .createNew
                    case "existing": mode = .attachExisting
                    default: throw AgentBridgeError.invalidInput("--mode must be new or existing.")
                    }
                case "--path":
                    guard destinationPath == nil else { throw AgentBridgeError.invalidInput("--path cannot be repeated.") }
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard value.hasPrefix("/"), !value.contains("\0") else {
                        throw AgentBridgeError.invalidInput("--path must be an absolute local path.")
                    }
                    destinationPath = value
                case "--provider":
                    guard provider == nil else { throw AgentBridgeError.invalidInput("--provider cannot be repeated.") }
                    provider = try parseProvider(nextOptionValue(option, arguments: arguments, index: &index))
                case "--profile":
                    guard profileID == nil else { throw AgentBridgeError.invalidInput("--profile cannot be repeated.") }
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let parsed = UUID(uuidString: value) else { throw AgentBridgeError.invalidInput("--profile needs a valid profile UUID.") }
                    profileID = parsed
                case "--access":
                    guard !accessModeWasSet else { throw AgentBridgeError.invalidInput("--access cannot be repeated.") }
                    accessModeWasSet = true
                    switch try nextOptionValue(option, arguments: arguments, index: &index) {
                    case "read-only": accessMode = .readOnly
                    case "changes": accessMode = .isolatedChanges
                    default: throw AgentBridgeError.invalidInput("--access must be read-only or changes.")
                    }
                case "--turn":
                    guard !noContext else { throw AgentBridgeError.invalidInput("--no-context and --turn are mutually exclusive.") }
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let id = UUID(uuidString: value) else { throw AgentBridgeError.invalidInput("--turn needs a valid turn UUID.") }
                    var selected = selectedTurnIDs ?? []
                    guard selected.insert(id).inserted else { throw AgentBridgeError.invalidInput("The same --turn cannot be repeated.") }
                    selectedTurnIDs = selected
                case "--no-context":
                    guard !noContext, selectedTurnIDs == nil else { throw AgentBridgeError.invalidInput("--no-context and --turn are mutually exclusive, and --no-context cannot be repeated.") }
                    noContext = true
                    selectedTurnIDs = []
                default:
                    throw AgentBridgeError.invalidInput("Unknown chat project preview option \(option).")
                }
            }
            guard let mode, let destinationPath, let provider, let profileID else {
                throw AgentBridgeError.invalidInput("Specify --mode, --path, --provider and --profile.")
            }
            guard provider != .local || accessMode == .readOnly else {
                throw AgentBridgeError.invalidInput("Local project chat only supports read-only sessions.")
            }
            let handoff = try await service.prepareDiscussionProjectHandoff(
                discussionID: discussionID,
                destinationPath: destinationPath,
                mode: mode,
                targetProvider: provider,
                targetProfileID: profileID,
                selectedTurnIDs: selectedTurnIDs,
                accessMode: accessMode
            )
            print("Project handoff preview: \(handoff.id.uuidString.lowercased())")
            print("Source chat: \(handoff.discussionID.uuidString.lowercased()) · revision \(handoff.discussionRevision)")
            print("Destination: \(handoff.destinationPath)")
            print("Mode: \(handoff.mode == .createNew ? "create a new Git project" : "link an existing Git project")")
            if handoff.mode == .createNew {
                print("Initial Git commit: an empty-tree commit; chat content does not enter Git history. On apply, only the approved content listed above is imported into AgentBridge memory.")
            } else if let expectedCommit = handoff.expectedRepositoryCommit {
                print("Existing repository HEAD: \(expectedCommit)")
            }
            print("Target: \(handoff.targetProvider.rawValue) · \(handoff.targetProfileID.uuidString.lowercased())")
            let accessDescription: String
            switch handoff.accessMode {
            case .readOnly: accessDescription = "read-only"
            case .interactiveManualApproval: accessDescription = "interactive, manual approval"
            case .isolatedChanges: accessDescription = "isolated changes (plan approval)"
            }
            print("Session access: \(accessDescription)")
            print("Shared content selected: \(handoff.selectedTurns.count) turn(s)")
            for turn in handoff.selectedTurns {
                print("\n[turn \(turn.id.uuidString.lowercased()) · \(turn.provider.rawValue) · \(turn.timestamp)]")
                print("Source profile: \(turn.sourceAccountProfileID.uuidString.lowercased())")
                print("User (full text): \(String(reflecting: turn.userText))")
                print("Assistant (full text): \(String(reflecting: turn.assistantText))")
            }
            print("Review digest: \(handoff.reviewedDigest)")
            print("On apply, only the approved content listed above is copied into the destination session's AgentBridge memory; the original chat is left unchanged.")
            print("This preview does not create a project or session. After reviewing everything above, run:")
            print("agentbridge chat project apply \(handoff.id.uuidString.lowercased()) --digest \(handoff.reviewedDigest) --confirm")
        case "apply":
            guard arguments.count >= 2, let handoffID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge chat project apply HANDOFF-ID --digest REVIEW-DIGEST --confirm")
            }
            var reviewedDigest: String?
            var confirmed = false
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                switch option {
                case "--digest":
                    guard reviewedDigest == nil else { throw AgentBridgeError.invalidInput("--digest cannot be repeated.") }
                    reviewedDigest = try nextOptionValue(option, arguments: arguments, index: &index)
                case "--confirm":
                    guard !confirmed else { throw AgentBridgeError.invalidInput("--confirm cannot be repeated.") }
                    confirmed = true
                default:
                    throw AgentBridgeError.invalidInput("Unknown chat project apply option \(option).")
                }
            }
            guard let reviewedDigest, confirmed else {
                throw AgentBridgeError.invalidInput("apply needs --digest REVIEW-DIGEST and an explicit --confirm.")
            }
            let session = try await service.createOrAttachProjectFromDiscussion(
                handoffID: handoffID,
                reviewedDigest: reviewedDigest,
                explicitConfirmation: true
            )
            print("Created a session from the reviewed handoff: \(session.id.uuidString.lowercased())")
            print("Working directory: \(session.workspacePath)")
            print("Pinned commit: \(session.snapshotCommit)")
            print("The conversation stays in the original chat; nothing is pushed and no remote project is created.")
        default:
            throw AgentBridgeError.invalidInput("Unknown chat project subcommand \(action). Run `agentbridge chat help` for usage.")
        }
    }

    private static func localModelCommand(_ arguments: [String], service: BridgeService) async throws {
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

    private static func localBackendName(_ backend: LocalModelBackend) -> String {
        switch backend {
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible"
        }
    }

    private static func printContextCompressionPreview(_ preview: ContextCompressionPreview, settings: LocalModelSettings) {
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

    private static func printChatHelp() {
        print("""
        Usage: agentbridge chat <subcommand>

          agentbridge chat new --provider codex|claude|local [--profile PROFILE-ID]
          agentbridge chat list
          agentbridge chat show CHAT-ID
          agentbridge chat target CHAT-ID --provider codex|claude|local --profile PROFILE-ID
          agentbridge chat send CHAT-ID [--share|--no-share] < prompt.txt
          agentbridge chat cancel CHAT-ID
          agentbridge chat project preview CHAT-ID --mode new|existing --path /absolute/path --provider codex|claude|local --profile PROFILE-ID [--access read-only|changes] [--turn TURN-ID ... | --no-context]
          agentbridge chat project apply HANDOFF-ID --digest REVIEW-DIGEST --confirm

        `chat new` needs a selected user data root but no Git repository. `chat send` reads the UTF-8 prompt from standard input only, up to \(DiscussionStore.maximumTextBytes) bytes; the prompt is never placed in process arguments. Turns are shareable for later shared context and handoffs by default, and `--share` is an explicit alias; `--no-share` keeps the turn in the chat transcript but excludes it from later context and handoffs. If the source or target account does not allow shared memory, that consent setting keeps the turn out of shared context. When a project preview omits `--turn` and `--no-context`, it selects every complete turn that satisfies the sharing consent; repeating `--turn` selects only the listed turns, and an ineligible turn makes the preview fail; `--no-context` explicitly transfers no turns and cannot be combined with `--turn`. `--access` defaults to read-only. A new project starts with an empty initial Git commit that contains no chat content; apply copies only the approved content listed in the preview into the destination session's AgentBridge memory, and the original chat is kept. No project is created or linked before the preview is done; apply needs the preview digest and `--confirm`. No remote Git call or push is made.
        Codex and Claude chats use only the bound official CLI subscription sign-in; Local chats connect only to the explicitly configured local model. Local project sessions are always read-only. Chat has no API key or budget parameters and no API-credits fallback.
        `chat new --profile`, `chat target` and `project preview` can use a configured account of the matching provider; if `--profile` is omitted for a new chat, the provider's currently selected account is used.

        Local model settings, model list and connection test: `agentbridge local settings|configure|models|test`. Only `models` and `test` connect to the configured local endpoint, and only when you run them; AgentBridge never installs or starts a service or downloads a model. `agentbridge local preview discussion CHAT-ID|project SESSION-ID < prompt.txt` shows the actual context, the compression summary and byte/token estimates.
        """)
    }

    private static func settingsCommand(_ arguments: [String], service: BridgeService) throws {
        guard let subcommand = arguments.first else { throw AgentBridgeError.invalidInput("Specify settings show, usage or binary.") }
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
        default:
            throw AgentBridgeError.invalidInput("Unknown settings subcommand.")
        }
    }

    private static func listSessions(service: BridgeService) throws {
        let sessions = try service.sessions()
        if sessions.isEmpty { print("No Sessions Yet."); return }
        for session in sessions {
            let mode: String
            switch session.policy.accessMode {
            case .readOnly: mode = "read-only"
            case .interactiveManualApproval: mode = "interactive, manual approval"
            case .isolatedChanges: mode = "isolated changes (plan approval)"
            }
            print("\(session.id.uuidString.lowercased())  \(session.provider.rawValue)  \(mode)  \(session.status.rawValue)  \(session.snapshotCommit.prefix(12))")
            print("  \(session.workspacePath)")
        }
    }

    private static func sessionCommand(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.first == "create" else { throw AgentBridgeError.invalidInput("Usage: agentbridge session create --provider codex|claude|local --repo PATH [--interactive|--changes]") }
        var provider: AgentProvider?
        var repoPath: String?
        var interactive = false
        var isolatedChanges = false
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
        let session = try await service.createSession(sourcePath: repoPath, provider: provider, accessMode: access)
        print("Created an isolated session: \(session.id.uuidString.lowercased())")
        print("Workspace: \(session.workspacePath)")
        print("Pinned commit: \(session.snapshotCommit)")
        if session.sourceWasDirty { print("The source has uncommitted changes; they were not copied into the workspace.") }
        if interactive {
            let profileID = session.accountProfileID?.uuidString.lowercased() ?? AccountProfile.defaultID(for: provider).uuidString.lowercased()
            print("Interactive mode must run in Terminal: agentbridge interactive \(session.id.uuidString.lowercased()) --profile \(profileID)")
        }
        if isolatedChanges {
            print("Created an isolated changes session. Read-only remains the default; nothing is written until you create and explicitly approve a work plan.")
        }
    }

    private static func runCommand(_ arguments: [String], service: BridgeService) async throws {
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

    private static func interactiveCommand(_ arguments: [String], service: BridgeService) async throws {
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

    private static func usageTUICommand(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count == 4,
              arguments[0] == "--provider",
              let provider = AgentProvider(rawValue: arguments[1]),
              provider != .local,
              arguments[2] == "--profile",
              let profileID = UUID(uuidString: arguments[3]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge usage-tui --provider codex|claude --profile PROFILE-ID")
        }
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        _ = try await service.runUsageTUI(provider: provider, profileID: profileID, cancellation: cancellation)
    }

    private static func profilesCommand(_ arguments: [String], service: BridgeService) throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge profiles list|create|select|memory ...")
        }
        switch action {
        case "list":
            guard arguments.count <= 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge profiles list [codex|claude|local]") }
            let providers = arguments.count == 2 ? [try parseProvider(arguments[1])] : AgentProvider.allCases
            for provider in providers {
                let selectedID = try service.selectedAccountProfile(provider: provider).id
                for profile in try service.accountProfiles(provider: provider) {
                    let selectedMarker = profile.id == selectedID ? "*" : " "
                    let loginKind = provider == .local ? "Local modelAccount" : (profile.usesExistingLogin ? "Current local login" : "separate sign-in")
                    let memory = profile.allowsSharedMemory ? "shared memory on" : "shared memory off"
                    print("\(selectedMarker) \(profile.id.uuidString.lowercased())  \(provider.rawValue)  \(profile.name)  \(loginKind)  \(memory)")
                }
            }
        case "create":
            var provider: AgentProvider?
            var name: String?
            var allowsSharedMemory = true
            var index = 1
            while index < arguments.count {
                switch arguments[index] {
                case "--provider":
                    index += 1
                    guard index < arguments.count else { throw AgentBridgeError.invalidInput("--provider needs codex, claude or local.") }
                    provider = try parseProvider(arguments[index])
                case "--name":
                    index += 1
                    guard index < arguments.count else { throw AgentBridgeError.invalidInput("--name needs an account name.") }
                    name = arguments[index]
                case "--share-memory":
                    allowsSharedMemory = true
                default:
                    throw AgentBridgeError.invalidInput("Unknown profiles create option \(arguments[index]).")
                }
                index += 1
            }
            guard let provider, let name else { throw AgentBridgeError.invalidInput("Specify --provider and --name.") }
            let profile = try service.createAccountProfile(name: name, provider: provider, allowsSharedMemory: allowsSharedMemory)
            print("Created a separate account profile: \(profile.id.uuidString.lowercased()) (\(provider.rawValue), shared memory \(allowsSharedMemory ? "on" : "off")).")
            if provider == .local {
                print("Local accounts do not use a CLI sign-in or credential folder.")
            } else {
                print("To sign in, run in an interactive Terminal: agentbridge profile-login \(profile.id.uuidString.lowercased())")
            }
        case "select":
            guard arguments.count == 4, arguments[1] == "--provider",
                  let provider = AgentProvider(rawValue: arguments[2]),
                  let profileID = UUID(uuidString: arguments[3]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge profiles select --provider codex|claude|local PROFILE-ID")
            }
            try service.selectAccountProfile(id: profileID, provider: provider)
            print("Selected \(provider.rawValue) account profile \(profileID.uuidString.lowercased()). New sessions will be bound to this account.")
        case "memory":
            guard arguments.count == 3, let profileID = UUID(uuidString: arguments[1]),
                  arguments[2] == "on" || arguments[2] == "off" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge profiles memory PROFILE-ID on|off")
            }
            try service.setAccountSharedMemoryAllowed(id: profileID, allowed: arguments[2] == "on")
            print("Updated the account's shared-memory setting.")
        default:
            throw AgentBridgeError.invalidInput("Unknown profiles subcommand.")
        }
    }

    private static func profileLoginCommand(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count == 1, let profileID = UUID(uuidString: arguments[0]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge profile-login PROFILE-ID")
        }
        let profile = try service.accountProfile(id: profileID)
        guard profile.provider != .local else {
            throw AgentBridgeError.invalidInput("Local model accounts do not use CLI sign-in.")
        }
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        _ = try await service.loginAccountProfile(profileID: profileID, cancellation: cancellation) { message in
            FileHandle.standardError.write(Data("• \(message)\n".utf8))
        }
    }

    /// Convert terminal and app shutdown signals into a cooperative runner
    /// cancellation so SafeProcessRunner can terminate the provider's process
    /// group and wait for its bounded cleanup path.
    private static func makeCancellationSignalSources(_ cancellation: CancellationFlag) -> [DispatchSourceSignal] {
        [SIGINT, SIGTERM, SIGHUP].map { signalNumber in
            _ = signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .userInitiated))
            source.setEventHandler { cancellation.cancel() }
            source.resume()
            return source
        }
    }

    private static func memoryCommand(_ arguments: [String], service: BridgeService) throws {
        guard let action = arguments.first, arguments.count >= 2,
              let sessionID = UUID(uuidString: arguments[1]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge memory show|notes|clear|relink-candidates|relink SESSION-ID [--confirm]")
        }
        switch action {
        case "show":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge memory show SESSION-ID") }
            let snapshot = try service.sharedMemory(sessionID: sessionID)
            print("Scope: \(snapshot.scope.repositoryPath) @ \(snapshot.scope.snapshotCommit.prefix(12))")
            print("Revision: \(snapshot.revision); turns: \(snapshot.turns.count); content truncated: \(snapshot.wasTruncated ? "yes" : "no")")
            print("\n[Notes]\n\(snapshot.notes)")
            for turn in snapshot.turns {
                print("\n[\(turn.id.uuidString.lowercased()) · \(turn.provider.rawValue) \(turn.timestamp)]\nUser: \(turn.userText)\nAssistant: \(turn.assistantText)")
            }
        case "notes":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge memory notes SESSION-ID < notes.txt") }
            let notes = try readPromptFromStandardInput(maximumBytes: 64 * 1_024)
            try service.setSharedMemoryNotes(sessionID: sessionID, notes: notes)
            print("Updated the shared-memory notes for this isolated workspace.")
        case "clear":
            guard arguments.count == 3, arguments[2] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Clearing cannot be undone; run agentbridge memory clear SESSION-ID --confirm explicitly.")
            }
            try service.clearSharedMemory(sessionID: sessionID)
            print("Cleared the shared memory for this isolated workspace.")
        case "relink-candidates":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge memory relink-candidates SESSION-ID") }
            let candidates = try service.memoryRelinkCandidates(sessionID: sessionID)
            for candidate in candidates {
                print("\(candidate.source.key)  earlier path: \(candidate.source.repositoryPath)  turns: \(candidate.turnCount)  notes=\(candidate.hasNotes ? "yes" : "no")")
            }
            if candidates.isEmpty { print("No earlier memory can be linked.") }
            else { print("\nTo copy one of them: agentbridge memory relink SESSION-ID KEY --confirm (the original memory is not changed)") }
        case "relink":
            guard arguments.count == 4, arguments[3] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge memory relink SESSION-ID KEY --confirm; use relink-candidates first to see the KEY.")
            }
            let candidate = try service.relinkMemory(sessionID: sessionID, sourceKey: arguments[2])
            print("Copied \(candidate.turnCount) turn(s) from \(candidate.source.repositoryPath) into this workspace's memory; the original memory was not changed.")
        case "handoffs":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge memory handoffs SESSION-ID") }
            let handoffs = try service.projectMemoryHandoffs(sessionID: sessionID)
            for handoff in handoffs {
                print("\(handoff.id.uuidString.lowercased())  \(handoff.sourceCommit) -> \(handoff.targetCommit)  \(handoff.turns.count) selected turns  notes=\(handoff.notes == nil ? "no" : "yes")")
            }
            if handoffs.isEmpty { print("This repository has no explicit memory handoffs yet.") }
        case "carry-forward":
            guard arguments.count >= 3,
                  let sourceID = UUID(uuidString: arguments[1]),
                  let targetID = UUID(uuidString: arguments[2]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge memory carry-forward SOURCE-SESSION TARGET-SESSION [--turn TURN-ID ...] [--notes]")
            }
            var selectedTurnIDs = Set<UUID>()
            var includeNotes = false
            var index = 3
            while index < arguments.count {
                switch arguments[index] {
                case "--turn":
                    index += 1
                    guard index < arguments.count, let id = UUID(uuidString: arguments[index]) else {
                        throw AgentBridgeError.invalidInput("--turn needs a valid turn UUID.")
                    }
                    selectedTurnIDs.insert(id)
                case "--notes": includeNotes = true
                default: throw AgentBridgeError.invalidInput("Unknown memory carry-forward option \(arguments[index]).")
                }
                index += 1
            }
            let handoff = try service.carryForwardProjectMemory(
                sourceSessionID: sourceID,
                targetSessionID: targetID,
                selectedTurnIDs: selectedTurnIDs,
                includeNotes: includeNotes
            )
            print("Created explicit handoff \(handoff.id.uuidString.lowercased()): \(handoff.sourceCommit) -> \(handoff.targetCommit).")
            print("Only the selected App memory is copied; the next shared-memory prompt allowed at the target commit receives it as untrusted, size-bounded history.")
        default:
            throw AgentBridgeError.invalidInput("Unknown memory subcommand.")
        }
    }

    private static func changesCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge changes plan|approve|run|diff|restore|restore-all|export|verify|accept|apply ...")
        }
        switch action {
        case "plan":
            guard arguments.count >= 2, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes plan SESSION-ID --title TITLE --summary SUMMARY --step STEP [--step STEP ...]")
            }
            var title: String?
            var summary: String?
            var steps: [String] = []
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("\(option) needs a value.") }
                switch option {
                case "--title": title = arguments[index]
                case "--summary": summary = arguments[index]
                case "--step": steps.append(arguments[index])
                default: throw AgentBridgeError.invalidInput("Unknown changes plan option \(option).")
                }
                index += 1
            }
            guard let title, let summary else { throw AgentBridgeError.invalidInput("Specify --title and --summary.") }
            let plan = try service.createChangePlan(sessionID: sessionID, title: title, summary: summary, steps: steps)
            print("Plan awaiting review: \(plan.id.uuidString.lowercased())")
            print("Title: \(plan.title)\nSummary: \(plan.summary)\nSteps:")
            for (offset, step) in plan.steps.enumerated() { print("  \(offset + 1). \(step)") }
            print("Review digest: \(plan.reviewDigest)")
            print("The plan is not approved; it does not authorize writes yet.")
        case "approve":
            guard arguments.count == 4,
                  let sessionID = UUID(uuidString: arguments[1]),
                  let planID = UUID(uuidString: arguments[2]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes approve SESSION-ID PLAN-ID REVIEW-DIGEST")
            }
            let session = try requireSession(sessionID, service: service)
            guard let plan = session.changePlan, plan.id == planID, plan.reviewDigest == arguments[3].lowercased() else {
                throw AgentBridgeError.invalidChangePlan("The plan ID or digest does not match what is currently saved.")
            }
            print("Review the plan below item by item. Change runs unlock only after you approve it explicitly:")
            print("\(plan.title)\n\(plan.summary)")
            for (offset, step) in plan.steps.enumerated() { print("  \(offset + 1). \(step)") }
            print("Type the exact text APPROVE \(plan.reviewDigest) to approve:")
            guard readLine(strippingNewline: true) == "APPROVE \(plan.reviewDigest)" else {
                throw AgentBridgeError.invalidChangePlan("The full review digest was not entered; the plan is still not approved.")
            }
            _ = try service.approveChangePlan(sessionID: sessionID, planID: planID, reviewedDigest: plan.reviewDigest)
            print("Explicitly approved the current work plan.")
        case "run":
            guard arguments.count == 4,
                  let sessionID = UUID(uuidString: arguments[1]),
                  let planID = UUID(uuidString: arguments[2]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes run SESSION-ID PLAN-ID REVIEW-DIGEST < prompt.txt")
            }
            let prompt = try readPromptFromStandardInput(maximumBytes: 256_000)
            let cancellation = CancellationFlag()
            let signalSources = makeCancellationSignalSources(cancellation)
            defer { signalSources.forEach { $0.cancel() } }
            let output = try await service.runChanges(
                sessionID: sessionID,
                prompt: prompt,
                planID: planID,
                reviewedDigest: arguments[3].lowercased(),
                cancellation: cancellation
            ) { progress in
                FileHandle.standardError.write(Data("• \(OutputRedactor.redact(progress))\n".utf8))
            }
            FileHandle.standardOutput.write(Data((OutputRedactor.redact(output.text) + "\n").utf8))
        case "diff":
            guard arguments.count == 2, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes diff SESSION-ID")
            }
            let diff = try await service.changesDiff(sessionID: sessionID)
            for file in diff.files {
                print("\n--- \(file.status.rawValue) \(file.path) ---")
                if file.isBinary { print("[binary file]") }
                else { print(file.patch, terminator: "") }
            }
            if diff.files.isEmpty { print("The isolated workspace has no differences.") }
        case "restore":
            guard arguments.count >= 3, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes restore SESSION-ID RELATIVE-PATH [RELATIVE-PATH ...]")
            }
            try await service.restoreChangeFiles(sessionID: sessionID, filePaths: Array(arguments.dropFirst(2)))
            print("Restored the listed isolated-workspace files; the source repository was not changed.")
        case "restore-all":
            guard arguments.count == 3, let sessionID = UUID(uuidString: arguments[1]), arguments[2] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes restore-all SESSION-ID --confirm")
            }
            try await service.restoreAllChanges(sessionID: sessionID)
            print("Restored the isolated workspace to the base commit; the source repository was not changed.")
        case "export":
            guard arguments.count == 3, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes export SESSION-ID /absolute/path/to/changes.patch")
            }
            let destination = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            guard destination.path.hasPrefix("/"), !destination.path.contains("\0") else {
                throw AgentBridgeError.invalidInput("Patch output needs a valid absolute path.")
            }
            let patch = try await service.exportChangePatch(sessionID: sessionID)
            try writeNewPrivateFile(patch, to: destination)
            print("Exported a \(patch.count)-byte patch to \(destination.path).")
        case "verify":
            guard arguments.count >= 2, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes verify SESSION-ID [--custom /absolute/executable --approve-custom [--arg ARG ...]]")
            }
            var customPath: URL?
            var approved = false
            var verifierArguments: [String] = []
            var index = 2
            while index < arguments.count {
                switch arguments[index] {
                case "--custom":
                    index += 1
                    guard index < arguments.count, customPath == nil else { throw AgentBridgeError.invalidInput("--custom needs one absolute executable path.") }
                    customPath = URL(fileURLWithPath: arguments[index])
                case "--approve-custom": approved = true
                case "--arg":
                    index += 1
                    guard index < arguments.count else { throw AgentBridgeError.invalidInput("--arg needs one argument value.") }
                    verifierArguments.append(arguments[index])
                default: throw AgentBridgeError.invalidInput("Unknown changes verify option \(arguments[index]).")
                }
                index += 1
            }
            guard customPath == nil || approved else {
                throw AgentBridgeError.verificationCommandRejected("Custom verification also needs --approve-custom; each --arg is passed as a separate argv entry and never goes through a shell.")
            }
            let cancellation = CancellationFlag()
            let signalSources = makeCancellationSignalSources(cancellation)
            defer { signalSources.forEach { $0.cancel() } }
            let result = try await service.runVerification(
                sessionID: sessionID,
                customExecutableURL: customPath,
                arguments: verifierArguments,
                customCommandApproved: customPath != nil && approved,
                cancellation: cancellation
            )
            print("Executable: \(OutputRedactor.redact(result.command?.executablePath ?? "not launched"))")
            print("Exit code: \(result.exitCode.map(String.init) ?? "not provided"); duration: \(String(format: "%.3f", result.durationSeconds)) s; succeeded: \(result.succeeded ? "yes" : "no")")
            if let skipped = result.skippedReason { print("Skipped: \(OutputRedactor.redact(skipped))") }
            if !result.standardOutput.isEmpty { print("\n[stdout]\n\(result.standardOutput)") }
            if !result.standardError.isEmpty { FileHandle.standardError.write(Data("\n[stderr]\n\(result.standardError)\n".utf8)) }
        case "accept":
            guard arguments.count == 3, let sessionID = UUID(uuidString: arguments[1]), arguments[2] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes accept SESSION-ID --confirm")
            }
            _ = try await service.acceptChanges(sessionID: sessionID)
            print("Accepted the currently verified isolated diff; the source repository is still unchanged.")
        case "apply":
            guard arguments.count == 3, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge changes apply SESSION-ID LOCAL-BRANCH")
            }
            let result = try await service.applyChangesToLocalBranch(sessionID: sessionID, branchName: arguments[2])
            print("Created a worktree: \(result.worktreePath) (branch \(result.branchName), \(result.changedFileCount) file(s)).")
            print("The worktree is left uncommitted; AgentBridge did not commit, push or merge.")
        default:
            throw AgentBridgeError.invalidInput("Unknown changes subcommand \(action).")
        }
    }

    private static func requireSession(_ id: UUID, service: BridgeService) throws -> SessionRecord {
        guard let session = try service.sessions().first(where: { $0.id == id }) else {
            throw AgentBridgeError.sessionNotFound(id)
        }
        return session
    }

    private static func writeNewPrivateFile(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw AgentBridgeError.persistence("Patch output already exists or cannot be created safely.")
        }
        defer { _ = close(descriptor) }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("Could not secure patch output file.")
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AgentBridgeError.persistence("Could not write patch output file.")
                }
                guard written > 0 else { throw AgentBridgeError.persistence("Patch output write was incomplete.") }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw AgentBridgeError.persistence("Could not sync patch output file.") }
    }

    private static func tasksCommand(_ arguments: [String], service: BridgeService) throws {
        guard arguments.count <= 1 else { throw AgentBridgeError.invalidInput("Usage: agentbridge tasks [SESSION-ID]") }
        let sessionID = arguments.first.flatMap(UUID.init(uuidString:))
        guard arguments.isEmpty || sessionID != nil else { throw AgentBridgeError.invalidInput("SESSION-ID must be a valid UUID.") }
        let records = try service.taskRecords(sessionID: sessionID)
        if records.isEmpty { print("No task records yet."); return }
        for task in records {
            print("\(task.id.uuidString.lowercased())  \(task.status.rawValue)  approval=\(task.approvalState.rawValue)  session=\(task.sessionID.uuidString.lowercased())")
            print("  \(OutputRedactor.redact(task.progressSummary))")
            for reference in task.references {
                print("  \(reference.kind.rawValue): \(OutputRedactor.redact(reference.value))")
            }
        }
    }

    private static func autonomousCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge autonomous plan|approve|run|status|cancel ...")
        }
        switch action {
        case "plan":
            var sourcePath: String?
            var plannerBinding: (AgentProvider, UUID)?
            var roleBindings: [AutonomousRole: (AgentProvider, UUID)] = [:]
            var extensions: [AutonomousRole: [String]] = [:]
            var maxConcurrentAgents = 3
            var maxReviewRounds = 2
            var maxDurationSeconds = 1_800
            var maxProviderInvocations = 20
            var shareDependencies = false
            var shareDiffWithReviewer = false
            var desktopControlScope: String?
            var desktopControlSeparateFromGit = false
            var saveRunSummaryToMemory = false
            var memoryDestinationProfileID: UUID?
            var verificationMode: AutonomousVerificationSelection.Mode = .projectCI
            var verificationExecutable: String?
            var verificationArguments: [String] = []
            var emitJSON = false
            var index = 1
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                switch option {
                case "--source":
                    sourcePath = try nextOptionValue(option, arguments: arguments, index: &index)
                case "--planner":
                    plannerBinding = try parseProviderProfile(try nextOptionValue(option, arguments: arguments, index: &index))
                case "--researcher", "--implementer", "--reviewer":
                    let role = try autonomousRole(for: option)
                    roleBindings[role] = try parseProviderProfile(try nextOptionValue(option, arguments: arguments, index: &index))
                case "--researcher-extension", "--implementer-extension", "--reviewer-extension":
                    let role: AutonomousRole
                    switch option {
                    case "--researcher-extension": role = .researcher
                    case "--implementer-extension": role = .implementer
                    default: role = .reviewer
                    }
                    extensions[role, default: []].append(try nextOptionValue(option, arguments: arguments, index: &index))
                case "--max-concurrent":
                    maxConcurrentAgents = try parseInteger(try nextOptionValue(option, arguments: arguments, index: &index), option: option)
                case "--max-review-rounds":
                    maxReviewRounds = try parseInteger(try nextOptionValue(option, arguments: arguments, index: &index), option: option)
                case "--max-duration-seconds":
                    maxDurationSeconds = try parseInteger(try nextOptionValue(option, arguments: arguments, index: &index), option: option)
                case "--max-provider-invocations":
                    maxProviderInvocations = try parseInteger(try nextOptionValue(option, arguments: arguments, index: &index), option: option)
                case "--share-dependencies": shareDependencies = true
                case "--share-diff-with-reviewer": shareDiffWithReviewer = true
                case "--desktop-control-scope": desktopControlScope = try nextOptionValue(option, arguments: arguments, index: &index)
                case "--confirm-desktop-separate-from-git": desktopControlSeparateFromGit = true
                case "--save-summary-to-memory": saveRunSummaryToMemory = true
                case "--memory-destination":
                    let rawValue = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let profileID = UUID(uuidString: rawValue) else { throw AgentBridgeError.invalidInput("--memory-destination requires a profile UUID.") }
                    memoryDestinationProfileID = profileID
                case "--verification":
                    guard let mode = AutonomousVerificationSelection.Mode(rawValue: try nextOptionValue(option, arguments: arguments, index: &index)) else {
                        throw AgentBridgeError.invalidInput("--verification must be none, projectCI, or custom.")
                    }
                    verificationMode = mode
                case "--verify-command": verificationExecutable = try nextOptionValue(option, arguments: arguments, index: &index)
                case "--verify-arg": verificationArguments.append(try nextOptionValue(option, arguments: arguments, index: &index))
                case "--json": emitJSON = true
                default: throw AgentBridgeError.invalidInput("Unknown autonomous plan option \(option).")
                }
            }
            guard let sourcePath, let plannerBinding,
                  let researcherBinding = roleBindings[.researcher],
                  let implementerBinding = roleBindings[.implementer],
                  let reviewerBinding = roleBindings[.reviewer] else {
                throw AgentBridgeError.invalidInput("Plan needs --source, --planner PROVIDER:PROFILE-ID, and provider/profile bindings for --researcher, --implementer, and --reviewer.")
            }
            guard shareDiffWithReviewer else {
                throw AgentBridgeError.invalidInput("Add --share-diff-with-reviewer to explicitly allow the exact implementation diff to be reviewed by the selected reviewer profile.")
            }
            guard (desktopControlScope != nil) == desktopControlSeparateFromGit else {
                throw AgentBridgeError.invalidInput("Desktop control requires both --desktop-control-scope and --confirm-desktop-separate-from-git.")
            }
            guard saveRunSummaryToMemory == (memoryDestinationProfileID != nil) else {
                throw AgentBridgeError.invalidInput("Saving a run summary requires both --save-summary-to-memory and --memory-destination PROFILE-ID.")
            }
            let goal = try readBoundedStandardInput(maximumBytes: 8_000, label: "Autonomous goal")
            let planner = try AutonomousRoleBinding(role: .planner, provider: plannerBinding.0, accountProfileID: plannerBinding.1)
            let bindings = try [
                AutonomousRoleBinding(role: .researcher, provider: researcherBinding.0, accountProfileID: researcherBinding.1, extensionIDs: extensions[.researcher] ?? []),
                AutonomousRoleBinding(role: .implementer, provider: implementerBinding.0, accountProfileID: implementerBinding.1, extensionIDs: extensions[.implementer] ?? []),
                AutonomousRoleBinding(role: .reviewer, provider: reviewerBinding.0, accountProfileID: reviewerBinding.1, extensionIDs: extensions[.reviewer] ?? [])
            ]
            let limits = try AutonomousRunLimits(
                maxConcurrentAgents: maxConcurrentAgents,
                maxReviewRounds: maxReviewRounds,
                maxDurationSeconds: maxDurationSeconds,
                maxProviderInvocations: maxProviderInvocations
            )
            let verification: AutonomousVerificationSelection
            switch verificationMode {
            case .none:
                guard verificationExecutable == nil, verificationArguments.isEmpty else {
                    throw AgentBridgeError.invalidInput("--verify-command and --verify-arg require --verification custom.")
                }
                verification = .none
            case .projectCI:
                guard verificationExecutable == nil, verificationArguments.isEmpty else {
                    throw AgentBridgeError.invalidInput("--verify-command and --verify-arg require --verification custom.")
                }
                verification = .projectCI
            case .custom:
                guard let verificationExecutable else {
                    throw AgentBridgeError.invalidInput("--verification custom requires --verify-command EXECUTABLE; use repeated --verify-arg for separate argv values.")
                }
                verification = try .custom(executablePath: verificationExecutable, arguments: verificationArguments)
            }
            let request = try AutonomousRunRequest(
                goal: goal,
                sourceRepositoryPath: sourcePath,
                planner: planner,
                roleBindings: bindings,
                limits: limits,
                shareOutputsWithDependencies: shareDependencies,
                shareDiffWithReviewer: true,
                desktopControlScope: desktopControlScope,
                desktopControlSeparateFromGit: desktopControlSeparateFromGit,
                saveRunSummaryToMemory: saveRunSummaryToMemory,
                memoryDestinationProfileID: memoryDestinationProfileID,
                verification: verification
            )
            let record = try await service.prepareAutonomousRun(request)
            if emitJSON {
                try printJSON(record)
            } else {
                printAutonomousPlan(record)
                print("Planning started a real provider request using the selected official CLI subscription profile. The plan is not approved yet.")
            }
        case "approve":
            guard arguments.count == 5,
                  let runID = UUID(uuidString: arguments[1]),
                  arguments[2] == "--digest",
                  arguments[4] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge autonomous approve RUN-ID --digest REVIEW-DIGEST --confirm")
            }
            guard let record = try service.autonomousRun(id: runID) else {
                throw AgentBridgeError.invalidInput("Autonomous run not found.")
            }
            guard record.planDigest == arguments[3].lowercased() else {
                throw AgentBridgeError.invalidInput("The reviewed digest does not match the saved autonomous plan.")
            }
            _ = try service.approveAutonomousRun(id: runID, reviewedDigest: record.planDigest)
            print("Approved the reviewed plan and its bounded repair and verification loop for digest \(record.planDigest).")
        case "run":
            guard arguments.count == 4,
                  let runID = UUID(uuidString: arguments[1]),
                  arguments[2] == "--digest" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge autonomous run RUN-ID --digest REVIEW-DIGEST")
            }
            let cancellation = CancellationFlag()
            let signalSources = makeCancellationSignalSources(cancellation)
            defer { signalSources.forEach { $0.cancel() } }
            let record = try await service.runAutonomousRun(
                id: runID,
                reviewedDigest: arguments[3].lowercased(),
                cancellation: cancellation
            )
            try printJSON(record)
        case "status":
            let remainder = Array(arguments.dropFirst())
            let identifiers = remainder.filter { !$0.hasPrefix("--") }
            let options = Set(remainder.filter { $0.hasPrefix("--") })
            guard options.isSubset(of: ["--json"]), identifiers.count <= 1 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge autonomous status [RUN-ID] [--json]")
            }
            let records: [AutonomousRunRecord]
            if let identifier = identifiers.first {
                guard let id = UUID(uuidString: identifier) else { throw AgentBridgeError.invalidInput("RUN-ID must be a UUID.") }
                guard let record = try service.autonomousRun(id: id) else {
                    throw AgentBridgeError.invalidInput("Autonomous run not found.")
                }
                records = [record]
            } else {
                records = try service.autonomousRuns()
            }
            if options.contains("--json") {
                try printJSON(records)
            } else if records.isEmpty {
                print("No autonomous runs yet.")
            } else {
                for record in records { printAutonomousStatus(record) }
            }
        case "cancel":
            guard arguments.count == 3,
                  let runID = UUID(uuidString: arguments[1]),
                  arguments[2] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge autonomous cancel RUN-ID --confirm")
            }
            try service.cancelAutonomousRun(id: runID)
            print("Cancellation requested for autonomous run \(runID.uuidString.lowercased()); active role sessions are being cancelled.")
        default:
            throw AgentBridgeError.invalidInput("Unknown autonomous action. Use plan, approve, run, status, or cancel.")
        }
    }

    private static func autonomousRole(for option: String) throws -> AutonomousRole {
        switch option {
        case "--researcher": return .researcher
        case "--implementer": return .implementer
        case "--reviewer": return .reviewer
        default: throw AgentBridgeError.invalidInput("Unknown autonomous role \(option).")
        }
    }

    private static func parseProviderProfile(_ value: String) throws -> (AgentProvider, UUID) {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let provider = AgentProvider(rawValue: String(parts[0])),
              let profileID = UUID(uuidString: String(parts[1])) else {
            throw AgentBridgeError.invalidInput("Provider profile must use PROVIDER:PROFILE-UUID, such as codex:00000000-0000-0000-0000-000000000001.")
        }
        return (provider, profileID)
    }

    private static func nextOptionValue(_ option: String, arguments: [String], index: inout Int) throws -> String {
        guard index < arguments.count, !arguments[index].hasPrefix("--") else {
            throw AgentBridgeError.invalidInput("\(option) requires a value.")
        }
        let value = arguments[index]
        index += 1
        return value
    }

    private static func parseInteger(_ value: String, option: String) throws -> Int {
        guard let parsed = Int(value) else { throw AgentBridgeError.invalidInput("\(option) requires an integer.") }
        return parsed
    }

    private static func printAutonomousPlan(_ record: AutonomousRunRecord) {
        let plan = record.plan
        print("Run: \(record.id.uuidString.lowercased())")
        print("Status: \(record.status.rawValue)")
        print("Goal: \(OutputRedactor.redact(plan.goal))")
        print("Source: \(plan.sourceRepositoryPath) @ \(plan.baseCommit)")
        print("Source repository fingerprint: \(plan.sourceRepositoryFingerprint.overallDigest)")
        print("  HEAD \(plan.sourceRepositoryFingerprint.headCommit) · status \(plan.sourceRepositoryFingerprint.statusDigest)")
        print("  tracked diff \(plan.sourceRepositoryFingerprint.trackedDiffDigest) · untracked paths \(plan.sourceRepositoryFingerprint.untrackedPathsDigest) · untracked contents \(plan.sourceRepositoryFingerprint.untrackedContentDigest)")
        print("  Checked before execution and after desktop control/final work; agents use an isolated snapshot.")
        if let desktopScope = plan.desktopControlScope {
            print("Desktop control scope: \(OutputRedactor.redact(desktopScope)) · separate from Git/source access: \(plan.desktopControlSeparateFromGit)")
        } else {
            print("Desktop control scope: none")
        }
        if let memory = plan.projectMemorySnapshot {
            print("Frozen project memory: \(memory.repositoryPath) @ \(memory.snapshotCommit) · revision \(memory.revision) · SHA-256 \(memory.digest) · truncated \(memory.wasTruncated)")
            print("  Role profiles receiving context: \(plan.roleProfiles.filter { $0.profile.allowsSharedMemory }.map { "\($0.binding.role.rawValue):\($0.binding.provider.rawValue)/\($0.profile.name)" }.joined(separator: ", "))")
            print("  Exact notes: \(OutputRedactor.redact(memory.notes))")
            for turn in memory.turns {
                print("  \(turn.provider.rawValue) memory turn \(turn.id.uuidString.lowercased()) · \(turn.timestamp.formatted()):")
                print("    User: \(OutputRedactor.redact(turn.userText))")
                print("    Assistant: \(OutputRedactor.redact(turn.assistantText))")
            }
        } else {
            print("Frozen project memory: none (no bound profile allows shared memory)")
        }
        print("Save final summary to project memory: \(plan.saveRunSummaryToMemory) · destination \(plan.memoryDestinationProfileID?.uuidString.lowercased() ?? "none")")
        print("Planner: \(plan.plannerBinding.provider.rawValue) / \(plan.plannerBinding.accountProfileID.uuidString.lowercased())")
        print("Concurrency: \(plan.limits.maxConcurrentAgents); review rounds: \(plan.limits.maxReviewRounds); duration: \(plan.limits.maxDurationSeconds)s; provider calls: \(plan.limits.maxProviderInvocations)")
        print("Dependency outputs shared: \(plan.shareOutputsWithDependencies); exact diff shared with reviewer: \(plan.shareDiffWithReviewer)")
        print("Verification: \(plan.verification.mode.rawValue)\(plan.verification.executablePath.map { " · \($0)" } ?? "")")
        if let disclosure = plan.verification.executionTrustDisclosure {
            print("Verification trust: \(disclosure)")
        }
        for binding in plan.roleProfiles {
            print("Role \(binding.binding.role.rawValue): \(binding.binding.provider.rawValue) / \(binding.profile.name) / \(binding.profile.id.uuidString.lowercased()) · shared memory \(binding.profile.allowsSharedMemory ? "allowed" : "off") · extensions \(binding.binding.extensionIDs.joined(separator: ", "))")
        }
        print("\nChange scope: \(plan.changeScope.title)\n\(OutputRedactor.redact(plan.changeScope.summary))")
        for (offset, step) in plan.changeScope.steps.enumerated() { print("  \(offset + 1). \(OutputRedactor.redact(step))") }
        print("\nTask plan:")
        for task in plan.tasks {
            print("  \(task.id) [\(task.role.rawValue)] \(OutputRedactor.redact(task.title)) · dependencies: \(task.dependencies.joined(separator: ", "))")
            print("    \(OutputRedactor.redact(task.prompt))")
        }
        if !plan.extensionActivations.isEmpty {
            print("\nExtension activation manifest:")
            for activation in plan.extensionActivations {
                print("  \(activation.role.rawValue) / \(activation.taskID) / \(activation.extensionID) · \(activation.kind) · config \(activation.configurationDigest)")
                if let reviewedDigest = activation.reviewedDigest { print("    review digest: \(reviewedDigest)") }
                if let commandPath = activation.commandPath { print("    command: \(commandPath) \(activation.arguments.map(\.debugDescription).joined(separator: " "))") }
                for pin in activation.entrypointPins {
                    print("    pinned entrypoint: \(pin.path) · SHA-256 \(pin.digest)")
                }
                if let executableDigest = activation.executableDigest { print("    executable SHA-256: \(executableDigest)") }
                if let targetBundleID = activation.targetBundleID { print("    target bundle ID: \(targetBundleID) · access: \(activation.accessMode ?? "unknown")") }
                if let proxyPath = activation.proxyExecutablePath { print("    AgentBridge proxy: \(proxyPath) · SHA-256 \(activation.proxyExecutableDigest ?? "unknown")") }
                if !activation.permissions.isEmpty { print("    permissions: \(activation.permissions.joined(separator: ", "))") }
                if !activation.allowedActions.isEmpty { print("    allowed actions/tools: \(activation.allowedActions.joined(separator: ", "))") }
                if !activation.targetScope.isEmpty { print("    target scope: \(activation.targetScope.joined(separator: ", "))") }
                if let disclosure = activation.dataDisclosure { print("    data disclosure: \(OutputRedactor.redact(disclosure))") }
                if let callLimit = activation.maximumToolCallsPerRun,
                   let perResultLimit = activation.maximumToolResponseBytes,
                   let totalLimit = activation.maximumTotalToolResponseBytes {
                    print("    tool response limits: \(callLimit) calls · \(perResultLimit) bytes/result · \(totalLimit) bytes/run")
                }
            }
        }
        print("\nReview digest: \(record.planDigest)")
        print("Inspect all scope and verification details, then approve with: autonomous approve \(record.id.uuidString.lowercased()) --digest \(record.planDigest) --confirm")
    }

    private static func printAutonomousStatus(_ record: AutonomousRunRecord) {
        print("\(record.id.uuidString.lowercased())  \(record.status.rawValue)  digest=\(record.planDigest)")
        print("  Goal: \(OutputRedactor.redact(record.plan.goal))")
        print("  Review round: \(record.currentReviewRound)/\(record.plan.limits.maxReviewRounds) · provider invocations: \(record.providerInvocationsStarted)/\(record.plan.limits.maxProviderInvocations)")
        for progress in record.taskProgress {
            print("  [\(progress.status.rawValue)] \(progress.id): \(OutputRedactor.redact(progress.summary))")
        }
        if let diffDigest = record.diffDigest { print("  Final diff: \(diffDigest) · review: \(record.reviewVerdict?.rawValue ?? "pending") · verification: \(record.verificationPassed.map(String.init) ?? "not run")") }
        if let writerSessionID = record.writerSessionID { print("  Writer session: \(writerSessionID.uuidString.lowercased())") }
        if let resultSummary = record.resultSummary { print("  Result: \(OutputRedactor.redact(resultSummary))") }
        if record.plan.saveRunSummaryToMemory {
            print("  Project memory summary saved: \(record.memorySummarySaved.map(String.init) ?? "pending")")
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data([0x0A]))
    }

    private static func extensionsCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge extensions list|import|grant|revoke ... or extensions runtime ...")
        }
        switch action {
        case "runtime":
            try await activeExtensionsCommand(Array(arguments.dropFirst()), service: service)
        case "list":
            guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("Usage: agentbridge extensions list") }
            for descriptor in try service.extensionDescriptors() {
                print("\(descriptor.kind.rawValue.uppercased()) \(descriptor.id) v\(descriptor.version) — \(descriptor.name)")
                print("  requested: \(descriptor.requestedPermissions.map(\.rawValue).joined(separator: ", "))")
                if !descriptor.summary.isEmpty { print("  \(OutputRedactor.redact(descriptor.summary))") }
            }
            print("Descriptors and grants are policy metadata only; they do not activate or execute extensions.")
        case "import":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge extensions import /path/to/descriptor.json") }
            let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let data = try BoundedDescriptorFileReader.read(at: url)
            let descriptor = try JSONDecoder().decode(ExtensionDescriptor.self, from: data)
            _ = try service.importExtensionDescriptor(descriptor, source: .localMetadata, sourceReference: url.path)
            print("Imported inert descriptor \(descriptor.id). No script was executed; no provider extension was activated.")
        case "grant":
            guard arguments.count >= 5,
                  let sessionID = UUID(uuidString: arguments[1]),
                  arguments.last == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions grant SESSION-ID EXTENSION-ID --permission PERMISSION [--path RELATIVE-PATH] [--host HOST] --confirm")
            }
            let extensionID = arguments[2]
            var permissions: [ExtensionPermission] = []
            var paths: [String] = []
            var hosts: [String] = []
            var index = 3
            while index < arguments.count - 1 {
                let option = arguments[index]
                index += 1
                guard index < arguments.count - 1 else { throw AgentBridgeError.invalidInput("\(option) needs a value.") }
                switch option {
                case "--permission":
                    guard let permission = ExtensionPermission(rawValue: arguments[index]) else {
                        throw AgentBridgeError.invalidInput("Unknown extension permission \(arguments[index]).")
                    }
                    permissions.append(permission)
                case "--path": paths.append(arguments[index])
                case "--host": hosts.append(arguments[index])
                default: throw AgentBridgeError.invalidInput("Unknown extensions grant option \(option).")
                }
                index += 1
            }
            let projectID = try service.extensionProjectID(sessionID: sessionID)
            let grant = try service.grantExtensionPermissions(
                extensionID: extensionID,
                projectID: projectID,
                permissions: permissions,
                allowedRelativePaths: paths,
                allowedHosts: hosts
            )
            print("Saved per-project metadata grant for \(grant.extensionID): \(grant.permissions.map(\.rawValue).joined(separator: ", ")). Extensions remain inactive and are not executed.")
        case "revoke":
            guard arguments.count == 4,
                  let sessionID = UUID(uuidString: arguments[1]),
                  arguments[3] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions revoke SESSION-ID EXTENSION-ID --confirm")
            }
            let projectID = try service.extensionProjectID(sessionID: sessionID)
            _ = try service.revokeExtensionPermissions(extensionID: arguments[2], projectID: projectID)
            print("Revoked the extension permission metadata for this project.")
        default:
            throw AgentBridgeError.invalidInput("Unknown extensions subcommand.")
        }
    }

    private static func activeExtensionsCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime list|import-skill|import-mcp|test|inspect|enable|disable ...")
        }
        switch action {
        case "list":
            guard arguments.count == 1 || (arguments.count == 2 && arguments[1] == "--json") else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime list [--json]")
            }
            let configurations = try service.activeExtensionConfigurations()
            if arguments.last == "--json" {
                let values: [[String: Any]] = configurations.map { configuration in
                    [
                        "id": configuration.id,
                        "kind": configuration.kind.rawValue,
                        "name": configuration.name,
                        "version": configuration.version,
                        "summary": configuration.summary,
                        "sourceReference": configuration.sourceReference,
                        "configurationDigest": configuration.configurationDigest,
                        "skillDigest": configuration.skillDigest.map { $0 as Any } ?? NSNull(),
                        "executablePath": configuration.executablePath.map { $0 as Any } ?? NSNull(),
                        "arguments": configuration.arguments,
                        "entrypointPins": configuration.entrypointPins.map { ["path": $0.path, "digest": $0.digest] },
                        "allowedTools": configuration.allowedTools,
                        "startupTimeoutSeconds": configuration.startupTimeoutSeconds.map { $0 as Any } ?? NSNull(),
                        "toolTimeoutSeconds": configuration.toolTimeoutSeconds.map { $0 as Any } ?? NSNull(),
                        "maximumToolCallsPerRun": configuration.maximumToolCallsPerRun.map { $0 as Any } ?? NSNull(),
                        "maximumToolResponseBytes": configuration.maximumToolResponseBytes.map { $0 as Any } ?? NSNull(),
                        "maximumTotalToolResponseBytes": configuration.maximumTotalToolResponseBytes.map { $0 as Any } ?? NSNull(),
                        "macControlTargetBundleID": configuration.macControlTargetBundleID.map { $0 as Any } ?? NSNull(),
                        "macControlAccessMode": configuration.macControlAccessMode.map { $0.rawValue as Any } ?? NSNull(),
                        "macControlActionNames": configuration.macControlActionNames,
                        "screenCaptureDisclosure": configuration.screenCaptureDisclosure.map { $0 as Any } ?? NSNull()
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            } else if configurations.isEmpty {
                print("No active runtime configurations have been imported.")
            } else {
                for configuration in configurations {
                    print("\(configuration.kind.rawValue.uppercased()) \(configuration.id) v\(configuration.version) — \(configuration.name)")
                    print("  digest: \(configuration.configurationDigest)")
                    print("  source: \(configuration.sourceReference)")
                    if let skillDigest = configuration.skillDigest { print("  Skill SHA-256: \(skillDigest)") }
                    if let executablePath = configuration.executablePath {
                        print("  command: \(executablePath) \(configuration.arguments.map(\.debugDescription).joined(separator: " "))")
                        for pin in configuration.entrypointPins {
                            print("  pinned entrypoint: \(pin.path) · SHA-256 \(pin.digest)")
                        }
                        print("  allowed tools: \(configuration.allowedTools.joined(separator: ", "))")
                    }
                    if let targetBundleID = configuration.macControlTargetBundleID {
                        print("  Mac Control target: \(targetBundleID) · access: \(configuration.macControlAccessMode?.rawValue ?? "unknown")")
                        print("  actions: \(configuration.macControlActionNames.joined(separator: ", "))")
                        if let disclosure = configuration.screenCaptureDisclosure { print("  screen disclosure: \(OutputRedactor.redact(disclosure))") }
                        print("  tool budgets: \(configuration.maximumToolCallsPerRun ?? 0) calls · \(configuration.maximumToolResponseBytes ?? 0) bytes/response · \(configuration.maximumTotalToolResponseBytes ?? 0) bytes total")
                    }
                }
            }
        case "import-skill":
            guard arguments.count >= 2 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime import-skill /path/to/SKILL.md --id ID --name NAME [--version VERSION] [--summary SUMMARY]")
            }
            let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            var identifier: String?
            var name: String?
            var version = "1"
            var summary = ""
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                let value = try nextOptionValue(option, arguments: arguments, index: &index)
                switch option {
                case "--id": identifier = value
                case "--name": name = value
                case "--version": version = value
                case "--summary": summary = value
                default: throw AgentBridgeError.invalidInput("Unknown Skill import option \(option).")
                }
            }
            guard let identifier, let name else {
                throw AgentBridgeError.invalidInput("Skill import requires both --id and --name.")
            }
            let descriptor = try ExtensionDescriptor(id: identifier, kind: .skill, name: name, version: version, summary: summary)
            let snapshot = try service.importSkillRuntime(descriptor: descriptor, sourceReference: url.path, skillFileURL: url)
            print("Imported instructions-only Skill \(snapshot.extensionID) v\(snapshot.version).")
            print("Content SHA-256: \(snapshot.contentDigest)\nConfiguration digest: \(snapshot.configurationDigest)")
            print("Import did not run scripts, hooks, installers, or dependencies. Preview exact instructions and approve a project/provider/profile scope before enabling.")
        case "import-mcp":
            guard arguments.count == 2 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime import-mcp /path/to/mcp-runtime.json")
            }
            let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let configuration = try service.importMCPRuntimeManifest(at: url)
            print("Imported MCP \(configuration.extensionID) v\(configuration.version).")
            print("Command: \(configuration.executablePath) \(configuration.arguments.map(\.debugDescription).joined(separator: " "))")
            print("Allowed tools: \(configuration.allowedTools.joined(separator: ", "))")
            print("Configuration digest: \(configuration.configurationDigest)")
            print("The MCP server has not been started. Test Connection is an explicit action and the process runs with your macOS user permissions.")
        case "test":
            guard arguments.count == 3, arguments[2] == "--confirm-start" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime test EXTENSION-ID --confirm-start (starts the selected MCP process as your macOS user; allowlist is not an OS sandbox)")
            }
            let cancellation = CancellationFlag()
            let signalSources = makeCancellationSignalSources(cancellation)
            defer { signalSources.forEach { $0.cancel() } }
            let inspection = try await service.testMCPRuntime(extensionID: arguments[1], cancellation: cancellation)
            print("MCP initialization and tools/list succeeded for \(inspection.extensionID). No tool was called.")
            print("Configuration digest: \(inspection.configurationDigest)")
            print("Inspection digest: \(inspection.inspectionDigest)")
            print("Tools: \(inspection.toolNames.joined(separator: ", "))")
            print("\n--- Exact MCP tool definitions and input schemas ---\n\(inspection.toolDefinitionsJSON)\n--- End MCP tool definitions ---")
            for diagnostic in inspection.diagnostics { print("  \(OutputRedactor.redact(diagnostic))") }
            print("The exact allowlist must be reviewed and enabled separately for a project/provider/profile.")
        case "mac-control-status":
            let selection = try parseMacControlTargetOptions(Array(arguments.dropFirst()), requiredConfirmation: nil)
            let status = service.macControlPresetStatus(targetBundleID: selection.targetBundleID, accessMode: selection.accessMode)
            print("Mac Control preset status · target \(selection.targetBundleID) · mode \(selection.accessMode.rawValue)")
            print("\(OutputRedactor.redact(status.message))")
            if let path = status.helperPath { print("Fixed helper: \(path)") }
            if let digest = status.helperDigest { print("Helper SHA-256: \(digest)") }
            if let path = status.proxyExecutablePath { print("AgentBridge proxy: \(path)") }
            if let digest = status.proxyExecutableDigest { print("Proxy SHA-256: \(digest)") }
            print("Status detection hashes installed binaries only; it does not start the helper or access the screen.")
        case "mac-control-import":
            let selection = try parseMacControlTargetOptions(Array(arguments.dropFirst()), requiredConfirmation: "--confirm-import")
            let configuration = try service.importMacControlPreset(targetBundleID: selection.targetBundleID, accessMode: selection.accessMode)
            print("Imported typed Mac Control \(selection.accessMode.rawValue) preset \(configuration.extensionID).")
            print("Configuration digest: \(configuration.configurationDigest)")
            print("Target: \(configuration.macControlTargetBundleID ?? "unknown") · actions: \(configuration.macControlActionNames.joined(separator: ", "))")
            if let disclosure = configuration.screenCaptureDisclosure { print("Screen disclosure: \(OutputRedactor.redact(disclosure))") }
            print("Import does not start the helper, capture the screen, or enable input.")
        case "mac-control-test":
            let selection = try parseMacControlTargetOptions(Array(arguments.dropFirst()), requiredConfirmation: "--confirm-start")
            let cancellation = CancellationFlag()
            let signalSources = makeCancellationSignalSources(cancellation)
            defer { signalSources.forEach { $0.cancel() } }
            let readiness = try await service.testMacControlPermissions(targetBundleID: selection.targetBundleID, cancellation: cancellation)
            print("Mac Control permission readiness · target \(readiness.targetBundleID) · checked \(readiness.checkedAt.formatted())")
            print("Helper available: \(readiness.helperAvailable) · status tool available: \(readiness.statusToolAvailable)")
            print(OutputRedactor.redact(readiness.statusText))
            print("This status-only test never captures the screen, sends input, or requests macOS permission. Grant missing permissions manually in System Settings.")
        case "mac-control-stop":
            guard arguments.count == 4,
                  let sessionID = UUID(uuidString: arguments[1]),
                  arguments[3] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime mac-control-stop SESSION-ID EXTENSION-ID --confirm")
            }
            let cancelled = try service.stopMacControl(extensionID: arguments[2], sessionID: sessionID)
            print("Mac Control Control access was revoked for the exact project/provider/profile scope.")
            print("Cancellation requests sent to \(cancelled.count) affected provider session(s).")
        case "inspect":
            guard arguments.count == 3,
                  let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime inspect SESSION-ID EXTENSION-ID")
            }
            let review = try service.previewExtensionActivation(extensionID: arguments[2], sessionID: sessionID)
            print("Extension: \(review.extensionID)")
            print("Scope: project \(review.projectID) · \(review.provider.rawValue) profile \(review.profileID.uuidString.lowercased())")
            print("Configuration digest: \(review.configurationDigest)")
            print("Review digest: \(review.reviewedDigest)")
            if let skillDigest = review.skillDigest {
                print("Skill SHA-256: \(skillDigest)")
                print("\n--- Exact Skill instructions ---\n\(review.instructionText ?? "")\n--- End Skill instructions ---")
            }
            if let executablePath = review.executablePath {
                print("Command: \(executablePath) \(review.arguments.map(\.debugDescription).joined(separator: " "))")
                for pin in review.entrypointPins {
                    print("Pinned entrypoint: \(pin.path) · SHA-256 \(pin.digest)")
                }
                print("Allowed tools: \(review.allowedTools.joined(separator: ", "))")
                print("Tools discovered by Test Connection: \(review.inspectedTools.joined(separator: ", "))")
                if let definitions = review.toolDefinitionsJSON {
                    print("\n--- Exact MCP tool definitions and input schemas ---\n\(definitions)\n--- End MCP tool definitions ---")
                }
            }
            if let targetBundleID = review.macControlTargetBundleID {
                print("Mac Control target: \(targetBundleID) · access mode: \(review.macControlAccessMode?.rawValue ?? "unknown")")
                print("Mac Control actions: \(review.macControlActionNames.joined(separator: ", "))")
            }
            if let calls = review.maximumToolCallsPerRun,
               let response = review.maximumToolResponseBytes,
               let total = review.maximumTotalToolResponseBytes {
                print("Tool budgets: \(calls) calls · \(response) bytes/response · \(total) bytes total")
            }
            if let disclosure = review.screenCaptureDisclosure { print("Screen disclosure: \(OutputRedactor.redact(disclosure))") }
            print("\nTrust notice: \(OutputRedactor.redact(review.trustWarning))")
        case "enable":
            guard arguments.count >= 6,
                  let sessionID = UUID(uuidString: arguments[1]),
                  arguments[3] == "--digest",
                  arguments[5] == "--confirm-execution" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime enable SESSION-ID EXTENSION-ID --digest REVIEW-DIGEST --confirm-execution [--confirm-screen-capture] [--confirm-input-control]")
            }
            let consentFlags = Array(arguments.dropFirst(6))
            guard consentFlags.allSatisfy({ ["--confirm-screen-capture", "--confirm-input-control"].contains($0) }),
                  Set(consentFlags).count == consentFlags.count else {
                throw AgentBridgeError.invalidInput("Unknown or repeated Mac Control consent flag.")
            }
            let configuration = try service.activeExtensionConfigurations().first(where: { $0.id == arguments[2] })
            if configuration?.requiresScreenCaptureConsent == true,
               !consentFlags.contains("--confirm-screen-capture") {
                throw AgentBridgeError.invalidInput("Mac Control requires --confirm-screen-capture after reviewing that full-display screenshots are sent to the selected provider.")
            }
            if configuration?.requiresInputControlConsent == true,
               !consentFlags.contains("--confirm-input-control") {
                throw AgentBridgeError.invalidInput("Control mode requires the separate --confirm-input-control consent.")
            }
            let grant = try service.enableExtensionRuntime(
                extensionID: arguments[2],
                sessionID: sessionID,
                reviewedDigest: arguments[4].lowercased(),
                explicitExecutionConsent: true,
                explicitScreenCaptureConsent: consentFlags.contains("--confirm-screen-capture"),
                explicitInputControlConsent: consentFlags.contains("--confirm-input-control")
            )
            print("Enabled \(grant.extensionID) for project \(grant.projectID), \(grant.provider.rawValue) profile \(grant.profileID.uuidString.lowercased()).")
            print("Existing sessions keep their pinned extension snapshot; create a new session to use this exact approved configuration.")
        case "disable":
            guard arguments.count == 4,
                  let sessionID = UUID(uuidString: arguments[1]),
                  arguments[3] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime disable SESSION-ID EXTENSION-ID --confirm")
            }
            _ = try service.disableExtensionRuntime(extensionID: arguments[2], sessionID: sessionID)
            print("Disabled the extension for the session's exact project/provider/profile scope.")
        case "status":
            guard arguments.count == 2, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime status SESSION-ID")
            }
            let invocation = try service.activeExtensionsForSession(sessionID: sessionID)
            print("Scope: project \(invocation.projectID) · \(invocation.provider.rawValue) profile \(invocation.profileID.uuidString.lowercased())")
            print("Runtime fingerprint: \(invocation.fingerprint)")
            for skill in invocation.skills { print("Skill: \(skill.extensionID) · \(skill.configurationDigest)") }
            for mcp in invocation.mcpServers { print("MCP: \(mcp.extensionID) · \(mcp.configurationDigest) · tools \(mcp.allowedTools.joined(separator: ", "))") }
            if invocation.skills.isEmpty && invocation.mcpServers.isEmpty { print("No runtime extensions are active for this scope.") }
        default:
            throw AgentBridgeError.invalidInput("Unknown extensions runtime action. Use list, import-skill, import-mcp, test, inspect, enable, disable, or status.")
        }
    }

    private static func cancelCommand(_ arguments: [String], service: BridgeService) throws {
        guard arguments.count == 1, let sessionID = UUID(uuidString: arguments[0]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge cancel SESSION-ID")
        }
        try service.cancel(sessionID: sessionID)
        print("Cancellation requested; the running process will exit once it receives the signal.")
    }

    private static func showEvents(_ arguments: [String], service: BridgeService) throws {
        guard arguments.count == 1, let sessionID = UUID(uuidString: arguments[0]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge events SESSION-ID")
        }
        for event in try service.events(sessionID: sessionID) {
            let formatter = ISO8601DateFormatter()
            print("\(formatter.string(from: event.timestamp)) [\(event.kind)] \(event.message)")
        }
    }

    private static func showBudget(service: BridgeService) throws {
        let snapshot = try service.budgetSnapshot()
        print("Month (UTC): \(snapshot.month)")
        print(String(format: "Monthly limit: US$%.2f", snapshot.monthlyLimitUSD))
        print(String(format: "Used: US$%.2f; reserved: US$%.2f; available: US$%.2f", snapshot.usedUSD, snapshot.reservedUSD, snapshot.availableUSD))
        print("The ledger counts only AgentBridge API calls; the final bill is what the provider shows.")
    }

    private static func budgetCommand(_ arguments: [String], service: BridgeService) throws {
        guard arguments.first == "reconcile" else {
            guard arguments.isEmpty else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge budget reconcile SESSION-ID --profile PROFILE-ID (--actual-usd USD | --settle-at-reserved) --confirm")
            }
            try showBudget(service: service)
            return
        }
        let settlesAtReserved = arguments.count == 6 && arguments[4] == "--settle-at-reserved"
        guard arguments.count == 7 || settlesAtReserved,
              let sessionID = UUID(uuidString: arguments[1]),
              arguments[2] == "--profile",
              let profileID = UUID(uuidString: arguments[3]),
              settlesAtReserved || arguments[4] == "--actual-usd",
              arguments.last == "--confirm" else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge budget reconcile SESSION-ID --profile PROFILE-ID (--actual-usd USD | --settle-at-reserved) --confirm")
        }
        let profile = try service.accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
        let actualUSD: Double
        if settlesAtReserved {
            // The full reservation is a conservative stand-in for a bill that
            // is not available yet; it cannot be changed afterwards.
            guard let candidate = try service.unresolvedAPICalls(profileID: profileID)
                .first(where: { $0.session.id == sessionID }) else {
                throw UsageControlError.apiReconciliationNotFound(sessionID)
            }
            actualUSD = candidate.reservedUSD
        } else {
            guard let amount = Double(arguments[5]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge budget reconcile SESSION-ID --profile PROFILE-ID (--actual-usd USD | --settle-at-reserved) --confirm")
            }
            actualUSD = amount
        }
        try service.reconcileAPIUsageFromProviderBill(
            profileID: profileID,
            sessionID: sessionID,
            actualUSD: actualUSD,
            explicitlyConfirmed: true
        )
        if settlesAtReserved {
            print(String(format: "Settled conservatively at the full reserved amount of US$%.6f; it cannot be changed to another amount afterwards.", actualUSD))
        } else {
            print(String(format: "Settled manually at the Anthropic bill amount of US$%.6f that you confirmed.", actualUSD))
        }
        print("Claude Account: \(profile.name) (\(profile.id.uuidString.lowercased()))")
        print("Sessions: \(sessionID.uuidString.lowercased())")
    }

    private static func parseProvider(_ value: String) throws -> AgentProvider {
        guard let provider = AgentProvider(rawValue: value) else {
            throw AgentBridgeError.invalidInput("The provider must be codex, claude or local.")
        }
        return provider
    }

    private static func parseMacControlTargetOptions(
        _ arguments: [String],
        requiredConfirmation: String?
    ) throws -> (targetBundleID: String, accessMode: MacControlAccessMode) {
        var targetBundleID: String?
        var accessMode: MacControlAccessMode = .observe
        var confirmed = false
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            switch option {
            case "--target":
                guard targetBundleID == nil else { throw AgentBridgeError.invalidInput("Only one --target may be supplied.") }
                targetBundleID = try nextOptionValue(option, arguments: arguments, index: &index)
            case "--mode":
                let value = try nextOptionValue(option, arguments: arguments, index: &index)
                guard let parsed = MacControlAccessMode(rawValue: value) else {
                    throw AgentBridgeError.invalidInput("Mac Control mode must be observe or control.")
                }
                accessMode = parsed
            case "--confirm-import", "--confirm-start":
                guard option == requiredConfirmation, !confirmed else {
                    throw AgentBridgeError.invalidInput("Unexpected or repeated confirmation flag \(option).")
                }
                confirmed = true
            default:
                throw AgentBridgeError.invalidInput("Unknown Mac Control option \(option).")
            }
        }
        guard let targetBundleID, !targetBundleID.isEmpty else {
            throw AgentBridgeError.invalidInput("Mac Control commands require --target BUNDLE-ID.")
        }
        if let requiredConfirmation, !confirmed {
            throw AgentBridgeError.invalidInput("This Mac Control action requires \(requiredConfirmation).")
        }
        return (targetBundleID, accessMode)
    }

    private static func readPromptFromStandardInput(maximumBytes: Int) throws -> String {
        try readBoundedStandardInput(maximumBytes: maximumBytes, label: "Prompt")
    }

    private static func readBoundedStandardInput(maximumBytes: Int, label: String) throws -> String {
        guard maximumBytes > 0 else { throw AgentBridgeError.invalidInput("Input byte limit must be positive.") }
        var data = Data()
        while data.count <= maximumBytes {
            let amount = min(65_536, maximumBytes + 1 - data.count)
            guard amount > 0 else { break }
            let chunk = try FileHandle.standardInput.read(upToCount: amount) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw AgentBridgeError.invalidInput("\(label) exceeds its \(maximumBytes)-byte input limit.") }
        guard let text = String(data: data, encoding: .utf8) else { throw AgentBridgeError.invalidInput("\(label) must be UTF-8 text.") }
        return text
    }

    private static func printHelp() {
        print("""
        AgentBridge \(version) — session management for macOS Codex / Claude CLI and Local models

        Commands:
          agentbridge workspace show
          agentbridge workspace set /absolute/path/to/root
          agentbridge chat help
          agentbridge doctor
          agentbridge local settings
          agentbridge local configure --backend ollama|openai-compatible --endpoint URL --model NAME [--context-window TOKENS] [--max-output TOKENS]
          agentbridge local models|test
          agentbridge local preview discussion CHAT-ID|project SESSION-ID < prompt.txt
          agentbridge settings show
          agentbridge settings usage subscription|api
          agentbridge settings binary codex|claude /absolute/path/to/cli|auto
          agentbridge profiles list [codex|claude|local]
          agentbridge profiles create --provider codex|claude|local --name NAME [--share-memory] (shared memory is on by default)
          agentbridge profiles select --provider codex|claude|local PROFILE-ID
          agentbridge profiles memory PROFILE-ID on|off
          agentbridge profile-login PROFILE-ID
          agentbridge session create --provider codex|claude|local --repo PATH [--interactive|--changes]
          agentbridge sessions
          agentbridge run SESSION-ID [--api-budget USD --confirm-api-spend --api-key-env ANTHROPIC_API_KEY]
          agentbridge changes plan SESSION-ID --title TITLE --summary SUMMARY --step STEP [--step STEP ...]
          agentbridge changes approve SESSION-ID PLAN-ID REVIEW-DIGEST
          agentbridge changes run SESSION-ID PLAN-ID REVIEW-DIGEST < prompt.txt
          agentbridge changes diff|restore|restore-all|export|verify|accept|apply ...
          agentbridge tasks [SESSION-ID]
          agentbridge autonomous plan --source REPOSITORY --planner PROVIDER:PROFILE-ID --researcher PROVIDER:PROFILE-ID --implementer PROVIDER:PROFILE-ID --reviewer PROVIDER:PROFILE-ID --share-diff-with-reviewer [--desktop-control-scope TEXT --confirm-desktop-separate-from-git] [--save-summary-to-memory --memory-destination PROFILE-ID] [--verification none|projectCI|custom] < goal.txt
          agentbridge autonomous approve RUN-ID --digest PLAN-DIGEST --confirm
          agentbridge autonomous run RUN-ID --digest PLAN-DIGEST
          agentbridge autonomous status [RUN-ID] --json
          agentbridge autonomous cancel RUN-ID --confirm
          agentbridge extensions list|import|grant|revoke ...
          agentbridge extensions runtime list [--json]
          agentbridge extensions runtime import-skill /path/to/SKILL.md --id ID --name NAME [--version VERSION] [--summary SUMMARY]
          agentbridge extensions runtime import-mcp /path/to/mcp-runtime.json
          agentbridge extensions runtime test EXTENSION-ID --confirm-start
          agentbridge extensions runtime inspect SESSION-ID EXTENSION-ID
          agentbridge extensions runtime enable SESSION-ID EXTENSION-ID --digest REVIEW-DIGEST --confirm-execution [--confirm-screen-capture] [--confirm-input-control]
          agentbridge extensions runtime disable SESSION-ID EXTENSION-ID --confirm
          agentbridge extensions runtime status SESSION-ID
          agentbridge extensions runtime mac-control-status --target APP-BUNDLE-ID [--mode observe|control]
          agentbridge extensions runtime mac-control-import --target APP-BUNDLE-ID [--mode observe|control] --confirm-import
          agentbridge extensions runtime mac-control-test --target APP-BUNDLE-ID --confirm-start
          agentbridge extensions runtime mac-control-stop SESSION-ID EXTENSION-ID --confirm
          agentbridge interactive SESSION-ID [--profile PROFILE-ID]
          agentbridge usage-tui --provider codex|claude --profile PROFILE-ID
          agentbridge memory show SESSION-ID
          agentbridge memory notes SESSION-ID < notes.txt
          agentbridge memory clear SESSION-ID --confirm
          agentbridge memory handoffs SESSION-ID
          agentbridge memory carry-forward SOURCE-SESSION TARGET-SESSION [--turn TURN-ID ...] [--notes]
          agentbridge cancel SESSION-ID
          agentbridge events SESSION-ID
          agentbridge budget
          agentbridge budget reconcile SESSION-ID --profile PROFILE-ID --actual-usd USD --confirm
          agentbridge budget reconcile SESSION-ID --profile PROFILE-ID --settle-at-reserved --confirm

        `run` reads up to 256 KiB of prompt text from standard input and never puts the prompt in process arguments or the audit file.
        Local models support chats and read-only project chats only; local sessions offer no autonomy, editing tools, interactive Terminal, Skills or MCP. Local uses no API key, no official CLI sign-in and no cloud fallback.
        `autonomous plan` immediately starts one real planning request to the official CLI subscription model; the goal is read from standard input, up to 8,000 bytes. Every role and the planner must name a provider and a profile UUID explicitly, for example `--planner codex:00000000-0000-0000-0000-000000000001`. Claude API mode is not used for autonomous workflows.
        The plan command saves an immutable plan that is not yet approved. Review the roles, extensions, file scope, limits and verification settings in full, then approve with `autonomous approve RUN-ID --digest PLAN-DIGEST --confirm`; a single approval covers only the revision rounds and verification in that plan. Running requires the exact same `--digest` again. `status --json` lets automation read session progress, review results and verification status; an interrupted run is never replayed automatically.
        Sharing output across accounts needs both the source and the receiving profile to allow shared memory. By default the content of a dependency task is not handed to the next role; the exact implementation diff always needs an explicit `--share-diff-with-reviewer`, and both the implementer and reviewer profiles must agree to shared memory.
        To use Mac Control in Control mode, the plan command must include `--desktop-control-scope` and `--confirm-desktop-separate-from-git`; only the implementer role can select Control. Both are included in the immutable plan digest.
        `--save-summary-to-memory --memory-destination PROFILE-ID` is a separate explicit consent; the destination profile must be an account bound to this plan that allows shared memory. Without it, no result summary is saved.
        Example: `agentbridge autonomous plan --source /work/repo --planner codex:00000000-0000-0000-0000-000000000001 --researcher claude:00000000-0000-0000-0000-000000000002 --implementer codex:00000000-0000-0000-0000-000000000001 --reviewer claude:00000000-0000-0000-0000-000000000002 --share-diff-with-reviewer --verification projectCI < goal.txt`
        `autonomous status --json` only prints the run state AgentBridge saved; it does not call a model or resume interrupted work.
        `budget reconcile` only settles a stopped Claude API session by hand: check the Anthropic bill first, then enter the actual dollar amount and pass `--confirm` explicitly. It does not call the provider, and retrying with the same amount is safe. If the bill is not shown yet, use `--settle-at-reserved` to settle conservatively at the full reserved amount; it cannot be changed to another amount afterwards.
        API mode needs `usage api` selected first, and each run must supply a limit, an environment variable name and an explicit confirmation.
        usage-tui starts the native CLI only when the selected provider account uses a subscription sign-in; after sign-in finishes and an input prompt appears, the App's fixed button sends /usage. This screen is not parsed or stored by AgentBridge.
        Custom accounts have their own provider config folders; create the profile, then run profile-login in an interactive Terminal.
        `session create --interactive` creates an isolated Codex or Claude Terminal workspace, still subject to manual approval and the bound account.
        `session create --changes` creates a subscription-mode isolated-changes session that is read-only by default; save and review a plan, then retype its digest in the approve command before anything can run.
        `changes verify` runs .codex/ci.sh only when you call it explicitly. Custom verification needs `--approve-custom` and passes separate argv values with repeated `--arg`; nothing goes through a shell.
        `changes accept` and `changes apply` both require the current diff to be verified successfully. Apply only creates an uncommitted isolated worktree on a local branch and refuses if the source base differs; it never commits, pushes or merges.
        `memory carry-forward` copies only the explicitly selected App memory turns/notes to another commit of the same repository and requires the target's bound account to allow shared memory; native TUI conversations are not imported.
        The older `extensions import` reads inert metadata JSON only. Those older grants never enable a Skill or MCP. `runtime import-skill` snapshots at most 64 KiB of SKILL.md instruction text; `runtime import-mcp` reads a bounded JSON manifest with an absolute `command`, a separate `args` array and `allowedTools`, and starts no process.
        `runtime test` needs `--confirm-start` and starts the selected MCP with the current macOS user's permissions, running only initialize and tools/list; it never calls an MCP tool or a model. The allowed-tools list only limits which tools the agent can pick; it is not an operating-system sandbox. First use `runtime inspect` to review the full configuration, Skill content or discovered tools and the digest, then enable it for the chosen session's project/provider/account profile with the exact same `--digest` and `--confirm-execution`. Older metadata grants have no effect; after any configuration change you must test and review again.
        Mac Control uses only AgentBridge's built-in typed proxy and the fixed installed helper. `mac-control-test` needs `--confirm-start` and only calls `mac_status` to read the permission state; it takes no screenshot, sends no input and never requests TCC automatically. If a macOS permission is missing, turn it on manually in System Settings. Enabling requires an explicit `--confirm-screen-capture` after you review the digest; Control mode also needs a separate `--confirm-input-control`. A full main-screen screenshot may include other windows, is sent to the selected provider and cannot be redacted as text; the target-app restriction applies to input only and does not crop screenshots. `mac-control-stop` revokes that scope's Control grant and cancels the affected provider sessions.
        New accounts have shared memory on by default; `--share-memory` can be used as an explicit on switch. Read-only chat turns in the App and CLI can be shared between account profiles that allow shared memory; user input and output in a native Terminal are not captured.
        `memory show/notes/clear` manage only the memory the App saved for the same project and commit; clear needs `--confirm`.
        `chat help` shows pre-project chat, the explicit shared-content preview and the digest-confirmed create/link commands.
        New sessions live in workspaces/<session-id> under the selected data root; shared memory lives in shared-memory. Before first use, choose a data root in the App or run `agentbridge workspace set /absolute/path/to/root`.
        """)
    }
}
