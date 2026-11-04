import AppKit
import AgentBridgeCore
import Observation
import UserNotifications

/// State and actions for the first-use setup wizard. Settings, account
/// profiles, sign-in status and the terminal stay on `AppModel`, which the
/// wizard reads and updates through `app`.
@MainActor
@Observable
final class SetupWizardModel {
    var isPresented = false
    var currentStep: SetupWizardStep = .welcome {
        didSet { UserDefaults.standard.set(currentStep.rawValue, forKey: Self.stepPreferenceKey) }
    }
    var provider: AgentProvider = .codex {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: Self.providerPreferenceKey) }
    }
    var profileName = "" {
        didSet { UserDefaults.standard.set(profileName, forKey: Self.profileNamePreferenceKey) }
    }
    var cliPath = "" {
        didSet {
            UserDefaults.standard.set(cliPath, forKey: Self.cliPathPreferenceKey(for: provider))
        }
    }
    var cliStatus = ""
    var usageControls = UsageControlSettings()
    var usageStatus = ""
    var status = ""
    var errorMessage: String?
    var authCheckInProgress = false
    @ObservationIgnored private var authRequestID: UUID?

    private static let startedPreferenceKey = "setupWizard.started"
    private static let completedPreferenceKey = "setupWizard.completed"
    private static let stepPreferenceKey = "setupWizard.step"
    private static let providerPreferenceKey = "setupWizard.provider"
    private static let profileNamePreferenceKey = "setupWizard.profileName"
    static func cliPathPreferenceKey(for provider: AgentProvider) -> String {
        "setupWizard.cliPath.\(provider.rawValue)"
    }

    var selectedProfile: AccountProfile? {
        guard let id = app.selectedProfileIDs[provider] else { return nil }
        return app.accountProfiles[provider]?.first(where: { $0.id == id })
    }

    var authentication: AuthAssessment? {
        guard provider != .local else { return nil }
        guard let profile = selectedProfile else { return nil }
        return app.authStatus[profile.id]
    }

    var resolvedCLIPath: String? {
        guard provider != .local else { return nil }
        let configuredPath = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return try? RuntimeEnvironment.resolveExecutable(
            provider: provider,
            configuredPath: configuredPath.isEmpty ? nil : configuredPath
        ).path
    }

    var savedCLIPath: String? {
        guard provider != .local else { return nil }
        return try? RuntimeEnvironment.resolveExecutable(
            provider: provider,
            configuredPath: app.settings.binaryPath(for: provider)
        ).path
    }

    var cliSettingIsDirty: Bool {
        guard provider != .local else { return false }
        let draft = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = app.settings.binaryPath(for: provider)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return draft != saved
    }

    var readiness: SetupWizardReadiness {
        SetupWizardReadiness(
            workspaceConfigured: app.workspaceRootIsConfigured,
            commandLineAvailable: provider == .local || savedCLIPath != nil,
            commandLineSettingSaved: provider == .local || !cliSettingIsDirty,
            subscriptionLoginConfirmed: provider == .local || authentication?.confirmedSubscription == true
        )
    }

    func initialize(workspaceRootConfigured: Bool) {
        let defaults = UserDefaults.standard
        if let savedProvider = defaults.string(forKey: Self.providerPreferenceKey)
            .flatMap(AgentProvider.init(rawValue:)) {
            provider = savedProvider
        } else {
            provider = app.settings.defaultProvider
        }
        cliPath = provider == .local ? "" : (defaults.string(forKey: Self.cliPathPreferenceKey(for: provider))
            ?? app.settings.binaryPath(for: provider)
            ?? "")
        let savedStep = defaults.string(forKey: Self.stepPreferenceKey)
            .flatMap(SetupWizardStep.init(rawValue:))
        profileName = defaults.string(forKey: Self.profileNamePreferenceKey) ?? ""
        currentStep = SetupWizardFlow.startingStep(
            savedStep: savedStep,
            workspaceRootConfigured: workspaceRootConfigured
        )
        let hasStarted = defaults.bool(forKey: Self.startedPreferenceKey)
        let hasCompleted = defaults.bool(forKey: Self.completedPreferenceKey)
        isPresented = SetupWizardFlow.shouldPresentAutomatically(
            workspaceRootConfigured: workspaceRootConfigured,
            hasStarted: hasStarted,
            hasCompleted: hasCompleted
        )
        if isPresented {
            defaults.set(true, forKey: Self.startedPreferenceKey)
            if let appError = app.errorMessage {
                errorMessage = appError
                app.errorMessage = nil
            }
        }
    }

    func open() {
        guard app.canPresentSetupWizard else { return }
        let hasCompleted = UserDefaults.standard.bool(forKey: Self.completedPreferenceKey)
        currentStep = SetupWizardFlow.reopeningStep(
            savedStep: currentStep,
            hasCompleted: hasCompleted,
            workspaceRootConfigured: app.workspaceRootIsConfigured
        )
        UserDefaults.standard.set(true, forKey: Self.startedPreferenceKey)
        cliPath = hasCompleted
            ? (app.settings.binaryPath(for: provider) ?? "")
            : (UserDefaults.standard.string(forKey: Self.cliPathPreferenceKey(for: provider))
                ?? app.settings.binaryPath(for: provider)
                ?? "")
        errorMessage = nil
        status = ""
        app.errorMessage = nil
        isPresented = true
    }

    func dismissForNow() {
        guard SetupWizardFlow.canDismiss(workspaceRootConfigured: app.workspaceRootIsConfigured),
              !app.isChangingWorkspaceRoot, !app.terminalRunning, app.terminalLaunch == nil,
              !app.hasActiveDiscussionOperation else { return }
        isPresented = false
        app.errorMessage = nil
    }

    func finish() {
        guard SetupWizardFlow.canDismiss(workspaceRootConfigured: app.workspaceRootIsConfigured),
              !app.isChangingWorkspaceRoot, !app.terminalRunning, app.terminalLaunch == nil,
              !app.hasActiveDiscussionOperation else { return }
        UserDefaults.standard.set(true, forKey: Self.completedPreferenceKey)
        currentStep = .welcome
        isPresented = false
        app.errorMessage = nil
    }

    func move(to step: SetupWizardStep) {
        guard !app.isChangingWorkspaceRoot else { return }
        if let currentIndex = SetupWizardStep.allCases.firstIndex(of: currentStep),
           let targetIndex = SetupWizardStep.allCases.firstIndex(of: step),
           targetIndex > currentIndex,
           !SetupWizardFlow.canAdvance(from: currentStep, workspaceRootConfigured: app.workspaceRootIsConfigured) {
            return
        }
        currentStep = step
        errorMessage = nil
        if step == .commandLine {
            if provider == .local {
                cliPath = ""
                cliStatus = ""
            } else {
                cliPath = UserDefaults.standard.string(forKey: Self.cliPathPreferenceKey(for: provider))
                    ?? app.settings.binaryPath(for: provider)
                    ?? ""
                checkCLIAvailability()
            }
        } else if step == .usage {
            loadUsageControls()
        }
    }

    func selectProvider(_ provider: AgentProvider) {
        guard self.provider != provider else { return }
        self.provider = provider
        cliPath = provider == .local ? "" : (UserDefaults.standard.string(forKey: Self.cliPathPreferenceKey(for: provider))
            ?? app.settings.binaryPath(for: provider)
            ?? "")
        cliStatus = ""
        usageStatus = ""
        if currentStep == .usage { loadUsageControls() }
    }

    func chooseCLIPath() {
        guard provider != .local else { return }
        let panel = NSOpenPanel()
        panel.title = app.localized("Choose the official CLI executable")
        panel.message = app.localized("Select the installed codex or claude executable. AgentBridge will only save this path.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        cliPath = url.path
        checkCLIAvailability()
    }

    func checkCLIAvailability() {
        guard provider != .local else {
            cliStatus = app.localized("Local models do not require a command-line app.")
            return
        }
        let path = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let executable = try RuntimeEnvironment.resolveExecutable(
                provider: provider,
                configuredPath: path.isEmpty ? nil : path
            )
            cliStatus = cliSettingIsDirty
                ? String(format: app.localized("Draft executable found: %@. Save this path before finishing setup."), executable.path)
                : String(format: app.localized("Found executable: %@"), executable.path)
        } catch {
            cliStatus = app.localized("CLI not found. Choose an executable or follow the official install guide.")
        }
    }

    func saveCLIPath() {
        guard provider != .local else {
            cliStatus = app.localized("Local models do not require a command-line app.")
            return
        }
        guard let service = app.service else {
            errorMessage = app.localized("Choose a workspace folder before saving CLI settings.")
            return
        }
        let path = cliPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty {
            do {
                _ = try RuntimeEnvironment.resolveExecutable(provider: provider, configuredPath: path)
            } catch {
                errorMessage = error.localizedDescription
                cliStatus = app.localized("The selected path is not an executable for this provider.")
                return
            }
        }
        let previousSettings = app.settings
        let previousPath = app.settings.binaryPath(for: provider)?.trimmingCharacters(in: .whitespacesAndNewlines)
        app.settings.setBinaryPath(path.isEmpty ? nil : path, for: provider)
        do {
            try service.saveSettings(app.settings)
            if previousPath != path {
                for profile in app.accountProfiles[provider] ?? [] {
                    app.authStatus.removeValue(forKey: profile.id)
                }
            }
            errorMessage = nil
            checkCLIAvailability()
            status = app.localized("CLI setting saved.")
        } catch {
            app.settings = previousSettings
            errorMessage = error.localizedDescription
        }
    }

    func selectDefaultProvider() {
        guard let service = app.service else {
            errorMessage = app.localized("Choose a workspace folder before saving provider settings.")
            return
        }
        let previous = app.settings
        app.settings.defaultProvider = provider
        if provider == .codex { app.settings.usageMode = .subscription }
        if provider == .local { app.requestedAccessMode = .readOnly }
        do {
            try service.saveSettings(app.settings)
            if previous.defaultProvider != app.settings.defaultProvider || previous.usageMode != app.settings.usageMode {
                app.clearAPIAuthorization()
            }
            app.providerUsageReport = nil
            app.usage.loadedUsageControlsScopeKey = nil
            app.refresh(forceUsageStatistics: true)
            if let anchor = app.selectedSession { app.selectOrCreateSession(for: provider, anchoredTo: anchor) }
            status = provider == .local
                ? app.localized("Local model is now the default. Cloud provider settings remain saved separately.")
                : app.settings.usageMode == .subscription
                    ? app.localized("Default provider and subscription sign-in saved.")
                    : app.localized("Default provider saved; the existing Claude API mode was preserved.")
            errorMessage = nil
        } catch {
            app.settings = previous
            errorMessage = error.localizedDescription
        }
    }

    func selectSubscriptionMode() {
        guard provider == .claude, app.settings.defaultProvider == .claude,
              app.settings.usageMode != .subscription else { return }
        app.selectUsageMode(.subscription)
    }

    func selectProfile(_ profileID: UUID) {
        guard let service = app.service, app.selectedProfileIDs[provider] != profileID else { return }
        do {
            try service.selectAccountProfile(id: profileID, provider: provider)
            app.selectedProfileIDs[provider] = profileID
            app.accountProfiles[provider] = try service.accountProfiles(provider: provider)
            app.usage.loadedUsageControlsScopeKey = nil
            app.providerUsageReport = nil
            app.authStatus.removeValue(forKey: profileID)
            status = provider == .local
                ? app.localized("Local memory account selected. No sign-in is needed.")
                : app.localized("Account selected. Sign-in remains managed by the provider CLI.")
            errorMessage = nil
            if app.settings.defaultProvider == provider, let anchor = app.selectedSession {
                app.selectOrCreateSession(for: provider, anchoredTo: anchor)
            }
            if currentStep == .usage { loadUsageControls() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createProfile(name: String) -> Bool {
        guard let service = app.service else {
            errorMessage = app.localized("Choose a workspace folder before creating an account.")
            return false
        }
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            errorMessage = app.localized("Enter a display name for the new account.")
            return false
        }
        do {
            let profile = try service.createAccountProfile(name: displayName, provider: provider, allowsSharedMemory: true)
            try service.selectAccountProfile(id: profile.id, provider: provider)
            app.selectedProfileIDs[provider] = profile.id
            app.accountProfiles[provider] = try service.accountProfiles(provider: provider)
            app.usage.loadedUsageControlsScopeKey = nil
            app.authStatus.removeValue(forKey: profile.id)
            profileName = ""
            status = provider == .local
                ? app.localized("Separate local memory account created. No sign-in is needed.")
                : app.localized("Isolated account created. Sign in when you are ready.")
            errorMessage = nil
            if app.settings.defaultProvider == provider, let anchor = app.selectedSession {
                app.selectOrCreateSession(for: provider, anchoredTo: anchor)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setMemorySharing(_ allowed: Bool) {
        guard let service = app.service, let profile = selectedProfile else { return }
        do {
            try service.setAccountSharedMemoryAllowed(id: profile.id, allowed: allowed)
            app.accountProfiles[provider] = try service.accountProfiles(provider: provider)
            if let session = app.selectedSession,
               (session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)) == profile.id {
                app.refreshSelectedEvents()
            }
            status = allowed
                ? app.localized("This account may load and save shared project memory.")
                : app.localized("This account will not load or save shared project memory.")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkAuthentication() {
        guard provider != .local else {
            status = app.localized("Local models do not use CLI sign-in.")
            return
        }
        guard let profile = selectedProfile else {
            errorMessage = app.localized("No account profile is available for this provider.")
            return
        }
        let profileID = profile.id
        let requestID = UUID()
        authRequestID = requestID
        authCheckInProgress = true
        status = app.localized("Checking official CLI sign-in…")
        app.checkAuthentication(for: profile) { [weak self] assessment, error in
            guard let self, self.authRequestID == requestID else { return }
            self.authCheckInProgress = false
            self.authRequestID = nil
            guard self.selectedProfile?.id == profileID else { return }
            if let assessment {
                self.status = assessment.message
                self.errorMessage = nil
            } else if let error {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func openProfileLogin() {
        guard provider != .local else {
            errorMessage = app.localized("Local models do not use CLI sign-in.")
            return
        }
        guard let profile = selectedProfile else {
            errorMessage = app.localized("No account profile is available for this provider.")
            return
        }
        app.openProfileLoginTerminal(for: profile)
    }

    func loadUsageControls() {
        usageControls = UsageControlSettings()
        if provider == .local {
            usageStatus = app.localized("Local models do not use subscription quota or API billing controls.")
            return
        }
        guard let service = app.service, let profile = selectedProfile else { return }
        do {
            usageControls = try service.usageControlSettings(provider: profile.provider, profileID: profile.id)
            usageStatus = ""
        } catch {
            usageStatus = error.localizedDescription
        }
    }

    func updateUsageControls(_ update: (inout UsageControlSettings) -> Void) {
        update(&usageControls)
    }

    func saveUsageControls() {
        guard provider != .local else {
            usageStatus = app.localized("Local models do not use subscription quota or API billing controls.")
            return
        }
        guard let service = app.service, let profile = selectedProfile else {
            usageStatus = app.localized("Choose a workspace folder before saving usage settings.")
            return
        }
        do {
            try service.saveUsageControlSettings(usageControls, provider: profile.provider, profileID: profile.id)
            usageStatus = app.localized("Local usage settings saved.")
            if app.settings.defaultProvider == profile.provider,
               app.selectedProfileIDs[profile.provider] == profile.id {
                app.usage.usageControls = usageControls
                app.usage.loadedUsageControlsScopeKey = "\(profile.provider.rawValue):\(profile.id.uuidString.lowercased())"
            }
        } catch {
            usageStatus = error.localizedDescription
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        guard let service = app.service, let profile = selectedProfile else { return }
        if !enabled {
            persistNotificationPreference(false, service: service, profile: profile)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.persistNotificationPreference(granted, service: service, profile: profile)
                if self.provider == profile.provider,
                   self.selectedProfile?.id == profile.id,
                   let error {
                    self.usageStatus = String(format: self.app.localized("Could not enable macOS notifications: %@"), error.localizedDescription)
                } else if self.provider == profile.provider,
                          self.selectedProfile?.id == profile.id,
                          !granted {
                    self.usageStatus = self.app.localized("macOS permission was not granted; in-app reminders still work.")
                }
            }
        }
    }

    private func persistNotificationPreference(_ enabled: Bool, service: BridgeService, profile: AccountProfile) {
        do {
            var updated = try service.usageControlSettings(provider: profile.provider, profileID: profile.id)
            updated.macOSNotificationsEnabled = enabled
            try service.saveUsageControlSettings(updated, provider: profile.provider, profileID: profile.id)
            if provider == profile.provider, selectedProfile?.id == profile.id {
                usageControls.macOSNotificationsEnabled = enabled
                usageStatus = enabled
                    ? app.localized("macOS usage notifications are enabled.")
                    : app.localized("macOS notifications are off; in-app reminders remain available.")
            }
            if app.settings.defaultProvider == profile.provider,
               app.selectedProfileIDs[profile.provider] == profile.id {
                app.usage.usageControls = updated
                app.usage.loadedUsageControlsScopeKey = "\(profile.provider.rawValue):\(profile.id.uuidString.lowercased())"
            }
        } catch {
            if provider == profile.provider, selectedProfile?.id == profile.id {
                usageStatus = error.localizedDescription
            }
        }
    }

    @ObservationIgnored private weak var owner: AppModel?

    private var app: AppModel {
        guard let owner else { preconditionFailure("SetupWizardModel outlived its AppModel.") }
        return owner
    }

    /// Connects the wizard to the model that owns it; called once from `AppModel.init`.
    func attach(to app: AppModel) {
        owner = app
    }
}
