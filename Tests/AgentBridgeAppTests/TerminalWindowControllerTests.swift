import AppKit
import Darwin
import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// The window controller keeps the one live terminal view while SwiftUI makes and
/// dismantles its containers in either order. Plain `NSView`s stand in for those
/// containers, and real child processes run in the terminal view.
@MainActor
final class TerminalWindowControllerTests: XCTestCase {
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
        let root = canonicalParent.appendingPathComponent("TerminalWindowControllerTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        let store = try AuditStore(rootURL: root.appendingPathComponent("state"), workspaceRootURL: root.appendingPathComponent("data"), managedWorkspaceRoots: [])
        let service = try BridgeService(store: store)
        let model = AppModel(store: store, service: service)
        model.refresh()
        return model
    }

    private func launch(_ executable: String, _ arguments: [String] = [], title: String = "Test Terminal") -> TerminalLaunchSpec {
        TerminalLaunchSpec(
            title: title,
            executablePath: executable,
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin"],
            workingDirectory: "/"
        )
    }

    /// Lets queued main-queue work, such as the deferred process start and the
    /// termination callback, run until `condition` holds.
    @discardableResult
    private func runMainLoop(timeout: TimeInterval = 5, until condition: () -> Bool = { false }) -> Bool {
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
        let model = try makeModel()
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
        let model = try makeModel()
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

    func testANewLaunchIsRefusedOnceWhileAnEarlierProcessRunsAndTheModelShowsThatProcessAgain() throws {
        let model = try makeModel()
        let controller = model.terminal.windowController
        let running = launch("/bin/sleep", ["30"], title: "Earlier Terminal")
        let first = NSView()
        model.terminal.terminalLaunch = running
        model.terminal.terminalRunning = true
        mount(controller, in: first, running)
        let view = try XCTUnwrap(terminal(in: first))
        defer {
            view.terminateWithEscalation()
            runMainLoop { !controller.hasRunningProcess }
        }

        XCTAssertTrue(runMainLoop { controller.hasRunningProcess(for: running.id) }, "The deferred start never ran.")
        XCTAssertEqual(controller.runningLaunch, running)
        XCTAssertFalse(controller.hasRunningProcess(for: UUID()))
        XCTAssertEqual(model.terminal.terminalProcessLaunchID, running.id)

        // The model moved on to a new launch that the controller cannot start, and
        // SwiftUI updates its container several times before the report runs.
        let refused = launch("/usr/bin/true")
        let second = NSView()
        model.terminal.terminalLaunch = refused
        for _ in 0..<3 { mount(controller, in: second, refused) }
        XCTAssertTrue(second.subviews.isEmpty)
        XCTAssertTrue(terminal(in: first) === view, "The running terminal is not moved or replaced.")
        XCTAssertTrue(runMainLoop { model.terminal.terminalLaunch?.id == running.id })
        XCTAssertTrue(model.terminal.closeRequiresManualStop)
        XCTAssertNotNil(model.errorMessage)

        // The same refused launch is not reported again, even if the model went back to it.
        model.errorMessage = nil
        model.terminal.terminalLaunch = refused
        mount(controller, in: second, refused)
        runMainLoop(timeout: 0.2)
        XCTAssertEqual(model.terminal.terminalLaunch?.id, refused.id)
        XCTAssertNil(model.errorMessage)

        // A different refused launch is reported.
        let another = launch("/usr/bin/true")
        model.terminal.terminalLaunch = another
        mount(controller, in: NSView(), another)
        XCTAssertTrue(runMainLoop { model.terminal.terminalLaunch?.id == running.id })
        XCTAssertNotNil(model.errorMessage)

        // Once the earlier process ends, nothing runs and the panel closes normally.
        view.terminateWithEscalation()
        XCTAssertTrue(runMainLoop { !controller.hasRunningProcess && !model.terminal.terminalRunning })
        XCTAssertNil(controller.runningLaunch)
        model.terminal.closeEmbeddedTerminal()
        XCTAssertNil(model.terminal.terminalLaunch)
        XCTAssertEqual(model.status, "The in-app terminal closed.")
    }

    // MARK: Starting a real process

    func testAChildThatExitsAtOnceStartsAndReportsItsExitOnce() {
        let view = AgentBridgeTerminalView.make()
        var exitCodes: [Int32?] = []
        view.onTermination = { exitCodes.append($0) }

        XCTAssertTrue(view.start(launch("/usr/bin/true")), "A child that exits at once still started.")
        XCTAssertTrue(exitCodes.isEmpty, "Its exit is reported after start returns.")
        XCTAssertTrue(runMainLoop { !exitCodes.isEmpty })
        runMainLoop(timeout: 0.3)
        XCTAssertEqual(exitCodes, [0])
        XCTAssertFalse(view.processIsRunning)
    }

    func testAMissingExecutableStartsAChildThatExitsWithAFailure() {
        let view = AgentBridgeTerminalView.make()
        var exitCodes: [Int32?] = []
        view.onTermination = { exitCodes.append($0) }

        // forkpty succeeds and the child's execve fails, so SwiftTerm reports a
        // started process whose exit is a failure, not a start failure.
        XCTAssertTrue(view.start(launch("/nonexistent/agentbridge-\(UUID().uuidString)")))
        XCTAssertTrue(runMainLoop { !exitCodes.isEmpty })
        runMainLoop(timeout: 0.3)
        XCTAssertEqual(exitCodes.count, 1)
        let status = exitCodes.first.flatMap { $0 }
        XCTAssertNotNil(status)
        XCTAssertNotEqual(status, 0)
        XCTAssertFalse(view.processIsRunning)
    }
}
