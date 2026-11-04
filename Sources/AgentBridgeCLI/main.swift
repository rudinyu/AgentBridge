import Darwin
import Foundation
import AgentBridgeCore

@main
enum AgentBridgeCLI {
    private static let version = "0.10.0"

    static func main() async {
        do {
            try await dispatch(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("錯誤：\(OutputRedactor.redact(error.localizedDescription))\n".utf8))
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
            throw AgentBridgeError.invalidInput("不認識的命令 \(command)。使用 `agentbridge help` 查看用法。")
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

    private static func doctor(service: BridgeService) async throws {
        print("AgentBridge \(version)")
        let settings = try service.settings()
        if settings.defaultProvider == .local {
            print("目前預設：Local model（不使用 API 金鑰或訂閱用量）")
        } else {
            print("登入模式：\(settings.usageMode == .subscription ? "官方 CLI 訂閱登入" : "Claude API（每次執行需單次預算與確認）")")
        }
        for provider in AgentProvider.allCases {
            if provider == .local {
                let profile = try service.selectedAccountProfile(provider: .local)
                print("local（\(profile.name)）：\(settings.localModel.backend.rawValue) · \(settings.localModel.model.isEmpty ? "尚未選擇模型" : settings.localModel.model)")
                print("  Endpoint：\(settings.localModel.endpoint)")
                print("  本機模型狀態不會在 doctor 中連線檢查；請明確執行 `agentbridge local test`。")
                continue
            }
            do {
                let executable = try RuntimeEnvironment.resolveExecutable(provider: provider, configuredPath: settings.binaryPath(for: provider))
                let profile = try service.selectedAccountProfile(provider: provider)
                let assessment = try await service.checkAuthentication(provider: provider, profileID: profile.id)
                print("\(provider.rawValue)（\(profile.name)）：\(executable.path)")
                if let accountLabel = assessment.accountLabel { print("  帳戶：\(accountLabel)") }
                if let planName = assessment.planName { print("  方案：\(planName)") }
                print("  \(assessment.message)")
            } catch let error as AgentBridgeError {
                if case .missingExecutable = error { print("\(provider.rawValue): 找不到 CLI") }
                else { print("\(provider.rawValue): \(error.localizedDescription)") }
            }
        }
        if settings.defaultProvider == .claude && settings.usageMode == .api {
            do {
                let snapshot = try service.budgetSnapshot()
                print(String(format: "Claude API 月度帳本（UTC 月）：已用 US$%.2f，暫留 US$%.2f，可用 US$%.2f。", snapshot.usedUSD, snapshot.reservedUSD, snapshot.availableUSD))
            } catch UsageControlError.apiMonthlyLimitRequired {
                print("目前選取的 Claude 帳戶尚未設定本機 API 月上限；設定前不會啟用 API 執行。")
            }
        }
    }

    private static func workspaceCommand(_ arguments: [String]) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("用法：agentbridge workspace show|set /absolute/path/to/root")
        }
        switch action {
        case "show":
            guard arguments.count == 1 else {
                throw AgentBridgeError.invalidInput("用法：agentbridge workspace show")
            }
            let privateRoot = try RuntimePaths.applicationSupportRoot()
            if let configuration = try WorkspaceRootConfigurationStore.load(privateRootURL: privateRoot) {
                print(configuration.selectedRootURL.path)
            } else {
                print("尚未設定工作區資料根目錄。請在 App 選擇資料夾，或執行：agentbridge workspace set /absolute/path/to/root")
            }
        case "set":
            guard arguments.count == 2 else {
                throw AgentBridgeError.invalidInput("用法：agentbridge workspace set /absolute/path/to/root")
            }
            guard arguments[1].hasPrefix("/") else {
                throw AgentBridgeError.invalidInput("請提供絕對路徑，例如 `agentbridge workspace set /Users/you/AgentBridgeData`。")
            }
            let requested = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let privateRoot = try RuntimePaths.applicationSupportRoot()
            let selected = try await WorkspaceRootCoordinator.changeRoot(to: requested, privateRootURL: privateRoot)
            print("已設定工作區資料根目錄：\(selected.path)")
        default:
            throw AgentBridgeError.invalidInput("不認識的 workspace 子命令；用法：agentbridge workspace show|set /absolute/path/to/root")
        }
    }

