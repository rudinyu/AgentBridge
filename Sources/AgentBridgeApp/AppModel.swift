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
    var status = "Ready."
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
    /// What the last compatibility check found for each CLI, by provider.
    var cliCompatibility: [AgentProvider: CLICompatibilityReport] = [:]
    var selectedProfileIDs: [AgentProvider: UUID] = [:]
    var newProfileName = ""
    var newProfileAllowsSharedMemory = true
    var memorySnapshot: SharedMemorySnapshot?
    var memoryNotes = ""
    var confirmClearMemory = false
    var isSwitchingTarget = false

    private(set) var service: BridgeService?
    @ObservationIgnored private(set) var refreshGeneration = 0
    @ObservationIgnored private var isRefreshingInBackground = false
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
                status = "Choose a workspace data root to get started."
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
            refreshCLICompatibility()
            setupWizard.initialize(workspaceRootConfigured: true)
        } catch {
            if let root = try? RuntimePaths.requireWorkspaceRoot() { workspaceRootPath = root.path }
            errorMessage = error.localizedDescription
            setupWizard.initialize(workspaceRootConfigured: workspaceRootIsConfigured)
        }
    }

    /// An `AppModel` backed by an explicit store and service, for tests. It never
    /// reads the user's real data root or saved preferences.
    init(store: AuditStore, service: BridgeService) {
        appLanguage = .english
        setupWizard.attach(to: self)
        usage.attach(to: self)
        chats.attach(to: self)
        changes.attach(to: self)
        extensions.attach(to: self)
        terminal.attach(to: self)
        self.store = store
        self.service = service
        workspaceRootPath = store.workspaceRootURL?.path ?? ""
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
            ?? (session.provider == .local ? localized("Local account") : localized("Current local login"))
    }

    func boundProfile(for session: SessionRecord) -> AccountProfile? {
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        return accountProfiles[session.provider]?.first(where: { $0.id == profileID })
    }

    /// Reads the current data and applies it right away. Use it after an action
    /// that changed something and whose result the caller is about to read.
    func refresh(forceUsageStatistics: Bool = false) {
        guard let service else { return }
        refreshGeneration += 1
        apply(RefreshReads.load(service: service, selectedSessionID: selectedSessionID), forceUsageStatistics: forceUsageStatistics)
    }

    /// The periodic refresh. The disk reads run off the main thread and only
    /// their result is applied here, so a large store cannot stall the window
    /// every few seconds. A synchronous `refresh()` that runs meanwhile already
    /// applied newer data, so a result loaded before it is dropped.
    func refreshInBackground() {
        guard let service, !isRefreshingInBackground else { return }
        isRefreshingInBackground = true
        let generation = refreshGeneration
        let selected = selectedSessionID
        Task.detached(priority: .utility) { [weak self] in
            let reads = RefreshReads.load(service: service, selectedSessionID: selected)
            await MainActor.run { [weak self] in
                self?.finishBackgroundRefresh(reads, loadedAt: generation)
            }
        }
    }

    func finishBackgroundRefresh(_ reads: RefreshReads, loadedAt generation: Int) {
        isRefreshingInBackground = false
        guard generation == refreshGeneration else { return }
        apply(reads, forceUsageStatistics: false)
    }

    private func apply(_ reads: RefreshReads, forceUsageStatistics: Bool) {
        guard let service else { return }
        do {
            let previousSelectedSessionID = selectedSessionID
            var loadedSettings = try reads.settings.get()
            if loadedSettings.defaultProvider == .codex, loadedSettings.usageMode == .api {
                loadedSettings.usageMode = .subscription
                try service.saveSettings(loadedSettings)
                status = "Codex uses its official CLI subscription sign-in. An older incompatible setting was corrected."
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
            let profiles = try reads.accountProfiles.get()
            let selectedIDs = try reads.selectedProfileIDs.get()
            for provider in AgentProvider.allCases {
                accountProfiles[provider] = profiles[provider]
                selectedProfileIDs[provider] = selectedIDs[provider]
            }
            chats.reconcileNewDiscussionTarget()
            terminal.adoptSavedUsageReports(reads.savedUsageReports)
            sessions = try reads.sessions.get()
            chats.applyDiscussions(reads.discussions)
            taskRecords = try reads.taskRecords.get()
            extensions.extensionDescriptors = try reads.extensionDescriptors.get()
            do {
                autonomousRuns = try reads.autonomousRuns.get().sorted { $0.plan.createdAt > $1.plan.createdAt }
                if selectedAutonomousRunID == nil || !autonomousRuns.contains(where: { $0.id == selectedAutonomousRunID }) {
                    selectedAutonomousRunID = autonomousRuns.first?.id
                }
            } catch {
                autonomousError = error.localizedDescription
            }
            do {
                extensions.activeExtensionConfigurations = try reads.activeExtensions.get()
            } catch {
                extensions.activeExtensionError = error.localizedDescription
            }
            if selectedSessionID == nil, let first = sessions.first {
                selectedSessionID = first.id
            }
            if let selectedSessionID {
                applySelectedSessionReads(reads, for: selectedSessionID)
            }
            if previousSelectedSessionID != selectedSessionID {
                changes.loadChangePlanDraftFromSelectedSession()
            }
            try usage.refresh(service: service, force: forceUsageStatistics)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Applies the events, shared memory and handoffs read for `sessionID`. A
    /// read made for a different session, because the selection changed while it
    /// was loading, is skipped; the next refresh reads the right one.
    private func applySelectedSessionReads(_ reads: RefreshReads, for sessionID: UUID) {
        guard reads.sessionID == sessionID, let selected = reads.selected else { return }
        switch selected {
        case .success(let session):
            events = session.events
            outputText = events.last(where: { $0.kind == "run.output" })?.message ?? ""
            if memorySnapshot?.scope.key != session.memory.scope.key { memoryNotes = session.memory.notes }
            memorySnapshot = session.memory
            projectMemoryHandoffs = session.handoffs
            refreshChangeDiffIfNeeded(for: sessionID)
        case .failure(let error):
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
            refreshChangeDiffIfNeeded(for: selectedSessionID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshChangeDiffIfNeeded(for selectedSessionID: UUID) {
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
                ? "Switched to Codex and saved official CLI subscription mode."
                : "The default assistant for new sessions was saved."
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
            status = "Claude usage mode was saved."
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
        panel.title = localized("Choose a Git Repository Root")
        panel.message = localized("AgentBridge copies the current commit into a private isolated workspace. Uncommitted source changes are not copied.")
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
        panel.title = localized("Choose workspace data root")
        panel.message = localized("AgentBridge stores isolated workspaces and shared memory in this folder. Private settings and usage data stay in Application Support.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isChangingWorkspaceRoot = true
        status = localized("Safely copying existing workspaces and shared memory…")
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
                status = localized("Workspace data root updated. Existing data remains at its previous location.")
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

    /// Asks each installed CLI for its version and help in the background and
    /// records whether AgentBridge still matches it. Advisory only.
    func refreshCLICompatibility() {
        guard let service else { return }
        Task.detached(priority: .utility) { [weak self] in
            var collected: [AgentProvider: CLICompatibilityReport] = [:]
            for provider in [AgentProvider.codex, .claude] {
                if let report = try? await service.cliCompatibility(provider: provider) { collected[provider] = report }
            }
            let reports = collected
            await MainActor.run { [weak self] in self?.cliCompatibility = reports }
        }
    }

    /// The warning lines to show for a CLI, empty when it matches what AgentBridge was verified with.
    func cliCompatibilityWarnings(for provider: AgentProvider) -> [String] {
        guard let report = cliCompatibility[provider] else { return [] }
        var lines: [String] = []
        switch report.versionStatus {
        case .olderThanTested:
            lines.append(localizedFormat("CLI version %@ is older than the verified %@; some features may not work.", report.version ?? "?", report.testedVersion))
        case .unreadable:
            lines.append(localizedFormat("Could not read the CLI version; AgentBridge was verified with %@.", report.testedVersion))
        case .matchesTested, .newerThanTested:
            break
        }
        if !report.flagsWereChecked {
            lines.append(localized("Could not read the CLI help, so the required flags were not confirmed."))
        }
        if !report.missingFlags.isEmpty {
            lines.append(localizedFormat("The CLI help no longer lists flags AgentBridge needs: %@.", report.missingFlags.joined(separator: " ")))
        }
        return lines
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
            status = "Settings saved."
            refresh()
            refreshCLICompatibility()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkAuthentication() {
        guard !hasActiveAutonomousWorkflow, !chats.hasActiveDiscussionOperation else {
            errorMessage = localized("Provider checks are paused while a discussion request is active.")
            return
        }
        guard let profile = selectedAccountProfile else { errorMessage = "The selected account settings could not be found."; return }
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
        status = "Checking official CLI sign-in status…"
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
                status = "Sign-in check failed."
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
        guard !repositoryPath.isEmpty else { errorMessage = "Select a Git repository first."; return }
        guard provider != .local || requestedAccessMode == .readOnly else {
            errorMessage = localized("Local project chat only supports read-only sessions.")
            return
        }
        guard provider == .local || requestedAccessMode != .interactiveManualApproval || settings.usageMode == .subscription else {
            errorMessage = "Interactive mode currently supports subscription sign-in only."
            return
        }
        guard provider == .local || requestedAccessMode != .isolatedChanges || settings.usageMode == .subscription else {
            errorMessage = "Isolated-changes mode supports only the subscription sign-in; Claude API can create read-only sessions only."
            return
        }
        do {
            try service.saveSettings(settings)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        status = "Creating an isolated workspace for the pinned commit…"
        let access = requestedAccessMode
        Task {
            do {
                let session = try await service.createSession(sourcePath: repositoryPath, provider: provider, accessMode: access)
                status = session.sourceWasDirty ? "Session created. Uncommitted source changes were excluded." : "Session created."
                refresh()
                isProjectConversationActive = true
                selectedSessionID = session.id
                selectedSessionDidChange()
            } catch {
                errorMessage = error.localizedDescription
                status = "Could not create the session."
            }
        }
    }

    func runPrompt() {
        guard let service, let session = selectedSession else { errorMessage = "Select a session."; return }
        guard session.policy.accessMode == .readOnly else {
            errorMessage = session.policy.accessMode == .isolatedChanges
                ? "For an isolated-changes session, create, review and approve a work plan before running changes."
                : "Start native interactive sessions from the Terminal panel."
            return
        }
        guard canStartAnotherRun else {
            errorMessage = hasActiveAutonomousWorkflow
                ? localized("Manual provider runs are paused while an autonomous workflow is active.")
                : "Up to three different sessions can run at once; the current session also cannot run twice."
            return
        }
        var apiRequest: APIUsageRequest?
        if settings.usageMode == .api && session.provider != .local {
            guard isClaudeAPIRunContext else {
                errorMessage = "Claude API is available only with Claude selected as the default assistant and in a Claude session."
                return
            }
            guard let budget = Double(apiBudget), budget.isFinite, budget > 0, !apiKey.isEmpty, confirmAPIRun else {
                errorMessage = "API mode requires a per-run budget, an API key, and explicit confirmation."
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
            : (settings.usageMode == .api ? "Checking and reserving the budget…" : "Running…")
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
                status = "Response finished."
                prompt = ""
            } catch {
                errorMessage = error.localizedDescription
                status = "Run ended."
            }
        }
    }

    func runApprovedChanges() {
        guard let service, let session = selectedSession, let plan = session.changePlan else {
            errorMessage = "Save and explicitly approve the current work plan first."
            return
        }
        guard changes.selectedChangePlanDraftMatchesSaved else {
            errorMessage = localized("Save your plan changes before review or approval.")
            return
        }
        guard session.approvedChangePlanDigest == plan.reviewDigest else {
            errorMessage = "Save and explicitly approve the current work plan first."
            return
        }
        guard settings.usageMode == .subscription else {
            errorMessage = "Isolated changes support only the official CLI subscription sign-in."
            return
        }
        guard canStartAnotherRun else {
            errorMessage = hasActiveAutonomousWorkflow
                ? localized("Manual provider runs are paused while an autonomous workflow is active.")
                : "Up to three different sessions can run at once; the current session also cannot run twice."
            return
        }
        let promptValue = prompt
        guard !promptValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Enter the change request for the assistant."
            return
        }
        let cancellation = CancellationFlag()
        activeRunFlags[session.id] = cancellation
        activeRunSessionID = session.id
        isRunning = true
        errorMessage = nil
        status = "Running the approved changes in the isolated workspace…"
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
                status = "The CLI reported the change run finished; review the full file diff."
            } catch {
                errorMessage = error.localizedDescription
                status = "The change run ended."
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
            errorMessage = "This session already has work in progress."
            return
        }
        guard activeRunFlags.count < 3 else { errorMessage = "Up to three tasks can run at once."; return }
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
                    ? "The verification CLI reported success; exit code 0, took \(String(format: "%.2f", result.durationSeconds)) s."
                    : "Verification did not pass or did not finish; check the CLI output and the activity log."
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
            status = "Created an explicit memory handoff: \(handoff.sourceCommit.prefix(12)) → \(handoff.targetCommit.prefix(12))."
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
            status = "Cancellation request sent…"
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
            status = "Switched to the same-project \(provider.rawValue.capitalized) session; shared memory is unchanged."
            return
        }
        repositoryPath = anchor.sourceRepositoryPath
        requestedAccessMode = access
        isSwitchingTarget = true
        status = "Creating an isolated workspace for this project and the selected assistant and account…"
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
                    ? "Session switched. Accounts that consented can load shared memory for the same commit."
                    : "A new session was created for the current commit. A different commit uses separate shared memory."
            } catch {
                errorMessage = error.localizedDescription
                status = "Could not switch sessions."
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
        guard !name.isEmpty else { errorMessage = "Enter a name for the new account."; return }
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
            status = allowed ? "This account can now load and save shared project memory." : "This account will not load or save shared project memory."
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
            status = "Shared memory notes saved."
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
            status = "Shared memory for this project and commit was cleared."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
