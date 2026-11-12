import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class LocalModelCoreIntegrationTests: XCTestCase {
    func testLegacySettingsDecodeAddsLocalDefaultsWithoutChangingProviderMode() throws {
        let legacyJSON = #"{"defaultProvider":"claude","usageMode":"api","codexBinaryPath":"/custom/codex","claudeBinaryPath":"/custom/claude"}"#
        let settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(legacyJSON.utf8))

        XCTAssertEqual(settings.defaultProvider, .claude)
        XCTAssertEqual(settings.usageMode, .api)
        XCTAssertEqual(settings.codexBinaryPath, "/custom/codex")
        XCTAssertEqual(settings.claudeBinaryPath, "/custom/claude")
        XCTAssertEqual(settings.localModel, LocalModelSettings())
    }

    func testLocalSettingsAcceptLoopbackLiteralsAndRejectUnsafeEndpoints() throws {
        var settings = LocalModelSettings(
            backend: .openAICompatible,
            endpoint: "http://[::1]:1234/v1",
            model: "qwen-test",
            contextWindowTokens: 8_192,
            maxOutputTokens: 1_024
        )
        XCTAssertNoThrow(try LocalModelClient.validateSettings(settings))

        for endpoint in [
            "https://127.0.0.1:1234",
            "http://localhost:1234",
            "http://192.168.1.25:1234",
            "http://user:password@127.0.0.1:1234",
            "http://127.0.0.1:1234?model=remote",
            "http://127.0.0.1:1234/#fragment",
            "http://127.0.0.1:1234/%2e%2e/private"
        ] {
            settings.endpoint = endpoint
            XCTAssertThrowsError(try LocalModelClient.validateSettings(settings), "Accepted unsafe endpoint: \(endpoint)")
        }

        settings.endpoint = "http://127.0.0.1:1234"
        settings.contextWindowTokens = 1_023
        XCTAssertThrowsError(try LocalModelClient.validateSettings(settings))
        settings.contextWindowTokens = 8_192
        settings.maxOutputTokens = 8_192
        XCTAssertThrowsError(try LocalModelClient.validateSettings(settings))
    }

    func testLocalProfilesHaveSeparateConsentAndNeverCreateCredentialDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-LocalProfiles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AccountProfileStore(rootURL: root)

        let builtIn = try store.selected(provider: .local)
        XCTAssertEqual(builtIn.id, AccountProfile.defaultID(for: .local))
        XCTAssertEqual(builtIn.name, "Local model")
        XCTAssertTrue(builtIn.allowsSharedMemory)
        XCTAssertEqual(try store.environmentOverrides(for: builtIn), [:])

        let localProfile = try store.create(name: "Desk model", provider: .local)
        XCTAssertFalse(localProfile.usesExistingLogin)
        XCTAssertTrue(localProfile.allowsSharedMemory)
        XCTAssertEqual(try store.environmentOverrides(for: localProfile), [:])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("accounts/\(localProfile.id.uuidString.lowercased())").path
        ))
        XCTAssertThrowsError(try store.loginArguments(for: localProfile))

        try store.setSharedMemoryAllowed(id: AccountProfile.defaultID(for: .local), allowed: false)
        let reopened = try AccountProfileStore(rootURL: root)
        XCTAssertFalse(try reopened.selected(provider: .local).allowsSharedMemory)
        XCTAssertTrue(try reopened.profiles(provider: .local).first(where: { $0.id == localProfile.id })?.allowsSharedMemory == true)
        XCTAssertEqual(try reopened.selected(provider: .codex).id, AccountProfile.defaultID(for: .codex))
        XCTAssertEqual(try reopened.selected(provider: .claude).id, AccountProfile.defaultID(for: .claude))
    }

    func testLocalUsageParserCannotInferClaudePlanOrWindows() {
        let report = ProviderUsageReportParser.parse(
            screenText: "Claude Code Plan: Max\nCurrent session 90% used\nCurrent week 99%",
            provider: .local,
            accountProfileID: AccountProfile.defaultID(for: .local),
            accountName: "Local model"
        )

        XCTAssertNil(report.plan)
        XCTAssertTrue(report.usageWindows.isEmpty)
        XCTAssertEqual(report.status, .noRecognizedFields)
        XCTAssertTrue(report.source.lowercased().contains("local model endpoint"))
    }

    func testLocalRuntimeNeverInheritsProviderCredentialsOrHomes() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("AgentBridge-local-env")
        let environment = RuntimeEnvironment.sanitized(
            base: [
                "HOME": "/Users/example",
                "CODEX_HOME": "/Users/example/.codex",
                "CLAUDE_CONFIG_DIR": "/Users/example/.claude",
                "OPENAI_API_KEY": "must-not-pass",
                "ANTHROPIC_API_KEY": "must-not-pass",
                "HTTP_PROXY": "http://proxy.invalid"
            ],
            provider: .local,
            privateTemporaryDirectory: temp
        )

        XCTAssertEqual(environment["HOME"], "/Users/example")
        XCTAssertEqual(environment["TMPDIR"], temp.path)
        XCTAssertNil(environment["CODEX_HOME"])
        XCTAssertNil(environment["CLAUDE_CONFIG_DIR"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["HTTP_PROXY"])
        XCTAssertThrowsError(try RuntimeEnvironment.resolveExecutable(provider: .local, configuredPath: "/bin/false"))
    }

    func testManagedReadOnlyBuildersCanAvoidVendorHistory() throws {
        let workspace = "/tmp/AgentBridge-local-stateless"
        let codex = try ProviderCommandBuilder.codexRunArguments(workspacePath: workspace, ephemeral: true)
        XCTAssertTrue(codex.contains("--ephemeral"))
        XCTAssertFalse(codex.contains("resume"))

        let claude = try ProviderCommandBuilder.claudeReadOnlyArguments(
            workspacePath: workspace,
            sessionID: UUID(),
            resumeID: "3b12f1df-5232-4804-897e-917bf397618a",
            stateless: true
        )
        XCTAssertTrue(claude.contains("--no-session-persistence"))
        XCTAssertFalse(claude.contains("--session-id"))
        XCTAssertFalse(claude.contains("--resume"))
    }

    func testLocalDiscussionWorksInClaudeAPIModeHonorsLocalConsentAndRefusesBeforeMutation() async throws {
        let root = try temporaryDirectory("AgentBridge-LocalDiscussion")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, service, _) = try makeService(
            root: root,
            baseEnvironment: [
                "HOME": root.path,
                "USER": "local-discussion-test",
                "ANTHROPIC_API_KEY": "inherited-secret-must-not-pass"
            ]
        )
        let modelList = Data(#"{"models":[{"name":"local-test"}]}"#.utf8)
        let response = Data([
            #"{"message":{"role":"assistant","content":"local answer"},"done":false}"#,
            #"{"done":true,"done_reason":"stop"}"#
        ].joined(separator: "\n").appending("\n").utf8)
        let server = try LoopbackHTTPServer { request in
            request.method == "GET" ? .json(modelList) : .stream(response)
        }
        defer { server.stop() }

        var settings = try service.settings()
        settings.defaultProvider = .claude
        settings.usageMode = .api
        settings.claudeBinaryPath = root.appendingPathComponent("missing-claude").path
        settings.localModel = LocalModelSettings(
            backend: .ollama,
            endpoint: "http://127.0.0.1:\(server.port)",
            model: "local-test"
        )
        try service.saveSettings(settings)
        let budgetBefore = try service.budgetSnapshot()
        let discussion = try service.createDiscussion(provider: .local)

        let first = try await service.sendDiscussionMessage(id: discussion.id, prompt: "Maple Lantern remains private")
        XCTAssertEqual(first.text, "local answer")
        let privateProfile = try service.createAccountProfile(
            name: "Local without shared history",
            provider: .local,
            allowsSharedMemory: false
        )
        _ = try service.setDiscussionTarget(id: discussion.id, provider: .local, accountProfileID: privateProfile.id)
        let second = try await service.sendDiscussionMessage(id: discussion.id, prompt: "Only use this new question")
        XCTAssertEqual(second.text, "local answer")

        let posts = server.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 2)
        let secondBody = try XCTUnwrap(posts.last?.jsonBody)
        let secondMessages = try XCTUnwrap(secondBody["messages"] as? [[String: Any]])
        let secondPrompt = try XCTUnwrap(secondMessages.first?["content"] as? String)
        XCTAssertTrue(secondPrompt.contains("Only use this new question"))
        XCTAssertFalse(secondPrompt.contains("Maple Lantern remains private"), "A destination profile without consent must not receive prior shared history.")
        XCTAssertFalse(server.requests.contains { $0.headers["authorization"] != nil })
        XCTAssertEqual(server.requests.map(\.method), ["GET", "POST", "GET", "POST"])

        let completed = try service.discussion(id: discussion.id)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.turns.count, 2)
        XCTAssertEqual(completed.turns.map(\.accountProfileID), [AccountProfile.defaultID(for: .local), privateProfile.id])
        XCTAssertEqual(try service.settings().usageMode, .api, "Local discussion must not rewrite the saved Claude API mode.")
        XCTAssertTrue(try store.events(sessionID: discussion.id).contains(where: { $0.kind == "local.run.completed" }))
        XCTAssertFalse(try store.events(sessionID: discussion.id).contains(where: { $0.kind == "api.run.authorized" || $0.kind == "usage.api.reserved" }))

        let localUsage = try service.usageStatistics(
            provider: .local,
            profileID: privateProfile.id,
            selectedSessionID: discussion.id
        )
        XCTAssertEqual(localUsage.localDailyRuns, 1)
        XCTAssertEqual(localUsage.localSessionRuns, 1)
        XCTAssertEqual(localUsage.apiDailyRuns, 0)
        let claudeUsage = try service.usageStatistics(provider: .claude, profileID: AccountProfile.defaultID(for: .claude))
        XCTAssertEqual(claudeUsage.apiDailyRuns, 0)
        let budgetAfter = try service.budgetSnapshot()
        XCTAssertEqual(budgetAfter.usedUSD, budgetBefore.usedUSD, accuracy: 0.000_001)
        XCTAssertEqual(budgetAfter.reservedUSD, budgetBefore.reservedUSD, accuracy: 0.000_001)

        settings.localModel.contextWindowTokens = 1_024
        settings.localModel.maxOutputTokens = 511
        try service.saveSettings(settings)
        do {
            _ = try await service.sendDiscussionMessage(
                id: discussion.id,
                prompt: "This complete current request cannot fit in a one byte context budget."
            )
            XCTFail("A context refusal must stop before model discovery or prompt submission.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else { return XCTFail("Unexpected compression refusal: \(error)") }
        }
        XCTAssertEqual(server.requests.count, 4, "Compression refusal must happen before any additional HTTP request.")
        let afterRefusal = try service.discussion(id: discussion.id)
        XCTAssertEqual(afterRefusal.status, .completed)
        XCTAssertEqual(afterRefusal.turns.count, 2, "A refused request must not mutate the stored transcript.")
        XCTAssertEqual(
            try service.usageStatistics(provider: .local, profileID: privateProfile.id, selectedSessionID: discussion.id).localSessionRuns,
            1,
            "Refused context is not counted as a local model run."
        )
    }

    func testLocalReadOnlyProjectUsesHTTPAndSavesAppOwnedOutputAndMemory() async throws {
        let root = try temporaryDirectory("AgentBridge-LocalProject")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeGitRepository(at: source)
        let (store, service, _) = try makeService(root: root)
        let modelList = Data(#"{"data":[{"id":"local-chat","context_length":8192}]}"#.utf8)
        let response = Data([
            #"data: {"choices":[{"index":0,"delta":{"content":"Project answer"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "data: [DONE]"
        ].joined(separator: "\n\n").appending("\n\n").utf8)
        let server = try LoopbackHTTPServer { request in
            request.method == "GET" ? .json(modelList) : .stream(response, contentType: "text/event-stream")
        }
        defer { server.stop() }

        var settings = try service.settings()
        settings.usageMode = .api
        settings.localModel = LocalModelSettings(
            backend: .openAICompatible,
            endpoint: "http://127.0.0.1:\(server.port)/v1",
            model: "local-chat"
        )
        try service.saveSettings(settings)
        let session = try await service.createSession(sourcePath: source.path, provider: .local)
        let memory = try SharedMemoryStore(rootURL: store.sharedMemoryURL)
        try memory.appendTurn(
            scope: SharedMemoryScope(repositoryPath: session.sourceRepositoryPath, snapshotCommit: session.snapshotCommit),
            provider: .codex,
            userText: "Keep the local project context.",
            assistantText: "Use the existing parser interface."
        )

        let output = try await service.runReadOnly(sessionID: session.id, prompt: "Summarize the checked-in README.")

        XCTAssertEqual(output.text, "Project answer")
        XCTAssertNil(output.providerSessionID)
        XCTAssertEqual(try store.session(id: session.id)?.status, .completed)
        XCTAssertNil(try store.session(id: session.id)?.providerSessionID)
        XCTAssertEqual(try service.settings().usageMode, .api, "Local project runs must preserve global billing mode.")
        XCTAssertTrue(try store.events(sessionID: session.id).contains(where: { $0.kind == "local.run.started" }))
        XCTAssertTrue(try store.events(sessionID: session.id).contains(where: { $0.kind == "local.run.completed" }))
        XCTAssertFalse(try store.events(sessionID: session.id).contains(where: { $0.kind == "api.run.authorized" || $0.kind == "run.started" }))

        let snapshot = try service.sharedMemory(sessionID: session.id)
        XCTAssertEqual(snapshot.turns.count, 2)
        XCTAssertEqual(snapshot.turns[0].provider, .codex)
        XCTAssertEqual(snapshot.turns[1].provider, .local)
        XCTAssertEqual(snapshot.turns[1].userText, "Summarize the checked-in README.")
        XCTAssertEqual(snapshot.turns[1].assistantText, "Project answer")

        let requests = server.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "POST"])
        XCTAssertEqual(requests.map(\.path), ["/v1/models", "/v1/chat/completions"])
        XCTAssertFalse(requests.contains { $0.headers["authorization"] != nil })
        let body = try XCTUnwrap(requests.last?.jsonBody)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let sentPrompt = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(sentPrompt.contains("Keep the local project context."))
        XCTAssertTrue(sentPrompt.contains("Summarize the checked-in README."))

        let usage = try service.usageStatistics(provider: .local, profileID: AccountProfile.defaultID(for: .local), selectedSessionID: session.id)
        XCTAssertEqual(usage.localDailyRuns, 1)
        XCTAssertEqual(usage.localSessionRuns, 1)
        XCTAssertEqual(usage.apiDailyRuns, 0)
    }

    func testUnsupportedLocalProjectModesRefuseBeforeWorkspaceOrGitMutation() async throws {
        let root = try temporaryDirectory("AgentBridge-LocalUnsupported")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeGitRepository(at: source)
        let (store, service, _) = try makeService(root: root)
        let server = try LoopbackHTTPServer { _ in .json(Data(#"{"models":[]}"#.utf8)) }
        defer { server.stop() }
        var settings = try service.settings()
        settings.localModel = LocalModelSettings(
            endpoint: "http://127.0.0.1:\(server.port)",
            model: "unused-local-model"
        )
        try service.saveSettings(settings)

        do {
            _ = try await service.createSession(
                sourcePath: source.path,
                provider: .local,
                accessMode: .isolatedChanges
            )
            XCTFail("Local isolated-change sessions must be rejected before workspace creation.")
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { return XCTFail("Unexpected local isolated-session error: \(error)") }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.workspacesURL.path).isEmpty)
        XCTAssertTrue(try service.sessions().isEmpty)

        let localProfileID = AccountProfile.defaultID(for: .local)
        let planner = try AutonomousRoleBinding(role: .planner, provider: .local, accountProfileID: localProfileID)
        let autonomousRoles = try [
            AutonomousRoleBinding(role: .researcher, provider: .local, accountProfileID: localProfileID),
            AutonomousRoleBinding(role: .implementer, provider: .local, accountProfileID: localProfileID),
            AutonomousRoleBinding(role: .reviewer, provider: .local, accountProfileID: localProfileID)
        ]
        let autonomousRequest = try AutonomousRunRequest(
            goal: "Do not start an autonomous local workflow",
            sourceRepositoryPath: source.path,
            planner: planner,
            roleBindings: autonomousRoles,
            shareDiffWithReviewer: true
        )
        do {
            _ = try await service.prepareAutonomousRun(autonomousRequest)
            XCTFail("Local profiles must be refused before autonomous workspace creation.")
        } catch let error as AutonomousOrchestrationError {
            guard case .invalidRequest = error else { return XCTFail("Unexpected autonomous local error: \(error)") }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.workspacesURL.path).isEmpty)
        XCTAssertTrue(try service.sessions().isEmpty)

        let session = try await service.createSession(sourcePath: source.path, provider: .local)
        let workspaceHead = try FixtureGit.run(["-C", session.workspacePath, "rev-parse", "HEAD"])
        let workspaceStatus = try FixtureGit.run(["-C", session.workspacePath, "status", "--porcelain"])
        let sourceHead = try FixtureGit.run(["-C", source.path, "rev-parse", "HEAD"])

        do {
            _ = try await service.runInteractive(sessionID: session.id)
            XCTFail("Local sessions must refuse interactive terminal launch.")
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { return XCTFail("Unexpected local interactive error: \(error)") }
        }
        XCTAssertThrowsError(try service.createChangePlan(
            sessionID: session.id,
            title: "Unsupported",
            summary: "Local changes are not enabled",
            steps: ["Modify a file"]
        ))
        do {
            _ = try await service.runChanges(
                sessionID: session.id,
                prompt: "Do not edit files",
                planID: UUID(),
                reviewedDigest: ""
            )
            XCTFail("Local sessions must refuse isolated change runs.")
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { return XCTFail("Unexpected local change-run error: \(error)") }
        }
        XCTAssertThrowsError(try service.appendAutonomousMemoryTurn(
            sessionID: session.id,
            profileID: AccountProfile.defaultID(for: .local),
            userText: "autonomous",
            assistantText: "memory"
        ))

        XCTAssertEqual(try FixtureGit.run(["-C", session.workspacePath, "rev-parse", "HEAD"]), workspaceHead)
        XCTAssertEqual(try FixtureGit.run(["-C", session.workspacePath, "status", "--porcelain"]), workspaceStatus)
        XCTAssertTrue(workspaceStatus.isEmpty)
        XCTAssertEqual(try FixtureGit.run(["-C", source.path, "rev-parse", "HEAD"]), sourceHead)
        XCTAssertEqual(try store.session(id: session.id)?.status, .created)
        XCTAssertNil(try store.session(id: session.id)?.changePlan)
        XCTAssertFalse(try store.events(sessionID: session.id).contains(where: {
            ["local.run.started", "run.started", "change.run.started", "interactive.launching"].contains($0.kind)
        }))
        XCTAssertTrue(server.requests.isEmpty, "Unsupported capabilities must be rejected before local HTTP calls.")
    }

    private func makeService(
        root: URL,
        baseEnvironment: [String: String] = [:]
    ) throws -> (AuditStore, BridgeService, URL) {
        let dataRoot = root.appendingPathComponent("user-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let store = try AuditStore(
            rootURL: root.appendingPathComponent("state", isDirectory: true),
            workspaceRootURL: dataRoot,
            managedWorkspaceRoots: []
        )
        let service = try BridgeService(store: store, baseEnvironment: baseEnvironment)
        return (store, service, dataRoot)
    }

    private func temporaryDirectory(_ prefix: String) throws -> URL {
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
        let root = canonicalParent.appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func makeGitRepository(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FixtureGit.run(["-c", "init.defaultBranch=main", "init", "--quiet", "--", url.path])
        try Data("# Local integration fixture\n".utf8).write(to: url.appendingPathComponent("README.md"))
        try FixtureGit.run(["-C", url.path, "add", "README.md"])
        try FixtureGit.run(["-C", url.path, "commit", "--quiet", "-m", "initial"])
    }
}
