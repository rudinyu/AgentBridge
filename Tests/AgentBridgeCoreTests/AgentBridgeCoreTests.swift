import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class AgentBridgeCoreTests: XCTestCase {
    func testProviderArgumentsAreSeparateAndResumeIDsAreValidated() throws {
        let workspace = "/tmp/AgentBridge workspace;$(touch /tmp/should-not-exist)"
        let codex = try ProviderCommandBuilder.codexRunArguments(workspacePath: workspace)
        XCTAssertEqual(codex[codex.firstIndex(of: "--cd")! + 1], workspace)
        XCTAssertTrue(codex.contains("read-only"))
        XCTAssertFalse(codex.contains("--ask-for-approval"))
        XCTAssertFalse(codex.contains("never"))
        XCTAssertTrue(codex.contains("--no-daemon"))
        XCTAssertFalse(codex.contains("--dangerously-bypass-approvals-and-sandbox"))

        let claude = try ProviderCommandBuilder.claudeReadOnlyArguments(workspacePath: workspace, sessionID: UUID())
        XCTAssertEqual(claude[claude.firstIndex(of: "--add-dir")! + 1], workspace)
        XCTAssertTrue(claude.contains("Read,Glob,Grep"))
        XCTAssertTrue(claude.contains("--strict-mcp-config"))
        XCTAssertTrue(claude.contains("--safe-mode"))
        XCTAssertFalse(claude.contains("--bare"))

        let contextDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-InteractiveArgs-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: contextDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: contextDirectory) }
        let contextFile = contextDirectory.appendingPathComponent("context.md")
        let contextText = "private memory line\nquote: \"hello\" path C:\\tmp\nprivate memory body"
        try Data(contextText.utf8).write(to: contextFile)
        XCTAssertEqual(chmod(contextFile.path, mode_t(0o600)), 0)

        let codexInteractive = try ProviderCommandBuilder.codexInteractiveArguments(
            workspacePath: workspace,
            contextFilePath: contextFile.path
        )
        XCTAssertTrue(codexInteractive.contains("--sandbox"))
        XCTAssertTrue(codexInteractive.contains("read-only"))
        XCTAssertEqual(codexInteractive[codexInteractive.firstIndex(of: "--ask-for-approval")! + 1], "on-request")
        XCTAssertFalse(codexInteractive.contains("--ignore-user-config"))
        let developerInstructions = try XCTUnwrap(codexInteractive.first(where: { $0.hasPrefix("developer_instructions=") }))
        XCTAssertEqual(
            developerInstructions,
            #"developer_instructions="private memory line\nquote: \"hello\" path C:\\tmp\nprivate memory body""#
        )
        XCTAssertEqual(codexInteractive[codexInteractive.firstIndex(of: developerInstructions)! - 1], "-c")
        XCTAssertFalse(codexInteractive.contains(contextText))
        XCTAssertFalse(codexInteractive.contains(contextFile.path))
        XCTAssertTrue(positionalArguments(in: codexInteractive, valueOptions: ["--disable", "--sandbox", "--ask-for-approval", "--cd", "-c"]).isEmpty)

        let claudeInteractiveWithMemory = try ProviderCommandBuilder.claudeInteractiveArguments(
            workspacePath: workspace,
            sessionID: UUID(),
            contextFilePath: contextFile.path
        )
        let appendFileIndex = try XCTUnwrap(claudeInteractiveWithMemory.firstIndex(of: "--append-system-prompt-file"))
        XCTAssertEqual(claudeInteractiveWithMemory[appendFileIndex + 1], contextFile.path)
        XCTAssertFalse(claudeInteractiveWithMemory.contains(contextText))
        XCTAssertFalse(claudeInteractiveWithMemory.contains("--bare"))
        XCTAssertFalse(claudeInteractiveWithMemory.contains("--system-prompt-file"))
        XCTAssertFalse(claudeInteractiveWithMemory.contains("--system-prompt"))
        XCTAssertTrue(positionalArguments(in: claudeInteractiveWithMemory, valueOptions: [
            "--setting-sources", "--mcp-config", "--settings", "--permission-mode", "--tools", "--add-dir", "--session-id", "--append-system-prompt-file"
        ]).isEmpty)

        let codexResumed = try ProviderCommandBuilder.codexInteractiveArguments(
            workspacePath: workspace,
            resumeID: "3b12f1df-5232-4804-897e-917bf397618a"
        )
        XCTAssertEqual(codexResumed[codexResumed.firstIndex(of: "resume")! + 1], "3b12f1df-5232-4804-897e-917bf397618a")

        XCTAssertThrowsError(try ProviderCommandBuilder.codexRunArguments(workspacePath: workspace, resumeID: "--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertThrowsError(try ProviderCommandBuilder.claudeReadOnlyArguments(workspacePath: workspace, sessionID: UUID(), resumeID: "--resume"))

        let interactiveID = UUID()
        let firstInteractive = try ProviderCommandBuilder.claudeInteractiveArguments(workspacePath: workspace, sessionID: interactiveID)
        XCTAssertFalse(firstInteractive.contains("--resume"))
        XCTAssertFalse(firstInteractive.contains("--append-system-prompt-file"))
        XCTAssertEqual(firstInteractive[firstInteractive.firstIndex(of: "--session-id")! + 1], interactiveID.uuidString.lowercased())
        let resumedInteractive = try ProviderCommandBuilder.claudeInteractiveArguments(workspacePath: workspace, sessionID: interactiveID, resumeID: "3b12f1df-5232-4804-897e-917bf397618a")
        XCTAssertEqual(resumedInteractive[resumedInteractive.firstIndex(of: "--resume")! + 1], "3b12f1df-5232-4804-897e-917bf397618a")

        let api = try ProviderCommandBuilder.claudeAPIArguments(workspacePath: workspace, budgetUSD: 1.25)
        XCTAssertTrue(api.contains("--max-budget-usd"))
        XCTAssertEqual(api[api.firstIndex(of: "--max-budget-usd")! + 1], "1.25")
        XCTAssertTrue(api.contains("--no-session-persistence"))
        XCTAssertFalse(api.contains("--bare"))
        XCTAssertFalse(api.contains("sk-ant-test-key"))
        XCTAssertThrowsError(try ProviderCommandBuilder.claudeAPIArguments(workspacePath: workspace, budgetUSD: 0))
        XCTAssertThrowsError(try ProviderCommandBuilder.claudeAPIArguments(workspacePath: workspace, budgetUSD: 1.001))
    }

    func testUsageTUIRefusesAPIAndCrossProviderLaunchesBeforeStartingAProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-UsageTUI-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AuditStore(rootURL: root)
        let service = try BridgeService(store: store)
        var settings = try service.settings()
        settings.defaultProvider = .claude
        settings.usageMode = .api
        try service.saveSettings(settings)

        do {
            _ = try await service.runUsageTUI(
                provider: .claude,
                profileID: AccountProfile.defaultID(for: .claude)
            )
            XCTFail("Claude API mode opened a subscription usage TUI.")
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else {
                return XCTFail("Unexpected error for API mode: \(error)")
            }
        }

        settings.defaultProvider = .codex
        settings.usageMode = .subscription
        try service.saveSettings(settings)
        do {
            _ = try await service.runUsageTUI(
                provider: .claude,
                profileID: AccountProfile.defaultID(for: .claude)
            )
            XCTFail("A non-selected provider opened a usage TUI.")
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else {
                return XCTFail("Unexpected error for cross-provider launch: \(error)")
            }
        }
    }

    func testUsageTUIArgumentsAreInteractiveReadOnlyAndKeepSlashCommandsEnabled() throws {
        let workingDirectory = "/tmp/AgentBridge usage;$(touch /tmp/should-not-exist)"
        let codex = try ProviderCommandBuilder.codexUsageArguments(workingDirectory: workingDirectory)
        XCTAssertEqual(codex[codex.firstIndex(of: "--cd")! + 1], workingDirectory)
        XCTAssertTrue(codex.contains("read-only"))
        XCTAssertEqual(codex[codex.firstIndex(of: "--ask-for-approval")! + 1], "never")
        XCTAssertTrue(codex.contains("--no-daemon"))
        XCTAssertFalse(codex.contains("exec"))
        XCTAssertFalse(codex.contains("--ignore-user-config"))
        XCTAssertTrue(positionalArguments(in: codex, valueOptions: [
            "--disable", "--sandbox", "--ask-for-approval", "--cd", "-c"
        ]).isEmpty)
        XCTAssertThrowsError(try ProviderCommandBuilder.codexUsageArguments(workingDirectory: "relative/path"))
        XCTAssertThrowsError(try ProviderCommandBuilder.codexUsageArguments(workingDirectory: "/tmp/bad\npath"))

        let claude = ProviderCommandBuilder.claudeUsageArguments()
        XCTAssertTrue(claude.contains("--restricted"))
        XCTAssertTrue(claude.contains("--safe-mode"))
        XCTAssertTrue(claude.contains("--no-session-persistence"))
        XCTAssertTrue(claude.contains("--permission-mode"))
        XCTAssertEqual(claude[claude.firstIndex(of: "--permission-mode")! + 1], "plan")
        XCTAssertEqual(claude[claude.firstIndex(of: "--tools")! + 1], "")
        XCTAssertTrue(claude.contains("--strict-mcp-config"))
        XCTAssertFalse(claude.contains("--disable-slash-commands"))
        XCTAssertFalse(claude.contains("--print"))
        XCTAssertFalse(claude.contains("-p"))
        XCTAssertFalse(claude.contains("--console"))
        XCTAssertTrue(claude.contains(where: { $0.contains("forceLoginMethod") && $0.contains("claudeai") }))
        XCTAssertTrue(positionalArguments(in: claude, valueOptions: [
            "--setting-sources", "--mcp-config", "--settings", "--permission-mode", "--tools"
        ]).isEmpty)
    }

    func testProviderUsageReportParserRecognizesCodexFixtureWindowsAndPlan() throws {
        let fixture = """
        ChatGPT plan: Plus
        5h limit: 42% used
        Resets in 2h 10m
        Weekly limit: 82% remaining
        Resets in 5d 4h
        Prompt completion: 99%
        """
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let capturedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let report = ProviderUsageReportParser.parse(
            screenText: fixture,
            provider: .codex,
            accountProfileID: profileID,
            accountName: "Personal Codex",
            capturedAt: capturedAt
        )

        XCTAssertEqual(report.provider, .codex)
        XCTAssertEqual(report.accountProfileID, profileID)
        XCTAssertEqual(report.accountName, "Personal Codex")
        XCTAssertEqual(report.plan, "Plus")
        XCTAssertEqual(report.capturedAt, capturedAt)
        XCTAssertEqual(report.source, "Codex CLI /usage screen")
        XCTAssertEqual(report.status, .recognizedFields)
        XCTAssertEqual(report.usageWindows.map(\.id), ["five-hour", "weekly"])
        XCTAssertEqual(report.usageWindows[0].percentageUsed, 42)
        XCTAssertEqual(report.usageWindows[0].resetText, "Resets in 2h 10m")
        XCTAssertEqual(report.usageWindows[1].percentageUsed, 18)
        XCTAssertEqual(report.usageWindows[1].resetText, "Resets in 5d 4h")
    }

    func testProviderUsageReportParserRecognizesClaudeFixtureWindowsAndIgnoresUnrelatedPercentages() throws {
        let fixture = """
        Claude Code usage
        Plan: Pro
        Current session
        ███████ 37% used
        Resets in 3h 40m
        Current week (all models)
        ████ 23% used
        Resets in 4d 2h
        Current week (Sonnet only)
        ██████ 63% used
        Resets in 4d 2h
        Cache hit rate: 91%
        """
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        let report = ProviderUsageReportParser.parse(
            screenText: fixture,
            provider: .claude,
            accountProfileID: profileID,
            accountName: "Work Claude"
        )

        XCTAssertEqual(report.provider, .claude)
        XCTAssertEqual(report.accountProfileID, profileID)
        XCTAssertEqual(report.accountName, "Work Claude")
        XCTAssertEqual(report.plan, "Pro")
        XCTAssertEqual(report.source, "Claude Code /usage screen")
        XCTAssertEqual(report.status, .recognizedFields)
        XCTAssertEqual(report.usageWindows.map(\.id), [
            "current-session", "current-week-all-models", "current-week-sonnet"
        ])
        XCTAssertEqual(report.usageWindows[0].percentageUsed, 37)
        XCTAssertEqual(report.usageWindows[0].resetText, "Resets in 3h 40m")
        XCTAssertEqual(report.usageWindows[1].percentageUsed, 23)
        XCTAssertEqual(report.usageWindows[1].resetText, "Resets in 4d 2h")
        XCTAssertEqual(report.usageWindows[2].percentageUsed, 63)
        XCTAssertEqual(report.usageWindows[2].resetText, "Resets in 4d 2h")
    }

    func testProviderUsageReportParserDoesNotTreatArbitraryPercentagesAsQuota() throws {
        let report = ProviderUsageReportParser.parse(
            screenText: """
            Cache hit rate: 91%
            Build complete: 100%
            Last 5h of tasks used 42%
            15h limit: 88% used
            Current week (all models): 63% used
            """,
            provider: .codex,
            accountProfileID: UUID(),
            accountName: "Codex"
        )

        XCTAssertNil(report.plan)
        XCTAssertTrue(report.usageWindows.isEmpty)
        XCTAssertEqual(report.status, .noRecognizedFields)
    }

    func testEnvironmentWhitelistExcludesInheritedSecretsUnlessExplicitAPIRun() throws {
        let base = [
            "HOME": "/Users/tester",
            "USER": "tester",
            "PATH": "/untrusted/path",
            "LANG": "zh_TW.UTF-8",
            "TERM": "xterm-256color",
            "CODEX_HOME": "/Users/tester/.codex",
            "OPENAI_API_KEY": "should-not-pass",
            "ANTHROPIC_API_KEY": "also-should-not-pass",
            "ANTHROPIC_AUTH_TOKEN": "also-not-passed",
            "CLAUDE_CODE_OAUTH_TOKEN": "not-passed",
            "CODEX_API_KEY": "not-passed",
            "CLAUDECODE": "nested",
            "AWS_SECRET_ACCESS_KEY": "not-passed",
            "HTTP_PROXY": "http://example.invalid"
        ]
        let temp = URL(fileURLWithPath: "/tmp/agentbridge-private-temp", isDirectory: true)
        let codex = RuntimeEnvironment.sanitized(base: base, provider: .codex, privateTemporaryDirectory: temp)
        XCTAssertEqual(codex["CODEX_HOME"], "/Users/tester/.codex")
        XCTAssertEqual(codex["TERM"], "dumb")
        XCTAssertEqual(codex["TMPDIR"], temp.path)
        XCTAssertNil(codex["OPENAI_API_KEY"])
        XCTAssertNil(codex["ANTHROPIC_API_KEY"])
        XCTAssertNil(codex["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(codex["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(codex["CODEX_API_KEY"])
        XCTAssertNil(codex["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(codex["AWS_SECRET_ACCESS_KEY"])
        XCTAssertNil(codex["HTTP_PROXY"])
        XCTAssertFalse(codex["PATH"]?.contains("/untrusted/path") ?? true)

        let subscriptionClaude = RuntimeEnvironment.sanitized(base: base, provider: .claude, privateTemporaryDirectory: temp)
        XCTAssertNil(subscriptionClaude["ANTHROPIC_API_KEY"])
        XCTAssertNil(subscriptionClaude["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(subscriptionClaude["CLAUDE_CODE_OAUTH_TOKEN"])
        XCTAssertNil(subscriptionClaude["CODEX_API_KEY"])
        XCTAssertNil(subscriptionClaude["CODEX_HOME"])
        let apiClaude = RuntimeEnvironment.sanitized(base: base, provider: .claude, privateTemporaryDirectory: temp, apiKey: "explicit-api-key")
        XCTAssertEqual(apiClaude["ANTHROPIC_API_KEY"], "explicit-api-key")
        let codexWithExplicitKey = RuntimeEnvironment.sanitized(base: base, provider: .codex, privateTemporaryDirectory: temp, apiKey: "explicit-api-key")
        XCTAssertNil(codexWithExplicitKey["ANTHROPIC_API_KEY"])

        var claudeBase = base
        claudeBase["CLAUDE_CONFIG_DIR"] = "/Users/tester/.claude"
        let existingClaude = RuntimeEnvironment.sanitized(base: claudeBase, provider: .claude, privateTemporaryDirectory: temp)
        XCTAssertEqual(existingClaude["CLAUDE_CONFIG_DIR"], "/Users/tester/.claude")
    }

    func testSubscriptionAuthenticationClassifierFailsClosed() {
        let empty = Data()
        let codexSubscription = AuthStatusClassifier.codex(stdout: empty, stderr: Data("Logged in using ChatGPT".utf8), exitCode: 0)
        XCTAssertTrue(codexSubscription.confirmedSubscription)
        XCTAssertFalse(AuthStatusClassifier.codex(stdout: Data("Logged in using an API key".utf8), stderr: empty, exitCode: 0).confirmedSubscription)
        XCTAssertFalse(AuthStatusClassifier.codex(stdout: empty, stderr: Data("authentication status unknown".utf8), exitCode: 0).confirmedSubscription)
        XCTAssertFalse(AuthStatusClassifier.codex(stdout: Data("Logged in using ChatGPT".utf8), stderr: empty, exitCode: 1).confirmedSubscription)

        let claudeSubscription = Data(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}"#.utf8)
        let claudeAssessment = AuthStatusClassifier.claude(
            stdout: Data(#"{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"member@example.invalid"}"#.utf8),
            stderr: empty,
            exitCode: 0
        )
        XCTAssertTrue(claudeAssessment.confirmedSubscription)
        XCTAssertEqual(claudeAssessment.accountLabel, "member@example.invalid")
        XCTAssertEqual(claudeAssessment.planName, "max")
        XCTAssertNil(AuthStatusClassifier.codex(stdout: empty, stderr: Data("Logged in using ChatGPT".utf8), exitCode: 0).planName)
        let claudeAPIKey = Data(#"{"loggedIn":true,"authMethod":"api_key","subscriptionType":""}"#.utf8)
        XCTAssertFalse(AuthStatusClassifier.claude(stdout: claudeAPIKey, stderr: empty, exitCode: 0).confirmedSubscription)
        XCTAssertFalse(AuthStatusClassifier.claude(stdout: Data("{}".utf8), stderr: empty, exitCode: 0).confirmedSubscription)
        XCTAssertFalse(AuthStatusClassifier.claude(stdout: claudeSubscription, stderr: empty, exitCode: 1).confirmedSubscription)
    }

    func testProviderSemanticErrorsCannotPassAsSuccessfulExit() throws {
        let codex = [
            #"{"type":"thread.started","thread_id":"3b12f1df-5232-4804-897e-917bf397618a"}"#,
            #"{"type":"item.completed","item":{"type":"agent_message","text":"Done"}}"#,
            #"{"type":"turn.completed"}"#
        ].joined(separator: "\n")
        let codexResult = try ProviderOutputParser.parse(provider: .codex, data: Data(codex.utf8))
        XCTAssertEqual(codexResult.text, "Done")
        XCTAssertEqual(codexResult.providerSessionID, "3b12f1df-5232-4804-897e-917bf397618a")

        let codexFailure = Data(#"{"type":"turn.failed","error":{"message":"private details"}}"#.utf8)
        XCTAssertThrowsError(try ProviderOutputParser.parse(provider: .codex, data: codexFailure))

        let claudeSuccess = Data(([
            #"{"type":"system","subtype":"init","session_id":"3b12f1df-5232-4804-897e-917bf397618a"}"#,
            #"{"type":"result","subtype":"success","result":"Ready","total_cost_usd":0.125}"#
        ].joined(separator: "\n")).utf8)
        let claudeResult = try ProviderOutputParser.parse(provider: .claude, data: claudeSuccess)
        XCTAssertEqual(claudeResult.text, "Ready")
        XCTAssertEqual(claudeResult.actualCostUSD, 0.125)

        XCTAssertThrowsError(try ProviderOutputParser.parse(provider: .claude, data: Data(#"{"type":"result","subtype":"success","is_error":true,"result":"Looks fine"}"#.utf8)))
        XCTAssertThrowsError(try ProviderOutputParser.parse(provider: .claude, data: Data(#"{"type":"result","subtype":"error_max_budget_usd","result":"Budget reached"}"#.utf8)))
        XCTAssertThrowsError(try ProviderOutputParser.parse(provider: .claude, data: Data(#"{"type":"result","subtype":"success","result":"bad cost","total_cost_usd":true}"#.utf8)))
        XCTAssertThrowsError(try ProviderOutputParser.parse(provider: .claude, data: Data((#"{"type":"result","subtype":"success","result":"Done"}"# + "\n" + #"{"type":"error"}"#).utf8)))
        XCTAssertThrowsError(try ProviderOutputParser.parse(provider: .codex, data: Data(#"{"type":"turn.completed"}"#.utf8)))
    }

    func testSplitSecretFragmentsAreRedactedOnlyAfterCompleteOutput() throws {
        let secret = "sk-ant-api03-super-secret-token-that-crosses-events"
        let first = String(secret.prefix(13))
        let rest = String(secret.dropFirst(13))
        let events = [
            ["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": first]]],
            ["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": rest]]],
            ["type": "result", "subtype": "success"]
        ]
        let data = try events.map { try JSONSerialization.data(withJSONObject: $0) + Data([0x0A]) }.reduce(into: Data()) { $0.append($1) }
        let output = try ProviderOutputParser.parse(provider: .claude, data: data)
        XCTAssertFalse(output.text.contains(secret))
        XCTAssertTrue(output.text.contains("<redacted>"))

        let arbitrarySecret = "private-token-not-covered-by-generic-patterns"
        let knownSecretRedaction = OutputRedactor.redact("provider echoed \(arbitrarySecret)", knownSecrets: [arbitrarySecret])
        XCTAssertFalse(knownSecretRedaction.contains(arbitrarySecret))
        XCTAssertTrue(knownSecretRedaction.contains("<redacted>"))
    }

    func testAuditStoreUsesPrivatePermissionsAndCrossInstanceLocking() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dataRoot = root.appendingPathComponent("state", isDirectory: true)
        let first = try AuditStore(rootURL: dataRoot)
        let second = try AuditStore(rootURL: dataRoot)
        let sessionID = UUID()
        let errors = LockedValues<String>()
        DispatchQueue.concurrentPerform(iterations: 48) { index in
            do {
                let store = index.isMultiple(of: 2) ? first : second
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "fixture", message: "event-\(index)"))
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        XCTAssertTrue(errors.values.isEmpty, errors.values.joined(separator: ", "))
        XCTAssertEqual(try first.events(sessionID: sessionID).count, 48)

        let settingsPath = dataRoot.appendingPathComponent("sessions.jsonl").path
        let eventsPath = dataRoot.appendingPathComponent("events").path
        XCTAssertEqual(fileMode(atPath: settingsPath), 0o600)
        XCTAssertEqual(fileMode(atPath: eventsPath), 0o700)

        XCTAssertThrowsError(try first.appendEvent(AuditEvent(sessionID: sessionID, kind: "oversized", message: String(repeating: "x", count: 10 * 1_024 * 1_024))))
    }

    func testAuditStoreRejectsSymlinkRootWithoutChangingTargetPermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(target.path, mode_t(0o755)), 0)
        let link = root.appendingPathComponent("state-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try AuditStore(rootURL: link))
        XCTAssertEqual(fileMode(atPath: target.path), 0o755)
    }

    func testConcurrentStoreInitializationDoesNotTruncateSessionIndex() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state", isDirectory: true)
        let initial = try AuditStore(rootURL: state)
        let session = SessionRecord(provider: .claude, sourceRepositoryPath: "/tmp/source", workspacePath: "/tmp/workspace", snapshotCommit: String(repeating: "a", count: 40), sourceWasDirty: false)
        try initial.saveSession(session)
        let before = try Data(contentsOf: state.appendingPathComponent("sessions.jsonl"))
        let failures = LockedValues<String>()
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            do { _ = try AuditStore(rootURL: state) }
            catch { failures.append(error.localizedDescription) }
        }
        XCTAssertTrue(failures.values.isEmpty, failures.values.joined(separator: ", "))
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("sessions.jsonl")), before)
        XCTAssertEqual(try AuditStore(rootURL: state).loadSessions().map(\.id), [session.id])
    }

    func testRunLeasePreventsConcurrentResumeOfSameSession() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AuditStore(rootURL: root.appendingPathComponent("state", isDirectory: true))
        let sessionID = UUID()
        var lease: SessionRunLease? = try store.acquireRunLease(for: sessionID)
        XCTAssertNotNil(lease)
        XCTAssertThrowsError(try store.acquireRunLease(for: sessionID))
        lease = nil
        XCTAssertNotNil(try store.acquireRunLease(for: sessionID))
    }

    func testProcessRunnerFramesUTF8LineAcrossPipeChunks() async throws {
        let runner = SafeProcessRunner()
        let prefix = #"{"type":"thread.started","text":""#
        let fillerCount = max(1, 16_383 - prefix.utf8.count)
        let jsonLine = prefix + String(repeating: "a", count: fillerCount) + "🙂" + "\"}\n"
        let captured = LockedValues<String>()
        let handler: @Sendable (String) -> Void = { captured.append($0) }
        let spec = ProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            environment: ["PATH": "/bin:/usr/bin", "TMPDIR": "/tmp"],
            standardInput: Data(jsonLine.utf8),
            timeout: 5,
            outputLimit: 256_000,
            standardOutputLineHandler: handler
        )
        let result = try await runner.run(spec)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(String(data: result.standardOutput, encoding: .utf8), jsonLine)
        XCTAssertEqual(captured.values, [String(jsonLine.dropLast())])
    }

    func testProcessRunnerTimeoutAndCancellation() async throws {
        let runner = SafeProcessRunner()
        let timeout = ProcessSpec(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: ["PATH": "/bin:/usr/bin"], timeout: 0.15, outputLimit: 10_000)
        let timeoutResult = try await runner.run(timeout)
        XCTAssertTrue(timeoutResult.timedOut)
        XCTAssertTrue(timeoutResult.wasCancelled)

        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let request = root.appendingPathComponent("cancel.request")
        let spec = ProcessSpec(executableURL: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], environment: ["PATH": "/bin:/usr/bin"], timeout: 5, outputLimit: 10_000, cancellationRequestURL: request)
        let task = Task { try await runner.run(spec) }
        try await Task.sleep(nanoseconds: 150_000_000)
        try Data("cancel".utf8).write(to: request)
        let cancelled = try await task.value
        XCTAssertTrue(cancelled.wasCancelled)
        XCTAssertFalse(cancelled.timedOut)
    }

    func testProcessRunnerBoundsFloodingOutputAndStillTimesOut() async throws {
        let spec = ProcessSpec(executableURL: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], environment: ["PATH": "/usr/bin:/bin"], timeout: 0.15, outputLimit: 4_096)
        let result = try await SafeProcessRunner().run(spec)
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.outputWasTruncated)
        XCTAssertLessThanOrEqual(result.standardOutput.count, 4_096)
    }

    func testCancellationTerminatesDescendantProcessGroup() async throws {
        let runner = SafeProcessRunner()
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "process-tree", withExtension: "sh"))
        XCTAssertEqual(chmod(fixture.path, mode_t(0o700)), 0)
        let marker = root.appendingPathComponent("term-seen")
        let cancellation = CancellationFlag()
        let handler: @Sendable (String) -> Void = { _ in cancellation.cancel() }
        let spec = ProcessSpec(
            executableURL: fixture,
            arguments: [],
            environment: ["PATH": "/bin:/usr/bin", "TMPDIR": root.path, "MARKER_PATH": marker.path],
            workingDirectoryURL: root,
            timeout: 5,
            outputLimit: 10_000,
            standardOutputLineHandler: handler
        )
        let result = try await runner.run(spec, cancellation: cancellation)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "The process group termination signal did not reach the descendant fixture.")
    }

    func testCancellationEscalatesForDescendantsThatIgnoreTERMAndClosePipes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "process-tree-ignore-term", withExtension: "sh"))
        XCTAssertEqual(chmod(fixture.path, mode_t(0o700)), 0)
        let childPID = LockedValues<pid_t>()
        let cancellation = CancellationFlag()
        let handler: @Sendable (String) -> Void = { line in
            if let pid = pid_t(line.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID.append(pid)
                cancellation.cancel()
            }
        }
        let result = try await SafeProcessRunner().run(ProcessSpec(
            executableURL: fixture,
            arguments: [],
            environment: ["PATH": "/bin:/usr/bin", "TMPDIR": root.path],
            workingDirectoryURL: root,
            timeout: 5,
            outputLimit: 1_000,
            standardOutputLineHandler: handler
        ), cancellation: cancellation)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertEqual(childPID.values.count, 1)
        let pid = try XCTUnwrap(childPID.values.first)
        let deadline = Date().addingTimeInterval(2)
        var remains = kill(pid, 0) == 0
        while remains, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            remains = kill(pid, 0) == 0
        }
        XCTAssertFalse(remains, "The TERM-ignoring descendant survived process-group escalation.")
    }

    func testInteractiveLauncherQuotesUntrustedExecutablePath() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("expanded")
        let executable = root.appendingPathComponent("Agent's $(touch expanded)\nCLI")
        let capture = root.appendingPathComponent("captured-args")
        let helper = "#!/bin/sh\nprintf '%s\\n' \"$1\" \"$2\" > \"$CAPTURE_PATH\"\n"
        try Data(helper.utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, mode_t(0o700)), 0)
        let sessionID = UUID()
        let command = try InteractiveTerminalCommand.script(executablePath: executable.path, sessionID: sessionID)
        let launcher = root.appendingPathComponent("launcher.command")
        try Data(command.utf8).write(to: launcher)
        XCTAssertEqual(chmod(launcher.path, mode_t(0o700)), 0)

        let result = try await SafeProcessRunner().run(ProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [launcher.path],
            environment: ["PATH": "/bin:/usr/bin", "TMPDIR": root.path, "CAPTURE_PATH": capture.path],
            workingDirectoryURL: root,
            timeout: 5,
            outputLimit: 10_000
        ))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "The shell metacharacter in the executable path was interpreted.")
        XCTAssertEqual(try String(contentsOf: capture, encoding: .utf8), "interactive\n\(sessionID.uuidString.lowercased())\n")
        XCTAssertEqual(InteractiveTerminalCommand.shellQuote("a'b"), "'a'\\''b'")
    }

    func testSnapshotUsesCommittedSourceWithoutChangingRepository() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try runGit(["init", "-q", source.path])
        try runGit(["-C", source.path, "config", "user.name", "AgentBridge Test"])
        try runGit(["-C", source.path, "config", "user.email", "agentbridge@example.invalid"])
        try Data("committed\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        try runGit(["-C", source.path, "add", "tracked.txt"])
        try runGit(["-C", source.path, "commit", "-q", "-m", "snapshot"])

        let fsmonitor = root.appendingPathComponent("fsmonitor-fixture")
        let marker = root.appendingPathComponent("fsmonitor-ran")
        try Data("#!/bin/sh\nprintf called > '\(marker.path)'\n".utf8).write(to: fsmonitor)
        XCTAssertEqual(chmod(fsmonitor.path, mode_t(0o700)), 0)
        try runGit(["-C", source.path, "config", "core.fsmonitor", fsmonitor.path])
        try Data("local-only\n".utf8).write(to: source.appendingPathComponent("uncommitted.txt"))
        let configBefore = try Data(contentsOf: source.appendingPathComponent(".git/config"))
        let statusBefore = try runGit(["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", source.path, "status", "--porcelain=v1", "--untracked-files=normal"])

        let store = try AuditStore(rootURL: root.appendingPathComponent("state", isDirectory: true))
        let manager = WorkspaceManager(store: store)
        let session = try await manager.createSnapshot(sourcePath: source.path, provider: .codex)
        try await manager.validateWorkspace(for: session, accessMode: .readOnly)

        let configAfter = try Data(contentsOf: source.appendingPathComponent(".git/config"))
        let statusAfter = try runGit(["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-C", source.path, "status", "--porcelain=v1", "--untracked-files=normal"])
        XCTAssertEqual(configAfter, configBefore)
        XCTAssertEqual(statusAfter, statusBefore)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "The source repository's fsmonitor command ran.")
        XCTAssertTrue(session.sourceWasDirty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: session.workspacePath).appendingPathComponent("uncommitted.txt").path))
        XCTAssertEqual(try runGit(["-C", session.workspacePath, "remote"]), "")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: session.workspacePath).appendingPathComponent("tracked.txt"), encoding: .utf8), "committed\n")

        do {
            try await manager.validateWorkspace(for: session, accessMode: .interactiveManualApproval)
            XCTFail("A read-only session accepted the interactive policy.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("權限"))
        }
    }

    func testBridgeServiceKeepsReadOnlyRunsStatelessAndRoutesExplicitAPIKeyThroughMockCLI() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeGitRepository(at: source)
        let mockDirectory = root.appendingPathComponent("mock-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: mockDirectory, withIntermediateDirectories: true)
        let mockClaude = mockDirectory.appendingPathComponent("claude")
        let providerSessionID = "3b12f1df-5232-4804-897e-917bf397618a"
        let mock = #"""
#!/bin/sh
arguments=" $* "
case "$arguments" in
  *"auth status --json"*)
    case "$arguments" in
      *"--restricted"*"--safe-mode"*"apiKeyHelper"*) ;;
      *) printf '%s\n' '{"loggedIn":true,"authMethod":"unknown","subscriptionType":""}'; exit 0 ;;
    esac
    case "$(pwd)" in
      */tmp/auth-*) printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max"}' ;;
      *) printf '%s\n' '{"loggedIn":true,"authMethod":"unknown","subscriptionType":""}' ;;
    esac
    exit 0
    ;;
