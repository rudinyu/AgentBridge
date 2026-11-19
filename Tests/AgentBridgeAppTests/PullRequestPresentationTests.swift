import AgentBridgeCore
import XCTest
@testable import AgentBridgeApp

final class PullRequestPresentationTests: XCTestCase {
    private func preview(
        gitHubCLI: GitHubCLIStatus = .ready(executablePath: "/opt/homebrew/bin/gh"),
        matches: Bool = true,
        completed: [PullRequestStep] = [],
        appliedCommit: String? = nil,
        pullRequestURL: String? = nil
    ) -> PullRequestPreview {
        PullRequestPreview(
            sessionID: UUID(),
            branchName: "agentbridge/feature",
            worktreePath: "/tmp/apply",
            remotes: [GitRemote(name: "origin", fetchURL: "git@github.com:octo/app.git", pushURL: "git@github.com:octo/app.git")],
            selectedRemote: "origin",
            proposedBase: "main",
            baseSource: .remoteHead,
            remoteDefaultBranch: "main",
            commitMessage: "Title\n",
            pullRequestTitle: "Title",
            pullRequestBody: "Body\n",
            gitHubCLI: gitHubCLI,
            changedFiles: ["a.txt"],
            worktreeMatchesVerifiedDiff: matches,
            completedSteps: completed,
            appliedCommit: appliedCommit,
            pushedRemote: nil,
            pullRequestURL: pullRequestURL
        )
    }

    private let form = PullRequestPresentation.Form(remote: "origin", base: "main", commitMessage: "Title\n", title: "Title")

    func testStartsOnlyWithReadyGitHubCLIAndAMatchingWorktree() {
        XCTAssertTrue(PullRequestPresentation.canStart(preview: preview(), form: form, isRunning: false))
        XCTAssertFalse(PullRequestPresentation.canStart(preview: nil, form: form, isRunning: false))
        XCTAssertFalse(PullRequestPresentation.canStart(preview: preview(), form: form, isRunning: true))
        XCTAssertFalse(PullRequestPresentation.canStart(preview: preview(gitHubCLI: .notInstalled), form: form, isRunning: false))
        XCTAssertFalse(PullRequestPresentation.canStart(preview: preview(gitHubCLI: .notAuthenticated(executablePath: "/x/gh")), form: form, isRunning: false))
        XCTAssertFalse(PullRequestPresentation.canStart(preview: preview(matches: false), form: form, isRunning: false))
        // A recorded commit is pushed as it is, so a retry does not need the worktree check.
        XCTAssertTrue(PullRequestPresentation.canStart(preview: preview(matches: false, appliedCommit: "abc"), form: form, isRunning: false))
        XCTAssertFalse(PullRequestPresentation.canStart(preview: preview(pullRequestURL: "https://github.com/octo/app/pull/1"), form: form, isRunning: false))
    }

    func testStartNeedsAKnownRemoteABaseOtherThanTheBranchAndText() {
        var edited = form
        edited.remote = "upstream"
        XCTAssertFalse(PullRequestPresentation.canStart(preview: preview(), form: edited, isRunning: false))
        edited = form
        edited.base = "  "
        XCTAssertFalse(PullRequestPresentation.canStart(preview: preview(), form: edited, isRunning: false))
        edited.base = "agentbridge/feature"
        XCTAssertFalse(PullRequestPresentation.canStart(preview: preview(), form: edited, isRunning: false))
        edited = form
        edited.title = " \n"
        XCTAssertFalse(PullRequestPresentation.canStart(preview: preview(), form: edited, isRunning: false))
        edited = form
        edited.commitMessage = ""
        XCTAssertFalse(PullRequestPresentation.canStart(preview: preview(), form: edited, isRunning: false))
    }

    func testBlockingMessagesNameWhatToDo() {
        XCTAssertNil(PullRequestPresentation.blockingMessage(for: .ready(executablePath: "/x/gh")))
        XCTAssertEqual(
            PullRequestPresentation.blockingMessage(for: .notAuthenticated(executablePath: "/x/gh")),
            "Sign in with `gh auth login` in Terminal, then try again."
        )
        XCTAssertTrue(PullRequestPresentation.blockingMessage(for: .notInstalled)?.contains("brew install gh") == true)
    }

    func testStepStatesShowEarlierProgressTheRunningStepAndAFailure() {
        func states(_ completed: [PullRequestStep], running: PullRequestStep? = nil, failed: PullRequestStep? = nil) -> [PullRequestPresentation.StepState] {
            PullRequestPresentation.stepStates(completed: completed, running: running, failed: failed).map(\.state)
        }
        XCTAssertEqual(states([]), [.pending, .pending, .pending])
        XCTAssertEqual(states([], running: .push), [.done, .running, .pending])
        XCTAssertEqual(states([.commit], failed: .push), [.done, .failed, .pending])
        XCTAssertEqual(states([.commit, .push, .pullRequest]), [.done, .done, .done])
        XCTAssertEqual(PullRequestPresentation.stepStates(completed: [], running: nil, failed: nil).map(\.step), [.commit, .push, .pullRequest])
    }

    func testFailedStepComesFromTheServiceError() {
        XCTAssertEqual(PullRequestPresentation.failedStep(of: AgentBridgeError.pullRequestStepFailed(.push, "rejected")), .push)
        XCTAssertNil(PullRequestPresentation.failedStep(of: AgentBridgeError.invalidInput("no gh")))
    }

    func testOnlyHTTPSAddressesOpenInTheBrowser() {
        XCTAssertEqual(PullRequestPresentation.browserURL("https://github.com/octo/app/pull/1")?.host, "github.com")
        XCTAssertNil(PullRequestPresentation.browserURL("file:///etc/passwd"))
        XCTAssertNil(PullRequestPresentation.browserURL(nil))
    }

    func testEveryStepTitleAndBlockingMessageIsTranslated() {
        let texts = PullRequestStep.allCases.map(PullRequestPresentation.title(of:))
            + [GitHubCLIStatus.notInstalled, .notAuthenticated(executablePath: "/x/gh")].compactMap(PullRequestPresentation.blockingMessage(for:))
        for text in texts {
            XCTAssertNotEqual(AppLocalization.display(text, language: .traditionalChinese), text, text)
        }
        XCTAssertEqual(
            AppLocalization.display("The push step failed: git exited with code 1.", language: .traditionalChinese),
            "推送步驟失敗：git 結束代碼 1。"
        )
    }
}
