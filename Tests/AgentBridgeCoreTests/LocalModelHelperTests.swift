import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

/// The local model helper, against a loopback fixture server: the switches, what
/// is sent, strict answers, fallbacks, limits, cancellation and what is never saved.
final class LocalModelHelperTests: XCTestCase {
    private let secret = "api_key = abcdefghijklmnopqrstuvwxyz0123456789"

    // MARK: Settings

    func testSettingsWithoutHelperFieldsDecodeAndEncodeUnchanged() throws {
        let legacy = #"{"defaultProvider":"codex","usageMode":"subscription","localModel":{"backend":"ollama","endpoint":"http://127.0.0.1:11434","model":"","contextWindowTokens":8192,"maxOutputTokens":1024}}"#
        let decoded = try JSONDecoder().decode(BridgeSettings.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.localModelHelper)
        XCTAssertEqual(decoded.localHelper, LocalModelHelperSettings())
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        XCTAssertNil(encoded?["localModelHelper"], "A settings file without the helper must be written as before.")

        var settings = decoded
        settings.localHelper = LocalModelHelperSettings(enabled: true, changeSummary: true)
        let reread = try JSONDecoder().decode(BridgeSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(reread.localHelper.allows(.changeSummary))
        XCTAssertFalse(reread.localHelper.allows(.commitText))
        settings.localHelper = LocalModelHelperSettings()
        XCTAssertNil(settings.localModelHelper, "All switches off stores nothing.")

        let partial = try JSONDecoder().decode(LocalModelHelperSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertEqual(partial, LocalModelHelperSettings(enabled: true))
    }

    func testTurningOnNeedsAPassingConnectionTest() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        var settings = try fixture.service.settings()
        settings.localModel.model = ""
        try fixture.service.saveSettings(settings)
        do {
            try await fixture.service.setLocalHelperEnabled(true)
            XCTFail("The helper was turned on without a model.")
        } catch AgentBridgeError.invalidInput {}

        settings.localModel.model = "helper-test"
        settings.localModel.endpoint = "http://127.0.0.1:\(try closedPort())"
        try fixture.service.saveSettings(settings)
        do {
            try await fixture.service.setLocalHelperEnabled(true)
            XCTFail("The helper was turned on although the server does not answer.")
        } catch AgentBridgeError.invalidInput(let message) {
            XCTAssertTrue(message.hasPrefix("The local model connection test did not pass"))
        }
        XCTAssertFalse(try fixture.service.localHelperSettings().enabled)

        settings.localModel.endpoint = "http://127.0.0.1:\(fixture.server.port)"
        try fixture.service.saveSettings(settings)
        let saved = try await fixture.service.setLocalHelperEnabled(true)
        XCTAssertTrue(saved.enabled)
        XCTAssertEqual(fixture.server.requests.map(\.method), ["GET"], "The test lists models and generates nothing.")
        let off = try await fixture.service.setLocalHelperEnabled(false)
        XCTAssertFalse(off.enabled)
    }

    // MARK: Switches

    func testHelperOffSendsNoRequest() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let outcome = try await fixture.service.summarizeChangesWithLocalModel(sessionID: fixture.session.id)
        XCTAssertNil(outcome.draft)
        XCTAssertEqual(outcome.fallbackReason, "The local model helper is off. Turn it on in Local model settings.")
        XCTAssertTrue(fixture.server.requests.isEmpty)
    }

