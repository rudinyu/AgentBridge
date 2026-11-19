import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

/// Commit, push and pull request from the apply worktree. Every test uses a local
/// bare repository as the remote and a fake `gh` that records its arguments, so
/// nothing reaches the network or GitHub.
final class PullRequestWorkflowTests: XCTestCase {
    private struct Fixture {
        let rootURL: URL
        let sourceURL: URL
        let remoteURL: URL
        let ghLogURL: URL
        let store: AuditStore
        let service: BridgeService
        let session: SessionRecord
        let snapshot: String
        let branch: String
        let worktreeURL: URL
    }

    // MARK: Preview

    func testPreviewProposesTheRemoteBaseAndTextFromThePlan() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        XCTAssertEqual(preview.branchName, fixture.branch)
        XCTAssertEqual(preview.worktreePath, fixture.worktreeURL.path)
        XCTAssertEqual(preview.remotes, [GitRemote(name: "origin", fetchURL: fixture.remoteURL.path, pushURL: fixture.remoteURL.path)])
        XCTAssertEqual(preview.selectedRemote, "origin")
        XCTAssertEqual(preview.selectedRemoteURL, fixture.remoteURL.path)
        XCTAssertEqual(preview.proposedBase, "master")
        XCTAssertEqual(preview.baseSource, .remoteHead)
        XCTAssertEqual(preview.remoteDefaultBranch, "master")
        XCTAssertEqual(preview.changedFiles, ["new.txt", "old.txt", "source.txt"])
        XCTAssertTrue(preview.worktreeMatchesVerifiedDiff)
        XCTAssertEqual(preview.completedSteps, [])
        XCTAssertEqual(preview.gitHubCLI, .ready(executablePath: fixture.rootURL.appendingPathComponent("bin/gh").path))
        XCTAssertEqual(preview.pullRequestTitle, "Update the source text")
        XCTAssertEqual(preview.commitMessage, """
        Update the source text

        Replace the original line and add a new file.

        Steps:
        1. Edit source.txt
        2. Add new.txt

        Verified with .codex/ci.sh: passed

        """)
        XCTAssertTrue(preview.pullRequestBody.hasPrefix("Replace the original line and add a new file.\n\nSteps:\n1. Edit source.txt"))
        XCTAssertTrue(preview.pullRequestBody.hasSuffix(
            "Opened with AgentBridge; changes were made by Codex in an isolated workspace and verified before this PR.\n"
        ))
        // A preview changes nothing and calls gh only to check sign-in.
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "rev-parse", "HEAD"]), fixture.snapshot)
        XCTAssertEqual(try ghCalls(fixture).map(\.first), ["auth"])

        let requested = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id, remote: "origin", base: "release")
        XCTAssertEqual(requested.proposedBase, "release")
        XCTAssertEqual(requested.baseSource, .requested)
        do {
            _ = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id, remote: "upstream")
            XCTFail("A remote the repository does not have was accepted.")
        } catch AgentBridgeError.invalidInput(let message) {
            XCTAssertTrue(message.contains("no remote named upstream"))
        }
    }

    func testPreviewFallsBackToAnExistingBranchWithoutRemoteHead() async throws {
        let fixture = try await makeAppliedFixture(setRemoteHead: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        XCTAssertEqual(preview.proposedBase, "master")
        XCTAssertEqual(preview.baseSource, .existingBranch)
        XCTAssertNil(preview.remoteDefaultBranch)
    }

    func testPreviewNeedsAnAppliedBranch() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        var session = try XCTUnwrap(fixture.store.session(id: fixture.session.id))
        session.appliedBranchName = nil
        session.appliedWorktreePath = nil
        try fixture.store.saveSession(session)
        do {
            _ = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
            XCTFail("A preview was made without an applied branch.")
        } catch AgentBridgeError.invalidInput(let message) {
            XCTAssertEqual(message, "Apply the verified changes to a local branch first.")
        }
    }

    // MARK: Commit, push, open

    func testOpeningCommitsPushesAndOpensADraftPullRequest() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        let request = try XCTUnwrap(PullRequestRequest(preview: preview))
        XCTAssertTrue(request.draft)

        let steps = StepRecorder()
        let outcome = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: request) { steps.append($0) }
        XCTAssertEqual(steps.values, [.commit, .push, .pullRequest])
        XCTAssertEqual(outcome.steps.map(\.outcome), [.done, .done, .done])
        XCTAssertEqual(outcome.pullRequestURL, "https://github.com/example/repo/pull/7")

        // One commit on the branch, on top of the session's base, with the user's identity.
        let head = try FixtureGit.run(["-C", fixture.worktreeURL.path, "rev-parse", "HEAD"])
        XCTAssertEqual(outcome.commit, head)
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "rev-parse", "HEAD^"]), fixture.snapshot)
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "log", "-1", "--format=%an <%ae>"]), "AgentBridge Tests <agentbridge-tests@example.invalid>")
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "log", "-1", "--format=%B"]), request.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "status", "--porcelain"]), "")
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "show", "--name-status", "--format=", "HEAD"]), "A\tnew.txt\nD\told.txt\nM\tsource.txt")
        // Pushed to the bare remote with an upstream; the source checkout is untouched.
        XCTAssertEqual(try FixtureGit.run(["--git-dir", fixture.remoteURL.path, "rev-parse", "refs/heads/\(fixture.branch)"]), head)
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.sourceURL.path, "config", "branch.\(fixture.branch).remote"]), "origin")
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.sourceURL.path, "rev-parse", "HEAD"]), fixture.snapshot)

        let create = try XCTUnwrap(try ghCalls(fixture).first(where: { $0.starts(with: ["pr", "create"]) }))
        XCTAssertEqual(argument(after: "--base", in: create), "master")
        XCTAssertEqual(argument(after: "--head", in: create), fixture.branch)
        XCTAssertEqual(argument(after: "--title", in: create), "Update the source text")
        XCTAssertTrue(create.contains("--draft"))
        XCTAssertFalse(create.contains("--repo"), "A local remote has no GitHub repository, so gh works it out.")
        XCTAssertEqual(try String(contentsOf: fixture.rootURL.appendingPathComponent("gh-last-body.txt"), encoding: .utf8), request.body)
        XCTAssertTrue(try ghCalls(fixture).contains(["pr", "view", fixture.branch, "--json", "url,state"]))

        let session = try XCTUnwrap(fixture.store.session(id: fixture.session.id))
        XCTAssertEqual(session.appliedCommit, head)
        XCTAssertEqual(session.pushedRemote, "origin")
        XCTAssertNotNil(session.pushedAt)
        XCTAssertEqual(session.pullRequestURL, "https://github.com/example/repo/pull/7")
        let kinds = try fixture.store.events(sessionID: fixture.session.id).map(\.kind)
        XCTAssertTrue(kinds.contains("change.pr.committed"))
        XCTAssertTrue(kinds.contains("change.pr.pushed"))
        XCTAssertTrue(kinds.contains("change.pr.opened"))
        XCTAssertFalse(kinds.contains("change.pr.failed"))

        let after = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        XCTAssertEqual(after.completedSteps, [.commit, .push, .pullRequest])
        XCTAssertTrue(after.worktreeMatchesVerifiedDiff)
    }

    func testDraftCanBeTurnedOff() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        let request = try XCTUnwrap(PullRequestRequest(preview: preview, draft: false))
        _ = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: request)
        let create = try XCTUnwrap(try ghCalls(fixture).first(where: { $0.starts(with: ["pr", "create"]) }))
        XCTAssertFalse(create.contains("--draft"))
    }

    func testAWorktreeChangedAfterVerificationIsNotCommitted() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try Data("edited after verification\n".utf8).write(to: fixture.worktreeURL.appendingPathComponent("source.txt"))
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        XCTAssertFalse(preview.worktreeMatchesVerifiedDiff)

        do {
            _ = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: try XCTUnwrap(PullRequestRequest(preview: preview)))
            XCTFail("A worktree that differs from the verified diff was committed.")
        } catch AgentBridgeError.pullRequestStepFailed(let step, let reason) {
            XCTAssertEqual(step, .commit)
            XCTAssertTrue(reason.contains("differs from the verified changes"), reason)
        }
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "rev-parse", "HEAD"]), fixture.snapshot)
        XCTAssertNotEqual(try FixtureGit.exitStatus(["--git-dir", fixture.remoteURL.path, "rev-parse", "--verify", "refs/heads/\(fixture.branch)"]), 0)
        XCTAssertFalse(try ghCalls(fixture).contains(where: { $0.first == "pr" }))
        XCTAssertNil(try fixture.store.session(id: fixture.session.id)?.appliedCommit)
        XCTAssertTrue(try fixture.store.events(sessionID: fixture.session.id).contains { $0.kind == "change.pr.failed" })
    }

    func testAnExtraFileInTheWorktreeIsNotCommitted() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try Data("not verified\n".utf8).write(to: fixture.worktreeURL.appendingPathComponent("extra.txt"))
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        do {
            _ = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: try XCTUnwrap(PullRequestRequest(preview: preview)))
            XCTFail("An unverified file was committed.")
        } catch AgentBridgeError.pullRequestStepFailed(let step, _) {
            XCTAssertEqual(step, .commit)
        }
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "rev-parse", "HEAD"]), fixture.snapshot)
    }

    func testPushingIntoTheBaseBranchIsRefused() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        var request = try XCTUnwrap(PullRequestRequest(preview: preview))
        request.base = fixture.branch
        do {
            _ = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: request)
            XCTFail("The branch was pushed as its own base.")
        } catch AgentBridgeError.invalidInput(let message) {
            XCTAssertTrue(message.contains("is the base branch"))
        }
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "rev-parse", "HEAD"]), fixture.snapshot)
    }

    func testPushingTheRemoteDefaultBranchIsRefused() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        // The remote's HEAD now names the applied branch.
        try FixtureGit.run(["-C", fixture.sourceURL.path, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/\(fixture.branch)"])
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id, base: "master")
        do {
            _ = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: try XCTUnwrap(PullRequestRequest(preview: preview)))
            XCTFail("The remote's default branch was pushed.")
        } catch AgentBridgeError.invalidInput(let message) {
            XCTAssertTrue(message.contains("remote's default branch"))
        }
    }

    func testAnExistingPullRequestIsRecordedInsteadOfOpeningAnother() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try Data(#"{"state":"OPEN","url":"https://github.com/example/repo/pull/3"}"#.utf8)
            .write(to: fixture.rootURL.appendingPathComponent("gh-existing-pr.json"))
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        let outcome = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: try XCTUnwrap(PullRequestRequest(preview: preview)))
        XCTAssertEqual(outcome.pullRequestURL, "https://github.com/example/repo/pull/3")
        XCTAssertEqual(outcome.steps.last?.outcome, .reusedExisting)
        XCTAssertFalse(try ghCalls(fixture).contains(where: { $0.starts(with: ["pr", "create"]) }))
        XCTAssertEqual(try fixture.store.session(id: fixture.session.id)?.pullRequestURL, "https://github.com/example/repo/pull/3")
    }

    func testAClosedPullRequestForTheBranchIsNotReused() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try Data(#"{"state":"MERGED","url":"https://github.com/example/repo/pull/3"}"#.utf8)
            .write(to: fixture.rootURL.appendingPathComponent("gh-existing-pr.json"))
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        let outcome = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: try XCTUnwrap(PullRequestRequest(preview: preview)))
        XCTAssertEqual(outcome.pullRequestURL, "https://github.com/example/repo/pull/7")
    }

    func testARetryAfterAFailedPushContinuesWithoutASecondCommit() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        let request = try XCTUnwrap(PullRequestRequest(preview: preview))
        let missingRemote = fixture.rootURL.appendingPathComponent("missing-remote.git").path
        try FixtureGit.run(["-C", fixture.sourceURL.path, "remote", "set-url", "origin", missingRemote])
        do {
            _ = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: request)
            XCTFail("The push to a missing remote succeeded.")
        } catch AgentBridgeError.pullRequestStepFailed(let step, let reason) {
            XCTAssertEqual(step, .push)
            XCTAssertTrue(reason.contains("git exited with code"), reason)
        }
        let afterFailure = try XCTUnwrap(fixture.store.session(id: fixture.session.id))
        let commit = try XCTUnwrap(afterFailure.appliedCommit)
        XCTAssertNil(afterFailure.pushedRemote)
        let previewAfterFailure = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        XCTAssertEqual(previewAfterFailure.completedSteps, [.commit])
        XCTAssertTrue(try fixture.store.events(sessionID: fixture.session.id).contains {
            $0.kind == "change.pr.failed" && $0.message.hasPrefix("The push step failed")
        })

        try FixtureGit.run(["-C", fixture.sourceURL.path, "remote", "set-url", "origin", fixture.remoteURL.path])
        let outcome = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: request)
        XCTAssertEqual(outcome.steps.map(\.outcome), [.alreadyDone, .done, .done])
        XCTAssertEqual(outcome.commit, commit)
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "rev-list", "--count", "\(fixture.snapshot)..HEAD"]), "1")
        XCTAssertEqual(try FixtureGit.run(["--git-dir", fixture.remoteURL.path, "rev-parse", "refs/heads/\(fixture.branch)"]), commit)

        // Everything is done, so a third run repeats nothing.
        let again = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: request)
        XCTAssertEqual(again.steps.map(\.outcome), [.alreadyDone, .alreadyDone, .alreadyDone])
        XCTAssertEqual(try ghCalls(fixture).filter { $0.starts(with: ["pr", "create"]) }.count, 1)
    }

    func testABranchThatMovedAfterTheCommitIsNotPushed() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        let request = try XCTUnwrap(PullRequestRequest(preview: preview))
        try FixtureGit.run(["-C", fixture.sourceURL.path, "remote", "set-url", "origin", fixture.rootURL.appendingPathComponent("missing.git").path])
        _ = try? await fixture.service.openPullRequest(sessionID: fixture.session.id, request: request)
        try FixtureGit.run(["-C", fixture.sourceURL.path, "remote", "set-url", "origin", fixture.remoteURL.path])
        try FixtureGit.run(["-C", fixture.worktreeURL.path, "commit", "-q", "--allow-empty", "-m", "someone else"])
        do {
            _ = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: request)
            XCTFail("A branch that moved was pushed.")
        } catch AgentBridgeError.pullRequestStepFailed(let step, let reason) {
            XCTAssertEqual(step, .commit)
            XCTAssertTrue(reason.contains("moved after AgentBridge committed"), reason)
        }
        XCTAssertNotEqual(try FixtureGit.exitStatus(["--git-dir", fixture.remoteURL.path, "rev-parse", "--verify", "refs/heads/\(fixture.branch)"]), 0)
    }

    func testAMissingGitHubCLIStopsBeforeAnythingIsCommitted() async throws {
        let fixture = try await makeAppliedFixture(installGitHubCLI: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        XCTAssertEqual(preview.gitHubCLI, .notInstalled)
        do {
            _ = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: try XCTUnwrap(PullRequestRequest(preview: preview)))
            XCTFail("The flow ran without gh.")
        } catch AgentBridgeError.invalidInput(let message) {
            XCTAssertTrue(message.contains("brew install gh"), message)
        }
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "rev-parse", "HEAD"]), fixture.snapshot)
    }

    func testAGitHubCLIThatIsNotSignedInStopsBeforeAnythingIsCommitted() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try Data().write(to: fixture.rootURL.appendingPathComponent("gh-signed-out"))
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        XCTAssertEqual(preview.gitHubCLI, .notAuthenticated(executablePath: fixture.rootURL.appendingPathComponent("bin/gh").path))
        do {
            _ = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: try XCTUnwrap(PullRequestRequest(preview: preview)))
            XCTFail("The flow ran with gh signed out.")
        } catch AgentBridgeError.invalidInput(let message) {
            XCTAssertTrue(message.contains("gh auth login"), message)
        }
        XCTAssertEqual(try FixtureGit.run(["-C", fixture.worktreeURL.path, "rev-parse", "HEAD"]), fixture.snapshot)
        XCTAssertFalse(try ghCalls(fixture).contains(where: { $0.first != "auth" }))
    }

    func testApplyingAgainStartsTheProgressOver() async throws {
        let fixture = try await makeAppliedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let preview = try await fixture.service.pullRequestPreview(sessionID: fixture.session.id)
        _ = try await fixture.service.openPullRequest(sessionID: fixture.session.id, request: try XCTUnwrap(PullRequestRequest(preview: preview)))
        let result = try await fixture.service.applyChangesToLocalBranch(sessionID: fixture.session.id, branchName: "agentbridge/second")
        let session = try XCTUnwrap(fixture.store.session(id: fixture.session.id))
        XCTAssertEqual(session.appliedBranchName, "agentbridge/second")
        XCTAssertEqual(session.appliedWorktreePath, result.worktreePath)
        XCTAssertNil(session.appliedCommit)
        XCTAssertNil(session.pushedRemote)
        XCTAssertNil(session.pushedAt)
        XCTAssertNil(session.pullRequestURL)
    }

    // MARK: Pure helpers

    func testGitHubRepositoryIsReadFromCommonRemoteURLs() {
        let expected = BridgeService.GitHubRepository(host: "github.com", owner: "octo", name: "app")
        XCTAssertEqual(BridgeService.gitHubRepository(fromRemoteURL: "git@github.com:octo/app.git"), expected)
        XCTAssertEqual(BridgeService.gitHubRepository(fromRemoteURL: "https://github.com/octo/app.git"), expected)
        XCTAssertEqual(BridgeService.gitHubRepository(fromRemoteURL: "https://github.com/octo/app"), expected)
        XCTAssertEqual(BridgeService.gitHubRepository(fromRemoteURL: "ssh://git@ssh.github.com:443/octo/app.git"), expected)
        XCTAssertEqual(expected.argument, "octo/app")
        XCTAssertEqual(BridgeService.gitHubRepository(fromRemoteURL: "git@github.example.com:team/tool.git")?.argument, "github.example.com/team/tool")
        XCTAssertNil(BridgeService.gitHubRepository(fromRemoteURL: "/Users/me/remote.git"))
        XCTAssertNil(BridgeService.gitHubRepository(fromRemoteURL: "https://gitlab.com/octo/app.git"))
        XCTAssertNil(BridgeService.gitHubRepository(fromRemoteURL: "https://github.com/octo/app/extra"))
    }

    func testRemoteURLCredentialsAreNotShown() {
        XCTAssertEqual(BridgeService.withoutCredentials("https://user:secret@github.com/octo/app.git"), "https://github.com/octo/app.git")
        XCTAssertEqual(BridgeService.withoutCredentials("git@github.com:octo/app.git"), "git@github.com:octo/app.git")
        XCTAssertEqual(BridgeService.withoutCredentials("/Users/me/remote.git"), "/Users/me/remote.git")
        XCTAssertFalse(BridgeService.publishingErrorSummary(Data("fatal: unable to access 'https://user:secret@github.com/x/y.git/'\n".utf8)).contains("secret"))
    }

    func testPullRequestURLIsTheLastOneGHPrints() {
        XCTAssertEqual(
            BridgeService.pullRequestURL(in: "Creating draft pull request\nhttps://github.com/octo/app/pull/12\n"),
            "https://github.com/octo/app/pull/12"
        )
        XCTAssertNil(BridgeService.pullRequestURL(in: "Warning: 1 uncommitted change\n"))
        XCTAssertNil(BridgeService.pullRequestURL(in: "http://github.com/octo/app/pull/12"))
    }

    func testPublishingEnvironmentPassesCredentialsHelpersNeedAndNothingElse() throws {
        let root = try canonicalFixtureParent().appendingPathComponent("PullRequestEnv-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["state", "data"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let store = try AuditStore(rootURL: root.appendingPathComponent("state"), workspaceRootURL: root.appendingPathComponent("data"), managedWorkspaceRoots: [])
        let service = try BridgeService(store: store, baseEnvironment: [
            "HOME": "/Users/example",
            "PATH": "/custom/bin:relative/bin:/usr/bin",
            "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
            "GH_TOKEN": "gho_example",
            "GH_CONFIG_DIR": "/Users/example/.config/gh",
            "HTTPS_PROXY": "http://proxy.example:8080",
            "GIT_DIR": "/somewhere/else",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "ANTHROPIC_API_KEY": "sk-ant-example",
            "OPENAI_API_KEY": "sk-example"
        ])
        let environment = service.publishingEnvironment(temporaryDirectory: URL(fileURLWithPath: "/private/tmp/publish"))
        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["SSH_AUTH_SOCK"], "/private/tmp/agent.sock")
        XCTAssertEqual(environment["GH_TOKEN"], "gho_example")
        XCTAssertEqual(environment["GH_CONFIG_DIR"], "/Users/example/.config/gh")
        XCTAssertEqual(environment["HTTPS_PROXY"], "http://proxy.example:8080")
        XCTAssertEqual(environment["TMPDIR"], "/private/tmp/publish")
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(environment["GH_PROMPT_DISABLED"], "1")
        XCTAssertEqual(environment["PATH"], "/custom/bin:/usr/bin:/opt/homebrew/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(environment["GIT_DIR"])
        XCTAssertNil(environment["GIT_CONFIG_GLOBAL"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
    }

    // MARK: Older records

    func testRecordsWithoutTheNewFieldsDecodeAndEncodeUnchanged() throws {
        let old = """
        {"accountProfileID":null,"createdAt":"2026-01-01T00:00:00Z","id":"00000000-0000-0000-0000-000000000031",\
        "policy":{"accessMode":"isolatedChanges","apiModeAllowed":false,"workspaceReadOnly":false},"provider":"codex",\
        "snapshotCommit":"\(String(repeating: "b", count: 40))","sourceRepositoryPath":"/tmp/repo","sourceWasDirty":false,\
        "status":"created","updatedAt":"2026-01-01T00:00:00Z","verificationPassed":true,"workspacePath":"/tmp/ws"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(SessionRecord.self, from: Data(old.utf8))
        XCTAssertNil(session.appliedBranchName)
        XCTAssertNil(session.appliedWorktreePath)
        XCTAssertNil(session.appliedCommit)
        XCTAssertNil(session.pushedRemote)
        XCTAssertNil(session.pushedAt)
        XCTAssertNil(session.pullRequestURL)
        XCTAssertNil(session.verificationCommandLabel)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = String(decoding: try encoder.encode(session), as: UTF8.self)
        // Nil fields are left out, so an older record is written back as it was.
        let withoutNulls = old.replacingOccurrences(of: #""accountProfileID":null,"#, with: "")
        XCTAssertEqual(encoded, withoutNulls)

        var progressed = session
        progressed.appliedBranchName = "agentbridge/x"
        progressed.appliedWorktreePath = "/tmp/apply"
        progressed.appliedCommit = String(repeating: "c", count: 40)
        progressed.pushedRemote = "origin"
        progressed.pushedAt = Date(timeIntervalSince1970: 1_800_000_000)
        progressed.pullRequestURL = "https://github.com/octo/app/pull/1"
        progressed.verificationCommandLabel = ".codex/ci.sh"
        XCTAssertEqual(try decoder.decode(SessionRecord.self, from: try encoder.encode(progressed)), progressed)
    }

    // MARK: Fixture

    private final class StepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var steps: [PullRequestStep] = []
        func append(_ step: PullRequestStep) { lock.lock(); steps.append(step); lock.unlock() }
        var values: [PullRequestStep] { lock.lock(); defer { lock.unlock() }; return steps }
    }

    /// Each gh call's arguments, in order.
    private func ghCalls(_ fixture: Fixture) throws -> [[String]] {
        guard FileManager.default.fileExists(atPath: fixture.ghLogURL.path) else { return [] }
        return try String(contentsOf: fixture.ghLogURL, encoding: .utf8)
            .components(separatedBy: "\u{1E}\n")
            .filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\u{1F}").filter { !$0.isEmpty } }
    }

    private func argument(after flag: String, in call: [String]) -> String? {
        guard let index = call.firstIndex(of: flag), index + 1 < call.count else { return nil }
        return call[index + 1]
    }

    private func canonicalFixtureParent() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtureParent = packageRoot.appendingPathComponent("build/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureParent, withIntermediateDirectories: true)
        guard let resolvedPath = fixtureParent.path.withCString({ realpath($0, nil) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(resolvedPath) }
        return URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
    }

    private func makeAppliedFixture(setRemoteHead: Bool = true, installGitHubCLI: Bool = true) async throws -> Fixture {
        let root = try canonicalFixtureParent()
            .appendingPathComponent("AgentBridge-PullRequest-\(UUID().uuidString.lowercased())", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let workspaces = root.appendingPathComponent("workspace-data", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for directory in [source, state, workspaces, home, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Data("original\n".utf8).write(to: source.appendingPathComponent("source.txt"))
        try Data("to be removed\n".utf8).write(to: source.appendingPathComponent("old.txt"))
        try FixtureGit.run(["init", "-q", "--initial-branch=master", source.path])
        try FixtureGit.run(["-C", source.path, "config", "user.name", "AgentBridge Tests"])
        try FixtureGit.run(["-C", source.path, "config", "user.email", "agentbridge-tests@example.invalid"])
        try FixtureGit.run(["-C", source.path, "add", "source.txt", "old.txt"])
        try FixtureGit.run(["-C", source.path, "commit", "-q", "-m", "initial"])
        try FixtureGit.run(["init", "-q", "--bare", "--initial-branch=master", remote.path])
        try FixtureGit.run(["-C", source.path, "remote", "add", "origin", remote.path])
        try FixtureGit.run(["-C", source.path, "push", "-q", "origin", "master"])
        try FixtureGit.run(["-C", source.path, "fetch", "-q", "origin"])
        if setRemoteHead {
            try FixtureGit.run(["-C", source.path, "remote", "set-head", "origin", "master"])
        } else {
            // Newer Git records the remote's HEAD on fetch; older clones may not have it.
            _ = try FixtureGit.exitStatus(["-C", source.path, "remote", "set-head", "origin", "--delete"])
        }
        let snapshot = try FixtureGit.run(["-C", source.path, "rev-parse", "HEAD"])

        let ghLog = root.appendingPathComponent("gh-calls.log")
        if installGitHubCLI {
            let script = """
            #!/bin/sh
            for argument in "$@"; do printf '%s\\037' "$argument" >> '\(ghLog.path)'; done
            printf '\\036\\n' >> '\(ghLog.path)'
            case "$1 $2" in
            "auth status") [ -e '\(root.path)/gh-signed-out' ] && exit 1; exit 0 ;;
            "pr view") [ -e '\(root.path)/gh-existing-pr.json' ] || exit 1; cat '\(root.path)/gh-existing-pr.json'; exit 0 ;;
            "pr create")
              while [ $# -gt 0 ]; do
                if [ "$1" = "--body-file" ]; then cp "$2" '\(root.path)/gh-last-body.txt'; fi
                shift
              done
              echo "https://github.com/example/repo/pull/7"; exit 0 ;;
            esac
            exit 1
            """
            let gh = bin.appendingPathComponent("gh")
            try Data(script.utf8).write(to: gh)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        }

        let store = try AuditStore(rootURL: state, workspaceRootURL: workspaces, managedWorkspaceRoots: [])
        let service = try BridgeService(store: store, baseEnvironment: [
            "HOME": home.path,
            "PATH": "\(bin.path):/usr/bin:/bin",
            "USER": NSUserName()
        ])
        service.gitHubCLISearchDirectories = []
        let created = try await service.createSession(sourcePath: source.path, provider: .codex, accessMode: .isolatedChanges)
        _ = try service.createChangePlan(
            sessionID: created.id,
            title: "Update the source text",
            summary: "Replace the original line and add a new file.",
            steps: ["Edit source.txt", "Add new.txt"]
        )
        let workspace = URL(fileURLWithPath: created.workspacePath, isDirectory: true)
        try Data("accepted isolated edit\n".utf8).write(to: workspace.appendingPathComponent("source.txt"))
        try Data("new file\n".utf8).write(to: workspace.appendingPathComponent("new.txt"))
        try FileManager.default.removeItem(at: workspace.appendingPathComponent("old.txt"))
        let digest = try await service.changesDiff(sessionID: created.id).digest

        var session = try XCTUnwrap(store.session(id: created.id))
        let changeAt = Date()
        session.lastChangeRunAt = changeAt
        session.verificationPassed = true
        session.verificationDiffDigest = digest
        session.verificationCommandLabel = ".codex/ci.sh"
        session.verificationCompletedAt = changeAt.addingTimeInterval(1)
        try store.saveSession(session)

        let branch = "agentbridge/pr-test"
        let applied = try await service.applyChangesToLocalBranch(sessionID: created.id, branchName: branch)
        let stored = try XCTUnwrap(store.session(id: created.id))
        XCTAssertEqual(stored.appliedBranchName, branch)
        XCTAssertEqual(stored.appliedWorktreePath, applied.worktreePath)
        return Fixture(
            rootURL: root,
            sourceURL: source,
            remoteURL: remote,
            ghLogURL: ghLog,
            store: store,
            service: service,
            session: stored,
            snapshot: snapshot,
            branch: branch,
            worktreeURL: URL(fileURLWithPath: applied.worktreePath, isDirectory: true)
        )
    }
}