esac
case "$arguments" in
  *"subscription-first-prompt"*|*"subscription-second-prompt"*|*"api-prompt-marker"*|*"fixture-api-key"*)
    printf '%s\n' '{"type":"result","subtype":"error_args","result":"Prompt or key appeared in arguments"}'
    exit 0
    ;;
esac
prompt=$(/bin/cat)
case "$prompt" in
  *subscription-first-prompt*|*subscription-second-prompt*|*api-prompt-marker*) ;;
  *) printf '%s\n' '{"type":"result","subtype":"error_prompt","result":"Prompt was not sent on stdin"}'; exit 0 ;;
esac
case "$arguments" in
  *"--max-budget-usd 0.25"*)
    printf '%s\n' 'api-call' >> .api-call-count
    if [ "${ANTHROPIC_API_KEY:-}" = "fixture-api-key" ]; then
      printf '{"type":"result","subtype":"success","result":"echo:%s","total_cost_usd":0.02}\n' "$ANTHROPIC_API_KEY"
    else
      printf '%s\n' '{"type":"result","subtype":"error_auth","result":"API key was not passed for the explicit API run"}'
    fi
    ;;
  *)
    if [ "${ANTHROPIC_API_KEY+x}" = "x" ]; then
      response="inherited-api-key-leaked"
    else
      case "$arguments" in
        *"--resume \#(providerSessionID)"*) response="subscription-resumed" ;;
        *) response="subscription-safe" ;;
      esac
    fi
    printf '{"type":"system","subtype":"init","session_id":"\#(providerSessionID)"}\n'
    printf '{"type":"result","subtype":"success","result":"%s"}\n' "$response"
    ;;
