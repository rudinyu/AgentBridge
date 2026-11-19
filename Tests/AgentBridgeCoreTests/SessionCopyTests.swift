import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

/// "New session like this": a new session from an existing one's settings.
final class SessionCopyTests: XCTestCase {
    private let codexChoice = ProviderModelChoice(model: "gpt-test-1", reasoningEffort: "high")

    // MARK: Commit

    func testSameCommitPinsTheSourceCommitAndHeadPinsTheCurrentHead() async throws {
        let fixture = try makeFixture()
        let source = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .codex, modelChoice: codexChoice)
        try Data("moved on\n".utf8).write(to: fixture.source.appendingPathComponent("source.txt"))
        try FixtureGit.run(["-C", fixture.source.path, "commit", "-q", "-am", "second"])
        let head = try FixtureGit.run(["-C", fixture.source.path, "rev-parse", "HEAD"])
        XCTAssertNotEqual(head, source.snapshotCommit)

        let same = try await fixture.service.createSession(like: source.id)
        XCTAssertEqual(same.session.snapshotCommit, source.snapshotCommit)
        XCTAssertNotEqual(same.session.id, source.id)
        XCTAssertNotEqual(same.session.workspacePath, source.workspacePath)
        XCTAssertEqual(same.session.sourceRepositoryPath, source.sourceRepositoryPath)
        XCTAssertEqual(same.session.provider, .codex)
        XCTAssertEqual(same.session.policy.accessMode, .readOnly)

