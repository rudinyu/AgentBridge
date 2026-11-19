import Darwin
import Foundation

/// Commits verified changes in the apply worktree, pushes the branch and opens a
/// GitHub pull request, only after the user confirms. No model is called.
///
/// Unlike every other Git command AgentBridge runs, these use the user's own Git
/// and GitHub CLI setup, because the commit carries the user's identity and the
/// push and pull request need their credentials: see `publishingEnvironment`.
/// Hooks still never run, because the worktree's files came from a model.
extension BridgeService {
    static let gitHubCLIFallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
    private static let maximumPullRequestTitleBytes = 1_024
    private static let maximumPullRequestTextBytes = 60_000

    // MARK: Preview

    public func pullRequestPreview(sessionID: UUID, remote: String? = nil, base: String? = nil) async throws -> PullRequestPreview {
        let session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        guard let branch = session.appliedBranchName else {
            throw AgentBridgeError.invalidInput("Apply the verified changes to a local branch first.")
        }
        let worktree = try workspaceManager.validatedApplyWorktree(for: session)
        let source = URL(fileURLWithPath: session.sourceRepositoryPath, isDirectory: true).standardizedFileURL
        let remotes = try await gitRemotes(in: source)
        let selectedRemote: String?
        if let remote {
            guard remotes.contains(where: { $0.name == remote }) else {
                throw AgentBridgeError.invalidInput("The source repository has no remote named \(remote).")
            }
            selectedRemote = remote
        } else {
            selectedRemote = remotes.first(where: { $0.name == "origin" })?.name ?? remotes.first?.name
        }
        let gitHubCLI = await gitHubCLIStatus(host: selectedRemote.flatMap { name in
            remotes.first(where: { $0.name == name }).flatMap { Self.gitHubRepository(fromRemoteURL: $0.pushURL)?.host }
        })

        var remoteDefault: String?
        var proposedBase: String?
        var baseSource = PullRequestBaseSource.unknown
        if let selectedRemote, let remoteInfo = remotes.first(where: { $0.name == selectedRemote }) {
            if let fromHead = try await remoteHeadBranch(remote: selectedRemote, in: source) {
                remoteDefault = fromHead
                baseSource = .remoteHead
            } else if case .ready(let gh) = gitHubCLI,
                      let repository = Self.gitHubRepository(fromRemoteURL: remoteInfo.pushURL),
                      let fromGitHub = try? await gitHubDefaultBranch(gh: URL(fileURLWithPath: gh), repository: repository, worktree: worktree) {
                remoteDefault = fromGitHub
                baseSource = .gitHubCLI
            }
            proposedBase = remoteDefault
            if proposedBase == nil {
                for candidate in ["main", "master"] {
                    guard try await branchExists(candidate, remote: selectedRemote, in: source) else { continue }
                    proposedBase = candidate
                    baseSource = .existingBranch
                    break
                }
            }
        }
        if let base, !base.isEmpty {
            proposedBase = base
            baseSource = .requested
        }

        let diff = try? await workspaceManager.applyWorktreeDiff(for: session)
        let matches = diff.map { $0.digest == session.verificationDiffDigest && session.verificationPassed == true } ?? false
        let text = Self.proposedPullRequestText(for: session)
        return PullRequestPreview(
            sessionID: sessionID,
            branchName: branch,
            worktreePath: worktree.path,
            remotes: remotes,
            selectedRemote: selectedRemote,
            proposedBase: proposedBase,
            baseSource: baseSource,
            remoteDefaultBranch: remoteDefault,
            commitMessage: text.commitMessage,
            pullRequestTitle: text.title,
            pullRequestBody: text.body,
            gitHubCLI: gitHubCLI,
            changedFiles: diff?.files.map(\.path) ?? [],
            worktreeMatchesVerifiedDiff: matches,
            completedSteps: Self.completedPullRequestSteps(session),
            appliedCommit: session.appliedCommit,
            pushedRemote: session.pushedRemote,
            pullRequestURL: session.pullRequestURL
        )
    }