    func testMasterOnButTaskOffSendsNoRequest() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try fixture.setHelper(LocalModelHelperSettings(enabled: true, commitText: true))
        let outcome = try await fixture.service.summarizeChangesWithLocalModel(sessionID: fixture.session.id)
        XCTAssertEqual(outcome.fallbackReason, "This local model helper task is off. Turn it on in Local model settings.")
        XCTAssertTrue(fixture.server.requests.isEmpty)
    }

    // MARK: A request

    func testSummarySendsRedactedDiffCountsUsageAndSavesNothing() async throws {
        let fixture = try await makeFixture(answer: "Summary: edits notes.\nThings to check: the new line.")
        defer { fixture.cleanUp() }
        try fixture.setHelper(LocalModelHelperSettings(enabled: true, changeSummary: true))
        let memoryBefore = try fixture.service.sharedMemory(sessionID: fixture.session.id)

        let preview = try await fixture.service.localHelperChangeSummaryPreview(sessionID: fixture.session.id)
        XCTAssertTrue(fixture.server.requests.isEmpty, "A preview sends nothing.")
        XCTAssertEqual(preview.files.map(\.path), ["notes.txt"])
        XCTAssertEqual(preview.files.first?.addedLines, 2)
        XCTAssertEqual(preview.files.first?.removedLines, 1)
        XCTAssertFalse(preview.truncated)

        let outcome = try await fixture.service.summarizeChangesWithLocalModel(sessionID: fixture.session.id)
        XCTAssertEqual(outcome.draft, "Summary: edits notes.\nThings to check: the new line.")
        XCTAssertNil(outcome.fallbackReason)
        XCTAssertEqual(outcome.preview, preview)
        XCTAssertEqual(fixture.server.requests.map(\.method), ["GET", "POST"])
        let prompt = try XCTUnwrap(fixture.sentPrompts().first)
        XCTAssertTrue(prompt.contains("=== CHANGED FILES"))
        XCTAssertTrue(prompt.contains("notes.txt (modified, +2 -1)"))
        XCTAssertTrue(prompt.contains("+changed line"))
        XCTAssertFalse(prompt.contains("abcdefghijklmnopqrstuvwxyz0123456789"), "Secrets are redacted before sending.")
        XCTAssertEqual(prompt, preview.prompt)

        // Counted against the Local profile, not Codex, and the tokens are kept separately.
        let local = try fixture.service.usageStatistics(provider: .local)
        XCTAssertEqual(local.localDailyRuns, 1)
        XCTAssertEqual(local.dailyTokens.inputTokens, 21)
        XCTAssertEqual(local.dailyTokens.outputTokens, 7)
        let codex = try fixture.service.usageStatistics(provider: .codex, selectedSessionID: fixture.session.id)
        XCTAssertEqual(codex.subscriptionDailyRuns, 0)
        XCTAssertEqual(codex.dailyTokens, .zero)

        // Audit: the task and sizes, never the prompt or the answer.
        let events = try fixture.store.events(sessionID: fixture.session.id)
        XCTAssertEqual(events.filter { $0.kind.hasPrefix("local_helper.") }.map(\.kind), ["local_helper.started", "local_helper.finished"])
        for event in events where event.kind.hasPrefix("local_helper.") {
            XCTAssertTrue(event.message.contains("task=changeSummary"))
            XCTAssertFalse(event.message.contains("changed line"))
            XCTAssertFalse(event.message.contains("Things to check"))
        }

        // Nothing reaches shared memory or the session's record.
        let memoryAfter = try fixture.service.sharedMemory(sessionID: fixture.session.id)
        XCTAssertEqual(memoryAfter.turns, memoryBefore.turns)
        XCTAssertEqual(memoryAfter.revision, memoryBefore.revision)
        XCTAssertEqual(try fixture.store.session(id: fixture.session.id)?.status, fixture.session.status)
    }

    func testHelperDoesNotNeedSharedMemoryConsent() async throws {
        let fixture = try await makeFixture(answer: "A summary.")
        defer { fixture.cleanUp() }
        try fixture.setHelper(LocalModelHelperSettings(enabled: true, changeSummary: true))
        try fixture.service.setAccountSharedMemoryAllowed(id: AccountProfile.defaultID(for: .local), allowed: false)
        try fixture.service.setAccountSharedMemoryAllowed(id: AccountProfile.defaultID(for: .codex), allowed: false)
        let outcome = try await fixture.service.summarizeChangesWithLocalModel(sessionID: fixture.session.id)
        XCTAssertEqual(outcome.draft, "A summary.")
    }

    func testInvalidAnswerFallsBackAndKeepsExistingText() async throws {
        let fixture = try await makeFixture(answer: "```json\n{\"done\":\"a\",\"next\":\"b\",\"prompt\":\"c\"}\n```")
        defer { fixture.cleanUp() }
        try fixture.setHelper(LocalModelHelperSettings(enabled: true, handoffSummary: true))
        try fixture.addTurns()
        let outcome = try await fixture.service.draftHandoffWithLocalModel(sessionID: fixture.session.id)
        XCTAssertNil(outcome.draft)
        XCTAssertTrue(outcome.fallbackReason?.hasPrefix("The local model's answer could not be used:") == true)
        XCTAssertTrue(try fixture.store.events(sessionID: fixture.session.id).contains {
            $0.kind == "local_helper.failed" && $0.message.contains("reason=invalid_answer")
        })
    }

    func testHandoffDraftFromRecentTurnsWritesNoMemory() async throws {
        let fixture = try await makeFixture(answer: #"{"done":"Added the parser.","next":"Write tests.","prompt":"Check git status, then write tests."}"#)
        defer { fixture.cleanUp() }
        try fixture.setHelper(LocalModelHelperSettings(enabled: true, handoffSummary: true))
        try fixture.addTurns()
        let before = try fixture.service.sharedMemory(sessionID: fixture.session.id)
        let outcome = try await fixture.service.draftHandoffWithLocalModel(sessionID: fixture.session.id)
        XCTAssertEqual(outcome.draft, LocalHelperHandoffDraft(done: "Added the parser.", next: "Write tests.", prompt: "Check git status, then write tests."))
        let prompt = try XCTUnwrap(fixture.sentPrompts().first)
        XCTAssertTrue(prompt.contains("User: Add a parser"))
        XCTAssertFalse(prompt.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        let after = try fixture.service.sharedMemory(sessionID: fixture.session.id)
        XCTAssertEqual(after.turns, before.turns)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertNil(try fixture.service.projectHandoffMarkdown(sessionID: fixture.session.id), "No handoff file is written.")
    }

    func testUnreachableServerFallsBack() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        try fixture.setHelper(LocalModelHelperSettings(enabled: true, changeSummary: true))
        var settings = try fixture.service.settings()
        settings.localModel.endpoint = "http://127.0.0.1:\(try closedPort())"
        try fixture.service.saveSettings(settings)
        let outcome = try await fixture.service.summarizeChangesWithLocalModel(sessionID: fixture.session.id)
        XCTAssertNil(outcome.draft)
        XCTAssertTrue(outcome.fallbackReason?.hasPrefix("The local model could not draft this:") == true)
    }

    func testTimeoutFallsBack() async throws {
        let gate = StallGate()
        let fixture = try await makeFixture(stall: gate)
        defer { gate.release(); fixture.cleanUp() }
        try fixture.setHelper(LocalModelHelperSettings(enabled: true, changeSummary: true))
        fixture.service.localHelperTimeout = 1
        let outcome = try await fixture.service.summarizeChangesWithLocalModel(sessionID: fixture.session.id)
        XCTAssertNil(outcome.draft)
        XCTAssertEqual(outcome.fallbackReason, "The local model did not answer in time.")
    }

    func testCancellationStopsTheRequest() async throws {
        let gate = StallGate()
        let fixture = try await makeFixture(stall: gate)
        defer { gate.release(); fixture.cleanUp() }
        try fixture.setHelper(LocalModelHelperSettings(enabled: true, changeSummary: true))
        let cancellation = CancellationFlag()
        let service = fixture.service
        let sessionID = fixture.session.id
        let task = Task { try await service.summarizeChangesWithLocalModel(sessionID: sessionID, cancellation: cancellation) }
        XCTAssertTrue(gate.waitUntilStarted())
        cancellation.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled request returned an outcome.")
        } catch AgentBridgeError.processCancelled {}
        XCTAssertTrue(try fixture.store.events(sessionID: sessionID).contains {
            $0.kind == "local_helper.failed" && $0.message.contains("reason=cancelled")
        })

        let already = CancellationFlag()
        already.cancel()
        do {
            _ = try await service.summarizeChangesWithLocalModel(sessionID: sessionID, cancellation: already)
            XCTFail("A request cancelled before it started ran.")
        } catch AgentBridgeError.processCancelled {}
    }

    func testRefusedAtTheLocalLimitWithoutARequest() async throws {
        let fixture = try await makeFixture(answer: "A summary.")
        defer { fixture.cleanUp() }
        try fixture.setHelper(LocalModelHelperSettings(enabled: true, changeSummary: true))
        let profile = AccountProfile.defaultID(for: .local).uuidString.lowercased()
        let source = fixture.session.id.uuidString.lowercased()
        for _ in 0..<LocalModelClient.defaultSessionRunLimit {
            try fixture.store.appendEvent(AuditEvent(
                sessionID: LocalModelHelper.usageStreamID,
                kind: "local.run.started",
                message: "account_profile_id=\(profile); source_id=\(source); local_helper=changeSummary; earlier request."
            ))
        }
        XCTAssertEqual(try fixture.service.usageStatistics(provider: .local).localDailyRuns, LocalModelClient.defaultSessionRunLimit)
        let outcome = try await fixture.service.summarizeChangesWithLocalModel(sessionID: fixture.session.id)
        XCTAssertNil(outcome.draft)
        XCTAssertTrue(outcome.fallbackReason?.hasPrefix("The local model request was not sent:") == true)
        XCTAssertTrue(fixture.server.requests.isEmpty)
    }

    func testPullRequestTextNeedsAnAppliedBranch() async throws {
        let fixture = try await makeFixture(answer: "{}")
        defer { fixture.cleanUp() }
        try fixture.setHelper(LocalModelHelperSettings(enabled: true, commitText: true))
        let outcome = try await fixture.service.draftPullRequestTextWithLocalModel(sessionID: fixture.session.id)
        XCTAssertNil(outcome.draft)
        XCTAssertEqual(outcome.fallbackReason, "The local model request was not sent: Apply the verified changes to a local branch first.")
        XCTAssertTrue(fixture.server.requests.isEmpty)
    }

    func testExplainFailureSendsTheRedactedOutputTailAndFileList() async throws {
        let fixture = try await makeFixture(answer: "What went wrong: a test failed.\nFiles to check: notes.txt")
        defer { fixture.cleanUp() }
        try fixture.setHelper(LocalModelHelperSettings(enabled: true, explainFailure: true))
        let failure = LocalHelperVerificationFailure(
            commandLabel: ".codex/ci.sh",
            exitCode: 1,
            output: "building\n\(secret)\nerror: expected 2, got 3\n"
        )
        let outcome = try await fixture.service.explainVerificationFailureWithLocalModel(sessionID: fixture.session.id, failure: failure)
        XCTAssertEqual(outcome.draft, "What went wrong: a test failed.\nFiles to check: notes.txt")
        let prompt = try XCTUnwrap(fixture.sentPrompts().first)
        XCTAssertTrue(prompt.contains("Command: .codex/ci.sh\nExit code: 1"))
        XCTAssertTrue(prompt.contains("error: expected 2, got 3"))
        XCTAssertTrue(prompt.contains("notes.txt (modified, +2 -1)"))
        XCTAssertFalse(prompt.contains("+changed line"), "The failure explanation lists files without their diff.")
        XCTAssertFalse(prompt.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    // MARK: Input building

    func testDiffIsTruncatedToTheBudgetWithANote() throws {
        let files = (1...5).map { index in
            ChangeFileDiff(path: "file\(index).swift", status: .modified, patch: patch(path: "file\(index).swift", lines: 30), isBinary: false)
        }
        let diff = WorkspaceChangeDiff(baseCommit: "abc", files: files, patch: Data())
        let full = try LocalModelHelper.changeSummaryPreview(diff: diff, budget: 100_000)
        XCTAssertFalse(full.truncated)
        XCTAssertEqual(full.sentFileCount, 5)

        let budget = full.promptBytes - 2 * files[4].patch.utf8.count + 64
        let cut = try LocalModelHelper.changeSummaryPreview(diff: diff, budget: budget)
        XCTAssertLessThanOrEqual(cut.promptBytes, budget)
        XCTAssertEqual(cut.sentFileCount, 3)
        XCTAssertEqual(cut.truncationNotes.first, "Truncated: only the first 3 of 5 files were sent.")
        XCTAssertEqual(cut.files.map { $0.sentPatchBytes > 0 }, [true, true, true, false, false])
        XCTAssertTrue(cut.prompt.contains("DIFF, first 3 of 5 files"))
        XCTAssertTrue(cut.prompt.contains("file3.swift (modified, +30 -30)"))
        XCTAssertTrue(cut.prompt.contains("file5.swift (modified, +30 -30)"), "Every file is listed even when its diff is not sent.")

        // When not even the first diff fits, its start is sent, cut at a line.
        let skeletonBytes = full.promptBytes - full.files.reduce(0) { $0 + $1.patchBytes }
        let tiny = try LocalModelHelper.changeSummaryPreview(diff: diff, budget: skeletonBytes + 250)
        XCTAssertLessThanOrEqual(tiny.promptBytes, skeletonBytes + 250)
        XCTAssertEqual(tiny.sentFileCount, 1)
        XCTAssertTrue(tiny.truncationNotes.contains("Only the start of the diff of file1.swift was sent."))
        XCTAssertLessThan(tiny.files[0].sentPatchBytes, tiny.files[0].patchBytes)

        XCTAssertThrowsError(try LocalModelHelper.changeSummaryPreview(diff: diff, budget: 200))
    }

    func testPullRequestInputHasThePlanFilesVerificationAndDiff() throws {
        let diff = WorkspaceChangeDiff(baseCommit: "abc", files: [
            ChangeFileDiff(path: "a.swift", status: .added, patch: patch(path: "a.swift", lines: 2), isBinary: false),
            ChangeFileDiff(path: "logo.png", status: .added, patch: "", isBinary: true),
            ChangeFileDiff(path: "big.json", status: .modified, patch: "", isBinary: false, isTooLargeToDisplay: true)
        ], patch: Data())
        let preview = try LocalModelHelper.pullRequestTextPreview(
            plan: .init(title: "Add a parser", summary: "Parse the file. \(secret)", steps: ["Write it", "Test it"]),
            diff: diff,
            verificationLabel: ".codex/ci.sh",
            verificationPassed: true,
            budget: 50_000
        )
        XCTAssertTrue(preview.prompt.contains("Title: Add a parser"))
        XCTAssertTrue(preview.prompt.contains("1. Write it\n2. Test it"))
        XCTAssertTrue(preview.prompt.contains("Recorded by AgentBridge: .codex/ci.sh ran and passed."))
        XCTAssertTrue(preview.prompt.contains("a.swift (added, +2 -2)"))
        XCTAssertTrue(preview.prompt.contains("logo.png (added, binary)"))
        XCTAssertTrue(preview.prompt.contains("big.json (modified, lines not counted)"))
        XCTAssertFalse(preview.prompt.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertEqual(preview.sentFileCount, 2, "A diff too long to show is not sent, and nothing after it.")
        XCTAssertEqual(preview.truncationNotes.first, "Truncated: only the first 2 of 3 files were sent.")
    }

    func testFailureOutputKeepsOnlyTheTail() throws {
        let long = (1...3_000).map { "line \($0)" }.joined(separator: "\n")
        let preview = try LocalModelHelper.failureExplanationPreview(
            failure: LocalHelperVerificationFailure(commandLabel: "ci.sh", exitCode: nil, output: long),
            files: [],
            budget: 6_000
        )
        XCTAssertLessThanOrEqual(preview.promptBytes, 6_000)
        XCTAssertTrue(preview.prompt.contains("line 3000"))
        XCTAssertFalse(preview.prompt.contains("line 1\n"))
        XCTAssertTrue(preview.prompt.contains("Exit code: not reported"))
        XCTAssertTrue(preview.truncationNotes.first?.hasPrefix("Truncated: only the last ") == true)
    }

    func testVerificationFailureLabelIsRelativeToTheWorkspace() {
        let result = VerificationResult(
            command: VerificationCommand(executablePath: "/w/session/.codex/ci.sh", arguments: [], workingDirectoryPath: "/w/session"),
            exitCode: 2,
            durationSeconds: 1,
            standardOutput: "out",
            standardError: "err",
            wasCancelled: false,
            timedOut: false
        )
        let failure = LocalHelperVerificationFailure(result: result, workspacePath: "/w/session")
        XCTAssertEqual(failure.commandLabel, ".codex/ci.sh")
        XCTAssertEqual(failure.exitCode, 2)
        XCTAssertEqual(failure.output, "out\nerr")
    }

    // MARK: Strict answers

    func testPullRequestAnswerIsReadStrictly() throws {
        let record = LocalModelHelper.verificationRecord(label: ".codex/ci.sh", passed: true)
        let good = #"{"commitSubject":"Add a parser","commitBody":"It reads the file.","prTitle":"Add a parser","prBody":"Adds a parser."}"#
        let text = try LocalModelHelper.parsePullRequestText(good, verificationRecord: record)
        XCTAssertEqual(text.commitMessage, "Add a parser\n\nIt reads the file.\n")
        XCTAssertEqual(text.title, "Add a parser")
        XCTAssertEqual(text.body, "Adds a parser.\n\n\(record)\n", "The recorded verification is stated.")
        XCTAssertFalse(text.commitSubjectIsLong)

        let emptyBody = #"{"commitSubject":"Fix it","commitBody":"","prTitle":"Fix it","prBody":"\#(record)"}"#
        let short = try LocalModelHelper.parsePullRequestText(emptyBody, verificationRecord: record)
        XCTAssertEqual(short.commitMessage, "Fix it\n")
        XCTAssertEqual(short.body, record + "\n")

        let long = String(repeating: "word ", count: 20).trimmingCharacters(in: .whitespaces)
        XCTAssertTrue(try LocalModelHelper.parsePullRequestText(
            #"{"commitSubject":"\#(long)","commitBody":"","prTitle":"t","prBody":""}"#, verificationRecord: record
        ).commitSubjectIsLong)

        for bad in [
            "```json\n\(good)\n```",
            "Here it is: \(good)",
            #"{"commitSubject":"a","commitBody":"b","prTitle":"c"}"#,
            #"{"commitSubject":"a","commitBody":"b","prTitle":"c","prBody":"d","extra":"e"}"#,
            #"{"commitSubject":1,"commitBody":"b","prTitle":"c","prBody":"d"}"#,
            #"{"commitSubject":"two\nlines","commitBody":"b","prTitle":"c","prBody":"d"}"#,
            #"{"commitSubject":"","commitBody":"b","prTitle":"c","prBody":"d"}"#,
            #"{"commitSubject":"\#(String(repeating: "x", count: 201))","commitBody":"","prTitle":"c","prBody":"d"}"#,
            #"{"commitSubject":"a","commitBody":"b","prTitle":"","prBody":"d"}"#,
            "[]"
        ] {
            XCTAssertThrowsError(try LocalModelHelper.parsePullRequestText(bad, verificationRecord: record), bad)
        }
    }

    func testHandoffAnswerIsReadStrictly() throws {
        XCTAssertEqual(
            try LocalModelHelper.parseHandoff(#"{"done":" Did a. ","next":"Do b.","prompt":"Check, then do b."}"#),
            LocalHelperHandoffDraft(done: "Did a.", next: "Do b.", prompt: "Check, then do b.")
        )
        for bad in [
            #"{"done":"a","next":"b"}"#,
            #"{"done":"a","next":"b","prompt":"c","notes":"d"}"#,
            #"{"done":"a","next":"","prompt":"c"}"#,
            #"{"done":"a","next":["b"],"prompt":"c"}"#,
            #"{"done":"\#(String(repeating: "x", count: 6_001))","next":"b","prompt":"c"}"#,
            "done: a",
            "```\n{\"done\":\"a\",\"next\":\"b\",\"prompt\":\"c\"}\n```"
        ] {
            XCTAssertThrowsError(try LocalModelHelper.parseHandoff(bad), bad)
        }
    }

    func testPlainAnswerMustBeBoundedText() throws {
        XCTAssertEqual(try LocalModelHelper.parsePlainText("  An answer.\n"), "An answer.")
        XCTAssertThrowsError(try LocalModelHelper.parsePlainText("  \n"))
        XCTAssertThrowsError(try LocalModelHelper.parsePlainText(String(repeating: "x", count: 32 * 1_024 + 1)))
    }

    // MARK: Fixture

    private struct Fixture {
        let root: URL
        let store: AuditStore
        let service: BridgeService
        let server: LoopbackHTTPServer
        let session: SessionRecord

        func cleanUp() {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }

        func setHelper(_ helper: LocalModelHelperSettings) throws {
            var settings = try service.settings()
            settings.localHelper = helper
            try service.saveSettings(settings)
        }

        func sentPrompts() throws -> [String] {
            try server.requests.filter { $0.method == "POST" }.map { request in
                let messages = try XCTUnwrap(request.jsonBody?["messages"] as? [[String: Any]])
                return try XCTUnwrap(messages.first?["content"] as? String)
            }
        }

        func addTurns() throws {
            let scope = try service.memoryScope(for: session)
            try service.sharedMemoryStore.appendTurn(scope: scope, provider: .codex, userText: "Add a parser", assistantText: "I added the parser.")
            try service.sharedMemoryStore.appendTurn(scope: scope, provider: .codex, userText: "Note \("api_key = abcdefghijklmnopqrstuvwxyz0123456789")", assistantText: "Noted.")
        }
    }

    private func makeFixture(answer: String = "An answer.", stall: StallGate? = nil) async throws -> Fixture {
        let root = try fixtureParent().appendingPathComponent("AgentBridge-LocalHelper-\(UUID().uuidString.lowercased())", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let data = root.appendingPathComponent("data", isDirectory: true)
        for directory in [source, state, data] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try Data("first line\nsecond line\n".utf8).write(to: source.appendingPathComponent("notes.txt"))
        try FixtureGit.run(["init", "-q", "--initial-branch=main", source.path])
        try FixtureGit.run(["-C", source.path, "add", "notes.txt"])
        try FixtureGit.run(["-C", source.path, "-c", "user.name=Tests", "-c", "user.email=tests@example.invalid", "commit", "-q", "-m", "initial"])

        let modelList = Data(#"{"models":[{"name":"helper-test"}]}"#.utf8)
        let escaped = String(data: try JSONSerialization.data(withJSONObject: [answer]), encoding: .utf8)!.dropFirst().dropLast()
        let stream = Data([
            #"{"message":{"role":"assistant","content":\#(escaped)},"done":false}"#,
            #"{"done":true,"done_reason":"stop","prompt_eval_count":21,"eval_count":7}"#
        ].joined(separator: "\n").appending("\n").utf8)
        let server = try LoopbackHTTPServer { request in
            if request.method == "GET" { return .json(modelList) }
            if let stall { return .stalled(Data(#"{"message":{"content":"partial"},"done":false}"#.utf8), declaredLength: 512, gate: stall) }
            return .stream(stream)
        }
        let store = try AuditStore(rootURL: state, workspaceRootURL: data, managedWorkspaceRoots: [])
        let service = try BridgeService(store: store, baseEnvironment: ["HOME": root.path, "PATH": "/usr/bin:/bin"])
        var settings = try service.settings()
        settings.localModel = LocalModelSettings(backend: .ollama, endpoint: "http://127.0.0.1:\(server.port)", model: "helper-test")
        try service.saveSettings(settings)
        let session = try await service.createSession(sourcePath: source.path, provider: .codex, accessMode: .isolatedChanges)
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true)
        try Data("changed line\nsecond line\n\(secret)\n".utf8).write(to: workspace.appendingPathComponent("notes.txt"))
        return Fixture(root: root, store: store, service: service, server: server, session: session)
    }

    private func patch(path: String, lines: Int) -> String {
        var text = "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n@@ -1,\(lines) +1,\(lines) @@\n"
        for index in 0..<lines { text += "-old \(index)\n+new \(index)\n" }
        return text
    }

    /// A loopback port nothing listens on.
    private func closedPort() throws -> UInt16 {
        let server = try LoopbackHTTPServer { _ in .json(Data()) }
        let port = server.port
        server.stop()
        return port
    }

    private func fixtureParent() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = packageRoot.appendingPathComponent("build/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let resolved = parent.path.withCString({ realpath($0, nil) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }
}
