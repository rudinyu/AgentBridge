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

    private func gitText(_ arguments: [String]) async throws -> String {
        let result = try await runGit(arguments: arguments, workingDirectory: nil)
        guard !result.outputWasTruncated,
              let value = String(data: result.standardOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            throw AgentBridgeError.git("Git 回傳無法辨識的資訊。")
        }
        return value
    }

    private func runGit(arguments: [String], workingDirectory: URL?) async throws -> ProcessResult {
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
                "-c", "core.untrackedCache=false"
            ] + arguments,
            environment: environment,
            workingDirectoryURL: workingDirectory,
            standardInput: Data(),
            timeout: 60,
            outputLimit: 256_000
        )
        let result = try await runner.run(spec)
        if result.timedOut { throw AgentBridgeError.git("Git 操作逾時。") }
        if result.wasCancelled { throw AgentBridgeError.git("Git 操作已取消。") }
        guard result.exitCode == 0 else { throw AgentBridgeError.git("Git 指令失敗，結束代碼 \(result.exitCode)。") }
        return result
    }

    private func isWithinManagedWorkspaces(_ url: URL) -> Bool {
        let root = store.workspacesURL.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        return candidate.hasPrefix(root + "/")
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