esac
"""#
        try Data(mock.utf8).write(to: mockClaude)
        XCTAssertEqual(chmod(mockClaude.path, mode_t(0o700)), 0)

        let store = try AuditStore(rootURL: root.appendingPathComponent("state", isDirectory: true))
        let service = try BridgeService(
            store: store,
            baseEnvironment: [
                "HOME": root.path,
                "USER": "agentbridge-test",
                "PATH": "/untrusted/path",
                "ANTHROPIC_API_KEY": "inherited-secret-must-not-pass"
            ]
        )
        var settings = try service.settings()
        settings.claudeBinaryPath = mockClaude.path
        settings.usageMode = .subscription
        try service.saveSettings(settings)

        let subscriptionSession = try await service.createSession(sourcePath: source.path, provider: .claude)
        let firstSubscription = try await service.runReadOnly(sessionID: subscriptionSession.id, prompt: "subscription-first-prompt")
        XCTAssertEqual(firstSubscription.text, "subscription-safe")
        XCTAssertNil(try store.session(id: subscriptionSession.id)?.providerSessionID)
        let secondSubscription = try await service.runReadOnly(sessionID: subscriptionSession.id, prompt: "subscription-second-prompt")
        XCTAssertEqual(secondSubscription.text, "subscription-safe", "Managed read-only runs rebuild context from AgentBridge memory and never resume opaque CLI history.")
        XCTAssertNil(try store.session(id: subscriptionSession.id)?.providerSessionID)

        settings.usageMode = .api
        try service.saveSettings(settings)
        let apiSession = try await service.createSession(sourcePath: source.path, provider: .claude)
        do {
            _ = try await service.runReadOnly(sessionID: apiSession.id, prompt: "api-prompt-marker")
            XCTFail("API mode ran without an explicit single-run authorization.")
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { return XCTFail("Unexpected refusal: \(error)") }
        }

        let budgetBeforeInvalidRequest = try service.budgetSnapshot()
        do {
            _ = try await service.runReadOnly(
                sessionID: apiSession.id,
                prompt: "api-prompt-marker",
                apiRequest: APIUsageRequest(requestedBudgetUSD: 0.011, explicitlyAuthorized: true, apiKey: "fixture-api-key")
            )
            XCTFail("A budget with fractional cents was accepted.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else { return XCTFail("Unexpected invalid-budget error: \(error)") }
        }
        let budgetAfterInvalidRequest = try service.budgetSnapshot()
        XCTAssertEqual(budgetAfterInvalidRequest.usedUSD, budgetBeforeInvalidRequest.usedUSD, accuracy: 0.000_001)
        XCTAssertEqual(budgetAfterInvalidRequest.reservedUSD, budgetBeforeInvalidRequest.reservedUSD, accuracy: 0.000_001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: apiSession.workspacePath).appendingPathComponent(".api-call-count").path))

        let apiOutput = try await service.runReadOnly(
            sessionID: apiSession.id,
            prompt: "api-prompt-marker",
            apiRequest: APIUsageRequest(requestedBudgetUSD: 0.25, explicitlyAuthorized: true, apiKey: "fixture-api-key")
        )
        XCTAssertEqual(apiOutput.text, "echo:<redacted>")
        XCTAssertNil(try store.session(id: apiSession.id)?.providerSessionID)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: apiSession.workspacePath).appendingPathComponent(".api-call-count"), encoding: .utf8), "api-call\n")

        do {
            _ = try await service.runReadOnly(
                sessionID: apiSession.id,
                prompt: "api-prompt-marker",
                apiRequest: APIUsageRequest(requestedBudgetUSD: 0.25, explicitlyAuthorized: true, apiKey: "fixture-api-key")
            )
            XCTFail("A session accepted a second API reservation.")
        } catch let error as BudgetLedgerError {
            XCTAssertEqual(error, .duplicateSession(apiSession.id))
        }
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: apiSession.workspacePath).appendingPathComponent(".api-call-count"), encoding: .utf8), "api-call\n")

        let events = try store.events(sessionID: apiSession.id)
        let storedText = events.map(\.message).joined(separator: "\n")
        XCTAssertFalse(storedText.contains("fixture-api-key"))
        XCTAssertFalse(storedText.contains("api-prompt-marker"))
        XCTAssertFalse(storedText.contains("inherited-secret-must-not-pass"))
        let settingsContents = try String(contentsOf: root.appendingPathComponent("state/settings.json"), encoding: .utf8)
        let budgetContents = try String(contentsOf: root.appendingPathComponent(
            "state/api-spend/\(AccountProfile.defaultID(for: .claude).uuidString.lowercased())/api-spend-ledger.json"
        ), encoding: .utf8)
        XCTAssertFalse(settingsContents.contains("fixture-api-key"))
        XCTAssertFalse(budgetContents.contains("fixture-api-key"))
        let budget = try service.budgetSnapshot()
        XCTAssertEqual(budget.usedUSD, 0.02, accuracy: 0.000_001)
        XCTAssertEqual(budget.reservedUSD, 0, accuracy: 0.000_001)
        let memory = try service.sharedMemory(sessionID: apiSession.id)
        XCTAssertTrue(memory.turns.contains(where: { $0.userText.contains("api-prompt-marker") }))
        XCTAssertFalse(memory.turns.map { $0.userText + $0.assistantText }.joined().contains("fixture-api-key"))
    }

    func testSharedMemoryFlowsAcrossProvidersWhenRetargetingAnOlderSnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeGitRepository(at: source)
        let binaries = root.appendingPathComponent("mock-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)

        let mockCodex = binaries.appendingPathComponent("codex")
        let codexScript = #"""
