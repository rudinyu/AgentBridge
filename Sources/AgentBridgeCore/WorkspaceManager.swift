import Darwin
import Foundation

public struct WorkspaceSnapshot: Equatable, Sendable {
    public let repositoryRoot: URL
    public let commit: String
    public let wasDirty: Bool
}

public final class WorkspaceManager: @unchecked Sendable {
    private let store: AuditStore
    private let runner: SafeProcessRunner
    private let fileManager: FileManager
    private let gitURL: URL
    private let baseEnvironment: [String: String]

    public init(
        store: AuditStore,
        runner: SafeProcessRunner = SafeProcessRunner(),
        gitURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        fileManager: FileManager = .default,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.store = store
        self.runner = runner
        self.gitURL = gitURL
        self.fileManager = fileManager
        self.baseEnvironment = baseEnvironment
    }

    public func createSnapshot(
        sourcePath: String,
        provider: AgentProvider,
        accessMode: AccessMode = .readOnly,
        accountProfileID: UUID? = nil,
        snapshotCommit requestedSnapshotCommit: String? = nil
    ) async throws -> SessionRecord {
        guard store.workspaceRootURL != nil else {
            throw AgentBridgeError.invalidInput("No workspace data root is set. Choose a folder in the app, or run `agentbridge workspace set /absolute/path/to/root` first.")
        }
        let currentSnapshot = try await inspectSourceRepository(path: sourcePath)
        let snapshot: WorkspaceSnapshot
        if let requestedSnapshotCommit {
            let pinnedCommit = try await resolveSnapshotCommit(
                requestedSnapshotCommit,
                repositoryRoot: currentSnapshot.repositoryRoot
            )
            snapshot = WorkspaceSnapshot(
                repositoryRoot: currentSnapshot.repositoryRoot,
                commit: pinnedCommit,
                wasDirty: currentSnapshot.wasDirty
            )
        } else {
            snapshot = currentSnapshot
        }
        let sessionID = UUID()
        let destination = store.workspacesURL.appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw AgentBridgeError.git("The isolated workspace path already exists.")
        }
        do {
            try AuditStore.createPrivateDirectory(destination, fileManager: fileManager)
            _ = try await runGit(arguments: [
                "-c", "core.hooksPath=/dev/null",
                "-c", "uploadpack.packObjectsHook=",
                "clone", "--no-local", "--no-hardlinks", "--no-checkout", "--",
                snapshot.repositoryRoot.path, destination.path
            ], workingDirectory: nil)
            guard isDirectory(destination), !isSymbolicLink(destination) else {
                throw AgentBridgeError.git("The isolated workspace after the Git clone is not a regular directory.")
            }
            guard chmod(destination.path, mode_t(0o700)) == 0 else {
                throw AgentBridgeError.git("Could not set permissions on the isolated workspace.")
            }
            _ = try await runGit(arguments: ["-C", destination.path, "remote", "remove", "origin"], workingDirectory: nil)
            let alternateObjects = destination.appendingPathComponent(".git/objects/info/alternates")
            guard !fileManager.fileExists(atPath: alternateObjects.path) else {
                throw AgentBridgeError.git("The isolated clone must not depend on the source Git object directory.")
            }
            _ = try await runGit(arguments: [
                "-c", "core.hooksPath=/dev/null",
                "-c", "filter.lfs.smudge=",
                "-c", "filter.lfs.required=false",
                "-C", destination.path, "checkout", "--detach", snapshot.commit
            ], workingDirectory: nil)
            let actualCommit = try await gitText(["-C", destination.path, "rev-parse", "HEAD"])
            guard actualCommit == snapshot.commit else {
                throw AgentBridgeError.git("The isolated workspace commit does not match the source.")
            }
            let record = SessionRecord(
                id: sessionID,
                provider: provider,
                sourceRepositoryPath: snapshot.repositoryRoot.path,
                workspacePath: destination.path,
                snapshotCommit: snapshot.commit,
                sourceWasDirty: snapshot.wasDirty,
                policy: SessionPolicy(accessMode: accessMode, workspaceReadOnly: accessMode == .readOnly, apiModeAllowed: false),
                accountProfileID: accountProfileID
            )
            if accessMode == .isolatedChanges { _ = try await privateBase(for: record) }
            try store.saveSession(record)
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "session.created", message: "Created an isolated workspace for commit \(snapshot.commit.prefix(12)); uncommitted source changes: \(snapshot.wasDirty ? "not included" : "not present")."))
            return record
        } catch {
            if isWithinManagedWorkspaces(destination), fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if let error = error as? AgentBridgeError { throw error }
            throw AgentBridgeError.git("Git could not create an isolated clone for the commit.")
        }
    }

    /// Validates a destination for an explicitly confirmed new project. The
    /// path must be absolute, unused, free of symlink components, and outside
    /// all existing Git repositories.
    func validateNewProjectDestination(path: String) throws -> URL {
        let destination = try validatedAbsolutePath(path)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let components = destination.path.split(separator: "/")
        guard !components.isEmpty else { throw AgentBridgeError.invalidInput("Choose a new local project folder.") }
        for component in components.dropLast() {
            current.appendPathComponent(String(component), isDirectory: true)
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.invalidInput("The parent folder of the new project path must exist and must not contain symbolic links.")
            }
        }
        var destinationMetadata = stat()
        guard lstat(destination.path, &destinationMetadata) != 0, errno == ENOENT else {
            throw AgentBridgeError.invalidInput("The new project destination must be a folder that does not exist yet; existing content will not be overwritten.")
        }
        var ancestor = destination.deletingLastPathComponent()
        while ancestor.path != "/" {
            let gitMetadata = ancestor.appendingPathComponent(".git")
            var gitInfo = stat()
            if lstat(gitMetadata.path, &gitInfo) == 0 {
                throw AgentBridgeError.invalidInput("A new project cannot be created inside an existing Git repository.")
            }
            var headInfo = stat()
            var objectsInfo = stat()
            var refsInfo = stat()
            if lstat(ancestor.appendingPathComponent("HEAD").path, &headInfo) == 0,
               lstat(ancestor.appendingPathComponent("objects").path, &objectsInfo) == 0,
               (objectsInfo.st_mode & S_IFMT) == S_IFDIR,
               lstat(ancestor.appendingPathComponent("refs").path, &refsInfo) == 0,
               (refsInfo.st_mode & S_IFMT) == S_IFDIR {
                throw AgentBridgeError.invalidInput("A new project cannot be created inside an existing Git repository.")
            }
            ancestor.deleteLastPathComponent()
        }
        return destination
    }

    /// Creates an empty local repository with one empty scaffold commit. Git
    /// global/system config, templates, hooks, remotes, and user content are
    /// excluded from this operation.
    func createEmptyProjectRepository(path: String) async throws -> WorkspaceSnapshot {
        let destination = try validateNewProjectDestination(path: path)
        guard mkdir(destination.path, mode_t(0o700)) == 0 else {
            throw AgentBridgeError.git("Could not create the new project folder; the destination may already have been created.")
        }
        do {
            _ = try await runGit(arguments: [
                "-c", "init.defaultBranch=main", "init", "--quiet", "--", destination.path
            ], workingDirectory: nil)
            _ = try await runGit(arguments: [
                "-c", "user.name=AgentBridge",
                "-c", "user.email=agentbridge@localhost",
                "-c", "commit.gpgsign=false",
                "-C", destination.path,
                "commit", "--allow-empty", "-m", "Initialize AgentBridge project"
            ], workingDirectory: nil)
            guard isDirectory(destination), !isSymbolicLink(destination),
                  isDirectory(destination.appendingPathComponent(".git")),
                  !isSymbolicLink(destination.appendingPathComponent(".git")) else {
                throw AgentBridgeError.git("The new project's Git structure could not be confirmed safely.")
            }
            let commit = try await gitText(["-C", destination.path, "rev-parse", "HEAD"])
            guard commit.range(of: #"^[0-9a-fA-F]{40,64}$"#, options: .regularExpression) != nil else {
                throw AgentBridgeError.git("Could not confirm the new project's initial commit.")
            }
            let tree = try await runGit(arguments: ["-C", destination.path, "ls-tree", "-r", "--name-only", "HEAD"], workingDirectory: nil)
            guard !tree.outputWasTruncated, tree.standardOutput.isEmpty else {
                throw AgentBridgeError.git("The new project's initial commit contains unexpected files.")
            }
            let status = try await runGit(arguments: [
                "-C", destination.path, "status", "--porcelain=v1", "--untracked-files=normal"
            ], workingDirectory: nil)
            guard !status.outputWasTruncated, status.standardOutput.isEmpty else {
                throw AgentBridgeError.git("Unexpected files appeared in the new project after initialization.")
            }
            return WorkspaceSnapshot(repositoryRoot: destination, commit: commit.lowercased(), wasDirty: false)
        } catch {
            if Self.directoryContainsOnlyGitMetadata(destination) {
                try? fileManager.removeItem(at: destination)
            }
            if let error = error as? AgentBridgeError { throw error }
            throw AgentBridgeError.git("Could not safely initialize the new local Git project.")
        }
    }

    /// Read-only repository inspection for an attach-existing handoff.
    func inspectProjectRepository(path: String) async throws -> WorkspaceSnapshot {
        try await inspectSourceRepository(path: path)
    }

    public func validateWorkspace(for session: SessionRecord, accessMode: AccessMode = .readOnly) async throws {
        guard session.policy.accessMode == accessMode,
              session.policy.workspaceReadOnly == (accessMode == .readOnly) else {
            throw AgentBridgeError.sessionMismatch("The session permissions do not match the requested run mode. Create a session with the matching mode.")
        }
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        guard isWithinManagedWorkspaces(workspace), isDirectory(workspace), !isSymbolicLink(workspace),
              workspace.lastPathComponent == session.id.uuidString.lowercased() else {
            throw AgentBridgeError.sessionMismatch("The session workspace is outside AgentBridge's managed isolated directory.")
        }
        // Providers can edit an isolated-change workspace, `.git` included, so its
        // review reads the pinned commit from the private base instead.
        if accessMode == .isolatedChanges {
            _ = try await privateBase(for: session)
            return
        }
        let gitMetadata = workspace.appendingPathComponent(".git")
        guard isDirectory(gitMetadata), !isSymbolicLink(gitMetadata) else {
            throw AgentBridgeError.sessionMismatch("The isolated workspace has lost its Git metadata.")
        }
        let alternateObjects = gitMetadata.appendingPathComponent("objects/info/alternates")
        guard !fileManager.fileExists(atPath: alternateObjects.path) else {
            throw AgentBridgeError.sessionMismatch("The isolated workspace still references another Git object directory.")
        }
        let topLevel = try await gitText(["-C", workspace.path, "rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL.path == workspace.path else {
            throw AgentBridgeError.sessionMismatch("The Git workspace root does not match the session record.")
        }
        let commit = try await gitText(["-C", workspace.path, "rev-parse", "HEAD"])
        guard commit == session.snapshotCommit else { throw AgentBridgeError.workspaceChanged }
    }

    /// AgentBridge's own copy of the pinned commit, in the private data root. Review,
    /// restore and verification read the commit and Git settings from here, never from
    /// the workspace's `.git`, which a provider or a terminal command can change.
    /// Only that one commit is fetched, and Git rehashes every object it receives.
    func privateBase(for session: SessionRecord) async throws -> URL {
        let bases = store.rootURL.appendingPathComponent("base-repositories", isDirectory: true)
        let base = bases.appendingPathComponent("\(session.id.uuidString.lowercased()).git", isDirectory: true)
        if try await privateBaseHasCommit(base, session.snapshotCommit) { return base }
        try AuditStore.createPrivateDirectory(bases, fileManager: fileManager)
        let staging = bases.appendingPathComponent(".staging-\(UUID().uuidString.lowercased()).git", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        _ = try await runGit(arguments: ["init", "--quiet", "--bare", "--template=", "--", staging.path], workingDirectory: nil)
        let source = URL(fileURLWithPath: session.sourceRepositoryPath, isDirectory: true).standardizedFileURL
        do {
            _ = try await runGit(arguments: [
                "--git-dir", staging.path, "-c", "protocol.version=2", "-c", "transfer.fsckObjects=true",
                "fetch", "--quiet", "--depth", "1", "--no-tags", source.path,
                "\(session.snapshotCommit):\(Self.privateBaseReference)"
            ], workingDirectory: nil, timeout: 300)
            _ = try await runGit(arguments: [
                "--git-dir", staging.path, "symbolic-ref", "HEAD", Self.privateBaseReference
            ], workingDirectory: nil)
        } catch {
            throw AgentBridgeError.sessionMismatch("The source repository no longer has this session's commit, so its changes cannot be reviewed. Create a new session.")
        }
        guard try await privateBaseHasCommit(staging, session.snapshotCommit) else {
            throw AgentBridgeError.git("The private copy of the session's commit could not be confirmed.")
        }
        if fileManager.fileExists(atPath: base.path) { try fileManager.removeItem(at: base) }
        do {
            try fileManager.moveItem(at: staging, to: base)
        } catch {
            // Another process may have finished the same copy first.
            guard try await privateBaseHasCommit(base, session.snapshotCommit) else { throw error }
        }
        return base
    }

    /// The branch that holds the pinned commit, so a clone of the base carries it.
    private static let privateBaseReference = "refs/heads/agentbridge-base"

    private func privateBaseHasCommit(_ base: URL, _ commit: String) async throws -> Bool {
        guard isDirectory(base), !isSymbolicLink(base) else { return false }
        let result = try await runGit(
            arguments: ["--git-dir", base.path, "rev-parse", "--verify", "--quiet", "\(Self.privateBaseReference)^{commit}"],
            workingDirectory: nil,
            allowedExitCodes: [0, 1, 128]
        )
        return result.exitCode == 0
            && String(decoding: result.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == commit
    }

    /// Git arguments that read `workTree` against the private base, with a fresh index
    /// of the pinned commit. Nothing in the work tree's own `.git` is read, so it can
    /// neither hide an edit nor make Git run a program.
    private struct ReviewRepository {
        let arguments: [String]
        let index: URL
    }

    private func withReviewRepository<T>(
        _ session: SessionRecord,
        workTree: URL,
        _ body: (ReviewRepository) async throws -> T
    ) async throws -> T {
        let base = try await privateBase(for: session)
        let directory = store.rootURL.appendingPathComponent("tmp/git", isDirectory: true)
        try AuditStore.createPrivateDirectory(directory, fileManager: fileManager)
        let index = directory.appendingPathComponent("index-\(UUID().uuidString.lowercased())")
        defer {
            try? fileManager.removeItem(at: index)
            try? fileManager.removeItem(at: index.appendingPathExtension("lock"))
        }
        let review = ReviewRepository(
            arguments: ["--git-dir", base.path, "--work-tree", workTree.path, "-C", workTree.path],
            index: index
        )
        _ = try await reviewGit(review, ["read-tree", session.snapshotCommit])
        return try await body(review)
    }

    private func reviewGit(
        _ review: ReviewRepository,
        _ arguments: [String],
        allowedExitCodes: Set<Int32> = [0],
        outputLimit: Int = 256_000
    ) async throws -> ProcessResult {
        try await runGit(
            arguments: review.arguments + arguments,
            workingDirectory: nil,
            allowedExitCodes: allowedExitCodes,
            outputLimit: outputLimit,
            indexFile: review.index
        )
    }

    /// Whether `.codex/ci.sh` is still the executable file from the pinned commit.
    func projectVerificationScriptIsUnchanged(for session: SessionRecord) async throws -> Bool {
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        let path = ".codex/ci.sh"
        try validateNoSymlinkParent(of: workspace.appendingPathComponent(path), inside: workspace)
        return try await withReviewRepository(session, workTree: workspace) { review in
            let hash = String(decoding: try await reviewGit(review, ["hash-object", "--no-filters", "--", path]).standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let entry = try await reviewGit(review, ["ls-tree", "-z", session.snapshotCommit, "--", path])
            return entry.standardOutput == Data("100755 blob \(hash)\t\(path)\0".utf8)
        }
    }

    public func diff(for session: SessionRecord) async throws -> WorkspaceChangeDiff {
        guard session.policy.accessMode == .isolatedChanges else {
            throw AgentBridgeError.sessionMismatch("Only isolated-change sessions can review changes.")
        }
        try await validateWorkspace(for: session, accessMode: .isolatedChanges)
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        return try await withReviewRepository(session, workTree: workspace) { review in
            try await changeDiff(review, baseCommit: session.snapshotCommit)
        }
    }

    private func changeDiff(_ review: ReviewRepository, baseCommit: String) async throws -> WorkspaceChangeDiff {
        let trackedResult = try await reviewGit(review, [
            "diff", "--name-status", "-z", "--no-renames", baseCommit, "--"
        ])
        let trackedEntries = try parseNameStatus(trackedResult.standardOutput)
        let untrackedResult = try await reviewGit(review, [
            "ls-files", "--others", "--exclude-standard", "-z", "--"
        ], outputLimit: Self.maximumIndexListingBytes)
        let untrackedPaths = try parseNULSeparatedPaths(untrackedResult.standardOutput)
        let trackedPaths = Set(trackedEntries.map(\.path))
        let allPaths = (trackedEntries.map(\.path) + untrackedPaths.filter { !trackedPaths.contains($0) }).sorted()

        var fileDiffs: [ChangeFileDiff] = []
        var combinedPatch = Data()
        for path in allPaths {
            // Git lists a folder holding its own `.git` as one entry and never looks inside.
            if path.hasSuffix("/") {
                throw AgentBridgeError.sessionMismatch("\(path) in the workspace is its own Git repository, so its files cannot be reviewed. Remove its .git folder, or restore all changes.")
            }
            try validateRelativeGitPath(path)
            let isUntracked = !trackedPaths.contains(path)
            let arguments: [String]
            if isUntracked {
                arguments = [
                    "diff", "--no-index", "--no-ext-diff", "--no-textconv",
                    "--no-color", "--binary", "--unified=3", "--", "/dev/null", path
                ]
            } else {
                arguments = [
                    "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                    "--binary", "--unified=3", "--no-renames", baseCommit, "--", path
                ]
            }
            let patchResult = try await reviewGit(
                review,
                arguments,
                allowedExitCodes: isUntracked ? [0, 1] : [0],
                outputLimit: max(1, Self.maximumPatchBytes - combinedPatch.count)
            )
            guard !patchResult.outputWasTruncated,
                  combinedPatch.count + patchResult.standardOutput.count <= Self.maximumPatchBytes else {
                throw AgentBridgeError.git("The full diff exceeds the size limit; split the session before exporting.")
            }
            combinedPatch.append(contentsOf: patchResult.standardOutput)
            // Only the shown text is limited. Every byte stays in the combined patch,
            // so one long or non-UTF-8 file cannot stop the whole session being reviewed.
            let patchText = String(decoding: patchResult.standardOutput, as: UTF8.self)
            let isTooLargeToDisplay = patchResult.standardOutput.count > Self.maximumDisplayedPatchBytes
            let trackedStatus = trackedEntries.first(where: { $0.path == path })?.status
            fileDiffs.append(ChangeFileDiff(
                path: path,
                status: isUntracked ? .untracked : Self.changeFileStatus(trackedStatus ?? ""),
                patch: isTooLargeToDisplay ? "" : patchText,
                isBinary: patchText.contains("Binary files ") || patchText.contains("GIT binary patch"),
                isTooLargeToDisplay: isTooLargeToDisplay,
                hasUndecodableText: String(data: patchResult.standardOutput, encoding: .utf8) == nil
            ))
        }
        // A clone starts with no ignored files, so these all appeared during the session.
        // `--directory` keeps a build folder to one entry.
        let ignoredResult = try await reviewGit(review, [
            "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z", "--"
        ])
        guard !ignoredResult.outputWasTruncated else { throw AgentBridgeError.git("The Git file index exceeds the size limit.") }
        return WorkspaceChangeDiff(
            baseCommit: baseCommit,
            files: fileDiffs,
            patch: combinedPatch,
            ignoredPaths: ignoredResult.standardOutput
                .split(separator: 0)
                .map { String(decoding: $0, as: UTF8.self) }
                .sorted()
        )
    }

    /// Builds what verification runs: the pinned commit plus exactly this patch.
    /// Git-ignored files stay behind, so a pass cannot rest on anything outside the
    /// digest. The commit comes from the private base, not the workspace.
    func createVerificationCheckout(for session: SessionRecord, patch: Data, at destination: URL) async throws {
        let base = try await privateBase(for: session)
        _ = try await runGit(arguments: [
            "clone", "--quiet", "--no-hardlinks", "--no-checkout", "--template=", "--", base.path, destination.path
        ], workingDirectory: nil)
        _ = try await runGit(arguments: ["-C", destination.path, "remote", "remove", "origin"], workingDirectory: nil)
        _ = try await runGit(arguments: [
            "-c", "filter.lfs.smudge=",
            "-c", "filter.lfs.required=false",
            "-C", destination.path, "checkout", "--detach", session.snapshotCommit
        ], workingDirectory: nil)
        guard try await gitText(["-C", destination.path, "rev-parse", "HEAD"]) == session.snapshotCommit else {
            throw AgentBridgeError.git("The verification checkout commit does not match the session.")
        }
        guard !patch.isEmpty else { return }
        _ = try await runGit(
            arguments: ["-C", destination.path, "apply", "--binary"],
            workingDirectory: nil,
            standardInput: patch
        )
    }

    /// Whether a finished verification left the checkout's diff as it started. Verified
    /// code could write the checkout's `.git`, so the diff is read against the private
    /// base, and anything that hides an edit or blocks the review counts as a change.
    func verificationCheckoutMatches(_ checkout: URL, session: SessionRecord, digest: String) async throws -> Bool {
        guard isDirectory(checkout), !isSymbolicLink(checkout) else { return false }
        do {
            return try await withReviewRepository(session, workTree: checkout) { review in
                try await changeDiff(review, baseCommit: session.snapshotCommit)
            }.digest == digest
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { throw error }
            return false
        }
    }

    private static let maximumPatchBytes = 10 * 1_024 * 1_024
    private static let maximumDisplayedPatchBytes = 1_048_576
    private static let maximumIndexListingBytes = 64 * 1_024 * 1_024

    public func restoreFiles(for session: SessionRecord, paths: [String]) async throws {
        guard session.policy.accessMode == .isolatedChanges else {
            throw AgentBridgeError.sessionMismatch("Only isolated-change sessions can restore files.")
        }
        try await validateWorkspace(for: session, accessMode: .isolatedChanges)
        guard !paths.isEmpty else { throw AgentBridgeError.invalidInput("Choose at least one file to restore.") }
        let requestedPaths = Set(try paths.map { try validateRelativeGitPath($0) })
        let diff = try await diff(for: session)
        let changedPaths = Set(diff.files.map(\.path))
        guard requestedPaths.isSubset(of: changedPaths) else {
            throw AgentBridgeError.invalidInput("Only files listed in the current diff can be restored.")
        }
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        try await withReviewRepository(session, workTree: workspace) { review in
            for path in requestedPaths.sorted() {
                let inBaseCommit = try await reviewGit(review, ["ls-tree", "-z", "--name-only", session.snapshotCommit, "--", path])
                guard !inBaseCommit.outputWasTruncated else { throw AgentBridgeError.git("The Git base file list exceeds the size limit.") }
                if !inBaseCommit.standardOutput.isEmpty {
                    _ = try await reviewGit(review, ["checkout", session.snapshotCommit, "--", path])
                    continue
                }
                let fileURL = workspace.appendingPathComponent(path)
                try validateNoSymlinkParent(of: fileURL, inside: workspace)
                var metadata = stat()
                guard lstat(fileURL.path, &metadata) == 0,
                      (metadata.st_mode & S_IFMT) == S_IFREG || (metadata.st_mode & S_IFMT) == S_IFLNK else {
                    throw AgentBridgeError.git("A new file changed or is not a regular file; nothing was restored.")
                }
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    public func restoreAllChanges(for session: SessionRecord) async throws {
        guard session.policy.accessMode == .isolatedChanges else {
            throw AgentBridgeError.sessionMismatch("Only isolated-change sessions can restore files.")
        }
        try await validateWorkspace(for: session, accessMode: .isolatedChanges)
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        try await withReviewRepository(session, workTree: workspace) { review in
            _ = try await reviewGit(review, ["checkout", "--force", session.snapshotCommit, "--", "."])
            _ = try await reviewGit(review, ["clean", "-fd", "--"])
        }
    }

    public func applyChangesToLocalBranch(for session: SessionRecord, branchName: String) async throws -> BranchApplyResult {
        guard session.policy.accessMode == .isolatedChanges else {
            throw AgentBridgeError.sessionMismatch("Only isolated-change sessions can be applied to a local branch.")
        }
        let diff = try await diff(for: session)
        return try await applyVerifiedChangesToLocalBranch(for: session, branchName: branchName, diff: diff)
    }

    func applyVerifiedChangesToLocalBranch(
        for session: SessionRecord,
        branchName: String,
        diff: WorkspaceChangeDiff
    ) async throws -> BranchApplyResult {
        guard session.policy.accessMode == .isolatedChanges else {
            throw AgentBridgeError.sessionMismatch("Only isolated-change sessions can be applied to a local branch.")
        }
        try await validateWorkspace(for: session, accessMode: .isolatedChanges)
        try validateVerifiedDiff(diff, for: session)
        guard !diff.files.isEmpty, !diff.patch.isEmpty else {
            throw AgentBridgeError.invalidInput("The workspace has no changes to apply.")
        }
        let source = URL(fileURLWithPath: session.sourceRepositoryPath, isDirectory: true).standardizedFileURL
        try await validateSourceRepository(source, expectedCommit: session.snapshotCommit)
        try await validateBranchName(branchName, in: source)

        let branchRef = "refs/heads/\(branchName)"
        let existingBranch = try await runGit(
            arguments: ["-C", source.path, "show-ref", "--verify", "--quiet", branchRef],
            workingDirectory: nil,
            allowedExitCodes: [0, 1]
        )
        let branchAlreadyExists = existingBranch.exitCode == 0
        if branchAlreadyExists {
            let branchCommit = try await gitText([
                "-C", source.path, "rev-parse", "--verify", "--end-of-options", "\(branchRef)^{commit}"
            ])
            guard branchCommit == session.snapshotCommit else {
                throw AgentBridgeError.sourceBaseConflict(expected: session.snapshotCommit, actual: branchCommit)
            }
        }

        try AuditStore.createPrivateDirectory(store.workspacesURL, fileManager: fileManager)
        let destination = store.workspacesURL.appendingPathComponent(
            "apply-\(session.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        var worktreeAdded = false
        var branchCreated = false
        do {
            var arguments = ["-C", source.path, "worktree", "add"]
            if !branchAlreadyExists {
                arguments += ["-b", branchName, destination.path, session.snapshotCommit]
            } else {
                arguments += [destination.path, branchName]
            }
            _ = try await runGit(arguments: arguments, workingDirectory: nil)
            worktreeAdded = true
            branchCreated = !branchAlreadyExists
            guard isWithinManagedWorkspaces(destination), isDirectory(destination), !isSymbolicLink(destination) else {
                throw AgentBridgeError.git("The created branch worktree is not inside an AgentBridge-managed isolated folder.")
            }
            try await validateSourceRepository(source, expectedCommit: session.snapshotCommit)
            _ = try await runGit(
                arguments: ["-C", destination.path, "apply", "--binary", "--check"],
                workingDirectory: nil,
                standardInput: diff.patch
            )
            _ = try await runGit(
                arguments: ["-C", destination.path, "apply", "--binary"],
                workingDirectory: nil,
                standardInput: diff.patch
            )
            return BranchApplyResult(branchName: branchName, worktreePath: destination.path, changedFileCount: diff.files.count)
        } catch {
            if worktreeAdded {
                _ = try? await runGit(arguments: ["-C", source.path, "worktree", "remove", "--force", destination.path], workingDirectory: nil)
            }
            if branchCreated,
               (try? await gitText(["-C", source.path, "rev-parse", "--verify", "--end-of-options", "\(branchRef)^{commit}"])) == session.snapshotCommit {
                _ = try? await runGit(arguments: ["-C", source.path, "branch", "-D", branchName], workingDirectory: nil)
            }
            if let error = error as? AgentBridgeError { throw error }
            throw AgentBridgeError.git("Could not apply the changes to the specified local branch; the source working directory is unchanged.")
        }
    }

    private func validateVerifiedDiff(_ diff: WorkspaceChangeDiff, for session: SessionRecord) throws {
        guard diff.baseCommit == session.snapshotCommit,
              session.verificationPassed == true,
              let verifiedAt = session.verificationCompletedAt,
              let lastChangeAt = session.lastChangeRunAt,
              verifiedAt >= lastChangeAt,
              session.verificationDiffDigest == diff.digest else {
            throw AgentBridgeError.verificationRequired
        }
    }

    private func inspectSourceRepository(path: String) async throws -> WorkspaceSnapshot {
        let input = try validatedAbsolutePath(path)
        guard isDirectory(input), !isSymbolicLink(input) else {
            throw AgentBridgeError.invalidInput("The source must be a regular directory. Choose the Git root, not a symlink.")
        }
        let sourceGitMetadata = input.appendingPathComponent(".git")
        guard isDirectory(sourceGitMetadata), !isSymbolicLink(sourceGitMetadata) else {
            throw AgentBridgeError.invalidInput("The source must be a full Git repository. Linked worktrees are not supported.")
        }
        let topLevel = try await gitText(["-C", input.path, "rev-parse", "--show-toplevel"])
        let root = URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL
        guard root.path == input.path else {
            throw AgentBridgeError.invalidInput("Select the Git repository root directly.")
        }
        let commit = try await gitText(["-C", root.path, "rev-parse", "HEAD"])
        guard commit.range(of: #"^[0-9a-fA-F]{40,64}$"#, options: .regularExpression) != nil else {
            throw AgentBridgeError.git("Could not confirm the source commit.")
        }
        let status = try await runGit(arguments: ["-C", root.path, "status", "--porcelain=v1", "--untracked-files=normal"], workingDirectory: nil)
        guard !status.outputWasTruncated else { throw AgentBridgeError.git("The source status output exceeds the size limit.") }
        return WorkspaceSnapshot(repositoryRoot: root, commit: commit.lowercased(), wasDirty: !status.standardOutput.isEmpty)
    }

    private func validatedAbsolutePath(_ path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix("/"), !path.contains("\0"),
              path.utf8.count <= 4_096,
              !components.contains(where: { $0 == ".." }),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentBridgeError.invalidInput("Choose a valid absolute local folder path.")
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    private static func directoryContainsOnlyGitMetadata(_ url: URL) -> Bool {
        var directoryInfo = stat()
        guard lstat(url.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
        do {
            let children = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return children == [".git"] && {
                var gitInfo = stat()
                return lstat(url.appendingPathComponent(".git").path, &gitInfo) == 0
                    && (gitInfo.st_mode & S_IFMT) == S_IFDIR
            }()
        } catch {
            return false
        }
    }

    private func resolveSnapshotCommit(_ requested: String, repositoryRoot: URL) async throws -> String {
        guard requested.range(of: #"^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"#, options: .regularExpression) != nil else {
            throw AgentBridgeError.invalidInput("The pinned commit must be a full 40- or 64-character Git hash.")
        }
        let normalized = requested.lowercased()
        let resolved = try await gitText([
            "-C", repositoryRoot.path,
            "rev-parse", "--verify", "--end-of-options", "\(normalized)^{commit}"
        ]).lowercased()
        guard resolved == normalized else {
            throw AgentBridgeError.git("The pinned commit does not exist or is not a complete commit in this source repository.")
        }
        return resolved
    }

    private func validateSourceRepository(_ source: URL, expectedCommit: String) async throws {
        guard isDirectory(source), !isSymbolicLink(source) else {
            throw AgentBridgeError.sessionMismatch("The original Git repository no longer exists or is no longer a regular folder.")
        }
        let gitMetadata = source.appendingPathComponent(".git")
        guard isDirectory(gitMetadata), !isSymbolicLink(gitMetadata) else {
            throw AgentBridgeError.sessionMismatch("The original Git repository structure changed, so the changes cannot be applied safely.")
        }
        let topLevel = try await gitText(["-C", source.path, "rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL.path == source.path else {
            throw AgentBridgeError.sessionMismatch("The original repository root does not match the session record.")
        }
        let actualCommit = try await gitText(["-C", source.path, "rev-parse", "HEAD"])
        guard actualCommit == expectedCommit else {
            throw AgentBridgeError.sourceBaseConflict(expected: expectedCommit, actual: actualCommit)
        }
    }

    private func validateBranchName(_ name: String, in repository: URL) async throws {
        guard !name.isEmpty, !name.hasPrefix("-"), name.utf8.count <= 200,
              !name.contains("@{-"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw AgentBridgeError.invalidInput("Enter a valid local branch name.")
        }
        let result = try await runGit(
            arguments: ["-C", repository.path, "check-ref-format", "--branch", name],
            workingDirectory: nil
        )
        guard !result.outputWasTruncated else {
            throw AgentBridgeError.invalidInput("Enter a valid local branch name.")
        }
    }

    private func parseNameStatus(_ data: Data) throws -> [(status: String, path: String)] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true).map { Data($0) }
        guard fields.count.isMultiple(of: 2) else { throw AgentBridgeError.git("The Git file diff format is not recognized.") }
        var entries: [(status: String, path: String)] = []
        for index in stride(from: 0, to: fields.count, by: 2) {
            guard let status = String(data: fields[index], encoding: .utf8),
                  let path = String(data: fields[index + 1], encoding: .utf8),
                  !status.isEmpty, !path.isEmpty else {
                throw AgentBridgeError.git("The Git file diff contains paths that cannot be displayed.")
            }
            entries.append((status: status, path: path))
        }
        return entries
    }

    private func parseNULSeparatedPaths(_ data: Data) throws -> [String] {
        try data.split(separator: 0, omittingEmptySubsequences: true).map { field in
            guard let path = String(data: Data(field), encoding: .utf8), !path.isEmpty else {
                throw AgentBridgeError.git("The Git untracked file list contains paths that cannot be displayed.")
            }
            return path
        }
    }

    @discardableResult
    private func validateRelativeGitPath(_ path: String) throws -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.utf8.count <= 4_096,
              !path.hasPrefix("/"),
              !path.contains("\0"),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw AgentBridgeError.invalidInput("A diff path is not a safe relative file path.")
        }
        return path
    }

    private func validateNoSymlinkParent(of fileURL: URL, inside root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw AgentBridgeError.invalidInput("The file path is outside the isolated workspace.")
        }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 1 else { throw AgentBridgeError.invalidInput("The file path is invalid.") }
        var parent = root
        for component in components.dropLast() {
            parent.appendPathComponent(String(component), isDirectory: true)
            var metadata = stat()
            guard lstat(parent.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.invalidInput("The file path's parent folder is not a regular folder.")
            }
        }
    }

    private static func changeFileStatus(_ status: String) -> ChangeFileStatus {
        switch status {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "T": .typeChanged
        default: .unknown
        }
    }

    private func gitText(_ arguments: [String]) async throws -> String {
        let result = try await runGit(arguments: arguments, workingDirectory: nil)
        guard !result.outputWasTruncated,
              let value = String(data: result.standardOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw AgentBridgeError.git("Git returned information that could not be recognized.")
        }
        return value
    }

    private func runGit(
        arguments: [String],
        workingDirectory: URL?,
        standardInput: Data = Data(),
        allowedExitCodes: Set<Int32> = [0],
        outputLimit: Int = 256_000,
        indexFile: URL? = nil,
        timeout: TimeInterval = 60
    ) async throws -> ProcessResult {
        guard fileManager.isExecutableFile(atPath: gitURL.path) else {
            throw AgentBridgeError.git("System Git could not be found.")
        }
        let privateTemp = store.rootURL.appendingPathComponent("tmp/git", isDirectory: true)
        try AuditStore.createPrivateDirectory(privateTemp, fileManager: fileManager)
        let home = store.rootURL.appendingPathComponent("git-home", isDirectory: true)
        try AuditStore.createPrivateDirectory(home, fileManager: fileManager)
        var environment: [String: String] = [
            "HOME": home.path,
            "USER": NSUserName(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": privateTemp.path,
            "LANG": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_ATTR_NOSYSTEM": "1"
        ]
        if let indexFile { environment["GIT_INDEX_FILE"] = indexFile.path }
        let spec = ProcessSpec(
            executableURL: gitURL,
            arguments: [
                "-c", "core.fsmonitor=false",
                "-c", "core.hooksPath=/dev/null",
                "-c", "core.untrackedCache=false",
                "--literal-pathspecs"
            ] + arguments,
            environment: environment,
            workingDirectoryURL: workingDirectory,
            standardInput: standardInput,
            timeout: timeout,
            outputLimit: outputLimit
        )
        let result = try await runner.run(spec)
        if result.timedOut { throw AgentBridgeError.git("The Git operation timed out.") }
        if result.wasCancelled { throw AgentBridgeError.git("The Git operation was cancelled.") }
        guard allowedExitCodes.contains(result.exitCode) else {
            throw AgentBridgeError.git("Git command failed with exit code \(result.exitCode).")
        }
        return result
    }

    private func isWithinManagedWorkspaces(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.path
        return store.managedWorkspaceRootURLs.contains { root in
            let normalizedRoot = root.standardizedFileURL
            let workspaces = normalizedRoot.appendingPathComponent("workspaces", isDirectory: true)
            guard isDirectory(normalizedRoot), !isSymbolicLink(normalizedRoot),
                  isDirectory(workspaces), !isSymbolicLink(workspaces) else { return false }
            return candidate.hasPrefix(workspaces.path + "/")
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFDIR
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && (metadata.st_mode & S_IFMT) == S_IFLNK
    }
}
