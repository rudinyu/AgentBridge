import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class ChangeWorkflowTests: XCTestCase {
    func testChangeCommandArgumentsUseTheDocumentedScopedWriteModes() throws {
        let workspace = "/tmp/AgentBridge changes;$(touch /tmp/should-not-exist)"

        let codex = try ProviderCommandBuilder.codexChangeArguments(workspacePath: workspace)
        XCTAssertEqual(codex[codex.firstIndex(of: "--cd")! + 1], workspace)
        XCTAssertEqual(codex[codex.firstIndex(of: "--sandbox")! + 1], "workspace-write")
        XCTAssertFalse(codex.contains("--ask-for-approval"))
        XCTAssertFalse(codex.contains("on-request"))
        XCTAssertTrue(codex.contains("--disable"))
        XCTAssertTrue(codex.contains("hooks"))
        XCTAssertTrue(codex.contains("plugins"))
        XCTAssertTrue(codex.contains("apps"))
        XCTAssertFalse(codex.contains("--dangerously-bypass-approvals-and-sandbox"))

        let claude = try ProviderCommandBuilder.claudeChangeArguments(workspacePath: workspace, sessionID: UUID())
        XCTAssertEqual(claude[claude.firstIndex(of: "--add-dir")! + 1], workspace)
        XCTAssertEqual(claude[claude.firstIndex(of: "--permission-mode")! + 1], "acceptEdits")
        XCTAssertEqual(claude[claude.firstIndex(of: "--tools")! + 1], "Read,Glob,Grep,Edit,Write")
        XCTAssertFalse(claude.contains("Bash"))
        XCTAssertFalse(claude.contains("--dangerously-skip-permissions"))
        XCTAssertTrue(claude.contains("--strict-mcp-config"))
    }

    func testPlanMustBeReviewedBeforeAnyChangeRunAndSourceRemainsUntouched() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let sourceHeadBefore = try gitText(["-C", fixture.sourceURL.path, "rev-parse", "HEAD"])
        let sourceTextBefore = try String(contentsOf: fixture.sourceURL.appendingPathComponent("source.txt"), encoding: .utf8)
        XCTAssertEqual(SessionPolicy().accessMode, .readOnly)

        let plan = try fixture.service.createChangePlan(
            sessionID: fixture.session.id,
            title: "Update the greeting",
            summary: "Change only the greeting in source.txt.",
            steps: ["Replace the existing greeting.", "Leave other files unchanged."]
        )
        do {
            _ = try await fixture.service.runChanges(
                sessionID: fixture.session.id,
                prompt: "Change the greeting.",
                planID: plan.id,
                reviewedDigest: plan.reviewDigest
            )
            XCTFail("An unreviewed plan started a change run.")
        } catch let error as AgentBridgeError {
            guard case .changePlanRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let saved = try XCTUnwrap(fixture.store.session(id: fixture.session.id))
        XCTAssertNil(saved.approvedChangePlanDigest)
        XCTAssertEqual(try gitText(["-C", fixture.sourceURL.path, "rev-parse", "HEAD"]), sourceHeadBefore)
        XCTAssertEqual(try String(contentsOf: fixture.sourceURL.appendingPathComponent("source.txt"), encoding: .utf8), sourceTextBefore)
        XCTAssertEqual(try gitText(["-C", fixture.sourceURL.path, "status", "--porcelain"]), "")
    }

    func testFileDiffAndPatchExportStayInsideTheIsolatedWorkspace() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let sourcePath = fixture.sourceURL.appendingPathComponent("source.txt")
        let sourceTextBefore = try String(contentsOf: sourcePath, encoding: .utf8)
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        try Data("changed in session\n".utf8).write(to: workspace.appendingPathComponent("source.txt"))
        try Data("new isolated file\n".utf8).write(to: workspace.appendingPathComponent("new.txt"))

        let diff = try await fixture.service.changesDiff(sessionID: fixture.session.id)
        XCTAssertEqual(Set(diff.files.map(\.path)), ["new.txt", "source.txt"])
        XCTAssertEqual(diff.files.first(where: { $0.path == "source.txt" })?.status, .modified)
        XCTAssertEqual(diff.files.first(where: { $0.path == "new.txt" })?.status, .untracked)
        let exportedPatch = try await fixture.service.exportChangePatch(sessionID: fixture.session.id)
        XCTAssertTrue(String(decoding: exportedPatch, as: UTF8.self).contains("changed in session"))

        try await fixture.service.restoreChangeFiles(sessionID: fixture.session.id, filePaths: ["new.txt"])
        let restoredDiff = try await fixture.service.changesDiff(sessionID: fixture.session.id)
        XCTAssertEqual(restoredDiff.files.map(\.path), ["source.txt"])
        XCTAssertEqual(try String(contentsOf: sourcePath, encoding: .utf8), sourceTextBefore)
        XCTAssertEqual(try gitText(["-C", fixture.sourceURL.path, "status", "--porcelain"]), "")
    }

    func testApplyUsesCapturedVerifiedDiffAfterWorkspaceChanges() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let manager = WorkspaceManager(store: fixture.store)
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        let isolatedFile = workspace.appendingPathComponent("source.txt")
        try Data("captured A\n".utf8).write(to: isolatedFile)
        let capturedDiff = try await manager.diff(for: fixture.session)

        var verifiedSession = fixture.session
        let changeAt = Date()
        verifiedSession.lastChangeRunAt = changeAt
        verifiedSession.verificationPassed = true
        verifiedSession.verificationDiffDigest = capturedDiff.digest
        verifiedSession.verificationCompletedAt = changeAt.addingTimeInterval(1)
        try fixture.store.saveSession(verifiedSession)

        try Data("later B\n".utf8).write(to: isolatedFile)
        let result = try await manager.applyVerifiedChangesToLocalBranch(
            for: verifiedSession,
            branchName: "agentbridge/captured-diff-test",
            diff: capturedDiff
        )

        let appliedText = try String(contentsOf: URL(fileURLWithPath: result.worktreePath).appendingPathComponent("source.txt"), encoding: .utf8)
        XCTAssertEqual(appliedText, "captured A\n")
        XCTAssertNotEqual(appliedText, "later B\n")
        XCTAssertEqual(try String(contentsOf: fixture.sourceURL.appendingPathComponent("source.txt"), encoding: .utf8), "original\n")
    }

    func testApplyRejectsDiffNotBoundToVerifiedSessionAndBaseCommit() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let manager = WorkspaceManager(store: fixture.store)
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        try Data("captured change\n".utf8).write(to: workspace.appendingPathComponent("source.txt"))
        let capturedDiff = try await manager.diff(for: fixture.session)

        var verifiedSession = fixture.session
        let changeAt = Date()
        verifiedSession.lastChangeRunAt = changeAt
        verifiedSession.verificationPassed = true
        verifiedSession.verificationDiffDigest = String(repeating: "f", count: 64)
        verifiedSession.verificationCompletedAt = changeAt.addingTimeInterval(1)
        do {
            _ = try await manager.applyVerifiedChangesToLocalBranch(
                for: verifiedSession,
                branchName: "agentbridge/unbound-diff-test",
                diff: capturedDiff
            )
            XCTFail("A diff with an unverified digest was applied.")
        } catch let error as AgentBridgeError {
            guard case .verificationRequired = error else { return XCTFail("Unexpected error: \(error)") }
        }

        verifiedSession.verificationDiffDigest = capturedDiff.digest
        let wrongBaseDiff = WorkspaceChangeDiff(
            baseCommit: String(repeating: "0", count: 40),
            files: capturedDiff.files,
            patch: capturedDiff.patch
        )
        do {
            _ = try await manager.applyVerifiedChangesToLocalBranch(
                for: verifiedSession,
                branchName: "agentbridge/unbound-diff-test",
                diff: wrongBaseDiff
            )
            XCTFail("A diff from a different base commit was applied.")
        } catch let error as AgentBridgeError {
            guard case .verificationRequired = error else { return XCTFail("Unexpected error: \(error)") }
        }

        XCTAssertEqual(
            try git(["-C", fixture.sourceURL.path, "show-ref", "--verify", "--quiet", "refs/heads/agentbridge/unbound-diff-test"], allowedExitCodes: [0, 1]),
            1
        )
    }

    func testChangePlanDraftMatchesSavedPlanAfterSaveNormalization() throws {
        let plan = ChangePlan(
            sessionID: UUID(),
            title: "Update greeting",
            summary: "Change the message.",
            steps: ["Edit the greeting.", "Keep other files unchanged."]
        )
        let equivalentDraft = ChangePlanDraft(
            title: "  Update greeting  ",
            summary: "\nChange the message.\t",
            stepsText: " Edit the greeting. \n\n Keep other files unchanged.  \n"
        )
        XCTAssertTrue(equivalentDraft.matches(plan))

        let changedDraft = ChangePlanDraft(
            title: "Update greeting",
            summary: "Change the message.",
            stepsText: "Edit the greeting.\nDelete unrelated files."
        )
        XCTAssertFalse(changedDraft.matches(plan))
    }

    func testApplyToNamedBranchRejectsChangedSourceBaseWithoutCreatingBranch() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        try Data("isolated change\n".utf8).write(to: workspace.appendingPathComponent("source.txt"))
        let diffDigest = try await fixture.service.changesDiff(sessionID: fixture.session.id).digest

        try Data("source advanced\n".utf8).write(to: fixture.sourceURL.appendingPathComponent("source.txt"))
        try git(["-C", fixture.sourceURL.path, "add", "source.txt"])
        try git(["-C", fixture.sourceURL.path, "commit", "-m", "advance source"])
        let advancedHead = try gitText(["-C", fixture.sourceURL.path, "rev-parse", "HEAD"])
        let advancedText = try String(contentsOf: fixture.sourceURL.appendingPathComponent("source.txt"), encoding: .utf8)

        var session = try XCTUnwrap(fixture.store.session(id: fixture.session.id))
        let changeAt = Date()
        session.lastChangeRunAt = changeAt
        session.verificationPassed = true
        session.verificationDiffDigest = diffDigest
        session.verificationCompletedAt = changeAt.addingTimeInterval(1)
        session.updatedAt = changeAt.addingTimeInterval(2)
        try fixture.store.saveSession(session)

        do {
            _ = try await fixture.service.applyChangesToLocalBranch(sessionID: fixture.session.id, branchName: "agentbridge/review-test")
            XCTFail("Changes were applied after the source base commit changed.")
        } catch let error as AgentBridgeError {
            guard case .sourceBaseConflict = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try gitText(["-C", fixture.sourceURL.path, "rev-parse", "HEAD"]), advancedHead)
        XCTAssertEqual(try String(contentsOf: fixture.sourceURL.appendingPathComponent("source.txt"), encoding: .utf8), advancedText)
        XCTAssertEqual(try git(["-C", fixture.sourceURL.path, "show-ref", "--verify", "--quiet", "refs/heads/agentbridge/review-test"], allowedExitCodes: [0, 1]), 1)
        XCTAssertEqual(try gitText(["-C", fixture.sourceURL.path, "status", "--porcelain"]), "")
    }

    func testApplyToNamedBranchCreatesOnlyAnUncommittedIsolatedWorktree() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let sourcePath = fixture.sourceURL.appendingPathComponent("source.txt")
        let sourceHead = try gitText(["-C", fixture.sourceURL.path, "rev-parse", "HEAD"])
        let sourceText = try String(contentsOf: sourcePath, encoding: .utf8)
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        try Data("accepted isolated edit\n".utf8).write(to: workspace.appendingPathComponent("source.txt"))
        try Data("new file\n".utf8).write(to: workspace.appendingPathComponent("new.txt"))
        let diffDigest = try await fixture.service.changesDiff(sessionID: fixture.session.id).digest

        var session = try XCTUnwrap(fixture.store.session(id: fixture.session.id))
        let changeAt = Date()
        session.lastChangeRunAt = changeAt
        session.verificationPassed = true
        session.verificationDiffDigest = diffDigest
        session.verificationCompletedAt = changeAt.addingTimeInterval(1)
        session.updatedAt = changeAt.addingTimeInterval(2)
        try fixture.store.saveSession(session)

        let result = try await fixture.service.applyChangesToLocalBranch(
            sessionID: fixture.session.id,
            branchName: "agentbridge/review-test"
        )
        XCTAssertEqual(result.branchName, "agentbridge/review-test")
        XCTAssertEqual(result.changedFileCount, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.worktreePath))
        XCTAssertEqual(try gitText(["-C", result.worktreePath, "branch", "--show-current"]), result.branchName)
        XCTAssertEqual(try gitText(["-C", result.worktreePath, "rev-parse", "HEAD"]), sourceHead)
        XCTAssertTrue(try gitText(["-C", result.worktreePath, "status", "--porcelain"]).contains("source.txt"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: result.worktreePath).contains("new.txt"))
        XCTAssertEqual(try gitText(["-C", fixture.sourceURL.path, "rev-parse", "HEAD"]), sourceHead)
        XCTAssertEqual(try String(contentsOf: sourcePath, encoding: .utf8), sourceText)
        XCTAssertEqual(try gitText(["-C", fixture.sourceURL.path, "status", "--porcelain"]), "")
    }

    func testVerificationRequiresCustomCommandApprovalAndPassesArgumentsLiterally() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        do {
            _ = try await fixture.service.runVerification(
                sessionID: fixture.session.id,
                customExecutableURL: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["%s", "unapproved"],
                customCommandApproved: false
            )
            XCTFail("A custom verification command ran without approval.")
        } catch let error as AgentBridgeError {
            guard case .verificationCommandRejected = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let marker = fixture.rootURL.appendingPathComponent("shell-marker")
        let literalArgument = "$(touch \(marker.path)); still one argument"
        let result = try await fixture.service.runVerification(
            sessionID: fixture.session.id,
            customExecutableURL: URL(fileURLWithPath: "/usr/bin/printf"),
            arguments: ["%s", literalArgument],
            customCommandApproved: true
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, literalArgument)
        XCTAssertEqual(result.command?.arguments, ["%s", literalArgument])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertGreaterThanOrEqual(result.durationSeconds, 0)

        let events = try fixture.service.events(sessionID: fixture.session.id)
        XCTAssertTrue(events.contains(where: { $0.kind == "verification.completed" && $0.message.contains("Exit code 0") }))
        XCTAssertTrue(events.contains(where: { $0.kind == "verification.started" && $0.message.contains("printf") }))
    }

    func testVerificationCancellationIsReportedAndDoesNotPassAcceptanceGate() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let cancellation = CancellationFlag()
        let task = Task {
            try await fixture.service.runVerification(
                sessionID: fixture.session.id,
                customExecutableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"],
                customCommandApproved: true,
                cancellation: cancellation
            )
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        cancellation.cancel()
        let result = try await task.value
        XCTAssertTrue(result.wasCancelled)
        XCTAssertFalse(result.succeeded)
        let saved = try XCTUnwrap(fixture.store.session(id: fixture.session.id))
        XCTAssertEqual(saved.verificationPassed, false)
        do {
            _ = try await fixture.service.acceptChanges(sessionID: fixture.session.id)
            XCTFail("A cancelled verification passed the acceptance gate.")
        } catch let error as AgentBridgeError {
            guard case .verificationRequired = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private struct Fixture {
        let rootURL: URL
        let sourceURL: URL
        let store: AuditStore
        let service: BridgeService
        let session: SessionRecord
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-ChangeWorkflow-\(UUID().uuidString.lowercased())", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let workspaces = root.appendingPathComponent("workspace-data", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        try Data("original\n".utf8).write(to: source.appendingPathComponent("source.txt"))
        try git(["init", "-q", source.path])
        try git(["-C", source.path, "config", "user.name", "AgentBridge Tests"])
        try git(["-C", source.path, "config", "user.email", "agentbridge-tests@example.invalid"])
        try git(["-C", source.path, "add", "source.txt"])
        try git(["-C", source.path, "commit", "-q", "-m", "initial"])

        let store = try AuditStore(rootURL: state, workspaceRootURL: workspaces, managedWorkspaceRoots: [])
        let service = try BridgeService(store: store)
        let session = try await service.createSession(sourcePath: source.path, provider: .codex, accessMode: .isolatedChanges)
        return Fixture(rootURL: root, sourceURL: source, store: store, service: service, session: session)
    }

    @discardableResult
    private func git(_ arguments: [String], allowedExitCodes: Set<Int32> = [0]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_AUTHOR_NAME"] = "AgentBridge Tests"
        environment["GIT_AUTHOR_EMAIL"] = "agentbridge-tests@example.invalid"
        environment["GIT_COMMITTER_NAME"] = "AgentBridge Tests"
        environment["GIT_COMMITTER_EMAIL"] = "agentbridge-tests@example.invalid"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard allowedExitCodes.contains(process.terminationStatus) else {
            throw NSError(
                domain: "ChangeWorkflowTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
            )
        }
        return process.terminationStatus
    }

    private func gitText(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "ChangeWorkflowTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
            )
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
