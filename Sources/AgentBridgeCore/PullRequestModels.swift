import Foundation

/// The three steps that take verified changes from the apply worktree to a pull
/// request, in the order they run. Each runs only after the user confirms.
public enum PullRequestStep: String, Codable, CaseIterable, Equatable, Sendable {
    case commit
    case push
    case pullRequest
}

/// A remote of the source repository, as `git remote -v` lists it.
public struct GitRemote: Equatable, Sendable {
    public let name: String
    public let fetchURL: String
    public let pushURL: String

    public init(name: String, fetchURL: String, pushURL: String) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURL = pushURL
    }
}

/// Whether the GitHub CLI can open a pull request. Only `gh auth status`'s exit
/// code is read; its output, and any token, is never kept.
public enum GitHubCLIStatus: Equatable, Sendable {
    case notInstalled
    case notAuthenticated(executablePath: String)
    case ready(executablePath: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Where the proposed base branch came from.
public enum PullRequestBaseSource: String, Equatable, Sendable {
    /// `refs/remotes/<remote>/HEAD`, the remote's default branch as last fetched.
    case remoteHead
    /// GitHub's default branch, as `gh repo view` reports it.
    case gitHubCLI
    /// A `main` or `master` branch that exists; it may not be the default.
    case existingBranch
    /// The caller chose it.
    case requested
    /// Nothing was found; the user must type the base branch.
    case unknown
}

/// Everything the user confirms before AgentBridge commits, pushes and opens a
/// pull request. Building it runs Git and `gh` read-only and calls no model.
public struct PullRequestPreview: Equatable, Sendable {
    public let sessionID: UUID
    public let branchName: String
    public let worktreePath: String
    public let remotes: [GitRemote]
    /// The remote the preview was made for: the requested one, else `origin`,
    /// else the first. Nil when the source repository has no remote.
    public let selectedRemote: String?
    public let proposedBase: String?
    public let baseSource: PullRequestBaseSource
    /// The selected remote's default branch when it is known, which is never pushed to.
    public let remoteDefaultBranch: String?
    public let commitMessage: String
    public let pullRequestTitle: String
    public let pullRequestBody: String
    public let gitHubCLI: GitHubCLIStatus
    /// The files the commit would contain, from the apply worktree.
    public let changedFiles: [String]
    /// Whether the apply worktree still holds exactly the verified diff, or holds
    /// it as the commit AgentBridge recorded.
    public let worktreeMatchesVerifiedDiff: Bool
    public let completedSteps: [PullRequestStep]
    public let appliedCommit: String?
    public let pushedRemote: String?
    public let pullRequestURL: String?

    public init(
        sessionID: UUID,
        branchName: String,
        worktreePath: String,
        remotes: [GitRemote],
        selectedRemote: String?,
        proposedBase: String?,
        baseSource: PullRequestBaseSource,
        remoteDefaultBranch: String?,
        commitMessage: String,
        pullRequestTitle: String,
        pullRequestBody: String,
        gitHubCLI: GitHubCLIStatus,
        changedFiles: [String],
        worktreeMatchesVerifiedDiff: Bool,
        completedSteps: [PullRequestStep],
        appliedCommit: String?,
        pushedRemote: String?,
        pullRequestURL: String?
    ) {
        self.sessionID = sessionID
        self.branchName = branchName
        self.worktreePath = worktreePath
        self.remotes = remotes
        self.selectedRemote = selectedRemote
        self.proposedBase = proposedBase
        self.baseSource = baseSource
        self.remoteDefaultBranch = remoteDefaultBranch
        self.commitMessage = commitMessage
        self.pullRequestTitle = pullRequestTitle
        self.pullRequestBody = pullRequestBody
        self.gitHubCLI = gitHubCLI
        self.changedFiles = changedFiles
        self.worktreeMatchesVerifiedDiff = worktreeMatchesVerifiedDiff
        self.completedSteps = completedSteps
        self.appliedCommit = appliedCommit
        self.pushedRemote = pushedRemote
        self.pullRequestURL = pullRequestURL
    }

    public var selectedRemoteURL: String? {
        remotes.first(where: { $0.name == selectedRemote })?.pushURL
    }
}

/// What the user confirmed. Every field is used as given.
public struct PullRequestRequest: Equatable, Sendable {
    public var remote: String
    public var base: String
    public var commitMessage: String
    public var title: String
    public var body: String
    public var draft: Bool

    public init(remote: String, base: String, commitMessage: String, title: String, body: String, draft: Bool = true) {
        self.remote = remote
        self.base = base
        self.commitMessage = commitMessage
        self.title = title
        self.body = body
        self.draft = draft
    }

    /// The preview's proposals, for a caller that changes nothing.
    public init?(preview: PullRequestPreview, draft: Bool = true) {
        guard let remote = preview.selectedRemote, let base = preview.proposedBase else { return nil }
        self.init(
            remote: remote,
            base: base,
            commitMessage: preview.commitMessage,
            title: preview.pullRequestTitle,
            body: preview.pullRequestBody,
            draft: draft
        )
    }
}

/// How one step ended in a run that succeeded.
public struct PullRequestStepResult: Equatable, Sendable {
    public enum Outcome: String, Equatable, Sendable {
        /// The step ran now.
        case done
        /// An earlier run already finished it, so it was not repeated.
        case alreadyDone
        /// A pull request for the branch already existed, and it was recorded.
        case reusedExisting
    }

    public let step: PullRequestStep
    public let outcome: Outcome
    /// The commit hash, the remote name or the pull request URL.
    public let detail: String

    public init(step: PullRequestStep, outcome: Outcome, detail: String) {
        self.step = step
        self.outcome = outcome
        self.detail = detail
    }
}

public struct PullRequestOutcome: Equatable, Sendable {
    public let steps: [PullRequestStepResult]
    public let commit: String
    public let pullRequestURL: String

    public init(steps: [PullRequestStepResult], commit: String, pullRequestURL: String) {
        self.steps = steps
        self.commit = commit
        self.pullRequestURL = pullRequestURL
    }
}
