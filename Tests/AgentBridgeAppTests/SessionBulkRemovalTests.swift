import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// Filtering the session lists and removing several sessions at once.
@MainActor
final class SessionBulkRemovalTests: XCTestCase {
    // MARK: Grouping

    private func record(_ provider: AgentProvider = .codex) -> SessionRecord {
        SessionRecord(
            provider: provider,
            sourceRepositoryPath: "/work/repo",
            workspacePath: "/data/workspaces/\(UUID().uuidString)",
            snapshotCommit: "0123456789abcdef",
            sourceWasDirty: false
        )
    }

    func testGroupingSortsSessionsIntoSafeMayLoseWorkAndBlocked() {
        let safe = record(), risky = record(), blocked = record(), unchecked = record()
        let review = SessionBulkRemovalReview(
            sessions: [safe, risky, blocked, unchecked],
            previews: [
                safe.id: SessionRemovalPreview(sessionID: safe.id, workspacePath: safe.workspacePath, workspaceExists: true),
                risky.id: SessionRemovalPreview(sessionID: risky.id, workspacePath: risky.workspacePath, workspaceExists: true, changedPaths: ["draft.txt"]),
                blocked.id: SessionRemovalPreview(sessionID: blocked.id, workspacePath: blocked.workspacePath, workspaceExists: true)
            ],
            blockers: [blocked.id: "Stop the session before removing it."]
        )
        XCTAssertEqual(review.safe.map(\.id), [safe.id])
        XCTAssertEqual(review.mayLoseWork.map(\.id), [risky.id])
        XCTAssertEqual(review.removable.map(\.id), [safe.id, risky.id])
        XCTAssertEqual(review.blocked.map(\.id), [blocked.id, unchecked.id])
        XCTAssertEqual(review.blocked.first?.reason, "Stop the session before removing it.")
        XCTAssertEqual(review.blocked.last?.reason, "AgentBridge could not check what removing this session would delete.")
    }

    func testAPreviewForAnotherSessionIsNotUsed() {
        let session = record(), other = record()
        let review = SessionBulkRemovalReview(
            sessions: [session],
            previews: [session.id: SessionRemovalPreview(sessionID: other.id, workspacePath: other.workspacePath, workspaceExists: true)],
            blockers: [:]
        )
        XCTAssertTrue(review.removable.isEmpty)
        XCTAssertEqual(review.blocked.map(\.id), [session.id])
    }

    func testTheSummaryCountsRemovalsAndListsFailuresInTheAppLanguage() throws {
        let model = try makeTestAppModel()
        XCTAssertEqual(model.bulkSessionRemovalSummary(removed: 3, attempted: 3, notRemovable: 0, failures: []), "Removed 3 of 3 sessions.")
        let english = model.bulkSessionRemovalSummary(
            removed: 1, attempted: 2, notRemovable: 1,
            failures: [(label: "Codex · repo · 0123456789ab", message: "Boom.")]
        )
        XCTAssertEqual(english, """
        Removed 1 of 2 sessions.
        Sessions left in place because they could not be removed now: 1.
        Could not remove Codex · repo · 0123456789ab: Boom.
        """)

        let previousLanguage = model.appLanguage
        model.appLanguage = .traditionalChinese
        defer { model.appLanguage = previousLanguage }
        let chinese = model.bulkSessionRemovalSummary(removed: 1, attempted: 2, notRemovable: 0, failures: [])
        XCTAssertEqual(chinese, "已移除 1 個工作階段（共 2 個）。")
    }

    // MARK: Filter and selection

    func testTheListsShowOnlyMatchingSessionsAndSelectAllTakesOnlyThoseShown() throws {
        let codex = record(.codex), claude = record(.claude), local = record(.local)
        let model = try makeTestAppModel(sessions: [codex, claude, local])
        XCTAssertEqual(Set(model.filteredSessions.map(\.id)), [codex.id, claude.id, local.id])

        model.sessionFilter.provider = .claude
        XCTAssertEqual(model.filteredSessions.map(\.id), [claude.id])

        model.setSelectingSessions(true)
        model.toggleSessionSelectedForRemoval(codex.id)
        model.selectAllShownSessions()
        // The hidden Codex session stays selected but is not acted on.
        XCTAssertEqual(model.sessionsSelectedForRemoval, [codex.id, claude.id])
        XCTAssertEqual(model.shownSessionsSelectedForRemoval.map(\.id), [claude.id])
        XCTAssertTrue(model.canReviewBulkSessionRemoval)

        model.clearSessionFilter()
        XCTAssertFalse(model.sessionFilter.isActive)
        model.setSelectingSessions(false)
        XCTAssertTrue(model.sessionsSelectedForRemoval.isEmpty)
        XCTAssertFalse(model.canReviewBulkSessionRemoval)
    }

