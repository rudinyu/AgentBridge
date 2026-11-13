import AppKit
import Darwin
import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// The window controller keeps the one live terminal view while SwiftUI makes and
/// dismantles its containers in either order. Plain `NSView`s stand in for those
/// containers, and real child processes run in the terminal view.
///
/// Work the controller defers with `DispatchQueue.main.async` (the process start,
/// a refusal report) is checked with `drainMainQueue()`, which is deterministic
/// for main-queue blocks. Real process events (a child exiting) and the exit
/// report, which arrives in a main-actor `Task`, are awaited with a loop that
/// returns as soon as the condition holds.
@MainActor
final class TerminalWindowControllerTests: XCTestCase {
    private func launch(_ executable: String, _ arguments: [String] = [], title: String = "Test Terminal") -> TerminalLaunchSpec {
        TerminalLaunchSpec(
            title: title,
            executablePath: executable,
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/"
        )
    }

    /// Runs the main run loop until `condition` holds, for real process events.
    /// Returns as soon as it holds; the timeout only bounds a failure.
    @discardableResult
    private func runMainLoop(timeout: TimeInterval = 10, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func terminal(in container: NSView) -> AgentBridgeTerminalView? {
        container.subviews.lazy.compactMap { $0 as? AgentBridgeTerminalView }.first
    }

    private func mount(_ controller: TerminalWindowController, in container: NSView, _ launch: TerminalLaunchSpec) {
        controller.mountTerminal(in: container, launch: launch, usageCommandRequest: 0, allowsUsageScreenCapture: false)
    }

    // MARK: Re-mounting

    func testDismantlingTheOldContainerBeforeTheNewOneIsUpdatedMountsIntoTheNewOne() throws {
        let model = try makeTestAppModel()
        let controller = model.terminal.windowController
        let spec = launch("/usr/bin/true")
        let old = NSView(), new = NSView()

        mount(controller, in: old, spec)
        let view = try XCTUnwrap(terminal(in: old))
        controller.embeddedContainerDidDismantle(old, launchID: spec.id)
        XCTAssertNil(view.superview, "No other container exists yet.")

        mount(controller, in: new, spec)
        XCTAssertTrue(terminal(in: new) === view, "The same view, and with it the same process, is reused.")
        XCTAssertNil(terminal(in: old))
    }

    func testDismantlingTheOldContainerAfterTheNewOneWasUpdatedMovesTheTerminalToTheNewOne() throws {
        let model = try makeTestAppModel()
        let controller = model.terminal.windowController
        let spec = launch("/usr/bin/true")
        let old = NSView(), new = NSView()

        mount(controller, in: old, spec)
        let view = try XCTUnwrap(terminal(in: old))
        mount(controller, in: new, spec)
        XCTAssertTrue(terminal(in: new) === view)
        // SwiftUI updates the old container last, which takes the terminal back,
        // and then never updates the new one again.
        mount(controller, in: old, spec)
        XCTAssertTrue(terminal(in: old) === view)

        controller.embeddedContainerDidDismantle(old, launchID: spec.id)
        XCTAssertTrue(terminal(in: new) === view, "The surviving container gets the terminal without another update.")
        XCTAssertNil(terminal(in: old))

        // Dismantling a container that does not hold the terminal leaves it alone.
        let spare = NSView()
        mount(controller, in: spare, spec)
        mount(controller, in: new, spec)
        controller.embeddedContainerDidDismantle(spare, launchID: spec.id)
        XCTAssertTrue(terminal(in: new) === view)
    }

    // MARK: Handing an interactive CLI over to a shell

    /// Mounts an interactive launch that runs `command` as its CLI and returns
    /// the model, controller and view once the wrapper has started.
    private func startInteractive(_ command: [String]) throws -> (AppModel, TerminalWindowController, TerminalLaunchSpec, AgentBridgeTerminalView) {
        let model = try makeTestAppModel()
        let controller = model.terminal.windowController
        let spec = TerminalModel.interactiveLaunchSpec(
            title: "Codex · Test",
            command: command,
            shellNotice: "The CLI ended.",
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/"
        )
        model.terminal.terminalLaunch = spec
        model.terminal.terminalRunning = true
        let container = NSView()
        mount(controller, in: container, spec)
        let view = try XCTUnwrap(terminal(in: container))
        addTeardownBlock { @MainActor in view.terminateWithEscalation() }
        drainMainQueue()
        return (model, controller, spec, view)
    }

    func testACLIThatEndsNormallyLeavesAShellThatMustBeEndedByTheUser() throws {
        let (model, controller, spec, _) = try startInteractive(["/usr/bin/true"])
        XCTAssertTrue(runMainLoop { model.terminal.terminalNeedsManualStop }, "The wrapper did not hand over to a shell.")
        XCTAssertTrue(controller.hasRunningProcess(for: spec.id), "The shell should keep the terminal running.")
        XCTAssertTrue(model.terminal.terminalRunning)
        XCTAssertTrue(model.terminal.closeRequiresManualStop)
        XCTAssertNil(model.terminal.terminalSessionIDForView, "No run is active any more, so closing cancels nothing.")
        XCTAssertEqual(model.status, "The CLI ended. A shell opened in the same isolated workspace.")
    }

    func testACLIThatFailsOrIsCancelledEndsTheTerminalWithItsOutput() throws {
        let (model, controller, spec, _) = try startInteractive(["/usr/bin/false"])
        XCTAssertTrue(runMainLoop { !controller.hasRunningProcess(for: spec.id) && !model.terminal.terminalRunning })
        XCTAssertFalse(model.terminal.terminalNeedsManualStop)
        XCTAssertEqual(model.status, "Terminal task ended (exit code 1).")
    }

    func testOnlyTheLaunchsOwnMarkerHandsOverToTheShell() throws {
        // A CLI that sets a title like the marker, but not this launch's, and
        // keeps running, so only the title could cause a handover.
        let (model, controller, spec, _) = try startInteractive([
            "/bin/sh", "-c", "printf '\\033]0;agentbridge-shell-forged\\007'; printf '\\033]0;Codex\\007'; exec sleep 30"
        ])
        XCTAssertFalse(runMainLoop(timeout: 1) { model.terminal.terminalNeedsManualStop }, "A forged title handed over.")
        XCTAssertTrue(controller.hasRunningProcess(for: spec.id))

        // A handover reported for another launch does not apply either.
        model.terminal.interactiveCLIDidHandOverToShell(launchID: UUID())
        XCTAssertFalse(model.terminal.terminalNeedsManualStop)
    }

    func testTheHandedOverShellKeepsFilenameExpansion() {
        let spec = TerminalModel.interactiveLaunchSpec(
            title: "Codex · Test", command: ["/usr/bin/true"], shellNotice: "", environment: [:], workingDirectory: "/"
        )
        let script = spec.arguments[1]
        XCTAssertTrue(script.contains("exec /bin/sh\n") || script.hasSuffix("exec /bin/sh"), script)
        XCTAssertFalse(script.contains("/bin/sh -f"), "-f turns off filename expansion.")
    }

    func testTerminalsGetNoShellStartupFile() {
        let environment = TerminalModel.terminalEnvironment(from: [
            "ENV": "/tmp/rc", "BASH_ENV": "/tmp/rc", "LANG": "zh_TW.UTF-8", "SECRET": "x"
        ])
        XCTAssertNil(environment["ENV"])
        XCTAssertNil(environment["BASH_ENV"])
        XCTAssertNil(environment["SECRET"])
        XCTAssertEqual(environment["LANG"], "zh_TW.UTF-8")
    }

    func testTheHandoverHappensOnceAndUsesTheLocalShellTitle() throws {
        let (model, _, spec, _) = try startInteractive(["/usr/bin/true"])
        XCTAssertTrue(runMainLoop { model.terminal.terminalNeedsManualStop })
        model.terminal.terminalTitle = "Changed later"
        model.status = "Something else"
        model.terminal.interactiveCLIDidHandOverToShell(launchID: spec.id)
        XCTAssertEqual(model.terminal.terminalTitle, "Changed later", "A second handover reset the panel.")
        XCTAssertEqual(model.status, "Something else")
    }

    func testAHiddenRunningTerminalIsShownAgainInsteadOfRefusingToOpen() throws {
        let running = try startRunningTerminal()
        defer { stop(running) }
        // The panel lost its launch while the process still runs.
        running.model.terminal.terminalLaunch = nil
        running.model.terminal.terminalRunning = false
        XCTAssertTrue(running.model.terminal.recoverHiddenTerminal())
        XCTAssertEqual(running.model.terminal.terminalLaunch?.id, running.launch.id)
        XCTAssertTrue(running.model.terminal.terminalRunning)
        XCTAssertTrue(running.model.terminal.closeRequiresManualStop)
    }

    func testTheDiagnosticSummaryListsTheRunningProcessOnItsTerminal() throws {
        let running = try startRunningTerminal()
        defer { stop(running) }
        let summary = running.model.terminal.windowController.diagnosticSummary()
        XCTAssertTrue(summary.contains("launch \(running.launch.id.uuidString)"), summary)
        XCTAssertTrue(summary.contains("running true"), summary)
        XCTAssertFalse(summary.contains("Processes: none"), summary)
        XCTAssertFalse(summary.contains("Processes: unavailable"), summary)
        let firstProcess = try XCTUnwrap(summary.range(of: #"first process (\d+)"#, options: .regularExpression).map { String(summary[$0]).split(separator: " ").last.map(String.init) } ?? nil)
        XCTAssertTrue(summary.contains("Processes: \(firstProcess)("), summary)
    }

    func testAStaleRunningFlagWithNothingRunningIsCleared() throws {
        let model = try makeTestAppModel()
        model.terminal.terminalRunning = true
        XCTAssertFalse(model.terminal.recoverHiddenTerminal())
        XCTAssertFalse(model.terminal.terminalRunning)
    }

    func testACLIThatEndsNormallyWhileClosingClosesThePanelInsteadOfOpeningAShell() throws {
        let (model, controller, spec, _) = try startInteractive(["/bin/sh", "-c", "sleep 0.5"])
        model.terminal.closeTerminalAfterCancellation = true
        XCTAssertTrue(runMainLoop { !controller.hasRunningProcess(for: spec.id) && model.terminal.terminalLaunch == nil })
        XCTAssertFalse(model.terminal.terminalNeedsManualStop)
    }

    func testEndingTheTerminalAlsoEndsTheCLIUnderTheWrapper() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("agentbridge-cli-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let (_, controller, spec, view) = try startInteractive(["/bin/sh", "-c", "echo $$ > \"$0\"; exec sleep 30", pidFile.path])
        XCTAssertTrue(runMainLoop { (try? String(contentsOf: pidFile, encoding: .utf8))?.isEmpty == false })
        let pid = try XCTUnwrap(Int32((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines)))
        view.terminateWithEscalation()
        XCTAssertTrue(runMainLoop { !controller.hasRunningProcess(for: spec.id) })
        XCTAssertTrue(runMainLoop { kill(pid, 0) != 0 }, "The CLI outlived the terminal.")
    }

    // MARK: Running process and refusal

    private struct RunningTerminal {
        let model: AppModel
        let controller: TerminalWindowController
        let launch: TerminalLaunchSpec
        let container: NSView
        let view: AgentBridgeTerminalView
    }

    /// A model showing a launch whose real process (`sleep 30`) the controller has
    /// started. Callers end it with `stop(_:)`, usually in a `defer`; a teardown
    /// block also signals it, so it cannot outlive a test that fails midway.
    private func startRunningTerminal() throws -> RunningTerminal {
        let model = try makeTestAppModel()
        let controller = model.terminal.windowController
        let running = launch("/bin/sleep", ["30"], title: "Earlier Terminal")
        let container = NSView()
        model.terminal.terminalLaunch = running
        model.terminal.terminalRunning = true
        mount(controller, in: container, running)
        let view = try XCTUnwrap(terminal(in: container))
        // Does nothing once the process has ended.
        addTeardownBlock { @MainActor in view.terminateWithEscalation() }
        // The controller starts the process in a main-queue block.
        drainMainQueue()
        XCTAssertTrue(controller.hasRunningProcess(for: running.id), "The deferred start did not start the process.")
        return RunningTerminal(model: model, controller: controller, launch: running, container: container, view: view)
    }

    /// Ends the running process and waits until it has exited and its exit report
    /// (a main-actor `Task` queued as the process stops) has been delivered to the
    /// controller's handler, and so to the model. Returns at once if no process runs.
    @discardableResult
    private func stop(_ running: RunningTerminal) -> Bool {
        guard running.controller.hasRunningProcess else { return true }
        var reported = false
        let report = running.view.onTermination
        running.view.onTermination = { exitCode in
            report?(exitCode)
            reported = true
        }
        running.view.terminateWithEscalation()
        return runMainLoop { reported && !running.controller.hasRunningProcess }
    }

    /// The model moves on to a launch the controller cannot start; SwiftUI then
    /// updates that launch's container `updates` times before the report runs.
    private func refuse(_ refused: TerminalLaunchSpec, in running: RunningTerminal, updates: Int = 1) {
        running.model.terminal.terminalLaunch = refused
        let container = NSView()
        for _ in 0..<updates { mount(running.controller, in: container, refused) }
        XCTAssertTrue(container.subviews.isEmpty, "A refused launch gets no terminal.")
    }

    func testTheControllerReportsTheLaunchWhoseProcessRuns() throws {
        let running = try startRunningTerminal()
        defer { stop(running) }

        XCTAssertEqual(running.controller.runningLaunch, running.launch)
        XCTAssertFalse(running.controller.hasRunningProcess(for: UUID()))
        XCTAssertEqual(running.model.terminal.terminalProcessLaunchID, running.launch.id)
    }

    func testANewLaunchIsRefusedWhileAnEarlierProcessRunsAndTheModelShowsThatProcessAgain() throws {
        let running = try startRunningTerminal()
        defer { stop(running) }

        refuse(launch("/usr/bin/true"), in: running, updates: 3)
        XCTAssertTrue(terminal(in: running.container) === running.view, "The running terminal is not moved or replaced.")
        drainMainQueue()
        XCTAssertEqual(running.model.terminal.terminalLaunch?.id, running.launch.id)
        XCTAssertTrue(running.model.terminal.closeRequiresManualStop)
        XCTAssertNotNil(running.model.errorMessage)
    }

    func testTheSameRefusedLaunchIsNotReportedAgain() throws {
        let running = try startRunningTerminal()
        defer { stop(running) }
        let refused = launch("/usr/bin/true")
        refuse(refused, in: running, updates: 3)
        drainMainQueue()
        XCTAssertEqual(running.model.terminal.terminalLaunch?.id, running.launch.id)

        // Even if the model goes back to it, that launch is not reported again.
        running.model.errorMessage = nil
        refuse(refused, in: running)
        drainMainQueue()
        XCTAssertEqual(running.model.terminal.terminalLaunch?.id, refused.id)
        XCTAssertNil(running.model.errorMessage)
    }

    func testADifferentRefusedLaunchIsReportedToo() throws {
        let running = try startRunningTerminal()
        defer { stop(running) }
        refuse(launch("/usr/bin/true"), in: running)
        drainMainQueue()
        running.model.errorMessage = nil

        refuse(launch("/usr/bin/true"), in: running)
        drainMainQueue()
        XCTAssertEqual(running.model.terminal.terminalLaunch?.id, running.launch.id)
        XCTAssertNotNil(running.model.errorMessage)
    }

    func testOnceTheEarlierProcessEndsThePanelClosesNormally() throws {
        let running = try startRunningTerminal()
        refuse(launch("/usr/bin/true"), in: running)
        drainMainQueue()

        XCTAssertTrue(stop(running), "The process did not end.")
        XCTAssertNil(running.controller.runningLaunch)
        XCTAssertFalse(running.model.terminal.terminalRunning)
        // Ending it from the app is not reported as a failure with a signal number.
        XCTAssertEqual(running.model.status, "Terminal task ended.")
        running.model.terminal.closeEmbeddedTerminal()
        XCTAssertNil(running.model.terminal.terminalLaunch)
        XCTAssertEqual(running.model.status, "The in-app terminal closed.")
    }

    // MARK: Starting a real process

    /// Starts `spec` in a new view and returns every exit the view reported: the
    /// first one, plus any further one that shows up while the main queue and the
    /// main actor are drained after it.
    private func exitCodes(running spec: TerminalLaunchSpec, file: StaticString = #filePath, line: UInt = #line) -> [Int32?] {
        let view = AgentBridgeTerminalView.make()
        var reported: [Int32?] = []
        view.onTermination = { reported.append($0) }

        XCTAssertTrue(view.start(spec), "The child did not start.", file: file, line: line)
        XCTAssertTrue(reported.isEmpty, "Its exit is reported after start returns.", file: file, line: line)
        XCTAssertTrue(runMainLoop { !reported.isEmpty && !view.processIsRunning }, "The child's exit was not reported.", file: file, line: line)
        // "Once" rests on SwiftTerm: it reports an exit from a one-shot process
        // source on the main queue and cancels the source in the same block, so
        // no second report can be made. The drain gives a hop that is already
        // queued a chance to show up; it cannot prove that none ever will.
        drainMainQueue()
        return reported
    }

    func testAChildThatExitsAtOnceStartsAndReportsItsExitOnce() {
        XCTAssertEqual(exitCodes(running: launch("/usr/bin/true")), [0])
    }

    func testAChildsExitStatusIsReportedAsItsExitCode() {
        XCTAssertEqual(exitCodes(running: launch("/bin/sh", ["-c", "exit 3"])), [3])
    }

    func testAChildEndedByASignalReportsNoExitCode() {
        XCTAssertEqual(exitCodes(running: launch("/bin/sh", ["-c", "kill -TERM $$"])), [nil])
    }

    func testAChildEndedByAnotherSignalReportsTheShellsSignalExitCode() {
        // Fault signals are covered by the decoder test: a real one writes a crash report on every run.
        XCTAssertEqual(exitCodes(running: launch("/bin/sh", ["-c", "kill -USR1 $$"])), [128 + SIGUSR1])
    }

    func testAWaitStatusIsDecodedIntoAnExitCode() {
        XCTAssertEqual(AgentBridgeTerminalView.exitCode(fromWaitStatus: 0), 0)
        XCTAssertEqual(AgentBridgeTerminalView.exitCode(fromWaitStatus: 1 << 8), 1)
        XCTAssertEqual(AgentBridgeTerminalView.exitCode(fromWaitStatus: 255 << 8), 255)
        // Signals that end a terminal on purpose: the app's close and cancel
        // (TERM, KILL), Control-C (INT) and the pseudo-terminal closing (HUP).
        for signal in [SIGTERM, SIGKILL, SIGINT, SIGHUP] {
            XCTAssertNil(AgentBridgeTerminalView.exitCode(fromWaitStatus: signal), "Ended on purpose by signal \(signal).")
        }
        XCTAssertNil(AgentBridgeTerminalView.exitCode(fromWaitStatus: 0x80 | SIGKILL), "Ended on purpose, with a core dump.")
        // Any other signal, such as a crash, gets the shell's 128 + signal number.
        XCTAssertEqual(AgentBridgeTerminalView.exitCode(fromWaitStatus: SIGSEGV), 139)
        XCTAssertEqual(AgentBridgeTerminalView.exitCode(fromWaitStatus: 0x80 | SIGABRT), 134, "With a core dump.")
        XCTAssertEqual(AgentBridgeTerminalView.exitCode(fromWaitStatus: SIGBUS), 128 + SIGBUS)
        XCTAssertEqual(AgentBridgeTerminalView.exitCode(fromWaitStatus: SIGQUIT), 131)
        XCTAssertNil(AgentBridgeTerminalView.exitCode(fromWaitStatus: (SIGSTOP << 8) | 0x7f), "Stopped, not ended.")
    }

    func testAMissingExecutableStartsAChildThatExitsWithAFailure() {
        // forkpty succeeds and the child's execve fails, so SwiftTerm reports a
        // started process that exits with 127, not a start failure. This is
        // SwiftTerm 1.20.0's forkpty path (its Subprocess path is compiled out);
        // another SwiftTerm version may report this differently.
        XCTAssertEqual(exitCodes(running: launch("/nonexistent/agentbridge-\(UUID().uuidString)")), [127])
    }
}
