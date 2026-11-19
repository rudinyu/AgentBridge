import AgentBridgeCore
import Foundation

/// How the commit, push and pull request sheet shows its steps and whether it can
/// start. Kept apart from the view so it can be tested without SwiftUI.
enum PullRequestPresentation {
    enum StepState: Equatable {
        case pending
        case running
        case done
        case failed
    }

    /// The English source text; the view passes it through `model.localized`.
    static func title(of step: PullRequestStep) -> String {
        switch step {
        case .commit: "Commit in the apply worktree"
        case .push: "Push the branch"
        case .pullRequest: "Open the pull request"
        }
    }

    /// Why the steps cannot run at all, or nil when gh is ready.
    static func blockingMessage(for status: GitHubCLIStatus) -> String? {
        switch status {
        case .ready: nil
        case .notInstalled: "The GitHub CLI (gh) is not installed. Install it with `brew install gh`, then try again."
        case .notAuthenticated: "Sign in with `gh auth login` in Terminal, then try again."
        }
    }

    /// Every step in order, with what is known about it: done in an earlier run,
    /// running now, the one that failed, or still to come.
    static func stepStates(
        completed: [PullRequestStep],
        running: PullRequestStep?,
        failed: PullRequestStep?
    ) -> [(step: PullRequestStep, state: StepState)] {
        PullRequestStep.allCases.map { step in
            if completed.contains(step) { return (step, .done) }
            if step == failed { return (step, .failed) }
            if step == running { return (step, .running) }
            if let running, PullRequestStep.allCases.firstIndex(of: step)! < PullRequestStep.allCases.firstIndex(of: running)! {
                return (step, .done)
            }
            return (step, .pending)
        }
    }

    struct Form: Equatable {
        var remote: String
        var base: String
        var commitMessage: String
        var title: String
    }

    /// Whether the confirm button can start the remaining steps.
    static func canStart(preview: PullRequestPreview?, form: Form, isRunning: Bool) -> Bool {
        guard let preview, !isRunning,
              preview.pullRequestURL == nil,
              blockingMessage(for: preview.gitHubCLI) == nil,
              preview.remotes.contains(where: { $0.name == form.remote }) else { return false }
        let base = form.base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base != preview.branchName,
              !form.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !form.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // A recorded commit is what gets pushed; otherwise the worktree must still be the verified diff.
        return preview.appliedCommit != nil || preview.worktreeMatchesVerifiedDiff
    }

    /// The step a failed run stopped at, from the error the service threw.
    static func failedStep(of error: Error) -> PullRequestStep? {
        if case .pullRequestStepFailed(let step, _)? = error as? AgentBridgeError { return step }
        return nil
    }

    /// Only a GitHub web address is opened in the browser.
    static func browserURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