#!/bin/sh
arguments=" $* "
case "$arguments" in
  *"login status"*) printf '%s\n' 'Logged in using ChatGPT'; exit 0 ;;
esac
prompt=$(/bin/cat)
case "$prompt" in
  *"codex-sees-claude-answer"*)
    case "$prompt" in
      *"claude-answer-cross-provider"*) response="codex-final-answer" ;;
      *) printf '%s\n' '{"type":"turn.failed"}'; exit 0 ;;
    esac
    ;;
  *"codex-seed-from-codex"*) response="codex-answer-from-codex" ;;
  *) printf '%s\n' '{"type":"turn.failed"}'; exit 0 ;;
esac
printf '%s\n' '{"type":"thread.started","thread_id":"3b12f1df-5232-4804-897e-917bf397618a"}'
printf '{"type":"item.completed","item":{"type":"agent_message","text":"%s"}}\n' "$response"
printf '%s\n' '{"type":"turn.completed"}'
"""#
        try Data(codexScript.utf8).write(to: mockCodex)
        XCTAssertEqual(chmod(mockCodex.path, mode_t(0o700)), 0)

        let mockClaude = binaries.appendingPathComponent("claude")
        let claudeScript = #"""
#!/bin/sh
arguments=" $* "
case "$arguments" in
  *"auth status --json"*) printf '%s\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"pro","email":"claude-fixture@example.invalid"}'; exit 0 ;;
