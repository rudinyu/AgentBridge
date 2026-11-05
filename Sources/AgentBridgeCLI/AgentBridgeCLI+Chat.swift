import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func chatCommand(_ arguments: [String], service: BridgeService) async throws {
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

    static func chatProjectCommand(_ arguments: [String], service: BridgeService) async throws {
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

    static func printChatHelp() {
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
}
