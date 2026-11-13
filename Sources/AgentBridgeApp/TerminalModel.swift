import AgentBridgeCore
import Foundation
import Observation

/// The embedded terminal: native interactive sessions, profile sign-in, the
/// local shell, and the official `/usage` screen with its parsed report.
/// Launch specs are built here; `EmbeddedTerminalView` runs them.
@MainActor
@Observable
final class TerminalModel {
    static let didReturnToConversationNotification = Notification.Name("AgentBridgeTerminalDidReturnToConversation")

    var providerUsageReport: ProviderUsageReport?
    var terminalLaunch: TerminalLaunchSpec?
    var terminalTitle = ""
    var terminalRunning = false
    var terminalIsDetached = false
    var terminalIsProfileLogin = false
    var terminalIsUsageTUI = false
    var terminalNeedsManualStop = false
    var usageCommandRequest = 0
    var closeTerminalAfterCancellation = false
    /// The launch whose process the window controller actually started. A launch
    /// that never got a process must stay closable, so the manual-stop rule waits
    /// for this rather than for `terminalRunning` alone.
    private(set) var terminalProcessLaunchID: UUID?
    @ObservationIgnored let windowController = TerminalWindowController()
    private var activeTerminalProfileID: UUID?
    private var activeTerminalSessionID: UUID?
    private var activeUsageProvider: AgentProvider?
    private var conversationReturnSessionID: UUID?

    var terminalSessionIDForView: UUID? { activeTerminalSessionID }

    /// True only while a started process of the shown launch must be ended by the
    /// user first. Drives the close button, so it can never lock on a launch
    /// whose process failed to start or was never created.
    var closeRequiresManualStop: Bool {
        guard terminalRunning, terminalNeedsManualStop, let launchID = terminalLaunch?.id else { return false }
        return terminalProcessLaunchID == launchID
    }

    var closeButtonTitle: String {
        guard terminalRunning else { return "Close terminal" }
        if closeRequiresManualStop { return "End the CLI, then close" }
        // A manual-stop launch whose process has not started (or failed to start)
        // has nothing to end or cancel, so closing it is a plain close.
        return terminalNeedsManualStop ? "Close terminal" : "Cancel and close"
    }

    /// An earlier launch's process can outlive the model's view of it; starting
    /// another launch then would leave the panel without a terminal.
    private var terminalIsBusy: Bool {
        terminalRunning || windowController.hasRunningProcess
    }

    var canSendUsageCommand: Bool {
        terminalIsUsageTUI
            && terminalRunning
            && app.settings.usageMode == .subscription
            && activeTerminalProfileID == app.selectedProfileIDs[app.settings.defaultProvider]
    }

