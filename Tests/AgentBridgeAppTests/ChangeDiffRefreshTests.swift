import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// The change diff of an isolated-changes session loads in the background while
/// holding the session's run lease, and several refreshes ask for it.
@MainActor
final class ChangeDiffRefreshTests: XCTestCase {
    func testOverlappingDiffRequestsDoNotReportTheSessionAsRunningElsewhere() async throws {
        let (model, session) = try await makeModelWithIsolatedChangesSession()
        let loadsBefore = model.changeDiffLoadCount

        // Selecting the session and a refresh both ask for its diff, as at launch;
        // the later requests arrive while the first load holds the lease.
        model.selectedSessionID = session.id
        model.refreshSelectedEvents()
        model.refreshSelectedEvents()
        model.refresh()
        XCTAssertEqual(model.changeDiffLoadsInFlight, [session.id])

        try await waitUntil { model.changeDiffLoadsInFlight.isEmpty }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.changes.changeDiff?.files.map(\.path), ["new.txt"])
        // The requests made meanwhile were served by one more load, not one each.
        XCTAssertEqual(model.changeDiffLoadCount, loadsBefore + 2)
    }

    func testARequestMadeDuringALoadIsServedByALaterLoad() async throws {
        let (model, session) = try await makeModelWithIsolatedChangesSession()
        let service = try XCTUnwrap(model.service)
        let loadsBefore = model.changeDiffLoadCount
        model.selectedSessionID = session.id

        // Hold the lease so the first load reads nothing, and ask again meanwhile.
        var lease: SessionRunLease? = try service.store.acquireRunLease(for: session.id)
        model.refreshSelectedEvents()
        model.refreshSelectedEvents()
        try await waitUntil { model.changeDiffLoadCount == loadsBefore + 1 && model.changes.changeDiff == nil }

        // Before the follow-up load, free the lease (a lease unlocks when
        // released) and change the workspace: the follow-up must show it.
        withExtendedLifetime(lease) {}
        lease = nil
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true)
        try Data("more\n".utf8).write(to: workspace.appendingPathComponent("later.txt"))
        try await waitUntil { model.changeDiffLoadsInFlight.isEmpty }
        XCTAssertEqual(model.changeDiffLoadCount, loadsBefore + 2)
        XCTAssertEqual(model.changes.changeDiff?.files.map(\.path), ["later.txt", "new.txt"])
        XCTAssertNil(model.errorMessage)
    }

    func testARequestedReloadIsDroppedWhenTheSessionIsNoLongerSelected() async throws {
        let (model, session) = try await makeModelWithIsolatedChangesSession()
        let service = try XCTUnwrap(model.service)
        let loadsBefore = model.changeDiffLoadCount
        model.selectedSessionID = session.id
        let lease = try service.store.acquireRunLease(for: session.id)
        model.refreshSelectedEvents()
        model.refreshSelectedEvents()
        // Deselect once the first load has started and a reload is pending.
        try await waitUntil { model.changeDiffLoadCount == loadsBefore + 1 }
        model.selectedSessionID = nil

        try await waitUntil { model.changeDiffLoadsInFlight.isEmpty }
        XCTAssertEqual(model.changeDiffLoadCount, loadsBefore + 1)
        withExtendedLifetime(lease) {}
    }

    func testNoLoadRunsForASessionDeselectedBeforeItsLoadStarts() async throws {
        let (model, session) = try await makeModelWithIsolatedChangesSession()
        let loadsBefore = model.changeDiffLoadCount
        model.selectedSessionID = session.id
        model.refreshSelectedEvents()
        model.selectedSessionID = nil

        try await waitUntil { model.changeDiffLoadsInFlight.isEmpty }
        XCTAssertEqual(model.changeDiffLoadCount, loadsBefore)
    }

    func testALeaseHeldByOtherWorkKeepsTheShownDiffWithoutAnAlert() async throws {
        let (model, session) = try await makeModelWithIsolatedChangesSession()
        model.selectedSessionID = session.id
        model.refreshSelectedEvents()
        try await waitUntil { model.changeDiffLoadsInFlight.isEmpty && model.changes.changeDiff != nil }
        let shown = model.changes.changeDiff
        let loadsSoFar = model.changeDiffLoadCount

        // Something else, such as a CLI run of this session, holds its lease.
        let service = try XCTUnwrap(model.service)
        let lease = try service.store.acquireRunLease(for: session.id)
        model.refreshSelectedEvents()
        XCTAssertEqual(model.changeDiffLoadsInFlight, [session.id])
        try await waitUntil { model.changeDiffLoadsInFlight.isEmpty }
        XCTAssertEqual(model.changeDiffLoadCount, loadsSoFar + 1)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.changes.changeDiff, shown)
        withExtendedLifetime(lease) {}
    }

    func testOtherDiffErrorsAreStillReported() async throws {
        let (model, session) = try await makeModelWithIsolatedChangesSession()
        model.selectedSessionID = session.id
        // A missing workspace makes the diff fail for a reason other than the lease.
        try FileManager.default.removeItem(atPath: session.workspacePath)
        model.refreshSelectedEvents()
        try await waitUntil { model.changeDiffLoadsInFlight.isEmpty }
        let message = try XCTUnwrap(model.errorMessage)
        XCTAssertNotEqual(message, AgentBridgeError.sessionBusyMessage)
    }

    // MARK: - Fixture

    private struct Timeout: Error, CustomStringConvertible {
        var description: String { "Timed out waiting for the change diff to load." }
    }

    private func makeModelWithIsolatedChangesSession() async throws -> (AppModel, SessionRecord) {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChangeDiffRefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        try Data("original\n".utf8).write(to: source.appendingPathComponent("source.txt"))
        try runGit(["init", "-q", source.path])
        try runGit(["-C", source.path, "add", "source.txt"])
        try runGit(["-C", source.path, "commit", "-q", "-m", "initial"])

        let session = try await service.createSession(sourcePath: source.path, provider: .codex, accessMode: .isolatedChanges)
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true)
        try Data("added\n".utf8).write(to: workspace.appendingPathComponent("new.txt"))
        // Show the new session without selecting it, so each test decides when
        // the first diff request is made.
        model.refresh()
        model.selectedSessionID = nil
        try await waitUntil { model.changeDiffLoadsInFlight.isEmpty }
        model.changes.changeDiff = nil
        return (model, session)
    }

    /// Lets the main actor run until `condition` holds; throws after 10 seconds.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw Timeout() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Git for the fixture source repository only: no inherited Git variables, no
    /// system or global config, templates or hooks, and a fixed identity. The
    /// core tests' `FixtureGit` is in another test target this one cannot import.
    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null"] + arguments
        process.environment = [
            "HOME": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TEMPLATE_DIR": "",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_AUTHOR_NAME": "AgentBridge Fixture",
            "GIT_AUTHOR_EMAIL": "agentbridge-fixture@example.invalid",
            "GIT_COMMITTER_NAME": "AgentBridge Fixture",
            "GIT_COMMITTER_EMAIL": "agentbridge-fixture@example.invalid"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")): \(text)"])
        }
    }
}
