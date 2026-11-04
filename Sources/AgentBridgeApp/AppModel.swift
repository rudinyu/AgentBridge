import AppKit
import AgentBridgeCore
import Observation
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class AppModel {
    var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: AppLanguage.preferenceKey) }
    }
    let setupWizard = SetupWizardModel()
    let usage = UsageModel()
    let chats = DiscussionModel()
    let changes = ChangeReviewModel()
    let extensions = ExtensionsModel()
    let terminal = TerminalModel()
    var settings = BridgeSettings()
    var sessions: [SessionRecord] = []
    var events: [AuditEvent] = []
    var selectedSessionID: UUID?
    var isProjectConversationActive = false
    var localModelModels: [LocalModelDescriptor] = []
    var localModelStatus = "Connection not checked."
    var localModelError: String?
    var isRefreshingLocalModels = false
    var isTestingLocalModel = false
    var requestedAccessMode: AccessMode = .readOnly
    var repositoryPath = ""
    var workspaceRootPath = ""
    var isChangingWorkspaceRoot = false
    var codexPath = ""
    var claudePath = ""
    var prompt = ""
    var status = "就緒。"
    var errorMessage: String?
    var outputText = ""
    var isRunning = false
    var taskRecords: [ParallelTaskRecord] = []
    var autonomousRuns: [AutonomousRunRecord] = []
    var selectedAutonomousRunID: UUID?
    var isPreparingAutonomousRun = false
    var isRunningAutonomousRun = false
    var autonomousStatus = ""
    var autonomousError: String?
    var projectMemoryHandoffs: [ProjectMemoryHandoff] = []
    var memoryHandoffTargetSessionID: UUID?
    var selectedMemoryTurnIDs = Set<UUID>()
    var includeMemoryNotes = false
    var apiBudget = ""
    var apiKey = ""
    var confirmAPIRun = false
    var authStatus: [UUID: AuthAssessment] = [:]
    var accountProfiles: [AgentProvider: [AccountProfile]] = [:]
    var selectedProfileIDs: [AgentProvider: UUID] = [:]
    var newProfileName = ""
    var newProfileAllowsSharedMemory = true
    var memorySnapshot: SharedMemorySnapshot?
    var memoryNotes = ""
    var confirmClearMemory = false
    var isSwitchingTarget = false

    private(set) var service: BridgeService?
    private var store: AuditStore?
    @ObservationIgnored private var activeRunFlags: [UUID: CancellationFlag] = [:]
    @ObservationIgnored private var autonomousCancellationFlags: [UUID: CancellationFlag] = [:]
    private var activeRunSessionID: UUID?
    private var savedLocalModelSettings: LocalModelSettings?

    /// Warning text when the data root is inside a cloud-synced folder.
    var workspaceRootSyncWarning: String? {
        guard !workspaceRootPath.isEmpty,
              let service = WorkspaceRootSyncCheck.syncedServiceName(for: URL(fileURLWithPath: workspaceRootPath, isDirectory: true)) else {
            return nil
        }
        return localizedFormat(Self.syncedRootWarningFormat, service)
    }

    static let syncedRootWarningFormat = "This folder is inside %@. Discussion transcripts, shared memory and workspace copies will leave this Mac, and file locks only protect this Mac. Choose a local folder that doesn't sync."

    var workspaceRootIsConfigured: Bool { !workspaceRootPath.isEmpty && service != nil && store != nil }

    var canPresentSetupWizard: Bool {
        activeRunFlags.isEmpty && !changes.isVerifying && !isSwitchingTarget && !isChangingWorkspaceRoot
            && !terminal.terminalRunning && terminal.terminalLaunch == nil && !hasActiveAutonomousWorkflow
            && !chats.hasActiveDiscussionOperation
    }

    var hasActiveAutonomousWorkflow: Bool {
        isPreparingAutonomousRun || isRunningAutonomousRun || autonomousRuns.contains(where: { $0.status == .running })
    }

    var canStartAutonomousWorkflow: Bool {
        !isLocalProviderContext && !hasActiveAutonomousWorkflow && activeRunFlags.isEmpty && !changes.isVerifying
            && !extensions.isTestingMCPRuntime && !terminal.terminalRunning && terminal.terminalLaunch == nil && !isSwitchingTarget
            && !isChangingWorkspaceRoot
    }

    func localized(_ source: String) -> String {
        AppLocalization.display(source, language: appLanguage)
    }

    func localizedFormat(_ source: String, _ arguments: CVarArg...) -> String {
        String(format: localized(source), locale: appLanguage.locale, arguments: arguments)
    }

    init() {
        appLanguage = AppLanguage.saved
        setupWizard.attach(to: self)
        usage.attach(to: self)
        chats.attach(to: self)
        changes.attach(to: self)
        extensions.attach(to: self)
        terminal.attach(to: self)
        chats.loadSavedPreferences()
        do {
            guard try RuntimePaths.workspaceRootConfiguration() != nil else {
                status = "請選擇工作區資料根目錄以開始。"
                setupWizard.initialize(workspaceRootConfigured: false)
                return
            }
            let root = try RuntimePaths.requireWorkspaceRoot()
            let store = try RuntimePaths.makeAuditStore()
            let service = try BridgeService(store: store)
            self.store = store
            self.service = service
            workspaceRootPath = root.path
            refresh()
            setupWizard.initialize(workspaceRootConfigured: true)
        } catch {
            if let root = try? RuntimePaths.requireWorkspaceRoot() { workspaceRootPath = root.path }
            errorMessage = error.localizedDescription
            setupWizard.initialize(workspaceRootConfigured: workspaceRootIsConfigured)
        }
    }

    func reportOperationError(_ message: String) {
        if setupWizard.isPresented {
            setupWizard.errorMessage = message
            errorMessage = nil
        } else {
            errorMessage = message
        }
    }

    var selectedSession: SessionRecord? {
        sessions.first(where: { $0.id == selectedSessionID })
    }

    var isLocalProviderContext: Bool {
        chats.selectedDiscussion?.provider == .local
            || selectedSession?.provider == .local
            || (chats.selectedDiscussion == nil && selectedSession == nil
                && (settings.defaultProvider == .local || chats.newDiscussionProvider == .local))
    }

    var localModelSettingsAreDirty: Bool {
        guard let savedLocalModelSettings else { return false }
        return settings.localModel != savedLocalModelSettings
    }

    var hasSelectedLocalRunScope: Bool {
        chats.selectedDiscussion?.provider == .local || selectedSession?.provider == .local
    }

    func profileName(for provider: AgentProvider, profileID: UUID) -> String {
        accountProfiles[provider]?.first(where: { $0.id == profileID })?.name
            ?? localized("Current local login")
    }

    func profileAllowsSharedMemory(provider: AgentProvider, profileID: UUID) -> Bool {
        accountProfiles[provider]?.first(where: { $0.id == profileID })?.allowsSharedMemory ?? false
    }

    func openProjectSession(_ id: UUID) {
        chats.selectedDiscussionID = nil
        isProjectConversationActive = true
        guard selectedSessionID != id else {
            selectedSessionDidChange()
            return
        }
        selectedSessionID = id
    }

    var selectedSessionIsRunning: Bool {
        selectedSession.map { activeRunFlags[$0.id] != nil } ?? false
    }

    var canStartAnotherRun: Bool {
        !hasActiveAutonomousWorkflow
            && !extensions.isTestingMCPRuntime
            && activeRunFlags.count < 3
            && selectedSession.map { activeRunFlags[$0.id] == nil } == true
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
        guard session.provider != .local else { return nil }
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        return authStatus[profileID]
    }

    var selectedProfileAuthentication: AuthAssessment? {
        guard let profile = selectedAccountProfile else { return nil }
        return authStatus[profile.id]
    }

    func profileName(for session: SessionRecord) -> String {
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        return accountProfiles[session.provider]?.first(where: { $0.id == profileID })?.name
            ?? (session.provider == .local ? localized("Local account") : localized("目前本機登入"))
    }

    func boundProfile(for session: SessionRecord) -> AccountProfile? {
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        return accountProfiles[session.provider]?.first(where: { $0.id == profileID })
    }

    func refresh(forceUsageStatistics: Bool = false) {
        guard let service else { return }
        do {
            let previousSelectedSessionID = selectedSessionID
            var loadedSettings = try service.settings()
            if loadedSettings.defaultProvider == .codex, loadedSettings.usageMode == .api {
                loadedSettings.usageMode = .subscription
                try service.saveSettings(loadedSettings)
                status = "Codex 使用官方 CLI 訂閱登入；已修正舊的不相容設定。"
                clearAPIAuthorization()
            }
            let localModelDraft = settings.localModel
            let previouslySavedLocalModel = savedLocalModelSettings
            let hasUnsavedLocalModelDraft = previouslySavedLocalModel.map { localModelDraft != $0 } ?? false
            let persistedLocalModel = loadedSettings.localModel
            let persistedLocalModelChanged = previouslySavedLocalModel.map { persistedLocalModel != $0 } ?? false
            if hasUnsavedLocalModelDraft {
                loadedSettings.localModel = localModelDraft
            }
            settings = loadedSettings
            savedLocalModelSettings = persistedLocalModel
            if persistedLocalModelChanged { invalidateLocalModelConnectionState() }
            codexPath = settings.codexBinaryPath ?? ""
            claudePath = settings.claudeBinaryPath ?? ""
            for provider in AgentProvider.allCases {
                accountProfiles[provider] = try service.accountProfiles(provider: provider)
                selectedProfileIDs[provider] = try service.selectedAccountProfile(provider: provider).id
            }
            chats.reconcileNewDiscussionTarget()
            sessions = try service.sessions()
            chats.refreshDiscussions()
            taskRecords = try service.taskRecords()
            extensions.extensionDescriptors = try service.extensionDescriptors()
            do {
                autonomousRuns = try service.autonomousRuns().sorted { $0.plan.createdAt > $1.plan.createdAt }
                if selectedAutonomousRunID == nil || !autonomousRuns.contains(where: { $0.id == selectedAutonomousRunID }) {
                    selectedAutonomousRunID = autonomousRuns.first?.id
                }
            } catch {
                autonomousError = error.localizedDescription
            }
            do {
                extensions.activeExtensionConfigurations = try service.activeExtensionConfigurations()
            } catch {
                extensions.activeExtensionError = error.localizedDescription
            }
            if selectedSessionID == nil, let first = sessions.first {
                selectedSessionID = first.id
                refreshSelectedEvents()
            } else if selectedSessionID != nil {
                refreshSelectedEvents()
            }
            if previousSelectedSessionID != selectedSessionID {
                changes.loadChangePlanDraftFromSelectedSession()
            }
            try usage.refresh(service: service, force: forceUsageStatistics)
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
            projectMemoryHandoffs = try service.projectMemoryHandoffs(sessionID: selectedSessionID)
            taskRecords = try service.taskRecords()
            if selectedSession?.policy.accessMode == .isolatedChanges,
               activeRunFlags[selectedSessionID] == nil,
               selectedSession?.status != .running {
                Task { @MainActor [weak self] in
                    guard let self, let service = self.service else { return }
                    do {
                        let diff = try await service.changesDiff(sessionID: selectedSessionID)
                        if self.selectedSessionID == selectedSessionID { self.changes.changeDiff = diff }
                    } catch {
                        if self.selectedSessionID == selectedSessionID { self.errorMessage = error.localizedDescription }
                    }
                }
            } else {
                changes.changeDiff = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectedSessionDidChange() {
        clearAPIAuthorization()
        changes.loadChangePlanDraftFromSelectedSession()
        selectedMemoryTurnIDs = []
        memoryHandoffTargetSessionID = nil
        extensions.loadSelectedExtensionGrant()
        refreshSelectedEvents()
        if let service {
            do {
                try usage.refreshUsageStatisticsIfNeeded(service: service, force: true)
                try usage.refreshLocalModelUsageStatisticsIfNeeded(service: service, force: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectDefaultProvider(_ provider: AgentProvider) {
        guard !hasActiveAutonomousWorkflow, !chats.hasActiveDiscussionOperation else {
            errorMessage = localized("Provider and account settings are locked while a discussion request is active.")
            return
        }
        guard settings.defaultProvider != provider else { return }
        guard let service else { return }
        let previous = settings
        settings.defaultProvider = provider
        if provider == .codex, settings.usageMode == .api {
            settings.usageMode = .subscription
        }
        if provider == .local { requestedAccessMode = .readOnly }
        if provider == .codex && settings.usageMode == .api { requestedAccessMode = .readOnly }
        clearAPIAuthorization()
        do {
            updateBinaryPathsInSettings()
            try service.saveSettings(settings)
            terminal.providerUsageReport = nil
            status = provider == .codex && previous.usageMode == .api
                ? "已切換至 Codex，並儲存為官方 CLI 訂閱登入模式。"
                : "新工作階段預設助理已儲存。"
            usage.loadedUsageControlsScopeKey = nil
            refresh(forceUsageStatistics: true)
            if let anchor = selectedSession { selectOrCreateSession(for: provider, anchoredTo: anchor) }
        } catch {
            settings = previous
            errorMessage = error.localizedDescription
        }
    }

    func selectUsageMode(_ usageMode: UsageMode) {
        guard !hasActiveAutonomousWorkflow, !chats.hasActiveDiscussionOperation else {
            errorMessage = localized("Provider and account settings are locked while a discussion request is active.")
            return
        }
        guard settings.defaultProvider == .claude,
              settings.usageMode != usageMode,
              let service else { return }
        let previous = settings
        settings.usageMode = usageMode
        if usageMode == .api { requestedAccessMode = .readOnly }
        clearAPIAuthorization()
        do {
            updateBinaryPathsInSettings()
            try service.saveSettings(settings)
            if usageMode == .api { terminal.providerUsageReport = nil }
            status = "Claude 使用模式已儲存。"
            refresh(forceUsageStatistics: true)
            if let anchor = selectedSession { selectOrCreateSession(for: .claude, anchoredTo: anchor) }
        } catch {
            settings = previous
            errorMessage = error.localizedDescription
        }
    }

    func saveLocalModelSettings() {
        guard let service else { return }
        guard (1_024...131_072).contains(settings.localModel.contextWindowTokens),
              (1...32_768).contains(settings.localModel.maxOutputTokens),
              settings.localModel.contextWindowTokens - settings.localModel.maxOutputTokens > 512 else {
            localModelError = localized("Context window must be 1,024–131,072 tokens and leave at least 513 tokens after the output reserve. Output reserve must be 1–32,768 tokens.")
            return
        }
        do {
            let previousSavedLocalModel = savedLocalModelSettings
            try service.saveSettings(settings)
            let savedLocalModel = try service.settings().localModel
            savedLocalModelSettings = savedLocalModel
            if previousSavedLocalModel.map({ $0 != savedLocalModel }) ?? true {
                invalidateLocalModelConnectionState()
                localModelStatus = localized("Settings saved. Connection not checked.")
            }
            status = localized("Local model settings saved.")
            refresh()
        } catch {
            localModelError = error.localizedDescription
        }
    }

    func localModelSettingsDidChange() {
        invalidateLocalModelConnectionState()
    }

    private func invalidateLocalModelConnectionState() {
        localModelModels = []
        localModelStatus = localized("Connection not checked.")
        localModelError = nil
    }

    func refreshLocalModels() {
        guard let service, !isRefreshingLocalModels else { return }
        let requestedSettings = settings.localModel
        isRefreshingLocalModels = true
        localModelError = nil
        localModelStatus = localized("Checking the configured local endpoint…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isRefreshingLocalModels = false }
            do {
                let models = try await service.localModels(settings: requestedSettings)
                guard self.settings.localModel == requestedSettings else { return }
                self.localModelModels = models
                self.localModelStatus = models.isEmpty
                    ? self.localized("No models are available at this endpoint. Start your local service and prepare a model in its own app.")
                    : String(format: self.localized("Found %d local models."), models.count)
                self.localModelError = nil
            } catch {
                guard self.settings.localModel == requestedSettings else { return }
                self.localModelStatus = self.localized("Could not list local models.")
                self.localModelError = error.localizedDescription
            }
        }
    }

    func testLocalModelConnectionFromUI() {
        guard let service, !isTestingLocalModel else { return }
        let requestedSettings = settings.localModel
        isTestingLocalModel = true
        localModelError = nil
        localModelStatus = localized("Testing the local model connection…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isTestingLocalModel = false }
            do {
                let isReady = try await service.testLocalModelConnection(settings: requestedSettings)
                guard self.settings.localModel == requestedSettings else { return }
                self.localModelStatus = isReady
                    ? self.localized("Local model connection is ready.")
                    : self.localized("The local service responded, but the selected model is not ready.")
                self.localModelError = nil
            } catch {
                guard self.settings.localModel == requestedSettings else { return }
                self.localModelStatus = self.localized("Local model connection failed.")
                self.localModelError = error.localizedDescription
            }
        }
    }

    func previewProjectContext(sessionID: UUID, currentPrompt: String) async throws -> ContextCompressionPreview {
        guard let service else {
            throw AgentBridgeError.invalidInput(localized("Choose a workspace folder before previewing context."))
        }
        let localSettings = sessions.first(where: { $0.id == sessionID })?.provider == .local ? settings.localModel : nil
        return try service.previewProjectContext(
            sessionID: sessionID,
            currentPrompt: currentPrompt,
            settings: localSettings
        )
    }

    private func updateBinaryPathsInSettings() {
        settings.codexBinaryPath = codexPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : codexPath
        settings.claudeBinaryPath = claudePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : claudePath
    }

    /// The amount a paid call would reserve for the budget being typed.
    var apiReservationPreviewUSD: Double? {
        guard let budget = Double(apiBudget.trimmingCharacters(in: .whitespacesAndNewlines)),
              budget.isFinite, budget > 0 else { return nil }
        return budget * 2
    }

    func clearAPIAuthorization() {
        apiBudget = ""
        apiKey = ""
        confirmAPIRun = false
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = localized("選擇 Git 儲存庫根目錄")
        panel.message = localized("AgentBridge 會複製目前提交版本到私有隔離工作區。來源的未提交變更不會複製。")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { repositoryPath = url.path }
    }

    func chooseWorkspaceRoot() {
        guard !isChangingWorkspaceRoot, !isRunning, !changes.isVerifying, !isSwitchingTarget,
              !terminal.terminalRunning, terminal.terminalLaunch == nil, !hasActiveAutonomousWorkflow,
              !chats.hasActiveDiscussionOperation else { return }
        let panel = NSOpenPanel()
        panel.title = localized("選擇工作區資料根目錄")
        panel.message = localized("AgentBridge 會在此資料夾保存隔離工作區與共用記憶；私人設定和用量資料仍保留在 Application Support。")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isChangingWorkspaceRoot = true
        status = localized("正在安全複製現有工作區與共用記憶…")
        Task {
            do {
                let privateRoot = try RuntimePaths.applicationSupportRoot()
                let selected = try await WorkspaceRootCoordinator.changeRoot(to: url, privateRootURL: privateRoot)
                let store = try RuntimePaths.makeAuditStore()
                let service = try BridgeService(store: store)
                self.store = store
                self.service = service
                workspaceRootPath = selected.path
                errorMessage = nil
                setupWizard.errorMessage = nil
                status = localized("工作區資料根目錄已更新；舊資料仍保留在原位置。")
                refresh(forceUsageStatistics: true)
                if setupWizard.cliPath.isEmpty {
                    setupWizard.cliPath = UserDefaults.standard.string(forKey: SetupWizardModel.cliPathPreferenceKey(for: setupWizard.provider))
                        ?? settings.binaryPath(for: setupWizard.provider)
                        ?? ""
                }
            } catch {
                reportOperationError(error.localizedDescription)
                if let root = try? RuntimePaths.requireWorkspaceRoot(),
                   let store = try? RuntimePaths.makeAuditStore(),
                   let service = try? BridgeService(store: store) {
                    self.store = store
                    self.service = service
                    workspaceRootPath = root.path
                    refresh(forceUsageStatistics: true)
                }
            }
            isChangingWorkspaceRoot = false
        }
    }

    func saveSettings() {
        guard !hasActiveAutonomousWorkflow, !chats.hasActiveDiscussionOperation else {
            errorMessage = localized("Provider and account settings are locked while a discussion request is active.")
            return
        }
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
        guard !hasActiveAutonomousWorkflow, !chats.hasActiveDiscussionOperation else {
            errorMessage = localized("Provider checks are paused while a discussion request is active.")
            return
        }
        guard let profile = selectedAccountProfile else { errorMessage = "找不到所選帳戶設定。"; return }
        checkAuthentication(for: profile)
    }

    func checkAuthentication(for profile: AccountProfile) {
        checkAuthentication(for: profile, completion: nil)
    }

    func checkAuthentication(
        for profile: AccountProfile,
        completion: ((AuthAssessment?, Error?) -> Void)?
    ) {
        guard let service else {
            let error = AgentBridgeError.invalidInput("Choose a workspace folder before checking sign-in.")
            if let completion {
                completion(nil, error)
            } else {
                reportOperationError(error.localizedDescription)
            }
            return
        }
        let provider = profile.provider
        let requestedCLIPath = normalizedCLIPath(settings.binaryPath(for: provider))
        status = "正在檢查官方 CLI 登入狀態…"
        Task {
            do {
                let assessment = try await service.checkAuthentication(provider: provider, profileID: profile.id)
                if normalizedCLIPath(try? service.settings().binaryPath(for: provider), fallback: settings.binaryPath(for: provider)) != requestedCLIPath {
                    let error = AgentBridgeError.invalidInput(localized("CLI settings changed; check sign-in again."))
                    authStatus.removeValue(forKey: profile.id)
                    status = error.localizedDescription
                    if let completion {
                        completion(nil, error)
                    } else {
                        reportOperationError(error.localizedDescription)
                    }
                    return
                }
                authStatus[profile.id] = assessment
                status = assessment.message
                completion?(assessment, nil)
            } catch {
                if normalizedCLIPath(try? service.settings().binaryPath(for: provider), fallback: settings.binaryPath(for: provider)) != requestedCLIPath {
                    let staleError = AgentBridgeError.invalidInput(localized("CLI settings changed; check sign-in again."))
                    authStatus.removeValue(forKey: profile.id)
                    status = staleError.localizedDescription
                    if let completion {
                        completion(nil, staleError)
                    } else {
                        reportOperationError(staleError.localizedDescription)
                    }
                    return
                }
                if let completion {
                    completion(nil, error)
                } else {
                    reportOperationError(error.localizedDescription)
                }
                status = "登入檢查失敗。"
            }
        }
    }

    private func normalizedCLIPath(_ path: String?) -> String {
        path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func normalizedCLIPath(_ persistedPath: String?, fallback: String?) -> String {
        normalizedCLIPath(persistedPath ?? fallback)
    }

    func createSession() {
        guard let service else { return }
        let provider = settings.defaultProvider
        guard !repositoryPath.isEmpty else { errorMessage = "請先選擇 Git 儲存庫。"; return }
        guard provider != .local || requestedAccessMode == .readOnly else {
            errorMessage = localized("Local project chat only supports read-only sessions.")
            return
        }
        guard provider == .local || requestedAccessMode != .interactiveManualApproval || settings.usageMode == .subscription else {
            errorMessage = "互動模式目前只支援訂閱登入。"
            return
        }
        guard provider == .local || requestedAccessMode != .isolatedChanges || settings.usageMode == .subscription else {
            errorMessage = "隔離變更模式只支援訂閱登入；Claude API 只能建立唯讀工作階段。"
            return
        }
        do {
            try service.saveSettings(settings)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        status = "正在建立提交版本的隔離工作區…"
        let access = requestedAccessMode
        Task {
            do {
                let session = try await service.createSession(sourcePath: repositoryPath, provider: provider, accessMode: access)
                status = session.sourceWasDirty ? "工作階段已建立。來源未提交變更已排除。" : "工作階段已建立。"
                refresh()
                isProjectConversationActive = true
                selectedSessionID = session.id
                selectedSessionDidChange()
            } catch {
                errorMessage = error.localizedDescription
                status = "無法建立工作階段。"
            }
        }
    }

    func runPrompt() {
        guard let service, let session = selectedSession else { errorMessage = "請選擇工作階段。"; return }
        guard session.policy.accessMode == .readOnly else {
            errorMessage = session.policy.accessMode == .isolatedChanges
                ? "隔離變更工作階段請先建立、檢視並核准工作計畫，再執行變更。"
                : "原生互動工作階段請從終端機面板啟動。"
            return
        }
        guard canStartAnotherRun else {
            errorMessage = hasActiveAutonomousWorkflow
                ? localized("Manual provider runs are paused while an autonomous workflow is active.")
                : "最多可同時執行三個不同工作階段；目前工作階段也不能重複執行。"
            return
        }
        var apiRequest: APIUsageRequest?
        if settings.usageMode == .api && session.provider != .local {
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
        activeRunFlags[session.id] = cancellation
        activeRunSessionID = session.id
        isRunning = !activeRunFlags.isEmpty
        errorMessage = nil
        outputText = ""
        status = session.provider == .local
            ? localized("Sending to the configured local model…")
            : (settings.usageMode == .api ? "正在檢查並保留預算…" : "正在執行…")
        apiKey = ""
        confirmAPIRun = false
        Task { @MainActor [self] in
            defer {
                activeRunFlags.removeValue(forKey: session.id)
                isRunning = !activeRunFlags.isEmpty
                activeRunSessionID = activeRunFlags.keys.first
                refresh(forceUsageStatistics: true)
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

    func runApprovedChanges() {
        guard let service, let session = selectedSession, let plan = session.changePlan else {
            errorMessage = "請先保存並明確核准目前的工作計畫。"
            return
        }
        guard changes.selectedChangePlanDraftMatchesSaved else {
            errorMessage = localized("Save your plan changes before review or approval.")
            return
        }
        guard session.approvedChangePlanDigest == plan.reviewDigest else {
            errorMessage = "請先保存並明確核准目前的工作計畫。"
            return
        }
        guard settings.usageMode == .subscription else {
            errorMessage = "隔離變更只支援官方 CLI 訂閱登入。"
            return
        }
        guard canStartAnotherRun else {
            errorMessage = hasActiveAutonomousWorkflow
                ? localized("Manual provider runs are paused while an autonomous workflow is active.")
                : "最多可同時執行三個不同工作階段；目前工作階段也不能重複執行。"
            return
        }
        let promptValue = prompt
        guard !promptValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "請輸入要交給助理的變更要求。"
            return
        }
        let cancellation = CancellationFlag()
        activeRunFlags[session.id] = cancellation
        activeRunSessionID = session.id
        isRunning = true
        errorMessage = nil
        status = "正在隔離工作區執行已核准的變更…"
        Task { @MainActor [self] in
            defer {
                activeRunFlags.removeValue(forKey: session.id)
                isRunning = !activeRunFlags.isEmpty
                activeRunSessionID = activeRunFlags.keys.first
                refresh()
                refreshSelectedEvents()
            }
            do {
                let output = try await service.runChanges(
                    sessionID: session.id,
                    prompt: promptValue,
                    planID: plan.id,
                    reviewedDigest: plan.reviewDigest,
                    cancellation: cancellation
                ) { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.status = message
                        self?.refreshSelectedEvents()
                    }
                }
                outputText = output.text
                prompt = ""
                status = "CLI 回報變更執行完成；請檢視完整檔案差異。"
            } catch {
                errorMessage = error.localizedDescription
                status = "變更執行結束。"
            }
        }
    }

    func runVerification(custom: Bool = false) {
        guard let service, let session = selectedSession,
              session.policy.accessMode == .isolatedChanges else { return }
        guard !hasActiveAutonomousWorkflow else {
            errorMessage = localized("Verification is locked while an autonomous workflow is active.")
            return
        }
        guard !isRunning || activeRunFlags[session.id] == nil else {
            errorMessage = "此工作階段目前已有執行中的工作。"
            return
        }
        guard activeRunFlags.count < 3 else { errorMessage = "最多可同時執行三項工作。"; return }
        let executable = custom ? URL(fileURLWithPath: changes.customVerifierPath) : nil
        let arguments = custom ? changes.customVerifierArgumentsText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) : []
        let cancellation = CancellationFlag()
        activeRunFlags[session.id] = cancellation
        activeRunSessionID = session.id
        isRunning = true
        changes.isVerifying = true
        changes.verificationResult = nil
        Task { @MainActor [self] in
            defer {
                activeRunFlags.removeValue(forKey: session.id)
                isRunning = !activeRunFlags.isEmpty
                changes.isVerifying = false
                activeRunSessionID = activeRunFlags.keys.first
                refresh()
                refreshSelectedEvents()
            }
            do {
                let result = try await service.runVerification(
                    sessionID: session.id,
                    customExecutableURL: executable,
                    arguments: arguments,
                    customCommandApproved: custom,
                    cancellation: cancellation
                )
                changes.verificationResult = result
                status = result.succeeded
                    ? "驗證 CLI 回報成功；退出代碼 0，耗時 \(String(format: "%.2f", result.durationSeconds)) 秒。"
                    : "驗證未通過或未完成；請查看 CLI 輸出與活動記錄。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func carryForwardSelectedMemory() {
        guard let service, let source = selectedSession,
              let targetID = memoryHandoffTargetSessionID else { return }
        do {
            if includeMemoryNotes {
                try service.setSharedMemoryNotes(sessionID: source.id, notes: memoryNotes)
            }
            let handoff = try service.carryForwardProjectMemory(
                sourceSessionID: source.id,
                targetSessionID: targetID,
                selectedTurnIDs: selectedMemoryTurnIDs,
                includeNotes: includeMemoryNotes
            )
            projectMemoryHandoffs = try service.projectMemoryHandoffs(sessionID: source.id)
            status = "已建立明確記憶交接：\(handoff.sourceCommit.prefix(12)) → \(handoff.targetCommit.prefix(12))。"
            selectedMemoryTurnIDs = []
            includeMemoryNotes = false
        } catch { errorMessage = error.localizedDescription }
    }

    var memoryHandoffTargets: [SessionRecord] {
        guard let source = selectedSession else { return [] }
        return sessions.filter { candidate in
            guard candidate.id != source.id,
                  candidate.snapshotCommit.lowercased() != source.snapshotCommit.lowercased() else { return false }
            let sourcePath = URL(fileURLWithPath: source.sourceRepositoryPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
            let candidatePath = URL(fileURLWithPath: candidate.sourceRepositoryPath, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
            return sourcePath == candidatePath
        }
    }

    var selectedMemoryTargetCanReceiveHandoff: Bool {
        guard let target = sessions.first(where: { $0.id == memoryHandoffTargetSessionID }) else { return false }
        let boundProfileID = target.accountProfileID ?? AccountProfile.defaultID(for: target.provider)
        return selectedProfileIDs[target.provider] == boundProfileID
            && (accountProfiles[target.provider]?.first(where: { $0.id == boundProfileID })?.allowsSharedMemory ?? false)
    }

    var selectedAutonomousRun: AutonomousRunRecord? {
        autonomousRuns.first(where: { $0.id == selectedAutonomousRunID })
    }

    func checkProfileAuthentication(provider: AgentProvider, profileID: UUID) async -> AuthAssessment? {
        guard let service else { return nil }
        do {
            let assessment = try await service.checkAuthentication(provider: provider, profileID: profileID)
            authStatus[profileID] = assessment
            return assessment
        } catch {
            autonomousError = error.localizedDescription
            return nil
        }
    }

    func prepareAutonomousRun(_ request: AutonomousRunRequest) {
        guard let service else { return }
        guard canStartAutonomousWorkflow else {
            autonomousError = localized("Close or cancel other provider sessions and stop the terminal before planning or running an autonomous workflow.")
            return
        }
        isPreparingAutonomousRun = true
        autonomousError = nil
        autonomousStatus = localized("Generating a plan with the selected official CLI subscription profile…")
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isPreparingAutonomousRun = false }
            do {
                let record = try await service.prepareAutonomousRun(request)
                self.selectedAutonomousRunID = record.id
                self.autonomousStatus = self.localized("Plan generation completed. Review the saved plan and digest before approval.")
                self.refresh()
            } catch {
                self.autonomousError = error.localizedDescription
                self.autonomousStatus = self.localized("Plan generation ended.")
                self.refresh()
            }
        }
    }

    func approveAutonomousRun(id: UUID, reviewedDigest: String) {
        guard let service else { return }
        do {
            let record = try service.approveAutonomousRun(id: id, reviewedDigest: reviewedDigest)
            selectedAutonomousRunID = record.id
            autonomousStatus = localized("The exact reviewed plan was approved.")
            autonomousError = nil
            refresh()
        } catch {
            autonomousError = error.localizedDescription
        }
    }

    func startAutonomousRun(id: UUID, reviewedDigest: String) {
        guard let service else { return }
        guard canStartAutonomousWorkflow else {
            autonomousError = localized("Close or cancel other provider sessions and stop the terminal before planning or running an autonomous workflow.")
            return
        }
        let cancellation = CancellationFlag()
        autonomousCancellationFlags[id] = cancellation
        isRunningAutonomousRun = true
        autonomousStatus = localized("Running the approved bounded workflow…")
        autonomousError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.autonomousCancellationFlags.removeValue(forKey: id)
                self.isRunningAutonomousRun = !self.autonomousCancellationFlags.isEmpty
                self.refresh()
            }
            do {
                let record = try await service.runAutonomousRun(id: id, reviewedDigest: reviewedDigest, cancellation: cancellation)
                self.selectedAutonomousRunID = record.id
                self.autonomousStatus = self.localized("Autonomous workflow finished. Review the final diff in the existing change review.")
            } catch {
                self.autonomousError = error.localizedDescription
                self.autonomousStatus = self.localized("Autonomous workflow ended.")
            }
        }
    }

    func cancelAutonomousRun(id: UUID) {
        guard let service else { return }
        autonomousCancellationFlags[id]?.cancel()
        do {
            let record = try service.cancelAutonomousRun(id: id)
            selectedAutonomousRunID = record.id
            autonomousStatus = localized("Cancellation was sent to every planned provider session.")
            autonomousError = nil
            refresh()
        } catch {
            autonomousError = error.localizedDescription
        }
    }

    func cancelRun() {
        if let selectedSessionID, activeRunFlags[selectedSessionID] != nil { cancelSession(selectedSessionID) }
    }

    func cancelSession(_ id: UUID) {
        activeRunFlags[id]?.cancel()
        do {
            try service?.cancel(sessionID: id)
            status = "已送出取消請求…"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectOrCreateSession(for provider: AgentProvider, anchoredTo anchor: SessionRecord) {
        guard isProjectConversationActive else { return }
        guard let profileID = selectedProfileIDs[provider], let service else { return }
        let access: AccessMode
        if provider == .local {
            access = .readOnly
        } else if settings.usageMode == .subscription,
           (anchor.policy.accessMode == .interactiveManualApproval || anchor.policy.accessMode == .isolatedChanges) {
            access = anchor.policy.accessMode
        } else {
            access = .readOnly
        }
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
        requestedAccessMode = access
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
        guard !hasActiveAutonomousWorkflow, !chats.hasActiveDiscussionOperation else {
            errorMessage = localized("Provider and account settings are locked while a discussion request is active.")
            return
        }
        guard let service else { return }
        let provider = settings.defaultProvider
        guard selectedProfileIDs[provider] != profileID else { return }
        let anchor = selectedSession
        clearAPIAuthorization()
        do {
            try service.selectAccountProfile(id: profileID, provider: provider)
            selectedProfileIDs[provider] = profileID
            terminal.providerUsageReport = nil
            accountProfiles[provider] = try service.accountProfiles(provider: provider)
            usage.loadedUsageControlsScopeKey = nil
            refresh(forceUsageStatistics: true)
            if let anchor { selectOrCreateSession(for: provider, anchoredTo: anchor) }
            else { status = provider == .local ? localized("Local memory account selected.") : localized("Official CLI account selected.") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAccountProfile() {
        guard !hasActiveAutonomousWorkflow, !chats.hasActiveDiscussionOperation else {
            errorMessage = localized("Provider and account settings are locked while a discussion request is active.")
            return
        }
        guard let service else { return }
        let provider = settings.defaultProvider
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "請為新帳戶輸入名稱。"; return }
        let anchor = selectedSession
        do {
            let profile = try service.createAccountProfile(name: name, provider: provider, allowsSharedMemory: newProfileAllowsSharedMemory)
            try service.selectAccountProfile(id: profile.id, provider: provider)
            newProfileName = ""
            newProfileAllowsSharedMemory = true
            selectedProfileIDs[provider] = profile.id
            terminal.providerUsageReport = nil
            accountProfiles[provider] = try service.accountProfiles(provider: provider)
            usage.loadedUsageControlsScopeKey = nil
            refresh(forceUsageStatistics: true)
            authStatus.removeValue(forKey: profile.id)
            if let anchor { selectOrCreateSession(for: provider, anchoredTo: anchor) }
            else { status = provider == .local
                ? localized("Separate local memory account created. No sign-in is needed.")
                : String(format: localized("Separate %@ account created. Sign in from the app terminal when ready."), provider.rawValue.capitalized) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSelectedAccountMemorySharing(_ allowed: Bool) {
        guard !hasActiveAutonomousWorkflow, !chats.hasActiveDiscussionOperation else {
            errorMessage = localized("Provider and account settings are locked while a discussion request is active.")
            return
        }
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
