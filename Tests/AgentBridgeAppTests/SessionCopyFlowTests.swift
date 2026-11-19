import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

/// "New Session Like This" and "Try Another Model…" in the App.
@MainActor
final class SessionCopyFlowTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)

    func testDraftStartsFromTheSourceSettings() {
        let profile = UUID()
        let source = record(provider: .claude, access: .isolatedChanges, model: "opus", effort: "max", profile: profile)
        let draft = SessionCopyDraft(source: source, fallbackAccountProfileID: UUID())
        XCTAssertEqual(draft.id, source.id)
        XCTAssertEqual(draft.provider, .claude)
        XCTAssertEqual(draft.accessMode, .isolatedChanges)
        XCTAssertEqual(draft.sourceCommit, commit)
        XCTAssertEqual(draft.modelChoice, ProviderModelChoice(model: "opus", reasoningEffort: "max"))
        XCTAssertEqual(draft.requestedModelChoice, ProviderModelChoice(model: "opus", reasoningEffort: "max"))
        XCTAssertEqual(draft.accountProfileID, profile)
        XCTAssertEqual(draft.commit, .sameAsSource)

        // A source without a bound account starts from the selected one.
        let fallback = UUID()
        XCTAssertEqual(SessionCopyDraft(source: record(provider: .codex, profile: nil), fallbackAccountProfileID: fallback).accountProfileID, fallback)
        // Local sessions have no model choice to send.
        XCTAssertNil(SessionCopyDraft(source: record(provider: .local)).requestedModelChoice)
    }

    func testTryAnotherModelIsOnlyForCodexAndClaude() {
        XCTAssertTrue(SessionCopyPresentation.canTryAnotherModel(record(provider: .codex)))
        XCTAssertTrue(SessionCopyPresentation.canTryAnotherModel(record(provider: .claude)))
        XCTAssertFalse(SessionCopyPresentation.canTryAnotherModel(record(provider: .local)))
    }

    func testComposerPrefillIsOnlyTheSourcePromptForReadOnlyConversations() {
        let source = record(provider: .codex)
        let copy = record(provider: .codex)
        XCTAssertEqual(SessionCopyPresentation.composerPrefill(source: source, newSession: copy, recentPrompts: [source.id: "Explain it."]), "Explain it.")
        XCTAssertNil(SessionCopyPresentation.composerPrefill(source: source, newSession: copy, recentPrompts: [:]))
        XCTAssertNil(SessionCopyPresentation.composerPrefill(source: source, newSession: copy, recentPrompts: [copy.id: "Other session."]))
        XCTAssertNil(SessionCopyPresentation.composerPrefill(source: source, newSession: copy, recentPrompts: [source.id: "  \n"]))
        let changes = record(provider: .codex, access: .isolatedChanges)
        XCTAssertNil(SessionCopyPresentation.composerPrefill(source: changes, newSession: changes, recentPrompts: [changes.id: "Edit it."]))
    }

    func testNewTextIsTranslated() {
        for text in [
            "New Session Like This…", "Try Another Model…", SessionCopyPresentation.sourceHeadLabel, SessionCopyPresentation.notCopiedNote,
            "Session created. Copied the change plan; approve it again before running."
        ] {
            XCTAssertNotEqual(AppLocalization.display(text, language: .traditionalChinese), text, text)
        }
        XCTAssertEqual(AppLocalization.display("Same commit (abc123def456)", language: .traditionalChinese), "相同提交（abc123def456）")
        XCTAssertEqual(
            AppLocalization.display("The new session was created, but the change plan was not copied: This account does not allow shared memory, so the plan cannot include it.", language: .traditionalChinese).hasPrefix("已建立新的工作階段，但未複製變更計畫："),
            true
        )
    }

    func testTheAlertOffersAnotherModelOnlyForTheProviderFailureItShows() throws {
        let codex = record(provider: .codex)
        let local = record(provider: .local)
        let model = try makeTestAppModel(sessions: [codex, local])
        let failure = AgentBridgeError.providerFailed(.codex, "CLI exit code 1. The CLI reported: model not found")
        model.errorMessage = failure.localizedDescription
        model.noteRunFailure(sessionID: codex.id, error: failure)
        XCTAssertEqual(model.sessionForTryAnotherModel?.id, codex.id)
        // Another error shown later is not about that run.
        model.errorMessage = "Something else."
        XCTAssertNil(model.sessionForTryAnotherModel)
        // Errors that are not the provider failing, such as a limit, offer nothing.
        let limit = AgentBridgeError.invalidInput("Up to three different sessions can run at once.")
        model.errorMessage = limit.localizedDescription
        model.noteRunFailure(sessionID: codex.id, error: limit)
        XCTAssertNil(model.sessionForTryAnotherModel)
        let localFailure = AgentBridgeError.providerFailed(.local, "No answer.")
        model.errorMessage = localFailure.localizedDescription
        model.noteRunFailure(sessionID: local.id, error: localFailure)
        XCTAssertNil(model.sessionForTryAnotherModel)
    }

    func testCreatingFromTheSheetOpensTheNewSessionWithTheLastPromptUnsent() async throws {
        let model = try makeTestAppModel()
        let service = try XCTUnwrap(model.service)
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionCopyFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        try Data("original\n".utf8).write(to: source.appendingPathComponent("source.txt"))
        try runFixtureGit(["init", "-q", source.path])
        try runFixtureGit(["-C", source.path, "add", "source.txt"])
        try runFixtureGit(["-C", source.path, "commit", "-q", "-m", "initial"])
        let original = try await service.createSession(
            sourcePath: source.path, provider: .codex, modelChoice: ProviderModelChoice(model: "gpt-test-1")
        )
        model.refresh()
        model.recentProjectPrompts[original.id] = "Explain the build."
        model.prompt = "An unrelated draft."

        model.reviewNewSessionLike(original.id)
        var draft = try XCTUnwrap(model.sessionCopyDraft)
        XCTAssertEqual(draft.modelChoice, ProviderModelChoice(model: "gpt-test-1"))
        draft.modelChoice = ProviderModelChoice(model: "gpt-test-2", reasoningEffort: "low")
        model.sessionCopyDraft = draft
        var opened: UUID?
        model.createSessionFromCopyDraft { opened = $0 }
        try await waitUntil { opened != nil && !model.isCreatingSessionCopy }

        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.sessionCopyDraft)
        let created = try XCTUnwrap(model.sessions.first { $0.id == opened })
        XCTAssertNotEqual(created.id, original.id)
        XCTAssertEqual(created.modelChoice, ProviderModelChoice(model: "gpt-test-2", reasoningEffort: "low"))
        XCTAssertEqual(created.snapshotCommit, original.snapshotCommit)
        XCTAssertEqual(model.prompt, "Explain the build.")
        // Nothing was sent: no run started and nothing reached the audit log as a prompt.
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(try service.events(sessionID: created.id).contains { $0.message.contains("Explain the build.") })

        // Without a remembered prompt the composer is left empty.
        model.prompt = "Another draft."
        model.reviewNewSessionLike(created.id)
        opened = nil
        model.createSessionFromCopyDraft { opened = $0 }
        try await waitUntil { opened != nil && !model.isCreatingSessionCopy }
        XCTAssertEqual(model.prompt, "")
    }

    // MARK: - Helpers

    private struct Timeout: Error {}

    private func record(
        provider: AgentProvider,
        access: AccessMode = .readOnly,
        model: String? = nil,
        effort: String? = nil,
        profile: UUID? = UUID()
    ) -> SessionRecord {
        SessionRecord(
            provider: provider,
            sourceRepositoryPath: "/tmp/repo",
            workspacePath: "/tmp/ws-\(UUID().uuidString)",
            snapshotCommit: commit,
            sourceWasDirty: false,
            policy: SessionPolicy(accessMode: access, workspaceReadOnly: access == .readOnly, apiModeAllowed: false),
            accountProfileID: profile,
            model: model,
            reasoningEffort: effort
        )
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { throw Timeout() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
