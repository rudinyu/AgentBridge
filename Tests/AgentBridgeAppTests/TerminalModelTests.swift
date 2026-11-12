import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// The embedded terminal's model must never be left "running" with no process
/// behind it: the panel then showed a spinner forever and its close button was
/// locked. No window or process is created here; the controller's callbacks
/// are called directly.
@MainActor
final class TerminalModelTests: XCTestCase {
    /// A model with one selected session, which the local shell needs.
    private func makeModel() throws -> AppModel {
        let model = try makeTestAppModel(sessions: [
            SessionRecord(
                updatedAt: Date(),
                provider: .codex,
                sourceRepositoryPath: "/tmp/repo",
                workspacePath: "/tmp/ws",
                snapshotCommit: String(repeating: "a", count: 40),
                sourceWasDirty: false
            )
        ])
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

    func testARefusedLaunchLeavesNothingOfItselfBehind() throws {
        let model = try makeModel()
        let refused = try openLocalShell(in: model)
        let selectedSession = try XCTUnwrap(model.selectedSession)
        // State another open function or a pending cancel-and-close could have set
        // for the refused launch before the controller refused it.
        model.terminal.terminalIsProfileLogin = true
        model.terminal.terminalIsUsageTUI = true
        model.terminal.closeTerminalAfterCancellation = true
        let running = TerminalLaunchSpec(title: "Earlier Terminal", executablePath: "/bin/sh", arguments: [], environment: [:], workingDirectory: "/tmp")

        model.terminal.terminalLaunchWasRefused(refused.id, runningLaunch: running)
        XCTAssertFalse(model.terminal.terminalIsProfileLogin)
        XCTAssertFalse(model.terminal.terminalIsUsageTUI)
        XCTAssertFalse(model.terminal.closeTerminalAfterCancellation)
        XCTAssertNil(model.terminal.terminalSessionIDForView)
        XCTAssertEqual(model.terminal.terminalProcessLaunchID, running.id)
        XCTAssertEqual(model.selectedSession, selectedSession, "Opening a terminal never marks a session as running.")

        // The refused launch never had a process, so a late report for it changes nothing.
        model.terminal.terminalDidTerminate(launchID: refused.id, exitCode: 0)
        model.terminal.terminalDidFailToStart(launchID: refused.id)
        XCTAssertTrue(model.terminal.terminalRunning)
        XCTAssertEqual(model.terminal.terminalLaunch?.id, running.id)

        // The earlier process ending does not close the panel by itself.
        model.terminal.terminalDidTerminate(launchID: running.id, exitCode: 0)
        XCTAssertEqual(model.terminal.terminalLaunch?.id, running.id)
        XCTAssertFalse(model.terminal.terminalRunning)
    }

    func testARefusalForALaunchTheModelNoLongerShowsIsIgnored() throws {
        let model = try makeModel()
        let current = try openLocalShell(in: model)
        let running = TerminalLaunchSpec(title: "Earlier Terminal", executablePath: "/bin/sh", arguments: [], environment: [:], workingDirectory: "/tmp")

        model.terminal.terminalLaunchWasRefused(UUID(), runningLaunch: running)
        XCTAssertEqual(model.terminal.terminalLaunch?.id, current.id)
        XCTAssertNil(model.errorMessage)
    }

    func testTheStatusLineSaysHowTheTerminalTaskEnded() throws {
        let expectations: [(exitCode: Int32?, status: String)] = [
            (0, "The terminal task completed."),
            (1, "Terminal task ended (exit code 1)."),
            (134, "Terminal task ended (exit code 134)."), // A crash: 128 + SIGABRT.
            (nil, "Terminal task ended.") // Ended on purpose, or no code known.
        ]
        for expected in expectations {
            let model = try makeModel()
            let launch = try openLocalShell(in: model)
            model.terminal.terminalProcessDidStart(launchID: launch.id)
            model.terminal.terminalDidTerminate(launchID: launch.id, exitCode: expected.exitCode)
            XCTAssertFalse(model.terminal.terminalRunning)
            XCTAssertEqual(model.status, expected.status, "Exit code \(String(describing: expected.exitCode)).")
        }
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
