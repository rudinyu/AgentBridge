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
        guard isWithinManagedWorkspaces(workspace), isDirectory(workspace), !isSymbolicLink(workspace) else {
            throw AgentBridgeError.sessionMismatch("The session workspace is outside AgentBridge's managed isolated directory.")
        }
        let gitMetadata = workspace.appendingPathComponent(".git")
        guard workspace.lastPathComponent == session.id.uuidString.lowercased(),
              isDirectory(gitMetadata), !isSymbolicLink(gitMetadata) else {
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

    public func diff(for session: SessionRecord) async throws -> WorkspaceChangeDiff {
        guard session.policy.accessMode == .isolatedChanges else {
            throw AgentBridgeError.sessionMismatch("Only isolated-change sessions can review changes.")
        }
        try await validateWorkspace(for: session, accessMode: .isolatedChanges)
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        let trackedResult = try await runGit(arguments: [
            "-C", workspace.path, "diff", "--name-status", "-z", "--no-renames", session.snapshotCommit, "--"
        ], workingDirectory: nil)
        let trackedEntries = try parseNameStatus(trackedResult.standardOutput)
        let untrackedResult = try await runGit(arguments: [
            "-C", workspace.path, "ls-files", "--others", "--exclude-standard", "-z", "--"
        ], workingDirectory: nil)
        let untrackedPaths = try parseNULSeparatedPaths(untrackedResult.standardOutput)
        let trackedPaths = Set(trackedEntries.map(\.path))
        let allPaths = (trackedEntries.map(\.path) + untrackedPaths.filter { !trackedPaths.contains($0) }).sorted()

        var fileDiffs: [ChangeFileDiff] = []
        var combinedPatch = Data()
        for path in allPaths {
            try validateRelativeGitPath(path)
            let isUntracked = !trackedPaths.contains(path)
            let arguments: [String]
            if isUntracked {
                arguments = [
                    "-C", workspace.path, "diff", "--no-index", "--no-ext-diff", "--no-textconv",
                    "--no-color", "--binary", "--unified=3", "--", "/dev/null", path
                ]
            } else {
                arguments = [
                    "-C", workspace.path, "diff", "--no-ext-diff", "--no-textconv", "--no-color",
                    "--binary", "--unified=3", "--no-renames", session.snapshotCommit, "--", path
                ]
            }
            let patchResult = try await runGit(
                arguments: arguments,
                workingDirectory: nil,
                allowedExitCodes: isUntracked ? [0, 1] : [0],
                outputLimit: 1_048_576
            )
            guard !patchResult.outputWasTruncated else {
                throw AgentBridgeError.git("The file diff exceeds the size limit; split the session before reviewing.")
            }
            guard let patchText = String(data: patchResult.standardOutput, encoding: .utf8) else {
                throw AgentBridgeError.git("The Git diff contains file names or content that cannot be displayed.")
            }
            guard combinedPatch.count + patchResult.standardOutput.count <= 10 * 1_024 * 1_024 else {
                throw AgentBridgeError.git("The full diff exceeds the size limit; split the session before exporting.")
            }
            combinedPatch.append(contentsOf: patchResult.standardOutput)
            let trackedStatus = trackedEntries.first(where: { $0.path == path })?.status
            fileDiffs.append(ChangeFileDiff(
                path: path,
                status: isUntracked ? .untracked : Self.changeFileStatus(trackedStatus ?? ""),
                patch: patchText,
                isBinary: patchText.contains("Binary files ") || patchText.contains("GIT binary patch")
            ))
        }
        return WorkspaceChangeDiff(baseCommit: session.snapshotCommit, files: fileDiffs, patch: combinedPatch)
    }

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
        for path in requestedPaths.sorted() {
            let tracked = try await runGit(
                arguments: ["-C", workspace.path, "ls-files", "--error-unmatch", "--", path],
                workingDirectory: nil,
                allowedExitCodes: [0, 1]
            )
            guard !tracked.outputWasTruncated else { throw AgentBridgeError.git("The Git file index exceeds the size limit.") }
            if tracked.exitCode == 0 {
                let inBaseCommit = try await runGit(arguments: [
                    "-C", workspace.path, "ls-tree", "-r", "--name-only", "-z", session.snapshotCommit, "--", path
                ], workingDirectory: nil)
                guard !inBaseCommit.outputWasTruncated else { throw AgentBridgeError.git("The Git base file list exceeds the size limit.") }
                if inBaseCommit.standardOutput.isEmpty {
                    _ = try await runGit(arguments: ["-C", workspace.path, "rm", "-f", "--", path], workingDirectory: nil)
                } else {
                    _ = try await runGit(arguments: [
                        "-C", workspace.path, "restore", "--source", session.snapshotCommit,
                        "--worktree", "--staged", "--", path
                    ], workingDirectory: nil)
                }
            } else {
                let fileURL = workspace.appendingPathComponent(path)
                try validateNoSymlinkParent(of: fileURL, inside: workspace)
                var metadata = stat()
                guard lstat(fileURL.path, &metadata) == 0,
                      (metadata.st_mode & S_IFMT) == S_IFREG || (metadata.st_mode & S_IFMT) == S_IFLNK else {
                    throw AgentBridgeError.git("An untracked file changed or is not a regular file; nothing was restored.")
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
        _ = try await runGit(arguments: ["-C", workspace.path, "reset", "--hard", session.snapshotCommit], workingDirectory: nil)
        _ = try await runGit(arguments: ["-C", workspace.path, "clean", "-fd", "--"], workingDirectory: nil)
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
        outputLimit: Int = 256_000
    ) async throws -> ProcessResult {
        guard fileManager.isExecutableFile(atPath: gitURL.path) else {
            throw AgentBridgeError.git("System Git could not be found.")
        }
        let privateTemp = store.rootURL.appendingPathComponent("tmp/git", isDirectory: true)
        try AuditStore.createPrivateDirectory(privateTemp, fileManager: fileManager)
        let home = store.rootURL.appendingPathComponent("git-home", isDirectory: true)
        try AuditStore.createPrivateDirectory(home, fileManager: fileManager)
        let environment: [String: String] = [
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
            timeout: 60,
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
