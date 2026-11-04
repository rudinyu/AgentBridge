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
            app.errorMessage = "請先建立互動手動核准模式的工作階段。"
            return
        }
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        guard let spec = terminalLaunchSpec(
            title: "\(session.provider.rawValue.capitalized) · \(app.selectedSessionProfileName)",
            arguments: ["interactive", session.id.uuidString.lowercased(), "--profile", profileID.uuidString.lowercased()],
            workingDirectory: session.workspacePath
        ) else {
            app.errorMessage = "找不到 AgentBridge 命令列輔助程式。請先使用 scripts/package-app.sh 建立 .app。"
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
        app.status = "已在 App 內啟動互動終端機。終端機文字不會自動加入共用記憶。"
    }

    func openSubscriptionUsageTUI() {
        guard !app.hasActiveAutonomousWorkflow else {
            app.errorMessage = app.localized("The terminal is locked while an autonomous workflow is active.")
            return
        }
        guard app.settings.usageMode == .subscription else {
            app.errorMessage = "官方 usage TUI 只支援訂閱登入。"
            return
        }
        guard terminalLaunch == nil else {
            app.errorMessage = "請先關閉目前的 App 終端機。"
            return
        }
        let provider = app.settings.defaultProvider
        guard provider != .local else {
            app.errorMessage = app.localized("Local models do not have a provider subscription usage screen.")
            return
        }
        guard let profileID = app.selectedProfileIDs[provider],
              let profile = app.accountProfiles[provider]?.first(where: { $0.id == profileID }) else {
            app.errorMessage = "找不到目前選取的帳戶設定。"
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
            app.errorMessage = "找不到 AgentBridge 命令列輔助程式。請先使用 scripts/package-app.sh 建立 .app。"
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
        app.status = "已啟動所選帳戶的官方 CLI 用量終端；請等待可輸入提示符並完成登入，再送出 /usage。"
    }

    func requestUsageCommand() {
        guard canSendUsageCommand else { return }
        usageCommandRequest &+= 1
        app.status = "已在目前官方 CLI 終端送出固定的 /usage 指令。"
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
        guard let profile = app.selectedAccountProfile else { app.errorMessage = "找不到所選帳戶設定。"; return }
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
            title: "登入 · \(profile.provider.rawValue.capitalized) · \(profile.name)",
            arguments: ["profile-login", profile.id.uuidString.lowercased()],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ) else {
            app.reportOperationError("找不到 AgentBridge 命令列輔助程式。請先使用 scripts/package-app.sh 建立 .app。")
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
        app.status = "已在 App 內開啟官方 CLI 登入流程。登入由你在終端機完成。"
        app.setupWizard.errorMessage = nil
    }

    func openLocalShell() {
        guard let session = app.selectedSession else { app.errorMessage = "請先選擇工作階段。"; return }
        guard terminalLaunch == nil else { app.errorMessage = "請先關閉目前的 App 終端機。"; return }
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
        app.status = "已在隔離工作區開啟本機 shell。Shell 命令仍以目前使用者權限執行。"
    }

    func closeEmbeddedTerminal() {
        if terminalRunning {
            if terminalNeedsManualStop {
                app.status = "請先在終端機按 Control-C 結束目前程序，再關閉終端面板。"
                return
            }
            guard let sessionID = activeTerminalSessionID else {
                app.status = "請先結束終端機中的工作，再關閉面板。"
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
        app.status = "已關閉 App 內終端機。"
    }

    func terminalDidTerminate(exitCode: Int32?) {
        terminalRunning = false
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        if let exitCode, exitCode == 0 {
            app.status = "終端機工作已完成。"
        } else {
            app.status = "終端機工作已結束\(exitCode.map { "（代碼 \($0)）" } ?? "")。"
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
