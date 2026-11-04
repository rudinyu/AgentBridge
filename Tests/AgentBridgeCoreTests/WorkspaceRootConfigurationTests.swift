import Foundation
import XCTest
@testable import AgentBridgeCore

final class WorkspaceRootConfigurationTests: XCTestCase {
    func testSyncCheckRecognizesCloudFoldersAndIgnoresLocalOnes() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        func service(_ relativePath: String) -> String? {
            WorkspaceRootSyncCheck.syncedServiceName(for: home.appendingPathComponent(relativePath, isDirectory: true), homeDirectory: home)
        }
        XCTAssertEqual(service("Library/Mobile Documents/com~apple~CloudDocs/AgentBridge"), "iCloud Drive")
        XCTAssertEqual(service("Library/CloudStorage/Dropbox/AgentBridge"), "Dropbox")
        XCTAssertEqual(service("Library/CloudStorage/OneDrive-Personal/Data"), "OneDrive")
        XCTAssertEqual(service("Library/CloudStorage/GoogleDrive-me@example.com/My Drive/Data"), "Google Drive")
        XCTAssertEqual(service("Dropbox/AgentBridge"), "Dropbox")
        XCTAssertEqual(service("OneDrive - Example Corp/AgentBridge"), "OneDrive")
        XCTAssertNil(service("AgentBridgeData"))
        XCTAssertNil(service("DropboxBackup/AgentBridge"))
        XCTAssertNil(service("Library/CloudStorage"))
    }

    func testChangeRootRejectsGitRepositoryAndMissingNestedRootBeforeCreatingIt() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }

        let repository = testRoot.appendingPathComponent("repository", isDirectory: true)
        try fileManager.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)

        await assertWorkspaceRootRejected(repository, privateRootURL: privateRoot)

        let nestedRoot = repository
            .appendingPathComponent("new", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        await assertWorkspaceRootRejected(nestedRoot, privateRootURL: privateRoot)
        XCTAssertFalse(fileManager.fileExists(atPath: nestedRoot.path))
        XCTAssertFalse(fileManager.fileExists(atPath: nestedRoot.deletingLastPathComponent().path))
    }

    func testChangeRootRejectsLinkedWorktreeGitFile() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }

        let worktree = testRoot.appendingPathComponent("worktree", isDirectory: true)
        let linkedGitDirectory = testRoot
            .appendingPathComponent("repository.git", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("linked", isDirectory: true)
        try fileManager.createDirectory(at: worktree, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: linkedGitDirectory, withIntermediateDirectories: true)
        try Data("gitdir: \(linkedGitDirectory.path)\n".utf8)
            .write(to: worktree.appendingPathComponent(".git"))

        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        await assertWorkspaceRootRejected(worktree, privateRootURL: privateRoot)
    }

    func testChangeRootChecksCanonicalPathForMissingRootBeneathSymlinkedParent() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }

        let repository = testRoot.appendingPathComponent("repository", isDirectory: true)
        try fileManager.createDirectory(
            at: repository.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        let alias = testRoot.appendingPathComponent("repository-alias", isDirectory: true)
        try fileManager.createSymbolicLink(at: alias, withDestinationURL: repository)

        let requested = alias
            .appendingPathComponent("new", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        await assertWorkspaceRootRejected(requested, privateRootURL: privateRoot)

        let canonicalRequested = repository
            .appendingPathComponent("new", isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
        XCTAssertFalse(fileManager.fileExists(atPath: canonicalRequested.path))
        XCTAssertFalse(fileManager.fileExists(atPath: canonicalRequested.deletingLastPathComponent().path))
    }

    func testChangeRootStillRejectsSelectedRootThatIsASymlink() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }

        let actualRoot = testRoot.appendingPathComponent("actual", isDirectory: true)
        try fileManager.createDirectory(at: actualRoot, withIntermediateDirectories: true)
        let selectedSymlink = testRoot.appendingPathComponent("selected", isDirectory: true)
        try fileManager.createSymbolicLink(at: selectedSymlink, withDestinationURL: actualRoot)

        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        await assertWorkspaceRootRejected(selectedSymlink, privateRootURL: privateRoot)
        XCTAssertTrue(fileManager.fileExists(atPath: actualRoot.path))
    }

    func testChangeRootMigratesDiscussionsAndUpdatesTheirDataRootWithoutRemovingSource() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        let oldRoot = testRoot.appendingPathComponent("old-workspace", isDirectory: true)
        let newRoot = testRoot.appendingPathComponent("new-workspace", isDirectory: true)
        try fileManager.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try WorkspaceRootConfigurationStore.save(
            selectedRootURL: oldRoot,
            priorRootURLs: [],
            privateRootURL: privateRoot
        )

        let oldAuditStore = try AuditStore(
            rootURL: privateRoot,
            workspaceRootURL: oldRoot,
            managedWorkspaceRoots: []
        )
        let oldService = try BridgeService(store: oldAuditStore)
        var discussion = try oldService.createDiscussion(provider: .codex)
        discussion.turns.append(DiscussionTurn(
            provider: .codex,
            accountProfileID: AccountProfile.defaultID(for: .codex),
            sourceSharedMemoryConsent: true,
            isShareable: false,
            userText: "Keep this discussion when the workspace folder changes.",
            assistantText: "The original conversation remains available."
        ))
        discussion.revision += 1
        let oldDiscussionStore = try DiscussionStore(rootURL: oldRoot.appendingPathComponent("discussions", isDirectory: true))
        discussion = try oldDiscussionStore.save(discussion)

        _ = try await WorkspaceRootCoordinator.changeRoot(to: newRoot, privateRootURL: privateRoot)

        let newAuditStore = try AuditStore(
            rootURL: privateRoot,
            workspaceRootURL: newRoot,
            managedWorkspaceRoots: [oldRoot]
        )
        let newService = try BridgeService(store: newAuditStore)
        let migrated = try newService.discussion(id: discussion.id)
        XCTAssertEqual(migrated.dataRootPath, newRoot.path)
        XCTAssertEqual(migrated.turns.map(\.id), discussion.turns.map(\.id))
        XCTAssertEqual(migrated.turns.map(\.userText), discussion.turns.map(\.userText))
        XCTAssertEqual(migrated.turns.compactMap(\.assistantText), discussion.turns.compactMap(\.assistantText))
        XCTAssertEqual(migrated.turns.map(\.isShareable), discussion.turns.map(\.isShareable))
        XCTAssertEqual(try oldDiscussionStore.record(id: discussion.id)?.dataRootPath, oldRoot.path)
        XCTAssertTrue(fileManager.fileExists(atPath: oldRoot.appendingPathComponent("discussions/\(discussion.id.uuidString.lowercased()).json").path))
    }

    func testSelectingTheSameRootAgainFinishesAnInterruptedSessionRepoint() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        let oldRoot = testRoot.appendingPathComponent("old-workspace", isDirectory: true)
        let newRoot = testRoot.appendingPathComponent("new-workspace", isDirectory: true)
        let repository = testRoot.appendingPathComponent("repository", isDirectory: true)
        try fileManager.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try makeGitRepository(at: repository)
        try WorkspaceRootConfigurationStore.save(selectedRootURL: oldRoot, priorRootURLs: [], privateRootURL: privateRoot)

        let oldStore = try AuditStore(rootURL: privateRoot, workspaceRootURL: oldRoot, managedWorkspaceRoots: [])
        let session = try await BridgeService(store: oldStore).createSession(sourcePath: repository.path, provider: .codex)
        XCTAssertTrue(session.workspacePath.hasPrefix(oldRoot.path + "/"))

        _ = try await WorkspaceRootCoordinator.changeRoot(to: newRoot, privateRootURL: privateRoot)
        let newStore = try AuditStore(rootURL: privateRoot, workspaceRootURL: newRoot, managedWorkspaceRoots: [oldRoot])
        let migrated = try XCTUnwrap(newStore.session(id: session.id))
        XCTAssertTrue(migrated.workspacePath.hasPrefix(newRoot.path + "/"))

        // Simulate a stop after the root was saved but before the session
        // record was repointed: the latest record still names the old copy.
        var stale = session
        stale.updatedAt = Date().addingTimeInterval(1)
        try newStore.saveSession(stale)
        XCTAssertEqual(try newStore.session(id: session.id)?.workspacePath, session.workspacePath)

        let selected = try await WorkspaceRootCoordinator.changeRoot(to: newRoot, privateRootURL: privateRoot)
        XCTAssertEqual(selected.path, newRoot.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertEqual(try newStore.session(id: session.id)?.workspacePath, migrated.workspacePath)
        XCTAssertTrue(fileManager.fileExists(atPath: session.workspacePath), "The prior copy is kept.")

        // With nothing left over, selecting the root again changes nothing.
        let sessionsFile = privateRoot.appendingPathComponent("sessions.jsonl")
        let before = try? Data(contentsOf: sessionsFile)
        _ = try await WorkspaceRootCoordinator.changeRoot(to: newRoot, privateRootURL: privateRoot)
        XCTAssertEqual(try? Data(contentsOf: sessionsFile), before)
    }

    func testChangeRootBlocksWhenASourceDiscussionIsInFlight() async throws {
        let fileManager = FileManager.default
        let testRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: testRoot) }
        let privateRoot = testRoot.appendingPathComponent("private", isDirectory: true)
        let oldRoot = testRoot.appendingPathComponent("old-workspace", isDirectory: true)
        let newRoot = testRoot.appendingPathComponent("new-workspace", isDirectory: true)
        try fileManager.createDirectory(at: oldRoot, withIntermediateDirectories: true)
        try WorkspaceRootConfigurationStore.save(
            selectedRootURL: oldRoot,
            priorRootURLs: [],
            privateRootURL: privateRoot
        )
        let oldAuditStore = try AuditStore(
            rootURL: privateRoot,
            workspaceRootURL: oldRoot,
            managedWorkspaceRoots: []
        )
        let oldService = try BridgeService(store: oldAuditStore)
        let discussion = try oldService.createDiscussion(provider: .codex)
        let discussionStore = try DiscussionStore(rootURL: oldRoot.appendingPathComponent("discussions", isDirectory: true))
        var active = try XCTUnwrap(discussionStore.record(id: discussion.id))
        active.status = .running
        _ = try discussionStore.save(active)
        let activeLease = try oldAuditStore.acquireRunLease(for: discussion.id)
        defer { withExtendedLifetime(activeLease) {} }

        do {
            _ = try await WorkspaceRootCoordinator.changeRoot(to: newRoot, privateRootURL: privateRoot)
            XCTFail("Workspace root migration must not move an in-flight discussion.")
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { return XCTFail("Unexpected migration error: \(error)") }
        }
        XCTAssertEqual(
            try WorkspaceRootConfigurationStore.load(privateRootURL: privateRoot)?.selectedRootURL,
            oldRoot
        )
        XCTAssertFalse(fileManager.fileExists(atPath: newRoot.appendingPathComponent("discussions/\(discussion.id.uuidString.lowercased()).json").path))
        XCTAssertEqual(try discussionStore.record(id: discussion.id)?.status, .running)
    }

    private func makeGitRepository(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("fixture\n".utf8).write(to: url.appendingPathComponent("README.md"))
        for arguments in [
            ["-c", "init.defaultBranch=main", "init", "--quiet", "--", url.path],
            ["-C", url.path, "add", "README.md"],
            ["-C", url.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
             "-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "initial"]
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.environment = [
                "HOME": NSTemporaryDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"
            ]
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-WorkspaceRoot-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func assertWorkspaceRootRejected(
        _ selectedRoot: URL,
        privateRootURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await WorkspaceRootCoordinator.changeRoot(
                to: selectedRoot,
                privateRootURL: privateRootURL
            )
            XCTFail("Expected the selected workspace data root to be rejected.", file: file, line: line)
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else {
                XCTFail("Expected invalidInput, got \(error).", file: file, line: line)
                return
            }
        } catch {
            XCTFail("Expected AgentBridgeError.invalidInput, got \(error).", file: file, line: line)
        }
    }
}