        let latest = try await fixture.service.createSession(like: source.id, commit: .sourceHead)
        XCTAssertEqual(latest.session.snapshotCommit, head)
    }

    // MARK: Model

    func testModelIsInheritedUnlessOverriddenAndIsValidatedLikeAnyNewSession() async throws {
        let fixture = try makeFixture()
        let source = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .codex, modelChoice: codexChoice)
        // Saved new-session defaults do not replace the source's choice.
        var settings = try fixture.service.settings()
        settings.setModelDefaults(ProviderModelChoice(model: "gpt-default", reasoningEffort: "low"), for: .codex)
        try fixture.service.saveSettings(settings)

        let inherited = try await fixture.service.createSession(like: source.id)
        XCTAssertEqual(inherited.session.modelChoice, codexChoice)

        let overridden = try await fixture.service.createSession(like: source.id, modelChoice: ProviderModelChoice(model: "gpt-test-2", reasoningEffort: "ultra"))
        XCTAssertEqual(overridden.session.modelChoice, ProviderModelChoice(model: "gpt-test-2", reasoningEffort: "ultra"))

        // A source on the CLI default stays on it, rather than taking the saved defaults.
        let plain = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .codex, modelChoice: .cliDefault)
        let plainCopy = try await fixture.service.createSession(like: plain.id)
        XCTAssertEqual(plainCopy.session.modelChoice, .cliDefault)

        for invalid in [ProviderModelChoice(model: "bad name"), ProviderModelChoice(reasoningEffort: "minimal")] {
            do {
                _ = try await fixture.service.createSession(like: source.id, modelChoice: invalid)
                XCTFail("An invalid model choice created a session.")
            } catch let error as AgentBridgeError {
                guard case .invalidInput = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testLocalReadOnlySourceIsCopiedWithoutAModel() async throws {
        let fixture = try makeFixture()
        let source = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .local)
        let copy = try await fixture.service.createSession(like: source.id)
        XCTAssertEqual(copy.session.provider, .local)
        XCTAssertEqual(copy.session.policy.accessMode, .readOnly)
        XCTAssertEqual(copy.session.modelChoice, .cliDefault)
        XCTAssertNil(copy.copiedChangePlan)
        do {
            _ = try await fixture.service.createSession(like: source.id, modelChoice: ProviderModelChoice(model: "llama3"))
            XCTFail("A local session was given a model.")
        } catch {}
    }

    // MARK: Account

    func testAccountDefaultsToTheSourceAndMustBeForTheSameProvider() async throws {
        let fixture = try makeFixture()
        let second = try fixture.service.createAccountProfile(name: "Second Codex", provider: .codex)
        let source = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .codex, accountProfileID: second.id)
        // Selecting another account later does not change the copy's default.
        try fixture.service.selectAccountProfile(id: AccountProfile.defaultID(for: .codex), provider: .codex)

        let defaulted = try await fixture.service.createSession(like: source.id)
        XCTAssertEqual(defaulted.session.accountProfileID, second.id)
        let chosen = try await fixture.service.createSession(like: source.id, accountProfileID: AccountProfile.defaultID(for: .codex))
        XCTAssertEqual(chosen.session.accountProfileID, AccountProfile.defaultID(for: .codex))

        let claude = try fixture.service.selectedAccountProfile(provider: .claude)
        do {
            _ = try await fixture.service.createSession(like: source.id, accountProfileID: claude.id)
            XCTFail("An account of another provider was accepted.")
        } catch let error as AccountProfileError {
            XCTAssertEqual(error, .providerMismatch(claude.id, .codex))
        }
    }

    // MARK: Change plan

    func testChangePlanIsCopiedUnapprovedAndNothingElseCarriesOver() async throws {
        let fixture = try makeFixture()
        let source = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .codex, accessMode: .isolatedChanges, modelChoice: codexChoice)
        let plan = try fixture.service.createChangePlan(
            sessionID: source.id, title: "Edit", summary: "Edit source.txt.", steps: ["Edit it.", "Check it."], includesSharedMemory: true
        )
        // Approval with memory needs saved memory, so the approved state is set
        // on the record directly, as a finished session would have it.
        var finished = try XCTUnwrap(fixture.store.session(id: source.id))
        finished.approvedChangePlanDigest = plan.reviewDigest
        finished.approvedChangePlanMemoryDigest = String(repeating: "m", count: 64)
        finished.providerSessionID = UUID().uuidString.lowercased()
        finished.verificationPassed = true
        finished.verificationDiffDigest = String(repeating: "d", count: 64)
        finished.verificationCompletedAt = Date()
        finished.changesAcceptedAt = Date()
        finished.lastChangeRunAt = Date()
        finished.status = .failed
        try fixture.store.saveSession(finished)

        let copy = try await fixture.service.createSession(like: source.id)
        let copied = try XCTUnwrap(copy.copiedChangePlan)
        XCTAssertNil(copy.changePlanCopyError)
        XCTAssertEqual(copy.session.changePlan?.id, copied.id)
        XCTAssertEqual(copied.title, plan.title)
        XCTAssertEqual(copied.summary, plan.summary)
        XCTAssertEqual(copied.steps, plan.steps)
        XCTAssertTrue(copied.includesSharedMemory)
        XCTAssertEqual(copied.sessionID, copy.session.id)
        XCTAssertNotEqual(copied.id, plan.id)

        let session = copy.session
        XCTAssertEqual(session.policy.accessMode, .isolatedChanges)
        XCTAssertNil(session.approvedChangePlanDigest)
        XCTAssertNil(session.approvedChangePlanMemoryDigest)
        XCTAssertNil(session.verificationPassed)
        XCTAssertNil(session.verificationDiffDigest)
        XCTAssertNil(session.verificationCompletedAt)
        XCTAssertNil(session.changesAcceptedAt)
        XCTAssertNil(session.lastChangeRunAt)
        XCTAssertNil(session.providerSessionID)
        XCTAssertEqual(session.status, .created)
        XCTAssertEqual(session.modelChoice, codexChoice)
        // A run needs the copy's own approval.
        do {
            _ = try await fixture.service.runChanges(sessionID: session.id, prompt: "Edit it.", planID: copied.id, reviewedDigest: copied.reviewDigest)
            XCTFail("An unapproved copied plan ran.")
        } catch {}

        let events = try fixture.service.events(sessionID: session.id)
        XCTAssertTrue(events.contains { $0.kind == "change.plan.created" })
        let created = try XCTUnwrap(events.first { $0.kind == "session.created_like" })
        XCTAssertEqual(created.message, "Created from session \(source.id.uuidString.lowercased()); its change plan was copied and must be approved again.")
        XCTAssertFalse(events.contains { $0.kind.hasPrefix("change.plan.approved") })
    }

    func testSourceWithoutAPlanCopiesNoPlan() async throws {
        let fixture = try makeFixture()
        let source = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .codex, accessMode: .isolatedChanges)
        let copy = try await fixture.service.createSession(like: source.id)
        XCTAssertNil(copy.copiedChangePlan)
        XCTAssertNil(copy.changePlanCopyError)
        XCTAssertNil(copy.session.changePlan)
        let event = try XCTUnwrap(try fixture.service.events(sessionID: copy.session.id).first { $0.kind == "session.created_like" })
        XCTAssertEqual(event.message, "Created from session \(source.id.uuidString.lowercased()); there was no change plan to copy.")
    }

    func testAPlanThatCannotBeSavedLeavesTheNewSessionAndSaysSo() async throws {
        let fixture = try makeFixture()
        let source = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .codex, accessMode: .isolatedChanges)
        _ = try fixture.service.createChangePlan(sessionID: source.id, title: "Edit", summary: "Edit it.", steps: ["Edit."], includesSharedMemory: true)
        let noMemory = try fixture.service.createAccountProfile(name: "No Memory", provider: .codex, allowsSharedMemory: false)

        let copy = try await fixture.service.createSession(like: source.id, accountProfileID: noMemory.id)
        XCTAssertNil(copy.copiedChangePlan)
        let error = try XCTUnwrap(copy.changePlanCopyError)
        XCTAssertTrue(error.hasPrefix("The new session was created, but the change plan was not copied: "), error)
        XCTAssertNotNil(try fixture.store.session(id: copy.session.id))
        XCTAssertNil(try fixture.store.session(id: copy.session.id)?.changePlan)
        let event = try XCTUnwrap(try fixture.service.events(sessionID: copy.session.id).first { $0.kind == "session.created_like" })
        XCTAssertEqual(event.message, "Created from session \(source.id.uuidString.lowercased()); its change plan could not be copied.")
    }

    // MARK: Source state and mode limits

    func testRemovedSourceStillWorksAndAccessModeIsKept() async throws {
        let fixture = try makeFixture()
        let source = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .claude, accessMode: .interactiveManualApproval)
        var removed = try XCTUnwrap(fixture.store.session(id: source.id))
        removed.removedAt = Date()
        removed.status = .cancelled
        try fixture.store.saveSession(removed)
        XCTAssertNil(try fixture.store.session(id: source.id))

        let copy = try await fixture.service.createSession(like: source.id)
        XCTAssertEqual(copy.session.provider, .claude)
        XCTAssertEqual(copy.session.policy.accessMode, .interactiveManualApproval)

        do {
            _ = try await fixture.service.createSession(like: UUID())
            XCTFail("A missing source created a session.")
        } catch let error as AgentBridgeError {
            guard case .sessionNotFound = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testAPIModeStillLimitsWhatCanBeCreated() async throws {
        let fixture = try makeFixture()
        let codex = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .codex)
        let claudeChanges = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .claude, accessMode: .isolatedChanges)
        let claudeReadOnly = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .claude)
        var settings = try fixture.service.settings()
        settings.usageMode = .api
        try fixture.service.saveSettings(settings)

        for sourceID in [codex.id, claudeChanges.id] {
            do {
                _ = try await fixture.service.createSession(like: sourceID)
                XCTFail("API mode created a session it does not support.")
            } catch let error as AgentBridgeError {
                guard case .sessionMismatch = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        let allowed = try await fixture.service.createSession(like: claudeReadOnly.id)
        XCTAssertEqual(allowed.session.provider, .claude)
    }

    // MARK: CLI arguments

    func testLikeArgumentsParseAndKeepTheSourceValuesThatAreNotGiven() throws {
        let id = UUID()
        let profile = UUID()
        let parsed = try SessionLikeArguments.parse([
            "--like", id.uuidString, "--model", "gpt-test-2", "--latest-commit", "--profile", profile.uuidString
        ])
        XCTAssertEqual(parsed, SessionLikeArguments(sourceSessionID: id, model: "gpt-test-2", latestCommit: true, profileID: profile))
        XCTAssertEqual(parsed.commit, .sourceHead)

        let source = SessionRecord(
            provider: .codex, sourceRepositoryPath: "/tmp/repo", workspacePath: "/tmp/ws",
            snapshotCommit: String(repeating: "a", count: 40), sourceWasDirty: false,
            model: "gpt-test-1", reasoningEffort: "high"
        )
        XCTAssertEqual(parsed.modelChoice(source: source), ProviderModelChoice(model: "gpt-test-2", reasoningEffort: "high"))
        let plain = try SessionLikeArguments.parse(["--like", id.uuidString])
        XCTAssertNil(plain.modelChoice(source: source))
        XCTAssertEqual(plain.commit, .sameAsSource)
        // An empty value means the CLI default, as with `session create`.
        let cleared = try SessionLikeArguments.parse(["--like", id.uuidString, "--effort", ""])
        XCTAssertEqual(cleared.modelChoice(source: source), ProviderModelChoice(model: "gpt-test-1", reasoningEffort: ""))
        XCTAssertEqual(try cleared.modelChoice(source: source)?.validated(for: .codex), ProviderModelChoice(model: "gpt-test-1"))

        for invalid in [
            [], ["--model", "x"], ["--like"], ["--like", "not-a-uuid"],
            ["--like", id.uuidString, "--provider", "codex"], ["--like", id.uuidString, "--repo", "/tmp"],
            ["--like", id.uuidString, "--changes"], ["--like", id.uuidString, "--interactive"],
            ["--like", id.uuidString, "--like", id.uuidString], ["--like", id.uuidString, "--profile", "x"],
            ["--like", id.uuidString, "--unknown"]
        ] {
            XCTAssertThrowsError(try SessionLikeArguments.parse(invalid), "\(invalid)")
        }
        XCTAssertThrowsError(try SessionLikeArguments.parse(["--like", id.uuidString, "--changes"])) { error in
            XCTAssertEqual(error.localizedDescription, "The --changes option cannot be used with --like; the new session takes it from the source session.")
        }
    }

    // MARK: Helpers

    private struct Fixture {
        let source: URL
        let store: AuditStore
        let service: BridgeService
    }

    private func makeFixture() throws -> Fixture {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = packageRoot.appendingPathComponent("build/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let resolved = parent.path.withCString({ realpath($0, nil) }) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("AgentBridge-SessionCopy-\(UUID().uuidString.lowercased())", isDirectory: true)
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
        var settings = try service.settings()
        settings.usageMode = .subscription
        try service.saveSettings(settings)
        return Fixture(source: source, store: store, service: service)
    }
}
