import AgentBridgeCore
import Darwin
import XCTest

final class SessionRemovalTests: XCTestCase {
    func testRemovingACleanSessionDeletesItsWorkspaceAndHidesItButKeepsItsRecord() async throws {
        let fixture = try await makeFixture()
        let preview = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        XCTAssertTrue(preview.workspaceExists)
        XCTAssertFalse(preview.mayLoseWork, "\(preview)")

        try await fixture.service.removeSession(sessionID: fixture.session.id, reviewed: preview)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.session.workspacePath))
        XCTAssertFalse(try fixture.service.sessions().contains { $0.id == fixture.session.id })
        XCTAssertNil(try fixture.store.session(id: fixture.session.id))
        let kept = try fixture.store.loadSessions(includingRemoved: true).first { $0.id == fixture.session.id }
        XCTAssertNotNil(kept?.removedAt)
        XCTAssertTrue(try fixture.service.events(sessionID: fixture.session.id).contains { $0.kind == "session.removed" })
        // A removed session cannot be used any more.
        await XCTAssertThrowsErrorAsync(try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)) {
            XCTAssertEqual($0 as? AgentBridgeError, .sessionNotFound(fixture.session.id))
        }
    }

    func testUncommittedAndUntrackedFilesAreListed() async throws {
        let fixture = try await makeFixture()
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        try Data("edited\n".utf8).write(to: workspace.appendingPathComponent("source.txt"))
        try Data("new\n".utf8).write(to: workspace.appendingPathComponent("notes.txt"))

        let preview = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        XCTAssertEqual(preview.changedPaths.sorted(), ["notes.txt", "source.txt"])
        XCTAssertEqual(preview.changedPathCount, 2)
        XCTAssertTrue(preview.unsavedReferences.isEmpty)
        XCTAssertNil(preview.inspectionProblem)
        XCTAssertTrue(preview.mayLoseWork)
    }

    func testCommitsTheSourceLacksAreUnsavedUntilTheSourceHasThem() async throws {
        let fixture = try await makeFixture()
        let workspace = fixture.session.workspacePath
        try FixtureGit.run(["-C", workspace, "switch", "-q", "-c", "feature"])
        try Data("feature\n".utf8).write(to: URL(fileURLWithPath: workspace).appendingPathComponent("feature.txt"))
        try FixtureGit.run(["-C", workspace, "add", "feature.txt"])
        try FixtureGit.run(["-C", workspace, "commit", "-q", "-m", "feature"])

        let unsaved = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        XCTAssertEqual(unsaved.unsavedReferences, ["feature"])
        // Compared with the pinned commit, the committed file is still a difference.
        XCTAssertEqual(unsaved.changedPaths, ["feature.txt"])

        // Once the source has the commit, as after a push and pull, nothing is lost.
        try FixtureGit.run(["-C", fixture.sourceURL.path, "fetch", "-q", workspace, "feature:feature"])
        let saved = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        XCTAssertFalse(saved.mayLoseWork, "\(saved)")
    }

    func testAChangeAfterTheReviewStopsTheRemoval() async throws {
        let fixture = try await makeFixture()
        let preview = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        try Data("late\n".utf8).write(to: workspace.appendingPathComponent("late.txt"))

        await XCTAssertThrowsErrorAsync(try await fixture.service.removeSession(sessionID: fixture.session.id, reviewed: preview))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("late.txt").path))
        XCTAssertNotNil(try fixture.store.session(id: fixture.session.id))
    }

    func testARunningSessionCannotBeRemoved() async throws {
        let fixture = try await makeFixture()
        let preview = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        let lease = try fixture.store.acquireRunLease(for: fixture.session.id)

        await XCTAssertThrowsErrorAsync(try await fixture.service.removeSession(sessionID: fixture.session.id, reviewed: preview)) {
            XCTAssertEqual(($0 as? AgentBridgeError)?.isSessionBusy, true)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.session.workspacePath))
        withExtendedLifetime(lease) {}
    }

    func testTheWorkspacesGitSettingsCannotMakeTheCheckRunAProgram() async throws {
        let fixture = try await makeFixture()
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        let marker = fixture.rootURL.appendingPathComponent("ran")
        let program = fixture.rootURL.appendingPathComponent("program.sh")
        try Data("#!/bin/sh\ntouch '\(marker.path)'\ncat\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        try FixtureGit.run(["-C", workspace.path, "config", "core.fsmonitor", program.path])
        try FixtureGit.run(["-C", workspace.path, "config", "filter.evil.clean", program.path])
        try Data("* filter=evil\n".utf8).write(to: workspace.appendingPathComponent(".gitattributes"))
        try Data("edited\n".utf8).write(to: workspace.appendingPathComponent("source.txt"))

        let preview = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Git ran a program from the workspace's settings.")
        XCTAssertEqual(preview.changedPaths.sorted(), [".gitattributes", "source.txt"])
    }

    func testIgnoredFilesAreListedEvenWhenTheWorkspaceIgnoresThemItself() async throws {
        let fixture = try await makeFixture()
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        // A local secret, and a rule the workspace added to hide another file.
        try Data(".env\n".utf8).write(to: workspace.appendingPathComponent(".git/info/exclude"))
        try Data("KEY=1\n".utf8).write(to: workspace.appendingPathComponent(".env"))
        try Data("hidden.txt\n".utf8).write(to: workspace.appendingPathComponent(".gitignore"))
        try Data("hidden\n".utf8).write(to: workspace.appendingPathComponent("hidden.txt"))

        let preview = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        // `.git/info/exclude` is the workspace's own and is not read, so `.env`
        // counts as untracked; the work tree's `.gitignore` only moves a file to
        // the ignored list. Neither is left out.
        XCTAssertEqual(preview.changedPaths.sorted(), [".env", ".gitignore"])
        XCTAssertEqual(preview.ignoredPaths, ["hidden.txt"])
        XCTAssertEqual(preview.ignoredPathCount, 1)
        XCTAssertTrue(preview.mayLoseWork)
    }

    func testTagsOlderStashesAndADetachedHeadTheSourceLacksAreUnsaved() async throws {
        let fixture = try await makeFixture()
        let workspace = fixture.session.workspacePath
        let file = URL(fileURLWithPath: workspace).appendingPathComponent("source.txt")
        // A tagged commit no branch holds.
        try FixtureGit.run(["-C", workspace, "commit", "-q", "--allow-empty", "-m", "tagged"])
        try FixtureGit.run(["-C", workspace, "tag", "v1"])
        try FixtureGit.run(["-C", workspace, "reset", "-q", "--hard", "HEAD~1"])
        // Two stashes: `refs/stash` and the older `stash@{1}`.
        try Data("first\n".utf8).write(to: file)
        try FixtureGit.run(["-C", workspace, "stash", "-q"])
        try Data("second\n".utf8).write(to: file)
        try FixtureGit.run(["-C", workspace, "stash", "-q"])
        // A commit on a detached HEAD.
        try FixtureGit.run(["-C", workspace, "switch", "-q", "--detach"])
        try FixtureGit.run(["-C", workspace, "commit", "-q", "--allow-empty", "-m", "detached"])

        let preview = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        XCTAssertEqual(preview.unsavedReferences, ["HEAD", "stash", "stash@{1}", "tags/v1"])
    }

    func testControlCharactersInNamesAreNotShown() async throws {
        let fixture = try await makeFixture()
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        try Data("x\n".utf8).write(to: workspace.appendingPathComponent("evil\u{1B}[2Jname.txt"))

        let preview = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        XCTAssertEqual(preview.changedPaths, ["evil?[2Jname.txt"])
    }

    func testAClaudeSessionWithAnUnreconciledAPICallCannotBeRemoved() async throws {
        let fixture = try await makeFixture()
        let profile = try fixture.service.createAccountProfile(name: "Claude billing", provider: .claude)
        let session = try await fixture.service.createSession(
            sourcePath: fixture.sourceURL.path,
            provider: .claude,
            accessMode: .interactiveManualApproval,
            accountProfileID: profile.id
        )
        let ledger = try APISpendLedger(
            rootURL: fixture.store.rootURL.appendingPathComponent("api-spend", isDirectory: true)
                .appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
        )
        _ = try ledger.reserve(
            sessionID: session.id,
            requestedUSD: 1,
            explicitlyAuthorized: true,
            limits: APISpendLimits(monthlyUSD: 25, dailyUSD: 10, sessionUSD: 10)
        )
        let preview = try await fixture.service.sessionRemovalPreview(sessionID: session.id)

        await XCTAssertThrowsErrorAsync(try await fixture.service.removeSession(sessionID: session.id, reviewed: preview)) {
            XCTAssertEqual($0 as? AgentBridgeError, .sessionMismatch("This session has a paid API call that is not reconciled yet. Reconcile it before removing the session."))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.workspacePath))
    }

    func testAReviewOfAnotherSessionIsRejected() async throws {
        let fixture = try await makeFixture()
        let preview = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        await XCTAssertThrowsErrorAsync(try await fixture.service.removeSession(sessionID: UUID(), reviewed: preview))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.session.workspacePath))
    }

    func testAMissingWorkspaceCanStillBeRemoved() async throws {
        let fixture = try await makeFixture()
        try FileManager.default.removeItem(atPath: fixture.session.workspacePath)
        let preview = try await fixture.service.sessionRemovalPreview(sessionID: fixture.session.id)
        XCTAssertFalse(preview.workspaceExists)
        XCTAssertFalse(preview.mayLoseWork)
        try await fixture.service.removeSession(sessionID: fixture.session.id, reviewed: preview)
        XCTAssertNil(try fixture.store.session(id: fixture.session.id))
    }

    // MARK: - Fixture

    private struct Fixture {
        let rootURL: URL
        let sourceURL: URL
        let store: AuditStore
        let service: BridgeService
        let session: SessionRecord
    }

    private func makeFixture() async throws -> Fixture {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureParent = packageRoot.appendingPathComponent("build/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureParent, withIntermediateDirectories: true)
        guard let resolvedPath = fixtureParent.path.withCString({ realpath($0, nil) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(resolvedPath) }
        let root = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
            .appendingPathComponent("AgentBridge-SessionRemoval-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let workspaces = root.appendingPathComponent("workspace-data", isDirectory: true)
        for directory in [source, state, workspaces] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("original\n".utf8).write(to: source.appendingPathComponent("source.txt"))
        try FixtureGit.run(["init", "-q", source.path])
        try FixtureGit.run(["-C", source.path, "add", "source.txt"])
        try FixtureGit.run(["-C", source.path, "commit", "-q", "-m", "initial"])

        let store = try AuditStore(rootURL: state, workspaceRootURL: workspaces, managedWorkspaceRoots: [])
        let service = try BridgeService(store: store)
        let session = try await service.createSession(
            sourcePath: source.path,
            provider: .codex,
            accessMode: .interactiveManualApproval
        )
        return Fixture(rootURL: root, sourceURL: source, store: store, service: service, session: session)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error.", file: file, line: line)
    } catch {
        handler(error)
    }
}