    func openEmbeddedInteractiveTerminal() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("The terminal is locked while an autonomous workflow is active.")
            return
        }
        guard let session = app.selectedSession, session.policy.accessMode == .interactiveManualApproval else {
            app.errorMessage = "Create a session with interactive manual approval first."
            return
        }
        guard !terminalIsBusy else {
            app.errorMessage = "Close the current app terminal first."
            return
        }
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        guard let cli = interactiveCLIURL() else {
            app.errorMessage = "The AgentBridge command-line helper was not found. Run scripts/package-app.sh to build the .app first."
            return
        }
        let spec = Self.interactiveLaunchSpec(
            title: "\(session.provider.rawValue.capitalized) · \(app.selectedSessionProfileName)",
            command: [cli.path, "interactive", session.id.uuidString.lowercased(), "--profile", profileID.uuidString.lowercased()],
            shellNotice: app.localized("The CLI ended. This shell runs in the session's isolated workspace; type exit to close it."),
            environment: sanitizedTerminalEnvironment(),
            workingDirectory: session.workspacePath
        )
        terminalIsProfileLogin = false
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        terminalTitle = spec.title
        activeTerminalProfileID = profileID
        activeTerminalSessionID = session.id
        conversationReturnSessionID = session.id
        terminalNeedsManualStop = false
        closeTerminalAfterCancellation = false
        terminalLaunch = spec
        terminalRunning = true
        app.status = "The interactive terminal opened in the app. Terminal text is not added to shared memory automatically."
    }

    func openSubscriptionUsageTUI() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("The terminal is locked while an autonomous workflow is active.")
            return
        }
        guard app.settings.usageMode == .subscription else {
            app.errorMessage = "The official usage TUI supports subscription sign-in only."
            return
        }
        guard terminalLaunch == nil, !terminalIsBusy else {
            app.errorMessage = "Close the current app terminal first."
            return
        }
        let provider = app.settings.defaultProvider
        guard provider != .local else {
            app.errorMessage = app.localized("Local models do not have a provider subscription usage screen.")
            return
        }
        guard let profileID = app.selectedProfileIDs[provider],
              let profile = app.accountProfiles[provider]?.first(where: { $0.id == profileID }) else {
            app.errorMessage = "The currently selected account settings could not be found."
            return
        }
        guard let spec = terminalLaunchSpec(
            title: "Official Usage · \(provider.rawValue.capitalized) · \(profile.name)",
            arguments: [
                "usage-tui",
                "--provider", provider.rawValue,
                "--profile", profile.id.uuidString.lowercased(),
                "--in-app"
            ],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ) else {
            app.errorMessage = "The AgentBridge command-line helper was not found. Run scripts/package-app.sh to build the .app first."
            return
        }
        terminalIsProfileLogin = false
        terminalIsUsageTUI = true
        activeUsageProvider = provider
        providerUsageReport = nil
        terminalTitle = spec.title
        activeTerminalProfileID = profile.id
        activeTerminalSessionID = nil
        conversationReturnSessionID = app.selectedSessionID
        terminalNeedsManualStop = true
        closeTerminalAfterCancellation = false
        usageCommandRequest = 0
        terminalLaunch = spec
        terminalRunning = true
        app.status = "The official CLI usage terminal opened for the selected account. Wait for the input prompt and finish signing in before sending /usage."
    }

    func requestUsageCommand() {
        guard canSendUsageCommand else { return }
        usageCommandRequest &+= 1
        app.status = "The fixed /usage command was sent to the current official CLI terminal."
    }

    func usageScreenDidUpdate(_ screenText: String, capturedAt: Date, launchID: UUID) -> Bool {
        guard terminalLaunch?.id == launchID,
              terminalIsUsageTUI,
              let provider = activeUsageProvider,
              app.settings.defaultProvider == provider,
              app.settings.usageMode == .subscription,
              let profileID = activeTerminalProfileID,
              app.selectedProfileIDs[provider] == profileID,
              let profile = app.accountProfiles[provider]?.first(where: { $0.id == profileID }) else { return false }
        let report = ProviderUsageReportParser.parse(
            screenText: screenText,
            provider: provider,
            accountProfileID: profileID,
            accountName: profile.name,
            capturedAt: capturedAt
        )
        providerUsageReport = report
        let recognized = report.usageWindows.contains { $0.percentageUsed != nil || $0.resetText != nil }
        if recognized { try? app.service?.saveProviderUsageReport(report) }
        return recognized
    }

    /// Shows a saved report for the selected account when it is newer than the one
    /// on the card, such as one `agentbridge usage-tui` read in the user's own terminal.
    func adoptSavedUsageReports(_ reports: [ProviderUsageReport]) {
        let provider = app.settings.defaultProvider
        guard let profileID = app.selectedProfileIDs[provider],
              let saved = reports.first(where: { $0.provider == provider && $0.accountProfileID == profileID }) else { return }
        if let current = providerUsageReport,
           current.provider == provider,
           current.accountProfileID == profileID,
           current.capturedAt >= saved.capturedAt {
            return
        }
        providerUsageReport = saved
    }

    func openProfileLoginTerminal() {
        guard let profile = app.selectedAccountProfile else { app.errorMessage = "The selected account settings could not be found."; return }
        openProfileLoginTerminal(for: profile)
    }

    func openProfileLoginTerminal(for profile: AccountProfile) {
        guard profile.provider != .local else {
            app.reportOperationError(app.localized("Local models do not use CLI sign-in."))
            return
        }
        guard !app.hasActiveAutonomousWorkflow else {
            app.reportOperationError(app.localized("The terminal is locked while an autonomous workflow is active."))
            return
        }
        guard !terminalIsBusy else {
            app.reportOperationError(app.localized("Close the current terminal before opening sign-in."))
            return
        }
        guard !profile.usesExistingLogin else {
            app.reportOperationError(app.localized("This built-in account keeps its existing CLI login. Add an isolated account to sign in separately."))
            return
        }
        guard let spec = terminalLaunchSpec(
            title: "Sign In · \(profile.provider.rawValue.capitalized) · \(profile.name)",
            arguments: ["profile-login", profile.id.uuidString.lowercased()],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ) else {
            app.reportOperationError("The AgentBridge command-line helper was not found. Run scripts/package-app.sh to build the .app first.")
            return
        }
        terminalIsProfileLogin = true
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        terminalTitle = spec.title
        activeTerminalProfileID = profile.id
        activeTerminalSessionID = nil
        conversationReturnSessionID = app.selectedSessionID
        terminalNeedsManualStop = true
        closeTerminalAfterCancellation = false
        terminalLaunch = spec
        terminalRunning = true
        app.status = "The official CLI sign-in flow opened in the app. Complete sign-in in the terminal."
        app.setupWizard.errorMessage = nil
    }

    func openLocalShell() {
        guard let session = app.selectedSession else { app.errorMessage = "Select a session first."; return }
        guard terminalLaunch == nil, !terminalIsBusy else { app.errorMessage = "Close the current app terminal first."; return }
        let spec = TerminalLaunchSpec(
            title: Self.localShellTitle(for: session),
            executablePath: "/bin/sh",
            // An interactive POSIX sh reads only $ENV as a startup file, and the
            // sanitized environment has none, so no rc file runs. Filename
            // expansion stays on (no -f), as users expect in a shell.
            arguments: [],
            environment: sanitizedTerminalEnvironment(),
            workingDirectory: session.workspacePath
        )
        terminalIsProfileLogin = false
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        terminalNeedsManualStop = true
        activeTerminalProfileID = nil
        activeTerminalSessionID = nil
        conversationReturnSessionID = session.id
        closeTerminalAfterCancellation = false
        terminalTitle = spec.title
        terminalLaunch = spec
        terminalRunning = true
        app.status = "The local shell opened in the isolated workspace. Shell commands still run with your current user permissions."
    }

    func closeEmbeddedTerminal() {
        let closingLaunchID = terminalLaunch?.id
        // A process still running for another launch must stay reachable: show it
        // again instead of closing into a state where nothing can stop it.
        if let runningLaunch = windowController.runningLaunch, runningLaunch.id != closingLaunchID {
            showRunningLaunch(runningLaunch)
            return
        }
        if terminalRunning {
            if let closingLaunchID, windowController.hasRunningProcess(for: closingLaunchID) {
                if terminalNeedsManualStop {
                    app.status = "Press Control-C in the terminal to end the current process before closing the terminal panel."
                    return
                }
                guard let sessionID = activeTerminalSessionID else {
                    app.status = "Finish the terminal task before closing the panel."
                    return
                }
                closeTerminalAfterCancellation = true
                app.cancelSession(sessionID)
                return
            }
            // Nothing runs for this launch: it never started, failed to start, or its
            // exit has not been delivered yet. Finish it here so the panel can close.
            if let closingLaunchID {
                terminalDidTerminate(launchID: closingLaunchID, exitCode: nil)
            } else {
                terminalRunning = false
            }
        }
        if windowController.hasRunningProcess {
            app.status = "Wait for the terminal process to stop before closing the terminal."
            return
        }
        windowController.discardTerminal(launchID: closingLaunchID)
        terminalIsDetached = false
        terminalLaunch = nil
        conversationReturnSessionID = nil
        terminalRunning = false
        terminalProcessLaunchID = nil
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        activeTerminalProfileID = nil
        activeTerminalSessionID = nil
        terminalNeedsManualStop = false
        closeTerminalAfterCancellation = false
        app.status = "The in-app terminal closed."
    }

    /// Called by the window controller once the launch's process exists.
    func terminalProcessDidStart(launchID: UUID) {
        guard terminalLaunch?.id == launchID else { return }
        terminalProcessLaunchID = launchID
    }

    /// SwiftTerm reports nothing when it cannot create the pseudo-terminal or
    /// child, so the controller calls this; without it the panel waits forever.
    func terminalDidFailToStart(launchID: UUID) {
        guard terminalLaunch?.id == launchID else { return }
        terminalDidTerminate(launchID: launchID, exitCode: nil)
        reportTerminalProblem("The in-app terminal could not start. Close the panel and try again.")
    }

    /// The controller refused `refusedLaunchID` because an earlier launch's process
    /// still runs. That process is never killed implicitly, so it is shown again.
    func terminalLaunchWasRefused(_ refusedLaunchID: UUID, runningLaunch: TerminalLaunchSpec) {
        guard terminalLaunch == nil || terminalLaunch?.id == refusedLaunchID else { return }
        showRunningLaunch(runningLaunch)
    }

    /// Points the model back at a launch whose process is still running. Its
    /// session and account context is no longer known, so it gets the
    /// conservative local-shell rules: the user ends it before closing, and no
    /// /usage command or screen capture is allowed.
    private func showRunningLaunch(_ launch: TerminalLaunchSpec) {
        terminalLaunch = launch
        terminalTitle = launch.title
        terminalRunning = true
        terminalProcessLaunchID = launch.id
        terminalNeedsManualStop = true
        terminalIsProfileLogin = false
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        activeTerminalProfileID = nil
        activeTerminalSessionID = nil
        closeTerminalAfterCancellation = false
        reportTerminalProblem("An earlier terminal process is still running, so it is shown again. End it before opening another terminal.")
    }

    /// Puts `message` in the status line, which is localized when shown, and
    /// reports it as an error, as the open functions report a busy terminal. The
    /// error also reaches the setup wizard, which does not show the status line.
    private func reportTerminalProblem(_ message: String) {
        app.status = message
        app.reportOperationError(app.localized(message))
    }

    func openTerminalInWindow() {
        guard terminalLaunch != nil else { return }
        windowController.openWindow()
    }

    func returnTerminalToConversation() {
        guard terminalIsDetached else { return }
        windowController.returnToConversation()
        finishReturningToConversation()
    }

    func detachedWindowDidClose() {
        finishReturningToConversation()
    }

    private func finishReturningToConversation() {
        terminalIsDetached = false
        if let sessionID = conversationReturnSessionID,
           app.sessions.contains(where: { $0.id == sessionID }) {
            app.openProjectSession(sessionID)
        } else {
            app.chats.selectedDiscussionID = nil
            app.isProjectConversationActive = app.selectedSession != nil
        }
        app.status = "The terminal returned to the conversation window."
        NotificationCenter.default.post(name: Self.didReturnToConversationNotification, object: self)
    }

    func terminalDidTerminate(launchID: UUID, exitCode: Int32?) {
        guard terminalLaunch?.id == launchID else { return }
        terminalRunning = false
        terminalProcessLaunchID = nil
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        if let exitCode, exitCode == 0 {
            app.status = "The terminal task completed."
        } else {
            app.status = "Terminal task ended\(exitCode.map { " (exit code \($0))" } ?? "")."
        }
        if terminalIsProfileLogin, let profileID = activeTerminalProfileID,
           let profile = app.accountProfiles.values.flatMap({ $0 }).first(where: { $0.id == profileID }) {
            app.checkAuthentication(for: profile)
        }
        app.refresh(forceUsageStatistics: true)
        if closeTerminalAfterCancellation {
            windowController.discardTerminal(launchID: launchID)
            terminalIsDetached = false
            terminalLaunch = nil
            closeTerminalAfterCancellation = false
            activeTerminalProfileID = nil
            activeTerminalSessionID = nil
            conversationReturnSessionID = nil
        }
    }

    /// Runs `command`, the provider CLI through the AgentBridge helper, and when
    /// it ends normally keeps the terminal open as a shell in the same workspace,
    /// with the CLI's last screen still above it. Before the shell starts, the
    /// wrapper sets the terminal title to a marker made for this launch, which
    /// tells the app the CLI has ended. A cancelled or failed run (non-zero exit)
    /// ends the terminal as before, so its error stays on screen and a cancelling
    /// close still closes.
    ///
    /// Everything reaches the shell as positional arguments, never inside the
    /// script, so paths need no quoting.
    ///
    /// The CLI runs as a child of the wrapper in the same process group (the
    /// wrapper leads the terminal's session and, not being interactive, makes no
    /// job-control groups), so ending the terminal signals both. A cancelled
    /// helper exits non-zero, so a cancel never hands over to a shell.
    ///
    /// The marker is visible in the wrapper's arguments, so a same-user process
    /// could forge it; that only switches the panel to the local-shell rules.
    static func interactiveLaunchSpec(
        title: String,
        command: [String],
        shellNotice: String,
        environment: [String: String],
        workingDirectory: String
    ) -> TerminalLaunchSpec {
        let marker = "agentbridge-shell-\(UUID().uuidString.lowercased())"
        // `"$@" || exit $?` passes a failing or cancelled CLI's status on to
        // `terminalDidTerminate`. `\033]0;…\007` is the OSC sequence that sets the
        // terminal title (backslashes doubled for Swift). The shell is the same
        // as the local shell's; see `openLocalShell`.
        let script = """
        marker=$1; notice=$2; shift 2
        "$@" || exit $?
        printf '\\033]0;%s\\007\\n%s\\n\\n' "$marker" "$notice"
        exec /bin/sh
        """
        return TerminalLaunchSpec(
            title: title,
            executablePath: "/bin/sh",
            arguments: ["-c", script, "agentbridge-terminal", marker, shellNotice] + command,
            environment: environment,
            workingDirectory: workingDirectory,
            shellHandoffMarker: marker
        )
    }

    /// The provider CLI of `launchID` ended normally and its terminal is now a
    /// shell. Closing it is then like closing the local shell: the user ends the
    /// shell first, and nothing is cancelled, because no run is active.
    ///
    /// If the user asked to close the panel while cancelling and the CLI still
    /// ended normally, the shell is ended too, so the panel closes as asked.
    func interactiveCLIDidHandOverToShell(launchID: UUID) {
        guard terminalLaunch?.id == launchID, terminalRunning, shellHandoffLaunchID != launchID else { return }
        shellHandoffLaunchID = launchID
        if closeTerminalAfterCancellation {
            windowController.terminateProcess(for: launchID)
            return
        }
        if let sessionID = activeTerminalSessionID,
           let session = app.sessions.first(where: { $0.id == sessionID }) {
            terminalTitle = Self.localShellTitle(for: session)
        }
        activeTerminalSessionID = nil
        activeTerminalProfileID = nil
        terminalNeedsManualStop = true
        closeTerminalAfterCancellation = false
        app.status = "The CLI ended. A shell opened in the same isolated workspace."
        app.refresh(forceUsageStatistics: true)
    }

    /// The shell runs in the session's isolated copy, not in the source
    /// repository the name comes from, so the title says so.
    static func localShellTitle(for session: SessionRecord) -> String {
        "Local Terminal · isolated copy of \(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent)"
    }

    /// The launch whose CLI already handed over to a shell, so a repeated
    /// marker does not reset the panel again.
    @ObservationIgnored private var shellHandoffLaunchID: UUID?

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

    @ObservationIgnored private weak var owner: AppModel?

    private var app: AppModel {
        guard let owner else { preconditionFailure("TerminalModel outlived its AppModel.") }
        return owner
    }

    /// Connects this model to the `AppModel` that owns it; called once from `AppModel.init`.
    func attach(to app: AppModel) {
        owner = app
        windowController.attach(terminalModel: self, appModel: app)
    }
}
