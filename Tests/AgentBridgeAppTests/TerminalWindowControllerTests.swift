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
/// a refusal report) is checked with `drainMainQueue()`, which is deterministic.
/// Only real process events (a child exiting) are awaited with a timed loop.
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

    // MARK: Running process and refusal

    private struct RunningTerminal {
        let model: AppModel
        let controller: TerminalWindowController
        let launch: TerminalLaunchSpec
        let container: NSView
        let view: AgentBridgeTerminalView
    }

    /// A model showing a launch whose real process (`sleep 30`) the controller has
    /// started. Callers end it with `stop(_:)`, usually in a `defer`.
    private func startRunningTerminal() throws -> RunningTerminal {
        let model = try makeTestAppModel()
        let controller = model.terminal.windowController
        let running = launch("/bin/sleep", ["30"], title: "Earlier Terminal")
        let container = NSView()
        model.terminal.terminalLaunch = running
        model.terminal.terminalRunning = true
        mount(controller, in: container, running)
        let view = try XCTUnwrap(terminal(in: container))
        // The controller starts the process in a main-queue block.
        drainMainQueue()
        XCTAssertTrue(controller.hasRunningProcess(for: running.id), "The deferred start did not start the process.")
        return RunningTerminal(model: model, controller: controller, launch: running, container: container, view: view)
    }

    /// Ends the running process and waits until it has exited and the exit report,
    /// queued on the main queue as the process stops, has reached the model.
    @discardableResult
    private func stop(_ running: RunningTerminal) -> Bool {
        running.view.terminateWithEscalation()
        guard runMainLoop(until: { !running.controller.hasRunningProcess }) else { return false }
        drainMainQueue()
        return true
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

    /// Starts `spec` in a new view and returns every exit the view reported, once
    /// the first one arrived and anything already queued after it has run.
    private func exitCodes(running spec: TerminalLaunchSpec, file: StaticString = #filePath, line: UInt = #line) -> [Int32?] {
        let view = AgentBridgeTerminalView.make()
        var exitCodes: [Int32?] = []
        view.onTermination = { exitCodes.append($0) }

        XCTAssertTrue(view.start(spec), "The child did not start.", file: file, line: line)
        XCTAssertTrue(exitCodes.isEmpty, "Its exit is reported after start returns.", file: file, line: line)
        XCTAssertTrue(runMainLoop { !exitCodes.isEmpty }, "The child's exit was not reported.", file: file, line: line)
        // SwiftTerm reports an exit from a one-shot process source and cancels the
        // source in the same call, so a second report could only be a main-queue
        // hop that is already queued.
        drainMainQueue()
        XCTAssertFalse(view.processIsRunning, file: file, line: line)
        return exitCodes
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

    func testAWaitStatusIsDecodedIntoAnExitCode() {
        XCTAssertEqual(AgentBridgeTerminalView.exitCode(fromWaitStatus: 0), 0)
        XCTAssertEqual(AgentBridgeTerminalView.exitCode(fromWaitStatus: 1 << 8), 1)
        XCTAssertEqual(AgentBridgeTerminalView.exitCode(fromWaitStatus: 255 << 8), 255)
        XCTAssertNil(AgentBridgeTerminalView.exitCode(fromWaitStatus: SIGTERM), "Ended by a signal.")
        XCTAssertNil(AgentBridgeTerminalView.exitCode(fromWaitStatus: 0x80 | SIGKILL), "Ended by a signal, with a core dump.")
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
