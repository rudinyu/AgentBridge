import AgentBridgeCore
import Foundation
import XCTest

final class SessionFilterTests: XCTestCase {
    private func session(
        provider: AgentProvider = .codex,
        repository: String = "/work/Alpha-Repo",
        commit: String = "0123456789abcdef0123456789abcdef01234567",
        status: SessionStatus = .created,
        mode: AccessMode = .readOnly,
        model: String? = nil,
        effort: String? = nil,
        planTitle: String? = nil
    ) -> SessionRecord {
        let id = UUID()
        return SessionRecord(
            id: id,
            provider: provider,
            sourceRepositoryPath: repository,
            workspacePath: "/data/workspaces/\(id.uuidString)",
            snapshotCommit: commit,
            sourceWasDirty: false,
            status: status,
            policy: SessionPolicy(accessMode: mode),
            changePlan: planTitle.map { ChangePlan(sessionID: id, title: $0, summary: "Summary", steps: ["Step"]) },
            model: model,
            reasoningEffort: effort
        )
    }

    func testAnEmptyFilterMatchesEverySessionAndIsNotActive() {
        let filter = SessionFilter(query: "   ")
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.matches(session()))
        XCTAssertTrue(filter.matches(session(provider: .local, status: .failed, mode: .isolatedChanges)))
    }

    func testTheQueryMatchesTheRepositoryFolderNameCaseInsensitively() {
        XCTAssertTrue(SessionFilter(query: "alpha").matches(session()))
        XCTAssertTrue(SessionFilter(query: " ALPHA-repo ").matches(session()))
        // Only the folder name counts, not the rest of the path.
        XCTAssertFalse(SessionFilter(query: "work").matches(session()))
        XCTAssertFalse(SessionFilter(query: "beta").matches(session()))
    }

    func testTheQueryMatchesTheModelAndEffort() {
        let withModel = session(model: "gpt-5.5-codex", effort: "high")
        XCTAssertTrue(SessionFilter(query: "GPT-5.5").matches(withModel))
        XCTAssertTrue(SessionFilter(query: "high").matches(withModel))
        XCTAssertFalse(SessionFilter(query: "gpt").matches(session()))
        // A label only the caller can make, such as the shown model label.
        XCTAssertTrue(SessionFilter(query: "cli default").matches(session(), extraText: ["CLI default · CLI default"]))
    }

    func testTheQueryMatchesACommitPrefixOnly() {
        XCTAssertTrue(SessionFilter(query: "0123ab").matches(session(commit: "0123abcdef")))
        XCTAssertTrue(SessionFilter(query: "0123AB").matches(session(commit: "0123abcdef")))
        XCTAssertFalse(SessionFilter(query: "abcdef").matches(session(commit: "0123abcdef")))
    }

    func testTheQueryMatchesTheChangePlanTitle() {
        let planned = session(planTitle: "Fix the Login Screen")
        XCTAssertTrue(SessionFilter(query: "login screen").matches(planned))
        XCTAssertFalse(SessionFilter(query: "login").matches(session()))
    }

    func testProviderStatusAndModeFilters() {
        let claude = session(provider: .claude, status: .failed, mode: .isolatedChanges)
        XCTAssertTrue(SessionFilter(provider: .claude).matches(claude))
        XCTAssertFalse(SessionFilter(provider: .codex).matches(claude))
        XCTAssertTrue(SessionFilter(status: .failed).matches(claude))
        XCTAssertFalse(SessionFilter(status: .completed).matches(claude))
        XCTAssertTrue(SessionFilter(accessMode: .isolatedChanges).matches(claude))
        XCTAssertFalse(SessionFilter(accessMode: .interactiveManualApproval).matches(claude))
        XCTAssertTrue(SessionFilter(provider: .claude).isActive)
    }

    func testEveryCriterionMustMatch() {
        let target = session(provider: .claude, status: .completed, mode: .interactiveManualApproval, model: "opus")
        let others = [
            session(provider: .codex, status: .completed, mode: .interactiveManualApproval, model: "opus"),
            session(provider: .claude, status: .failed, mode: .interactiveManualApproval, model: "opus"),
            session(provider: .claude, status: .completed, mode: .readOnly, model: "opus"),
            session(provider: .claude, status: .completed, mode: .interactiveManualApproval, model: "sonnet")
        ]
        let filter = SessionFilter(query: "opus", provider: .claude, status: .completed, accessMode: .interactiveManualApproval)
        XCTAssertEqual(filter.apply(to: [target] + others).map(\.id), [target.id])
    }

    func testTheRepositoryFilterComparesResolvedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SessionFilterTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repository)

        let inRepository = session(repository: repository.path)
        XCTAssertTrue(SessionFilter(repositoryPath: link.path).matches(inRepository))
        XCTAssertTrue(SessionFilter(repositoryPath: repository.path + "/").matches(inRepository))
        XCTAssertFalse(SessionFilter(repositoryPath: root.path).matches(inRepository))
    }

    func testTheCommandLineOptionsBuildTheFilter() throws {
        let filter = try SessionFilter.parseCommandLine([
            "--provider", "claude", "--status", "failed", "--mode", "changes", "--repo", "/work/repo"
        ])
        XCTAssertEqual(filter, SessionFilter(provider: .claude, status: .failed, accessMode: .isolatedChanges, repositoryPath: "/work/repo"))
        XCTAssertEqual(try SessionFilter.parseCommandLine([]), SessionFilter())
        XCTAssertEqual(try SessionFilter.parseCommandLine(["--mode", "read-only"]).accessMode, .readOnly)
        XCTAssertEqual(try SessionFilter.parseCommandLine(["--mode", "interactive"]).accessMode, .interactiveManualApproval)
    }

    func testTheCommandLineRejectsUnknownOptionsAndValues() {
        for arguments in [["--provider", "gemini"], ["--status", "done"], ["--mode", "write"], ["--repo"], ["--provider", "--status"], ["--all"]] {
            XCTAssertThrowsError(try SessionFilter.parseCommandLine(arguments), "\(arguments)")
        }
    }
}
