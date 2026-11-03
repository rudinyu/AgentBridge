import AgentBridgeCore
import SwiftUI

struct SetupWizardView: View {
    @ObservedObject var model: AppModel

    private var stepIndex: Int { SetupWizardStep.allCases.firstIndex(of: model.setupWizardStep) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(26)
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(!model.workspaceRootIsConfigured || model.isChangingWorkspaceRoot || model.terminalLaunch != nil)
        .sheet(item: Binding(
            get: { model.terminalLaunch },
            set: { if $0 == nil { model.closeEmbeddedTerminal() } }
        )) { launch in
            EmbeddedTerminalPanel(model: model, launch: launch)
                .padding(14)
                .frame(minWidth: 720, minHeight: 390)
                .interactiveDismissDisabled(model.terminalRunning)
        }
        .onAppear {
            if model.setupWizardStep == .commandLine && model.setupWizardProvider != .local { model.checkSetupWizardCLIAvailability() }
            if model.setupWizardStep == .usage { model.loadSetupWizardUsageControls() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "slider.horizontal.3")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.localized("Setup Wizard"))
                    .font(.headline)
                Text(String(format: model.localized("Step %d of %d · %@"), stepIndex + 1, SetupWizardStep.allCases.count, model.localized(stepTitle)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: Double(stepIndex + 1), total: Double(SetupWizardStep.allCases.count))
                    .frame(width: 250)
            }
            Spacer()
            Picker(model.localized("Language"), selection: $model.appLanguage) {
                Text("English").tag(AppLanguage.english)
                Text("繁體中文").tag(AppLanguage.traditionalChinese)
            }
            .pickerStyle(.menu)
            if model.workspaceRootIsConfigured {
                Button(model.localized("Close for now")) { model.dismissSetupWizardForNow() }
                    .disabled(model.isChangingWorkspaceRoot || model.terminalLaunch != nil)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var stepTitle: String {
        switch model.setupWizardStep {
        case .welcome: "Welcome"
        case .workspace: "Workspace folder"
        case .commandLine: model.setupWizardProvider == .local ? "Local model" : "CLI"
        case .account: "Account and memory"
        case .usage: "Usage settings"
        case .review: "Review"
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.setupWizardStep {
        case .welcome: welcomeStep
        case .workspace: workspaceStep
        case .commandLine: commandLineStep
        case .account: accountStep
        case .usage: usageStep
        case .review: reviewStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.localized("Set up AgentBridge"))
                .font(.largeTitle.weight(.semibold))
            Text(model.localized("Choose a provider and review the local settings AgentBridge needs. The wizard will not install software, store provider passwords, enable paid API calls, or send a model request."))
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox(model.localized("Provider for this setup")) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker(model.localized("Provider"), selection: Binding(
                        get: { model.setupWizardProvider },
                        set: { model.selectSetupWizardProvider($0) }
                    )) {
                        Text("Codex").tag(AgentProvider.codex)
                        Text("Claude").tag(AgentProvider.claude)
                        Text("Local").tag(AgentProvider.local)
                    }
                    .pickerStyle(.segmented)
                    Text(model.localized("This choice is a draft. The app's default provider changes only after you explicitly save it in Usage settings."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Label(model.localized("Official CLI subscription login is the default setup path. Codex is subscription-only."), systemImage: "checkmark.shield")
            if model.setupWizardProvider == .claude {
                Label(model.localized("Claude API setup is not part of this wizard. Existing usage settings stay unchanged unless you explicitly switch them."), systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            }
            if let url = officialQuickStartURL {
                Link(model.localized("Open the official CLI install and sign-in guide"), destination: url)
            }
        }
    }

    private var workspaceStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.localized("Choose a workspace data folder"))
                .font(.largeTitle.weight(.semibold))
            Text(model.localized("This folder stores isolated session workspaces and shared project memory. Private settings, account profiles, and usage records stay in Application Support."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox(model.localized("Required before continuing")) {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.workspaceRootIsConfigured {
                        Label(model.localized("No usable workspace folder is configured."), systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                        if !model.workspaceRootPath.isEmpty {
                            Text(model.workspaceRootPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else {
                        Label(model.localized("Current data folder"), systemImage: "folder")
                            .font(.caption.weight(.semibold))
                        Text(model.workspaceRootPath)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                    Button(model.localized(model.workspaceRootPath.isEmpty ? "Choose or create a folder…" : "Change folder…")) {
                        model.chooseWorkspaceRoot()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isChangingWorkspaceRoot || model.terminalRunning)
                    if model.isChangingWorkspaceRoot {
                        ProgressView(model.localized("Preparing the folder and preserving existing workspace data…"))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
            }
            Text(model.localized("Changing folders copies managed workspaces and shared memory. The old data stays in its original location."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var commandLineStep: some View {
        if model.setupWizardProvider == .local {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.localized("Configure a local model"))
                    .font(.largeTitle.weight(.semibold))
                Text(model.localized("Choose Ollama or an OpenAI-compatible local server. AgentBridge will not install software, start a service, download a model, or contact the endpoint until you select a test or model-list action."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LocalModelSettingsSection(model: model)
            }
        } else {
            cloudCommandLineStep
        }
    }

    private var cloudCommandLineStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(format: model.localized("Set up the %@ CLI"), model.setupWizardProvider.rawValue.capitalized))
                .font(.largeTitle.weight(.semibold))
            Text(model.localized("AgentBridge uses the provider's official command-line app and its own sign-in flow. It never installs or updates the CLI for you."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox(model.localized("Executable path")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField(model.localized("Leave blank to search the standard install locations"), text: $model.setupWizardCLIPath)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: model.setupWizardCLIPath) { _, _ in model.checkSetupWizardCLIAvailability() }
                        Button(model.localized("Choose…")) { model.chooseSetupWizardCLIPath() }
                    }
                    HStack(spacing: 8) {
                        Button(model.localized("Check path")) { model.checkSetupWizardCLIAvailability() }
                        Button(model.localized("Save CLI path")) { model.saveSetupWizardCLIPath() }
                            .buttonStyle(.borderedProminent)
                    }
                    if !model.setupWizardCLIStatus.isEmpty {
                        Label(model.localized(model.setupWizardCLIStatus), systemImage: model.setupWizardResolvedCLIPath == nil ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.callout)
                            .foregroundStyle(model.setupWizardResolvedCLIPath == nil ? .orange : .secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.vertical, 4)
            }
            HStack(spacing: 16) {
                if let url = officialQuickStartURL {
                    Link(model.localized("Official installation and sign-in instructions"), destination: url)
                }
                if let url = officialAuthenticationURL {
                    Link(model.localized("Authentication help"), destination: url)
                }
            }
            Label(model.localized("Saving a path changes only AgentBridge settings; it does not run the provider or contact a model."), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.localized(model.setupWizardProvider == .local
                ? "Choose a local account and review memory consent"
                : "Choose an account and review memory consent"))
                .font(.largeTitle.weight(.semibold))
            Text(model.localized(model.setupWizardProvider == .local
                ? "This local account only scopes memory consent. It has no provider login, credential folder, subscription, or API billing."
                : "Provider credentials remain in the official CLI's existing login or a separate account profile. Built-in login details are never copied or replaced."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox(model.localized(model.setupWizardProvider == .local ? "Local memory account" : "Official CLI account")) {
                VStack(alignment: .leading, spacing: 12) {
                    let profiles = model.accountProfiles[model.setupWizardProvider] ?? []
                    if profiles.isEmpty {
                        Text(model.localized("Choose a workspace folder to load account profiles."))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(model.localized("Selected account"), selection: Binding<UUID?>(
                            get: { model.setupWizardSelectedProfile?.id },
                            set: { if let id = $0 { model.selectSetupWizardProfile(id) } }
                        )) {
                            ForEach(profiles) { profile in
                                Text(profile.name).tag(Optional(profile.id))
                            }
                        }

                        if let profile = model.setupWizardSelectedProfile {
                            if model.setupWizardProvider == .local {
                                Label(model.localized("Local account selected. No sign-in check is needed."), systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            } else {
                                if let assessment = model.setupWizardAuthentication {
                                    Label(model.localized(assessment.message), systemImage: assessment.confirmedSubscription ? "checkmark.seal" : "exclamationmark.shield")
                                        .foregroundStyle(assessment.confirmedSubscription ? Color.secondary : Color.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    Label(model.localized("Sign-in has not been checked yet."), systemImage: "questionmark.circle")
                                        .foregroundStyle(.secondary)
                                }
                                HStack(spacing: 10) {
                                    Button(model.localized("Check subscription sign-in")) { model.checkSetupWizardAuthentication() }
                                        .disabled(model.setupWizardAuthCheckInProgress || model.setupWizardSavedCLIPath == nil || model.setupWizardCLISettingIsDirty)
                                    if !profile.usesExistingLogin {
                                        Button(model.localized("Open sign-in in AgentBridge")) { model.openSetupWizardProfileLogin() }
                                            .disabled(model.terminalRunning || model.setupWizardSavedCLIPath == nil || model.setupWizardCLISettingIsDirty)
                                    }
                                }
                                if profile.usesExistingLogin {
                                    Text(model.localized("This account keeps its current CLI login. To sign in as a different account, add an isolated profile below."))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Toggle(model.localized("Allow this account to load and save shared project memory"), isOn: Binding(
                                get: { model.setupWizardSelectedProfile?.allowsSharedMemory ?? false },
                                set: { model.setSetupWizardMemorySharing($0) }
                            ))
                            .disabled(model.setupWizardSelectedProfile == nil)
                            Text(model.localized("Existing memory choices are preserved. New isolated accounts start with sharing enabled and can be changed here."))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox(model.localized(model.setupWizardProvider == .local
                ? "Add a separate local memory account"
                : "Add a separate account")) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField(model.localized("Display name"), text: $model.setupWizardProfileName)
                        Button(model.localized(model.setupWizardProvider == .local ? "Add local memory account" : "Add isolated account")) {
                            _ = model.createSetupWizardProfile(name: model.setupWizardProfileName)
                        }
                        .disabled(model.setupWizardProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text(model.localized(model.setupWizardProvider == .local
                        ? "The new local account has its own memory-consent setting. It does not create a credential folder or start a sign-in flow."
                        : "The new profile uses a separate CLI configuration folder and starts with shared memory enabled. Sign-in starts only when you press the button above for that profile."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var usageStep: some View {
        if model.setupWizardProvider == .local {
            localUsageStep
        } else {
            cloudUsageStep
        }
    }

    private var localUsageStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.localized("Local model settings"))
                .font(.largeTitle.weight(.semibold))
            Label(model.localized("Local models do not have provider subscription quotas or API billing. Cloud usage settings stay saved separately."), systemImage: "desktopcomputer")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LocalModelSettingsSection(model: model)
        }
    }

    private var cloudUsageStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.localized("Subscription defaults and local limits"))
                .font(.largeTitle.weight(.semibold))
            Label(model.localized("Local counts include only AgentBridge-managed runs; they are not provider quota."), systemImage: "chart.bar")
                .foregroundStyle(.secondary)
            GroupBox(model.localized("Default for new sessions")) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(String(format: model.localized("Current app default: %@"), model.settings.defaultProvider.rawValue.capitalized))
                    if model.setupWizardProvider == .codex {
                        Text(model.localized("Codex uses official CLI subscription sign-in."))
                            .foregroundStyle(.secondary)
                    } else if model.settings.defaultProvider == .claude && model.settings.usageMode == .api {
                        Text(model.localized("Current Claude mode: API"))
                            .foregroundStyle(.orange)
                    } else {
                        Text(model.localized("Claude uses official CLI subscription sign-in by default."))
                            .foregroundStyle(.secondary)
                    }
                    if model.settings.defaultProvider != model.setupWizardProvider {
                        if model.settings.usageMode == .api && model.setupWizardProvider == .codex {
                            Label(model.localized("Saving this provider as the default also sets new sessions to subscription mode. Existing sessions keep their saved provider settings."), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(String(format: model.localized("Save %@ as the default subscription provider"), model.setupWizardProvider.rawValue.capitalized)) {
                            model.selectSetupWizardDefaultProvider()
                        }
                        .buttonStyle(.borderedProminent)
                    } else if model.setupWizardProvider == .claude && model.settings.usageMode == .api {
                        Label(model.localized("Claude API is already selected. This wizard will not change that mode, enter an API key, or send a paid request."), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(model.localized("Use subscription sign-in for new Claude sessions")) {
                            model.selectSetupWizardSubscriptionMode()
                        }
                    } else {
                        Label(model.localized("New sessions use official CLI subscription sign-in by default."), systemImage: "checkmark.shield")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox(model.localized("Optional local subscription run caps")) {
                VStack(alignment: .leading, spacing: 10) {
                    usageLimitRow(model.localized("Runs in rolling 5 hours"), keyPath: \.subscriptionFiveHourRunLimit)
                    usageLimitRow(model.localized("Runs in rolling 24 hours"), keyPath: \.subscriptionDailyRunLimit)
                    usageLimitRow(model.localized("Runs in rolling 7 days"), keyPath: \.subscriptionWeeklyRunLimit)
                    usageLimitRow(model.localized("Runs in current AgentBridge session"), keyPath: \.subscriptionSessionRunLimit)
                    Toggle(model.localized("Request macOS threshold notifications"), isOn: Binding(
                        get: { model.setupWizardUsageControls.macOSNotificationsEnabled },
                        set: { model.setSetupWizardNotificationsEnabled($0) }
                    ))
                    Text(model.localized("A missing cap means unlimited. Turning on macOS notifications asks for permission only after you enable this toggle; in-app reminders remain available."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(model.localized("Save local usage settings")) { model.saveSetupWizardUsageControls() }
                        .buttonStyle(.borderedProminent)
                    if !model.setupWizardUsageStatus.isEmpty {
                        Text(model.localized(model.setupWizardUsageStatus))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.localized("Review setup"))
                .font(.largeTitle.weight(.semibold))
            Text(model.localized(model.setupWizardProvider == .local
                ? "Saving settings does not contact a model. Connection checks run only after you select Test connection."
                : "Saving account or default settings can prepare a local session; this does not run the provider or send a model request. Sign-in and status checks start the official CLI only after you click them."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            GroupBox(model.localized("Readiness for the selected provider")) {
                VStack(alignment: .leading, spacing: 12) {
                    readinessRow(
                        model.localized("Workspace folder"),
                        complete: model.setupWizardReadiness.workspaceConfigured,
                        detail: model.workspaceRootPath.isEmpty ? model.localized("Required. Choose a usable data folder.") : model.workspaceRootPath
                    )
                    if model.setupWizardProvider == .local {
                        let local = model.settings.localModel
                        let isConfigured = !local.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && !model.localModelSettingsAreDirty
                        readinessRow(
                            model.localized("Local model configuration"),
                            complete: isConfigured,
                            detail: isConfigured
                                ? "\(local.backend.rawValue) · \(local.model) · \(local.endpoint)"
                                : model.localized("Choose a model, save the settings, and test the connection when your local service is ready.")
                        )
                        Label(model.localized("No CLI sign-in is required. Connection status is not checked automatically."), systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        readinessRow(
                            model.localized("Official CLI"),
                            complete: model.setupWizardReadiness.commandLineAvailable && !model.setupWizardCLISettingIsDirty,
                            detail: model.setupWizardCLISettingIsDirty
                                ? model.localized("The CLI path has edits that are not saved yet.")
                                : (model.setupWizardSavedCLIPath ?? model.localized("Not found. Install the official CLI or save its executable path."))
                        )
                        readinessRow(
                            model.localized("Subscription sign-in"),
                            complete: model.setupWizardAuthentication?.confirmedSubscription == true,
                            detail: model.setupWizardAuthentication.map { model.localized($0.message) }
                                ?? model.localized("Not checked. Check sign-in in the Account step.")
                        )
                        if model.setupWizardReadiness.subscriptionSetupReady {
                            Label(model.localized("Setup requirements are confirmed."), systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label(model.localized("Subscription setup is incomplete. Finish now and complete CLI sign-in later."), systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            if model.setupWizardProvider == .claude,
               model.settings.defaultProvider == .claude,
               model.settings.usageMode == .api {
                Label(model.localized("Existing Claude API settings are preserved. This review did not enable a key or make a paid request."), systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let url = officialAuthenticationURL {
                Link(model.localized("Open official authentication instructions"), destination: url)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.setupWizardError, !error.isEmpty {
                Label(model.localized(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.setupWizardStatus.isEmpty {
                Text(model.localized(model.setupWizardStatus))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if let previous = model.setupWizardStep.previous {
                    Button(model.localized("Back")) { model.moveSetupWizard(to: previous) }
                        .disabled(model.isChangingWorkspaceRoot)
                }
                Spacer()
                if let next = model.setupWizardStep.next {
                    Button(model.localized("Continue")) { model.moveSetupWizard(to: next) }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isChangingWorkspaceRoot || !SetupWizardFlow.canAdvance(
                            from: model.setupWizardStep,
                            workspaceRootConfigured: model.workspaceRootIsConfigured
                        ))
                } else {
                    Button(model.localized("Finish setup")) { model.finishSetupWizard() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.workspaceRootIsConfigured || model.isChangingWorkspaceRoot || model.terminalLaunch != nil)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var officialQuickStartURL: URL? {
        guard model.setupWizardProvider != .local else { return nil }
        return URL(string: model.setupWizardProvider == .codex
            ? "https://developers.openai.com/codex/cli"
            : "https://code.claude.com/docs/en/quickstart")
    }

    private var officialAuthenticationURL: URL? {
        guard model.setupWizardProvider != .local else { return nil }
        return URL(string: model.setupWizardProvider == .codex
            ? "https://developers.openai.com/codex/auth"
            : "https://code.claude.com/docs/en/authentication")
    }

    private func usageLimitRow(_ title: String, keyPath: WritableKeyPath<UsageControlSettings, Int?>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(model.localized("0 = unlimited"), value: usageLimitBinding(keyPath), format: .number)
                .frame(width: 110)
        }
    }

    private func usageLimitBinding(_ keyPath: WritableKeyPath<UsageControlSettings, Int?>) -> Binding<Int> {
        Binding(
            get: { model.setupWizardUsageControls[keyPath: keyPath] ?? 0 },
            set: { value in
                model.updateSetupWizardUsageControls { controls in
                    controls[keyPath: keyPath] = value == 0 ? nil : value
                }
            }
        )
    }

    private func readinessRow(_ title: String, complete: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(complete ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct EmbeddedTerminalPanel: View {
    @ObservedObject var model: AppModel
    let launch: TerminalLaunchSpec

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(model.localized(launch.title)).font(.subheadline.weight(.semibold))
                if model.terminalRunning { ProgressView().controlSize(.small) }
                Spacer()
                if model.terminalRunning && !model.terminalIsProfileLogin,
                   let sessionID = model.terminalSessionIDForView {
                    Button(model.localized("Cancel session")) { model.cancelSession(sessionID) }
                }
                if model.canSendUsageCommand {
                    Button(model.localized("Send /usage")) { model.requestUsageCommand() }
                        .help(model.localized("Only the fixed /usage command and Enter are sent after the CLI is ready."))
                }
                Button(model.localized(model.terminalRunning ? (model.terminalNeedsManualStop ? "End the CLI, then close" : "Cancel and close") : "Close terminal")) {
                    model.closeEmbeddedTerminal()
                }
                .disabled(model.terminalRunning && model.terminalNeedsManualStop)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            EmbeddedTerminalView(
                launch: launch,
                usageCommandRequest: model.usageCommandRequest,
                allowsUsageScreenCapture: model.terminalIsUsageTUI,
                onUsageScreenText: { screenText, capturedAt in
                    model.usageScreenDidUpdate(screenText, capturedAt: capturedAt)
                },
                onTermination: { exitCode in model.terminalDidTerminate(exitCode: exitCode) }
            )
            .id(launch.id)
            .frame(minHeight: 210, maxHeight: 340)
            if model.terminalIsUsageTUI && model.terminalRunning {
                Text(model.localized("Wait for the official CLI prompt and sign-in before sending /usage."))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Text(model.localized("Terminal output stays in this screen's memory; AgentBridge does not add TUI transcripts to chat memory or audit records."))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            if model.terminalSessionIDForView == nil && !model.terminalIsProfileLogin {
                Text(model.localized("A local shell runs with your macOS account permissions."))
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
    }
}
