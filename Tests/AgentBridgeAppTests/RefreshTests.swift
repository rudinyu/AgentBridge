import AgentBridgeCore
import Observation
import XCTest
@testable import AgentBridgeApp

@MainActor
final class RefreshTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let store: AuditStore
        let service: BridgeService
        let model: AppModel
    }

    private func makeFixture(sessions count: Int = 3, events eventCount: Int = 5) throws -> (Fixture, [SessionRecord]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RefreshTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        let store = try AuditStore(rootURL: root.appendingPathComponent("state"), workspaceRootURL: root.appendingPathComponent("data"), managedWorkspaceRoots: [])
        let service = try BridgeService(store: store)
        let sessions = (0..<count).map { makeSession($0) }
        try store.saveSessions(sessions)
        if let first = sessions.first {
            for index in 0..<eventCount {
                try store.appendEvent(AuditEvent(sessionID: first.id, kind: "run.progress", message: "event \(index)"))
            }
        }
        return (Fixture(root: root, store: store, service: service, model: AppModel(store: store, service: service)), sessions)
    }

    private func makeSession(_ index: Int) -> SessionRecord {
        SessionRecord(
            updatedAt: Date(timeIntervalSince1970: 1_000_000 - Double(index)),
            provider: .codex,
            sourceRepositoryPath: "/tmp/repo-\(index)",
            workspacePath: "/tmp/ws-\(index)",
            snapshotCommit: String(repeating: "a", count: 40),
            sourceWasDirty: false
        )
    }

    func testRefreshLoadsSessionsSelectsTheFirstAndReadsItsEvents() throws {
        let (fixture, sessions) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.refresh()

        XCTAssertEqual(Set(fixture.model.sessions.map(\.id)), Set(sessions.map(\.id)))
        XCTAssertEqual(fixture.model.selectedSessionID, fixture.model.sessions.first?.id)
        XCTAssertEqual(fixture.model.events.count, fixture.model.selectedSessionID == sessions[0].id ? 5 : 0)
        XCTAssertNil(fixture.model.errorMessage)
    }

    func testRefreshingUnchangedDataNotifiesNoObserver() throws {
        let (fixture, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model
        model.refresh()

        var notified = false
        withObservationTracking({
            _ = model.sessions
            _ = model.events
            _ = model.memorySnapshot
            _ = model.projectMemoryHandoffs
            _ = model.taskRecords
            _ = model.autonomousRuns
        }, onChange: { notified = true })
        model.refresh()
        XCTAssertFalse(notified, "Reloading identical data must not invalidate the views that read it.")
    }

    func testBackgroundRefreshReturnsQuicklyAndThenAppliesTheSameData() async throws {
        let (fixture, sessions) = try makeFixture(sessions: 1_500, events: 20_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model
        model.selectedSessionID = sessions[0].id

        let started = Date()
        model.refreshInBackground()
        let blocked = Date().timeIntervalSince(started)
        XCTAssertLessThan(blocked, 0.03, "Starting a background refresh must not do the disk reads on the main thread.")

        let deadline = Date().addingTimeInterval(20)
        while model.events.count < 20_000, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(model.sessions.count, 1_500)
        XCTAssertEqual(model.events.count, 20_000)
    }

    func testApplyingAnUnchangedLargeResultStaysCheapOnTheMainThread() throws {
        let (fixture, sessions) = try makeFixture(sessions: 1_500, events: 20_000)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model
        model.selectedSessionID = sessions[0].id
        model.refresh()

        let reads = RefreshReads.load(service: fixture.service, selectedSessionID: model.selectedSessionID)
        var worst: TimeInterval = 0
        for _ in 0..<5 {
            let started = Date()
            model.finishBackgroundRefresh(reads, loadedAt: model.refreshGeneration)
            worst = max(worst, Date().timeIntervalSince(started))
        }
        print("APPLY-COST worst main-thread time to apply an unchanged 1500-session / 20000-event result: \(String(format: "%.1f", worst * 1000)) ms")
        XCTAssertLessThan(worst, 0.06)
    }

    func testAResultLoadedBeforeASynchronousRefreshIsDropped() throws {
        let (fixture, sessions) = try makeFixture(sessions: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model
        model.refresh()
        XCTAssertEqual(model.sessions.count, 2)

        // A background read that started now...
        let staleReads = RefreshReads.load(service: fixture.service, selectedSessionID: model.selectedSessionID)
        let loadedAt = model.refreshGeneration
        // ...then the user creates a session and a synchronous refresh applies it.
        try fixture.store.saveSessions(sessions + [makeSession(9)])
        model.refresh()
        XCTAssertEqual(model.sessions.count, 3)

        model.finishBackgroundRefresh(staleReads, loadedAt: loadedAt)
        XCTAssertEqual(model.sessions.count, 3, "An older background result must not overwrite newer data.")
    }

    func testEventsReadForAnotherSessionAreNotApplied() throws {
        let (fixture, sessions) = try makeFixture(sessions: 2, events: 4)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model
        model.refresh()
        let other = try XCTUnwrap(model.sessions.first(where: { $0.id != sessions[0].id }))

        // Reads made for the first session arrive after the selection moved.
        let reads = RefreshReads.load(service: fixture.service, selectedSessionID: sessions[0].id)
        model.selectedSessionID = other.id
        model.events = []
        model.finishBackgroundRefresh(reads, loadedAt: model.refreshGeneration)
        XCTAssertTrue(model.events.isEmpty, "Events of a session that is no longer selected must not be shown.")
    }

    func testOnlyOneBackgroundRefreshRunsAtATime() async throws {
        let (fixture, _) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.model
        model.refreshInBackground()
        model.refreshInBackground()
        model.refreshInBackground()
        let deadline = Date().addingTimeInterval(10)
        while model.sessions.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(model.sessions.count, 3)
    }
}

@MainActor
final class CLICompatibilityWarningTests: XCTestCase {
    private func makeModel() throws -> (URL, AppModel) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CompatWarn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("data"), withIntermediateDirectories: true)
        let store = try AuditStore(rootURL: root.appendingPathComponent("state"), workspaceRootURL: root.appendingPathComponent("data"), managedWorkspaceRoots: [])
        return (root, AppModel(store: store, service: try BridgeService(store: store)))
    }

    func testAMatchingCLIShowsNoWarning() throws {
        let (root, model) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.cliCompatibility[.claude] = CLICompatibilityReport(
            provider: .claude, version: "2.1.311", testedVersion: "2.1.311",
            versionStatus: .matchesTested, missingFlags: [], flagsWereChecked: true
        )
        XCTAssertTrue(model.cliCompatibilityWarnings(for: .claude).isEmpty)
        XCTAssertTrue(model.cliCompatibilityWarnings(for: .codex).isEmpty, "No report means nothing to warn about.")
    }

    func testAMissingFlagAndAnOlderVersionAreReported() throws {
        let (root, model) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.cliCompatibility[.codex] = CLICompatibilityReport(
            provider: .codex, version: "0.100.0", testedVersion: "0.166.0",
            versionStatus: .olderThanTested, missingFlags: ["--ephemeral"], flagsWereChecked: true
        )
        let lines = model.cliCompatibilityWarnings(for: .codex)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("0.100.0") && lines[0].contains("0.166.0"), lines[0])
        XCTAssertTrue(lines[1].contains("--ephemeral"), lines[1])
    }

    func testANewerCLIIsNotAWarning() throws {
        let (root, model) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.cliCompatibility[.claude] = CLICompatibilityReport(
            provider: .claude, version: "9.0.0", testedVersion: "2.1.311",
            versionStatus: .newerThanTested, missingFlags: [], flagsWereChecked: true
        )
        XCTAssertTrue(model.cliCompatibilityWarnings(for: .claude).isEmpty)
    }
}
