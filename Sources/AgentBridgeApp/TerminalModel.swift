import AgentBridgeCore
import Foundation
import Observation

/// The embedded terminal: native interactive sessions, profile sign-in, the
/// local shell, and the official `/usage` screen with its parsed report.
/// Launch specs are built here; `EmbeddedTerminalView` runs them.
@MainActor
@Observable
final class TerminalModel {
    var providerUsageReport: ProviderUsageReport?
    var terminalLaunch: TerminalLaunchSpec?
    var terminalTitle = ""
    var terminalRunning = false
    var terminalIsProfileLogin = false
    var terminalIsUsageTUI = false
    var terminalNeedsManualStop = false
    var usageCommandRequest = 0
    var closeTerminalAfterCancellation = false
    private var activeTerminalProfileID: UUID?
    private var activeTerminalSessionID: UUID?
    private var activeUsageProvider: AgentProvider?

    var terminalSessionIDForView: UUID? { activeTerminalSessionID }

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
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        guard let spec = terminalLaunchSpec(
            title: "\(session.provider.rawValue.capitalized) · \(app.selectedSessionProfileName)",
            arguments: ["interactive", session.id.uuidString.lowercased(), "--profile", profileID.uuidString.lowercased()],
            workingDirectory: session.workspacePath
        ) else {
            app.errorMessage = "The AgentBridge command-line helper was not found. Run scripts/package-app.sh to build the .app first."
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
        guard terminalLaunch == nil else {
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
                "--profile", profile.id.uuidString.lowercased()
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

    func usageScreenDidUpdate(_ screenText: String, capturedAt: Date) -> Bool {
        guard terminalIsUsageTUI,
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
        return report.usageWindows.contains { $0.percentageUsed != nil || $0.resetText != nil }
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
        guard !terminalRunning else {
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
        terminalNeedsManualStop = true
        closeTerminalAfterCancellation = false
        terminalLaunch = spec
        terminalRunning = true
        app.status = "The official CLI sign-in flow opened in the app. Complete sign-in in the terminal."
        app.setupWizard.errorMessage = nil
    }

    func openLocalShell() {
        guard let session = app.selectedSession else { app.errorMessage = "Select a session first."; return }
        guard terminalLaunch == nil else { app.errorMessage = "Close the current app terminal first."; return }
        let spec = TerminalLaunchSpec(
            title: "Local Terminal · \(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent)",
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
        app.status = "The local shell opened in the isolated workspace. Shell commands still run with your current user permissions."
    }

    func closeEmbeddedTerminal() {
        if terminalRunning {
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
        terminalLaunch = nil
        terminalRunning = false
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        activeTerminalProfileID = nil
        activeTerminalSessionID = nil
        terminalNeedsManualStop = false
        app.status = "The in-app terminal closed."
    }

    func terminalDidTerminate(exitCode: Int32?) {
        terminalRunning = false
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

    @ObservationIgnored private weak var owner: AppModel?

    private var app: AppModel {
        guard let owner else { preconditionFailure("TerminalModel outlived its AppModel.") }
        return owner
    }

    /// Connects this model to the `AppModel` that owns it; called once from `AppModel.init`.
    func attach(to app: AppModel) {
        owner = app
    }
}