esac
prompt=$(/bin/cat)
case "$prompt" in
  *"claude-sees-codex-answer"*)
    case "$prompt" in
      *"codex-seed-from-codex"*) ;;
      *) printf '%s\n' '{"type":"result","subtype":"error_memory"}'; exit 0 ;;
    esac
    case "$prompt" in
      *"codex-answer-from-codex"*) response="claude-answer-cross-provider" ;;
      *) printf '%s\n' '{"type":"result","subtype":"error_memory"}'; exit 0 ;;
    esac
    ;;
  *) printf '%s\n' '{"type":"result","subtype":"error_prompt"}'; exit 0 ;;
esac
printf '%s\n' '{"type":"system","subtype":"init","session_id":"3b12f1df-5232-4804-897e-917bf397618a"}'
printf '{"type":"result","subtype":"success","result":"%s"}\n' "$response"
"""#
        try Data(claudeScript.utf8).write(to: mockClaude)
        XCTAssertEqual(chmod(mockClaude.path, mode_t(0o700)), 0)

        let store = try AuditStore(rootURL: root.appendingPathComponent("state", isDirectory: true))
        let service = try BridgeService(store: store, baseEnvironment: ["HOME": root.path, "USER": "fixture"])
        var settings = try service.settings()
        settings.codexBinaryPath = mockCodex.path
        settings.claudeBinaryPath = mockClaude.path
        settings.usageMode = .subscription
        try service.saveSettings(settings)

        let codexFirstSession = try await service.createSession(sourcePath: source.path, provider: .codex)
        XCTAssertEqual(codexFirstSession.accountProfileID, AccountProfile.defaultID(for: .codex))
        let codexFirst = try await service.runReadOnly(sessionID: codexFirstSession.id, prompt: "codex-seed-from-codex")
        XCTAssertEqual(codexFirst.text, "codex-answer-from-codex")

        try Data("advanced source head\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        try runGit(["-C", source.path, "add", "tracked.txt"])
        try runGit(["-C", source.path, "commit", "-q", "-m", "advance source after first session"])
        let advancedHead = try runGit(["-C", source.path, "rev-parse", "HEAD"])
        XCTAssertNotEqual(advancedHead, codexFirstSession.snapshotCommit)

        let claudeSession = try await service.createSession(
            sourcePath: source.path,
            provider: .claude,
            snapshotCommit: codexFirstSession.snapshotCommit
        )
        XCTAssertEqual(claudeSession.snapshotCommit, codexFirstSession.snapshotCommit)
        let claudeOutput = try await service.runReadOnly(sessionID: claudeSession.id, prompt: "claude-sees-codex-answer")
        XCTAssertEqual(claudeOutput.text, "claude-answer-cross-provider")

        let codexSecondSession = try await service.createSession(
            sourcePath: source.path,
            provider: .codex,
            snapshotCommit: claudeSession.snapshotCommit
        )
        XCTAssertEqual(codexSecondSession.snapshotCommit, claudeSession.snapshotCommit)
        let codexSecond = try await service.runReadOnly(sessionID: codexSecondSession.id, prompt: "codex-sees-claude-answer")
        XCTAssertEqual(codexSecond.text, "codex-final-answer")

        let snapshot = try service.sharedMemory(sessionID: codexSecondSession.id)
        XCTAssertEqual(snapshot.turns.map(\.provider), [.codex, .claude, .codex])
        XCTAssertEqual(snapshot.turns.count, 3)
        XCTAssertTrue(snapshot.turns[0].userText.contains("codex-seed-from-codex"))
        XCTAssertTrue(snapshot.turns[1].assistantText.contains("claude-answer-cross-provider"))
    }

    func testSessionIsPinnedToAccountProfileAndCannotResumeAfterSwitch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeGitRepository(at: source)
        let store = try AuditStore(rootURL: root.appendingPathComponent("state", isDirectory: true))
        let service = try BridgeService(store: store, baseEnvironment: ["HOME": root.path, "USER": "fixture"])

        let session = try await service.createSession(sourcePath: source.path, provider: .codex)
        XCTAssertEqual(session.accountProfileID, AccountProfile.defaultID(for: .codex))
        let alternate = try service.createAccountProfile(name: "Separate Codex", provider: .codex)
        XCTAssertTrue(alternate.allowsSharedMemory)
        try service.selectAccountProfile(id: alternate.id, provider: .codex)

        do {
            _ = try await service.runReadOnly(sessionID: session.id, prompt: "must-not-run-under-another-account")
            XCTFail("A session was resumed under a different selected account profile.")
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { return XCTFail("Unexpected profile-switch error: \(error)") }
        }
        XCTAssertFalse(try store.events(sessionID: session.id).contains(where: { $0.kind == "run.started" }))
    }

    func testSessionRecordDecodesOlderFilesWithoutAccountProfileID() throws {
        let session = SessionRecord(
            provider: .claude,
            sourceRepositoryPath: "/tmp/source",
            workspacePath: "/tmp/workspace",
            snapshotCommit: String(repeating: "a", count: 40),
            sourceWasDirty: false
        )
        let encoded = try JSONEncoder().encode(session)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "accountProfileID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SessionRecord.self, from: legacyData)
        XCTAssertNil(decoded.accountProfileID)
        XCTAssertEqual(decoded.id, session.id)
    }

    private func positionalArguments(in arguments: [String], valueOptions: Set<String>) -> [String] {
        var positional: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else {
                    positional.append("<missing value for \(argument)>")
                    break
                }
                index += 2
            } else if argument.hasPrefix("-") {
                index += 1
            } else {
                positional.append(argument)
                index += 1
            }
        }
        return positional
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AgentBridgeTests-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeGitRepository(at source: URL) throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try runGit(["init", "-q", source.path])
        try runGit(["-C", source.path, "config", "user.name", "AgentBridge Test"])
        try runGit(["-C", source.path, "config", "user.email", "agentbridge@example.invalid"])
        try Data("committed\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        try runGit(["-C", source.path, "add", "tracked.txt"])
        try runGit(["-C", source.path, "commit", "-q", "-m", "snapshot"])
    }

    @discardableResult
    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = [
            "HOME": FileManager.default.temporaryDirectory.path,
            "PATH": "/usr/bin:/bin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0"
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "AgentBridgeTests.Git", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: errorOutput, as: UTF8.self)])
        }
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func fileMode(atPath path: String) -> Int {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return -1 }
        return Int(metadata.st_mode & 0o777)
    }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: Value) { lock.lock(); storage.append(value); lock.unlock() }
}
