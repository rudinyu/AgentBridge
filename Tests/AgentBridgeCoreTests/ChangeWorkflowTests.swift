import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

/// macOS refuses a nested sandbox, so these cannot run when AgentBridge verifies itself.
func skipInsideVerificationSandbox() throws {
    try XCTSkipIf(ProcessInfo.processInfo.environment[ProcessSandbox.verificationMarker] != nil)
}

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

    func testReviewingChangesStillWorksWhileTheRunLimitIsReached() async throws {
        // The App asks for the diff of the selected session on every refresh, and the
        // user must still be able to inspect, restore and export while three runs are
        // in progress. Only provider runs count toward the limit.
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        try Data("changed in session\n".utf8).write(to: workspace.appendingPathComponent("source.txt"))

        var runs: [SessionRunLease] = []
        for _ in 0..<AuditStore.maximumConcurrentRuns {
            runs.append(try fixture.store.acquireRunLease(for: UUID(), countsTowardRunLimit: true))
        }
        XCTAssertThrowsError(try fixture.store.acquireRunLease(for: UUID(), countsTowardRunLimit: true))

        let diff = try await fixture.service.changesDiff(sessionID: fixture.session.id)
        XCTAssertEqual(diff.files.map(\.path), ["source.txt"])
        let patch = try await fixture.service.exportChangePatch(sessionID: fixture.session.id)
        XCTAssertTrue(String(decoding: patch, as: UTF8.self).contains("changed in session"))
        try await fixture.service.restoreAllChanges(sessionID: fixture.session.id)
        _ = runs
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
        try skipInsideVerificationSandbox()
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

    func testDefaultVerificationRunsAnUnchangedProjectScript() async throws {
        try skipInsideVerificationSandbox()
        let fixture = try await makeFixture(projectScript: "#!/bin/sh\necho project\n")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let result = try await fixture.service.runVerification(sessionID: fixture.session.id)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, "project\n")
    }

    func testChangedProjectScriptRunsOnlyAfterApprovalAsACustomCommand() async throws {
        try skipInsideVerificationSandbox()
        let fixture = try await makeFixture(projectScript: "#!/bin/sh\nexit 1\n")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let script = URL(fileURLWithPath: fixture.session.workspacePath).appendingPathComponent(".codex/ci.sh")
        try Data("#!/bin/sh\necho changed script\n".utf8).write(to: script)

        try await assertDefaultVerificationRejected(fixture)

        let result = try await fixture.service.runVerification(
            sessionID: fixture.session.id,
            customExecutableURL: script,
            customCommandApproved: true
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.standardOutput, "changed script\n")
    }

    func testVerificationRunsThePatchAndNotGitIgnoredFiles() async throws {
        try skipInsideVerificationSandbox()
        let fixture = try await makeFixture(projectScript: """
        #!/bin/sh
        grep -q patched source.txt || exit 1
        [ ! -e planted ] || exit 2
        """)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath)
        try Data("patched\n".utf8).write(to: workspace.appendingPathComponent("source.txt"))
        try Data("planted\n".utf8).write(to: workspace.appendingPathComponent(".gitignore"))
        try Data("from the provider\n".utf8).write(to: workspace.appendingPathComponent("planted"))
        let diff = try await fixture.service.changesDiff(sessionID: fixture.session.id)
        XCTAssertEqual(diff.ignoredPaths, ["planted"])

        let result = try await fixture.service.runVerification(sessionID: fixture.session.id)
        XCTAssertTrue(result.succeeded, result.standardError)
        XCTAssertNoThrow(try FileManager.default.contentsOfDirectory(atPath: workspace.path))
    }

    func testIgnoredCustomProgramIsRefusedBecauseItIsNotInThePatch() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath)
        let program = workspace.appendingPathComponent("planted")
        try Data("planted\n".utf8).write(to: workspace.appendingPathComponent(".gitignore"))
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        do {
            _ = try await fixture.service.runVerification(
                sessionID: fixture.session.id,
                customExecutableURL: program,
                customCommandApproved: true
            )
            XCTFail("An ignored program passed verification.")
        } catch let error as AgentBridgeError {
            guard case .verificationCommandRejected = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testVerificationCannotWriteOrReadOutsideItsCheckout() async throws {
        try skipInsideVerificationSandbox()
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath)
        let outside = fixture.sourceURL.appendingPathComponent("escaped")
        let secret = fixture.store.rootURL.appendingPathComponent("planted-secret")
        try Data("secret\n".utf8).write(to: secret)
        let script = workspace.appendingPathComponent("probe.sh")
        try Data("""
        #!/bin/sh
        touch '\(workspace.appendingPathComponent("escaped").path)' 2>/dev/null && echo wrote-workspace
        touch '\(outside.path)' 2>/dev/null && echo wrote-source
        cat '\(secret.path)' 2>/dev/null && echo read-secret
        cat '\(fixture.sourceURL.appendingPathComponent("source.txt").path)' 2>/dev/null && echo read-source
        ls '\(NSHomeDirectory())' >/dev/null 2>&1 && echo listed-home
        touch inside && echo wrote-checkout
        exit 0
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let result = try await fixture.service.runVerification(
            sessionID: fixture.session.id,
            customExecutableURL: script,
            customCommandApproved: true
        )
        XCTAssertEqual(result.standardOutput, "wrote-checkout\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("escaped").path))
    }

    func testClaudeChangeRunIsConfinedToTheWorkspaceAndCannotEditGitMetadata() async throws {
        try skipInsideVerificationSandbox()
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let secret = fixture.store.rootURL.appendingPathComponent("planted-secret")
        try Data("secret\n".utf8).write(to: secret)
        let claude = fixture.rootURL.appendingPathComponent("mock-bin/claude")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        case " $* " in
          *" auth status "*)
            printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}'
            exit 0 ;;
        esac
        /bin/cat >/dev/null
        found=""
        echo edited > source.txt && found="$found edited-workspace"
        echo x >> .git/config 2>/dev/null && found="$found wrote-git"
        cat '\(secret.path)' >/dev/null 2>&1 && found="$found read-secret"
        cat '\(fixture.sourceURL.appendingPathComponent("source.txt").path)' >/dev/null 2>&1 && found="$found read-source"
        touch '\(fixture.sourceURL.appendingPathComponent("escaped").path)' 2>/dev/null && found="$found wrote-source"
        printf '{"type":"result","subtype":"success","result":"%s"}\\n' "$found"
        """.utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)
        var settings = try fixture.service.settings()
        settings.claudeBinaryPath = claude.path
        settings.usageMode = .subscription
        try fixture.service.saveSettings(settings)
        let session = try await fixture.service.createSession(
            sourcePath: fixture.sourceURL.path,
            provider: .claude,
            accessMode: .isolatedChanges
        )
        let plan = try fixture.service.createChangePlan(
            sessionID: session.id,
            title: "Edit the file",
            summary: "Change source.txt.",
            steps: ["Edit source.txt."]
        )
        _ = try fixture.service.approveChangePlan(sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest)

        let output = try await fixture.service.runChanges(
            sessionID: session.id,
            prompt: "Edit source.txt.",
            planID: plan.id,
            reviewedDigest: plan.reviewDigest
        )
        XCTAssertEqual(output.text, " edited-workspace")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.appendingPathComponent("escaped").path))
        let diff = try await fixture.service.changesDiff(sessionID: session.id)
        XCTAssertEqual(diff.files.map(\.path), ["source.txt"])
    }

    func testVerificationThatEditsTheCheckoutFails() async throws {
        try skipInsideVerificationSandbox()
        let fixture = try await makeFixture(projectScript: "#!/bin/sh\necho edited > source.txt\n")
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let result = try await fixture.service.runVerification(sessionID: fixture.session.id)
        XCTAssertTrue(result.workspaceChangedDuringVerification)
        XCTAssertFalse(result.succeeded)
    }

    func testGitFilterLeftInTheCheckoutDoesNotRunOutsideTheSandbox() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("filter-ran")
        let fixture = try await makeFixture(projectScript: """
        #!/bin/sh
        git config filter.review.clean 'touch \(marker.path); cat'
        echo 'source.txt filter=review' > .gitattributes
        """)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let result = try await fixture.service.runVerification(sessionID: fixture.session.id)
        XCTAssertFalse(result.succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testProjectScriptAddedToTheWorkspaceIsRefusedEvenWhenGitIgnoresIt() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath)
        let marker = fixture.rootURL.appendingPathComponent("script-ran")
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        let script = workspace.appendingPathComponent(".codex/ci.sh")
        try Data("#!/bin/sh\ntouch \(marker.path)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Data("*\n".utf8).write(to: workspace.appendingPathComponent(".codex/.gitignore"))
        let diff = try await fixture.service.changesDiff(sessionID: fixture.session.id)
        XCTAssertTrue(diff.files.isEmpty)
        XCTAssertTrue(diff.ignoredPaths.contains(".codex/"))

        try await assertDefaultVerificationRejected(fixture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testProjectScriptMadeExecutableInTheWorkspaceIsRefused() async throws {
        let fixture = try await makeFixture(projectScript: "#!/bin/sh\nexit 0\n", projectScriptPermissions: 0o644)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let script = URL(fileURLWithPath: fixture.session.workspacePath).appendingPathComponent(".codex/ci.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try await assertDefaultVerificationRejected(fixture)
    }

    func testWorkspaceGitFilterIsRefusedBeforeGitCanRunIt() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath)
        let marker = fixture.rootURL.appendingPathComponent("filter-ran")
        try git(["-C", workspace.path, "config", "filter.review.clean", "touch \(marker.path); cat"])
        try Data("source.txt filter=review\n".utf8).write(to: workspace.appendingPathComponent(".gitattributes"))
        try Data("changed\n".utf8).write(to: workspace.appendingPathComponent("source.txt"))

        await assertGitSettingsRejected { _ = try await fixture.service.changesDiff(sessionID: fixture.session.id) }
        await assertGitSettingsRejected { _ = try await fixture.service.runVerification(sessionID: fixture.session.id) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testWorkspaceGitIncludeIsRefused() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try git(["-C", fixture.session.workspacePath, "config", "include.path", "/dev/null"])
        await assertGitSettingsRejected { _ = try await fixture.service.changesDiff(sessionID: fixture.session.id) }
    }

    func testCommitIdentitySetInTheWorkspaceIsAllowed() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try git(["-C", fixture.session.workspacePath, "config", "user.name", "AgentBridge Tests"])
        try git(["-C", fixture.session.workspacePath, "config", "user.email", "agentbridge-tests@example.invalid"])
        let diff = try await fixture.service.changesDiff(sessionID: fixture.session.id)
        XCTAssertTrue(diff.files.isEmpty)
    }

    func testNonUTF8FileIsReviewedAndAppliedWithItsOriginalBytes() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let big5 = Data([0xA4, 0x40, 0xA4, 0x48, 0x0A])
        let name = "big5.txt"
        try big5.write(to: URL(fileURLWithPath: fixture.session.workspacePath).appendingPathComponent(name))

        let diff = try await fixture.service.changesDiff(sessionID: fixture.session.id)
        let file = try XCTUnwrap(diff.files.first)
        XCTAssertTrue(file.hasUndecodableText)
        XCTAssertFalse(file.isBinary)
        XCTAssertFalse(file.patch.isEmpty)
        XCTAssertNotNil(diff.patch.range(of: Data([0xA4, 0x40, 0xA4, 0x48])))

        let worktree = try await applyVerified(diff, fixture)
        XCTAssertEqual(try Data(contentsOf: worktree.appendingPathComponent(name)), big5)
    }

    func testLongFileIsHiddenFromDisplayButStillApplied() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let long = Data(String(repeating: "generated lockfile line\n", count: 100_000).utf8)
        let name = "package-lock.json"
        try long.write(to: URL(fileURLWithPath: fixture.session.workspacePath).appendingPathComponent(name))
        try Data("changed\n".utf8).write(to: URL(fileURLWithPath: fixture.session.workspacePath).appendingPathComponent("source.txt"))

        let diff = try await fixture.service.changesDiff(sessionID: fixture.session.id)
        let hidden = try XCTUnwrap(diff.files.first { $0.path == name })
        XCTAssertTrue(hidden.isTooLargeToDisplay)
        XCTAssertEqual(hidden.patch, "")
        let shown = try XCTUnwrap(diff.files.first { $0.path == "source.txt" })
        XCTAssertFalse(shown.isTooLargeToDisplay)
        XCTAssertTrue(shown.patch.contains("changed"))
        XCTAssertGreaterThan(diff.patch.count, long.count)

        let worktree = try await applyVerified(diff, fixture)
        XCTAssertEqual(try Data(contentsOf: worktree.appendingPathComponent(name)), long)
    }

    func testDiffOverTheTotalLimitIsStillRefused() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let tooLong = Data(String(repeating: "generated lockfile line\n", count: 500_000).utf8)
        try tooLong.write(to: URL(fileURLWithPath: fixture.session.workspacePath).appendingPathComponent("huge.txt"))
        do {
            _ = try await fixture.service.changesDiff(sessionID: fixture.session.id)
            XCTFail("A diff over the total limit was accepted.")
        } catch let error as AgentBridgeError {
            guard case .git(let message) = error, message.contains("full diff exceeds the size limit") else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPartiallyShownFilesNeedAConfirmationToAcceptOrApply() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let file = URL(fileURLWithPath: fixture.session.workspacePath).appendingPathComponent("big5.txt")
        try Data([0xA4, 0x40, 0x0A]).write(to: file)
        let diff = try await fixture.service.changesDiff(sessionID: fixture.session.id)
        XCTAssertEqual(diff.partiallyShownFiles.map(\.path), ["big5.txt"])
        try markVerified(diff, fixture)

        await assertPartiallyShownRefused { _ = try await fixture.service.acceptChanges(sessionID: fixture.session.id) }
        await assertPartiallyShownRefused {
            _ = try await fixture.service.applyChangesToLocalBranch(sessionID: fixture.session.id, branchName: "agentbridge/unconfirmed")
        }
        XCTAssertNil(try XCTUnwrap(fixture.store.session(id: fixture.session.id)).changesAcceptedAt)

        let accepted = try await fixture.service.acceptChanges(sessionID: fixture.session.id, partiallyShownFilesConfirmedDigest: diff.digest)
        XCTAssertNotNil(accepted.changesAcceptedAt)
        let events = try fixture.service.events(sessionID: fixture.session.id)
        XCTAssertTrue(events.contains { $0.kind == "change.partially_shown_confirmed" && $0.message.contains(diff.digest) })

        let result = try await fixture.service.applyChangesToLocalBranch(
            sessionID: fixture.session.id,
            branchName: "agentbridge/confirmed",
            partiallyShownFilesConfirmedDigest: diff.digest
        )
        XCTAssertEqual(result.changedFileCount, 1)
    }

    func testPartiallyShownConfirmationDoesNotCarryOverToALaterDiff() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let file = URL(fileURLWithPath: fixture.session.workspacePath).appendingPathComponent("big5.txt")
        try Data([0xA4, 0x40, 0x0A]).write(to: file)
        let confirmedDiff = try await fixture.service.changesDiff(sessionID: fixture.session.id)

        try Data([0xA4, 0x48, 0x0A]).write(to: file)
        let laterDiff = try await fixture.service.changesDiff(sessionID: fixture.session.id)
        try markVerified(laterDiff, fixture)

        await assertPartiallyShownRefused {
            _ = try await fixture.service.acceptChanges(sessionID: fixture.session.id, partiallyShownFilesConfirmedDigest: confirmedDiff.digest)
        }
        await assertPartiallyShownRefused {
            _ = try await fixture.service.applyChangesToLocalBranch(
                sessionID: fixture.session.id,
                branchName: "agentbridge/stale-confirmation",
                partiallyShownFilesConfirmedDigest: confirmedDiff.digest
            )
        }
    }

    func testFullyShownDiffNeedsNoExtraConfirmation() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        try Data("changed\n".utf8).write(to: URL(fileURLWithPath: fixture.session.workspacePath).appendingPathComponent("source.txt"))
        let diff = try await fixture.service.changesDiff(sessionID: fixture.session.id)
        XCTAssertTrue(diff.partiallyShownFiles.isEmpty)
        try markVerified(diff, fixture)
        let accepted = try await fixture.service.acceptChanges(sessionID: fixture.session.id)
        XCTAssertNotNil(accepted.changesAcceptedAt)
    }

    func testVerificationCancellationIsReportedAndDoesNotPassAcceptanceGate() async throws {
        try skipInsideVerificationSandbox()
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

    @discardableResult
    func testWorkspaceThatHidesEditsFromTheDiffIsRefused() async throws {
        let hidingMoves: [(URL) throws -> Void] = [
            { workspace in
                try Data("hidden.txt\n".utf8).write(to: workspace.appendingPathComponent(".git/info/exclude"))
            },
            { workspace in
                try self.git(["-C", workspace.path, "update-index", "--assume-unchanged", "source.txt"])
            },
            { workspace in
                try self.git(["-C", workspace.path, "update-index", "--skip-worktree", "source.txt"])
            }
        ]
        for hide in hidingMoves {
            let fixture = try await makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
            let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
            try Data("changed\n".utf8).write(to: workspace.appendingPathComponent("source.txt"))
            try hide(workspace)
            await assertGitSettingsRejected {
                _ = try await WorkspaceManager(store: fixture.store).diff(for: fixture.session)
            }
        }
    }

    func testCommentsInTheExcludeFileAreNotRefused() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        try Data("# a comment\n\n# another\n".utf8).write(to: workspace.appendingPathComponent(".git/info/exclude"))
        let diff = try await WorkspaceManager(store: fixture.store).diff(for: fixture.session)
        XCTAssertTrue(diff.files.isEmpty)
    }

    func testIgnoredFilesAreListedButStayOutOfTheDigest() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let manager = WorkspaceManager(store: fixture.store)
        let workspace = URL(fileURLWithPath: fixture.session.workspacePath, isDirectory: true)
        try Data("build/\n".utf8).write(to: workspace.appendingPathComponent(".gitignore"))
        let before = try await manager.diff(for: fixture.session)
        XCTAssertEqual(before.ignoredPaths, [])

        let build = workspace.appendingPathComponent("build/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data("output\n".utf8).write(to: build.appendingPathComponent("first"))
        try Data("output\n".utf8).write(to: build.appendingPathComponent("second"))
        let selfIgnored = workspace.appendingPathComponent("vendored", isDirectory: true)
        try FileManager.default.createDirectory(at: selfIgnored, withIntermediateDirectories: true)
        try Data("*\n".utf8).write(to: selfIgnored.appendingPathComponent(".gitignore"))

        let after = try await manager.diff(for: fixture.session)
        XCTAssertTrue(after.ignoredPaths.contains("build/"))
        XCTAssertTrue(after.ignoredPaths.contains("vendored/"))
        XCTAssertEqual(after.digest, before.digest)
        XCTAssertEqual(after.files.map(\.path), [".gitignore"])
    }

    private func markVerified(_ diff: WorkspaceChangeDiff, _ fixture: Fixture) throws -> SessionRecord {
        var verifiedSession = fixture.session
        let changeAt = Date()
        verifiedSession.lastChangeRunAt = changeAt
        verifiedSession.verificationPassed = true
        verifiedSession.verificationDiffDigest = diff.digest
        verifiedSession.verificationCompletedAt = changeAt.addingTimeInterval(1)
        try fixture.store.saveSession(verifiedSession)
        return verifiedSession
    }

    private func applyVerified(_ diff: WorkspaceChangeDiff, _ fixture: Fixture) async throws -> URL {
        let verifiedSession = try markVerified(diff, fixture)
        let result = try await WorkspaceManager(store: fixture.store).applyVerifiedChangesToLocalBranch(
            for: verifiedSession,
            branchName: "agentbridge/review-test",
            diff: diff
        )
        return URL(fileURLWithPath: result.worktreePath, isDirectory: true)
    }

    private func assertDefaultVerificationRejected(_ fixture: Fixture, line: UInt = #line) async throws {
        do {
            _ = try await fixture.service.runVerification(sessionID: fixture.session.id)
            XCTFail("A changed project script ran as the default verification.", line: line)
        } catch let error as AgentBridgeError {
            guard case .verificationCommandRejected(let message) = error, message.contains("differs from the pinned commit") else {
                return XCTFail("Unexpected error: \(error)", line: line)
            }
        }
    }

    private func assertPartiallyShownRefused(line: UInt = #line, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Files that were not fully shown were taken without a matching confirmation.", line: line)
        } catch let error as AgentBridgeError {
            guard case .invalidInput(let message) = error, message.contains("not fully shown") else {
                return XCTFail("Unexpected error: \(error)", line: line)
            }
        } catch {
            XCTFail("Unexpected error: \(error)", line: line)
        }
    }

    private func assertGitSettingsRejected(line: UInt = #line, _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("The workspace's changed Git settings were accepted.", line: line)
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch(let message) = error, message.contains("Git settings were changed") else {
                return XCTFail("Unexpected error: \(error)", line: line)
            }
        } catch {
            XCTFail("Unexpected error: \(error)", line: line)
        }
    }

    private func makeFixture(projectScript: String? = nil, projectScriptPermissions: Int = 0o755) async throws -> Fixture {
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
        if let projectScript {
            let script = source.appendingPathComponent(".codex/ci.sh")
            try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(projectScript.utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: projectScriptPermissions], ofItemAtPath: script.path)
            try git(["-C", source.path, "add", ".codex/ci.sh"])
        }
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
