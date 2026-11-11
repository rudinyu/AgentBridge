import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class TokenUsageTests: XCTestCase {
    func testClaudeResultReportsTokensWithCacheSeparate() throws {
        let output = try ProviderOutputParser.parse(provider: .claude, data: Data("""
        {"type":"system","subtype":"init","session_id":"3b12f1df-5232-4804-897e-917bf397618a"}
        {"type":"result","subtype":"success","result":"done","usage":{"input_tokens":12,"cache_read_input_tokens":300,"cache_creation_input_tokens":40,"output_tokens":7}}
        """.utf8))
        XCTAssertEqual(output.tokenUsage, TokenUsage(inputTokens: 12, cachedInputTokens: 300, cacheWriteTokens: 40, outputTokens: 7))
        XCTAssertEqual(output.tokenUsage?.totalTokens, 359)
    }

    func testCodexInputTotalHasItsCachedPartRemoved() throws {
        let output = try ProviderOutputParser.parse(provider: .codex, data: Data("""
        {"type":"item.completed","item":{"type":"agent_message","text":"done"}}
        {"type":"turn.completed","usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":50}}
        """.utf8))
        XCTAssertEqual(output.tokenUsage, TokenUsage(inputTokens: 200, cachedInputTokens: 800, outputTokens: 50))
    }

    func testMissingOrMalformedUsageLeavesTokensOutWithoutFailingTheRun() throws {
        let missing = try ProviderOutputParser.parse(provider: .codex, data: Data("""
        {"type":"item.completed","item":{"type":"agent_message","text":"done"}}
        {"type":"turn.completed"}
        """.utf8))
        XCTAssertEqual(missing.text, "done")
        XCTAssertNil(missing.tokenUsage)
        for usage in [#"{"input_tokens":-1,"output_tokens":2}"#, #"{"input_tokens":true,"output_tokens":2}"#, #"{"input_tokens":1.5,"output_tokens":2}"#, #"{"output_tokens":2}"#] {
            let output = try ProviderOutputParser.parse(provider: .claude, data: Data(#"{"type":"result","subtype":"success","result":"done","usage":\#(usage)}"#.utf8))
            XCTAssertEqual(output.text, "done")
            XCTAssertNil(output.tokenUsage, usage)
        }
    }

    func testEventsSavedBeforeTokenUsageExistedStillDecode() throws {
        let event = try JSONDecoder().decode(AuditEvent.self, from: Data("""
        {"id":"3B12F1DF-5232-4804-897E-917BF397618A","timestamp":0,"sessionID":"3B12F1DF-5232-4804-897E-917BF397618B","kind":"run.output","message":"old"}
        """.utf8))
        XCTAssertNil(event.tokenUsage)
        let encoded = try JSONEncoder().encode(AuditEvent(sessionID: UUID(), kind: "usage.tokens", message: "m", tokenUsage: TokenUsage(outputTokens: 3)))
        XCTAssertEqual(try JSONDecoder().decode(AuditEvent.self, from: encoded).tokenUsage, TokenUsage(outputTokens: 3))
    }

    func testTokensAreSummedPerWindowAndSession() {
        let now = Date()
        let profileID = AccountProfile.defaultID(for: .codex)
        let session = SessionRecord(
            id: UUID(), provider: .codex, sourceRepositoryPath: "/tmp/source", workspacePath: "/tmp/workspace",
            snapshotCommit: String(repeating: "a", count: 40), sourceWasDirty: false, policy: SessionPolicy(),
            accountProfileID: profileID
        )
        let other = UUID()
        func tokens(_ hoursAgo: Double, _ output: Int, session id: UUID) -> AuditEvent {
            AuditEvent(timestamp: now.addingTimeInterval(-hoursAgo * 3_600), sessionID: id, kind: "usage.tokens", message: "", tokenUsage: TokenUsage(outputTokens: output))
        }
        let snapshot = UsageStatisticsAggregator.aggregate(
            provider: .codex,
            accountProfileID: profileID,
            sessions: [session],
            events: [tokens(1, 1, session: session.id), tokens(10, 10, session: session.id), tokens(100, 100, session: session.id),
                     tokens(200, 1_000, session: session.id), tokens(1, 5_000, session: other)],
            selectedSessionID: session.id,
            now: now
        )
        XCTAssertEqual(snapshot.fiveHourTokens.outputTokens, 1)
        XCTAssertEqual(snapshot.dailyTokens.outputTokens, 11)
        XCTAssertEqual(snapshot.sevenDayTokens.outputTokens, 111)
        XCTAssertEqual(snapshot.sessionTokens.outputTokens, 1_111, "Another account's session must not be counted.")
    }

    func testAManagedRunRecordsTheTokensItsCLIReported() async throws {
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
        let canonicalParent = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
        let root = canonicalParent.appendingPathComponent("AgentBridge-Tokens-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("tracked\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        for arguments in [["init", "-q", source.path], ["-C", source.path, "add", "."],
                          ["-C", source.path, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "init"]] {
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = arguments
            try git.run()
            git.waitUntilExit()
            XCTAssertEqual(git.terminationStatus, 0)
        }
        let codex = root.appendingPathComponent("bin/codex")
        try FileManager.default.createDirectory(at: codex.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"""
        #!/bin/sh
        case " $* " in *"login status"*) printf '%s\n' 'Logged in using ChatGPT'; exit 0 ;; esac
        /bin/cat >/dev/null
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"answer"}}'
        printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":900,"cached_input_tokens":600,"output_tokens":40}}'
        """#.utf8).write(to: codex)
        XCTAssertEqual(chmod(codex.path, 0o700), 0)

        let store = try AuditStore(rootURL: root.appendingPathComponent("state", isDirectory: true))
        let service = try BridgeService(store: store, baseEnvironment: ["HOME": root.path, "USER": "fixture"])
        var settings = try service.settings()
        settings.codexBinaryPath = codex.path
        settings.usageMode = .subscription
        try service.saveSettings(settings)
        let session = try await service.createSession(sourcePath: source.path, provider: .codex)
        _ = try await service.runReadOnly(sessionID: session.id, prompt: "question")
        _ = try await service.runReadOnly(sessionID: session.id, prompt: "question")

        let recorded = try service.events(sessionID: session.id).filter { $0.kind == "usage.tokens" }
        XCTAssertEqual(recorded.count, 2)
        XCTAssertEqual(recorded.first?.tokenUsage, TokenUsage(inputTokens: 300, cachedInputTokens: 600, outputTokens: 40))
        let snapshot = try service.usageStatistics(provider: .codex, selectedSessionID: session.id)
        XCTAssertEqual(snapshot.dailyTokens, TokenUsage(inputTokens: 600, cachedInputTokens: 1_200, outputTokens: 80))
        XCTAssertEqual(snapshot.sessionTokens.totalTokens, 1_880)

        // Each run reports 940 tokens. Below the limit a run starts; once it is
        // reached the next one is refused before the CLI is launched.
        let profileID = AccountProfile.defaultID(for: .codex)
        var controls = try service.usageControlSettings(provider: .codex, profileID: profileID)
        controls.dailyTokenLimit = 1_880
        try service.saveUsageControlSettings(controls, provider: .codex, profileID: profileID)
        do {
            _ = try await service.runReadOnly(sessionID: session.id, prompt: "question")
            XCTFail("A run started after the token limit was reached.")
        } catch let error as UsageControlError {
            XCTAssertEqual(error, .tokenLimitReached(window: .rolling24Hours, used: 1_880, limit: 1_880))
        }
        XCTAssertEqual(try service.events(sessionID: session.id).filter { $0.kind == "usage.tokens" }.count, 2)

        controls.dailyTokenLimit = 1_881
        try service.saveUsageControlSettings(controls, provider: .codex, profileID: profileID)
        _ = try await service.runReadOnly(sessionID: session.id, prompt: "question")
        XCTAssertEqual(try service.usageStatistics(provider: .codex).dailyTokens.totalTokens, 2_820, "The run that crosses a limit still finishes.")
    }

    func testTokenLimitsAreValidatedAndOptional() throws {
        XCTAssertNoThrow(try UsageControlSettings().validate())
        XCTAssertNoThrow(try UsageControlSettings(fiveHourTokenLimit: 1_000, sessionTokenLimit: 10_000_000_000).validate())
        for limits in [UsageControlSettings(dailyTokenLimit: 999), UsageControlSettings(weeklyTokenLimit: 10_000_000_001), UsageControlSettings(sessionTokenLimit: 0)] {
            XCTAssertThrowsError(try limits.validate()) { XCTAssertEqual($0 as? UsageControlError, .invalidTokenLimit) }
        }
        let saved = try JSONDecoder().decode(UsageControlSettings.self, from: Data(#"{"disableFutureAPI":false,"macOSNotificationsEnabled":false,"notifiedThresholds":{},"subscriptionDailyRunLimit":5}"#.utf8))
        XCTAssertEqual(saved.subscriptionDailyRunLimit, 5)
        XCTAssertNil(saved.dailyTokenLimit, "Settings saved before token limits existed still load, with no token limit.")
    }
}