    private static func chatCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else { printChatHelp(); return }
        switch action {
        case "help", "--help", "-h":
            guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("用法：agentbridge chat help") }
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
                    guard provider == nil else { throw AgentBridgeError.invalidInput("--provider 不可重複。") }
                    provider = try parseProvider(nextOptionValue(option, arguments: arguments, index: &index))
                case "--profile":
                    guard profileID == nil else { throw AgentBridgeError.invalidInput("--profile 不可重複。") }
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let parsed = UUID(uuidString: value) else { throw AgentBridgeError.invalidInput("--profile 需要有效的設定檔 UUID。") }
                    profileID = parsed
                default:
                    throw AgentBridgeError.invalidInput("不認識的 chat new 選項 \(option)。")
                }
            }
            guard let provider else { throw AgentBridgeError.invalidInput("用法：agentbridge chat new --provider codex|claude|local [--profile PROFILE-ID]") }
            let resolvedProfileID: UUID
            if let profileID {
                resolvedProfileID = profileID
            } else {
                resolvedProfileID = try service.selectedAccountProfile(provider: provider).id
            }
            let discussion = try service.createDiscussion(provider: provider, accountProfileID: resolvedProfileID)
            print("已建立討論：\(discussion.id.uuidString.lowercased())")
            print("供應商：\(discussion.provider.rawValue) · 設定檔：\(discussion.accountProfileID.uuidString.lowercased())")
            print("資料根目錄：\(discussion.dataRootPath)")
            print("此討論不需要 Git repository；建立或連結專案時才需要指定目的地。")
        case "list":
            guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("用法：agentbridge chat list") }
            let discussions = try service.discussions()
            if discussions.isEmpty { print("尚無討論。"); return }
            for discussion in discussions {
                print("\(discussion.id.uuidString.lowercased())  \(discussion.provider.rawValue)  \(discussion.status.rawValue)  turns=\(discussion.turns.count)  linked=\(discussion.linkedSessionIDs.count)")
                print("  設定檔：\(discussion.accountProfileID.uuidString.lowercased()) · 更新：\(discussion.updatedAt)")
            }
        case "show":
            guard arguments.count == 2, let discussionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge chat show CHAT-ID")
            }
            let discussion = try service.discussion(id: discussionID)
            print("討論：\(discussion.id.uuidString.lowercased())")
            print("狀態：\(discussion.status.rawValue) · Revision：\(discussion.revision)")
            print("目標：\(discussion.provider.rawValue) · 設定檔：\(discussion.accountProfileID.uuidString.lowercased())")
            print("建立：\(discussion.createdAt) · 更新：\(discussion.updatedAt)")
            if discussion.transcriptWasTruncated { print("注意：保存的對話內容曾依儲存上限截短。") }
            if !discussion.linkedSessionIDs.isEmpty {
                print("連結工作階段：\(discussion.linkedSessionIDs.map { $0.uuidString.lowercased() }.joined(separator: ", "))")
            }
            for turn in discussion.turns {
                print("\n[回合 \(turn.id.uuidString.lowercased()) · \(turn.provider.rawValue) · \(turn.timestamp)]")
                print("共享標記：\(turn.isShareable ? "允許" : "排除") · 來源帳戶同意：\(turn.sourceSharedMemoryConsent ? "是" : "否") · 交接仍需目標帳戶同意")
                print("使用者（完整文字）：\(String(reflecting: OutputRedactor.redact(turn.userText)))")
                if let assistantText = turn.assistantText {
                    print("助理（完整文字）：\(String(reflecting: OutputRedactor.redact(assistantText)))")
                } else {
                    print("助理：尚無完成回覆。")
                }
            }
        case "target":
            guard arguments.count >= 2, let discussionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge chat target CHAT-ID --provider codex|claude|local --profile PROFILE-ID")
            }
            var provider: AgentProvider?
            var profileID: UUID?
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                switch option {
                case "--provider":
                    guard provider == nil else { throw AgentBridgeError.invalidInput("--provider 不可重複。") }
                    provider = try parseProvider(nextOptionValue(option, arguments: arguments, index: &index))
                case "--profile":
                    guard profileID == nil else { throw AgentBridgeError.invalidInput("--profile 不可重複。") }
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let parsed = UUID(uuidString: value) else { throw AgentBridgeError.invalidInput("--profile 需要有效的設定檔 UUID。") }
                    profileID = parsed
                default:
                    throw AgentBridgeError.invalidInput("不認識的 chat target 選項 \(option)。")
                }
            }
            guard let provider, let profileID else {
                throw AgentBridgeError.invalidInput("用法：agentbridge chat target CHAT-ID --provider codex|claude|local --profile PROFILE-ID")
            }
            let discussion = try service.setDiscussionTarget(id: discussionID, provider: provider, accountProfileID: profileID)
            print("已更新討論目標：\(discussion.provider.rawValue) · \(discussion.accountProfileID.uuidString.lowercased())")
        case "send":
            guard arguments.count >= 2, let discussionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge chat send CHAT-ID [--share|--no-share] < prompt.txt")
            }
            var isShareable = true
            var sharingOptionWasSet = false
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                guard !sharingOptionWasSet, (option == "--share" || option == "--no-share") else {
                    throw AgentBridgeError.invalidInput("chat send 只接受一次 --share 或 --no-share；提示文字必須從標準輸入讀取。")
                }
                sharingOptionWasSet = true
                isShareable = option == "--share"
                index += 1
            }
            let prompt = try readPromptFromStandardInput(maximumBytes: DiscussionStore.maximumTextBytes)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentBridgeError.invalidInput("提示文字不可為空。")
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
                throw AgentBridgeError.invalidInput("用法：agentbridge chat cancel CHAT-ID")
            }
            try service.cancelDiscussion(id: discussionID)
            print("已送出討論取消要求：\(discussionID.uuidString.lowercased())")
        case "project":
            try await chatProjectCommand(Array(arguments.dropFirst()), service: service)
        default:
            throw AgentBridgeError.invalidInput("不認識的 chat 子命令 \(action)。使用 `agentbridge chat help` 查看用法。")
        }
    }

    private static func chatProjectCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("用法：agentbridge chat project preview|apply ...")
        }
        switch action {
        case "preview":
            guard arguments.count >= 2, let discussionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge chat project preview CHAT-ID --mode new|existing --path /absolute/path --provider codex|claude|local --profile PROFILE-ID [--access read-only|changes] [--turn TURN-ID ... | --no-context]")
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
                    guard mode == nil else { throw AgentBridgeError.invalidInput("--mode 不可重複。") }
                    switch try nextOptionValue(option, arguments: arguments, index: &index) {
                    case "new": mode = .createNew
                    case "existing": mode = .attachExisting
                    default: throw AgentBridgeError.invalidInput("--mode 必須是 new 或 existing。")
                    }
                case "--path":
                    guard destinationPath == nil else { throw AgentBridgeError.invalidInput("--path 不可重複。") }
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard value.hasPrefix("/"), !value.contains("\0") else {
                        throw AgentBridgeError.invalidInput("--path 必須是絕對本機路徑。")
                    }
                    destinationPath = value
                case "--provider":
                    guard provider == nil else { throw AgentBridgeError.invalidInput("--provider 不可重複。") }
                    provider = try parseProvider(nextOptionValue(option, arguments: arguments, index: &index))
                case "--profile":
                    guard profileID == nil else { throw AgentBridgeError.invalidInput("--profile 不可重複。") }
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let parsed = UUID(uuidString: value) else { throw AgentBridgeError.invalidInput("--profile 需要有效的設定檔 UUID。") }
                    profileID = parsed
                case "--access":
                    guard !accessModeWasSet else { throw AgentBridgeError.invalidInput("--access 不可重複。") }
                    accessModeWasSet = true
                    switch try nextOptionValue(option, arguments: arguments, index: &index) {
                    case "read-only": accessMode = .readOnly
                    case "changes": accessMode = .isolatedChanges
                    default: throw AgentBridgeError.invalidInput("--access 必須是 read-only 或 changes。")
                    }
                case "--turn":
                    guard !noContext else { throw AgentBridgeError.invalidInput("--no-context 與 --turn 互斥。") }
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let id = UUID(uuidString: value) else { throw AgentBridgeError.invalidInput("--turn 需要有效的回合 UUID。") }
                    var selected = selectedTurnIDs ?? []
                    guard selected.insert(id).inserted else { throw AgentBridgeError.invalidInput("同一個 --turn 不可重複。") }
                    selectedTurnIDs = selected
                case "--no-context":
                    guard !noContext, selectedTurnIDs == nil else { throw AgentBridgeError.invalidInput("--no-context 與 --turn 互斥，且不可重複。") }
                    noContext = true
                    selectedTurnIDs = []
                default:
                    throw AgentBridgeError.invalidInput("不認識的 chat project preview 選項 \(option)。")
                }
            }
            guard let mode, let destinationPath, let provider, let profileID else {
                throw AgentBridgeError.invalidInput("請指定 --mode、--path、--provider 與 --profile。")
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
            print("專案交接預覽：\(handoff.id.uuidString.lowercased())")
            print("來源討論：\(handoff.discussionID.uuidString.lowercased()) · revision \(handoff.discussionRevision)")
            print("目的地：\(handoff.destinationPath)")
            print("模式：\(handoff.mode == .createNew ? "建立新 Git 專案" : "連結既有 Git 專案")")
            if handoff.mode == .createNew {
                print("初始 Git 提交：建立空樹提交；聊天內容不會進入 Git 歷史。套用時僅上列核准內容匯入 AgentBridge 記憶。")
            } else if let expectedCommit = handoff.expectedRepositoryCommit {
                print("既有 repository HEAD：\(expectedCommit)")
            }
            print("目標：\(handoff.targetProvider.rawValue) · \(handoff.targetProfileID.uuidString.lowercased())")
            let accessDescription: String
            switch handoff.accessMode {
            case .readOnly: accessDescription = "唯讀"
            case .interactiveManualApproval: accessDescription = "互動手動核准"
            case .isolatedChanges: accessDescription = "隔離變更（計畫核准）"
            }
            print("工作階段權限：\(accessDescription)")
            print("選取的共享內容：\(handoff.selectedTurns.count) 個回合")
            for turn in handoff.selectedTurns {
                print("\n[回合 \(turn.id.uuidString.lowercased()) · \(turn.provider.rawValue) · \(turn.timestamp)]")
                print("來源設定檔：\(turn.sourceAccountProfileID.uuidString.lowercased())")
                print("使用者（完整文字）：\(String(reflecting: turn.userText))")
                print("助理（完整文字）：\(String(reflecting: turn.assistantText))")
            }
            print("檢視摘要：\(handoff.reviewedDigest)")
            print("套用時只會把上列核准內容複製到目的工作階段的 AgentBridge 記憶；原始討論保持不變。")
            print("預覽不會建立專案或工作階段。檢視上述全部內容後，才執行：")
            print("agentbridge chat project apply \(handoff.id.uuidString.lowercased()) --digest \(handoff.reviewedDigest) --confirm")
        case "apply":
            guard arguments.count >= 2, let handoffID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge chat project apply HANDOFF-ID --digest REVIEW-DIGEST --confirm")
            }
            var reviewedDigest: String?
            var confirmed = false
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                switch option {
                case "--digest":
                    guard reviewedDigest == nil else { throw AgentBridgeError.invalidInput("--digest 不可重複。") }
                    reviewedDigest = try nextOptionValue(option, arguments: arguments, index: &index)
                case "--confirm":
                    guard !confirmed else { throw AgentBridgeError.invalidInput("--confirm 不可重複。") }
                    confirmed = true
                default:
                    throw AgentBridgeError.invalidInput("不認識的 chat project apply 選項 \(option)。")
                }
            }
            guard let reviewedDigest, confirmed else {
                throw AgentBridgeError.invalidInput("apply 需要 --digest REVIEW-DIGEST 與明確的 --confirm。")
            }
            let session = try await service.createOrAttachProjectFromDiscussion(
                handoffID: handoffID,
                reviewedDigest: reviewedDigest,
                explicitConfirmation: true
            )
            print("已依已檢視的交接建立工作階段：\(session.id.uuidString.lowercased())")
            print("工作目錄：\(session.workspacePath)")
            print("固定提交：\(session.snapshotCommit)")
            print("對話已保留於原討論；不會推送或遠端建立專案。")
        default:
            throw AgentBridgeError.invalidInput("不認識的 chat project 子命令 \(action)。使用 `agentbridge chat help` 查看用法。")
        }
    }

    private static func localModelCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("用法：agentbridge local settings|configure|models|test|preview discussion|project …")
        }
        switch action {
        case "settings", "current":
            guard arguments.count == 1 else {
                throw AgentBridgeError.invalidInput("用法：agentbridge local settings")
            }
            let bridgeSettings = try service.settings()
            let profile = try service.selectedAccountProfile(provider: .local)
            let local = bridgeSettings.localModel
            print("模式：Local model（不使用 API 金鑰或訂閱用量）")
            print("本機帳戶：\(profile.name) · \(profile.id.uuidString.lowercased())")
            print("共享記憶：\(profile.allowsSharedMemory ? "已允許" : "未允許")")
            print("Backend：\(localBackendName(local.backend))")
            print("Endpoint：\(local.endpoint)")
            print("Model：\(local.model.isEmpty ? "尚未設定" : local.model)")
            print("Context window：\(local.contextWindowTokens) tokens")
            print("Output reserve：\(local.maxOutputTokens) tokens")
        case "configure":
            guard arguments.count > 1 else {
                throw AgentBridgeError.invalidInput("用法：agentbridge local configure --backend ollama|openai-compatible --endpoint URL --model NAME [--context-window TOKENS] [--max-output TOKENS]")
            }
            var bridgeSettings = try service.settings()
            var local = bridgeSettings.localModel
            var seen = Set<String>()
            var index = 1
            while index < arguments.count {
                let option = arguments[index]
                guard seen.insert(option).inserted else {
                    throw AgentBridgeError.invalidInput("\(option) 不可重複。")
                }
                index += 1
                switch option {
                case "--backend":
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    switch value {
                    case "ollama": local.backend = .ollama
                    case "openai-compatible": local.backend = .openAICompatible
                    default: throw AgentBridgeError.invalidInput("--backend 必須是 ollama 或 openai-compatible。")
                    }
                case "--endpoint":
                    local.endpoint = try nextOptionValue(option, arguments: arguments, index: &index)
                case "--model":
                    local.model = try nextOptionValue(option, arguments: arguments, index: &index)
                case "--context-window":
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let parsed = Int(value), parsed > 0 else {
                        throw AgentBridgeError.invalidInput("--context-window 必須是正整數 token 數。")
                    }
                    local.contextWindowTokens = parsed
                case "--max-output":
                    let value = try nextOptionValue(option, arguments: arguments, index: &index)
                    guard let parsed = Int(value), parsed > 0 else {
                        throw AgentBridgeError.invalidInput("--max-output 必須是正整數 token 數。")
                    }
                    local.maxOutputTokens = parsed
                case "--api-key", "--api-key-env":
                    throw AgentBridgeError.invalidInput("Local models do not use API keys. This option is unsupported.")
                default:
                    throw AgentBridgeError.invalidInput("不認識的 local configure 選項 \(option)。")
                }
            }
            guard (1_024...131_072).contains(local.contextWindowTokens),
                  (1...32_768).contains(local.maxOutputTokens),
                  local.contextWindowTokens - local.maxOutputTokens > 512 else {
                throw AgentBridgeError.invalidInput("上下文視窗須為 1,024–131,072 個 token，輸出保留量須為 1–32,768 個 token，且輸出保留量之外至少須剩下 513 個 token供輸入與安全餘裕使用。")
            }
            bridgeSettings.localModel = local
            try service.saveSettings(bridgeSettings)
            print("已儲存本機模型設定。AgentBridge 不會自動啟動服務、下載模型或改用雲端服務。")
            print("使用 `agentbridge local test` 明確測試連線，或使用 `agentbridge local models` 更新模型清單。")
        case "models":
            guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("用法：agentbridge local models") }
            let settings = try service.settings().localModel
            let models = try await service.localModels(settings: settings)
            if models.isEmpty {
                print("此 endpoint 沒有可用模型：\(settings.endpoint)")
                print("請自行啟動 Ollama 或 LM Studio，並先在該應用程式中準備模型；AgentBridge 不會下載或啟動服務。")
                return
            }
            for model in models {
                let context = model.contextWindowTokens.map { " · context \($0)" } ?? ""
                print("\(model.id) · \(model.name)\(context)")
            }
        case "test":
            guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("用法：agentbridge local test") }
            let settings = try service.settings().localModel
            let ready = try await service.testLocalModelConnection(settings: settings)
            if ready {
                print("本機模型連線成功：\(settings.model) · \(settings.endpoint)")
            } else {
                print("本機模型尚未就緒：\(settings.endpoint)。請確認本機服務已由你啟動，並選擇可用模型。")
            }
        case "preview":
            guard arguments.count == 3 else {
                throw AgentBridgeError.invalidInput("用法：agentbridge local preview discussion CHAT-ID|project SESSION-ID < prompt.txt")
            }
            let target = arguments[1]
            guard let id = UUID(uuidString: arguments[2]) else {
                throw AgentBridgeError.invalidInput("預覽需要有效的聊天或工作階段 UUID。")
            }
            let promptLimit = target == "project" ? 256 * 1_024 : DiscussionStore.maximumTextBytes
            let prompt = try readPromptFromStandardInput(maximumBytes: promptLimit)
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentBridgeError.invalidInput("提示文字不可為空。")
            }
            let settings = try service.settings().localModel
            let preview: ContextCompressionPreview
            switch target {
            case "discussion":
                preview = try service.previewDiscussionContext(id: id, currentPrompt: prompt, settings: settings)
            case "project":
                preview = try service.previewProjectContext(sessionID: id, currentPrompt: prompt, settings: settings)
            default:
                throw AgentBridgeError.invalidInput("預覽目標必須是 discussion 或 project。")
            }
            printContextCompressionPreview(preview, settings: settings)
        default:
            throw AgentBridgeError.invalidInput("不認識的 local 子命令 \(action)。用法：agentbridge local settings|configure|models|test|preview …")
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
        print("本機上下文預覽")
        print("位元組（原始／預計傳送）：\(report.originalInputBytes) / \(report.sentBytes)")
        print("依 UTF-8 位元組估算的輸入：約 \(estimatedTokens) 個 token；不是精確 tokenizer 計數。")
        print("估計輸入預算：約 \(estimatedBudget) 個 token（輸出保留 \(settings.maxOutputTokens)，另留 512 個 token 安全餘裕）；這是位元組代理估算，不是精確 tokenizer 計數。")
        print("回合：來源 \(report.originalTurnCount) · 近期原文 \(report.recentVerbatimCount) · 省略 \(report.omittedTurnCount) · 歷史摘錄來源 \(report.excerptSourceIDs.count)")
        if report.refusalReason != nil {
            print("需要調整後才能傳送：完整目前提示、釘選筆記與受保護的歷史內容無法安全放入可用預算。請縮短提示或筆記，或提高本機模型上下文視窗；不會傳送請求。")
        } else if preview.requiresReview {
            print("上下文需要調整後才能傳送；請先修改提示或設定預算。")
        } else {
            print(report.compressionApplied
                ? "已自動套用安全的易讀上下文壓縮。"
                : "完整上下文已保留，不需要壓縮。")
        }
        print("預覽摘要（僅供判斷是否過期，不是核准權杖）：\(preview.previewDigest)")
        if let compressedPrompt = preview.compressedPrompt {
            print("\n--- 預計傳送的上下文 ---\n\(compressedPrompt)\n--- 上下文結束 ---")
        } else {
            print("\n未組成供應商提示內容；上下文無法安全表示前會阻止傳送。")
            for section in preview.sections {
                print("\n--- \(section.title) ---")
                if !section.sourceIDs.isEmpty { print("來源：\(section.sourceIDs.joined(separator: ", "))") }
                print(section.text)
            }
            if preview.sections.isEmpty, let refusalReason = report.refusalReason {
                print("Protected context: \(refusalReason)")
            }
        }
    }

    private static func printChatHelp() {
        print("""
        用法：agentbridge chat <子命令>

          agentbridge chat new --provider codex|claude|local [--profile PROFILE-ID]
          agentbridge chat list
          agentbridge chat show CHAT-ID
          agentbridge chat target CHAT-ID --provider codex|claude|local --profile PROFILE-ID
          agentbridge chat send CHAT-ID [--share|--no-share] < prompt.txt
          agentbridge chat cancel CHAT-ID
          agentbridge chat project preview CHAT-ID --mode new|existing --path /absolute/path --provider codex|claude|local --profile PROFILE-ID [--access read-only|changes] [--turn TURN-ID ... | --no-context]
          agentbridge chat project apply HANDOFF-ID --digest REVIEW-DIGEST --confirm

        `chat new` 需要已選取的使用者資料根目錄，不需要 Git repository。`chat send` 只從標準輸入讀取 UTF-8 提示文字，最多 \(DiscussionStore.maximumTextBytes) 位元組；提示不會放在程序參數中。回合預設可供後續共享上下文與交接使用，`--share` 是明確別名；`--no-share` 仍保留回合於討論逐字稿，但排除於後續上下文與交接。來源或目標帳戶未允許共享記憶時，該同意設定會阻止回合進入共享上下文。專案預覽省略 `--turn` 與 `--no-context` 時會選取全部符合共享同意的完整回合；重複指定 `--turn` 會只選列出的回合，不符合資格的回合會讓預覽失敗；`--no-context` 明確不轉移任何回合，且不能和 `--turn` 並用。`--access` 預設唯讀。新專案先建立不含聊天內容的空 Git 初始提交；apply 只會把預覽列出的核准內容複製到目的工作階段的 AgentBridge 記憶，原始討論仍保留。預覽完成前不會建立或連結專案；apply 必須帶預覽摘要與 `--confirm`。不會呼叫遠端 Git 或 push。
        Codex 與 Claude 聊天只使用綁定的官方 CLI 訂閱登入；Local 聊天只連到明確設定的本機模型。Local 專案工作階段固定為唯讀。聊天不提供 API 金鑰/預算參數，也沒有 API credits 回退路徑。
        `chat new --profile`、`chat target` 與 `project preview` 可使用已設定的相符供應商帳戶；省略新討論的 `--profile` 時會沿用該供應商目前選取的帳戶。

        本機模型設定、模型清單與連線測試：`agentbridge local settings|configure|models|test`。只有 `models` 與 `test` 會在你明確執行時連線到設定的本機 endpoint；AgentBridge 不會安裝、啟動服務或下載模型。`agentbridge local preview discussion CHAT-ID|project SESSION-ID < prompt.txt` 會顯示實際上下文、壓縮摘要與 byte/token 估算。
        """)
    }

    private static func settingsCommand(_ arguments: [String], service: BridgeService) throws {
        guard let subcommand = arguments.first else { throw AgentBridgeError.invalidInput("請指定 settings show、usage 或 binary。") }
        switch subcommand {
        case "show":
            let settings = try service.settings()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            print(String(decoding: data, as: UTF8.self))
        case "usage":
            guard arguments.count == 2, let mode = UsageMode(rawValue: arguments[1]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge settings usage subscription|api")
            }
            var settings = try service.settings()
            settings.usageMode = mode
            try service.saveSettings(settings)
            print("已設定使用模式：\(mode.rawValue)。執行 API 前仍須提供單次預算並明確確認。")
        case "binary":
            guard arguments.count == 3,
                  let provider = AgentProvider(rawValue: arguments[1]),
                  provider != .local else {
                throw AgentBridgeError.invalidInput("用法：agentbridge settings binary codex|claude /absolute/path/to/cli|auto")
            }
            var settings = try service.settings()
            let path = arguments[2] == "auto" ? nil : arguments[2]
            settings.setBinaryPath(path, for: provider)
            try service.saveSettings(settings)
            print("已更新 \(provider.rawValue) CLI 路徑。")
        default:
            throw AgentBridgeError.invalidInput("不認識的 settings 子命令。")
        }
    }

    private static func listSessions(service: BridgeService) throws {
        let sessions = try service.sessions()
        if sessions.isEmpty { print("尚無工作階段。"); return }
        for session in sessions {
            let mode: String
            switch session.policy.accessMode {
            case .readOnly: mode = "唯讀"
            case .interactiveManualApproval: mode = "互動手動核准"
            case .isolatedChanges: mode = "隔離變更（計畫核准）"
            }
            print("\(session.id.uuidString.lowercased())  \(session.provider.rawValue)  \(mode)  \(session.status.rawValue)  \(session.snapshotCommit.prefix(12))")
            print("  \(session.workspacePath)")
        }
    }

    private static func sessionCommand(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.first == "create" else { throw AgentBridgeError.invalidInput("用法：agentbridge session create --provider codex|claude|local --repo PATH [--interactive|--changes]") }
        var provider: AgentProvider?
        var repoPath: String?
        var interactive = false
        var isolatedChanges = false
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--provider":
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("--provider 需要值。") }
                provider = AgentProvider(rawValue: arguments[index])
            case "--repo":
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("--repo 需要值。") }
                repoPath = arguments[index]
            case "--interactive":
                interactive = true
            case "--changes":
                isolatedChanges = true
            default:
                throw AgentBridgeError.invalidInput("不認識的 session create 選項 \(arguments[index])。")
            }
            index += 1
        }
        guard let provider, let repoPath else { throw AgentBridgeError.invalidInput("請指定 --provider 與 --repo。") }
        guard !(interactive && isolatedChanges) else { throw AgentBridgeError.invalidInput("--interactive 與 --changes 互斥。") }
        if provider == .local && (interactive || isolatedChanges) {
            throw AgentBridgeError.invalidInput("Local project chat only supports read-only sessions.")
        }
        if provider != .local, isolatedChanges, try service.settings().usageMode != .subscription {
            throw AgentBridgeError.sessionMismatch("隔離變更只支援官方 CLI 訂閱登入；Claude API 僅支援唯讀工作階段。")
        }
        let access: AccessMode = isolatedChanges ? .isolatedChanges : (interactive ? .interactiveManualApproval : .readOnly)
        let session = try await service.createSession(sourcePath: repoPath, provider: provider, accessMode: access)
        print("已建立隔離工作階段：\(session.id.uuidString.lowercased())")
        print("工作區：\(session.workspacePath)")
        print("固定提交：\(session.snapshotCommit)")
        if session.sourceWasDirty { print("來源包含未提交變更；這些變更未複製到工作區。") }
        if interactive {
            let profileID = session.accountProfileID?.uuidString.lowercased() ?? AccountProfile.defaultID(for: provider).uuidString.lowercased()
            print("互動模式需在 Terminal 中執行：agentbridge interactive \(session.id.uuidString.lowercased()) --profile \(profileID)")
        }
        if isolatedChanges {
            print("隔離變更工作階段已建立。唯讀仍是預設；建立工作計畫並明確核准前，不會執行寫入。")
        }
    }

    private static func runCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let first = arguments.first, let sessionID = UUID(uuidString: first) else {
            throw AgentBridgeError.invalidInput("用法：agentbridge run SESSION-ID [--api-budget USD --confirm-api-spend --api-key-env ANTHROPIC_API_KEY]；提示內容由標準輸入讀取。")
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
                    throw AgentBridgeError.invalidInput("--api-budget 需要有效金額。")
                }
                budget = value
            case "--confirm-api-spend":
                confirmed = true
            case "--api-key-env":
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("--api-key-env 需要環境變數名稱。") }
                keyEnvironmentName = arguments[index]
            default:
                throw AgentBridgeError.invalidInput("不認識的 run 選項 \(arguments[index])。")
            }
            index += 1
        }
        let apiRequest: APIUsageRequest?
        if budget != nil || confirmed || keyEnvironmentName != nil {
            guard let budget, confirmed, keyEnvironmentName == "ANTHROPIC_API_KEY" else {
                throw AgentBridgeError.invalidInput("API 模式需同時指定 --api-budget、--confirm-api-spend 與 --api-key-env ANTHROPIC_API_KEY。")
            }
            guard let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !key.isEmpty else {
                throw AgentBridgeError.invalidInput("找不到 ANTHROPIC_API_KEY；金鑰值不會作為命令列參數傳入。")
            }
            apiRequest = APIUsageRequest(requestedBudgetUSD: budget, explicitlyAuthorized: true, apiKey: key)
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
                FileHandle.standardError.write(Data(String(format: "供應商回報費用：US$%.4f\n", cost).utf8))
            } else {
                FileHandle.standardError.write(Data("供應商未提供實際費用；保留的預算不會退回。\n".utf8))
            }
        }
    }

    private static func interactiveCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let first = arguments.first, let sessionID = UUID(uuidString: first) else {
            throw AgentBridgeError.invalidInput("用法：agentbridge interactive SESSION-ID [--profile PROFILE-ID]")
        }
        var profileID: UUID?
        var index = 1
        while index < arguments.count {
            guard arguments[index] == "--profile", index + 1 < arguments.count,
                  let parsedID = UUID(uuidString: arguments[index + 1]), profileID == nil else {
                throw AgentBridgeError.invalidInput("互動模式只接受一個有效的 --profile PROFILE-ID。")
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
            throw AgentBridgeError.invalidInput("用法：agentbridge usage-tui --provider codex|claude --profile PROFILE-ID")
        }
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        _ = try await service.runUsageTUI(provider: provider, profileID: profileID, cancellation: cancellation)
    }

    private static func profilesCommand(_ arguments: [String], service: BridgeService) throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("用法：agentbridge profiles list|create|select|memory ...")
        }
        switch action {
        case "list":
            guard arguments.count <= 2 else { throw AgentBridgeError.invalidInput("用法：agentbridge profiles list [codex|claude|local]") }
            let providers = arguments.count == 2 ? [try parseProvider(arguments[1])] : AgentProvider.allCases
            for provider in providers {
                let selectedID = try service.selectedAccountProfile(provider: provider).id
                for profile in try service.accountProfiles(provider: provider) {
                    let selectedMarker = profile.id == selectedID ? "*" : " "
                    let loginKind = provider == .local ? "本機模型帳戶" : (profile.usesExistingLogin ? "目前本機登入" : "獨立登入")
                    let memory = profile.allowsSharedMemory ? "共享記憶開啟" : "共享記憶關閉"
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
                    guard index < arguments.count else { throw AgentBridgeError.invalidInput("--provider 需要 codex、claude 或 local。") }
                    provider = try parseProvider(arguments[index])
                case "--name":
                    index += 1
                    guard index < arguments.count else { throw AgentBridgeError.invalidInput("--name 需要帳戶名稱。") }
                    name = arguments[index]
                case "--share-memory":
                    allowsSharedMemory = true
                default:
                    throw AgentBridgeError.invalidInput("不認識的 profiles create 選項 \(arguments[index])。")
                }
                index += 1
            }
            guard let provider, let name else { throw AgentBridgeError.invalidInput("請指定 --provider 與 --name。") }
            let profile = try service.createAccountProfile(name: name, provider: provider, allowsSharedMemory: allowsSharedMemory)
            print("已建立獨立帳戶設定：\(profile.id.uuidString.lowercased())（\(provider.rawValue)，共享記憶\(allowsSharedMemory ? "開啟" : "關閉")）。")
            if provider == .local {
                print("Local 帳戶不使用 CLI 登入或憑證資料夾。")
            } else {
                print("登入請在互動 Terminal 執行：agentbridge profile-login \(profile.id.uuidString.lowercased())")
            }
        case "select":
            guard arguments.count == 4, arguments[1] == "--provider",
                  let provider = AgentProvider(rawValue: arguments[2]),
                  let profileID = UUID(uuidString: arguments[3]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge profiles select --provider codex|claude|local PROFILE-ID")
            }
            try service.selectAccountProfile(id: profileID, provider: provider)
            print("已選取 \(provider.rawValue) 帳戶設定 \(profileID.uuidString.lowercased())。新工作階段將綁定這個帳戶。")
        case "memory":
            guard arguments.count == 3, let profileID = UUID(uuidString: arguments[1]),
                  arguments[2] == "on" || arguments[2] == "off" else {
                throw AgentBridgeError.invalidInput("用法：agentbridge profiles memory PROFILE-ID on|off")
            }
            try service.setAccountSharedMemoryAllowed(id: profileID, allowed: arguments[2] == "on")
            print("已更新帳戶共享記憶設定。")
        default:
            throw AgentBridgeError.invalidInput("不認識的 profiles 子命令。")
        }
    }

    private static func profileLoginCommand(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count == 1, let profileID = UUID(uuidString: arguments[0]) else {
            throw AgentBridgeError.invalidInput("用法：agentbridge profile-login PROFILE-ID")
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
            throw AgentBridgeError.invalidInput("用法：agentbridge memory show|notes|clear SESSION-ID [--confirm]")
        }
        switch action {
        case "show":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("用法：agentbridge memory show SESSION-ID") }
            let snapshot = try service.sharedMemory(sessionID: sessionID)
            print("範圍：\(snapshot.scope.repositoryPath) @ \(snapshot.scope.snapshotCommit.prefix(12))")
            print("Revision：\(snapshot.revision)；回合：\(snapshot.turns.count)；內容截短：\(snapshot.wasTruncated ? "是" : "否")")
            print("\n[備註]\n\(snapshot.notes)")
            for turn in snapshot.turns {
                print("\n[\(turn.id.uuidString.lowercased()) · \(turn.provider.rawValue) \(turn.timestamp)]\n使用者：\(turn.userText)\n助理：\(turn.assistantText)")
            }
        case "notes":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("用法：agentbridge memory notes SESSION-ID < notes.txt") }
            let notes = try readPromptFromStandardInput(maximumBytes: 64 * 1_024)
            try service.setSharedMemoryNotes(sessionID: sessionID, notes: notes)
            print("已更新這個隔離工作區的共享記憶備註。")
        case "clear":
            guard arguments.count == 3, arguments[2] == "--confirm" else {
                throw AgentBridgeError.invalidInput("清除不可復原；請明確指定 agentbridge memory clear SESSION-ID --confirm。")
            }
            try service.clearSharedMemory(sessionID: sessionID)
            print("已清除這個隔離工作區的共享記憶。")
        case "handoffs":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("用法：agentbridge memory handoffs SESSION-ID") }
            let handoffs = try service.projectMemoryHandoffs(sessionID: sessionID)
            for handoff in handoffs {
                print("\(handoff.id.uuidString.lowercased())  \(handoff.sourceCommit) -> \(handoff.targetCommit)  \(handoff.turns.count) selected turns  notes=\(handoff.notes == nil ? "no" : "yes")")
            }
            if handoffs.isEmpty { print("此儲存庫尚無明確記憶交接。") }
        case "carry-forward":
            guard arguments.count >= 3,
                  let sourceID = UUID(uuidString: arguments[1]),
                  let targetID = UUID(uuidString: arguments[2]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge memory carry-forward SOURCE-SESSION TARGET-SESSION [--turn TURN-ID ...] [--notes]")
            }
            var selectedTurnIDs = Set<UUID>()
            var includeNotes = false
            var index = 3
            while index < arguments.count {
                switch arguments[index] {
                case "--turn":
                    index += 1
                    guard index < arguments.count, let id = UUID(uuidString: arguments[index]) else {
                        throw AgentBridgeError.invalidInput("--turn 需要有效的回合 UUID。")
                    }
                    selectedTurnIDs.insert(id)
                case "--notes": includeNotes = true
                default: throw AgentBridgeError.invalidInput("不認識的 memory carry-forward 選項 \(arguments[index])。")
                }
                index += 1
            }
            let handoff = try service.carryForwardProjectMemory(
                sourceSessionID: sourceID,
                targetSessionID: targetID,
                selectedTurnIDs: selectedTurnIDs,
                includeNotes: includeNotes
            )
            print("已建立明確交接 \(handoff.id.uuidString.lowercased())：\(handoff.sourceCommit) -> \(handoff.targetCommit)。")
            print("只複製所選 App 記憶；目標提交的下一個允許共用記憶提示會收到標記為未信任且有大小限制的歷史內容。")
        default:
            throw AgentBridgeError.invalidInput("不認識的 memory 子命令。")
        }
    }

    private static func changesCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("用法：agentbridge changes plan|approve|run|diff|restore|restore-all|export|verify|accept|apply ...")
        }
        switch action {
        case "plan":
            guard arguments.count >= 2, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge changes plan SESSION-ID --title TITLE --summary SUMMARY --step STEP [--step STEP ...]")
            }
            var title: String?
            var summary: String?
            var steps: [String] = []
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("\(option) 需要值。") }
                switch option {
                case "--title": title = arguments[index]
                case "--summary": summary = arguments[index]
                case "--step": steps.append(arguments[index])
                default: throw AgentBridgeError.invalidInput("不認識的 changes plan 選項 \(option)。")
                }
                index += 1
            }
            guard let title, let summary else { throw AgentBridgeError.invalidInput("請指定 --title 與 --summary。") }
            let plan = try service.createChangePlan(sessionID: sessionID, title: title, summary: summary, steps: steps)
            print("待檢視計畫：\(plan.id.uuidString.lowercased())")
            print("標題：\(plan.title)\n摘要：\(plan.summary)\n步驟：")
            for (offset, step) in plan.steps.enumerated() { print("  \(offset + 1). \(step)") }
            print("檢視摘要：\(plan.reviewDigest)")
            print("計畫尚未核准；目前不會授權寫入。")
        case "approve":
            guard arguments.count == 4,
                  let sessionID = UUID(uuidString: arguments[1]),
                  let planID = UUID(uuidString: arguments[2]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge changes approve SESSION-ID PLAN-ID REVIEW-DIGEST")
            }
            let session = try requireSession(sessionID, service: service)
            guard let plan = session.changePlan, plan.id == planID, plan.reviewDigest == arguments[3].lowercased() else {
                throw AgentBridgeError.invalidChangePlan("計畫識別碼或摘要不符目前保存內容。")
            }
            print("請逐項檢視下列計畫。只有你明確核准後，才會解鎖變更執行：")
            print("\(plan.title)\n\(plan.summary)")
            for (offset, step) in plan.steps.enumerated() { print("  \(offset + 1). \(step)") }
            print("輸入完整文字 APPROVE \(plan.reviewDigest) 以核准：")
            guard readLine(strippingNewline: true) == "APPROVE \(plan.reviewDigest)" else {
                throw AgentBridgeError.invalidChangePlan("未輸入完整檢視摘要確認；計畫仍未核准。")
            }
            _ = try service.approveChangePlan(sessionID: sessionID, planID: planID, reviewedDigest: plan.reviewDigest)
            print("已明確核准目前工作計畫。")
        case "run":
            guard arguments.count == 4,
                  let sessionID = UUID(uuidString: arguments[1]),
                  let planID = UUID(uuidString: arguments[2]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge changes run SESSION-ID PLAN-ID REVIEW-DIGEST < prompt.txt")
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
                throw AgentBridgeError.invalidInput("用法：agentbridge changes diff SESSION-ID")
            }
            let diff = try await service.changesDiff(sessionID: sessionID)
            for file in diff.files {
                print("\n--- \(file.status.rawValue) \(file.path) ---")
                if file.isBinary { print("[binary file]") }
                else { print(file.patch, terminator: "") }
            }
            if diff.files.isEmpty { print("隔離工作區沒有差異。") }
        case "restore":
            guard arguments.count >= 3, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge changes restore SESSION-ID RELATIVE-PATH [RELATIVE-PATH ...]")
            }
            try await service.restoreChangeFiles(sessionID: sessionID, filePaths: Array(arguments.dropFirst(2)))
            print("已還原所列隔離工作區檔案；來源儲存庫未變更。")
        case "restore-all":
            guard arguments.count == 3, let sessionID = UUID(uuidString: arguments[1]), arguments[2] == "--confirm" else {
                throw AgentBridgeError.invalidInput("用法：agentbridge changes restore-all SESSION-ID --confirm")
            }
            try await service.restoreAllChanges(sessionID: sessionID)
            print("已還原隔離工作區至基準提交；來源儲存庫未變更。")
        case "export":
            guard arguments.count == 3, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge changes export SESSION-ID /absolute/path/to/changes.patch")
            }
            let destination = URL(fileURLWithPath: arguments[2]).standardizedFileURL
            guard destination.path.hasPrefix("/"), !destination.path.contains("\0") else {
                throw AgentBridgeError.invalidInput("補丁輸出需要有效的絕對路徑。")
            }
            let patch = try await service.exportChangePatch(sessionID: sessionID)
            try writeNewPrivateFile(patch, to: destination)
            print("已匯出 \(patch.count) 位元組補丁至 \(destination.path)。")
        case "verify":
            guard arguments.count >= 2, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge changes verify SESSION-ID [--custom /absolute/executable --approve-custom [--arg ARG ...]]")
            }
            var customPath: URL?
            var approved = false
            var verifierArguments: [String] = []
            var index = 2
            while index < arguments.count {
                switch arguments[index] {
                case "--custom":
                    index += 1
                    guard index < arguments.count, customPath == nil else { throw AgentBridgeError.invalidInput("--custom 需要一個絕對執行檔路徑。") }
                    customPath = URL(fileURLWithPath: arguments[index])
                case "--approve-custom": approved = true
                case "--arg":
                    index += 1
                    guard index < arguments.count else { throw AgentBridgeError.invalidInput("--arg 需要一個引數值。") }
                    verifierArguments.append(arguments[index])
                default: throw AgentBridgeError.invalidInput("不認識的 changes verify 選項 \(arguments[index])。")
                }
                index += 1
            }
            guard customPath == nil || approved else {
                throw AgentBridgeError.verificationCommandRejected("自訂驗證需同時指定 --approve-custom；每個 --arg 會作為獨立 argv 傳入，不會經過 shell。")
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
            print("執行檔：\(OutputRedactor.redact(result.command?.executablePath ?? "not launched"))")
            print("退出代碼：\(result.exitCode.map(String.init) ?? "未提供")；耗時：\(String(format: "%.3f", result.durationSeconds)) 秒；成功：\(result.succeeded ? "是" : "否")")
            if let skipped = result.skippedReason { print("略過：\(OutputRedactor.redact(skipped))") }
            if !result.standardOutput.isEmpty { print("\n[stdout]\n\(result.standardOutput)") }
            if !result.standardError.isEmpty { FileHandle.standardError.write(Data("\n[stderr]\n\(result.standardError)\n".utf8)) }
        case "accept":
            guard arguments.count == 3, let sessionID = UUID(uuidString: arguments[1]), arguments[2] == "--confirm" else {
                throw AgentBridgeError.invalidInput("用法：agentbridge changes accept SESSION-ID --confirm")
            }
            _ = try await service.acceptChanges(sessionID: sessionID)
            print("已接受目前已驗證的隔離差異；來源儲存庫仍未修改。")
        case "apply":
            guard arguments.count == 3, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge changes apply SESSION-ID LOCAL-BRANCH")
            }
            let result = try await service.applyChangesToLocalBranch(sessionID: sessionID, branchName: arguments[2])
            print("已建立工作樹：\(result.worktreePath)（分支 \(result.branchName)，\(result.changedFileCount) 個檔案）。")
            print("工作樹保持未提交；AgentBridge 未建立提交、推送或合併。")
        default:
            throw AgentBridgeError.invalidInput("不認識的 changes 子命令 \(action)。")
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
        guard arguments.count <= 1 else { throw AgentBridgeError.invalidInput("用法：agentbridge tasks [SESSION-ID]") }
        let sessionID = arguments.first.flatMap(UUID.init(uuidString:))
        guard arguments.isEmpty || sessionID != nil else { throw AgentBridgeError.invalidInput("SESSION-ID 必須是有效 UUID。") }
        let records = try service.taskRecords(sessionID: sessionID)
        if records.isEmpty { print("尚無任務記錄。"); return }
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
            guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("用法：agentbridge extensions list") }
            for descriptor in try service.extensionDescriptors() {
                print("\(descriptor.kind.rawValue.uppercased()) \(descriptor.id) v\(descriptor.version) — \(descriptor.name)")
                print("  requested: \(descriptor.requestedPermissions.map(\.rawValue).joined(separator: ", "))")
                if !descriptor.summary.isEmpty { print("  \(OutputRedactor.redact(descriptor.summary))") }
            }
            print("Descriptors and grants are policy metadata only; they do not activate or execute extensions.")
        case "import":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("用法：agentbridge extensions import /path/to/descriptor.json") }
            let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let data = try BoundedDescriptorFileReader.read(at: url)
            let descriptor = try JSONDecoder().decode(ExtensionDescriptor.self, from: data)
            _ = try service.importExtensionDescriptor(descriptor, source: .localMetadata, sourceReference: url.path)
            print("Imported inert descriptor \(descriptor.id). No script was executed; no provider extension was activated.")
        case "grant":
            guard arguments.count >= 5,
                  let sessionID = UUID(uuidString: arguments[1]),
                  arguments.last == "--confirm" else {
                throw AgentBridgeError.invalidInput("用法：agentbridge extensions grant SESSION-ID EXTENSION-ID --permission PERMISSION [--path RELATIVE-PATH] [--host HOST] --confirm")
            }
            let extensionID = arguments[2]
            var permissions: [ExtensionPermission] = []
            var paths: [String] = []
            var hosts: [String] = []
            var index = 3
            while index < arguments.count - 1 {
                let option = arguments[index]
                index += 1
                guard index < arguments.count - 1 else { throw AgentBridgeError.invalidInput("\(option) 需要值。") }
                switch option {
                case "--permission":
                    guard let permission = ExtensionPermission(rawValue: arguments[index]) else {
                        throw AgentBridgeError.invalidInput("未知的 extension permission \(arguments[index])。")
                    }
                    permissions.append(permission)
                case "--path": paths.append(arguments[index])
                case "--host": hosts.append(arguments[index])
                default: throw AgentBridgeError.invalidInput("不認識的 extensions grant 選項 \(option)。")
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
                throw AgentBridgeError.invalidInput("用法：agentbridge extensions revoke SESSION-ID EXTENSION-ID --confirm")
            }
            let projectID = try service.extensionProjectID(sessionID: sessionID)
            _ = try service.revokeExtensionPermissions(extensionID: arguments[2], projectID: projectID)
            print("Revoked the extension permission metadata for this project.")
        default:
            throw AgentBridgeError.invalidInput("不認識的 extensions 子命令。")
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
            throw AgentBridgeError.invalidInput("用法：agentbridge cancel SESSION-ID")
        }
        try service.cancel(sessionID: sessionID)
        print("已送出取消請求；執行中的程序將在收到訊號後結束。")
    }

    private static func showEvents(_ arguments: [String], service: BridgeService) throws {
        guard arguments.count == 1, let sessionID = UUID(uuidString: arguments[0]) else {
            throw AgentBridgeError.invalidInput("用法：agentbridge events SESSION-ID")
        }
        for event in try service.events(sessionID: sessionID) {
            let formatter = ISO8601DateFormatter()
            print("\(formatter.string(from: event.timestamp)) [\(event.kind)] \(event.message)")
        }
    }

    private static func showBudget(service: BridgeService) throws {
        let snapshot = try service.budgetSnapshot()
        print("月份（UTC）：\(snapshot.month)")
        print(String(format: "月度上限：US$%.2f", snapshot.monthlyLimitUSD))
        print(String(format: "已用：US$%.2f；保留：US$%.2f；可用：US$%.2f", snapshot.usedUSD, snapshot.reservedUSD, snapshot.availableUSD))
        print("帳本只計算 AgentBridge API 呼叫；供應商顯示的費用以最終帳單為準。")
    }

    private static func budgetCommand(_ arguments: [String], service: BridgeService) throws {
        guard arguments.first == "reconcile" else {
            guard arguments.isEmpty else {
                throw AgentBridgeError.invalidInput("用法：agentbridge budget reconcile SESSION-ID --profile PROFILE-ID --actual-usd USD --confirm")
            }
            try showBudget(service: service)
            return
        }
        guard arguments.count == 7,
              let sessionID = UUID(uuidString: arguments[1]),
              arguments[2] == "--profile",
              let profileID = UUID(uuidString: arguments[3]),
              arguments[4] == "--actual-usd",
              let actualUSD = Double(arguments[5]),
              arguments[6] == "--confirm" else {
            throw AgentBridgeError.invalidInput("用法：agentbridge budget reconcile SESSION-ID --profile PROFILE-ID --actual-usd USD --confirm")
        }
        let profile = try service.accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
        try service.reconcileAPIUsageFromProviderBill(
            profileID: profileID,
            sessionID: sessionID,
            actualUSD: actualUSD,
            explicitlyConfirmed: true
        )
        print(String(format: "已依使用者確認的 Anthropic 帳單金額 US$%.6f 手動結算。", actualUSD))
        print("Claude 帳戶：\(profile.name)（\(profile.id.uuidString.lowercased())）")
        print("工作階段：\(sessionID.uuidString.lowercased())")
    }

    private static func parseProvider(_ value: String) throws -> AgentProvider {
        guard let provider = AgentProvider(rawValue: value) else {
            throw AgentBridgeError.invalidInput("供應商必須是 codex、claude 或 local。")
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
        try readBoundedStandardInput(maximumBytes: maximumBytes, label: "提示內容")
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
        AgentBridge \(version) — macOS Codex / Claude CLI 與 Local model 工作階段管理

        命令：
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
          agentbridge profiles create --provider codex|claude|local --name NAME [--share-memory]（共用記憶預設開啟）
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

        `run` 從標準輸入讀取最多 256 KiB 的提示文字，不會把提示放在程序參數或稽核檔。
        Local model 只支援討論與唯讀專案聊天；local session 不提供 autonomy、編輯工具、互動 Terminal、Skills 或 MCP。Local 不使用 API 金鑰、官方 CLI 登入或雲端回退。
        `autonomous plan` 會立即開始一次真實的官方 CLI 訂閱模型規劃請求；目標從標準輸入讀取，最多 8,000 位元組。每個角色與規劃者都要明確指定供應商及設定檔 UUID，例如 `--planner codex:00000000-0000-0000-0000-000000000001`。Claude API 模式不會用於自主流程。
        規劃命令會保存尚未核准的不可變計畫。先完整檢視角色、擴充功能、檔案範圍、限制與驗證設定，再以 `autonomous approve RUN-ID --digest PLAN-DIGEST --confirm` 核准；單次核准只涵蓋該計畫中的修正回合與驗證。執行時必須再次提供完全相同的 `--digest`。`status --json` 可供自動化讀取工作階段進度、審查結果與驗證狀態；中斷的執行不會自動重播。
        跨帳戶輸出分享需要來源與接收設定檔都允許共用記憶。預設不會把依賴任務的內容交給下一個角色；精確實作差異一律需明確使用 `--share-diff-with-reviewer`，且實作者與審查者設定檔都必須同意共用記憶。
        如需使用 Mac Control Control mode，計畫命令必須帶 `--desktop-control-scope` 與 `--confirm-desktop-separate-from-git`；僅實作者角色可選 Control。這兩項內容會納入不可變計畫摘要。
        `--save-summary-to-memory --memory-destination PROFILE-ID` 是獨立明確同意；目的設定檔必須是此次計畫綁定且已允許共用記憶的帳戶。未提供時不會保存結果摘要。
        範例：`agentbridge autonomous plan --source /work/repo --planner codex:00000000-0000-0000-0000-000000000001 --researcher claude:00000000-0000-0000-0000-000000000002 --implementer codex:00000000-0000-0000-0000-000000000001 --reviewer claude:00000000-0000-0000-0000-000000000002 --share-diff-with-reviewer --verification projectCI < goal.txt`
        `autonomous status --json` 只輸出 AgentBridge 保存的執行狀態，不會呼叫模型或延續已中斷的工作。
        `budget reconcile` 只手動結算停止中的 Claude API 工作階段；先對照 Anthropic 帳單，再輸入實際美元金額並明確指定 `--confirm`。不會呼叫 provider；兩本帳本皆可按同一金額安全重試。
        API 模式需先選擇 usage api，並在每次執行提供上限、環境變數名稱與明確確認。
        usage-tui 只在目前選取的 provider 帳戶為訂閱登入時啟動其原生 CLI；等待登入完成並看到可輸入提示符後，再由 App 的固定按鈕送出 /usage。此畫面不會被解析或存入 AgentBridge。
        自訂帳戶有各自的供應商設定資料夾；請建立設定後在互動 Terminal 執行 profile-login。
        `session create --interactive` 建立隔離 Codex 或 Claude Terminal 工作區，仍受人工核准與綁定帳戶限制。
        `session create --changes` 建立唯讀預設下的訂閱模式隔離變更工作階段；保存並檢視計畫，再於核准命令逐字確認摘要後才可執行。
        `changes verify` 只在明確呼叫時執行 .codex/ci.sh。自訂驗證需 `--approve-custom`，並用重複 `--arg` 傳入獨立 argv 值；不會經過 shell。
        `changes accept` 與 `changes apply` 都要求目前差異成功驗證。Apply 只建立本機分支的未提交隔離工作樹，遇來源基準不同時會拒絕；不會提交、推送或合併。
        `memory carry-forward` 只複製明確選取的 App 記憶回合/備註到同一儲存庫的另一個提交，且要求目標綁定帳戶允許共享記憶；原生 TUI 對話不會匯入。
        舊版 `extensions import` 只讀入惰性中繼資料 JSON。這些舊 grant 不會啟用 Skill 或 MCP。`runtime import-skill` 只會快照最多 64 KiB 的 SKILL.md 指示文字；`runtime import-mcp` 讀入包含絕對 `command`、獨立 `args` 陣列及 `allowedTools` 的有界 JSON manifest，不會啟動程序。
        `runtime test` 需要 `--confirm-start`，並以目前 macOS 使用者權限啟動所選 MCP，只執行 initialize 與 tools/list，不會呼叫 MCP 工具或模型。允許工具清單只限制 agent 可選工具，並不是作業系統沙箱。先用 `runtime inspect` 檢視完整設定、Skill 內容或已發現工具及摘要，再用完全相同的 `--digest` 和 `--confirm-execution` 啟用到指定工作階段的專案/供應商/帳戶設定檔。舊版 metadata grant 不會生效；改變設定後必須重新測試與審閱。
        Mac Control 僅使用 AgentBridge 內建型別化代理與固定安裝 helper。`mac-control-test` 需要 `--confirm-start`，只呼叫 `mac_status` 讀取權限狀態；不截圖、不送輸入，也不會自動要求 TCC。若缺少 macOS 權限，請在系統設定手動開啟。啟用時必須在檢視 digest 後明確提供 `--confirm-screen-capture`；Control mode 還需要獨立的 `--confirm-input-control`。完整主螢幕截圖可能包含其他視窗，會傳給選定 provider，且無法文字遮蔽；目標 app 限制只套用於輸入，不會裁切截圖。`mac-control-stop` 會撤銷該範圍 Control grant 並取消受影響的 provider 工作階段。
        新帳戶預設開啟共用記憶；`--share-memory` 可作為明確開啟標記。App 與 CLI 的唯讀聊天回合可在允許共用記憶的帳戶設定間共用；原生 Terminal 的使用者輸入與輸出不會被擷取。
        `memory show/notes/clear` 只管理 App 保存的同專案同提交記憶；clear 需要 `--confirm`。
        `chat help` 顯示專案建立前的討論、明確共享內容預覽，以及以摘要確認的建立/連結命令。
        新工作階段位於所選資料根目錄的 workspaces/<session-id>；共享記憶位於 shared-memory。第一次使用前，請在 App 選擇資料根目錄，或執行 `agentbridge workspace set /absolute/path/to/root`。
        """)
    }
}
