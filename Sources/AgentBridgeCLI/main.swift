import Darwin
import Foundation
import AgentBridgeCore

@main
enum AgentBridgeCLI {
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
        if command == "version" || command == "--version" { print("AgentBridge 0.7.0"); return }
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
        case "profiles":
            try profilesCommand(Array(arguments.dropFirst()), service: service)
        case "profile-login":
            try await profileLoginCommand(Array(arguments.dropFirst()), service: service)
        case "memory":
            try memoryCommand(Array(arguments.dropFirst()), service: service)
        case "extensions":
            try extensionsCommand(Array(arguments.dropFirst()), service: service)
        case "sessions":
            try listSessions(service: service)
        case "session":
            try await sessionCommand(Array(arguments.dropFirst()), service: service)
        case "changes":
            try await changesCommand(Array(arguments.dropFirst()), service: service)
        case "tasks":
            try tasksCommand(Array(arguments.dropFirst()), service: service)
        case "run":
            try await runCommand(Array(arguments.dropFirst()), service: service)
        case "interactive":
            try await interactiveCommand(Array(arguments.dropFirst()), service: service)
        case "usage-tui":
            try await usageTUICommand(Array(arguments.dropFirst()), service: service)
        case "cancel":
            try cancelCommand(Array(arguments.dropFirst()), service: service)
        case "events":
            try showEvents(Array(arguments.dropFirst()), service: service)
        case "budget":
            try budgetCommand(Array(arguments.dropFirst()), service: service)
        default:
            throw AgentBridgeError.invalidInput("不認識的命令 \(command)。使用 `agentbridge help` 查看用法。")
        }
    }

    private static func doctor(service: BridgeService) async throws {
        print("AgentBridge 0.7.0")
        let settings = try service.settings()
        print("登入模式：\(settings.usageMode == .subscription ? "官方 CLI 訂閱登入" : "Claude API（每次執行需單次預算與確認）")")
        for provider in AgentProvider.allCases {
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
        do {
            let snapshot = try service.budgetSnapshot()
            print(String(format: "Claude API 月度帳本（UTC 月）：已用 US$%.2f，暫留 US$%.2f，可用 US$%.2f。", snapshot.usedUSD, snapshot.reservedUSD, snapshot.availableUSD))
        } catch UsageControlError.apiMonthlyLimitRequired {
            print("目前選取的 Claude 帳戶尚未設定本機 API 月上限；設定前不會啟用 API 執行。")
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
            guard arguments.count == 3, let provider = AgentProvider(rawValue: arguments[1]) else {
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
        guard arguments.first == "create" else { throw AgentBridgeError.invalidInput("用法：agentbridge session create --provider codex|claude --repo PATH [--interactive|--changes]") }
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
        if isolatedChanges, try service.settings().usageMode != .subscription {
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
            guard arguments.count <= 2 else { throw AgentBridgeError.invalidInput("用法：agentbridge profiles list [codex|claude]") }
            let providers = arguments.count == 2 ? [try parseProvider(arguments[1])] : AgentProvider.allCases
            for provider in providers {
                let selectedID = try service.selectedAccountProfile(provider: provider).id
                for profile in try service.accountProfiles(provider: provider) {
                    let selectedMarker = profile.id == selectedID ? "*" : " "
                    let loginKind = profile.usesExistingLogin ? "目前本機登入" : "獨立登入"
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
                    guard index < arguments.count else { throw AgentBridgeError.invalidInput("--provider 需要 codex 或 claude。") }
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
            print("登入請在互動 Terminal 執行：agentbridge profile-login \(profile.id.uuidString.lowercased())")
        case "select":
            guard arguments.count == 4, arguments[1] == "--provider",
                  let provider = AgentProvider(rawValue: arguments[2]),
                  let profileID = UUID(uuidString: arguments[3]) else {
                throw AgentBridgeError.invalidInput("用法：agentbridge profiles select --provider codex|claude PROFILE-ID")
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

    private static func extensionsCommand(_ arguments: [String], service: BridgeService) throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("用法：agentbridge extensions list|import|grant|revoke ...")
        }
        switch action {
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
        let result = try service.reconcileAPIUsageFromProviderBill(
            profileID: profileID,
            sessionID: sessionID,
            actualUSD: actualUSD,
            explicitlyConfirmed: true
        )
        print(String(format: "已依使用者確認的 Anthropic 帳單金額 US$%.6f 手動結算。", actualUSD))
        print("Claude 帳戶：\(profile.name)（\(profile.id.uuidString.lowercased())）")
        print("工作階段：\(sessionID.uuidString.lowercased())")
        print("月度帳本：\(result.monthlyLedgerSettled ? "已結算" : "無此預留")；每日/工作階段帳本：\(result.dailySessionLedgerSettled ? "已結算" : "無此預留")。")
    }

    private static func parseProvider(_ value: String) throws -> AgentProvider {
        guard let provider = AgentProvider(rawValue: value) else {
            throw AgentBridgeError.invalidInput("供應商必須是 codex 或 claude。")
        }
        return provider
    }

    private static func readPromptFromStandardInput(maximumBytes: Int) throws -> String {
        var data = Data()
        while data.count <= maximumBytes {
            let amount = min(65_536, maximumBytes + 1 - data.count)
            guard amount > 0 else { break }
            let chunk = try FileHandle.standardInput.read(upToCount: amount) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= maximumBytes else { throw AgentBridgeError.invalidInput("提示內容最多 256 KiB。") }
        guard let text = String(data: data, encoding: .utf8) else { throw AgentBridgeError.invalidInput("提示內容必須是 UTF-8 文字。") }
        return text
    }

    private static func printHelp() {
        print("""
        AgentBridge 0.7.0 — macOS Codex / Claude CLI 工作階段管理

        命令：
          agentbridge workspace show
          agentbridge workspace set /absolute/path/to/root
          agentbridge doctor
          agentbridge settings show
          agentbridge settings usage subscription|api
          agentbridge settings binary codex|claude /absolute/path/to/cli|auto
          agentbridge profiles list [codex|claude]
          agentbridge profiles create --provider codex|claude --name NAME [--share-memory]（共用記憶預設開啟）
          agentbridge profiles select --provider codex|claude PROFILE-ID
          agentbridge profiles memory PROFILE-ID on|off
          agentbridge profile-login PROFILE-ID
          agentbridge session create --provider codex|claude --repo PATH [--interactive|--changes]
          agentbridge sessions
          agentbridge run SESSION-ID [--api-budget USD --confirm-api-spend --api-key-env ANTHROPIC_API_KEY]
          agentbridge changes plan SESSION-ID --title TITLE --summary SUMMARY --step STEP [--step STEP ...]
          agentbridge changes approve SESSION-ID PLAN-ID REVIEW-DIGEST
          agentbridge changes run SESSION-ID PLAN-ID REVIEW-DIGEST < prompt.txt
          agentbridge changes diff|restore|restore-all|export|verify|accept|apply ...
          agentbridge tasks [SESSION-ID]
          agentbridge extensions list|import|grant|revoke ...
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
        `budget reconcile` 只手動結算停止中的 Claude API 工作階段；先對照 Anthropic 帳單，再輸入實際美元金額並明確指定 `--confirm`。不會呼叫 provider；兩本帳本皆可按同一金額安全重試。
        API 模式需先選擇 usage api，並在每次執行提供上限、環境變數名稱與明確確認。
        usage-tui 只在目前選取的 provider 帳戶為訂閱登入時啟動其原生 CLI；等待登入完成並看到可輸入提示符後，再由 App 的固定按鈕送出 /usage。此畫面不會被解析或存入 AgentBridge。
        自訂帳戶有各自的供應商設定資料夾；請建立設定後在互動 Terminal 執行 profile-login。
        `session create --interactive` 建立隔離 Codex 或 Claude Terminal 工作區，仍受人工核准與綁定帳戶限制。
        `session create --changes` 建立唯讀預設下的訂閱模式隔離變更工作階段；保存並檢視計畫，再於核准命令逐字確認摘要後才可執行。
        `changes verify` 只在明確呼叫時執行 .codex/ci.sh。自訂驗證需 `--approve-custom`，並用重複 `--arg` 傳入獨立 argv 值；不會經過 shell。
        `changes accept` 與 `changes apply` 都要求目前差異成功驗證。Apply 只建立本機分支的未提交隔離工作樹，遇來源基準不同時會拒絕；不會提交、推送或合併。
        `memory carry-forward` 只複製明確選取的 App 記憶回合/備註到同一儲存庫的另一個提交，且要求目標綁定帳戶允許共享記憶；原生 TUI 對話不會匯入。
        `extensions import` 只讀入中繼資料 JSON。Grant/revoke 是每專案政策中繼資料，不會啟用或執行 provider extension，也不會在匯入時執行腳本。
        新帳戶預設開啟共用記憶；`--share-memory` 可作為明確開啟標記。App 與 CLI 的唯讀聊天回合可在允許共用記憶的帳戶設定間共用；原生 Terminal 的使用者輸入與輸出不會被擷取。
        `memory show/notes/clear` 只管理 App 保存的同專案同提交記憶；clear 需要 `--confirm`。
        新工作階段位於所選資料根目錄的 workspaces/<session-id>；共享記憶位於 shared-memory。第一次使用前，請在 App 選擇資料根目錄，或執行 `agentbridge workspace set /absolute/path/to/root`。
        """)
    }
}