    // MARK: End to end

    func testBulkRemovalGroupsReviewsAndRemovesTheRemovableSessions() async throws {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        let source = try makeSourceRepository()
        let clean = try await service.createSession(sourcePath: source.path, provider: .codex, accessMode: .interactiveManualApproval)
        let dirty = try await service.createSession(sourcePath: source.path, provider: .claude, accessMode: .interactiveManualApproval)
        try Data("draft\n".utf8).write(to: URL(fileURLWithPath: dirty.workspacePath).appendingPathComponent("draft.txt"))
        model.refresh()
        model.selectedSessionID = clean.id

        model.setSelectingSessions(true)
        model.selectAllShownSessions()
        model.reviewBulkSessionRemoval()
        try await waitUntil { model.bulkSessionRemovalReview != nil && !model.isRemovingSession }
        let review = try XCTUnwrap(model.bulkSessionRemovalReview)
        XCTAssertEqual(review.safe.map(\.id), [clean.id])
        XCTAssertEqual(review.mayLoseWork.map(\.id), [dirty.id])
        XCTAssertTrue(review.blocked.isEmpty)
        let details = model.sessionRemovalDetails(try XCTUnwrap(review.mayLoseWork.first).preview).joined(separator: "\n")
        XCTAssertTrue(details.contains("• draft.txt"), details)
        XCTAssertNil(model.bulkSessionRemovalProgress)

        model.confirmBulkSessionRemoval()
        try await waitUntil { !model.isRemovingSession && model.sessions.isEmpty }
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.status, "Removed 2 of 2 sessions.")
        XCTAssertTrue(model.sessionsSelectedForRemoval.isEmpty)
        XCTAssertNil(model.selectedSessionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: clean.workspacePath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dirty.workspacePath))
    }

    func testABlockedSessionIsShownButNotRemoved() async throws {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        let source = try makeSourceRepository()
        let open = try await service.createSession(sourcePath: source.path, provider: .codex, accessMode: .interactiveManualApproval)
        let other = try await service.createSession(sourcePath: source.path, provider: .codex, accessMode: .interactiveManualApproval)
        model.refresh()
        model.selectedSessionID = open.id
        model.terminal.openLocalShell()
        defer { model.terminal.closeEmbeddedTerminal() }

        model.setSelectingSessions(true)
        model.selectAllShownSessions()
        model.reviewBulkSessionRemoval()
        try await waitUntil { model.bulkSessionRemovalReview != nil && !model.isRemovingSession }
        let review = try XCTUnwrap(model.bulkSessionRemovalReview)
        XCTAssertEqual(review.blocked.map(\.id), [open.id])
        XCTAssertEqual(review.blocked.first?.reason, "Close the terminal for this session before removing it.")
        XCTAssertEqual(review.removable.map(\.id), [other.id])

        model.confirmBulkSessionRemoval()
        try await waitUntil { !model.isRemovingSession && !model.sessions.contains { $0.id == other.id } }
        XCTAssertTrue(model.sessions.contains { $0.id == open.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: open.workspacePath))
        XCTAssertEqual(model.status, "Removed 1 of 1 sessions.\nSessions left in place because they could not be removed now: 1.")
    }

    // MARK: - Fixture

    private struct Timeout: Error {}

    private func makeSourceRepository() throws -> URL {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionBulkRemovalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        try Data("original\n".utf8).write(to: source.appendingPathComponent("source.txt"))
        try runFixtureGit(["init", "-q", source.path])
        try runFixtureGit(["-C", source.path, "add", "source.txt"])
        try runFixtureGit(["-C", source.path, "commit", "-q", "-m", "initial"])
        return source
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw Timeout() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
