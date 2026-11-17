import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class ProviderModelSelectionTests: XCTestCase {
    private let workspace = "/private/tmp/AgentBridge model"
    private let codexChoice = ProviderModelChoice(model: "gpt-test-1", reasoningEffort: "high")
    private let claudeChoice = ProviderModelChoice(model: "opus", reasoningEffort: "xhigh")

    // MARK: Command builders

    func testCodexBuildersPassModelAndEffortOnlyWhenChosen() throws {
        let contextFile = try privateContextFile()
        defer { try? FileManager.default.removeItem(at: contextFile) }
        let builders: [(ProviderModelChoice) throws -> [String]] = [
            { try ProviderCommandBuilder.codexDiscussionArguments(workspacePath: self.workspace, modelChoice: $0) },
            { try ProviderCommandBuilder.codexRunArguments(workspacePath: self.workspace, modelChoice: $0) },
            { try ProviderCommandBuilder.codexRunArguments(workspacePath: self.workspace, resumeID: UUID().uuidString, modelChoice: $0) },
            { try ProviderCommandBuilder.codexChangeArguments(workspacePath: self.workspace, modelChoice: $0) },
            { try ProviderCommandBuilder.codexInteractiveArguments(workspacePath: self.workspace, contextFilePath: contextFile.path, modelChoice: $0) },
            { try ProviderCommandBuilder.codexInteractiveArguments(workspacePath: self.workspace, resumeID: UUID().uuidString, modelChoice: $0) }
        ]
        for build in builders {
            let plain = try build(.cliDefault)
            XCTAssertFalse(plain.contains("-m"))
            XCTAssertFalse(plain.contains { $0.hasPrefix("model_reasoning_effort=") })

            let chosen = try build(codexChoice)
            let modelIndex = try XCTUnwrap(chosen.firstIndex(of: "-m"))
            XCTAssertEqual(chosen[modelIndex + 1], "gpt-test-1")
            let effortIndex = try XCTUnwrap(chosen.firstIndex(of: "model_reasoning_effort=\"high\""))
            XCTAssertEqual(chosen[effortIndex - 1], "-c")
            // Everything else is unchanged; the model options are only added.
            XCTAssertEqual(chosen.filter { !["-m", "gpt-test-1", "model_reasoning_effort=\"high\""].contains($0) }.count, plain.count + 1)
            if let resume = chosen.firstIndex(of: "resume"), chosen.contains("exec") == false {
                // The interactive TUI takes its options before `resume`.
                XCTAssertLessThan(modelIndex, resume)
            }
            if chosen.last == "-" { XCTAssertLessThan(effortIndex, chosen.count - 1) }
        }
        // Only one of the two.
        let effortOnly = try ProviderCommandBuilder.codexRunArguments(
            workspacePath: workspace,
            modelChoice: ProviderModelChoice(reasoningEffort: "ultra")
        )
        XCTAssertFalse(effortOnly.contains("-m"))
        XCTAssertTrue(effortOnly.contains("model_reasoning_effort=\"ultra\""))
    }

    func testClaudeBuildersPassModelAndEffortOnlyWhenChosen() throws {
        let sessionID = UUID()
        let builders: [(ProviderModelChoice) throws -> [String]] = [
            { try ProviderCommandBuilder.claudeDiscussionArguments(modelChoice: $0) },
            { try ProviderCommandBuilder.claudeReadOnlyArguments(workspacePath: self.workspace, sessionID: sessionID, modelChoice: $0) },
            { try ProviderCommandBuilder.claudeReadOnlyArguments(workspacePath: self.workspace, sessionID: sessionID, stateless: true, modelChoice: $0) },
            { try ProviderCommandBuilder.claudeChangeArguments(workspacePath: self.workspace, sessionID: sessionID, modelChoice: $0) },
            { try ProviderCommandBuilder.claudeInteractiveArguments(workspacePath: self.workspace, sessionID: sessionID, modelChoice: $0) },
            { try ProviderCommandBuilder.claudeAPIArguments(workspacePath: self.workspace, budgetUSD: 1, modelChoice: $0) }
        ]
        for build in builders {
            let plain = try build(.cliDefault)
            XCTAssertFalse(plain.contains("--model"))
            XCTAssertFalse(plain.contains("--effort"))
            let chosen = try build(claudeChoice)
            XCTAssertEqual(chosen[try XCTUnwrap(chosen.firstIndex(of: "--model")) + 1], "opus")
            XCTAssertEqual(chosen[try XCTUnwrap(chosen.firstIndex(of: "--effort")) + 1], "xhigh")
            XCTAssertEqual(chosen.count, plain.count + 4)
            // A rejected model must fail the run, never fall back to another one.
            XCTAssertFalse(chosen.contains("--fallback-model"))
        }
    }

    func testUsageTerminalNeverSetsAModel() throws {
        let codex = try ProviderCommandBuilder.codexUsageArguments(workingDirectory: workspace)
        let claude = ProviderCommandBuilder.claudeUsageArguments()
        for arguments in [codex, claude] {
            XCTAssertFalse(arguments.contains("-m"))
            XCTAssertFalse(arguments.contains("--model"))
            XCTAssertFalse(arguments.contains("--effort"))
            XCTAssertFalse(arguments.contains { $0.contains("model_reasoning_effort") })
        }
    }

    func testBuildersRecheckAStoredChoice() {
        // A record edited by hand still cannot smuggle in an option.
        XCTAssertThrowsError(try ProviderCommandBuilder.codexRunArguments(
            workspacePath: workspace,
            modelChoice: ProviderModelChoice(model: "--dangerously-bypass-approvals-and-sandbox")
        ))
        XCTAssertThrowsError(try ProviderCommandBuilder.claudeReadOnlyArguments(
            workspacePath: workspace,
            sessionID: UUID(),
            modelChoice: ProviderModelChoice(reasoningEffort: "ultra")
        ))
    }

    // MARK: Validation

    func testModelNamesAreValidatedAsOneSafeArgument() throws {
        for valid in ["gpt-6-luna", "opus", "claude-opus-5-5[1m]", "org/model:latest", "a@b_c.d"] {
            XCTAssertEqual(try ProviderModelOptions.validatedModel(valid), valid)
        }
        XCTAssertEqual(try ProviderModelOptions.validatedModel("  opus \n"), "opus")
        XCTAssertNil(try ProviderModelOptions.validatedModel("   "))
        XCTAssertNil(try ProviderModelOptions.validatedModel(nil))
        XCTAssertEqual(try ProviderModelOptions.validatedModel(String(repeating: "a", count: 128))?.count, 128)
        for invalid in ["-m", "--model", "gpt 6", "\"opus\"", "op'us", "opus\nsonnet", "op\tus", "opus;rm", "模型", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try ProviderModelOptions.validatedModel(invalid), invalid)
        }
    }

    func testEffortMustBeAKnownLevelForTheProvider() throws {
        XCTAssertEqual(ProviderModelOptions.effortLevels(for: .codex), ["low", "medium", "high", "xhigh", "max", "ultra"])
        XCTAssertEqual(ProviderModelOptions.effortLevels(for: .claude), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(try ProviderModelOptions.validatedEffort("ultra", provider: .codex), "ultra")
        XCTAssertNil(try ProviderModelOptions.validatedEffort("", provider: .claude))
        XCTAssertThrowsError(try ProviderModelOptions.validatedEffort("ultra", provider: .claude))
        XCTAssertThrowsError(try ProviderModelOptions.validatedEffort("HIGH", provider: .codex))
        XCTAssertThrowsError(try ProviderModelOptions.validatedEffort("minimal", provider: .codex))
        XCTAssertThrowsError(try ProviderModelChoice(model: "llama3").validated(for: .local))
        XCTAssertEqual(try ProviderModelChoice.cliDefault.validated(for: .local), .cliDefault)
        XCTAssertThrowsError(try AutonomousRoleBinding(role: .planner, provider: .codex, accountProfileID: UUID(), model: "-x"))
        XCTAssertThrowsError(try AutonomousRoleBinding(role: .reviewer, provider: .claude, accountProfileID: UUID(), reasoningEffort: "ultra"))
    }

    func testLabelSaysCLIDefaultInsteadOfGuessing() {
        XCTAssertEqual(ProviderModelOptions.label(model: nil, reasoningEffort: nil), "CLI default")
        XCTAssertEqual(ProviderModelOptions.label(model: "gpt-x", reasoningEffort: "high"), "gpt-x · high")
        XCTAssertEqual(ProviderModelOptions.label(model: nil, reasoningEffort: "low"), "CLI default · low")
        XCTAssertEqual(ProviderModelOptions.label(model: "opus", reasoningEffort: nil), "opus")
    }

    // MARK: Older records

    func testRecordsSavedBeforeThisChangeDecodeAsCLIDefault() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(SessionRecord.self, from: Data("""
        {"id":"00000000-0000-0000-0000-000000000021","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
         "provider":"codex","sourceRepositoryPath":"/tmp/repo","workspacePath":"/tmp/ws","snapshotCommit":"\(String(repeating: "a", count: 40))",
         "sourceWasDirty":false,"status":"created","policy":{"accessMode":"readOnly","workspaceReadOnly":true,"apiModeAllowed":false}}
        """.utf8))
        XCTAssertNil(session.model)
        XCTAssertNil(session.reasoningEffort)
        XCTAssertEqual(session.modelChoice, .cliDefault)

        let settings = try JSONDecoder().decode(BridgeSettings.self, from: Data(#"{"defaultProvider":"claude","usageMode":"subscription"}"#.utf8))
        XCTAssertNil(settings.codexModelDefaults)
        XCTAssertNil(settings.claudeModelDefaults)
        XCTAssertEqual(settings.modelDefaults(for: .claude), .cliDefault)
        // Unset defaults are not written, so the file stays as it was.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertFalse(String(decoding: try encoder.encode(settings), as: UTF8.self).contains("ModelDefaults"))
        var withDefaults = settings
        withDefaults.setModelDefaults(codexChoice, for: .codex)
        withDefaults.setModelDefaults(.cliDefault, for: .claude)
        let roundTrip = try JSONDecoder().decode(BridgeSettings.self, from: try encoder.encode(withDefaults))
        XCTAssertEqual(roundTrip.modelDefaults(for: .codex), codexChoice)
        XCTAssertNil(roundTrip.claudeModelDefaults)

        let binding = try JSONDecoder().decode(AutonomousRoleBinding.self, from: Data("""
        {"role":"planner","provider":"codex","accountProfileID":"00000000-0000-0000-0000-000000000001","extensionIDs":[]}
        """.utf8))
        XCTAssertEqual(binding.modelChoice, .cliDefault)
        XCTAssertEqual(String(decoding: try encoder.encode(binding), as: UTF8.self), #"{"accountProfileID":"00000000-0000-0000-0000-000000000001","extensionIDs":[],"provider":"codex","role":"planner"}"#)
    }

    // MARK: Autonomous digest

    /// The fixture was written by the code before model selection existed.
    func testAPlanApprovedBeforeModelSelectionKeepsItsDigest() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let plan = try decoder.decode(AutonomousRunPlan.self, from: try Self.fixture("autonomous-plan-before-model-selection.json"))
        XCTAssertEqual(plan.reviewDigest, Self.digestBeforeModelSelection)
        XCTAssertTrue(plan.roleProfiles.allSatisfy { $0.binding.modelChoice == .cliDefault })
        // A plan built today with nothing chosen is the same plan.
        XCTAssertEqual(try Self.fixedPlan().reviewDigest, Self.digestBeforeModelSelection)
    }

    func testChangingARoleModelAfterApprovalInvalidatesTheApproval() async throws {
        let approvedPlan = try Self.fixedPlan(implementerModel: "gpt-test-1", implementerEffort: "high", withMemorySnapshot: true)
        XCTAssertNotEqual(try Self.fixedPlan(implementerModel: "gpt-test-1", implementerEffort: "high").reviewDigest, Self.digestBeforeModelSelection, "A set model must be covered by the digest.")
        XCTAssertNotEqual(approvedPlan.reviewDigest, try Self.fixedPlan(implementerModel: "gpt-test-2", implementerEffort: "high", withMemorySnapshot: true).reviewDigest)
        XCTAssertNotEqual(approvedPlan.reviewDigest, try Self.fixedPlan(implementerModel: "gpt-test-1", implementerEffort: "low", withMemorySnapshot: true).reviewDigest)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentbridge-model-digest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AuditStore(rootURL: root)
        let service = try BridgeService(store: store)
        let runsURL = store.rootURL.appendingPathComponent("autonomous-runs", isDirectory: true)
        var approved = AutonomousRunRecord(plan: approvedPlan, createdEvent: AutonomousRunEvent(kind: "plan.generated", message: "generated"))
        approved.status = .approved
        approved.approvedAt = Date()
        try AutonomousRunStore(rootURL: runsURL).insert(approved)

        // Change the implementer's model in the stored plan after approval; the
        // approved digest stays as it was.
        let document = runsURL.appendingPathComponent("autonomous-runs.json")
        let stored = try String(contentsOf: document, encoding: .utf8)
        XCTAssertEqual(stored.components(separatedBy: "\"gpt-test-1\"").count, 2)
        try Data(stored.replacingOccurrences(of: "\"gpt-test-1\"", with: "\"gpt-test-2\"").utf8).write(to: document)
        do {
            _ = try await service.runAutonomousRun(id: approved.id, reviewedDigest: approved.planDigest)
            XCTFail("A plan whose role model changed after approval was run.")
        } catch let error as AutonomousOrchestrationError {
            // The store refuses a plan that no longer matches its approved digest.
            guard case .invalidRequest(let message) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertTrue(message.contains("integrity"), message)
        }
        // Restoring the approved model makes the same approval valid again.
        try Data(stored.utf8).write(to: document)
        XCTAssertEqual(try AutonomousRunStore(rootURL: runsURL).record(id: approved.id)?.planDigest, approvedPlan.reviewDigest)
    }

    // MARK: Mock CLI runs

    func testBoundModelAndEffortReachTheChildArgvForReadOnlyAndChangeRuns() async throws {
        let fixture = try await makeFixture(script: """
        #!/bin/sh
        case " $* " in *"login status"*) printf '%s\\n' 'Logged in using ChatGPT'; exit 0 ;; esac
        printf '%s\\n' "$@" > "$(dirname "$0")/argv-$$.log"
        /bin/cat > /dev/null
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"done"}}' '{"type":"turn.completed"}'
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let readOnly = try await fixture.service.createSession(
            sourcePath: fixture.source.path, provider: .codex, accessMode: .readOnly, modelChoice: codexChoice
        )
        XCTAssertEqual(readOnly.modelChoice, codexChoice)
        XCTAssertEqual(try fixture.service.sessions().first(where: { $0.id == readOnly.id })?.modelChoice, codexChoice)
        _ = try await fixture.service.runReadOnly(sessionID: readOnly.id, prompt: "Read it.")
        try assertLoggedArgv(in: fixture.bin, contains: ["-m", "gpt-test-1", "-c", "model_reasoning_effort=\"high\""], sandbox: "read-only")

        let change = try await fixture.service.createSession(
            sourcePath: fixture.source.path, provider: .codex, accessMode: .isolatedChanges, modelChoice: codexChoice
        )
        let plan = try fixture.service.createChangePlan(sessionID: change.id, title: "Edit", summary: "Edit source.txt.", steps: ["Edit it."])
        _ = try fixture.service.approveChangePlan(sessionID: change.id, planID: plan.id, reviewedDigest: plan.reviewDigest)
        _ = try await fixture.service.runChanges(sessionID: change.id, prompt: "Edit it.", planID: plan.id, reviewedDigest: plan.reviewDigest)
        try assertLoggedArgv(in: fixture.bin, contains: ["-m", "gpt-test-1", "-c", "model_reasoning_effort=\"high\""], sandbox: "workspace-write")

        // Saved defaults fill in a session created without a choice; nothing saved means none.
        let plain = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .codex)
        XCTAssertEqual(plain.modelChoice, .cliDefault)
        var settings = try fixture.service.settings()
        settings.setModelDefaults(ProviderModelChoice(model: "gpt-default", reasoningEffort: "low"), for: .codex)
        try fixture.service.saveSettings(settings)
        let defaulted = try await fixture.service.createSession(sourcePath: fixture.source.path, provider: .codex)
        XCTAssertEqual(defaulted.modelChoice, ProviderModelChoice(model: "gpt-default", reasoningEffort: "low"))
        do {
            _ = try await fixture.service.createSession(
                sourcePath: fixture.source.path, provider: .codex, modelChoice: ProviderModelChoice(model: "bad name")
            )
            XCTFail("An invalid model name created a session.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testARejectedModelFailsTheRunWithTheCLIError() async throws {
        let fixture = try await makeFixture(script: """
        #!/bin/sh
        case " $* " in *"login status"*) printf '%s\\n' 'Logged in using ChatGPT'; exit 0 ;; esac
        printf '%s\\n' "$@" > "$(dirname "$0")/argv-$$.log"
        /bin/cat > /dev/null
        printf '%s\\n' '{"type":"turn.failed","error":{"message":"The model gpt-missing does not exist."}}'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = try await fixture.service.createSession(
            sourcePath: fixture.source.path, provider: .codex, modelChoice: ProviderModelChoice(model: "gpt-missing")
        )
        do {
            _ = try await fixture.service.runReadOnly(sessionID: session.id, prompt: "Read it.")
            XCTFail("A rejected model was reported as success.")
        } catch let error as AgentBridgeError {
            guard case .providerFailed(.codex, let reason) = error else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(reason, "CLI exit code 1. The CLI reported: The model gpt-missing does not exist.")
        }
        // One launch only: no retry with another model.
        let logs = try FileManager.default.contentsOfDirectory(atPath: fixture.bin.path).filter { $0.hasPrefix("argv-") }
        XCTAssertEqual(logs.count, 1)
    }

    func testFailureDetailIsBoundedAndRedacted() {
        let claudeOutput = Data(#"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Model sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789 not found"}"#.utf8)
        let detail = ProviderOutputParser.failureDetail(provider: .claude, standardOutput: claudeOutput, standardError: Data())
        XCTAssertNotNil(detail)
        XCTAssertFalse(detail?.contains("abcdefghijklmnopqrstuvwxyz0123456789") ?? true)
        let stderr = ProviderOutputParser.failureDetail(provider: .claude, standardOutput: Data(), standardError: Data("\nerror: unknown model 'x'\n\n".utf8))
        XCTAssertEqual(stderr, "error: unknown model 'x'")
        let long = ProviderOutputParser.failureDetail(provider: .codex, standardOutput: Data(), standardError: Data(String(repeating: "e", count: 2_000).utf8))
        XCTAssertEqual(long?.count, 501)
        XCTAssertNil(ProviderOutputParser.failureDetail(provider: .codex, standardOutput: Data(), standardError: Data()))
    }

    // MARK: Discussions

    func testChatsBindTheirModelAndAProviderSwitchClearsIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentbridge-model-chat-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaces = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        let store = try AuditStore(rootURL: root.appendingPathComponent("state", isDirectory: true), workspaceRootURL: workspaces, managedWorkspaceRoots: [])
        let service = try BridgeService(store: store)
        let chat = try service.createDiscussion(provider: .claude, modelChoice: claudeChoice)
        XCTAssertEqual(try service.discussion(id: chat.id).modelChoice, claudeChoice)
        XCTAssertThrowsError(try service.createDiscussion(provider: .claude, modelChoice: ProviderModelChoice(reasoningEffort: "ultra")))
        let codexProfile = try service.selectedAccountProfile(provider: .codex)
        let switched = try service.setDiscussionTarget(id: chat.id, provider: .codex, accountProfileID: codexProfile.id)
        XCTAssertEqual(switched.modelChoice, .cliDefault)
    }

    // MARK: Helpers

    private struct Fixture {
        let root: URL
        let source: URL
        let bin: URL
        let service: BridgeService
    }

    private func makeFixture(script: String) async throws -> Fixture {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = packageRoot.appendingPathComponent("build/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let resolved = parent.path.withCString({ realpath($0, nil) }) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("AgentBridge-Model-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = root.appendingPathComponent("source", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let workspaces = root.appendingPathComponent("workspace-data", isDirectory: true)
        let bin = root.appendingPathComponent("mock-bin", isDirectory: true)
        for directory in [source, state, workspaces, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("original\n".utf8).write(to: source.appendingPathComponent("source.txt"))
        try FixtureGit.run(["init", "-q", source.path])
        try FixtureGit.run(["-C", source.path, "config", "user.name", "AgentBridge Tests"])
        try FixtureGit.run(["-C", source.path, "config", "user.email", "agentbridge-tests@example.invalid"])
        try FixtureGit.run(["-C", source.path, "add", "source.txt"])
        try FixtureGit.run(["-C", source.path, "commit", "-q", "-m", "initial"])
        let codex = bin.appendingPathComponent("codex")
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        let store = try AuditStore(rootURL: state, workspaceRootURL: workspaces, managedWorkspaceRoots: [])
        let service = try BridgeService(store: store)
        var settings = try service.settings()
        settings.codexBinaryPath = codex.path
        settings.usageMode = .subscription
        try service.saveSettings(settings)
        return Fixture(root: root, source: source, bin: bin, service: service)
    }

    /// Checks the argv of the one run logged since the last call, then clears it.
    private func assertLoggedArgv(in bin: URL, contains expected: [String], sandbox: String, line: UInt = #line) throws {
        let logs = try FileManager.default.contentsOfDirectory(at: bin, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("argv-") }
        XCTAssertEqual(logs.count, 1, line: line)
        let argv = try String(contentsOf: XCTUnwrap(logs.first), encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for log in logs { try FileManager.default.removeItem(at: log) }
        XCTAssertEqual(argv[try XCTUnwrap(argv.firstIndex(of: "--sandbox"), line: line) + 1], sandbox, line: line)
        let start = try XCTUnwrap(argv.firstIndex(of: expected[0]), line: line)
        XCTAssertEqual(Array(argv[start..<start + expected.count]), expected, line: line)
    }

    private func privateContextFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agentbridge-context-\(UUID().uuidString)")
        try Data("context".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }

    /// The digest the fixed plan had before model selection was added.
    static let digestBeforeModelSelection = "541425fbdf0e16c6a1ae04656524814c9dbb2329caef52b762c8c241d5fb57fc"

    static func fixedPlan(implementerModel: String? = nil, implementerEffort: String? = nil, withMemorySnapshot: Bool = false) throws -> AutonomousRunPlan {
        func id(_ suffix: String) -> UUID { UUID(uuidString: "00000000-0000-0000-0000-0000000000\(suffix)")! }
        let planner = try AutonomousRoleBinding(role: .planner, provider: .codex, accountProfileID: id("01"))
        let researcher = try AutonomousRoleBinding(role: .researcher, provider: .codex, accountProfileID: id("02"))
        let implementer = try AutonomousRoleBinding(
            role: .implementer, provider: .claude, accountProfileID: id("03"),
            model: implementerModel, reasoningEffort: implementerEffort
        )
        let reviewer = try AutonomousRoleBinding(role: .reviewer, provider: .codex, accountProfileID: id("04"))
        let snapshots = [implementer, planner, researcher, reviewer].map { binding in
            AutonomousRoleProfileSnapshot(
                binding: binding,
                profile: AccountProfile(
                    id: binding.accountProfileID,
                    name: binding.role.rawValue,
                    provider: binding.provider,
                    usesExistingLogin: true,
                    allowsSharedMemory: true,
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                extensionFingerprint: String(repeating: "a", count: 64)
            )
        }
        return AutonomousRunPlan(
            id: id("10"),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            goal: "Update the greeting",
            sourceRepositoryPath: "/tmp/repository",
            baseCommit: String(repeating: "0", count: 40),
            sourceWasDirty: false,
            plannerSessionID: id("11"),
            plannerBinding: planner,
            tasks: [
                AutonomousTaskDefinition(id: "research", role: .researcher, title: "Inspect", prompt: "Read the relevant code.", dependencies: []),
                AutonomousTaskDefinition(id: "implement", role: .implementer, title: "Change", prompt: "Implement the approved edit.", dependencies: ["research"]),
                AutonomousTaskDefinition(id: "review", role: .reviewer, title: "Review", prompt: "Review the exact diff.", dependencies: ["implement"])
            ],
            changeScope: AutonomousChangeScope(title: "Small change", summary: "Change only one file.", steps: ["Edit the selected file."]),
            limits: try AutonomousRunLimits(maxConcurrentAgents: 2, maxReviewRounds: 1, maxDurationSeconds: 60, maxProviderInvocations: 4),
            roleProfiles: snapshots,
            plannedAgents: [
                AutonomousPlannedAgent(taskID: "research", sessionID: id("12"), role: .researcher, extensionFingerprint: String(repeating: "b", count: 64)),
                AutonomousPlannedAgent(taskID: "implement", sessionID: id("13"), role: .implementer, extensionFingerprint: String(repeating: "c", count: 64)),
                AutonomousPlannedAgent(taskID: "review", sessionID: id("14"), role: .reviewer, roundIndex: 1, extensionFingerprint: String(repeating: "d", count: 64))
            ],
            // The run store wants a memory snapshot when profiles share memory.
            projectMemorySnapshot: withMemorySnapshot ? try AutonomousProjectMemorySnapshot(SharedMemorySnapshot(
                scope: SharedMemoryScope(repositoryPath: "/tmp/repository", snapshotCommit: String(repeating: "0", count: 40)),
                turns: [],
                notes: "",
                revision: 0,
                wasTruncated: false
            )) : nil,
            sourceRepositoryFingerprint: AutonomousRepositoryFingerprint(
                sourceRepositoryPath: "/tmp/repository",
                headCommit: String(repeating: "0", count: 40),
                statusDigest: String(repeating: "1", count: 64),
                trackedDiffDigest: String(repeating: "2", count: 64),
                untrackedPathsDigest: String(repeating: "3", count: 64),
                untrackedContentDigest: String(repeating: "4", count: 64)
            ),
            settingsSnapshot: BridgeSettings(),
            shareOutputsWithDependencies: false,
            shareDiffWithReviewer: true,
            verification: .none
        )
    }
}
