import Darwin
import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// The embedded terminal's model must never be left "running" with no process
/// behind it: the panel then showed a spinner forever and its close button was
/// locked. No window or process is created here; the controller's callbacks
/// are called directly.
@MainActor
final class TerminalModelTests: XCTestCase {
    private func makeModel() throws -> AppModel {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureParent = packageRoot.appendingPathComponent("build/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureParent, withIntermediateDirectories: true)
        guard let resolvedPath = fixtureParent.path.withCString({ realpath($0, nil) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(resolvedPath) }
        let canonicalParent = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
        let root = canonicalParent.appendingPathComponent("TerminalModelTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        let store = try AuditStore(rootURL: root.appendingPathComponent("state"), workspaceRootURL: root.appendingPathComponent("data"), managedWorkspaceRoots: [])
        let service = try BridgeService(store: store)
        try store.saveSessions([
            SessionRecord(
                updatedAt: Date(),
                provider: .codex,
                sourceRepositoryPath: "/tmp/repo",
                workspacePath: "/tmp/ws",
                snapshotCommit: String(repeating: "a", count: 40),
                sourceWasDirty: false
            )
        ])
        let model = AppModel(store: store, service: service)
        model.refresh()
        XCTAssertNotNil(model.selectedSession)
        return model
    }

    private func openLocalShell(in model: AppModel) throws -> TerminalLaunchSpec {
        model.terminal.openLocalShell()
        let launch = try XCTUnwrap(model.terminal.terminalLaunch)
        XCTAssertTrue(model.terminal.terminalRunning)
        return launch
    }

    private func assertClosed(_ model: AppModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(model.terminal.terminalLaunch, file: file, line: line)
        XCTAssertFalse(model.terminal.terminalRunning, file: file, line: line)
        XCTAssertNil(model.terminal.terminalProcessLaunchID, file: file, line: line)
        XCTAssertFalse(model.terminal.terminalNeedsManualStop, file: file, line: line)
        XCTAssertEqual(model.status, "The in-app terminal closed.", file: file, line: line)
    }

    func testALocalShellWhoseProcessNeverStartedCanBeClosed() throws {
        let model = try makeModel()
        _ = try openLocalShell(in: model)

        XCTAssertFalse(model.terminal.closeRequiresManualStop)
        XCTAssertEqual(model.terminal.closeButtonTitle, "Close terminal")
        model.terminal.closeEmbeddedTerminal()
        assertClosed(model)
    }

    func testAStartedLocalShellKeepsTheManualStopRule() throws {
        let model = try makeModel()
        let launch = try openLocalShell(in: model)

        model.terminal.terminalProcessDidStart(launchID: launch.id)
        XCTAssertTrue(model.terminal.closeRequiresManualStop)
        XCTAssertEqual(model.terminal.closeButtonTitle, "End the CLI, then close")

        model.terminal.terminalDidTerminate(launchID: launch.id, exitCode: 0)
        XCTAssertFalse(model.terminal.closeRequiresManualStop)
        XCTAssertEqual(model.terminal.closeButtonTitle, "Close terminal")
        model.terminal.closeEmbeddedTerminal()
        assertClosed(model)
    }

    func testClosingWhenTheModelThinksAProcessRunsButNoneDoesResetsTheTerminal() throws {
        let model = try makeModel()
        let launch = try openLocalShell(in: model)
        // The model was told the process started, but the controller has no process
        // for this launch (here: no view was ever made), so closing must not dead-end.
        model.terminal.terminalProcessDidStart(launchID: launch.id)
        XCTAssertFalse(model.terminal.windowController.hasRunningProcess(for: launch.id))

        model.terminal.closeEmbeddedTerminal()
        assertClosed(model)
    }

    func testAStartFailureEndsTheLaunchAndSaysSo() throws {
        let model = try makeModel()
        let launch = try openLocalShell(in: model)

        model.terminal.terminalDidFailToStart(launchID: launch.id)
        XCTAssertFalse(model.terminal.terminalRunning)
        XCTAssertEqual(model.terminal.terminalLaunch?.id, launch.id, "The panel stays open so the user sees what happened.")
        XCTAssertFalse(model.terminal.closeRequiresManualStop)
        XCTAssertEqual(model.status, "The in-app terminal could not start. Close the panel and try again.")
        XCTAssertEqual(model.errorMessage, "The in-app terminal could not start. Close the panel and try again.")

        model.terminal.closeEmbeddedTerminal()
        assertClosed(model)
    }

    func testAStartFailureOfAnotherLaunchIsIgnored() throws {
        let model = try makeModel()
        let launch = try openLocalShell(in: model)

        model.terminal.terminalDidFailToStart(launchID: UUID())
        XCTAssertTrue(model.terminal.terminalRunning)
        XCTAssertEqual(model.terminal.terminalLaunch?.id, launch.id)
        XCTAssertNil(model.errorMessage)
    }

    func testARefusedLaunchShowsTheStillRunningLaunchAgain() throws {
        let model = try makeModel()
        let refused = try openLocalShell(in: model)
        let running = TerminalLaunchSpec(
            title: "Earlier Terminal",
            executablePath: "/bin/sh",
            arguments: ["-f"],
            environment: [:],
            workingDirectory: "/tmp"
        )

        model.terminal.terminalLaunchWasRefused(refused.id, runningLaunch: running)
        XCTAssertEqual(model.terminal.terminalLaunch?.id, running.id)
        XCTAssertEqual(model.terminal.terminalTitle, "Earlier Terminal")
        XCTAssertTrue(model.terminal.terminalRunning)
        XCTAssertTrue(model.terminal.closeRequiresManualStop, "The earlier process is never closed over or killed implicitly.")
        XCTAssertFalse(model.terminal.terminalIsUsageTUI)
        XCTAssertFalse(model.terminal.canSendUsageCommand)
        XCTAssertNil(model.terminal.terminalSessionIDForView)
        XCTAssertEqual(
            model.errorMessage,
            "An earlier terminal process is still running, so it is shown again. End it before opening another terminal."
        )

        // Once that process exits, the panel closes normally.
        model.terminal.terminalDidTerminate(launchID: running.id, exitCode: 0)
        XCTAssertFalse(model.terminal.terminalRunning)
        model.terminal.closeEmbeddedTerminal()
        assertClosed(model)
    }

    func testARefusalForALaunchTheModelNoLongerShowsIsIgnored() throws {
        let model = try makeModel()
        let current = try openLocalShell(in: model)
        let running = TerminalLaunchSpec(title: "Earlier Terminal", executablePath: "/bin/sh", arguments: [], environment: [:], workingDirectory: "/tmp")

        model.terminal.terminalLaunchWasRefused(UUID(), runningLaunch: running)
        XCTAssertEqual(model.terminal.terminalLaunch?.id, current.id)
        XCTAssertNil(model.errorMessage)
    }

    func testTheNewMessagesAreTranslated() {
        XCTAssertEqual(
            AppLocalization.display("The in-app terminal could not start. Close the panel and try again.", language: .traditionalChinese),
            "App 內終端機無法啟動。請關閉面板後再試一次。"
        )
        XCTAssertEqual(
            AppLocalization.display(
                "An earlier terminal process is still running, so it is shown again. End it before opening another terminal.",
                language: .traditionalChinese
            ),
            "先前的終端機程序仍在執行，因此重新顯示。請先結束它，再開啟其他終端機。"
        )
    }
}
