import AppKit
import Combine
import Darwin
import AgentBridgeCore
import Charts
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

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
    @Published var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: AppLanguage.preferenceKey) }
    }
    @Published var isSetupWizardPresented = false
    @Published var setupWizardStep: SetupWizardStep = .welcome {
        didSet { UserDefaults.standard.set(setupWizardStep.rawValue, forKey: Self.setupWizardStepPreferenceKey) }
    }
    @Published var setupWizardProvider: AgentProvider = .codex {
        didSet { UserDefaults.standard.set(setupWizardProvider.rawValue, forKey: Self.setupWizardProviderPreferenceKey) }
    }
    @Published var setupWizardProfileName = "" {
        didSet { UserDefaults.standard.set(setupWizardProfileName, forKey: Self.setupWizardProfileNamePreferenceKey) }
    }
    @Published var setupWizardCLIPath = "" {
        didSet {
            UserDefaults.standard.set(setupWizardCLIPath, forKey: Self.setupWizardCLIPathPreferenceKey(for: setupWizardProvider))
        }
    }
    @Published var setupWizardCLIStatus = ""
    @Published var setupWizardUsageControls = UsageControlSettings()
    @Published var setupWizardUsageStatus = ""
    @Published var setupWizardStatus = ""
    @Published var setupWizardError: String?
    @Published var setupWizardAuthCheckInProgress = false
    @Published var settings = BridgeSettings()
    @Published var sessions: [SessionRecord] = []
    @Published var discussions: [DiscussionRecord] = []
    @Published var events: [AuditEvent] = []
    @Published var selectedSessionID: UUID?
    @Published var selectedDiscussionID: UUID?
    @Published var isProjectConversationActive = false
    @Published var discussionProgress: [UUID: String] = [:]
    @Published var isPreparingDiscussionHandoff = false
    @Published var isApplyingDiscussionHandoff = false
    @Published var newDiscussionProvider: AgentProvider = .codex
    @Published var newDiscussionProfileID: UUID?
    @Published var discussionProfilePreferences: [AgentProvider: UUID] = [:]
    @Published var localModelModels: [LocalModelDescriptor] = []
    @Published var localModelUsageStatistics: UsageStatisticsSnapshot?
    @Published var localModelStatus = "Connection not checked."
    @Published var localModelError: String?
    @Published var isRefreshingLocalModels = false
    @Published var isTestingLocalModel = false
    @Published var requestedAccessMode: AccessMode = .readOnly
    @Published var repositoryPath = ""
    @Published var workspaceRootPath = ""
    @Published var isChangingWorkspaceRoot = false
    @Published var codexPath = ""
    @Published var claudePath = ""
    @Published var prompt = ""
    @Published var status = "就緒。"
    @Published var errorMessage: String?
    @Published var outputText = ""
    @Published var isRunning = false
    @Published var changePlanTitle = ""
    @Published var changePlanSummary = ""
    @Published var changePlanStepsText = ""
    @Published var changeDiff: WorkspaceChangeDiff?
    @Published var verificationResult: VerificationResult?
    @Published var branchName = ""
    @Published var customVerifierPath = ""
    @Published var customVerifierArgumentsText = ""
    @Published var isVerifying = false
    @Published var taskRecords: [ParallelTaskRecord] = []
    @Published var autonomousRuns: [AutonomousRunRecord] = []
    @Published var selectedAutonomousRunID: UUID?
    @Published var isPreparingAutonomousRun = false
    @Published var isRunningAutonomousRun = false
    @Published var isTestingMCPRuntime = false
    @Published var autonomousStatus = ""
    @Published var autonomousError: String?
    @Published var activeExtensionConfigurations: [ActiveExtensionConfigurationSummary] = []
    @Published var activeExtensionError: String?
    @Published var activeExtensionStatus = ""
    @Published var detectedMacControlPresetStatus: MacControlPresetStatus?
    @Published var macControlPermissionReadiness: MacControlPermissionReadiness?
    @Published var macControlStatusError: String?
    @Published var isCheckingMacControlPermissions = false
    @Published var projectMemoryHandoffs: [ProjectMemoryHandoff] = []
    @Published var memoryHandoffTargetSessionID: UUID?
    @Published var selectedMemoryTurnIDs = Set<UUID>()
    @Published var includeMemoryNotes = false
    @Published var extensionDescriptors: [ExtensionDescriptor] = []
    @Published var selectedExtensionID = ""
    @Published var selectedExtensionPermissions = Set<ExtensionPermission>()
    @Published var extensionPathScopesText = ""
    @Published var extensionHostScopesText = ""
    @Published var isImportingExtensionDescriptor = false
    @Published var apiBudget = ""
    @Published var apiKey = ""
    @Published var confirmAPIRun = false
    @Published var budgetSnapshot: BudgetSnapshot?
    @Published var apiCostSnapshot: APICostControlSnapshot?
    @Published var usageStatistics: UsageStatisticsSnapshot?
    @Published var providerUsageReport: ProviderUsageReport?
    @Published var usageControls = UsageControlSettings()
    @Published var apiMonthlyLimitInput = ""
    @Published var apiDailyLimitInput = ""
    @Published var apiSessionLimitInput = ""
    @Published var usageControlStatus = ""
    @Published var usageAlerts: [String] = []
    @Published var apiReconciliationCandidates: [APIReconciliationCandidate] = []
    @Published var apiReconciliationSessionID: UUID?
    @Published var apiReconciliationActualUSD = ""
    @Published var apiReconciliationConfirmed = false
    @Published var apiReconciliationStatus = ""
    @Published var authStatus: [UUID: AuthAssessment] = [:]
    @Published var accountProfiles: [AgentProvider: [AccountProfile]] = [:]
    @Published var selectedProfileIDs: [AgentProvider: UUID] = [:]
    @Published var newProfileName = ""
    @Published var newProfileAllowsSharedMemory = true
    @Published var memorySnapshot: SharedMemorySnapshot?
    @Published var memoryNotes = ""
    @Published var confirmClearMemory = false
    @Published var terminalLaunch: TerminalLaunchSpec?
    @Published var terminalTitle = ""
    @Published var terminalRunning = false
    @Published var terminalIsProfileLogin = false
    @Published var terminalIsUsageTUI = false
    @Published var terminalNeedsManualStop = false
    @Published var usageCommandRequest = 0
    @Published var closeTerminalAfterCancellation = false
    @Published var isSwitchingTarget = false

    private var service: BridgeService?
    private var store: AuditStore?
    private var activeRunFlags: [UUID: CancellationFlag] = [:]
    private var discussionCancellationFlags: [UUID: CancellationFlag] = [:]
    private var hasInitializedNewDiscussionTarget = false
    private var autonomousCancellationFlags: [UUID: CancellationFlag] = [:]
    private var activeRunSessionID: UUID?
    private var activeTerminalProfileID: UUID?
    private var activeTerminalSessionID: UUID?
    private var activeUsageProvider: AgentProvider?
    private var savedLocalModelSettings: LocalModelSettings?
    private var setupWizardAuthRequestID: UUID?
    private var loadedUsageControlsScopeKey: String?
    private var refreshedUsageStatisticsScopeKey: String?
    private var lastUsageStatisticsRefresh: Date?
    private var refreshedLocalModelUsageScopeKey: String?
    private var lastLocalModelUsageRefresh: Date?
    private var refreshedAPIReconciliationScopeKey: String?
    private var lastAPIReconciliationRefresh: Date?

    private static let setupWizardStartedPreferenceKey = "setupWizard.started"
    private static let setupWizardCompletedPreferenceKey = "setupWizard.completed"
    private static let setupWizardStepPreferenceKey = "setupWizard.step"
    private static let setupWizardProviderPreferenceKey = "setupWizard.provider"
    private static let setupWizardProfileNamePreferenceKey = "setupWizard.profileName"
    private static let newDiscussionProviderPreferenceKey = "discussion.newProvider"
    private static let discussionProfilePreferencesKey = "discussion.profilePreferences"
    private static func setupWizardCLIPathPreferenceKey(for provider: AgentProvider) -> String {
        "setupWizard.cliPath.\(provider.rawValue)"
    }

    var terminalSessionIDForView: UUID? { activeTerminalSessionID }

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

    var setupWizardSelectedProfile: AccountProfile? {
        guard let id = selectedProfileIDs[setupWizardProvider] else { return nil }
        return accountProfiles[setupWizardProvider]?.first(where: { $0.id == id })
    }

    var setupWizardAuthentication: AuthAssessment? {
        guard setupWizardProvider != .local else { return nil }
        guard let profile = setupWizardSelectedProfile else { return nil }
        return authStatus[profile.id]
    }

    var setupWizardResolvedCLIPath: String? {
        guard setupWizardProvider != .local else { return nil }
        let configuredPath = setupWizardCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? RuntimeEnvironment.resolveExecutable(
            provider: setupWizardProvider,
            configuredPath: configuredPath.isEmpty ? nil : configuredPath
        ).path
    }

    var setupWizardSavedCLIPath: String? {
        guard setupWizardProvider != .local else { return nil }
        return try? RuntimeEnvironment.resolveExecutable(
            provider: setupWizardProvider,
            configuredPath: settings.binaryPath(for: setupWizardProvider)
        ).path
    }

    var setupWizardCLISettingIsDirty: Bool {
        guard setupWizardProvider != .local else { return false }
        let draft = setupWizardCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = settings.binaryPath(for: setupWizardProvider)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return draft != saved
    }

    var setupWizardReadiness: SetupWizardReadiness {
        SetupWizardReadiness(
            workspaceConfigured: workspaceRootIsConfigured,
            commandLineAvailable: setupWizardProvider == .local || setupWizardSavedCLIPath != nil,
            commandLineSettingSaved: setupWizardProvider == .local || !setupWizardCLISettingIsDirty,
            subscriptionLoginConfirmed: setupWizardProvider == .local || setupWizardAuthentication?.confirmedSubscription == true
        )
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
                initializeSetupWizard(workspaceRootConfigured: false)
                return
            }
            let root = try RuntimePaths.requireWorkspaceRoot()
            let store = try RuntimePaths.makeAuditStore()
            let service = try BridgeService(store: store)
            self.store = store
            self.service = service
            workspaceRootPath = root.path
            refresh()
            initializeSetupWizard(workspaceRootConfigured: true)
        } catch {
            if let root = try? RuntimePaths.requireWorkspaceRoot() { workspaceRootPath = root.path }
            errorMessage = error.localizedDescription
            initializeSetupWizard(workspaceRootConfigured: workspaceRootIsConfigured)
        }
    }

    private func initializeSetupWizard(workspaceRootConfigured: Bool) {
        let defaults = UserDefaults.standard
        if let savedProvider = defaults.string(forKey: Self.setupWizardProviderPreferenceKey)
            .flatMap(AgentProvider.init(rawValue:)) {
            setupWizardProvider = savedProvider
        } else {
            setupWizardProvider = settings.defaultProvider
        }
        setupWizardCLIPath = setupWizardProvider == .local ? "" : (defaults.string(forKey: Self.setupWizardCLIPathPreferenceKey(for: setupWizardProvider))
            ?? settings.binaryPath(for: setupWizardProvider)
            ?? "")
        let savedStep = defaults.string(forKey: Self.setupWizardStepPreferenceKey)
            .flatMap(SetupWizardStep.init(rawValue:))
        setupWizardProfileName = defaults.string(forKey: Self.setupWizardProfileNamePreferenceKey) ?? ""
        setupWizardStep = SetupWizardFlow.startingStep(
            savedStep: savedStep,
            workspaceRootConfigured: workspaceRootConfigured
        )
        let hasStarted = defaults.bool(forKey: Self.setupWizardStartedPreferenceKey)
        let hasCompleted = defaults.bool(forKey: Self.setupWizardCompletedPreferenceKey)
        isSetupWizardPresented = SetupWizardFlow.shouldPresentAutomatically(
            workspaceRootConfigured: workspaceRootConfigured,
            hasStarted: hasStarted,
            hasCompleted: hasCompleted
        )
        if isSetupWizardPresented {
            defaults.set(true, forKey: Self.setupWizardStartedPreferenceKey)
            if let errorMessage {
                setupWizardError = errorMessage
                self.errorMessage = nil
            }
        }
    }

    func openSetupWizard() {
        guard canPresentSetupWizard else { return }
        let hasCompleted = UserDefaults.standard.bool(forKey: Self.setupWizardCompletedPreferenceKey)
        setupWizardStep = SetupWizardFlow.reopeningStep(
            savedStep: setupWizardStep,
            hasCompleted: hasCompleted,
            workspaceRootConfigured: workspaceRootIsConfigured
        )
        UserDefaults.standard.set(true, forKey: Self.setupWizardStartedPreferenceKey)
        setupWizardCLIPath = hasCompleted
            ? (settings.binaryPath(for: setupWizardProvider) ?? "")
            : (UserDefaults.standard.string(forKey: Self.setupWizardCLIPathPreferenceKey(for: setupWizardProvider))
                ?? settings.binaryPath(for: setupWizardProvider)
                ?? "")
        setupWizardError = nil
        setupWizardStatus = ""
        errorMessage = nil
        isSetupWizardPresented = true
    }

    func dismissSetupWizardForNow() {
        guard SetupWizardFlow.canDismiss(workspaceRootConfigured: workspaceRootIsConfigured),
              !isChangingWorkspaceRoot, !terminalRunning, terminalLaunch == nil,
              !hasActiveDiscussionOperation else { return }
        isSetupWizardPresented = false
        errorMessage = nil
    }

    func finishSetupWizard() {
        guard SetupWizardFlow.canDismiss(workspaceRootConfigured: workspaceRootIsConfigured),
              !isChangingWorkspaceRoot, !terminalRunning, terminalLaunch == nil,
              !hasActiveDiscussionOperation else { return }
        UserDefaults.standard.set(true, forKey: Self.setupWizardCompletedPreferenceKey)
        setupWizardStep = .welcome
        isSetupWizardPresented = false
        errorMessage = nil
    }

    func moveSetupWizard(to step: SetupWizardStep) {
        guard !isChangingWorkspaceRoot else { return }
        if let currentIndex = SetupWizardStep.allCases.firstIndex(of: setupWizardStep),
           let targetIndex = SetupWizardStep.allCases.firstIndex(of: step),
           targetIndex > currentIndex,
           !SetupWizardFlow.canAdvance(from: setupWizardStep, workspaceRootConfigured: workspaceRootIsConfigured) {
            return
        }
        setupWizardStep = step
        setupWizardError = nil
        if step == .commandLine {
            if setupWizardProvider == .local {
                setupWizardCLIPath = ""
                setupWizardCLIStatus = ""
            } else {
                setupWizardCLIPath = UserDefaults.standard.string(forKey: Self.setupWizardCLIPathPreferenceKey(for: setupWizardProvider))
                    ?? settings.binaryPath(for: setupWizardProvider)
                    ?? ""
                checkSetupWizardCLIAvailability()
            }
        } else if step == .usage {
            loadSetupWizardUsageControls()
        }
    }

    func selectSetupWizardProvider(_ provider: AgentProvider) {
        guard setupWizardProvider != provider else { return }
        setupWizardProvider = provider
        setupWizardCLIPath = provider == .local ? "" : (UserDefaults.standard.string(forKey: Self.setupWizardCLIPathPreferenceKey(for: provider))
            ?? settings.binaryPath(for: provider)
            ?? "")
        setupWizardCLIStatus = ""
        setupWizardUsageStatus = ""
        if setupWizardStep == .usage { loadSetupWizardUsageControls() }
    }

    func chooseSetupWizardCLIPath() {
        guard setupWizardProvider != .local else { return }
        let panel = NSOpenPanel()
        panel.title = localized("Choose the official CLI executable")
        panel.message = localized("Select the installed codex or claude executable. AgentBridge will only save this path.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setupWizardCLIPath = url.path
        checkSetupWizardCLIAvailability()
    }

    func checkSetupWizardCLIAvailability() {
        guard setupWizardProvider != .local else {
            setupWizardCLIStatus = localized("Local models do not require a command-line app.")
            return
        }
        let path = setupWizardCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let executable = try RuntimeEnvironment.resolveExecutable(
                provider: setupWizardProvider,
                configuredPath: path.isEmpty ? nil : path
            )
            setupWizardCLIStatus = setupWizardCLISettingIsDirty
                ? String(format: localized("Draft executable found: %@. Save this path before finishing setup."), executable.path)
                : String(format: localized("Found executable: %@"), executable.path)
        } catch {
            setupWizardCLIStatus = localized("CLI not found. Choose an executable or follow the official install guide.")
        }
    }

    func saveSetupWizardCLIPath() {
        guard setupWizardProvider != .local else {
            setupWizardCLIStatus = localized("Local models do not require a command-line app.")
            return
        }
        guard let service else {
            setupWizardError = localized("Choose a workspace folder before saving CLI settings.")
            return
        }
        let path = setupWizardCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty {
            do {
                _ = try RuntimeEnvironment.resolveExecutable(provider: setupWizardProvider, configuredPath: path)
            } catch {
                setupWizardError = error.localizedDescription
                setupWizardCLIStatus = localized("The selected path is not an executable for this provider.")
                return
            }
        }
        let previousSettings = settings
        let previousPath = settings.binaryPath(for: setupWizardProvider)?.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.setBinaryPath(path.isEmpty ? nil : path, for: setupWizardProvider)
        do {
            try service.saveSettings(settings)
            if previousPath != path {
                for profile in accountProfiles[setupWizardProvider] ?? [] {
                    authStatus.removeValue(forKey: profile.id)
                }
            }
            setupWizardError = nil
            checkSetupWizardCLIAvailability()
            setupWizardStatus = localized("CLI setting saved.")
        } catch {
            settings = previousSettings
            setupWizardError = error.localizedDescription
        }
    }

    func selectSetupWizardDefaultProvider() {
        guard let service else {
            setupWizardError = localized("Choose a workspace folder before saving provider settings.")
            return
        }
        let previous = settings
        settings.defaultProvider = setupWizardProvider
        if setupWizardProvider == .codex { settings.usageMode = .subscription }
        if setupWizardProvider == .local { requestedAccessMode = .readOnly }
        do {
            try service.saveSettings(settings)
            if previous.defaultProvider != settings.defaultProvider || previous.usageMode != settings.usageMode {
                clearAPIAuthorization()
            }
            providerUsageReport = nil
            loadedUsageControlsScopeKey = nil
            refresh(forceUsageStatistics: true)
            if let anchor = selectedSession { selectOrCreateSession(for: setupWizardProvider, anchoredTo: anchor) }
            setupWizardStatus = setupWizardProvider == .local
                ? localized("Local model is now the default. Cloud provider settings remain saved separately.")
                : settings.usageMode == .subscription
                    ? localized("Default provider and subscription sign-in saved.")
                    : localized("Default provider saved; the existing Claude API mode was preserved.")
            setupWizardError = nil
        } catch {
            settings = previous
            setupWizardError = error.localizedDescription
        }
    }

    func selectSetupWizardSubscriptionMode() {
        guard setupWizardProvider == .claude, settings.defaultProvider == .claude,
              settings.usageMode != .subscription else { return }
        selectUsageMode(.subscription)
    }

    func selectSetupWizardProfile(_ profileID: UUID) {
        guard let service, selectedProfileIDs[setupWizardProvider] != profileID else { return }
        do {
            try service.selectAccountProfile(id: profileID, provider: setupWizardProvider)
            selectedProfileIDs[setupWizardProvider] = profileID
            accountProfiles[setupWizardProvider] = try service.accountProfiles(provider: setupWizardProvider)
            loadedUsageControlsScopeKey = nil
            providerUsageReport = nil
            authStatus.removeValue(forKey: profileID)
            setupWizardStatus = setupWizardProvider == .local
                ? localized("Local memory account selected. No sign-in is needed.")
                : localized("Account selected. Sign-in remains managed by the provider CLI.")
            setupWizardError = nil
            if settings.defaultProvider == setupWizardProvider, let anchor = selectedSession {
                selectOrCreateSession(for: setupWizardProvider, anchoredTo: anchor)
            }
            if setupWizardStep == .usage { loadSetupWizardUsageControls() }
        } catch {
            setupWizardError = error.localizedDescription
        }
    }

    func createSetupWizardProfile(name: String) -> Bool {
        guard let service else {
            setupWizardError = localized("Choose a workspace folder before creating an account.")
            return false
        }
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            setupWizardError = localized("Enter a display name for the new account.")
            return false
        }
        do {
            let profile = try service.createAccountProfile(name: displayName, provider: setupWizardProvider, allowsSharedMemory: true)
            try service.selectAccountProfile(id: profile.id, provider: setupWizardProvider)
            selectedProfileIDs[setupWizardProvider] = profile.id
            accountProfiles[setupWizardProvider] = try service.accountProfiles(provider: setupWizardProvider)
            loadedUsageControlsScopeKey = nil
            authStatus.removeValue(forKey: profile.id)
            setupWizardProfileName = ""
            setupWizardStatus = setupWizardProvider == .local
                ? localized("Separate local memory account created. No sign-in is needed.")
                : localized("Isolated account created. Sign in when you are ready.")
            setupWizardError = nil
            if settings.defaultProvider == setupWizardProvider, let anchor = selectedSession {
                selectOrCreateSession(for: setupWizardProvider, anchoredTo: anchor)
            }
            return true
        } catch {
            setupWizardError = error.localizedDescription
            return false
        }
    }

    func setSetupWizardMemorySharing(_ allowed: Bool) {
        guard let service, let profile = setupWizardSelectedProfile else { return }
        do {
            try service.setAccountSharedMemoryAllowed(id: profile.id, allowed: allowed)
            accountProfiles[setupWizardProvider] = try service.accountProfiles(provider: setupWizardProvider)
            if let session = selectedSession,
               (session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)) == profile.id {
                refreshSelectedEvents()
            }
            setupWizardStatus = allowed
                ? localized("This account may load and save shared project memory.")
                : localized("This account will not load or save shared project memory.")
            setupWizardError = nil
        } catch {
            setupWizardError = error.localizedDescription
        }
    }

    func checkSetupWizardAuthentication() {
        guard setupWizardProvider != .local else {
            setupWizardStatus = localized("Local models do not use CLI sign-in.")
            return
        }
        guard let profile = setupWizardSelectedProfile else {
            setupWizardError = localized("No account profile is available for this provider.")
            return
        }
        let profileID = profile.id
        let requestID = UUID()
        setupWizardAuthRequestID = requestID
        setupWizardAuthCheckInProgress = true
        setupWizardStatus = localized("Checking official CLI sign-in…")
        checkAuthentication(for: profile) { [weak self] assessment, error in
            guard let self, self.setupWizardAuthRequestID == requestID else { return }
            self.setupWizardAuthCheckInProgress = false
            self.setupWizardAuthRequestID = nil
            guard self.setupWizardSelectedProfile?.id == profileID else { return }
            if let assessment {
                self.setupWizardStatus = assessment.message
                self.setupWizardError = nil
            } else if let error {
                self.setupWizardError = error.localizedDescription
            }
        }
    }

    func openSetupWizardProfileLogin() {
        guard setupWizardProvider != .local else {
            setupWizardError = localized("Local models do not use CLI sign-in.")
            return
        }
        guard let profile = setupWizardSelectedProfile else {
            setupWizardError = localized("No account profile is available for this provider.")
            return
        }
        openProfileLoginTerminal(for: profile)
    }

    func loadSetupWizardUsageControls() {
        setupWizardUsageControls = UsageControlSettings()
        if setupWizardProvider == .local {
            setupWizardUsageStatus = localized("Local models do not use subscription quota or API billing controls.")
            return
        }
        guard let service, let profile = setupWizardSelectedProfile else { return }
        do {
            setupWizardUsageControls = try service.usageControlSettings(provider: profile.provider, profileID: profile.id)
            setupWizardUsageStatus = ""
        } catch {
            setupWizardUsageStatus = error.localizedDescription
        }
    }

    func updateSetupWizardUsageControls(_ update: (inout UsageControlSettings) -> Void) {
        update(&setupWizardUsageControls)
    }

    func saveSetupWizardUsageControls() {
        guard setupWizardProvider != .local else {
            setupWizardUsageStatus = localized("Local models do not use subscription quota or API billing controls.")
            return
        }
        guard let service, let profile = setupWizardSelectedProfile else {
            setupWizardUsageStatus = localized("Choose a workspace folder before saving usage settings.")
            return
        }
        do {
            try service.saveUsageControlSettings(setupWizardUsageControls, provider: profile.provider, profileID: profile.id)
            setupWizardUsageStatus = localized("Local usage settings saved.")
            if settings.defaultProvider == profile.provider,
               selectedProfileIDs[profile.provider] == profile.id {
                usageControls = setupWizardUsageControls
                loadedUsageControlsScopeKey = "\(profile.provider.rawValue):\(profile.id.uuidString.lowercased())"
            }
        } catch {
            setupWizardUsageStatus = error.localizedDescription
        }
    }

    func setSetupWizardNotificationsEnabled(_ enabled: Bool) {
        guard let service, let profile = setupWizardSelectedProfile else { return }
        if !enabled {
            persistSetupWizardNotificationPreference(false, service: service, profile: profile)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.persistSetupWizardNotificationPreference(granted, service: service, profile: profile)
                if self.setupWizardProvider == profile.provider,
                   self.setupWizardSelectedProfile?.id == profile.id,
                   let error {
                    self.setupWizardUsageStatus = String(format: self.localized("Could not enable macOS notifications: %@"), error.localizedDescription)
                } else if self.setupWizardProvider == profile.provider,
                          self.setupWizardSelectedProfile?.id == profile.id,
                          !granted {
                    self.setupWizardUsageStatus = self.localized("macOS permission was not granted; in-app reminders still work.")
                }
            }
        }
    }

    private func persistSetupWizardNotificationPreference(_ enabled: Bool, service: BridgeService, profile: AccountProfile) {
        do {
            var updated = try service.usageControlSettings(provider: profile.provider, profileID: profile.id)
            updated.macOSNotificationsEnabled = enabled
            try service.saveUsageControlSettings(updated, provider: profile.provider, profileID: profile.id)
            if setupWizardProvider == profile.provider, setupWizardSelectedProfile?.id == profile.id {
                setupWizardUsageControls.macOSNotificationsEnabled = enabled
                setupWizardUsageStatus = enabled
                    ? localized("macOS usage notifications are enabled.")
                    : localized("macOS notifications are off; in-app reminders remain available.")
            }
            if settings.defaultProvider == profile.provider,
               selectedProfileIDs[profile.provider] == profile.id {
                usageControls = updated
                loadedUsageControlsScopeKey = "\(profile.provider.rawValue):\(profile.id.uuidString.lowercased())"
            }
        } catch {
            if setupWizardProvider == profile.provider, setupWizardSelectedProfile?.id == profile.id {
                setupWizardUsageStatus = error.localizedDescription
            }
        }
    }

    private func reportOperationError(_ message: String) {
        if isSetupWizardPresented {
            setupWizardError = message
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

    private var localUsageProfileID: UUID? {
        if let discussion = selectedDiscussion, discussion.provider == .local {
            return discussion.accountProfileID
        }
        if let session = selectedSession, session.provider == .local {
            return session.accountProfileID ?? AccountProfile.defaultID(for: .local)
        }
        if newDiscussionProvider == .local, let newDiscussionProfileID {
            return newDiscussionProfileID
        }
        return selectedProfileIDs[.local]
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
            refreshUsageControlsIfNeeded(service: service)
            if settings.defaultProvider == .claude, let profileID = selectedProfileIDs[.claude] {
                do {
                    budgetSnapshot = try service.budgetSnapshot(profileID: profileID)
                } catch UsageControlError.apiMonthlyLimitRequired {
                    budgetSnapshot = nil
                }
                if let session = selectedSession,
                   session.provider == .claude,
                   (session.accountProfileID ?? AccountProfile.defaultID(for: .claude)) == profileID {
                    apiCostSnapshot = try service.apiCostControlSnapshot(profileID: profileID, sessionID: session.id)
                } else {
                    apiCostSnapshot = nil
                }
                try refreshAPIReconciliationCandidatesIfNeeded(
                    service: service,
                    profileID: profileID,
                    force: forceUsageStatistics
                )
                if settings.usageMode == .api { evaluateAPIBudgetThresholds() }
            } else {
                budgetSnapshot = nil
                apiCostSnapshot = nil
                apiReconciliationCandidates = []
                apiReconciliationSessionID = nil
            }
            try refreshUsageStatisticsIfNeeded(service: service, force: forceUsageStatistics)
            try refreshLocalModelUsageStatisticsIfNeeded(service: service, force: forceUsageStatistics)
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

    private func refreshUsageControlsIfNeeded(service: BridgeService) {
        let provider = settings.defaultProvider
        guard let profileID = selectedProfileIDs[provider] else { return }
        let key = "\(provider.rawValue):\(profileID.uuidString.lowercased())"
        guard loadedUsageControlsScopeKey != key else { return }
        do {
            usageControls = try service.usageControlSettings(provider: provider, profileID: profileID)
            apiMonthlyLimitInput = usageControls.apiMonthlyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            apiDailyLimitInput = usageControls.apiDailyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            apiSessionLimitInput = usageControls.apiSessionLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            usageAlerts = []
            usageControlStatus = ""
            loadedUsageControlsScopeKey = key
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshUsageStatisticsIfNeeded(service: BridgeService, force: Bool) throws {
        let provider = settings.defaultProvider
        guard let profileID = selectedProfileIDs[provider] else { return }
        let scopeKey = "\(provider.rawValue):\(profileID.uuidString.lowercased()):\(selectedSessionID?.uuidString ?? "none")"
        let now = Date()
        if !force, refreshedUsageStatisticsScopeKey == scopeKey,
           let lastUsageStatisticsRefresh,
           now.timeIntervalSince(lastUsageStatisticsRefresh) < 30 {
            return
        }
        let snapshot = try service.usageStatistics(
            provider: provider,
            profileID: profileID,
            selectedSessionID: selectedSessionID,
            now: now
        )
        usageStatistics = snapshot
        refreshedUsageStatisticsScopeKey = scopeKey
        lastUsageStatisticsRefresh = now
        if provider != .local { evaluateSubscriptionThresholds(snapshot: snapshot) }
    }

    private func refreshLocalModelUsageStatisticsIfNeeded(service: BridgeService, force: Bool) throws {
        guard let profileID = localUsageProfileID else {
            localModelUsageStatistics = nil
            return
        }
        let currentLocalRunID: UUID?
        if let discussion = selectedDiscussion, discussion.provider == .local,
           discussion.accountProfileID == profileID {
            currentLocalRunID = discussion.id
        } else if let session = selectedSession, session.provider == .local,
                  (session.accountProfileID ?? AccountProfile.defaultID(for: .local)) == profileID {
            currentLocalRunID = session.id
        } else {
            currentLocalRunID = nil
        }
        let scopeKey = "local:\(profileID.uuidString.lowercased()):\(currentLocalRunID?.uuidString.lowercased() ?? "none")"
        let now = Date()
        if !force, refreshedLocalModelUsageScopeKey == scopeKey,
           let lastLocalModelUsageRefresh,
           now.timeIntervalSince(lastLocalModelUsageRefresh) < 30 {
            return
        }
        localModelUsageStatistics = try service.usageStatistics(
            provider: .local,
            profileID: profileID,
            selectedSessionID: currentLocalRunID,
            now: now
        )
        refreshedLocalModelUsageScopeKey = scopeKey
        lastLocalModelUsageRefresh = now
    }

    private func refreshAPIReconciliationCandidatesIfNeeded(
        service: BridgeService,
        profileID: UUID,
        force: Bool
    ) throws {
        let scopeKey = profileID.uuidString.lowercased()
        if refreshedAPIReconciliationScopeKey != scopeKey {
            apiReconciliationSessionID = nil
            apiReconciliationActualUSD = ""
            apiReconciliationConfirmed = false
            apiReconciliationStatus = ""
            refreshedAPIReconciliationScopeKey = scopeKey
            lastAPIReconciliationRefresh = nil
        }
        let now = Date()
        if !force, let lastAPIReconciliationRefresh,
           now.timeIntervalSince(lastAPIReconciliationRefresh) < 30 {
            return
        }
        apiReconciliationCandidates = try service.unresolvedAPICalls(profileID: profileID)
        if !apiReconciliationCandidates.contains(where: { $0.session.id == apiReconciliationSessionID }) {
            apiReconciliationSessionID = apiReconciliationCandidates.first?.session.id
        }
        lastAPIReconciliationRefresh = now
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
                try refreshUsageStatisticsIfNeeded(service: service, force: true)
                try refreshLocalModelUsageStatisticsIfNeeded(service: service, force: true)
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
            loadedUsageControlsScopeKey = nil
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

    func updateUsageControls(_ update: (inout UsageControlSettings) -> Void) {
        update(&usageControls)
    }

    func saveUsageControlSettings() {
        guard let service, let profile = selectedAccountProfile else {
            usageControlStatus = "找不到目前選取的帳戶設定。"
            return
        }
        var updated = usageControls
        if profile.provider == .claude, profile.id != AccountProfile.defaultID(for: .claude) {
            let rawLimit = apiMonthlyLimitInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawLimit.isEmpty {
                updated.apiMonthlyLimitUSD = nil
            } else if let limit = Double(rawLimit), limit.isFinite {
                updated.apiMonthlyLimitUSD = limit
            } else {
                usageControlStatus = "請輸入有效的 Claude API 月上限金額。"
                return
            }
        }
        var dailyLimit: Double?
        var sessionLimit: Double?
        guard parseOptionalDollarLimit(apiDailyLimitInput, into: &dailyLimit),
              parseOptionalDollarLimit(apiSessionLimitInput, into: &sessionLimit) else {
            usageControlStatus = "API 每日與工作階段 USD 上限必須是有效的正數，或留空代表不限。"
            return
        }
        updated.apiDailyLimitUSD = dailyLimit
        updated.apiSessionLimitUSD = sessionLimit
        if profile.provider != .claude { updated.apiMonthlyLimitUSD = nil }
        do {
            try service.saveUsageControlSettings(updated, provider: profile.provider, profileID: profile.id)
            usageControls = updated
            apiMonthlyLimitInput = updated.apiMonthlyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            apiDailyLimitInput = updated.apiDailyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            apiSessionLimitInput = updated.apiSessionLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            usageControlStatus = "本機用量控制已儲存。"
            refresh(forceUsageStatistics: true)
        } catch {
            usageControlStatus = error.localizedDescription
        }
    }

    var selectedAPIReconciliationCandidate: APIReconciliationCandidate? {
        apiReconciliationCandidates.first(where: { $0.session.id == apiReconciliationSessionID })
    }

    func reconcileSelectedAPICost() {
        guard let service, let profile = selectedAccountProfile,
              profile.provider == .claude,
              let candidate = selectedAPIReconciliationCandidate else {
            apiReconciliationStatus = "請選擇此 Claude 帳戶中尚未結算的 API 工作階段。"
            return
        }
        let rawAmount = apiReconciliationActualUSD.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let actualUSD = Double(rawAmount), actualUSD.isFinite, actualUSD >= 0 else {
            apiReconciliationStatus = "請輸入 provider 帳單所列的有效實際 USD 金額。"
            return
        }
        guard apiReconciliationConfirmed else {
            apiReconciliationStatus = "結算前請確認金額已對照 provider 帳單。"
            return
        }
        do {
            let result = try service.reconcileAPIUsageFromProviderBill(
                profileID: profile.id,
                sessionID: candidate.session.id,
                actualUSD: actualUSD,
                explicitlyConfirmed: true
            )
            apiReconciliationStatus = String(format: "費用已手動結算：月度帳本 %@；每日/工作階段帳本 %@。", result.monthlyLedgerSettled ? "已更新" : "沒有對應預留", result.dailySessionLedgerSettled ? "已更新" : "沒有對應預留")
            apiReconciliationActualUSD = ""
            apiReconciliationConfirmed = false
            lastAPIReconciliationRefresh = nil
            refresh(forceUsageStatistics: true)
        } catch {
            apiReconciliationStatus = error.localizedDescription
            lastAPIReconciliationRefresh = nil
            refresh(forceUsageStatistics: true)
        }
    }

    private func parseOptionalDollarLimit(_ rawValue: String, into output: inout Double?) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            output = nil
            return true
        }
        guard let number = Double(value), number.isFinite else { return false }
        output = number
        return true
    }

    func setMacOSUsageNotificationsEnabled(_ enabled: Bool) {
        guard let service, let profile = selectedAccountProfile else { return }
        if !enabled {
            var updated = usageControls
            updated.macOSNotificationsEnabled = false
            persistUsageControls(updated, service: service, profile: profile)
            return
        }
        let requestedSettings = usageControls
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                var updated = self.selectedAccountProfile?.id == profile.id ? self.usageControls : requestedSettings
                updated.macOSNotificationsEnabled = granted
                self.persistUsageControls(updated, service: service, profile: profile)
                if let error {
                    self.usageControlStatus = "無法啟用 macOS 通知：\(error.localizedDescription)"
                } else if !granted {
                    self.usageControlStatus = "未取得 macOS 通知權限；提醒仍會顯示在 App 內。"
                }
            }
        }
    }

    private func evaluateSubscriptionThresholds(snapshot: UsageStatisticsSnapshot) {
        let profileKey = "\(snapshot.provider.rawValue):\(snapshot.accountProfileID.uuidString.lowercased())"
        evaluateThreshold(
            title: "近 5 小時本機執行",
            used: snapshot.subscriptionFiveHourRuns,
            limit: usageControls.subscriptionFiveHourRunLimit,
            key: "\(profileKey):subscription-5h:\(usageAlertPeriodID(duration: 5 * 60 * 60, at: snapshot.generatedAt))"
        )
        evaluateThreshold(
            title: "近 24 小時本機執行",
            used: snapshot.subscriptionDailyRuns,
            limit: usageControls.subscriptionDailyRunLimit,
            key: "\(profileKey):subscription-24h:\(usageAlertPeriodID(duration: 24 * 60 * 60, at: snapshot.generatedAt))"
        )
        evaluateThreshold(
            title: "近 7 天本機執行",
            used: snapshot.subscriptionSevenDayRuns,
            limit: usageControls.subscriptionWeeklyRunLimit,
            key: "\(profileKey):subscription-7d:\(usageAlertPeriodID(duration: 7 * 24 * 60 * 60, at: snapshot.generatedAt))"
        )
        evaluateThreshold(
            title: "目前工作階段本機執行",
            used: snapshot.subscriptionSessionRuns,
            limit: usageControls.subscriptionSessionRunLimit,
            key: "\(profileKey):subscription-session:\(selectedSessionID?.uuidString ?? "none")"
        )
    }

    private func usageAlertPeriodID(duration: TimeInterval, at date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / duration))
    }

    private func evaluateAPIBudgetThresholds() {
        guard let budgetSnapshot else { return }
        let consumed = budgetSnapshot.usedUSD + budgetSnapshot.reservedUSD
        let ratio = consumed / budgetSnapshot.monthlyLimitUSD
        let profileID = selectedProfileIDs[.claude] ?? AccountProfile.defaultID(for: .claude)
        for threshold in [50, 75, 90, 100] {
            let key = "api:\(profileID.uuidString.lowercased()):\(budgetSnapshot.month):\(threshold)"
            if ratio >= Double(threshold) / 100 {
                recordUsageAlert(
                    key: key,
                    message: String(format: "Claude API 本機月預算已達 %d%%（已用與保留合計 US$%.2f / US$%.2f）。", threshold, consumed, budgetSnapshot.monthlyLimitUSD)
                )
            }
        }
        if let activity = usageStatistics {
            evaluateThreshold(
                title: "近 24 小時 Claude API 執行次數",
                used: activity.apiDailyRuns,
                limit: usageControls.apiDailyRunLimit,
                key: "api-count-24h:\(profileID.uuidString.lowercased()):\(ISO8601DateFormatter().string(from: Date()).prefix(10))"
            )
            evaluateThreshold(
                title: "目前工作階段 Claude API 執行次數",
                used: activity.apiSessionRuns,
                limit: usageControls.apiSessionRunLimit,
                key: "api-count-session:\(profileID.uuidString.lowercased()):\(selectedSessionID?.uuidString ?? "none")"
            )
        }
        if let costs = apiCostSnapshot {
            let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
            evaluateDollarThreshold(
                title: "Claude API UTC 每日 USD 上限",
                used: costs.dailyUsedUSD + costs.dailyReservedUSD,
                limit: usageControls.apiDailyLimitUSD,
                key: "api-usd-day:\(profileID.uuidString.lowercased()):\(day)"
            )
            evaluateDollarThreshold(
                title: "Claude API 工作階段 USD 上限",
                used: costs.sessionUsedUSD + costs.sessionReservedUSD,
                limit: usageControls.apiSessionLimitUSD,
                key: "api-usd-session:\(profileID.uuidString.lowercased()):\(selectedSessionID?.uuidString ?? "none")"
            )
        }
    }

    private func evaluateThreshold(title: String, used: Int, limit: Int?, key: String) {
        guard let limit, limit > 0 else { return }
        for threshold in [50, 75, 90, 100] {
            let alertKey = "\(key):\(threshold)"
            if Double(used) / Double(limit) >= Double(threshold) / 100 {
                recordUsageAlert(key: alertKey, message: "\(title)達到本機上限的 \(threshold)%（\(used)/\(limit)）。")
            }
        }
    }

    private func evaluateDollarThreshold(title: String, used: Double, limit: Double?, key: String) {
        guard let limit, limit > 0 else { return }
        for threshold in [50, 75, 90, 100] {
            let alertKey = "\(key):\(threshold)"
            if used / limit >= Double(threshold) / 100 {
                recordUsageAlert(
                    key: alertKey,
                    message: String(format: "%@達到本機上限的 %d%%（US$%.2f / US$%.2f）。", title, threshold, used, limit)
                )
            }
        }
    }

    private func recordUsageAlert(key: String, message: String) {
        if !usageAlerts.contains(message) {
            usageAlerts.insert(message, at: 0)
            usageAlerts = Array(usageAlerts.prefix(5))
        }
        guard usageControls.notifiedThresholds[key] == nil else { return }
        var updated = usageControls
        updated.notifiedThresholds[key] = Date()
        guard let service, let profile = selectedAccountProfile else { return }
        persistUsageControls(updated, service: service, profile: profile, updateStatus: false)
        guard usageControls.macOSNotificationsEnabled else { return }
        let notificationTitle = localized("AgentBridge 用量提醒")
        let notificationBody = localized(message)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = notificationTitle
            content.body = notificationBody
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func persistUsageControls(
        _ updated: UsageControlSettings,
        service: BridgeService,
        profile: AccountProfile,
        updateStatus: Bool = true
    ) {
        var updated = updated
        if updated.notifiedThresholds.count > 48 {
            let retainedKeys = updated.notifiedThresholds.sorted { $0.value > $1.value }.prefix(48).map(\.key)
            updated.notifiedThresholds = updated.notifiedThresholds.filter { retainedKeys.contains($0.key) }
        }
        do {
            try service.saveUsageControlSettings(updated, provider: profile.provider, profileID: profile.id)
            if selectedProfileIDs[profile.provider] == profile.id, settings.defaultProvider == profile.provider {
                usageControls = updated
            }
            if updateStatus {
                usageControlStatus = updated.macOSNotificationsEnabled
                    ? "已啟用 macOS 門檻通知；提醒也會保留在 App 內。"
                    : "已關閉 macOS 通知；門檻提醒仍會保留在 App 內。"
            }
        } catch {
            if updateStatus { usageControlStatus = error.localizedDescription }
        }
    }

    private func clearAPIAuthorization() {
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
                setupWizardError = nil
                status = localized("工作區資料根目錄已更新；舊資料仍保留在原位置。")
                refresh(forceUsageStatistics: true)
                if setupWizardCLIPath.isEmpty {
                    setupWizardCLIPath = UserDefaults.standard.string(forKey: Self.setupWizardCLIPathPreferenceKey(for: setupWizardProvider))
                        ?? settings.binaryPath(for: setupWizardProvider)
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

    private func checkAuthentication(
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
                    try? self.refreshLocalModelUsageStatisticsIfNeeded(service: service, force: true)
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
        setupWizardError = nil
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

    private func selectOrCreateSession(for provider: AgentProvider, anchoredTo anchor: SessionRecord) {
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
            loadedUsageControlsScopeKey = nil
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
            loadedUsageControlsScopeKey = nil
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

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var mainArea: MainArea = .chats
    @State private var isProjectConfigurationExpanded = false
    @State private var contextPreview: ContextCompressionPreview?
    @State private var contextPreviewSettings: LocalModelSettings?
    @State private var isShowingContextPreview = false
    @State private var isLoadingContextPreview = false

    private enum MainArea: String, CaseIterable, Identifiable {
        case chats
        case conversation
        case autonomous
        case extensions

        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if !model.workspaceRootIsConfigured {
                workspaceRootSetup
            } else {
                VStack(spacing: 0) {
                    header
                    mainAreaPicker
                    Divider()
                    HStack(spacing: 0) {
                        if mainArea == .chats {
                            chatsSidebar
                        } else {
                            projectSidebar
                        }
                        Divider()
                        mainAreaContent
                    }
                    Divider()
                    statusBar
                }
                .disabled(model.isChangingWorkspaceRoot)
            }
        }
        .frame(minWidth: 1160, minHeight: 780)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, model.appLanguage.locale)
        .sheet(isPresented: $model.isSetupWizardPresented) {
            SetupWizardView(model: model)
                .interactiveDismissDisabled(!model.workspaceRootIsConfigured || model.isChangingWorkspaceRoot || model.terminalLaunch != nil)
        }
        .alert("AgentBridge", isPresented: Binding(get: { model.errorMessage != nil && !model.isSetupWizardPresented }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.localized(model.errorMessage ?? ""))
        }
        .alert("清除此專案的共用記憶？", isPresented: $model.confirmClearMemory) {
            Button("清除記憶", role: .destructive) { model.clearSharedMemory() }
            Button("取消", role: .cancel) { model.confirmClearMemory = false }
        } message: {
            Text("這會刪除此來源儲存庫與固定提交版本的對話記憶與備註。provider 原生工作階段不會被修改。")
        }
        .fileImporter(
            isPresented: $model.isImportingExtensionDescriptor,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: model.importExtensionDescriptor
        )
        .onChange(of: model.selectedSessionID) { _, _ in model.selectedSessionDidChange() }
        .onChange(of: model.isLocalProviderContext) { _, isLocal in
            if isLocal && (mainArea == .autonomous || mainArea == .extensions) { mainArea = .chats }
        }
        .onChange(of: model.selectedExtensionID) { _, _ in model.selectedExtensionDidChange() }
        .onChange(of: model.isSetupWizardPresented) { _, isPresented in
            if !isPresented { model.errorMessage = nil }
        }
        .onAppear { model.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }

    private var workspaceRootSetup: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("選擇工作區資料根目錄")
                .font(.title2.weight(.semibold))
            Text("首次使用前，請選擇或建立一個資料夾。AgentBridge 會在裡面保存隔離工作區和共用記憶；App 設定、獨立帳戶的 CLI profile 資料夾與用量帳本仍留在 Application Support。內建帳戶沿用 provider CLI 原有的登入資料夾。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button("選擇或建立資料根目錄…") { model.chooseWorkspaceRoot() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isChangingWorkspaceRoot)
            if model.isChangingWorkspaceRoot {
                ProgressView("正在安全複製現有工作區與共用記憶…")
            }
            Text(model.localized(model.status))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2.weight(.semibold)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AgentBridge").font(.headline)
                Text("Start with a chat; hand off to Git when you’re ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("語言", selection: $model.appLanguage) {
                Text("English").tag(AppLanguage.english)
                Text("繁體中文").tag(AppLanguage.traditionalChinese)
            }
            .pickerStyle(.menu)
            Button(model.localized("Setup Wizard")) { model.openSetupWizard() }
                .disabled(!model.canPresentSetupWizard)
            if let session = model.selectedSession {
                if model.isProjectConversationActive {
                    Text("\(session.provider.rawValue.capitalized) · \(model.selectedSessionProfileName)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
            }
            if model.selectedDiscussionID == nil && !model.isLocalProviderContext {
                Button("檢查登入與方案") { model.checkAuthentication() }
                    .disabled(model.hasActiveAutonomousWorkflow || model.hasActiveDiscussionOperation)
            }
            Button("更新") { model.refresh() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var mainAreaPicker: some View {
        HStack(spacing: 8) {
            mainAreaButton(.chats, title: "Chats", symbol: "bubble.left.and.bubble.right")
            mainAreaButton(.conversation, title: "Project Conversations", symbol: "text.bubble")
            if !model.isLocalProviderContext {
                mainAreaButton(.autonomous, title: "Autonomous Workflow", symbol: "point.3.connected.trianglepath.dotted")
                mainAreaButton(.extensions, title: "Skills & MCP", symbol: "puzzlepiece.extension")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func mainAreaButton(_ area: MainArea, title: String, symbol: String) -> some View {
        Button {
            mainArea = area
            switch area {
            case .chats:
                model.isProjectConversationActive = false
            case .conversation:
                model.selectedDiscussionID = nil
                model.isProjectConversationActive = model.selectedSessionID != nil
            case .autonomous, .extensions:
                model.selectedDiscussionID = nil
                model.isProjectConversationActive = model.selectedSessionID != nil
            }
        } label: {
            Label(model.localized(title), systemImage: symbol)
                .font(.callout.weight(mainArea == area ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(mainArea == area ? Color.accentColor.opacity(0.14) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mainArea == area ? .isSelected : [])
    }

    @ViewBuilder
    private var mainAreaContent: some View {
        switch mainArea {
        case .chats:
            chatsPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
        case .conversation:
            conversationPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
        case .autonomous:
            if model.isLocalProviderContext {
                ContentUnavailableView("Not available for local models", systemImage: "desktopcomputer", description: Text("Local mode supports read-only project chat and discussion. Autonomy, write access, terminal, Skills, and MCP are unavailable for this local session."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AutonomousWorkflowView(model: model) { sessionID in
                    model.openProjectSession(sessionID)
                    mainArea = .conversation
                }
            }
        case .extensions:
            if model.isLocalProviderContext {
                ContentUnavailableView("Not available for local models", systemImage: "desktopcomputer", description: Text("Skills and MCP are unavailable for local sessions."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ActiveExtensionsView(model: model)
                        extensionPolicyPanel
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var chatsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Start a chat") {
                    VStack(alignment: .leading, spacing: 9) {
                        Picker("Provider", selection: Binding(
                            get: { model.newDiscussionProvider },
                            set: { model.selectNewDiscussionProvider($0) }
                        )) {
                            Text("Codex").tag(AgentProvider.codex)
                            Text("Claude").tag(AgentProvider.claude)
                            Text("Local").tag(AgentProvider.local)
                        }
                        if let profile = model.accountProfiles[model.newDiscussionProvider]?.first(where: {
                            $0.id == model.newDiscussionProfileID
                        }) {
                            Picker(model.newDiscussionProvider == .local ? "Memory account" : "Account", selection: Binding(
                                get: { model.newDiscussionProfileID ?? profile.id },
                                set: { model.selectNewDiscussionProfile($0) }
                            )) {
                                ForEach(model.accountProfiles[model.newDiscussionProvider] ?? []) { account in
                                    Text(account.name).tag(account.id)
                                }
                            }
                        } else {
                            Text("No account profile is available for this provider.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(model.newDiscussionProvider == .local
                            ? "Local chats use the configured model and separate local memory account. No API key or cloud fallback is used."
                            : "Chats use the provider’s official CLI subscription sign-in. Claude API usage is not available here.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.newDiscussionProvider == .local
                            || model.selectedDiscussion?.provider == .local
                            || model.settings.defaultProvider == .local {
                            LocalModelSettingsSection(model: model)
                        }
                        Button {
                            model.createDiscussion()
                        } label: {
                            Label("New Chat", systemImage: "plus.bubble")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isChangingWorkspaceRoot)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("Chats") {
                    if model.discussions.isEmpty {
                        Text("No saved chats yet. Start a New Chat whenever you are ready.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.discussions) { discussion in
                                Button {
                                    model.openDiscussion(discussion.id)
                                } label: {
                                    discussionRow(discussion)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                GroupBox("Project sessions") {
                    if model.sessions.isEmpty {
                        Text("Project sessions appear here after you create or link a Git project.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.sessions) { session in
                                Button {
                                    model.openProjectSession(session.id)
                                    mainArea = .conversation
                                } label: {
                                    projectSessionRow(session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 300)
    }

    private var projectSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingsPanel
                if model.isLocalProviderContext && model.settings.defaultProvider != .local {
                    LocalModelSettingsSection(model: model)
                }
                if model.settings.defaultProvider != .local { usagePanel }
                accountPanel
                DisclosureGroup("Project configuration", isExpanded: $isProjectConfigurationExpanded) {
                    workspacePanel
                        .padding(.top, 8)
                }
                sessionList
                if !model.isLocalProviderContext { taskBoardPanel }
            }
            .padding(12)
        }
        .frame(width: 330)
    }

    private func discussionRow(_ discussion: DiscussionRecord) -> some View {
        let isSelected = model.selectedDiscussionID == discussion.id
        let title = discussion.turns.first?.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleText = title.flatMap { $0.isEmpty ? nil : String($0.prefix(46)) }
            ?? model.localized("New conversation")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: discussion.provider == .codex ? "sparkle" : (discussion.provider == .local ? "desktopcomputer" : "message"))
                Text(titleText)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if discussion.status.isInFlight {
                    ProgressView().controlSize(.small)
                }
            }
            Text(model.localizedFormat(
                "%@ · %@ · %@",
                discussion.provider.rawValue.capitalized,
                model.profileName(for: discussion.provider, profileID: discussion.accountProfileID),
                discussion.updatedAt.formatted(date: .abbreviated, time: .shortened)
            ))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func projectSessionRow(_ session: SessionRecord) -> some View {
        let isSelected = model.isProjectConversationActive && model.selectedSessionID == session.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: session.provider == .codex ? "sparkle" : (session.provider == .local ? "desktopcomputer" : "message"))
            Text(model.localizedFormat(
                "%@ · %@",
                session.provider.rawValue.capitalized,
                URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent
            ))
                    .font(.callout.weight(.medium)).lineLimit(1)
            }
            Text(model.localizedFormat("%@ · %@", model.profileName(for: session), String(session.snapshotCommit.prefix(12))))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var chatsPanel: some View {
        if let discussion = model.selectedDiscussion {
            DiscussionChatView(model: model, discussionID: discussion.id) { session in
                model.openProjectSession(session.id)
                mainArea = .conversation
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text("Start with a chat")
                    .font(.title2.weight(.semibold))
                Text("Discuss an idea first. You can create a Git project or link an existing one later, after reviewing exactly what to carry over.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                Button {
                    model.createDiscussion()
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isChangingWorkspaceRoot)
                Text("Chats are saved under your selected workspace data root and stay separate from Git projects until you choose a handoff.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                        Text("Local").tag(AgentProvider.local)
                }
                if model.settings.defaultProvider == .claude {
                    Picker("Claude 使用模式", selection: Binding(
                            get: { model.settings.usageMode },
                            set: { model.selectUsageMode($0) }
                        )) {
                            Text("官方 CLI 訂閱登入").tag(UsageMode.subscription)
                            Text("Claude API（每次確認）").tag(UsageMode.api)
                    }
                } else if model.settings.defaultProvider == .local {
                    Label("Local mode uses a configured loopback model. No subscription quota, API key, or cloud fallback applies.", systemImage: "desktopcomputer")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Codex 使用官方 CLI 訂閱登入", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.isClaudeAPIRunContext {
                    Label("Claude API 會產生費用；每次執行都要確認。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.settings.defaultProvider == .local {
                    LocalModelSettingsSection(model: model)
                } else {
                    DisclosureGroup("CLI 執行檔") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Codex CLI 自動尋找", text: $model.codexPath)
                            TextField("Claude CLI 自動尋找", text: $model.claudePath)
                            Button("儲存 CLI 路徑") { model.saveSettings() }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(model.hasActiveAutonomousWorkflow || model.hasActiveDiscussionOperation)
    }

    private var usagePanel: some View {
        GroupBox(model.settings.defaultProvider == .claude && model.settings.usageMode == .api
            ? "Claude API 本機預算"
            : "訂閱活動估計") {
            VStack(alignment: .leading, spacing: 8) {
                if model.settings.defaultProvider == .claude && model.settings.usageMode == .api {
                    apiUsageDashboard
                } else {
                    subscriptionUsageDashboard
                }
                if model.settings.defaultProvider == .claude {
                    apiReconciliationPanel
                }
                if let alert = model.usageAlerts.first {
                    Label(model.localized(alert), systemImage: "bell.badge")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("macOS 門檻通知（需允許通知）", isOn: Binding(
                    get: { model.usageControls.macOSNotificationsEnabled },
                    set: { model.setMacOSUsageNotificationsEnabled($0) }
                ))
                .font(.caption2)
                if !model.usageControlStatus.isEmpty {
                    Text(model.localized(model.usageControlStatus))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var apiReconciliationPanel: some View {
        if !model.apiReconciliationCandidates.isEmpty {
            GroupBox("手動結算未確認的 Claude API 費用") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("選擇此帳戶綁定的工作階段，並依 Anthropic 帳單輸入實際費用。這只更新本機帳本，不會呼叫 provider；只有帳單明確顯示零費用時才輸入 0。若狀態仍是執行中，系統會先確認沒有作用中的執行鎖；只有中斷後殘留的狀態才會標記失敗並結算。若一個帳本先完成，使用相同金額重試即可。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: model.localized("帳戶：%@"), model.selectedAccountProfile?.name ?? "Claude"))
                        .font(.caption2.weight(.semibold))
                    ForEach(model.apiReconciliationCandidates) { candidate in
                        Button {
                            model.apiReconciliationSessionID = candidate.session.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: candidate.session.id == model.apiReconciliationSessionID ? "largecircle.fill.circle" : "circle")
                                    Text(URL(fileURLWithPath: candidate.session.sourceRepositoryPath).lastPathComponent)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text(model.localized(candidate.session.status.rawValue.capitalized))
                                        .foregroundStyle(candidate.session.status == .running ? .orange : .secondary)
                                }
                                Text(candidate.session.id.uuidString.lowercased())
                                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(String(format: model.localized("月度預留：%@ · 每日/工作階段預留：%@"),
                                            model.localized(candidate.monthlyLedgerUnresolved ? "未結算" : "無待結算"),
                                            model.localized(candidate.dailySessionLedgerUnresolved ? "未結算" : "無待結算")))
                                    .font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    HStack {
                        Text("帳單實際費用（USD）").font(.caption2)
                        TextField("例如 1.25", text: $model.apiReconciliationActualUSD)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 105)
                    }
                    Toggle("我已對照 Anthropic provider 帳單，確認這是所選工作階段的實際費用。", isOn: $model.apiReconciliationConfirmed)
                        .font(.caption2)
                    Button("結算已確認的費用") { model.reconcileSelectedAPICost() }
                        .controlSize(.small)
                        .disabled(model.selectedAPIReconciliationCandidate == nil
                            || !model.apiReconciliationConfirmed)
                    if !model.apiReconciliationStatus.isEmpty {
                        Text(model.localized(model.apiReconciliationStatus))
                            .font(.caption2)
                            .foregroundStyle(model.apiReconciliationStatus.contains("已手動結算") ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        } else if (model.budgetSnapshot?.reservedUSD ?? 0) > 0 {
            Label("月度帳本包含無法安全歸屬到目前 Claude 帳戶的舊預留；為避免把費用分配給錯誤帳戶，這些預留目前不能由此處結算。", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subscriptionUsageDashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let activity = model.usageStatistics {
                HStack(spacing: 6) {
                    usageMetric("近 5 小時", value: "\(activity.subscriptionFiveHourRuns)", detail: "次本機啟動")
                    usageMetric("近 7 天", value: "\(activity.subscriptionSevenDayRuns)", detail: "次本機啟動")
                }
                Chart(activity.sevenDayBuckets) { bucket in
                    BarMark(
                        x: .value(model.localized("24 小時區間"), bucket.index),
                        y: .value(model.localized("AgentBridge 啟動"), bucket.runCount)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: activity.sevenDayBuckets.map(\.index)) { value in
                        AxisValueLabel {
                            if let index = value.as(Int.self),
                               let bucket = activity.sevenDayBuckets.first(where: { $0.index == index }) {
                                Text(model.localized(bucket.label)).font(.system(size: 8))
                            }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 82)
                Text(String(format: model.localized("近 24 小時：%@ 次 · 目前 AgentBridge 工作階段：%@ 次。只統計此 %@ 帳戶的本機執行嘗試，不是供應商額度或帳戶總用量；互動終端回合不會被讀取。"),
                            String(activity.subscriptionDailyRuns),
                            String(activity.subscriptionSessionRuns),
                            activity.provider.rawValue.capitalized))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(format: model.localized("本機統計更新於 %@"),
                            activity.generatedAt.formatted(Date.FormatStyle(time: .shortened).locale(model.appLanguage.locale))))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            } else {
                ProgressView("載入本機活動記錄…").controlSize(.small)
            }
            Label("按下「送出 /usage」後，App 會從官方 CLI 可見畫面盡力辨識方案、用量百分比與重置時間；未知欄位顯示「Not provided / 未提供」。請以仍開啟的原始 TUI 核對資料卡。", systemImage: "terminal")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("開啟官方 CLI 用量終端") { model.openSubscriptionUsageTUI() }
                    .controlSize(.small)
                    .disabled(model.terminalLaunch != nil || model.isSwitchingTarget)
                Text("等終端顯示可輸入提示符並完成登入後，再按「送出 /usage」。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = model.providerUsageReport,
               report.provider == model.settings.defaultProvider,
               report.accountProfileID == model.selectedProfileIDs[model.settings.defaultProvider] {
                providerUsageReportCard(report)
            }
            DisclosureGroup("AgentBridge 本機執行上限") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("留空或輸入 0 代表不限。上限計算 AgentBridge 管理的唯讀執行提示與互動工作階段啟動，不代表 provider 限額或 TUI 內的回合。")
                        .font(.caption2).foregroundStyle(.secondary)
                    usageLimitRow("近 5 小時", keyPath: \.subscriptionFiveHourRunLimit)
                    usageLimitRow("近 24 小時", keyPath: \.subscriptionDailyRunLimit)
                    usageLimitRow("近 7 天", keyPath: \.subscriptionWeeklyRunLimit)
                    usageLimitRow("目前工作階段", keyPath: \.subscriptionSessionRunLimit)
                    Button("儲存本機上限") { model.saveUsageControlSettings() }
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
    }

    private var apiUsageDashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let budget = model.budgetSnapshot {
                let committed = budget.usedUSD + budget.reservedUSD
                HStack(spacing: 5) {
                    usageMetric("本月已用", value: String(format: "$%.2f", budget.usedUSD), detail: "本機帳本")
                    usageMetric("已保留", value: String(format: "$%.2f", budget.reservedUSD), detail: "未結算執行")
                }
                HStack {
                    Text("可用")
                    Spacer()
                    Text(String(format: "$%.2f", budget.availableUSD)).fontWeight(.semibold)
                }
                .font(.caption)
                ProgressView(value: min(1, committed / budget.monthlyLimitUSD))
                    .tint(committed >= budget.monthlyLimitUSD ? .red : .accentColor)
                if committed >= budget.monthlyLimitUSD {
                    Label("已達 AgentBridge 本機月上限；新的 API 執行會被阻擋。", systemImage: "xmark.octagon.fill")
                        .font(.caption2).foregroundStyle(.red)
                }
                let builtInLedgerNote = model.selectedAccountProfile?.id == AccountProfile.defaultID(for: .claude)
                    ? "內建帳戶沿用舊版帳本；舊紀錄的帳戶歸屬無法還原。新帳戶各自使用獨立帳本。"
                    : "此 Claude 帳戶使用獨立帳本；App 與 CLI 共用。"
                Text(String(format: model.localized("UTC %@ · 本機月上限 $%.2f。此帳本與 Anthropic provider credit/帳單分開。%@"), budget.month, budget.monthlyLimitUSD, model.localized(builtInLedgerNote)))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("此 Claude 帳戶尚未設定本機 API 月上限；完成設定前不會啟用 API 執行。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let activity = model.usageStatistics {
                Text(String(format: model.localized("此帳戶近 24 小時 API 啟動：%@ 次 · 目前工作階段：%@ 次"),
                            String(activity.apiDailyRuns),
                            String(activity.apiSessionRuns)))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(String(format: model.localized("本機統計更新於 %@"),
                            activity.generatedAt.formatted(Date.FormatStyle(time: .shortened).locale(model.appLanguage.locale))))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            if let costs = model.apiCostSnapshot {
                if let limit = costs.dailyLimitUSD {
                    apiDollarCapRow(
                        title: "UTC 今日 API 費用上限",
                        used: costs.dailyUsedUSD,
                        reserved: costs.dailyReservedUSD,
                        limit: limit
                    )
                }
                if let limit = costs.sessionLimitUSD {
                    apiDollarCapRow(
                        title: "目前 AgentBridge 工作階段 API 費用上限",
                        used: costs.sessionUsedUSD,
                        reserved: costs.sessionReservedUSD,
                        limit: limit
                    )
                }
                if costs.hasUnresolvedCall {
                    Label("上一筆 API 執行費用尚未確認；新的付費執行會保持封鎖。", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            DisclosureGroup("Claude API 本機控制") {
                VStack(alignment: .leading, spacing: 6) {
                    if model.selectedAccountProfile?.id == AccountProfile.defaultID(for: .claude) {
                        Text("內建 Claude 帳戶沿用既有 AgentBridge 本機 US$140 月帳本；App 與 CLI 共用。舊版帳本沒有帳戶欄位，過去紀錄可能跨帳戶，無法回溯拆分。")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("本機月上限（USD）")
                            TextField("例如 25", text: $model.apiMonthlyLimitInput)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.usageControls.apiMonthlyLimitUSD != nil)
                                .frame(width: 95)
                        }
                        if model.usageControls.apiMonthlyLimitUSD != nil {
                            Text("此帳戶月帳本已建立；為保留既有支出，月上限不能再變更。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("美元上限（預留金額按單次預算的兩倍計算）")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    apiDollarLimitInputRow("UTC 每日 USD 上限", text: $model.apiDailyLimitInput)
                    apiDollarLimitInputRow("工作階段 USD 上限", text: $model.apiSessionLimitInput)
                    Text("選用 API 執行次數上限（獨立於美元上限）")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    usageLimitRow("近 24 小時執行次數", keyPath: \.apiDailyRunLimit)
                    usageLimitRow("目前工作階段執行次數", keyPath: \.apiSessionRunLimit)
                    Toggle("停用此帳戶後續 Claude API 執行", isOn: Binding(
                        get: { model.usageControls.disableFutureAPI },
                        set: { value in model.updateUsageControls { $0.disableFutureAPI = value } }
                    ))
                    .font(.caption2)
                    Button("儲存本機控制") { model.saveUsageControlSettings() }
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }
            Text("每次填寫的 USD 預算是本次 API 執行上限；本機月預算、API 執行次數及 provider credit 是不同限制。停用後續 API 只會阻止此帳戶未來的 AgentBridge API 執行，不會切換帳戶或模式。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Claude API 本機帳本不代表訂閱用量；若要查看 Claude 訂閱方案用量，請切回官方 CLI 訂閱登入模式，再由訂閱活動面板開啟用量終端。", systemImage: "terminal")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func usageMetric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.localized(title)).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            Text(model.localized(detail)).font(.system(size: 8)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }

    private func apiDollarLimitInputRow(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(model.localized(title)).font(.caption2)
            Spacer(minLength: 4)
            TextField("不限", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 95)
        }
    }

    private func providerUsageReportCard(_ report: ProviderUsageReport) -> some View {
        GroupBox("官方 /usage 摘要 · Best-effort") {
            VStack(alignment: .leading, spacing: 5) {
                usageReportField("Provider / 供應商", report.provider.rawValue.capitalized)
                usageReportField("Selected account / 選取帳戶", report.accountName)
                usageReportField("Plan / 方案", report.plan ?? "Not provided / 未提供", localizeValue: report.plan == nil)
                if report.usageWindows.isEmpty {
                    usageReportField("Usage windows / 用量視窗", "Not provided / 未提供", localizeValue: true)
                } else {
                    ForEach(report.usageWindows) { window in
                        Divider()
                        Text(model.localized(window.label)).font(.caption.weight(.semibold))
                        usageReportField(
                            "Used / 已使用",
                            formattedUsagePercentage(window.percentageUsed),
                            localizeValue: window.percentageUsed == nil
                        )
                        usageReportField(
                            "Reset / 重置",
                            window.resetText ?? "Not provided / 未提供",
                            localizeValue: window.resetText == nil
                        )
                    }
                }
                usageReportField("Source / 來源", model.localized(report.source))
                usageReportField(
                    "Status / 狀態",
                    report.status == .recognizedFields
                        ? "Some fields recognized / 已辨識部分欄位"
                        : "No recognized fields / 未辨識到欄位",
                    localizeValue: true
                )
                usageReportField("Captured / 擷取時間", report.capturedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(model.appLanguage.locale)))
                Text("Best-effort screen reading, not a stable API. Keep the official TUI visible to verify these fields. / 依畫面盡力辨識，非穩定 API；請保留官方 TUI 畫面核對。")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func usageReportField(_ title: String, _ value: String, localizeValue: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(model.localized(title)).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(localizeValue ? model.localized(value) : value).font(.caption2.monospacedDigit()).multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedUsagePercentage(_ value: Double?) -> String {
        guard let value else { return "Not provided / 未提供" }
        return value.rounded() == value ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    private func apiDollarCapRow(title: String, used: Double, reserved: Double, limit: Double) -> some View {
        let committed = used + reserved
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model.localized(title))
                Spacer(minLength: 4)
                Text(String(format: "$%.2f / $%.2f", committed, limit)).fontWeight(.semibold)
            }
            .font(.caption2)
            ProgressView(value: min(1, committed / limit))
                .tint(committed >= limit ? .red : .accentColor)
            Text(String(format: model.localized("已用 $%.2f · 保留 $%.2f · 可用 $%.2f"), used, reserved, max(0, limit - committed)))
                .font(.system(size: 8)).foregroundStyle(.secondary)
            if committed >= limit {
                Label("已達本機 USD 上限；新的 API 執行會被阻擋。", systemImage: "xmark.octagon.fill")
                    .font(.system(size: 8)).foregroundStyle(.red)
            }
        }
    }

    private func usageLimitRow(_ title: String, keyPath: WritableKeyPath<UsageControlSettings, Int?>) -> some View {
        HStack {
            Text(model.localized(title)).font(.caption2)
            Spacer(minLength: 4)
            TextField("0 = 不限", value: usageLimitBinding(keyPath), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 75)
        }
    }

    private func usageLimitBinding(_ keyPath: WritableKeyPath<UsageControlSettings, Int?>) -> Binding<Int> {
        Binding(
            get: { model.usageControls[keyPath: keyPath] ?? 0 },
            set: { value in
                model.updateUsageControls { settings in
                    settings[keyPath: keyPath] = value == 0 ? nil : value
                }
            }
        )
    }

    private var accountPanel: some View {
        GroupBox(model.settings.defaultProvider == .local ? "Local memory account" : "官方 CLI 帳戶") {
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
                    if model.settings.defaultProvider == .local {
                        Text("This account scopes local chat memory consent. It does not have a CLI login or provider plan.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let assessment = model.selectedProfileAuthentication {
                        Label(model.localized(assessment.message), systemImage: assessment.confirmedSubscription ? "checkmark.seal" : "exclamationmark.shield")
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
                    if model.settings.defaultProvider == .local {
                        Text("Local models do not use sign-in or credential folders.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if !profile.usesExistingLogin {
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
                TextField(model.settings.defaultProvider == .local ? "New local account name" : "新帳戶顯示名稱", text: $model.newProfileName)
                Toggle("建立後允許共用專案記憶（預設開啟）", isOn: $model.newProfileAllowsSharedMemory)
                    .font(.caption)
                Button("新增並切換帳戶") { model.createAccountProfile() }
                    .disabled(model.newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSwitchingTarget)
            }
            .padding(.vertical, 2)
        }
        .disabled(model.hasActiveAutonomousWorkflow || model.hasActiveDiscussionOperation)
    }

    private var workspacePanel: some View {
        GroupBox("Project") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("資料根目錄").font(.caption.weight(.semibold))
                        Text(model.workspaceRootPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Button("變更…") { model.chooseWorkspaceRoot() }
                        .disabled(model.isChangingWorkspaceRoot || model.isRunning || model.terminalRunning)
                }
                TextField("Git 儲存庫路徑", text: $model.repositoryPath)
                Button("選擇儲存庫…") { model.chooseRepository() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.settings.defaultProvider == .local {
                    Label("Local project chat is read-only. Editing, terminal, autonomy, Skills, and MCP are unavailable.", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Picker("新工作階段存取模式", selection: $model.requestedAccessMode) {
                        Text("唯讀（預設）").tag(AccessMode.readOnly)
                        Text("隔離變更（需先核准計畫）").tag(AccessMode.isolatedChanges)
                            .disabled(model.settings.usageMode == .api)
                        Text("原生互動終端").tag(AccessMode.interactiveManualApproval)
                            .disabled(model.settings.usageMode == .api)
                    }
                    .font(.caption)
                }
                if model.settings.usageMode == .api && model.settings.defaultProvider != .local {
                    Text("Claude API 只提供唯讀工作階段；隔離變更與互動終端僅支援官方 CLI 訂閱登入。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("建立同一專案的新工作階段") { model.createSession() }
                    .disabled(model.repositoryPath.isEmpty || model.isSwitchingTarget)
                Text(model.settings.defaultProvider == .local
                    ? "AgentBridge 固定提交版本並在自己的隔離工作區執行。Local 專案聊天只讀，並依綁定本機帳戶的同意設定共用記憶。"
                    : "AgentBridge 固定提交版本並在自己的隔離工作區執行。相同來源與提交版本在 Codex、Claude 間共用聊天記憶。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .disabled(model.hasActiveAutonomousWorkflow || model.hasActiveDiscussionOperation)
    }

    private var sessionList: some View {
        GroupBox("工作階段") {
            if model.sessions.isEmpty {
                ContentUnavailableView("尚無工作階段", systemImage: "bubble.left.and.bubble.right")
                    .frame(minHeight: 120)
            } else {
                List(model.sessions, selection: Binding(
                    get: { model.selectedSessionID },
                    set: { if let id = $0 { model.openProjectSession(id) } }
                )) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: session.provider == .codex ? "sparkle" : (session.provider == .local ? "desktopcomputer" : "message"))
                            Text(session.provider.rawValue.capitalized)
                                .font(.headline)
                            if session.policy.accessMode == .interactiveManualApproval {
                                Text("Terminal").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: Capsule())
                            } else if session.policy.accessMode == .isolatedChanges {
                                Text("Isolated changes").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(.orange.opacity(0.14), in: Capsule())
                            }
                        }
                        Text("\(model.profileName(for: session)) · \(model.localized(session.status.rawValue.capitalized))")
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
                if session.provider == .local {
                    chatTimeline
                    composer(session)
                    activityTimeline
                } else if session.policy.accessMode == .readOnly {
                    chatTimeline
                    composer(session)
                    activityTimeline
                } else if session.policy.accessMode == .isolatedChanges {
                    changeWorkflowPanel(session)
                    activityTimeline
                } else {
                    interactivePanel(session)
                    activityTimeline
                }
            } else {
                ContentUnavailableView("選擇或建立工作階段", systemImage: "bubble.left.and.bubble.right", description: Text("先選擇 Git 儲存庫，再開始一段固定版本的專案對話。"))
                    .frame(maxWidth: .infinity, maxHeight: model.terminalLaunch == nil ? .infinity : 110)
            }
            if !model.isSetupWizardPresented, let launch = model.terminalLaunch {
                EmbeddedTerminalPanel(model: model, launch: launch)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func conversationHeader(_ session: SessionRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.provider == .codex ? "sparkle" : (session.provider == .local ? "desktopcomputer" : "message"))
                .font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.provider.rawValue.capitalized) · \(model.profileName(for: session))")
                    .font(.headline)
                Text("\(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent) · \(session.snapshotCommit.prefix(12))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let assessment = model.selectedSessionAuthentication {
                Label(model.localized(assessment.message), systemImage: assessment.confirmedSubscription ? "checkmark.seal" : "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if session.provider == .local {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.settings.localModel.model.isEmpty ? model.localized("No model selected") : model.settings.localModel.model)
                        .font(.caption.weight(.medium))
                    Text(model.settings.localModel.endpoint)
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Text(model.localized(model.localModelStatus))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Button("本機終端機") { model.openLocalShell() }
                    .disabled(model.terminalLaunch != nil)
            }
            if session.provider != .local && session.policy.accessMode == .interactiveManualApproval {
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
                        Text(String(format: model.localized("修訂 %@ · %@ 則對話%@"),
                                    String(memory.revision),
                                    String(memory.turns.count),
                                    memory.wasTruncated ? model.localized(" · 顯示最近內容") : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let memory = model.memorySnapshot {
                    Text(String(format: model.localized("來源 %@ · 固定提交 %@"),
                                URL(fileURLWithPath: memory.scope.repositoryPath).lastPathComponent,
                                String(memory.scope.snapshotCommit.prefix(12))))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if let profile = model.boundProfile(for: session), !profile.allowsSharedMemory {
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
                DisclosureGroup("明確交接至另一個提交版本") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("只會複製你選取的 App 聊天回合與備註。目標工作階段綁定的帳戶必須允許共用記憶；交接會以來源與目標提交版本標記，並作為明確的未信任歷史內容附加到目標提示。")
                            .font(.caption2).foregroundStyle(.secondary)
                        if model.memoryHandoffTargets.isEmpty {
                            Text("需要同一個儲存庫的另一個不同提交版本工作階段。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Picker("目標工作階段", selection: $model.memoryHandoffTargetSessionID) {
                                Text("選擇目標").tag(UUID?.none)
                                ForEach(model.memoryHandoffTargets) { target in
                                    Text("\(target.provider.rawValue.capitalized) · \(target.snapshotCommit.prefix(12)) · \(model.profileName(for: target))")
                                        .tag(Optional(target.id))
                                }
                            }
                            if model.memoryHandoffTargetSessionID != nil && !model.selectedMemoryTargetCanReceiveHandoff {
                                Label("Select the target session’s bound account and allow shared memory before creating this handoff.", systemImage: "lock.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            if let turns = model.memorySnapshot?.turns, !turns.isEmpty {
                                Text("選取要帶入的對話回合")
                                    .font(.caption.weight(.semibold))
                                ForEach(turns) { turn in
                                    Toggle(isOn: Binding(
                                        get: { model.selectedMemoryTurnIDs.contains(turn.id) },
                                        set: { selected in
                                            if selected { model.selectedMemoryTurnIDs.insert(turn.id) }
                                            else { model.selectedMemoryTurnIDs.remove(turn.id) }
                                        }
                                    )) {
                                        Text("\(turn.provider.rawValue.capitalized) · \(turn.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(turn.userText.prefix(72))")
                                            .font(.caption2).lineLimit(2)
                                    }
                                }
                            }
                            Toggle("包含目前已儲存的專案備註", isOn: $model.includeMemoryNotes)
                                .font(.caption)
                            Button("建立明確記憶交接") { model.carryForwardSelectedMemory() }
                                .disabled(model.memoryHandoffTargetSessionID == nil || !model.selectedMemoryTargetCanReceiveHandoff || (model.selectedMemoryTurnIDs.isEmpty && !model.includeMemoryNotes))
                        }
                        if !model.projectMemoryHandoffs.isEmpty {
                            Divider()
                            Text("此儲存庫的交接記錄")
                                .font(.caption.weight(.semibold))
                            ForEach(model.projectMemoryHandoffs.prefix(5)) { handoff in
                                Text("\(handoff.sourceCommit.prefix(12)) → \(handoff.targetCommit.prefix(12)) · \(handoff.turns.count) turns · \(handoff.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 5)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func changeWorkflowPanel(_ session: SessionRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                GroupBox("Isolated changes · review before writing") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This session writes only inside its isolated workspace. Each change run requires an editable plan, an explicit approval, and official CLI subscription mode. The source repository is not changed by the run.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Plan title", text: $model.changePlanTitle)
                        TextField("Plan summary", text: $model.changePlanSummary, axis: .vertical)
                            .lineLimit(2...4)
                        Text("Plan steps · one step per line")
                            .font(.caption.weight(.semibold))
                        TextEditor(text: $model.changePlanStepsText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 70, maxHeight: 130)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        HStack {
                            Button("Save plan for review") { model.saveChangePlan() }
                            if let plan = session.changePlan {
                                Text("Plan digest · \(plan.reviewDigest.prefix(16))")
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                                Spacer()
                                if !model.selectedChangePlanDraftMatchesSaved {
                                    Label("Unsaved plan edits. Save changes before review or approval.", systemImage: "pencil.line")
                                        .font(.caption).foregroundStyle(.orange)
                                } else if model.selectedChangePlanIsApproved {
                                    Label("Approved", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                                } else {
                                    Button("Approve this displayed plan") { model.approveChangePlan() }
                                        .buttonStyle(.borderedProminent)
                                }
                            }
                        }
                        if session.changePlan != nil,
                           model.selectedChangePlanDraftMatchesSaved,
                           !model.selectedChangePlanIsApproved {
                            Text("The saved plan is pending approval. Editing and saving it again clears any earlier approval.")
                                .font(.caption2).foregroundStyle(.orange)
                        }
                    }
                }

                GroupBox("Run request") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $model.prompt)
                            .font(.system(.body, design: .rounded))
                            .frame(minHeight: 70, maxHeight: 120)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        HStack {
                            Button("Run approved changes") { model.runApprovedChanges() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.isSwitchingTarget || !model.canStartAnotherRun || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.changePlan == nil || !model.selectedChangePlanDraftMatchesSaved || !model.selectedChangePlanIsApproved || model.settings.usageMode != .subscription)
                            if model.selectedSessionIsRunning { Button("Cancel this session") { model.cancelSession(session.id) } }
                            Spacer()
                        }
                    }
                }

                verificationPanel(session)
                changeDiffPanel(session)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func verificationPanel(_ session: SessionRecord) -> some View {
        GroupBox("Verification") {
            VStack(alignment: .leading, spacing: 8) {
                Text("The default runs the workspace’s .codex/ci.sh only after you select the button. A custom executable and its separate argv entries run only after you select the explicit approval button; no shell command string is constructed.")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Run .codex/ci.sh") { model.runVerification() }
                        .disabled(!model.canStartAnotherRun || model.isSwitchingTarget || model.changeDiff?.files.isEmpty != false)
                    if model.selectedSessionIsRunning { Button("Cancel verification") { model.cancelSession(session.id) } }
                    if model.verifiedCurrentDiff {
                        Label("Current diff verified", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                    } else {
                        Label("Verification must pass for this exact diff", systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                    }
                }
                DisclosureGroup("Use an approved custom verifier") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("Absolute executable path", text: $model.customVerifierPath)
                            Button("Choose…") { model.chooseCustomVerifier() }
                        }
                        Text("Arguments · one argv item per line; spaces stay inside that argument")
                            .font(.caption2).foregroundStyle(.secondary)
                        TextEditor(text: $model.customVerifierArgumentsText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 45, maxHeight: 85)
                        Button("Approve and run this executable with these arguments") { model.runVerification(custom: true) }
                            .disabled(model.customVerifierPath.isEmpty || !model.canStartAnotherRun || model.changeDiff?.files.isEmpty != false)
                    }
                    .padding(.top, 4)
                }
                if let result = model.verificationResult {
                    HStack(spacing: 10) {
                        Text("Exit: \(result.exitCode.map(String.init) ?? "not reported")")
                        Text("Duration: \(String(format: "%.3f", result.durationSeconds))s")
                        Text(result.succeeded ? "CLI reported success" : (result.skippedReason ?? (result.wasCancelled ? "Cancelled" : "Not successful")))
                    }
                    .font(.caption.monospacedDigit())
                    if !result.standardOutput.isEmpty {
                        Text("Standard output").font(.caption.weight(.semibold))
                        Text(result.standardOutput).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !result.standardError.isEmpty {
                        Text("Standard error").font(.caption.weight(.semibold))
                        Text(result.standardError).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func changeDiffPanel(_ session: SessionRecord) -> some View {
        GroupBox("Full file diff") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(model.changeDiff?.files.count ?? 0) changed files")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Button("Refresh diff") { model.refreshSelectedEvents() }
                    Button("Export patch…") { model.exportChangePatch() }
                        .disabled(model.changeDiff?.files.isEmpty != false)
                    Button("Restore all", role: .destructive) {
                        model.restoreAllChangeFiles()
                    }
                    .disabled(model.changeDiff?.files.isEmpty != false)
                }
                if let diff = model.changeDiff, !diff.files.isEmpty {
                    ForEach(diff.files, id: \.path) { file in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(file.path).font(.caption.monospaced()).textSelection(.enabled)
                                    Text(file.status.rawValue).font(.caption2).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Reject / restore file", role: .destructive) { model.restoreChangeFile(file.path) }
                                }
                                if file.isBinary {
                                    Text("Binary diff; file content is represented as binary.")
                                        .font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    ScrollView([.horizontal, .vertical]) {
                                        Text(file.patch).font(.system(.caption2, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .frame(minHeight: 90, maxHeight: 260)
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No changes in the isolated workspace", systemImage: "doc.text.magnifyingglass")
                        .frame(minHeight: 90)
                }
                HStack {
                    Button("Accept this verified diff") { model.acceptChanges() }
                        .disabled(!model.verifiedCurrentDiff || model.changeDiff?.files.isEmpty != false)
                    TextField("Local branch name", text: $model.branchName)
                        .frame(maxWidth: 240)
                    Button("Apply to branch as an uncommitted worktree") { model.applyChangesToBranch() }
                        .disabled(!model.verifiedCurrentDiff || model.changeDiff?.files.isEmpty != false || model.branchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("Applying checks the source base commit for conflicts and creates an uncommitted isolated worktree. AgentBridge never commits, pushes, or merges.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var activityTimeline: some View {
        GroupBox("Activity timeline") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ordered, redacted audit events. Progress, responses, and claims show what the underlying CLI reported; verification includes the process exit code and elapsed time.")
                    .font(.caption2).foregroundStyle(.secondary)
                if model.events.isEmpty {
                    Text("No activity recorded yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(model.events.sorted(by: { $0.timestamp < $1.timestamp }).suffix(80)) { event in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(event.kind).font(.caption.weight(.semibold).monospaced())
                                        Spacer()
                                        Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Text(event.message).font(.caption2).textSelection(.enabled)
                                }
                                .padding(7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    private var taskBoardPanel: some View {
        GroupBox("Parallel session task records") {
            VStack(alignment: .leading, spacing: 6) {
                Text("These records track individual session launches. Autonomous Workflow creates a separate approved plan, coordinates several role profiles, and has its own review and cancellation state.")
                    .font(.caption2).foregroundStyle(.secondary)
                if model.taskRecords.isEmpty {
                    Text("No run records yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.taskRecords.prefix(12)) { task in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(task.status.rawValue).font(.caption.weight(.semibold))
                                Text(task.approvalState.rawValue).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                if task.status == .inProgress {
                                    Button("Cancel") { model.cancelSession(task.sessionID) }
                                }
                            }
                            Text(task.progressSummary).font(.caption2).textSelection(.enabled)
                            Text("Session \(task.sessionID.uuidString.lowercased())")
                                .font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                            ForEach(task.references, id: \.self) { reference in
                                Text("\(reference.kind.rawValue): \(reference.value)")
                                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    private var extensionPolicyPanel: some View {
        GroupBox("Skills / MCP policy metadata") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Imports are inert descriptors. Grants are narrow per-project policy metadata only; they do not activate or execute provider extensions. Import never runs scripts.")
                    .font(.caption2).foregroundStyle(.orange)
                Button("Import descriptor JSON…") { model.isImportingExtensionDescriptor = true }
                if model.extensionDescriptors.isEmpty {
                    Text("No descriptors imported.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Descriptor", selection: $model.selectedExtensionID) {
                        Text("Select descriptor").tag("")
                        ForEach(model.extensionDescriptors) { descriptor in
                            Text("\(descriptor.kind.rawValue.uppercased()) · \(descriptor.name)").tag(descriptor.id)
                        }
                    }
                    if let descriptor = model.selectedExtensionDescriptor {
                        Text("\(descriptor.id) · v\(descriptor.version)\n\(descriptor.summary)")
                            .font(.caption2).textSelection(.enabled)
                        Text("Requested: \(descriptor.requestedPermissions.map(\.rawValue).joined(separator: ", "))")
                            .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                        if let grant = model.selectedExtensionGrant {
                            Text("Current project grant: \(grant.permissions.map(\.rawValue).joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.green)
                        } else {
                            Text("No grant for this project.").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(ExtensionPermission.allCases, id: \.self) { permission in
                            Toggle(permission.rawValue, isOn: Binding(
                                get: { model.selectedExtensionPermissions.contains(permission) },
                                set: { enabled in
                                    if enabled { model.selectedExtensionPermissions.insert(permission) }
                                    else { model.selectedExtensionPermissions.remove(permission) }
                                }
                            ))
                            .font(.caption2)
                            .disabled(!descriptor.requestedPermissions.contains(permission))
                        }
                        Text("Allowed relative paths · one normalized path per line")
                            .font(.caption2)
                        TextEditor(text: $model.extensionPathScopesText).frame(minHeight: 38, maxHeight: 70)
                        Text("Allowed exact hostnames · one per line")
                            .font(.caption2)
                        TextEditor(text: $model.extensionHostScopesText).frame(minHeight: 38, maxHeight: 70)
                        HStack {
                            Button("Grant selected scopes") { model.grantSelectedExtension() }
                            Button("Revoke for this project", role: .destructive) { model.revokeSelectedExtension() }
                        }
                    }
                }
            }
        }
    }

    private var chatTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let turns = model.memorySnapshot?.turns, !turns.isEmpty {
                        ForEach(turns) { turn in
                            messageBubble(label: model.localized("你"), text: turn.userText, alignment: .trailing, color: Color.accentColor.opacity(0.12), id: "user-\(turn.id)")
                            messageBubble(label: turn.provider.rawValue.capitalized, text: turn.assistantText, alignment: .leading, color: Color(nsColor: .controlBackgroundColor), id: "assistant-\(turn.id)")
                        }
                    } else {
                        ContentUnavailableView("開始專案對話", systemImage: "text.bubble", description: Text("成功完成的對話會依來源儲存庫與固定提交版本寫入共用記憶。"))
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                    if model.selectedSessionIsRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.localized(model.status)).font(.caption).foregroundStyle(.secondary)
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
                Text("取消執行無法撤回已產生的 Anthropic 費用。")
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextEditor(text: $model.prompt)
                    .font(.system(.body, design: .rounded))
                    .frame(minHeight: 78, maxHeight: 118)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
                    .disabled(isLoadingContextPreview || model.selectedSessionIsRunning)
                VStack(spacing: 7) {
                    Button {
                        loadProjectContextPreview(session, showEvenWhenSafe: true)
                    } label: {
                        if isLoadingContextPreview { ProgressView().controlSize(.small) }
                        else { Label(model.localized("Preview context"), systemImage: "text.magnifyingglass") }
                    }
                    .disabled(!model.canStartAnotherRun || model.isSwitchingTarget || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (session.provider == .local && model.localModelSettingsAreDirty) || isLoadingContextPreview)
                    Button(model.localized(model.isClaudeAPIRunContext ? "執行 Claude API" : (session.provider == .local ? "Send to local model" : "傳送"))) {
                        submitProjectPrompt(session)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartAnotherRun || model.isSwitchingTarget || isLoadingContextPreview || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.settings.usageMode == .api && session.provider != .local && (!model.isClaudeAPIRunContext || model.budgetSnapshot == nil)) || (model.isClaudeAPIRunContext && model.usageControls.disableFutureAPI) || (session.provider == .local && model.localModelSettingsAreDirty))
                    if model.selectedSessionIsRunning { Button("取消") { model.cancelRun() } }
                }
            }
            Text(model.localized(session.provider == .local
                ? "Prompts and responses are stored in shared memory only after a successful turn. Context compression preserves recent turns and the exact current request."
                : "提示和回應只在成功完成後進入共用記憶；金鑰不會保存。"))
                .font(.caption2).foregroundStyle(.secondary)
            if session.provider == .local && model.localModelSettingsAreDirty {
                Label(model.localized("Save local model settings before sending."), systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if session.sourceWasDirty {
                Text("來源有未提交變更；此對話固定的工作區不包含那些變更。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $isShowingContextPreview) {
            if let contextPreview {
                ContextPreviewSheet(model: model, preview: contextPreview, settings: contextPreviewSettings)
                    .frame(minWidth: 760, minHeight: 620)
            }
        }
    }

    private func loadProjectContextPreview(_ session: SessionRecord, showEvenWhenSafe: Bool) {
        let currentPrompt = model.prompt
        guard !currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoadingContextPreview = true
        Task { @MainActor in
            defer { isLoadingContextPreview = false }
            do {
                let preview = try await model.previewProjectContext(sessionID: session.id, currentPrompt: currentPrompt)
                contextPreview = preview
                contextPreviewSettings = session.provider == .local ? model.settings.localModel : nil
                if showEvenWhenSafe || preview.requiresReview { isShowingContextPreview = true }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func submitProjectPrompt(_ session: SessionRecord) {
        guard !model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard session.provider != .local || !model.localModelSettingsAreDirty else {
            model.errorMessage = model.localized("Save local model settings before sending.")
            return
        }
        let currentPrompt = model.prompt
        isLoadingContextPreview = true
        Task { @MainActor in
            defer { isLoadingContextPreview = false }
            do {
                let preview = try await model.previewProjectContext(sessionID: session.id, currentPrompt: currentPrompt)
                if preview.requiresReview {
                    contextPreview = preview
                    contextPreviewSettings = session.provider == .local ? model.settings.localModel : nil
                    isShowingContextPreview = true
                    return
                }
                model.runPrompt()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
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

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isRunning || model.isSwitchingTarget || model.terminalRunning { ProgressView().controlSize(.small) }
            Text(model.localized(model.status)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(appVersionFooterText).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    private var appVersionFooterText: String {
        let version = appBundleMetadata("CFBundleShortVersionString")
        let build = appBundleMetadata("CFBundleVersion")

        switch (version, build) {
        case let (.some(version), .some(build)):
            return model.localizedFormat("AgentBridge %@ · Build %@", version, build)
        case let (.some(version), .none):
            return model.localizedFormat("AgentBridge %@", version)
        case let (.none, .some(build)):
            return model.localizedFormat("AgentBridge · Build %@", build)
        case (.none, .none):
            return model.localized("AgentBridge")
        }
    }

    private func appBundleMetadata(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
