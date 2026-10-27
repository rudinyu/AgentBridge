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
            throw AgentBridgeError.invalidInput("尚未設定工作區資料根目錄；請在 App 選擇資料夾，或先執行 `agentbridge workspace set /absolute/path/to/root`。")
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
            throw AgentBridgeError.git("隔離工作區路徑已存在。")
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
                throw AgentBridgeError.git("Git 複製後的隔離工作區不是一般資料夾。")
            }
            guard chmod(destination.path, mode_t(0o700)) == 0 else {
                throw AgentBridgeError.git("無法設定隔離工作區權限。")
            }
            _ = try await runGit(arguments: ["-C", destination.path, "remote", "remove", "origin"], workingDirectory: nil)
            let alternateObjects = destination.appendingPathComponent(".git/objects/info/alternates")
            guard !fileManager.fileExists(atPath: alternateObjects.path) else {
                throw AgentBridgeError.git("隔離複本不得依賴來源 Git 物件資料夾。")
            }
            _ = try await runGit(arguments: [
                "-c", "core.hooksPath=/dev/null",
                "-c", "filter.lfs.smudge=",
                "-c", "filter.lfs.required=false",
                "-C", destination.path, "checkout", "--detach", snapshot.commit
            ], workingDirectory: nil)
            let actualCommit = try await gitText(["-C", destination.path, "rev-parse", "HEAD"])
            guard actualCommit == snapshot.commit else {
                throw AgentBridgeError.git("隔離工作區提交版本與來源不符。")
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
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "session.created", message: "建立提交版本 \(snapshot.commit.prefix(12)) 的隔離工作區；來源未提交變更 \(snapshot.wasDirty ? "不包含" : "不存在")。"))
            return record
        } catch {
            if isWithinManagedWorkspaces(destination), fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            if let error = error as? AgentBridgeError { throw error }
            throw AgentBridgeError.git("Git 無法建立提交版本的隔離複本。")
        }
    }

    public func validateWorkspace(for session: SessionRecord, accessMode: AccessMode = .readOnly) async throws {
        guard session.policy.accessMode == accessMode,
              session.policy.workspaceReadOnly == (accessMode == .readOnly) else {
            throw AgentBridgeError.sessionMismatch("工作階段權限與要求的執行模式不符；請建立符合模式的新工作階段。")
        }
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        guard isWithinManagedWorkspaces(workspace), isDirectory(workspace), !isSymbolicLink(workspace) else {
            throw AgentBridgeError.sessionMismatch("工作階段工作區不在 AgentBridge 管理的隔離資料夾內。")
        }
        let gitMetadata = workspace.appendingPathComponent(".git")
        guard workspace.lastPathComponent == session.id.uuidString.lowercased(),
              isDirectory(gitMetadata), !isSymbolicLink(gitMetadata) else {
            throw AgentBridgeError.sessionMismatch("隔離工作區已失去 Git 中繼資料。")
        }
        let alternateObjects = gitMetadata.appendingPathComponent("objects/info/alternates")
        guard !fileManager.fileExists(atPath: alternateObjects.path) else {
            throw AgentBridgeError.sessionMismatch("隔離工作區仍參照其他 Git 物件資料夾。")
        }
        let topLevel = try await gitText(["-C", workspace.path, "rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL.path == workspace.path else {
            throw AgentBridgeError.sessionMismatch("Git 工作區根目錄與工作階段記錄不符。")
        }
        let commit = try await gitText(["-C", workspace.path, "rev-parse", "HEAD"])
        guard commit == session.snapshotCommit else { throw AgentBridgeError.workspaceChanged }
    }

    public func diff(for session: SessionRecord) async throws -> WorkspaceChangeDiff {
        guard session.policy.accessMode == .isolatedChanges else {
            throw AgentBridgeError.sessionMismatch("只有隔離變更工作階段可以檢視變更。")
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
                throw AgentBridgeError.git("檔案差異超過大小限制；請拆分工作階段後再檢視。")
            }
            guard let patchText = String(data: patchResult.standardOutput, encoding: .utf8) else {
                throw AgentBridgeError.git("Git 差異包含無法顯示的檔名或內容。")
            }
            guard combinedPatch.count + patchResult.standardOutput.count <= 10 * 1_024 * 1_024 else {
                throw AgentBridgeError.git("完整差異超過大小限制；請拆分工作階段後再匯出。")
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
            throw AgentBridgeError.sessionMismatch("只有隔離變更工作階段可以還原檔案。")
        }
        try await validateWorkspace(for: session, accessMode: .isolatedChanges)
        guard !paths.isEmpty else { throw AgentBridgeError.invalidInput("請選擇至少一個要還原的檔案。") }
        let requestedPaths = Set(try paths.map { try validateRelativeGitPath($0) })
        let diff = try await diff(for: session)
        let changedPaths = Set(diff.files.map(\.path))
        guard requestedPaths.isSubset(of: changedPaths) else {
            throw AgentBridgeError.invalidInput("只能還原目前差異中列出的檔案。")
        }
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        for path in requestedPaths.sorted() {
            let tracked = try await runGit(
                arguments: ["-C", workspace.path, "ls-files", "--error-unmatch", "--", path],
                workingDirectory: nil,
                allowedExitCodes: [0, 1]
            )
            guard !tracked.outputWasTruncated else { throw AgentBridgeError.git("Git 檔案索引超過大小限制。") }
            if tracked.exitCode == 0 {
                let inBaseCommit = try await runGit(arguments: [
                    "-C", workspace.path, "ls-tree", "-r", "--name-only", "-z", session.snapshotCommit, "--", path
                ], workingDirectory: nil)
                guard !inBaseCommit.outputWasTruncated else { throw AgentBridgeError.git("Git 基準檔案清單超過大小限制。") }
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
                    throw AgentBridgeError.git("未追蹤檔案已改變或不是一般檔案，未執行還原。")
                }
                try fileManager.removeItem(at: fileURL)
            }
        }
    }

    public func restoreAllChanges(for session: SessionRecord) async throws {
        guard session.policy.accessMode == .isolatedChanges else {
            throw AgentBridgeError.sessionMismatch("只有隔離變更工作階段可以還原檔案。")
        }
        try await validateWorkspace(for: session, accessMode: .isolatedChanges)
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        _ = try await runGit(arguments: ["-C", workspace.path, "reset", "--hard", session.snapshotCommit], workingDirectory: nil)
        _ = try await runGit(arguments: ["-C", workspace.path, "clean", "-fd", "--"], workingDirectory: nil)
    }

    public func applyChangesToLocalBranch(for session: SessionRecord, branchName: String) async throws -> BranchApplyResult {
        guard session.policy.accessMode == .isolatedChanges else {
            throw AgentBridgeError.sessionMismatch("只有隔離變更工作階段可以套用到本機分支。")
        }
        try await validateWorkspace(for: session, accessMode: .isolatedChanges)
        let diff = try await diff(for: session)
        guard !diff.files.isEmpty, !diff.patch.isEmpty else {
            throw AgentBridgeError.invalidInput("工作區沒有可套用的變更。")
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
                throw AgentBridgeError.git("建立的分支工作樹不在 AgentBridge 管理的隔離資料夾內。")
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
            throw AgentBridgeError.git("無法將變更套用到指定的本機分支；來源工作目錄保持不變。")
        }
    }

    private func inspectSourceRepository(path: String) async throws -> WorkspaceSnapshot {
        let input = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        guard input.path.hasPrefix("/") else { throw AgentBridgeError.invalidInput("請選擇本機 Git 資料夾。") }
        guard isDirectory(input), !isSymbolicLink(input) else {
            throw AgentBridgeError.invalidInput("來源必須是一般資料夾；請選擇 Git 根目錄，而非符號連結。")
        }
        let sourceGitMetadata = input.appendingPathComponent(".git")
        guard isDirectory(sourceGitMetadata), !isSymbolicLink(sourceGitMetadata) else {
            throw AgentBridgeError.invalidInput("來源必須是完整 Git 儲存庫；目前不支援 linked worktree。")
        }
        let topLevel = try await gitText(["-C", input.path, "rev-parse", "--show-toplevel"])
        let root = URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL
        guard root.path == input.path else {
            throw AgentBridgeError.invalidInput("請直接選擇 Git 儲存庫根目錄。")
        }
        let commit = try await gitText(["-C", root.path, "rev-parse", "HEAD"])
        guard commit.range(of: #"^[0-9a-fA-F]{40,64}$"#, options: .regularExpression) != nil else {
            throw AgentBridgeError.git("無法確認來源提交版本。")
        }
        let status = try await runGit(arguments: ["-C", root.path, "status", "--porcelain=v1", "--untracked-files=normal"], workingDirectory: nil)
        guard !status.outputWasTruncated else { throw AgentBridgeError.git("來源狀態輸出超過大小限制。") }
        return WorkspaceSnapshot(repositoryRoot: root, commit: commit.lowercased(), wasDirty: !status.standardOutput.isEmpty)
    }

    private func resolveSnapshotCommit(_ requested: String, repositoryRoot: URL) async throws -> String {
        guard requested.range(of: #"^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$"#, options: .regularExpression) != nil else {
            throw AgentBridgeError.invalidInput("指定的固定提交必須是完整的 40 或 64 位 Git 雜湊。")
        }
        let normalized = requested.lowercased()
        let resolved = try await gitText([
            "-C", repositoryRoot.path,
            "rev-parse", "--verify", "--end-of-options", "\(normalized)^{commit}"
        ]).lowercased()
        guard resolved == normalized else {
            throw AgentBridgeError.git("指定的固定提交不存在，或不是這個來源儲存庫中的完整提交。")
        }
        return resolved
    }

    private func validateSourceRepository(_ source: URL, expectedCommit: String) async throws {
        guard isDirectory(source), !isSymbolicLink(source) else {
            throw AgentBridgeError.sessionMismatch("原始 Git 儲存庫已不存在或不再是一般資料夾。")
        }
        let gitMetadata = source.appendingPathComponent(".git")
        guard isDirectory(gitMetadata), !isSymbolicLink(gitMetadata) else {
            throw AgentBridgeError.sessionMismatch("原始 Git 儲存庫結構已改變，無法安全套用變更。")
        }
        let topLevel = try await gitText(["-C", source.path, "rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: topLevel, isDirectory: true).standardizedFileURL.path == source.path else {
            throw AgentBridgeError.sessionMismatch("原始儲存庫根目錄與工作階段記錄不符。")
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
            throw AgentBridgeError.invalidInput("請輸入有效的本機分支名稱。")
        }
        let result = try await runGit(
            arguments: ["-C", repository.path, "check-ref-format", "--branch", name],
            workingDirectory: nil
        )
        guard !result.outputWasTruncated else {
            throw AgentBridgeError.invalidInput("請輸入有效的本機分支名稱。")
        }
    }

    private func parseNameStatus(_ data: Data) throws -> [(status: String, path: String)] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: true).map { Data($0) }
        guard fields.count.isMultiple(of: 2) else { throw AgentBridgeError.git("Git 檔案差異格式無法辨識。") }
        var entries: [(status: String, path: String)] = []
        for index in stride(from: 0, to: fields.count, by: 2) {
            guard let status = String(data: fields[index], encoding: .utf8),
                  let path = String(data: fields[index + 1], encoding: .utf8),
                  !status.isEmpty, !path.isEmpty else {
                throw AgentBridgeError.git("Git 檔案差異包含無法顯示的路徑。")
            }
            entries.append((status: status, path: path))
        }
        return entries
    }

    private func parseNULSeparatedPaths(_ data: Data) throws -> [String] {
        try data.split(separator: 0, omittingEmptySubsequences: true).map { field in
            guard let path = String(data: Data(field), encoding: .utf8), !path.isEmpty else {
                throw AgentBridgeError.git("Git 未追蹤檔案清單包含無法顯示的路徑。")
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
            throw AgentBridgeError.invalidInput("差異路徑不是安全的相對檔案路徑。")
        }
        return path
    }

    private func validateNoSymlinkParent(of fileURL: URL, inside root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw AgentBridgeError.invalidInput("檔案路徑超出隔離工作區。")
        }
        let relative = String(filePath.dropFirst(rootPath.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count >= 1 else { throw AgentBridgeError.invalidInput("檔案路徑無效。") }
        var parent = root
        for component in components.dropLast() {
            parent.appendPathComponent(String(component), isDirectory: true)
            var metadata = stat()
            guard lstat(parent.path, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFDIR else {
                throw AgentBridgeError.invalidInput("檔案路徑的父資料夾不是一般資料夾。")
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
            throw AgentBridgeError.git("Git 回傳無法辨識的資訊。")
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
            throw AgentBridgeError.git("找不到系統 Git。")
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
        if result.timedOut { throw AgentBridgeError.git("Git 操作逾時。") }
        if result.wasCancelled { throw AgentBridgeError.git("Git 操作已取消。") }
        guard allowedExitCodes.contains(result.exitCode) else {
            throw AgentBridgeError.git("Git 指令失敗，結束代碼 \(result.exitCode)。")
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