    static func completedPullRequestSteps(_ session: SessionRecord) -> [PullRequestStep] {
        var steps: [PullRequestStep] = []
        if session.appliedCommit != nil { steps.append(.commit) }
        if session.pushedRemote != nil { steps.append(.push) }
        if session.pullRequestURL != nil { steps.append(.pullRequest) }
        return steps
    }

    /// The plan's title and summary, its steps and the verification result. No
    /// prompt and no model output is included.
    static func proposedPullRequestText(for session: SessionRecord) -> (commitMessage: String, title: String, body: String) {
        let plan = session.changePlan
        let title = plan?.title ?? "Changes from AgentBridge session \(session.id.uuidString.lowercased().prefix(8))"
        var details: [String] = []
        if let plan {
            details.append(plan.summary)
            details.append((["Steps:"] + plan.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }).joined(separator: "\n"))
        }
        if session.verificationPassed == true {
            details.append("Verified with \(session.verificationCommandLabel ?? "the approved verifier"): passed")
        }
        let providerName = session.provider == .claude ? "Claude Code" : "Codex"
        let commitMessage = ([title] + details).joined(separator: "\n\n") + "\n"
        let body = (details + ["Opened with AgentBridge; changes were made by \(providerName) in an isolated workspace and verified before this PR."])
            .joined(separator: "\n\n") + "\n"
        return (commitMessage, title, body)
    }

    // MARK: Commit, push, open

    @discardableResult
    public func openPullRequest(
        sessionID: UUID,
        request: PullRequestRequest,
        cancellation: CancellationFlag = CancellationFlag(),
        onStepStarted: (@Sendable (PullRequestStep) -> Void)? = nil
    ) async throws -> PullRequestOutcome {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        guard let branch = session.appliedBranchName else {
            throw AgentBridgeError.invalidInput("Apply the verified changes to a local branch first.")
        }
        let worktree = try workspaceManager.validatedApplyWorktree(for: session)
        let source = URL(fileURLWithPath: session.sourceRepositoryPath, isDirectory: true).standardizedFileURL
        try validatePullRequestText(request)
        let remotes = try await gitRemotes(in: source)
        guard let remote = remotes.first(where: { $0.name == request.remote }) else {
            throw AgentBridgeError.invalidInput("The source repository has no remote named \(request.remote).")
        }
        try await validateBaseBranchName(request.base, in: worktree)
        guard request.base != branch else {
            throw AgentBridgeError.invalidInput("The branch to push is the base branch. Apply the changes to a new branch.")
        }
        if let remoteDefault = try await remoteHeadBranch(remote: remote.name, in: source), remoteDefault == branch {
            throw AgentBridgeError.invalidInput("The branch to push is the remote's default branch. Apply the changes to a new branch.")
        }
        let repository = Self.gitHubRepository(fromRemoteURL: remote.pushURL)

        // The pull request needs gh, so nothing is committed or pushed without it.
        var gh: URL?
        if session.pullRequestURL == nil {
            switch await gitHubCLIStatus(host: repository?.host) {
            case .notInstalled:
                throw AgentBridgeError.invalidInput("The GitHub CLI (gh) is not installed. Install it with `brew install gh`, then try again.")
            case .notAuthenticated:
                throw AgentBridgeError.invalidInput("The GitHub CLI is not signed in. Sign in with `gh auth login` in Terminal, then try again.")
            case .ready(let path):
                gh = URL(fileURLWithPath: path)
            }
        }

        var results: [PullRequestStepResult] = []
        var currentStep = PullRequestStep.commit
        do {
            onStepStarted?(.commit)
            let commitResult = try await commitVerifiedChanges(session: &session, branch: branch, worktree: worktree, message: request.commitMessage, cancellation: cancellation)
            results.append(commitResult)

            currentStep = .push
            onStepStarted?(.push)
            if session.pushedRemote == remote.name {
                results.append(PullRequestStepResult(step: .push, outcome: .alreadyDone, detail: remote.name))
            } else {
                try await requireCommittedWorktree(session: session, worktree: worktree)
                _ = try await runPublishingGit([
                    "-C", worktree.path, "push", "--no-verify", "--porcelain", "-u", remote.name,
                    "refs/heads/\(branch):refs/heads/\(branch)"
                ], timeout: 300, cancellation: cancellation)
                session.pushedRemote = remote.name
                session.pushedAt = Date()
                session.updatedAt = Date()
                try store.saveSession(session)
                try store.appendEvent(AuditEvent(
                    sessionID: sessionID,
                    kind: "change.pr.pushed",
                    message: "Pushed branch \(branch) to remote \(remote.name) without force."
                ))
                results.append(PullRequestStepResult(step: .push, outcome: .done, detail: remote.name))
            }

            currentStep = .pullRequest
            onStepStarted?(.pullRequest)
            if let url = session.pullRequestURL {
                results.append(PullRequestStepResult(step: .pullRequest, outcome: .alreadyDone, detail: url))
            } else {
                guard let gh else { throw AgentBridgeError.invalidInput("The GitHub CLI (gh) is not installed. Install it with `brew install gh`, then try again.") }
                let repositoryArguments = repository.map { ["--repo", $0.argument] } ?? []
                let (url, reused) = try await createOrFindPullRequest(
                    gh: gh, worktree: worktree, branch: branch, request: request,
                    repositoryArguments: repositoryArguments, cancellation: cancellation
                )
                session.pullRequestURL = url
                session.updatedAt = Date()
                try store.saveSession(session)
                try store.appendEvent(AuditEvent(
                    sessionID: sessionID,
                    kind: "change.pr.opened",
                    message: reused
                        ? "Recorded the existing pull request \(url) for branch \(branch)."
                        : "Opened pull request \(url) for branch \(branch) into \(request.base)."
                ))
                results.append(PullRequestStepResult(step: .pullRequest, outcome: reused ? .reusedExisting : .done, detail: url))
            }
        } catch {
            let reason: String
            if case .pullRequestStepFailed(_, let message)? = error as? AgentBridgeError {
                reason = message
            } else {
                reason = OutputRedactor.redact(error.localizedDescription)
            }
            try? store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "change.pr.failed",
                message: "The \(currentStep.rawValue) step failed: \(reason)"
            ))
            throw AgentBridgeError.pullRequestStepFailed(currentStep, reason)
        }
        return PullRequestOutcome(steps: results, commit: session.appliedCommit ?? "", pullRequestURL: session.pullRequestURL ?? "")
    }

    private func validatePullRequestText(_ request: PullRequestRequest) throws {
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = request.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.utf8.count <= Self.maximumPullRequestTitleBytes, !title.contains("\0"), !title.contains("\n") else {
            throw AgentBridgeError.invalidInput("Enter a one-line pull request title.")
        }
        guard !subject.isEmpty, request.commitMessage.utf8.count <= Self.maximumPullRequestTextBytes, !request.commitMessage.contains("\0") else {
            throw AgentBridgeError.invalidInput("Enter a commit message.")
        }
        guard request.body.utf8.count <= Self.maximumPullRequestTextBytes, !request.body.contains("\0") else {
            throw AgentBridgeError.invalidInput("The pull request description is too long.")
        }
    }

    /// Commits the verified diff once. A recorded commit that is still the branch
    /// tip is kept; anything else on the branch stops the run.
    private func commitVerifiedChanges(
        session: inout SessionRecord,
        branch: String,
        worktree: URL,
        message: String,
        cancellation: CancellationFlag
    ) async throws -> PullRequestStepResult {
        let currentBranch = try await publishingGitText(["-C", worktree.path, "symbolic-ref", "--quiet", "--short", "HEAD"], cancellation: cancellation)
        guard currentBranch == branch else {
            throw AgentBridgeError.sessionMismatch("The apply worktree is no longer on branch \(branch).")
        }
        let tip = try await publishingGitText(["-C", worktree.path, "rev-parse", "--verify", "HEAD^{commit}"], cancellation: cancellation).lowercased()
        if let recorded = session.appliedCommit {
            guard tip == recorded else {
                throw AgentBridgeError.sessionMismatch("Branch \(branch) moved after AgentBridge committed to it. Nothing more was pushed.")
            }
            return PullRequestStepResult(step: .commit, outcome: .alreadyDone, detail: recorded)
        }
        guard tip == session.snapshotCommit else {
            throw AgentBridgeError.sessionMismatch("Branch \(branch) has commits AgentBridge did not make, so it was not committed to.")
        }
        try requireSuccessfulChangeVerification(session)
        let diff = try await workspaceManager.applyWorktreeDiff(for: session)
        guard !diff.files.isEmpty else {
            throw AgentBridgeError.invalidInput("The apply worktree has no changes to commit.")
        }
        guard diff.digest == session.verificationDiffDigest else {
            throw AgentBridgeError.sessionMismatch("The apply worktree differs from the verified changes, so nothing was committed. Apply the verified changes to a new branch.")
        }

        // Exactly the verified paths, even ones the user's global ignore file skips.
        let paths = diff.files.map(\.path)
        _ = try await runPublishingGit(
            ["-C", worktree.path, "add", "--all", "--force", "--pathspec-from-file=-", "--pathspec-file-nul"],
            standardInput: Data(paths.joined(separator: "\0").utf8),
            cancellation: cancellation
        )
        let staged = try await runPublishingGit(
            ["-C", worktree.path, "diff", "--cached", "--name-only", "-z", "--no-renames", "HEAD", "--"],
            cancellation: cancellation
        )
        let stagedPaths = Set(staged.standardOutput.split(separator: 0).map { String(decoding: $0, as: UTF8.self) })
        guard !staged.outputWasTruncated, stagedPaths == Set(paths) else {
            _ = try? await runPublishingGit(["-C", worktree.path, "reset", "--quiet"], cancellation: cancellation)
            throw AgentBridgeError.sessionMismatch("Git staged different files than the verified changes, so nothing was committed.")
        }

        let messageFile = try writePrivatePublishingFile(message, name: "commit-message")
        defer { try? FileManager.default.removeItem(at: messageFile) }
        _ = try await runPublishingGit(
            ["-C", worktree.path, "commit", "--no-verify", "--quiet", "--cleanup=whitespace", "--file", messageFile.path],
            timeout: 120,
            cancellation: cancellation
        )
        let commit = try await publishingGitText(["-C", worktree.path, "rev-parse", "--verify", "HEAD^{commit}"], cancellation: cancellation).lowercased()
        session.appliedCommit = commit
        session.updatedAt = Date()
        try store.saveSession(session)
        try store.appendEvent(AuditEvent(
            sessionID: session.id,
            kind: "change.pr.committed",
            message: "Committed \(paths.count) verified files on branch \(branch) as \(commit.prefix(12)) in the apply worktree."
        ))
        return PullRequestStepResult(step: .commit, outcome: .done, detail: commit)
    }

    /// Before pushing: the branch tip is the recorded commit and the worktree has
    /// nothing else in it, so what leaves this Mac is what was verified.
    private func requireCommittedWorktree(session: SessionRecord, worktree: URL) async throws {
        let tip = try await publishingGitText(["-C", worktree.path, "rev-parse", "--verify", "HEAD^{commit}"]).lowercased()
        guard let commit = session.appliedCommit, tip == commit else {
            throw AgentBridgeError.sessionMismatch("The branch tip is not the commit AgentBridge made, so nothing was pushed.")
        }
        let status = try await runPublishingGit(["-C", worktree.path, "status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let diff = try await workspaceManager.applyWorktreeDiff(for: session)
        guard status.standardOutput.isEmpty, diff.digest == session.verificationDiffDigest else {
            throw AgentBridgeError.sessionMismatch("The apply worktree changed after the commit, so nothing was pushed.")
        }
    }

    private func createOrFindPullRequest(
        gh: URL,
        worktree: URL,
        branch: String,
        request: PullRequestRequest,
        repositoryArguments: [String],
        cancellation: CancellationFlag
    ) async throws -> (url: String, reused: Bool) {
        let existing = try await runPublishingProcess(
            gh, ["pr", "view", branch, "--json", "url,state"] + repositoryArguments,
            workingDirectory: worktree, timeout: 60, allowedExitCodes: [0, 1], cancellation: cancellation
        )
        if existing.exitCode == 0,
           let object = try? JSONSerialization.jsonObject(with: existing.standardOutput) as? [String: Any],
           (object["state"] as? String)?.uppercased() == "OPEN",
           let url = (object["url"] as? String).flatMap(Self.pullRequestURL(in:)) {
            return (url, true)
        }
        let bodyFile = try writePrivatePublishingFile(request.body, name: "pull-request-body")
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        var arguments = ["pr", "create"] + repositoryArguments + [
            "--base", request.base,
            "--head", branch,
            "--title", request.title.trimmingCharacters(in: .whitespacesAndNewlines),
            "--body-file", bodyFile.path
        ]
        if request.draft { arguments.append("--draft") }
        let created = try await runPublishingProcess(gh, arguments, workingDirectory: worktree, timeout: 120, cancellation: cancellation)
        let output = String(decoding: created.standardOutput, as: UTF8.self)
        guard let url = Self.pullRequestURL(in: output) else {
            throw AgentBridgeError.invalidInput("The GitHub CLI did not report a pull request URL.")
        }
        return (url, false)
    }

    /// The last `https://…/pull/N` URL in `text`.
    static func pullRequestURL(in text: String) -> String? {
        let pattern = #"https://[A-Za-z0-9.\-]+(?::[0-9]+)?/[A-Za-z0-9._\-]+/[A-Za-z0-9._\-]+/pull/[0-9]+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.last.flatMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    // MARK: Remotes and branches

    func gitRemotes(in source: URL) async throws -> [GitRemote] {
        let output = String(decoding: try await runPublishingGit(["-C", source.path, "remote", "-v"]).standardOutput, as: UTF8.self)
        var fetch: [String: String] = [:]
        var push: [String: String] = [:]
        var order: [String] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2 else { continue }
            let name = String(fields[0])
            let rest = String(fields[1])
            if rest.hasSuffix(" (fetch)") {
                fetch[name] = String(rest.dropLast(8))
            } else if rest.hasSuffix(" (push)") {
                push[name] = String(rest.dropLast(7))
            } else { continue }
            if !order.contains(name) { order.append(name) }
        }
        return order.map { name in
            GitRemote(
                name: name,
                fetchURL: Self.withoutCredentials(fetch[name] ?? push[name] ?? ""),
                pushURL: Self.withoutCredentials(push[name] ?? fetch[name] ?? "")
            )
        }
    }

    /// A remote URL with any `user:password@` removed, so it can be shown and logged.
    static func withoutCredentials(_ url: String) -> String {
        guard var components = URLComponents(string: url), components.scheme != nil, components.password != nil || components.user != nil else {
            return url
        }
        if components.scheme == "https" || components.scheme == "http" {
            components.user = nil
            components.password = nil
        } else {
            components.password = nil
        }
        return components.string ?? url
    }

    private func remoteHeadBranch(remote: String, in source: URL) async throws -> String? {
        let result = try await runPublishingGit(
            ["-C", source.path, "symbolic-ref", "--quiet", "--short", "refs/remotes/\(remote)/HEAD"],
            allowedExitCodes: [0, 1, 128]
        )
        guard result.exitCode == 0 else { return nil }
        let value = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "\(remote)/"
        guard value.hasPrefix(prefix), value.count > prefix.count else { return nil }
        return String(value.dropFirst(prefix.count))
    }

    private func branchExists(_ name: String, remote: String, in source: URL) async throws -> Bool {
        for reference in ["refs/remotes/\(remote)/\(name)", "refs/heads/\(name)"] {
            let result = try await runPublishingGit(
                ["-C", source.path, "show-ref", "--verify", "--quiet", reference],
                allowedExitCodes: [0, 1, 128]
            )
            if result.exitCode == 0 { return true }
        }
        return false
    }

    private func validateBaseBranchName(_ name: String, in repository: URL) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), name.utf8.count <= 200,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentBridgeError.invalidInput("Enter a valid base branch name.")
        }
        let result = try await runPublishingGit(["-C", repository.path, "check-ref-format", "--branch", name], allowedExitCodes: [0, 1, 128])
        guard result.exitCode == 0 else { throw AgentBridgeError.invalidInput("Enter a valid base branch name.") }
    }

    struct GitHubRepository: Equatable {
        let host: String
        let owner: String
        let name: String

        /// What `gh --repo` takes: `OWNER/REPO` on github.com, else `HOST/OWNER/REPO`.
        var argument: String { host == "github.com" ? "\(owner)/\(name)" : "\(host)/\(owner)/\(name)" }
    }

    /// The GitHub repository a remote URL names, for SSH (`git@host:owner/repo`),
    /// `ssh://` and `https://` URLs. Nil for a local path or anything else; gh then
    /// works the repository out from the worktree.
    static func gitHubRepository(fromRemoteURL url: String) -> GitHubRepository? {
        var host: String
        var path: String
        if let components = URLComponents(string: url), let scheme = components.scheme, ["https", "http", "ssh", "git"].contains(scheme) {
            guard let componentHost = components.host, !componentHost.isEmpty else { return nil }
            host = componentHost
            path = components.path
        } else if let at = url.firstIndex(of: "@"), let colon = url[at...].firstIndex(of: ":"), !url.hasPrefix("/") {
            host = String(url[url.index(after: at)..<colon])
            path = String(url[url.index(after: colon)...])
        } else {
            return nil
        }
        host = host.lowercased()
        if host == "ssh.github.com" { host = "github.com" }
        guard host.contains("github") else { return nil }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return nil }
        var name = parts[1]
        if name.hasSuffix(".git") { name.removeLast(4) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !parts[0].isEmpty, !name.isEmpty,
              parts[0].unicodeScalars.allSatisfy(allowed.contains), name.unicodeScalars.allSatisfy(allowed.contains),
              host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return GitHubRepository(host: host, owner: parts[0], name: name)
    }

    // MARK: GitHub CLI

    func resolveGitHubCLI() -> URL? {
        let pathDirectories = (baseEnvironment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        for directory in pathDirectories + gitHubCLISearchDirectories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("gh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return nil
    }

    /// Only the exit code of `gh auth status` is used; its output is discarded.
    func gitHubCLIStatus(host: String?) async -> GitHubCLIStatus {
        guard let gh = resolveGitHubCLI() else { return .notInstalled }
        let arguments = ["auth", "status"] + (host.map { ["--hostname", $0] } ?? [])
        guard let result = try? await runPublishingProcess(gh, arguments, workingDirectory: nil, timeout: 30, allowedExitCodes: nil),
              result.exitCode == 0 else {
            return .notAuthenticated(executablePath: gh.path)
        }
        return .ready(executablePath: gh.path)
    }

    private func gitHubDefaultBranch(gh: URL, repository: GitHubRepository, worktree: URL) async throws -> String? {
        let result = try await runPublishingProcess(
            gh, ["repo", "view", repository.argument, "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"],
            workingDirectory: worktree, timeout: 15, allowedExitCodes: nil
        )
        guard result.exitCode == 0 else { return nil }
        let name = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.contains("\n") ? nil : name
    }

    // MARK: Processes

    /// The environment for the user's own Git and GitHub CLI. Provider runs get a
    /// sanitized environment, and AgentBridge's other Git commands a private home
    /// with no global or system Git config. A commit needs the user's identity and
    /// a push and `gh` their credentials, so this keeps the real home folder (Git
    /// config, credential helpers, `~/.ssh`, gh's config and the login keychain),
    /// the SSH agent socket, gh's own config and token variables, GnuPG's home for
    /// signed commits, proxy settings, and a PATH that also finds Homebrew tools.
    /// Prompts are turned off, so nothing waits for typed input.
    func publishingEnvironment(temporaryDirectory: URL) -> [String: String] {
        var environment: [String: String] = [:]
        let absoluteKeys = ["HOME", "SSH_AUTH_SOCK", "GNUPGHOME", "GH_CONFIG_DIR", "XDG_CONFIG_HOME"]
        for key in absoluteKeys {
            if let value = baseEnvironment[key], value.hasPrefix("/"), !value.contains("\0") { environment[key] = value }
        }
        let passedKeys = [
            "USER", "LOGNAME", "LANG", "GH_HOST", "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
            "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"
        ]
        for key in passedKeys {
            if let value = baseEnvironment[key], !value.isEmpty, !value.contains("\0"), value.utf8.count <= 4_096 { environment[key] = value }
        }
        if environment["USER"] == nil { environment["USER"] = NSUserName() }
        if environment["HOME"] == nil { environment["HOME"] = NSHomeDirectory() }
        var path: [String] = []
        for directory in (baseEnvironment["PATH"] ?? "").split(separator: ":").map(String.init) + gitHubCLISearchDirectories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            where directory.hasPrefix("/") && !path.contains(directory) {
            path.append(directory)
        }
        environment["PATH"] = path.joined(separator: ":")
        environment["TMPDIR"] = temporaryDirectory.path
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "never"
        environment["GH_PROMPT_DISABLED"] = "1"
        environment["GH_NO_UPDATE_NOTIFIER"] = "1"
        environment["GH_SPINNER_DISABLED"] = "1"
        return environment
    }

    private var publishingTemporaryDirectory: URL {
        get throws {
            let directory = store.rootURL.appendingPathComponent("tmp/publish", isDirectory: true)
            try AuditStore.createPrivateDirectory(directory)
            return directory
        }
    }

    private func writePrivatePublishingFile(_ text: String, name: String) throws -> URL {
        let url = try publishingTemporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.lowercased()).txt")
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw AgentBridgeError.persistence("Could not write a temporary file for the commit or pull request.")
        }
        return url
    }

    /// The user's Git, with hooks and fsmonitor off: the worktree's files came from
    /// a model, and a tracked hook folder could otherwise run them.
    @discardableResult
    private func runPublishingGit(
        _ arguments: [String],
        standardInput: Data = Data(),
        timeout: TimeInterval = 60,
        allowedExitCodes: Set<Int32>? = [0],
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> ProcessResult {
        try await runPublishingProcess(
            URL(fileURLWithPath: "/usr/bin/git"),
            ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "--literal-pathspecs"] + arguments,
            workingDirectory: nil,
            standardInput: standardInput,
            timeout: timeout,
            allowedExitCodes: allowedExitCodes,
            cancellation: cancellation
        )
    }

    private func publishingGitText(_ arguments: [String], cancellation: CancellationFlag = CancellationFlag()) async throws -> String {
        let result = try await runPublishingGit(arguments, cancellation: cancellation)
        let value = String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.outputWasTruncated, !value.isEmpty else {
            throw AgentBridgeError.git("Git returned information that could not be recognized.")
        }
        return value
    }

    /// Runs one program with argv and no shell. A failure reports the exit code and
    /// the end of its error output, redacted, which is what says why a push failed.
    private func runPublishingProcess(
        _ executable: URL,
        _ arguments: [String],
        workingDirectory: URL?,
        standardInput: Data = Data(),
        timeout: TimeInterval,
        allowedExitCodes: Set<Int32>? = [0],
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> ProcessResult {
        let spec = ProcessSpec(
            executableURL: executable,
            arguments: arguments,
            environment: publishingEnvironment(temporaryDirectory: try publishingTemporaryDirectory),
            workingDirectoryURL: workingDirectory,
            standardInput: standardInput,
            timeout: timeout,
            outputLimit: 1_048_576,
            endsWithParent: true
        )
        let result = try await runner.run(spec, cancellation: cancellation)
        if result.wasCancelled { throw AgentBridgeError.processCancelled }
        if result.timedOut { throw AgentBridgeError.processTimedOut }
        if let allowedExitCodes, !allowedExitCodes.contains(result.exitCode) {
            let program = executable.lastPathComponent
            let detail = Self.publishingErrorSummary(result.standardError)
            throw AgentBridgeError.invalidInput(detail.isEmpty
                ? "\(program) exited with code \(result.exitCode)."
                : "\(program) exited with code \(result.exitCode): \(detail)")
        }
        return result
    }

    /// The last lines of a program's error output, without credentials in URLs and
    /// redacted, at most 600 characters.
    static func publishingErrorSummary(_ data: Data) -> String {
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var text = lines.suffix(6).joined(separator: " ")
        if let expression = try? NSRegularExpression(pattern: #"(https?://)[^/\s@]+@"#) {
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1")
        }
        text = OutputRedactor.redact(text)
        return text.count > 600 ? String(text.suffix(600)) : text
    }
}
