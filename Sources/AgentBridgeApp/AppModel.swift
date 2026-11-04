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
    var settings = BridgeSettings()
    var sessions: [SessionRecord] = []
    var discussions: [DiscussionRecord] = []
    var events: [AuditEvent] = []
    var selectedSessionID: UUID?
    var selectedDiscussionID: UUID?
    var isProjectConversationActive = false
    var discussionProgress: [UUID: String] = [:]
    var isPreparingDiscussionHandoff = false
    var isApplyingDiscussionHandoff = false
    var newDiscussionProvider: AgentProvider = .codex
    var newDiscussionProfileID: UUID?
    var discussionProfilePreferences: [AgentProvider: UUID] = [:]
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
    var changePlanTitle = ""
    var changePlanSummary = ""
    var changePlanStepsText = ""
    var changeDiff: WorkspaceChangeDiff?
    var verificationResult: VerificationResult?
    var branchName = ""
    var customVerifierPath = ""
    var customVerifierArgumentsText = ""
    var isVerifying = false
    var taskRecords: [ParallelTaskRecord] = []
    var autonomousRuns: [AutonomousRunRecord] = []
    var selectedAutonomousRunID: UUID?
    var isPreparingAutonomousRun = false
    var isRunningAutonomousRun = false
    var isTestingMCPRuntime = false
    var autonomousStatus = ""
    var autonomousError: String?
    var activeExtensionConfigurations: [ActiveExtensionConfigurationSummary] = []
    var activeExtensionError: String?
    var activeExtensionStatus = ""
    var detectedMacControlPresetStatus: MacControlPresetStatus?
    var macControlPermissionReadiness: MacControlPermissionReadiness?
    var macControlStatusError: String?
    var isCheckingMacControlPermissions = false
    var projectMemoryHandoffs: [ProjectMemoryHandoff] = []
    var memoryHandoffTargetSessionID: UUID?
    var selectedMemoryTurnIDs = Set<UUID>()
    var includeMemoryNotes = false
    var extensionDescriptors: [ExtensionDescriptor] = []
    var selectedExtensionID = ""
    var selectedExtensionPermissions = Set<ExtensionPermission>()
    var extensionPathScopesText = ""
    var extensionHostScopesText = ""
    var isImportingExtensionDescriptor = false
    var apiBudget = ""
    var apiKey = ""
    var confirmAPIRun = false
    var providerUsageReport: ProviderUsageReport?
    var authStatus: [UUID: AuthAssessment] = [:]
    var accountProfiles: [AgentProvider: [AccountProfile]] = [:]
    var selectedProfileIDs: [AgentProvider: UUID] = [:]
    var newProfileName = ""
    var newProfileAllowsSharedMemory = true
    var memorySnapshot: SharedMemorySnapshot?
    var memoryNotes = ""
    var confirmClearMemory = false
    var terminalLaunch: TerminalLaunchSpec?
    var terminalTitle = ""
    var terminalRunning = false
    var terminalIsProfileLogin = false
    var terminalIsUsageTUI = false
    var terminalNeedsManualStop = false
    var usageCommandRequest = 0
    var closeTerminalAfterCancellation = false
    var isSwitchingTarget = false

    private(set) var service: BridgeService?
    private var store: AuditStore?
    @ObservationIgnored private var activeRunFlags: [UUID: CancellationFlag] = [:]
    @ObservationIgnored private var discussionCancellationFlags: [UUID: CancellationFlag] = [:]
    @ObservationIgnored private var hasInitializedNewDiscussionTarget = false
    @ObservationIgnored private var autonomousCancellationFlags: [UUID: CancellationFlag] = [:]
    private var activeRunSessionID: UUID?
    private var activeTerminalProfileID: UUID?
    private var activeTerminalSessionID: UUID?
    private var activeUsageProvider: AgentProvider?
    private var savedLocalModelSettings: LocalModelSettings?

    private static let newDiscussionProviderPreferenceKey = "discussion.newProvider"
    private static let discussionProfilePreferencesKey = "discussion.profilePreferences"

    var terminalSessionIDForView: UUID? { activeTerminalSessionID }

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
        activeRunFlags.isEmpty && !isVerifying && !isSwitchingTarget && !isChangingWorkspaceRoot
            && !terminalRunning && terminalLaunch == nil && !hasActiveAutonomousWorkflow
            && !hasActiveDiscussionOperation
    }

    var hasActiveDiscussionOperation: Bool {
        !discussionCancellationFlags.isEmpty || isPreparingDiscussionHandoff || isApplyingDiscussionHandoff
            || discussions.contains(where: { $0.status.isInFlight })
    }

    func isDiscussionRunning(id: UUID) -> Bool {
        discussionCancellationFlags[id] != nil
            || discussions.first(where: { $0.id == id })?.status == .running
    }

    var hasActiveAutonomousWorkflow: Bool {
        isPreparingAutonomousRun || isRunningAutonomousRun || autonomousRuns.contains(where: { $0.status == .running })
    }

    var canStartAutonomousWorkflow: Bool {
        !isLocalProviderContext && !hasActiveAutonomousWorkflow && activeRunFlags.isEmpty && !isVerifying
            && !isTestingMCPRuntime && !terminalRunning && terminalLaunch == nil && !isSwitchingTarget
            && !isChangingWorkspaceRoot
    }

    func localized(_ source: String) -> String {
        AppLocalization.display(source, language: appLanguage)
    }

    func localizedFormat(_ source: String, _ arguments: CVarArg...) -> String {
        String(format: localized(source), locale: appLanguage.locale, arguments: arguments)
    }

    var canSendUsageCommand: Bool {
        terminalIsUsageTUI
            && terminalRunning
            && settings.usageMode == .subscription
            && activeTerminalProfileID == selectedProfileIDs[settings.defaultProvider]
    }

    init() {
        appLanguage = AppLanguage.saved
        setupWizard.attach(to: self)
        usage.attach(to: self)
        if let savedProvider = UserDefaults.standard.string(forKey: Self.newDiscussionProviderPreferenceKey)
            .flatMap(AgentProvider.init(rawValue:)) {
            newDiscussionProvider = savedProvider
        }
        if let savedProfiles = UserDefaults.standard.dictionary(forKey: Self.discussionProfilePreferencesKey) as? [String: String] {
            for (providerRawValue, profileRawValue) in savedProfiles {
                guard let provider = AgentProvider(rawValue: providerRawValue),
                      let profileID = UUID(uuidString: profileRawValue) else { continue }
                discussionProfilePreferences[provider] = profileID
            }
        }
        newDiscussionProfileID = discussionProfilePreferences[newDiscussionProvider]
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

    private func reportOperationError(_ message: String) {
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
        selectedDiscussion?.provider == .local
            || selectedSession?.provider == .local
            || (selectedDiscussion == nil && selectedSession == nil
                && (settings.defaultProvider == .local || newDiscussionProvider == .local))
    }

    var localModelSettingsAreDirty: Bool {
        guard let savedLocalModelSettings else { return false }
        return settings.localModel != savedLocalModelSettings
    }

    var hasSelectedLocalRunScope: Bool {
        selectedDiscussion?.provider == .local || selectedSession?.provider == .local
    }

    var selectedDiscussion: DiscussionRecord? {
        discussions.first(where: { $0.id == selectedDiscussionID })
    }

    func profileName(for provider: AgentProvider, profileID: UUID) -> String {
        accountProfiles[provider]?.first(where: { $0.id == profileID })?.name
            ?? localized("Current local login")
    }

    func profileAllowsSharedMemory(provider: AgentProvider, profileID: UUID) -> Bool {
        accountProfiles[provider]?.first(where: { $0.id == profileID })?.allowsSharedMemory ?? false
    }

    func preferredDiscussionProfileID(for provider: AgentProvider) -> UUID? {
        discussionProfilePreferences[provider]
            ?? (newDiscussionProvider == provider ? newDiscussionProfileID : nil)
            ?? selectedProfileIDs[provider]
            ?? accountProfiles[provider]?.first?.id
    }

    func openDiscussion(_ id: UUID) {
        selectedDiscussionID = id
        isProjectConversationActive = false
    }

    func openProjectSession(_ id: UUID) {
        selectedDiscussionID = nil
        isProjectConversationActive = true
        guard selectedSessionID != id else {
            selectedSessionDidChange()
            return
        }
        selectedSessionID = id
    }

    var selectedChangePlanDraftMatchesSaved: Bool {
        guard let plan = selectedSession?.changePlan else { return false }
        return ChangePlanDraft(
            title: changePlanTitle,
            summary: changePlanSummary,
            stepsText: changePlanStepsText
        ).matches(plan)
    }

    var selectedChangePlanIsApproved: Bool {
        guard selectedChangePlanDraftMatchesSaved,
              let session = selectedSession,
              let plan = session.changePlan else { return false }
        return session.approvedChangePlanDigest == plan.reviewDigest
    }

    var selectedSessionIsRunning: Bool {
        selectedSession.map { activeRunFlags[$0.id] != nil } ?? false
    }

    var canStartAnotherRun: Bool {
        !hasActiveAutonomousWorkflow
            && !isTestingMCPRuntime
            && activeRunFlags.count < 3
            && selectedSession.map { activeRunFlags[$0.id] == nil } == true
    }

    var verifiedCurrentDiff: Bool {
        guard let session = selectedSession, let diff = changeDiff,
              session.verificationPassed == true,
              session.verificationDiffDigest == diff.digest,
              let verifiedAt = session.verificationCompletedAt,
              let lastChangeAt = session.lastChangeRunAt else { return false }
        return verifiedAt >= lastChangeAt
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
            reconcileNewDiscussionTarget()
            sessions = try service.sessions()
            refreshDiscussions()
            taskRecords = try service.taskRecords()
            extensionDescriptors = try service.extensionDescriptors()
            do {
                autonomousRuns = try service.autonomousRuns().sorted { $0.plan.createdAt > $1.plan.createdAt }
                if selectedAutonomousRunID == nil || !autonomousRuns.contains(where: { $0.id == selectedAutonomousRunID }) {
                    selectedAutonomousRunID = autonomousRuns.first?.id
                }
            } catch {
                autonomousError = error.localizedDescription
            }
            do {
                activeExtensionConfigurations = try service.activeExtensionConfigurations()
            } catch {
                activeExtensionError = error.localizedDescription
            }
            if selectedSessionID == nil, let first = sessions.first {
                selectedSessionID = first.id
                refreshSelectedEvents()
            } else if selectedSessionID != nil {
                refreshSelectedEvents()
            }
            if previousSelectedSessionID != selectedSessionID {
                loadChangePlanDraftFromSelectedSession()
            }
            try usage.refresh(service: service, force: forceUsageStatistics)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshDiscussions() {
        guard let service else {
            discussions = []
            return
        }
        do {
            discussions = try service.discussions()
            if let selectedDiscussionID,
               !discussions.contains(where: { $0.id == selectedDiscussionID }) {
                self.selectedDiscussionID = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func refreshDiscussion(id: UUID) -> DiscussionRecord? {
        guard let service else { return nil }
        do {
            let discussion = try service.discussion(id: id)
            if discussions.first(where: { $0.id == id }) != discussion {
                replaceDiscussion(discussion)
            }
            return discussion
        } catch {
            return nil
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
                        if self.selectedSessionID == selectedSessionID { self.changeDiff = diff }
                    } catch {
                        if self.selectedSessionID == selectedSessionID { self.errorMessage = error.localizedDescription }
                    }
                }
            } else {
                changeDiff = nil
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectedSessionDidChange() {
        clearAPIAuthorization()
        loadChangePlanDraftFromSelectedSession()
        selectedMemoryTurnIDs = []
        memoryHandoffTargetSessionID = nil
        loadSelectedExtensionGrant()
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

    private func loadChangePlanDraftFromSelectedSession() {
        if let plan = selectedSession?.changePlan {
            changePlanTitle = plan.title
            changePlanSummary = plan.summary
            changePlanStepsText = plan.steps.joined(separator: "\n")
        } else {
            changePlanTitle = ""
            changePlanSummary = ""
            changePlanStepsText = ""
        }
    }

    func selectDefaultProvider(_ provider: AgentProvider) {
        guard !hasActiveAutonomousWorkflow, !hasActiveDiscussionOperation else {
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
            providerUsageReport = nil
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
        guard !hasActiveAutonomousWorkflow, !hasActiveDiscussionOperation else {
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
            if usageMode == .api { providerUsageReport = nil }
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

    func previewDiscussionContext(id: UUID, currentPrompt: String) async throws -> ContextCompressionPreview {
        guard let service else {
            throw AgentBridgeError.invalidInput(localized("Choose a workspace folder before previewing context."))
        }
        let localSettings = discussions.first(where: { $0.id == id })?.provider == .local ? settings.localModel : nil
        return try service.previewDiscussionContext(
            id: id,
            currentPrompt: currentPrompt,
            settings: localSettings
        )
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
        guard !isChangingWorkspaceRoot, !isRunning, !isVerifying, !isSwitchingTarget,
              !terminalRunning, terminalLaunch == nil, !hasActiveAutonomousWorkflow,
              !hasActiveDiscussionOperation else { return }
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
        guard !hasActiveAutonomousWorkflow, !hasActiveDiscussionOperation else {
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
        guard !hasActiveAutonomousWorkflow, !hasActiveDiscussionOperation else {
            errorMessage = localized("Provider checks are paused while a discussion request is active.")
            return
        }
        guard let profile = selectedAccountProfile else { errorMessage = "找不到所選帳戶設定。"; return }
        checkAuthentication(for: profile)
    }

    private func checkAuthentication(for profile: AccountProfile) {
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

    func createDiscussion(provider: AgentProvider? = nil, profileID: UUID? = nil) {
        guard let service else { return }
        let targetProvider = provider ?? newDiscussionProvider
        let preferredProfileID = profileID
            ?? (targetProvider == newDiscussionProvider ? newDiscussionProfileID : nil)
            ?? discussionProfilePreferences[targetProvider]
            ?? selectedProfileIDs[targetProvider]
            ?? accountProfiles[targetProvider]?.first?.id
        guard let targetProfileID = preferredProfileID
            ?? (targetProvider == .local ? try? service.selectedAccountProfile(provider: .local).id : nil) else {
            errorMessage = localized("No account profile is available for this provider.")
            return
        }
        do {
            let discussion = try service.createDiscussion(provider: targetProvider, accountProfileID: targetProfileID)
            discussions = try service.discussions()
            discussionProfilePreferences[targetProvider] = targetProfileID
            persistDiscussionProfilePreferences()
            selectedDiscussionID = discussion.id
            isProjectConversationActive = false
            discussionProgress.removeValue(forKey: discussion.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setDiscussionTarget(id: UUID, provider: AgentProvider, profileID: UUID) {
        guard !hasActiveDiscussionOperation else {
            errorMessage = localized("A discussion request or project handoff is already in progress.")
            return
        }
        if let discussion = discussions.first(where: { $0.id == id }), discussion.status.isInFlight {
            errorMessage = localized("A discussion request or project handoff is already in progress.")
            return
        }
        guard let service,
              accountProfiles[provider]?.contains(where: { $0.id == profileID }) == true else {
            errorMessage = localized("Choose an available account profile.")
            return
        }
        do {
            let discussion = try service.setDiscussionTarget(id: id, provider: provider, accountProfileID: profileID)
            replaceDiscussion(discussion)
            discussionProfilePreferences[provider] = profileID
            persistDiscussionProfilePreferences()
            discussionProgress.removeValue(forKey: id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setDiscussionProvider(id: UUID, provider: AgentProvider) {
        guard let profileID = preferredDiscussionProfileID(for: provider) else {
            errorMessage = localized("No account profile is available for this provider.")
            return
        }
        setDiscussionTarget(id: id, provider: provider, profileID: profileID)
    }

    func selectNewDiscussionProvider(_ provider: AgentProvider) {
        newDiscussionProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.newDiscussionProviderPreferenceKey)
        let profileID = discussionProfilePreferences[provider]
            ?? selectedProfileIDs[provider]
            ?? accountProfiles[provider]?.first?.id
        newDiscussionProfileID = profileID
        if let profileID {
            discussionProfilePreferences[provider] = profileID
            persistDiscussionProfilePreferences()
        }
    }

    func selectNewDiscussionProfile(_ profileID: UUID) {
        guard accountProfiles[newDiscussionProvider]?.contains(where: { $0.id == profileID }) == true else { return }
        newDiscussionProfileID = profileID
        discussionProfilePreferences[newDiscussionProvider] = profileID
        persistDiscussionProfilePreferences()
    }

    func sendDiscussionMessage(
        id: UUID,
        prompt: String,
        isShareable: Bool,
        onCompletion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let service,
              let discussion = discussions.first(where: { $0.id == id }) else {
            onCompletion(false)
            return
        }
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            onCompletion(false)
            return
        }
        guard !hasActiveDiscussionOperation, !discussion.status.isInFlight,
              discussionCancellationFlags[id] == nil else {
            onCompletion(false)
            return
        }

        let hasConsent = profileAllowsSharedMemory(provider: discussion.provider, profileID: discussion.accountProfileID)
        let cancellation = CancellationFlag()
        discussionCancellationFlags[id] = cancellation
        discussionProgress[id] = localized(discussion.provider == .local
            ? "Sending to the configured local model…"
            : "Sending with the official CLI subscription sign-in…")
        errorMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let startingRevision = discussion.revision
            let refreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, self.discussionCancellationFlags[id] != nil else { return }
                    if let latest = self.refreshDiscussion(id: id),
                       latest.revision != startingRevision || latest.status.isInFlight {
                        return
                    }
                    do {
                        try await Task.sleep(nanoseconds: 250_000_000)
                    } catch {
                        return
                    }
                }
            }
            defer {
                refreshTask.cancel()
                self.discussionCancellationFlags.removeValue(forKey: id)
                self.refreshDiscussions()
                if discussion.provider == .local {
                    try? self.usage.refreshLocalModelUsageStatisticsIfNeeded(service: service, force: true)
                }
            }
            do {
                _ = try await service.sendDiscussionMessage(
                    id: id,
                    prompt: message,
                    isShareable: isShareable && hasConsent,
                    cancellation: cancellation
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.refreshDiscussion(id: id)
                        guard self.selectedDiscussionID == id else { return }
                        self.discussionProgress[id] = progress
                    }
                }
                _ = self.refreshDiscussion(id: id)
                self.discussionProgress[id] = self.localized("Response complete.")
                onCompletion(true)
            } catch {
                let persistedDiscussion = self.refreshDiscussion(id: id)
                if cancellation.isCancelled || persistedDiscussion?.status == .cancelled {
                    self.discussionProgress[id] = self.localized("Cancellation requested…")
                } else {
                    self.discussionProgress[id] = error.localizedDescription
                    self.errorMessage = error.localizedDescription
                }
                onCompletion(false)
            }
        }
    }

    func cancelDiscussion(id: UUID) {
        guard let service else { return }
        let cancellation = discussionCancellationFlags[id]
        cancellation?.cancel()

        guard let latest = refreshDiscussion(id: id) else {
            if cancellation != nil {
                discussionProgress[id] = localized("Cancellation requested…")
            }
            return
        }
        guard latest.status == .running else {
            if latest.status == .completed {
                discussionProgress[id] = localized("Response complete.")
            } else if cancellation != nil {
                discussionProgress[id] = localized("Cancellation requested…")
            }
            return
        }

        do {
            try service.cancelDiscussion(id: id)
            discussionProgress[id] = localized("Cancellation requested…")
            refreshDiscussion(id: id)
        } catch {
            let updated = refreshDiscussion(id: id)
            if updated?.status == .completed {
                discussionProgress[id] = localized("Response complete.")
            } else if updated?.status == .cancelled || cancellation != nil {
                discussionProgress[id] = localized("Cancellation requested…")
            } else if updated?.status == .running {
                discussionProgress[id] = error.localizedDescription
            }
        }
    }

    func prepareDiscussionProjectHandoff(
        discussionID: UUID,
        destinationPath: String,
        mode: DiscussionProjectMode,
        targetProvider: AgentProvider,
        targetProfileID: UUID,
        selectedTurnIDs: Set<UUID>,
        accessMode: AccessMode = .readOnly
    ) async throws -> DiscussionProjectHandoff {
        guard let service else { throw AgentBridgeError.persistence("The workspace data root is not ready.") }
        isPreparingDiscussionHandoff = true
        defer { isPreparingDiscussionHandoff = false }
        let handoff = try await service.prepareDiscussionProjectHandoff(
            discussionID: discussionID,
            destinationPath: destinationPath,
            mode: mode,
            targetProvider: targetProvider,
            targetProfileID: targetProfileID,
            selectedTurnIDs: selectedTurnIDs,
            accessMode: accessMode
        )
        refreshDiscussions()
        return handoff
    }

    func createOrAttachProjectFromDiscussion(
        handoffID: UUID,
        reviewedDigest: String
    ) async throws -> SessionRecord {
        guard let service else { throw AgentBridgeError.persistence("The workspace data root is not ready.") }
        isApplyingDiscussionHandoff = true
        defer { isApplyingDiscussionHandoff = false }
        let session = try await service.createOrAttachProjectFromDiscussion(
            handoffID: handoffID,
            reviewedDigest: reviewedDigest,
            explicitConfirmation: true
        )
        refresh()
        refreshDiscussions()
        selectedDiscussionID = nil
        isProjectConversationActive = true
        selectedSessionID = session.id
        return session
    }

    private func replaceDiscussion(_ discussion: DiscussionRecord) {
        if let index = discussions.firstIndex(where: { $0.id == discussion.id }) {
            discussions[index] = discussion
        } else {
            discussions.insert(discussion, at: 0)
        }
        discussions.sort { $0.updatedAt > $1.updatedAt }
    }

    private func reconcileNewDiscussionTarget() {
        if !hasInitializedNewDiscussionTarget {
            if UserDefaults.standard.string(forKey: Self.newDiscussionProviderPreferenceKey) == nil {
                newDiscussionProvider = settings.defaultProvider
            }
            hasInitializedNewDiscussionTarget = true
        }
        let availableProfiles = accountProfiles[newDiscussionProvider] ?? []
        if let newDiscussionProfileID,
           availableProfiles.contains(where: { $0.id == newDiscussionProfileID }) { return }
        let preferredProfileID = discussionProfilePreferences[newDiscussionProvider]
        let selectedProfileID = selectedProfileIDs[newDiscussionProvider]
        newDiscussionProfileID = [preferredProfileID, selectedProfileID, availableProfiles.first?.id]
            .compactMap { $0 }
            .first(where: { id in availableProfiles.contains(where: { $0.id == id }) })
        if let newDiscussionProfileID {
            discussionProfilePreferences[newDiscussionProvider] = newDiscussionProfileID
            persistDiscussionProfilePreferences()
        }
    }

    private func persistDiscussionProfilePreferences() {
        let values = Dictionary(uniqueKeysWithValues: discussionProfilePreferences.map {
            ($0.key.rawValue, $0.value.uuidString.lowercased())
        })
        UserDefaults.standard.set(values, forKey: Self.discussionProfilePreferencesKey)
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

    func saveChangePlan() {
        guard !hasActiveAutonomousWorkflow else {
            errorMessage = localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service, let session = selectedSession,
              session.policy.accessMode == .isolatedChanges else {
            errorMessage = "請先建立隔離變更工作階段。"
            return
        }
        let steps = changePlanStepsText
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        do {
            let plan = try service.createChangePlan(
                sessionID: session.id,
                title: changePlanTitle,
                summary: changePlanSummary,
                steps: steps
            )
            changePlanTitle = plan.title
            changePlanSummary = plan.summary
            changePlanStepsText = plan.steps.joined(separator: "\n")
            status = "計畫已保存為待檢視狀態；尚未授權寫入。"
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func approveChangePlan() {
        guard !hasActiveAutonomousWorkflow else {
            errorMessage = localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service, let session = selectedSession, let plan = session.changePlan else {
            errorMessage = "請先保存一份工作計畫。"
            return
        }
        guard selectedChangePlanDraftMatchesSaved else {
            errorMessage = localized("Save your plan changes before review or approval.")
            return
        }
        do {
            _ = try service.approveChangePlan(sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest)
            status = "已明確核准目前顯示的計畫；現在可以執行隔離變更。"
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runApprovedChanges() {
        guard let service, let session = selectedSession, let plan = session.changePlan else {
            errorMessage = "請先保存並明確核准目前的工作計畫。"
            return
        }
        guard selectedChangePlanDraftMatchesSaved else {
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

    func restoreChangeFile(_ path: String) {
        guard !hasActiveAutonomousWorkflow else {
            errorMessage = localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service, let session = selectedSession else { return }
        Task { @MainActor [weak self] in
            do {
                try await service.restoreChangeFiles(sessionID: session.id, filePaths: [path])
                self?.refreshSelectedEvents()
                self?.refresh()
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func restoreAllChangeFiles() {
        guard !hasActiveAutonomousWorkflow else {
            errorMessage = localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service, let session = selectedSession else { return }
        Task { @MainActor [weak self] in
            do {
                try await service.restoreAllChanges(sessionID: session.id)
                self?.refreshSelectedEvents()
                self?.refresh()
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func exportChangePatch() {
        guard let service, let session = selectedSession else { return }
        Task { @MainActor [weak self] in
            do {
                let patch = try await service.exportChangePatch(sessionID: session.id)
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "AgentBridge-\(session.id.uuidString.prefix(8)).patch"
                panel.allowedContentTypes = [.plainText]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try patch.write(to: url, options: .atomic)
                self?.status = "已匯出 \(patch.count) 位元組補丁。"
                self?.refreshSelectedEvents()
            } catch { self?.errorMessage = error.localizedDescription }
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
        let executable = custom ? URL(fileURLWithPath: customVerifierPath) : nil
        let arguments = custom ? customVerifierArgumentsText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) : []
        let cancellation = CancellationFlag()
        activeRunFlags[session.id] = cancellation
        activeRunSessionID = session.id
        isRunning = true
        isVerifying = true
        verificationResult = nil
        Task { @MainActor [self] in
            defer {
                activeRunFlags.removeValue(forKey: session.id)
                isRunning = !activeRunFlags.isEmpty
                isVerifying = false
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
                verificationResult = result
                status = result.succeeded
                    ? "驗證 CLI 回報成功；退出代碼 0，耗時 \(String(format: "%.2f", result.durationSeconds)) 秒。"
                    : "驗證未通過或未完成；請查看 CLI 輸出與活動記錄。"
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func chooseCustomVerifier() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Executable"
        if panel.runModal() == .OK, let url = panel.url { customVerifierPath = url.path }
    }

    func acceptChanges() {
        guard !hasActiveAutonomousWorkflow else {
            errorMessage = localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service, let session = selectedSession else { return }
        Task { @MainActor [weak self] in
            do {
                _ = try await service.acceptChanges(sessionID: session.id)
                self?.status = "已接受目前已驗證的差異；來源儲存庫仍未修改。"
                self?.refresh()
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }

    func applyChangesToBranch() {
        guard !hasActiveAutonomousWorkflow else {
            errorMessage = localized("Changes are locked while an autonomous workflow is active.")
            return
        }
        guard let service, let session = selectedSession else { return }
        let requestedBranchName = branchName
        Task { @MainActor [weak self] in
            do {
                let result = try await service.applyChangesToLocalBranch(sessionID: session.id, branchName: requestedBranchName)
                self?.status = "已建立未提交工作樹：\(result.worktreePath)；沒有建立提交、推送或合併。"
                self?.refresh()
            } catch { self?.errorMessage = error.localizedDescription }
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

    var selectedExtensionDescriptor: ExtensionDescriptor? {
        extensionDescriptors.first(where: { $0.id == selectedExtensionID })
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

    func refreshActiveExtensionConfigurations() {
        guard let service else { return }
        do {
            activeExtensionConfigurations = try service.activeExtensionConfigurations()
            activeExtensionError = nil
        } catch {
            activeExtensionError = error.localizedDescription
        }
    }

    func importSkillRuntime(descriptor: ExtensionDescriptor, sourceReference: String, skillFileURL: URL) throws -> ActiveSkillSnapshot {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        let snapshot = try service.importSkillRuntime(descriptor: descriptor, sourceReference: sourceReference, skillFileURL: skillFileURL)
        refreshActiveExtensionConfigurations()
        activeExtensionStatus = localized("Skill instructions were imported as a bounded snapshot; no script was executed.")
        return snapshot
    }

    func importMCPRuntimeManifest(at manifestURL: URL) throws -> ActiveMCPConfiguration {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        let configuration = try service.importMCPRuntimeManifest(at: manifestURL)
        refreshActiveExtensionConfigurations()
        activeExtensionStatus = localized("MCP configuration was imported. The process has not been started.")
        return configuration
    }

    func testMCPRuntime(extensionID: String) async throws -> MCPServerInspection {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        guard canStartAutonomousWorkflow else {
            throw AgentBridgeError.invalidInput("Wait for provider sessions and terminals to stop before testing an MCP process.")
        }
        isTestingMCPRuntime = true
        defer { isTestingMCPRuntime = false }
        return try await service.testMCPRuntime(extensionID: extensionID)
    }

    func refreshMacControlPresetStatus(targetBundleID: String?, accessMode: MacControlAccessMode) {
        guard let service else { return }
        detectedMacControlPresetStatus = service.macControlPresetStatus(
            targetBundleID: targetBundleID,
            accessMode: accessMode
        )
        macControlStatusError = nil
    }

    func importMacControlPreset(targetBundleID: String, accessMode: MacControlAccessMode) throws -> ActiveMCPConfiguration {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        guard canStartAutonomousWorkflow else {
            throw AgentBridgeError.invalidInput("Wait for provider sessions and terminals to stop before changing an extension runtime.")
        }
        let configuration = try service.importMacControlPreset(targetBundleID: targetBundleID, accessMode: accessMode)
        refreshActiveExtensionConfigurations()
        refreshMacControlPresetStatus(targetBundleID: targetBundleID, accessMode: accessMode)
        activeExtensionStatus = localized("The Mac Control preset was imported. Screen or input access is not enabled.")
        return configuration
    }

    func testMacControlPermissions(targetBundleID: String) async throws -> MacControlPermissionReadiness {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        guard canStartAutonomousWorkflow else {
            throw AgentBridgeError.invalidInput("Wait for provider sessions and terminals to stop before checking Mac Control permissions.")
        }
        isTestingMCPRuntime = true
        isCheckingMacControlPermissions = true
        defer {
            isTestingMCPRuntime = false
            isCheckingMacControlPermissions = false
        }
        let readiness = try await service.testMacControlPermissions(targetBundleID: targetBundleID)
        macControlPermissionReadiness = readiness
        macControlStatusError = nil
        return readiness
    }

    func stopMacControl(extensionID: String, sessionID: UUID) throws -> [UUID] {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        let cancelledSessionIDs = try service.stopMacControl(extensionID: extensionID, sessionID: sessionID)
        activeExtensionStatus = cancelledSessionIDs.isEmpty
            ? localized("Mac Control Control access was revoked for this scope.")
            : localizedFormat("Mac Control was stopped and cancellation was requested for %@ affected session(s).", String(cancelledSessionIDs.count))
        refreshActiveExtensionConfigurations()
        return cancelledSessionIDs
    }

    func previewExtensionActivation(extensionID: String, sessionID: UUID) throws -> ActiveExtensionActivationReview {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        return try service.previewExtensionActivation(extensionID: extensionID, sessionID: sessionID)
    }

    func enableExtensionRuntime(
        extensionID: String,
        sessionID: UUID,
        reviewedDigest: String,
        explicitExecutionConsent: Bool,
        explicitScreenCaptureConsent: Bool = false,
        explicitInputControlConsent: Bool = false
    ) throws -> ActiveExtensionGrant {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        let grant = try service.enableExtensionRuntime(
            extensionID: extensionID,
            sessionID: sessionID,
            reviewedDigest: reviewedDigest,
            explicitExecutionConsent: explicitExecutionConsent,
            explicitScreenCaptureConsent: explicitScreenCaptureConsent,
            explicitInputControlConsent: explicitInputControlConsent
        )
        activeExtensionStatus = localized("The extension is enabled for this exact project, provider, and account profile. New sessions will receive this snapshot.")
        refreshActiveExtensionConfigurations()
        return grant
    }

    func disableExtensionRuntime(extensionID: String, sessionID: UUID) throws -> Bool {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        let disabled = try service.disableExtensionRuntime(extensionID: extensionID, sessionID: sessionID)
        activeExtensionStatus = localized("The extension was disabled for this exact project, provider, and account profile.")
        return disabled
    }

    func createExtensionTargetSession(sourcePath: String, provider: AgentProvider, profileID: UUID) async throws -> SessionRecord {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        return try await service.createSession(
            sourcePath: sourcePath,
            provider: provider,
            accessMode: .readOnly,
            accountProfileID: profileID
        )
    }

    func extensionProjectID(sessionID: UUID) throws -> String {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        return try service.extensionProjectID(sessionID: sessionID)
    }

    func activeExtensionsForSession(sessionID: UUID, extensionIDs: [String]? = nil) throws -> ActiveExtensionInvocation {
        guard let service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        return try service.activeExtensionsForSession(sessionID: sessionID, extensionIDs: extensionIDs)
    }

    var selectedExtensionGrant: ExtensionGrant? {
        guard let service, let session = selectedSession, !selectedExtensionID.isEmpty,
              let projectID = try? service.extensionProjectID(sessionID: session.id) else { return nil }
        return try? service.extensionGrant(extensionID: selectedExtensionID, projectID: projectID)
    }

    func selectedExtensionDidChange() {
        loadSelectedExtensionGrant()
    }

    private func loadSelectedExtensionGrant() {
        guard let grant = selectedExtensionGrant else {
            selectedExtensionPermissions = []
            extensionPathScopesText = ""
            extensionHostScopesText = ""
            return
        }
        selectedExtensionPermissions = Set(grant.permissions)
        extensionPathScopesText = grant.allowedRelativePaths.joined(separator: "\n")
        extensionHostScopesText = grant.allowedHosts.joined(separator: "\n")
    }

    func importExtensionDescriptor(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try BoundedDescriptorFileReader.read(at: url)
            let descriptor = try JSONDecoder().decode(ExtensionDescriptor.self, from: data)
            let source: ExtensionImportSource = descriptor.kind == .skill ? .localMetadata : .localMetadata
            _ = try service?.importExtensionDescriptor(descriptor, source: source, sourceReference: url.path)
            extensionDescriptors = try service?.extensionDescriptors() ?? []
            selectedExtensionID = descriptor.id
            status = "已匯入惰性擴充功能中繼資料；未執行任何指令或腳本。"
        } catch { errorMessage = error.localizedDescription }
    }

    func grantSelectedExtension() {
        guard let service, let session = selectedSession, !selectedExtensionID.isEmpty else { return }
        do {
            let projectID = try service.extensionProjectID(sessionID: session.id)
            let paths = extensionPathScopesText.split(whereSeparator: \.isNewline).map(String.init)
            let hosts = extensionHostScopesText.split(whereSeparator: \.isNewline).map(String.init)
            _ = try service.grantExtensionPermissions(
                extensionID: selectedExtensionID,
                projectID: projectID,
                permissions: selectedExtensionPermissions.sorted { $0.rawValue < $1.rawValue },
                allowedRelativePaths: paths,
                allowedHosts: hosts
            )
            status = "已保存此專案的窄範圍政策中繼資料；擴充功能仍未啟用或執行。"
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }

    func revokeSelectedExtension() {
        guard let service, let session = selectedSession, !selectedExtensionID.isEmpty else { return }
        do {
            let projectID = try service.extensionProjectID(sessionID: session.id)
            _ = try service.revokeExtensionPermissions(extensionID: selectedExtensionID, projectID: projectID)
            status = "已撤銷此專案的擴充功能權限政策。"
            refresh()
        } catch { errorMessage = error.localizedDescription }
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

    func openEmbeddedInteractiveTerminal() {
        guard !hasActiveAutonomousWorkflow else {
            errorMessage = localized("The terminal is locked while an autonomous workflow is active.")
            return
        }
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
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        terminalTitle = spec.title
        activeTerminalProfileID = profileID
        activeTerminalSessionID = session.id
        terminalNeedsManualStop = false
        closeTerminalAfterCancellation = false
        terminalLaunch = spec
        terminalRunning = true
        status = "已在 App 內啟動互動終端機。終端機文字不會自動加入共用記憶。"
    }

    func openSubscriptionUsageTUI() {
        guard !hasActiveAutonomousWorkflow else {
            errorMessage = localized("The terminal is locked while an autonomous workflow is active.")
            return
        }
        guard settings.usageMode == .subscription else {
            errorMessage = "官方 usage TUI 只支援訂閱登入。"
            return
        }
        guard terminalLaunch == nil else {
            errorMessage = "請先關閉目前的 App 終端機。"
            return
        }
        let provider = settings.defaultProvider
        guard provider != .local else {
            errorMessage = localized("Local models do not have a provider subscription usage screen.")
            return
        }
        guard let profileID = selectedProfileIDs[provider],
              let profile = accountProfiles[provider]?.first(where: { $0.id == profileID }) else {
            errorMessage = "找不到目前選取的帳戶設定。"
            return
        }
        guard let spec = terminalLaunchSpec(
            title: "官方用量 · \(provider.rawValue.capitalized) · \(profile.name)",
            arguments: [
                "usage-tui",
                "--provider", provider.rawValue,
                "--profile", profile.id.uuidString.lowercased()
            ],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ) else {
            errorMessage = "找不到 AgentBridge 命令列輔助程式。請先使用 scripts/package-app.sh 建立 .app。"
            return
        }
        terminalIsProfileLogin = false
        terminalIsUsageTUI = true
        activeUsageProvider = provider
        providerUsageReport = nil
        terminalTitle = spec.title
        activeTerminalProfileID = profile.id
        activeTerminalSessionID = nil
        terminalNeedsManualStop = true
        closeTerminalAfterCancellation = false
        usageCommandRequest = 0
        terminalLaunch = spec
        terminalRunning = true
        status = "已啟動所選帳戶的官方 CLI 用量終端；請等待可輸入提示符並完成登入，再送出 /usage。"
    }

    func requestUsageCommand() {
        guard canSendUsageCommand else { return }
        usageCommandRequest &+= 1
        status = "已在目前官方 CLI 終端送出固定的 /usage 指令。"
    }

    func usageScreenDidUpdate(_ screenText: String, capturedAt: Date) -> Bool {
        guard terminalIsUsageTUI,
              let provider = activeUsageProvider,
              settings.defaultProvider == provider,
              settings.usageMode == .subscription,
              let profileID = activeTerminalProfileID,
              selectedProfileIDs[provider] == profileID,
              let profile = accountProfiles[provider]?.first(where: { $0.id == profileID }) else { return false }
        let report = ProviderUsageReportParser.parse(
            screenText: screenText,
            provider: provider,
            accountProfileID: profileID,
            accountName: profile.name,
            capturedAt: capturedAt
        )
        providerUsageReport = report
        return report.usageWindows.contains { $0.percentageUsed != nil || $0.resetText != nil }
    }

    func openProfileLoginTerminal() {
        guard let profile = selectedAccountProfile else { errorMessage = "找不到所選帳戶設定。"; return }
        openProfileLoginTerminal(for: profile)
    }

    func openProfileLoginTerminal(for profile: AccountProfile) {
        guard profile.provider != .local else {
            reportOperationError(localized("Local models do not use CLI sign-in."))
            return
        }
        guard !hasActiveAutonomousWorkflow else {
            reportOperationError(localized("The terminal is locked while an autonomous workflow is active."))
            return
        }
        guard !terminalRunning else {
            reportOperationError(localized("Close the current terminal before opening sign-in."))
            return
        }
        guard !profile.usesExistingLogin else {
            reportOperationError(localized("This built-in account keeps its existing CLI login. Add an isolated account to sign in separately."))
            return
        }
        guard let spec = terminalLaunchSpec(
            title: "登入 · \(profile.provider.rawValue.capitalized) · \(profile.name)",
            arguments: ["profile-login", profile.id.uuidString.lowercased()],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ) else {
            reportOperationError("找不到 AgentBridge 命令列輔助程式。請先使用 scripts/package-app.sh 建立 .app。")
            return
        }
        terminalIsProfileLogin = true
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        terminalTitle = spec.title
        activeTerminalProfileID = profile.id
        activeTerminalSessionID = nil
        terminalNeedsManualStop = true
        closeTerminalAfterCancellation = false
        terminalLaunch = spec
        terminalRunning = true
        status = "已在 App 內開啟官方 CLI 登入流程。登入由你在終端機完成。"
        setupWizard.errorMessage = nil
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
        terminalIsUsageTUI = false
        activeUsageProvider = nil
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
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        activeTerminalProfileID = nil
        activeTerminalSessionID = nil
        terminalNeedsManualStop = false
        status = "已關閉 App 內終端機。"
    }

    func terminalDidTerminate(exitCode: Int32?) {
        terminalRunning = false
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        if let exitCode, exitCode == 0 {
            status = "終端機工作已完成。"
        } else {
            status = "終端機工作已結束\(exitCode.map { "（代碼 \($0)）" } ?? "")。"
        }
        if terminalIsProfileLogin, let profileID = activeTerminalProfileID,
           let profile = accountProfiles.values.flatMap({ $0 }).first(where: { $0.id == profileID }) {
            checkAuthentication(for: profile)
        }
        refresh(forceUsageStatistics: true)
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
        guard !hasActiveAutonomousWorkflow, !hasActiveDiscussionOperation else {
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
            providerUsageReport = nil
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
        guard !hasActiveAutonomousWorkflow, !hasActiveDiscussionOperation else {
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
            providerUsageReport = nil
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
        guard !hasActiveAutonomousWorkflow, !hasActiveDiscussionOperation else {
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
