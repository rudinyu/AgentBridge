import AppKit
import Combine
import Darwin
import AgentBridgeCore
import SwiftUI

@main
struct AgentBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 700)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = BridgeSettings()
    @Published var sessions: [SessionRecord] = []
    @Published var events: [AuditEvent] = []
    @Published var selectedSessionID: UUID?
    @Published var repositoryPath = ""
    @Published var codexPath = ""
    @Published var claudePath = ""
    @Published var prompt = ""
    @Published var status = "就緒。"
    @Published var errorMessage: String?
    @Published var outputText = ""
    @Published var isRunning = false
    @Published var interactiveMode = false
    @Published var apiBudget = ""
    @Published var apiKey = ""
    @Published var confirmAPIRun = false
    @Published var budgetSnapshot: BudgetSnapshot?
    @Published var authStatus: [UUID: AuthAssessment] = [:]
    @Published var accountProfiles: [AgentProvider: [AccountProfile]] = [:]
    @Published var selectedProfileIDs: [AgentProvider: UUID] = [:]
    @Published var newProfileName = ""
    @Published var newProfileAllowsSharedMemory = false
    @Published var memorySnapshot: SharedMemorySnapshot?
    @Published var memoryNotes = ""
    @Published var confirmClearMemory = false
    @Published var terminalLaunch: TerminalLaunchSpec?
    @Published var terminalTitle = ""
    @Published var terminalRunning = false
    @Published var terminalIsProfileLogin = false
    @Published var terminalNeedsManualStop = false
    @Published var closeTerminalAfterCancellation = false
    @Published var isSwitchingTarget = false

    private var service: BridgeService?
    private var store: AuditStore?
    private var cancellation: CancellationFlag?
    private var activeRunSessionID: UUID?
    private var activeTerminalProfileID: UUID?
    private var activeTerminalSessionID: UUID?

    var terminalSessionIDForView: UUID? { activeTerminalSessionID }

    init() {
        do {
            let root = try RuntimePaths.applicationSupportRoot()
            let store = try AuditStore(rootURL: root)
            let service = try BridgeService(store: store)
            self.store = store
            self.service = service
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var selectedSession: SessionRecord? {
        sessions.first(where: { $0.id == selectedSessionID })
    }

    var isClaudeAPIRunContext: Bool {
        settings.defaultProvider == .claude && settings.usageMode == .api && selectedSession?.provider == .claude
    }

    var selectedAccountProfile: AccountProfile? {
        guard let id = selectedProfileIDs[settings.defaultProvider] else { return nil }
        return accountProfiles[settings.defaultProvider]?.first(where: { $0.id == id })
    }

    var selectedSessionProfileName: String {
        guard let session = selectedSession else { return "" }
        return profileName(for: session)
    }

    var selectedSessionAuthentication: AuthAssessment? {
        guard let session = selectedSession else { return nil }
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        return authStatus[profileID]
    }

    var selectedProfileAuthentication: AuthAssessment? {
        guard let profile = selectedAccountProfile else { return nil }
        return authStatus[profile.id]
    }

    func profileName(for session: SessionRecord) -> String {
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        return accountProfiles[session.provider]?.first(where: { $0.id == profileID })?.name ?? "目前本機登入"
    }

    func refresh() {
        guard let service else { return }
        do {
            var loadedSettings = try service.settings()
            if loadedSettings.defaultProvider == .codex, loadedSettings.usageMode == .api {
                loadedSettings.usageMode = .subscription
                try service.saveSettings(loadedSettings)
                status = "Codex 使用官方 CLI 訂閱登入；已修正舊的不相容設定。"
                clearAPIAuthorization()
            }
            settings = loadedSettings
            codexPath = settings.codexBinaryPath ?? ""
            claudePath = settings.claudeBinaryPath ?? ""
            for provider in AgentProvider.allCases {
                accountProfiles[provider] = try service.accountProfiles(provider: provider)
                selectedProfileIDs[provider] = try service.selectedAccountProfile(provider: provider).id
            }
            sessions = try service.sessions()
            budgetSnapshot = try service.budgetSnapshot()
            if selectedSessionID == nil, let first = sessions.first {
                selectedSessionID = first.id
                refreshSelectedEvents()
            } else if selectedSessionID != nil {
                refreshSelectedEvents()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSelectedEvents() {
        guard let service, let selectedSessionID else {
            events = []
            memorySnapshot = nil
            memoryNotes = ""
            return
        }
        do {
            events = try service.events(sessionID: selectedSessionID)
            outputText = events.last(where: { $0.kind == "run.output" })?.message ?? ""
            let snapshot = try service.sharedMemory(sessionID: selectedSessionID)
            if memorySnapshot?.scope.key != snapshot.scope.key { memoryNotes = snapshot.notes }
            memorySnapshot = snapshot
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectedSessionDidChange() {
        clearAPIAuthorization()
        refreshSelectedEvents()
    }

    func selectDefaultProvider(_ provider: AgentProvider) {
        guard settings.defaultProvider != provider else { return }
        guard let service else { return }
        let previous = settings
        settings.defaultProvider = provider
        if provider == .codex, settings.usageMode == .api {
            settings.usageMode = .subscription
        }
        if provider == .codex { interactiveMode = false }
        clearAPIAuthorization()
        do {
            updateBinaryPathsInSettings()
            try service.saveSettings(settings)
            status = provider == .codex && previous.usageMode == .api
                ? "已切換至 Codex，並儲存為官方 CLI 訂閱登入模式。"
                : "新工作階段預設助理已儲存。"
            if let anchor = selectedSession { selectOrCreateSession(for: provider, anchoredTo: anchor) }
        } catch {
            settings = previous
            errorMessage = error.localizedDescription
        }
    }

    func selectUsageMode(_ usageMode: UsageMode) {
        guard settings.defaultProvider == .claude,
              settings.usageMode != usageMode,
              let service else { return }
        let previous = settings
        settings.usageMode = usageMode
        if usageMode == .api { interactiveMode = false }
        clearAPIAuthorization()
        do {
            updateBinaryPathsInSettings()
            try service.saveSettings(settings)
            status = "Claude 使用模式已儲存。"
            if let anchor = selectedSession { selectOrCreateSession(for: .claude, anchoredTo: anchor) }
        } catch {
            settings = previous
            errorMessage = error.localizedDescription
        }
    }

    private func updateBinaryPathsInSettings() {
        settings.codexBinaryPath = codexPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : codexPath
        settings.claudeBinaryPath = claudePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : claudePath
    }

    private func clearAPIAuthorization() {
        apiBudget = ""
        apiKey = ""
        confirmAPIRun = false
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "選擇 Git 儲存庫根目錄"
        panel.message = "AgentBridge 會複製目前提交版本到私有隔離工作區。來源的未提交變更不會複製。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { repositoryPath = url.path }
    }

    func saveSettings() {
        guard let service else { return }
        do {
            updateBinaryPathsInSettings()
            try service.saveSettings(settings)
            status = "設定已儲存。"
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkAuthentication() {
        guard let profile = selectedAccountProfile else { errorMessage = "找不到所選帳戶設定。"; return }
        checkAuthentication(for: profile)
    }

    private func checkAuthentication(for profile: AccountProfile) {
        guard let service else { return }
        status = "正在檢查官方 CLI 登入狀態…"
        Task {
            do {
                let assessment = try await service.checkAuthentication(provider: profile.provider, profileID: profile.id)
                authStatus[profile.id] = assessment
                status = assessment.message
            } catch {
                errorMessage = error.localizedDescription
                status = "登入檢查失敗。"
            }
        }
    }

    func createSession() {
        guard let service else { return }
        let provider = settings.defaultProvider
        guard !repositoryPath.isEmpty else { errorMessage = "請先選擇 Git 儲存庫。"; return }
        guard !interactiveMode || settings.usageMode == .subscription else { errorMessage = "互動模式目前只支援訂閱登入。"; return }
        do {
            try service.saveSettings(settings)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        status = "正在建立提交版本的隔離工作區…"
        let access: AccessMode = interactiveMode ? .interactiveManualApproval : .readOnly
        Task {
            do {
                let session = try await service.createSession(sourcePath: repositoryPath, provider: provider, accessMode: access)
                status = session.sourceWasDirty ? "工作階段已建立。來源未提交變更已排除。" : "工作階段已建立。"
                refresh()
                selectedSessionID = session.id
                refreshSelectedEvents()
            } catch {
                errorMessage = error.localizedDescription
                status = "無法建立工作階段。"
            }
        }
    }

    func runPrompt() {
        guard let service, let session = selectedSession else { errorMessage = "請選擇工作階段。"; return }
        var apiRequest: APIUsageRequest?
        if settings.usageMode == .api {
            guard isClaudeAPIRunContext else {
                errorMessage = "Claude API 只能用於 Claude 預設助理與 Claude 工作階段。"
                return
            }
            guard let budget = Double(apiBudget), budget.isFinite, budget > 0, !apiKey.isEmpty, confirmAPIRun else {
                errorMessage = "API 模式需要單次預算、API 金鑰，以及明確確認。"
                return
            }
            apiRequest = APIUsageRequest(requestedBudgetUSD: budget, explicitlyAuthorized: true, apiKey: apiKey)
        }
        let promptValue = prompt
        let cancellation = CancellationFlag()
        self.cancellation = cancellation
        activeRunSessionID = session.id
        isRunning = true
        errorMessage = nil
        outputText = ""
        status = settings.usageMode == .api ? "正在檢查並保留預算…" : "正在執行…"
        apiKey = ""
        confirmAPIRun = false
        Task { @MainActor [self] in
            defer {
                isRunning = false
                self.cancellation = nil
                activeRunSessionID = nil
                refresh()
                refreshSelectedEvents()
                apiKey = ""
            }
            do {
                let output = try await service.runReadOnly(sessionID: session.id, prompt: promptValue, apiRequest: apiRequest, cancellation: cancellation) { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.status = message
                        self?.refreshSelectedEvents()
                    }
                }
                outputText = output.text
                status = "回應完成。"
                prompt = ""
            } catch {
                errorMessage = error.localizedDescription
                status = "執行結束。"
            }
        }
    }

    func cancelRun() {
        if let activeRunSessionID { cancelSession(activeRunSessionID) }
    }

    func cancelSession(_ id: UUID) {
        if activeRunSessionID == id { cancellation?.cancel() }
        do {
            try service?.cancel(sessionID: id)
            status = "已送出取消請求…"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openEmbeddedInteractiveTerminal() {
        guard let session = selectedSession, session.policy.accessMode == .interactiveManualApproval else {
            errorMessage = "請先建立互動手動核准模式的工作階段。"
            return
        }
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        guard let spec = terminalLaunchSpec(
            title: "\(session.provider.rawValue.capitalized) · \(selectedSessionProfileName)",
            arguments: ["interactive", session.id.uuidString.lowercased(), "--profile", profileID.uuidString.lowercased()],
            workingDirectory: session.workspacePath
        ) else {
            errorMessage = "找不到 AgentBridge 命令列輔助程式。請先使用 scripts/package-app.sh 建立 .app。"
            return
        }
        terminalIsProfileLogin = false
        terminalTitle = spec.title
        activeTerminalProfileID = profileID
        activeTerminalSessionID = session.id
        terminalNeedsManualStop = false
        closeTerminalAfterCancellation = false
        terminalLaunch = spec
        terminalRunning = true
        status = "已在 App 內啟動互動終端機。終端機文字不會自動加入共用記憶。"
    }

    func openProfileLoginTerminal() {
        guard let profile = selectedAccountProfile else { errorMessage = "找不到所選帳戶設定。"; return }
        guard !profile.usesExistingLogin else {
            errorMessage = "為避免登出或覆寫目前登入，請先新增獨立帳戶後再登入。"
            return
        }
        guard let spec = terminalLaunchSpec(
            title: "登入 · \(profile.provider.rawValue.capitalized) · \(profile.name)",
            arguments: ["profile-login", profile.id.uuidString.lowercased()],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ) else {
            errorMessage = "找不到 AgentBridge 命令列輔助程式。請先使用 scripts/package-app.sh 建立 .app。"
            return
        }
        terminalIsProfileLogin = true
        terminalTitle = spec.title
        activeTerminalProfileID = profile.id
        activeTerminalSessionID = nil
        terminalNeedsManualStop = true
        closeTerminalAfterCancellation = false
        terminalLaunch = spec
        terminalRunning = true
        status = "已在 App 內開啟官方 CLI 登入流程。登入由你在終端機完成。"
    }

    func openLocalShell() {
        guard let session = selectedSession else { errorMessage = "請先選擇工作階段。"; return }
        guard terminalLaunch == nil else { errorMessage = "請先關閉目前的 App 終端機。"; return }
        let spec = TerminalLaunchSpec(
            title: "本機終端 · \(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent)",
            executablePath: "/bin/sh",
            arguments: ["-f"],
            environment: sanitizedTerminalEnvironment(),
            workingDirectory: session.workspacePath
        )
        terminalIsProfileLogin = false
        terminalNeedsManualStop = true
        activeTerminalProfileID = nil
        activeTerminalSessionID = nil
        closeTerminalAfterCancellation = false
        terminalTitle = spec.title
        terminalLaunch = spec
        terminalRunning = true
        status = "已在隔離工作區開啟本機 shell。Shell 命令仍以目前使用者權限執行。"
    }

    func closeEmbeddedTerminal() {
        if terminalRunning {
            if terminalNeedsManualStop {
                status = "請先在終端機按 Control-C 結束目前程序，再關閉終端面板。"
                return
            }
            guard let sessionID = activeTerminalSessionID else {
                status = "請先結束終端機中的工作，再關閉面板。"
                return
            }
            closeTerminalAfterCancellation = true
            cancelSession(sessionID)
            return
        }
        terminalLaunch = nil
        terminalRunning = false
        activeTerminalProfileID = nil
        activeTerminalSessionID = nil
        terminalNeedsManualStop = false
        status = "已關閉 App 內終端機。"
    }

    func terminalDidTerminate(exitCode: Int32?) {
        terminalRunning = false
        if let exitCode, exitCode == 0 {
            status = "終端機工作已完成。"
        } else {
            status = "終端機工作已結束\(exitCode.map { "（代碼 \($0)）" } ?? "")。"
        }
        if terminalIsProfileLogin, let profileID = activeTerminalProfileID,
           let profile = accountProfiles.values.flatMap({ $0 }).first(where: { $0.id == profileID }) {
            checkAuthentication(for: profile)
        }
        refresh()
        if closeTerminalAfterCancellation {
            terminalLaunch = nil
            closeTerminalAfterCancellation = false
            activeTerminalProfileID = nil
            activeTerminalSessionID = nil
        }
    }

    private func terminalLaunchSpec(title: String, arguments: [String], workingDirectory: String) -> TerminalLaunchSpec? {
        guard let cli = interactiveCLIURL() else { return nil }
        return TerminalLaunchSpec(
            title: title,
            executablePath: cli.path,
            arguments: arguments,
            environment: sanitizedTerminalEnvironment(),
            workingDirectory: workingDirectory
        )
    }

    private func sanitizedTerminalEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        var safeEnvironment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color"
        ]
        if let language = environment["LANG"], language.count <= 64 { safeEnvironment["LANG"] = language }
        if let temporaryDirectory = environment["TMPDIR"], temporaryDirectory.hasPrefix("/") { safeEnvironment["TMPDIR"] = temporaryDirectory }
        return safeEnvironment
    }

    private func interactiveCLIURL() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agentbridge")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        guard let argument = CommandLine.arguments.first else { return nil }
        let sibling = URL(fileURLWithPath: argument).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("agentbridge")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    private func selectOrCreateSession(for provider: AgentProvider, anchoredTo anchor: SessionRecord) {
        guard let profileID = selectedProfileIDs[provider], let service else { return }
        let access = anchor.policy.accessMode == .interactiveManualApproval && settings.usageMode == .subscription
            ? AccessMode.interactiveManualApproval
            : AccessMode.readOnly
        if let match = sessions.first(where: {
            $0.provider == provider
                && ($0.accountProfileID ?? AccountProfile.defaultID(for: provider)) == profileID
                && $0.sourceRepositoryPath == anchor.sourceRepositoryPath
                && $0.snapshotCommit == anchor.snapshotCommit
                && $0.policy.accessMode == access
        }) {
            selectedSessionID = match.id
            repositoryPath = match.sourceRepositoryPath
            status = "已切換至同一專案的 \(provider.rawValue.capitalized) 工作階段；共用記憶保持不變。"
            return
        }
        repositoryPath = anchor.sourceRepositoryPath
        interactiveMode = access == .interactiveManualApproval
        isSwitchingTarget = true
        status = "正在為所選助理與帳戶建立同一專案的隔離工作區…"
        Task {
            defer { isSwitchingTarget = false }
            do {
                let session = try await service.createSession(
                    sourcePath: anchor.sourceRepositoryPath,
                    provider: provider,
                    accessMode: access,
                    snapshotCommit: anchor.snapshotCommit
                )
                refresh()
                selectedSessionID = session.id
                refreshSelectedEvents()
                status = session.snapshotCommit == anchor.snapshotCommit
                    ? "已切換工作階段；同一提交版本的共用記憶可由已同意的帳戶載入。"
                    : "新工作階段已建立於目前提交版本；提交版本改變時會使用不同的共用記憶。"
            } catch {
                errorMessage = error.localizedDescription
                status = "無法切換工作階段。"
            }
        }
    }

    func selectAccountProfile(_ profileID: UUID) {
        guard let service else { return }
        let provider = settings.defaultProvider
        guard selectedProfileIDs[provider] != profileID else { return }
        let anchor = selectedSession
        clearAPIAuthorization()
        do {
            try service.selectAccountProfile(id: profileID, provider: provider)
            selectedProfileIDs[provider] = profileID
            accountProfiles[provider] = try service.accountProfiles(provider: provider)
            if let anchor { selectOrCreateSession(for: provider, anchoredTo: anchor) }
            else { status = "已切換官方 CLI 帳戶。" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAccountProfile() {
        guard let service else { return }
        let provider = settings.defaultProvider
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "請為新帳戶輸入名稱。"; return }
        let anchor = selectedSession
        do {
            let profile = try service.createAccountProfile(name: name, provider: provider, allowsSharedMemory: newProfileAllowsSharedMemory)
            try service.selectAccountProfile(id: profile.id, provider: provider)
            newProfileName = ""
            newProfileAllowsSharedMemory = false
            selectedProfileIDs[provider] = profile.id
            accountProfiles[provider] = try service.accountProfiles(provider: provider)
            authStatus.removeValue(forKey: profile.id)
            if let anchor { selectOrCreateSession(for: provider, anchoredTo: anchor) }
            else { status = "已建立隔離的 \(provider.rawValue.capitalized) 帳戶；請在 App 終端機登入。" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSelectedAccountMemorySharing(_ allowed: Bool) {
        guard let service, let profile = selectedAccountProfile else { return }
        do {
            try service.setAccountSharedMemoryAllowed(id: profile.id, allowed: allowed)
            accountProfiles[settings.defaultProvider] = try service.accountProfiles(provider: settings.defaultProvider)
            status = allowed ? "已允許此帳戶載入與保存專案共用記憶。" : "此帳戶不會載入或保存專案共用記憶。"
            refreshSelectedEvents()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveMemoryNotes() {
        guard let service, let session = selectedSession else { return }
        do {
            try service.setSharedMemoryNotes(sessionID: session.id, notes: memoryNotes)
            memorySnapshot = try service.sharedMemory(sessionID: session.id)
            status = "共用記憶備註已儲存。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSharedMemory() {
        guard let service, let session = selectedSession else { return }
        do {
            try service.clearSharedMemory(sessionID: session.id)
            memorySnapshot = try service.sharedMemory(sessionID: session.id)
            memoryNotes = memorySnapshot?.notes ?? ""
            confirmClearMemory = false
            status = "此專案與提交版本的共用記憶已清除。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        settingsPanel
                        accountPanel
                        workspacePanel
                        sessionList
                    }
                    .padding(12)
                }
                .frame(width: 330)
                Divider()
                conversationPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(14)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 1160, minHeight: 780)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("AgentBridge", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("清除此專案的共用記憶？", isPresented: $model.confirmClearMemory) {
            Button("清除記憶", role: .destructive) { model.clearSharedMemory() }
            Button("取消", role: .cancel) { model.confirmClearMemory = false }
        } message: {
            Text("這會刪除此來源儲存庫與固定提交版本的對話記憶與備註。provider 原生工作階段不會被修改。")
        }
        .onChange(of: model.selectedSessionID) { _, _ in model.selectedSessionDidChange() }
        .onAppear { model.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2.weight(.semibold)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AgentBridge").font(.headline)
                Text("Codex 與 Claude 共用專案記憶").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let session = model.selectedSession {
                Text("\(session.provider.rawValue.capitalized) · \(model.selectedSessionProfileName)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
            Button("檢查登入與方案") { model.checkAuthentication() }
            Button("更新") { model.refresh() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var settingsPanel: some View {
        GroupBox("助理") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("助理", selection: Binding(
                        get: { model.settings.defaultProvider },
                        set: { model.selectDefaultProvider($0) }
                    )) {
                        Text("Codex").tag(AgentProvider.codex)
                        Text("Claude").tag(AgentProvider.claude)
                }
                if model.settings.defaultProvider == .claude {
                    Picker("Claude 使用模式", selection: Binding(
                            get: { model.settings.usageMode },
                            set: { model.selectUsageMode($0) }
                        )) {
                            Text("官方 CLI 訂閱登入").tag(UsageMode.subscription)
                            Text("Claude API（每次確認）").tag(UsageMode.api)
                    }
                } else {
                    Label("Codex 使用官方 CLI 訂閱登入", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.isClaudeAPIRunContext {
                    Label("Claude API 會產生費用；每次執行都要確認。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                    if let budget = model.budgetSnapshot {
                        Text(String(format: "UTC 月份 %@ · 已用 $%.2f · 保留 $%.2f · 可用 $%.2f", budget.month, budget.usedUSD, budget.reservedUSD, budget.availableUSD))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("CLI 執行檔") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Codex CLI 自動尋找", text: $model.codexPath)
                        TextField("Claude CLI 自動尋找", text: $model.claudePath)
                        Button("儲存 CLI 路徑") { model.saveSettings() }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var accountPanel: some View {
        GroupBox("官方 CLI 帳戶") {
            VStack(alignment: .leading, spacing: 8) {
                if let profile = model.selectedAccountProfile {
                    Picker("帳戶", selection: Binding(
                        get: { model.selectedProfileIDs[model.settings.defaultProvider] ?? profile.id },
                        set: { model.selectAccountProfile($0) }
                    )) {
                        ForEach(model.accountProfiles[model.settings.defaultProvider] ?? []) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    if let assessment = model.selectedProfileAuthentication {
                        Label(assessment.message, systemImage: assessment.confirmedSubscription ? "checkmark.seal" : "exclamationmark.shield")
                            .font(.caption).foregroundStyle(assessment.confirmedSubscription ? Color.secondary : Color.orange)
                    } else {
                        Text("尚未檢查此帳戶的登入方式與方案。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("允許此帳戶載入與保存專案共用記憶", isOn: Binding(
                        get: { model.selectedAccountProfile?.allowsSharedMemory ?? false },
                        set: { model.setSelectedAccountMemorySharing($0) }
                    ))
                    .font(.caption)
                    if !profile.usesExistingLogin {
                        Button("在 App 內登入此帳戶") { model.openProfileLoginTerminal() }
                            .disabled(model.terminalRunning)
                    } else {
                        Text("目前本機登入保持原狀；新增其他帳戶會使用獨立的 CLI 設定資料夾。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("正在載入帳戶設定…").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                TextField("新帳戶顯示名稱", text: $model.newProfileName)
                Toggle("建立後允許共用專案記憶（預設關閉）", isOn: $model.newProfileAllowsSharedMemory)
                    .font(.caption)
                Button("新增並切換帳戶") { model.createAccountProfile() }
                    .disabled(model.newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSwitchingTarget)
            }
            .padding(.vertical, 2)
        }
    }

    private var workspacePanel: some View {
        GroupBox("專案") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Git 儲存庫路徑", text: $model.repositoryPath)
                Button("選擇儲存庫…") { model.chooseRepository() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("互動終端工作階段", isOn: $model.interactiveMode)
                    .disabled(model.settings.defaultProvider == .claude && model.settings.usageMode == .api)
                    .font(.caption)
                Button("建立同一專案的新工作階段") { model.createSession() }
                    .disabled(model.repositoryPath.isEmpty || model.isSwitchingTarget)
                Text("AgentBridge 固定提交版本並在自己的隔離工作區執行。相同來源與提交版本在 Codex、Claude 間共用聊天記憶。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var sessionList: some View {
        GroupBox("工作階段") {
            if model.sessions.isEmpty {
                ContentUnavailableView("尚無工作階段", systemImage: "bubble.left.and.bubble.right")
                    .frame(minHeight: 120)
            } else {
                List(model.sessions, selection: $model.selectedSessionID) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: session.provider == .codex ? "sparkle" : "message")
                            Text(session.provider.rawValue.capitalized)
                                .font(.headline)
                            if session.policy.accessMode == .interactiveManualApproval {
                                Text("Terminal").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: Capsule())
                            }
                        }
                        Text("\(model.profileName(for: session)) · \(session.status.rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(session.snapshotCommit.prefix(12)) · \(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .tag(session.id)
                }
                .frame(minHeight: 120, maxHeight: 280)
            }
        }
    }

    private var conversationPanel: some View {
        VStack(spacing: 10) {
            if let session = model.selectedSession {
                conversationHeader(session)
                memoryPanel(session)
                if session.policy.accessMode == .readOnly {
                    chatTimeline
                    composer(session)
                } else {
                    interactivePanel(session)
                }
                if let launch = model.terminalLaunch {
                    terminalPanel(launch)
                }
            } else {
                ContentUnavailableView("選擇或建立工作階段", systemImage: "bubble.left.and.bubble.right", description: Text("先選擇 Git 儲存庫，再開始一段固定版本的專案對話。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func conversationHeader(_ session: SessionRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.provider == .codex ? "sparkle" : "message")
                .font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.provider.rawValue.capitalized) · \(model.profileName(for: session))")
                    .font(.headline)
                Text("\(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent) · \(session.snapshotCommit.prefix(12))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let assessment = model.selectedSessionAuthentication {
                Label(assessment.message, systemImage: assessment.confirmedSubscription ? "checkmark.seal" : "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button("本機終端機") { model.openLocalShell() }
                .disabled(model.terminalLaunch != nil)
            if session.policy.accessMode == .interactiveManualApproval {
                Button("開啟內嵌終端機") { model.openEmbeddedInteractiveTerminal() }
                    .disabled(model.terminalRunning)
                if session.status == .running { Button("取消工作階段") { model.cancelSession(session.id) } }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
    }

    private func memoryPanel(_ session: SessionRecord) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("專案共用記憶", systemImage: "brain.head.profile")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let memory = model.memorySnapshot {
                        Text("修訂 \(memory.revision) · \(memory.turns.count) 則對話\(memory.wasTruncated ? " · 顯示最近內容" : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let memory = model.memorySnapshot {
                    Text("來源 \(URL(fileURLWithPath: memory.scope.repositoryPath).lastPathComponent) · 固定提交 \(memory.scope.snapshotCommit.prefix(12))")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if let profile = model.selectedAccountProfile, !profile.allowsSharedMemory {
                    Label("此帳戶未同意把記憶傳給助理。開啟左側「允許此帳戶載入與保存」後才會共用。", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                DisclosureGroup("記憶備註與終端機交接") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("AgentBridge 會自動保存 App 聊天中成功完成的回合。內嵌 Terminal 的 TUI 內容不會自動匯入；請在這裡手動記下要交給另一個助理的重點。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $model.memoryNotes)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 54, maxHeight: 90)
                        HStack {
                            Button("儲存備註") { model.saveMemoryNotes() }
                            Button("清除此提交的記憶…", role: .destructive) { model.confirmClearMemory = true }
                            Spacer()
                        }
                    }
                    .padding(.top, 5)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var chatTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let turns = model.memorySnapshot?.turns, !turns.isEmpty {
                        ForEach(turns) { turn in
                            messageBubble(label: "你", text: turn.userText, alignment: .trailing, color: Color.accentColor.opacity(0.12), id: "user-\(turn.id)")
                            messageBubble(label: turn.provider.rawValue.capitalized, text: turn.assistantText, alignment: .leading, color: Color(nsColor: .controlBackgroundColor), id: "assistant-\(turn.id)")
                        }
                    } else {
                        ContentUnavailableView("開始專案對話", systemImage: "text.bubble", description: Text("成功完成的對話會依來源儲存庫與固定提交版本寫入共用記憶。"))
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                    if model.isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.status).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .id("running-indicator")
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.memorySnapshot?.revision) { _, _ in
                if let last = model.memorySnapshot?.turns.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("assistant-\(last.id)", anchor: .bottom) }
                }
            }
        }
    }

    private func messageBubble(label: String, text: String, alignment: HorizontalAlignment, color: Color, id: String) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: alignment == .leading ? .leading : .trailing)
                .padding(12)
                .background(color, in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .id(id)
    }

    private func composer(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isClaudeAPIRunContext {
                Label("Claude API 會產生費用；每次執行都要輸入預算與確認。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                HStack {
                    TextField("本次預算（USD）", text: $model.apiBudget).frame(width: 160)
                    SecureField("Anthropic API key（只保留在記憶體）", text: $model.apiKey)
                    Toggle("確認這次付費呼叫", isOn: $model.confirmAPIRun).toggleStyle(.checkbox)
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextEditor(text: $model.prompt)
                    .font(.system(.body, design: .rounded))
                    .frame(minHeight: 78, maxHeight: 118)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
                VStack(spacing: 7) {
                    Button(model.isClaudeAPIRunContext ? "執行 Claude API" : "傳送") { model.runPrompt() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning || model.isSwitchingTarget || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.settings.usageMode == .api && !model.isClaudeAPIRunContext))
                    if model.isRunning { Button("取消") { model.cancelRun() } }
                }
            }
            Text("提示和回應只在成功完成後進入共用記憶；金鑰不會保存。")
                .font(.caption2).foregroundStyle(.secondary)
            if session.sourceWasDirty {
                Text("來源有未提交變更；此對話固定的工作區不包含那些變更。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
    }

    private func interactivePanel(_ session: SessionRecord) -> some View {
        VStack(spacing: 8) {
            ContentUnavailableView("互動工作階段", systemImage: "terminal", description: Text("此工作階段使用 provider 原生互動終端。它不會自動匯入 TUI 對話；請將重點記在上方的共用記憶備註。"))
                .frame(maxHeight: 200)
            HStack {
                Text("已核准的指令可能存取工作區外的檔案或網路。")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("開啟內嵌終端機") { model.openEmbeddedInteractiveTerminal() }
                    .disabled(model.terminalRunning)
                if session.status == .running { Button("取消工作階段") { model.cancelSession(session.id) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func terminalPanel(_ launch: TerminalLaunchSpec) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(launch.title).font(.subheadline.weight(.semibold))
                if model.terminalRunning { ProgressView().controlSize(.small) }
                Spacer()
                if model.terminalRunning && !model.terminalIsProfileLogin,
                   let sessionID = model.terminalSessionIDForView {
                    Button("取消工作階段") { model.cancelSession(sessionID) }
                }
                Button(model.terminalRunning ? (model.terminalNeedsManualStop ? "結束後關閉" : "取消並關閉") : "關閉終端") { model.closeEmbeddedTerminal() }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            EmbeddedTerminalView(launch: launch) { exitCode in
                model.terminalDidTerminate(exitCode: exitCode)
            }
            .id(launch.id)
            .frame(minHeight: 210, maxHeight: 340)
            Text("終端輸出只保留在目前畫面記憶體中；App 不會將 ANSI/TUI 逐字稿加入聊天記憶或稽核記錄。")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.bottom, 6)
            if model.terminalSessionIDForView == nil && !model.terminalIsProfileLogin {
                Text("本機 shell 位於 AgentBridge 複本，但仍以目前使用者權限執行。")
                    .font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isRunning || model.isSwitchingTarget || model.terminalRunning { ProgressView().controlSize(.small) }
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("AgentBridge 0.2.0").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }
}
