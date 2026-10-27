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
        if command == "version" || command == "--version" { print("AgentBridge 0.4.0"); return }

        let root = try RuntimePaths.applicationSupportRoot()
        let store = try AuditStore(rootURL: root)
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
        case "sessions":
            try listSessions(service: service)
        case "session":
            try await sessionCommand(Array(arguments.dropFirst()), service: service)
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
        print("AgentBridge 0.4.0")
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
            let mode = session.policy.accessMode == .readOnly ? "唯讀" : "互動手動核准"
            print("\(session.id.uuidString.lowercased())  \(session.provider.rawValue)  \(mode)  \(session.status.rawValue)  \(session.snapshotCommit.prefix(12))")
            print("  \(session.workspacePath)")
        }
    }

    private static func sessionCommand(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.first == "create" else { throw AgentBridgeError.invalidInput("用法：agentbridge session create --provider codex|claude --repo PATH [--interactive]") }
        var provider: AgentProvider?
        var repoPath: String?
        var interactive = false
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
            default:
                throw AgentBridgeError.invalidInput("不認識的 session create 選項 \(arguments[index])。")
            }
            index += 1
        }
        guard let provider, let repoPath else { throw AgentBridgeError.invalidInput("請指定 --provider 與 --repo。") }
        let access: AccessMode = interactive ? .interactiveManualApproval : .readOnly
        let session = try await service.createSession(sourcePath: repoPath, provider: provider, accessMode: access)
        print("已建立隔離工作階段：\(session.id.uuidString.lowercased())")
        print("工作區：\(session.workspacePath)")
        print("固定提交：\(session.snapshotCommit)")
        if session.sourceWasDirty { print("來源包含未提交變更；這些變更未複製到工作區。") }
        if interactive {
            let profileID = session.accountProfileID?.uuidString.lowercased() ?? AccountProfile.defaultID(for: provider).uuidString.lowercased()
            print("互動模式需在 Terminal 中執行：agentbridge interactive \(session.id.uuidString.lowercased()) --profile \(profileID)")
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
                print("\n[\(turn.provider.rawValue) \(turn.timestamp)]\n使用者：\(turn.userText)\n助理：\(turn.assistantText)")
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
        default:
            throw AgentBridgeError.invalidInput("不認識的 memory 子命令。")
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
        AgentBridge 0.4.0 — macOS Codex / Claude CLI 工作階段管理

        命令：
          agentbridge doctor
          agentbridge settings show
          agentbridge settings usage subscription|api
          agentbridge settings binary codex|claude /absolute/path/to/cli|auto
          agentbridge profiles list [codex|claude]
          agentbridge profiles create --provider codex|claude --name NAME [--share-memory]（共用記憶預設開啟）
          agentbridge profiles select --provider codex|claude PROFILE-ID
          agentbridge profiles memory PROFILE-ID on|off
          agentbridge profile-login PROFILE-ID
          agentbridge session create --provider codex|claude --repo PATH [--interactive]
          agentbridge sessions
          agentbridge run SESSION-ID [--api-budget USD --confirm-api-spend --api-key-env ANTHROPIC_API_KEY]
          agentbridge interactive SESSION-ID [--profile PROFILE-ID]
          agentbridge usage-tui --provider codex|claude --profile PROFILE-ID
          agentbridge memory show SESSION-ID
          agentbridge memory notes SESSION-ID < notes.txt
          agentbridge memory clear SESSION-ID --confirm
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
        新帳戶預設開啟共用記憶；`--share-memory` 可作為明確開啟標記。App 與 CLI 的唯讀聊天回合可在允許共用記憶的帳戶設定間共用；原生 Terminal 的使用者輸入與輸出不會被擷取。
        `memory show/notes/clear` 只管理 App 保存的同專案同提交記憶；clear 需要 `--confirm`。
        """)
    }
}
