import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// Removing a session from the app: review what it deletes, then remove.
@MainActor
final class SessionRemovalFlowTests: XCTestCase {
    func testReviewingThenConfirmingRemovesTheSessionAndClearsTheSelection() async throws {
        let (model, session) = try await makeModelWithInteractiveSession()
        model.selectedSessionID = session.id

        model.reviewSessionRemoval(session.id)
        try await waitUntil { model.sessionRemovalPreview != nil }
        let preview = try XCTUnwrap(model.sessionRemovalPreview)
        XCTAssertFalse(preview.mayLoseWork)
        XCTAssertNil(model.errorMessage)

        model.confirmSessionRemoval()
        try await waitUntil { !model.isRemovingSession && !model.sessions.contains { $0.id == session.id } }
        XCTAssertNil(model.errorMessage)
        XCTAssertNotEqual(model.selectedSessionID, session.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.workspacePath))
    }

    func testCancellingKeepsTheSession() async throws {
        let (model, session) = try await makeModelWithInteractiveSession()
        model.reviewSessionRemoval(session.id)
        try await waitUntil { model.sessionRemovalPreview != nil }
        model.cancelSessionRemoval()
        XCTAssertNil(model.sessionRemovalPreview)
        XCTAssertTrue(model.sessions.contains { $0.id == session.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.workspacePath))
    }

    func testAnOpenTerminalInTheWorkspaceBlocksRemoval() async throws {
        let (model, session) = try await makeModelWithInteractiveSession()
        model.selectedSessionID = session.id
        model.terminal.openLocalShell()
        defer { model.terminal.closeEmbeddedTerminal() }

        model.reviewSessionRemoval(session.id)
        XCTAssertEqual(model.errorMessage, "Close the terminal for this session before removing it.")
        XCTAssertNil(model.sessionRemovalPreview)
        XCTAssertFalse(model.isRemovingSession)
    }

    func testTheMessageListsUnsavedWorkInTheAppLanguage() async throws {
        let (model, session) = try await makeModelWithInteractiveSession()
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true)
        try Data("draft\n".utf8).write(to: workspace.appendingPathComponent("draft.txt"))
        model.reviewSessionRemoval(session.id)
        try await waitUntil { model.sessionRemovalPreview != nil }
        let preview = try XCTUnwrap(model.sessionRemovalPreview)

        let english = model.sessionRemovalMessage(preview)
        XCTAssertTrue(english.contains("Files that differ from what the source repository has (1):\n• draft.txt"), english)
        XCTAssertTrue(english.contains("Anything listed here is lost. Removal cannot be undone."), english)

        let previousLanguage = model.appLanguage
        model.appLanguage = .traditionalChinese
        defer { model.appLanguage = previousLanguage }
        let chinese = model.sessionRemovalMessage(preview)
        XCTAssertTrue(chinese.contains("與來源儲存庫不同的檔案（1 個）：\n• draft.txt"), chinese)
        XCTAssertTrue(chinese.contains("以上列出的內容都會遺失。移除後無法復原。"), chinese)
        XCTAssertFalse(chinese.contains("Anything listed"), chinese)
    }

    // MARK: - Fixture

    private struct Timeout: Error {}

    private func makeModelWithInteractiveSession() async throws -> (AppModel, SessionRecord) {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionRemovalFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        try Data("original\n".utf8).write(to: source.appendingPathComponent("source.txt"))
        try runFixtureGit(["init", "-q", source.path])
        try runFixtureGit(["-C", source.path, "add", "source.txt"])
        try runFixtureGit(["-C", source.path, "commit", "-q", "-m", "initial"])
        let session = try await service.createSession(sourcePath: source.path, provider: .codex, accessMode: .interactiveManualApproval)
        model.refresh()
        return (model, session)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw Timeout() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
