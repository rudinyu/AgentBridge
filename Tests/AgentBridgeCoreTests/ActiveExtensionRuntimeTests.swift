import Foundation
import Darwin
import XCTest
@testable import AgentBridgeCore

final class ActiveExtensionRuntimeTests: XCTestCase {
    func testSkillImportSnapshotsOnlyBoundedNoFollowInstructions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let skillDirectory = root.appendingPathComponent("skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        let skillFile = skillDirectory.appendingPathComponent("SKILL.md")
        try Data("Use the local style guide.\n".utf8).write(to: skillFile)
        let descriptor = try ExtensionDescriptor(id: "style.skill", kind: .skill, name: "Style", version: "1", summary: "Task instructions only")

        let text = try ActiveSkillFileReader.read(at: skillFile)
        let snapshot = try ActiveSkillSnapshot(descriptor: descriptor, sourceReference: skillFile.path, instructionText: text)
        XCTAssertEqual(snapshot.instructionText, text)
        XCTAssertEqual(snapshot.contentDigest, ActiveExtensionDigest.sha256(Data(text.utf8)))

        let linkedDirectory = root.appendingPathComponent("linked-skill", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: skillDirectory)
        XCTAssertThrowsError(try ActiveSkillFileReader.read(at: linkedDirectory.appendingPathComponent("SKILL.md")))

        try Data(repeating: 0x61, count: ActiveSkillSnapshot.maximumContentBytes + 1).write(to: skillFile)
        XCTAssertThrowsError(try ActiveSkillFileReader.read(at: skillFile))
    }

    func testCurrentInvocationRejectsSkillRevocationReenableAndReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ActiveExtensionRuntimeStore(rootURL: root.appendingPathComponent("extension-runtime", isDirectory: true))
        let descriptor = try ExtensionDescriptor(
            id: "race.skill",
            kind: .skill,
            name: "Race Skill",
            version: "1",
            summary: "Fixture for a startup-time revoke."
        )
        let snapshot = try ActiveSkillSnapshot(
            descriptor: descriptor,
            sourceReference: "fixture SKILL.md",
            instructionText: "Use the reviewed instructions."
        )
        try store.importSkill(snapshot)
        let projectID = "project-revoke-race"
        let profileID = AccountProfile.defaultID(for: .codex)
        let review = try store.preview(extensionID: snapshot.extensionID, projectID: projectID, provider: .codex, profileID: profileID)
        _ = try store.enable(
            extensionID: snapshot.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            reviewedDigest: review.reviewedDigest,
            explicitExecutionConsent: true,
            grantedBy: "test"
        )

        let invocation = try store.invocation(
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            workspacePath: root.appendingPathComponent("workspace", isDirectory: true).path,
            selectedExtensionIDs: [snapshot.extensionID]
        )
        let sessionID = UUID()
        try store.validateAndBind(sessionID: sessionID, invocation: invocation)
        XCTAssertNoThrow(try store.validateCurrentInvocation(invocation))

        XCTAssertTrue(try store.disable(
            extensionID: snapshot.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            disabledBy: "test revoke during startup"
        ))
        XCTAssertThrowsError(try store.validateCurrentInvocation(invocation)) { error in
            XCTAssertEqual(error as? ActiveExtensionRuntimeError, .grantMissing(snapshot.extensionID))
        }

        let renewedReview = try store.preview(extensionID: snapshot.extensionID, projectID: projectID, provider: .codex, profileID: profileID)
        _ = try store.enable(
            extensionID: snapshot.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            reviewedDigest: renewedReview.reviewedDigest,
            explicitExecutionConsent: true,
            grantedBy: "test re-enable"
        )
        XCTAssertThrowsError(try store.validateCurrentInvocation(invocation)) { error in
            XCTAssertEqual(error as? ActiveExtensionRuntimeError, .sessionFingerprintChanged)
        }

        let renewedInvocation = try store.invocation(
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            workspacePath: invocation.workspacePath,
            selectedExtensionIDs: [snapshot.extensionID]
        )
        let replacement = try ActiveSkillSnapshot(
            descriptor: descriptor,
            sourceReference: "fixture SKILL.md",
            instructionText: "The reviewed instructions have changed."
        )
        try store.importSkill(replacement)
        XCTAssertThrowsError(try store.validateCurrentInvocation(renewedInvocation)) { error in
            XCTAssertEqual(error as? ActiveExtensionRuntimeError, .grantMissing(snapshot.extensionID))
        }
    }

    func testReadOnlyRunRejectsSkillRevokedWhileAuthenticationIsPending() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let state = root.appendingPathComponent("state", isDirectory: true)
        let workspaceData = root.appendingPathComponent("workspace-data", isDirectory: true)
        let providerHome = root.appendingPathComponent("provider-home", isDirectory: true)
        for directory in [source, state, workspaceData, providerHome] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("fixture\n".utf8).write(to: source.appendingPathComponent("source.txt"))
        try runGit(["init", "-q", source.path])
        try runGit(["-C", source.path, "config", "user.name", "AgentBridge Tests"])
        try runGit(["-C", source.path, "config", "user.email", "agentbridge-tests@example.invalid"])
        try runGit(["-C", source.path, "add", "source.txt"])
        try runGit(["-C", source.path, "commit", "-q", "-m", "initial"])

        let fakeCodex = root.appendingPathComponent("codex")
        let authStartedURL = providerHome.appendingPathComponent("authentication-started")
        let continueAuthenticationURL = providerHome.appendingPathComponent("continue-authentication")
        let providerStartedURL = providerHome.appendingPathComponent("provider-started")
        let codexScript = #"""
        #!/bin/sh
        if [ "$1" = "login" ] && [ "$2" = "status" ]; then
          : > "$CODEX_HOME/authentication-started"
          while [ ! -e "$CODEX_HOME/continue-authentication" ]; do /bin/sleep 0.02; done
          echo "Logged in using ChatGPT" >&2
          exit 0
        fi
        : > "$CODEX_HOME/provider-started"
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Provider unexpectedly launched."}}' '{"type":"turn.completed"}'
        """#
        try Data(codexScript.utf8).write(to: fakeCodex)
        XCTAssertEqual(chmod(fakeCodex.path, mode_t(0o755)), 0)

        let auditStore = try AuditStore(
            rootURL: state,
            workspaceRootURL: workspaceData,
            managedWorkspaceRoots: []
        )
        try auditStore.saveSettings(BridgeSettings(
            defaultProvider: .codex,
            usageMode: .subscription,
            codexBinaryPath: fakeCodex.path
        ))
        let service = try BridgeService(
            store: auditStore,
            baseEnvironment: ["HOME": providerHome.path, "CODEX_HOME": providerHome.path]
        )
        let session = try await service.createSession(sourcePath: source.path, provider: .codex)
        let skillFile = root.appendingPathComponent("SKILL.md")
        try Data("Use only the approved style guidance.\n".utf8).write(to: skillFile)
        let descriptor = try ExtensionDescriptor(
            id: "race.authentication-skill",
            kind: .skill,
            name: "Authentication race fixture",
            version: "1",
            summary: "Imported instructions revoked during authentication."
        )
        let skill = try service.importSkillRuntime(
            descriptor: descriptor,
            sourceReference: skillFile.path,
            skillFileURL: skillFile
        )
        let review = try service.previewExtensionActivation(extensionID: skill.extensionID, sessionID: session.id)
        try service.enableExtensionRuntime(
            extensionID: skill.extensionID,
            sessionID: session.id,
            reviewedDigest: review.reviewedDigest,
            explicitExecutionConsent: true
        )

        let run = Task {
            try await service.runReadOnly(sessionID: session.id, prompt: "Run the fixture.")
        }
        defer { try? Data("continue".utf8).write(to: continueAuthenticationURL) }
        var authenticationStarted = false
        for _ in 0..<500 {
            if FileManager.default.fileExists(atPath: authStartedURL.path) {
                authenticationStarted = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard authenticationStarted else {
            try? Data("continue".utf8).write(to: continueAuthenticationURL)
            _ = await run.result
            XCTFail("The fake CLI did not begin authentication within the bounded wait.")
            return
        }

        XCTAssertTrue(try service.disableExtensionRuntime(extensionID: skill.extensionID, sessionID: session.id))
        try Data("continue".utf8).write(to: continueAuthenticationURL)
        do {
            _ = try await run.value
            XCTFail("The provider run continued after its Skill was revoked during authentication.")
        } catch let error as ActiveExtensionRuntimeError {
            XCTAssertEqual(error, .grantMissing(skill.extensionID))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: providerStartedURL.path))
        XCTAssertEqual(try auditStore.session(id: session.id)?.status, .failed)
    }

    func testInterpreterEntrypointPinsRejectWorkspaceScriptsAndDetectChanges() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try pythonExecutable()
        let pinnedScript = root.appendingPathComponent("server.py")
        try Data("print('one')\n".utf8).write(to: pinnedScript)
        let pins = try MCPEntrypointIntegrity.pins(commandPath: python, arguments: [pinnedScript.path])
        XCTAssertEqual(pins.count, 1)
        XCTAssertEqual(pins.first?.path, pinnedScript.path)
        XCTAssertNoThrow(try MCPEntrypointIntegrity.validate(pins, workspacePath: root.appendingPathComponent("workspace").path))

        try Data("print('changed')\n".utf8).write(to: pinnedScript)
        XCTAssertThrowsError(try MCPEntrypointIntegrity.validate(pins, workspacePath: root.appendingPathComponent("workspace").path))

        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let writableScript = workspace.appendingPathComponent("server.py")
        try Data("print('mutable')\n".utf8).write(to: writableScript)
        let workspacePins = try MCPEntrypointIntegrity.pins(commandPath: python, arguments: [writableScript.path])
        XCTAssertThrowsError(try MCPEntrypointIntegrity.validate(workspacePins, workspacePath: workspace.path))

        let linkedScript = root.appendingPathComponent("linked-server.py")
        try FileManager.default.createSymbolicLink(at: linkedScript, withDestinationURL: pinnedScript)
        XCTAssertThrowsError(try MCPEntrypointIntegrity.pins(commandPath: python, arguments: [linkedScript.path]))

        let oversizedScript = root.appendingPathComponent("oversized-server.py")
        try Data(repeating: 0x23, count: Int(MCPEntrypointIntegrity.maximumScriptBytes) + 1).write(to: oversizedScript)
        XCTAssertThrowsError(try MCPEntrypointIntegrity.pins(commandPath: python, arguments: [oversizedScript.path]))

        let shellScript = root.appendingPathComponent("server.sh")
        try Data("printf 'fixture\\n'\n".utf8).write(to: shellScript)
        let shellPins = try MCPEntrypointIntegrity.pins(commandPath: "/bin/sh", arguments: [shellScript.path])
        XCTAssertEqual(shellPins.count, 1)
        XCTAssertNoThrow(try MCPEntrypointIntegrity.validate(shellPins, workspacePath: root.appendingPathComponent("other-workspace").path))
        XCTAssertTrue(try MCPEntrypointIntegrity.pins(commandPath: "/bin/sh", arguments: ["-c", "printf fixture"]).isEmpty)
        XCTAssertThrowsError(try MCPEntrypointIntegrity.pins(
            commandPath: "/usr/bin/env",
            arguments: [python, pinnedScript.path]
        ))
    }

    func testImportDoesNotStartMCPProcess() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try pythonExecutable()
        let marker = root.appendingPathComponent("must-not-exist")
        let store = try AuditStore(rootURL: root.appendingPathComponent("state", isDirectory: true))
        let service = try BridgeService(
            store: store,
            baseEnvironment: [:],
            runtimeProxyExecutableURL: URL(fileURLWithPath: python)
        )
        let manifest = try MCPRuntimeImportManifest(
            id: "local.marker",
            name: "Marker process",
            version: "1",
            summary: "Only starts after explicit test/enable.",
            command: python,
            args: ["-c", "open(\(String(reflecting: marker.path)), 'w').write('started')"],
            allowedTools: ["inspect"]
        )

        let imported = try service.importMCPRuntimeManifest(manifest, sourceReference: "test fixture")
        XCTAssertEqual(imported.allowedTools, ["inspect"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testMCPManifestRejectsUnsupportedEnvironmentAndRemoteTransportFields() throws {
        let base = #"{"schemaVersion":1,"id":"example.server","name":"Example","version":"1","summary":"Fixture","command":"/usr/bin/true","args":[],"allowedTools":["read"]}"#
        let withEnvironment = String(base.dropLast()) + #", "env":{"API_TOKEN":"must-not-be-accepted"}}"#
        let withHTTPTransport = String(base.dropLast()) + #", "type":"http","url":"https://example.invalid/mcp"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(MCPRuntimeImportManifest.self, from: Data(withEnvironment.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(MCPRuntimeImportManifest.self, from: Data(withHTTPTransport.utf8)))
    }

    func testMCPChildEnvironmentDoesNotInheritCredentialsOrProviderConfigHomes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = [
            "HOME": "/Users/example",
            "TMPDIR": "/tmp",
            "PATH": "/private/custom/bin",
            "CODEX_HOME": "/Users/example/.codex",
            "CLAUDE_CONFIG_DIR": "/Users/example/.claude",
            "OPENAI_API_KEY": "openai-secret",
            "ANTHROPIC_API_KEY": "anthropic-secret",
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "CUSTOM_TOKEN": "custom-secret"
        ]
        let environment = MCPRuntimeEnvironment.nativeServerEnvironment(provider: .claude, privateDirectory: root, base: base)
        XCTAssertEqual(environment["HOME"], root.path)
        XCTAssertEqual(environment["TMPDIR"], root.path)
        XCTAssertEqual(environment["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["CODEX_HOME"], root.path)
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], root.path)
        XCTAssertEqual(environment["OPENAI_API_KEY"], "")
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(environment["AWS_SECRET_ACCESS_KEY"], "")
        XCTAssertNil(environment["CUSTOM_TOKEN"])
    }

    func testActivationDigestScopeStaleTicketAndRevocationFailClosed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try MCPExecutableValidation.resolveAndDigest("/usr/bin/true")
        let store = try ActiveExtensionRuntimeStore(rootURL: root.appendingPathComponent("extension-runtime", isDirectory: true))
        let manifest = try MCPRuntimeImportManifest(
            id: "sample.echo",
            name: "Echo",
            version: "1",
            summary: "Local fixture server",
            command: executable.path,
            args: ["-u", "-c", FakeMCPServer.program],
            allowedTools: ["echo", "image_echo", "slow"],
            maximumToolCallsPerRun: 3,
            maximumToolResponseBytes: 64 * 1_024,
            maximumTotalToolResponseBytes: 128 * 1_024
        )
        let configuration = try ActiveMCPConfiguration(
            manifest: manifest,
            sourceReference: "offline test fixture",
            resolvedExecutablePath: executable.path,
            executableDigest: executable.digest
        )
        try store.importMCP(configuration)
        let serverTools = ["echo", "image_echo", "slow", "unapproved"].sorted()
        let serverDefinitions = try toolDefinitionsJSON(names: serverTools)
        try store.recordInspection(MCPServerInspection(
            extensionID: configuration.extensionID,
            configurationDigest: configuration.configurationDigest,
            toolNames: serverTools,
            toolDefinitionsJSON: serverDefinitions,
            inspectionDigest: MCPServerInspection.makeDigest(configurationDigest: configuration.configurationDigest, toolNames: serverTools, toolDefinitionsJSON: serverDefinitions),
            diagnostics: ["offline fixture inspected"],
            inspectedAt: Date()
        ))

        let projectID = "project-test"
        let profileID = AccountProfile.defaultID(for: .codex)
        let review = try store.preview(extensionID: configuration.extensionID, projectID: projectID, provider: .codex, profileID: profileID)
        XCTAssertEqual(review.toolDefinitionsJSON, serverDefinitions)
        XCTAssertEqual(review.allowedTools, ["echo", "image_echo", "slow"])
        XCTAssertThrowsError(try store.enable(
            extensionID: configuration.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            reviewedDigest: review.reviewedDigest,
            explicitExecutionConsent: false,
            grantedBy: "test"
        ))
        let grant = try store.enable(
            extensionID: configuration.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            reviewedDigest: review.reviewedDigest,
            explicitExecutionConsent: true,
            grantedBy: "test"
        )
        let workspace = root.appendingPathComponent("workspace", isDirectory: true).path
        let invocation = try store.invocation(
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            workspacePath: workspace,
            selectedExtensionIDs: [configuration.extensionID]
        )
        let sessionID = UUID()
        try store.validateAndBind(sessionID: sessionID, invocation: invocation)
        XCTAssertThrowsError(try store.invocation(
            projectID: "project-other",
            provider: .codex,
            profileID: profileID,
            workspacePath: workspace,
            selectedExtensionIDs: [configuration.extensionID]
        ))

        let proxy = executable
        let ticket = try MCPProxyTicket(
            sessionID: sessionID,
            extensionID: configuration.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            configurationDigest: configuration.configurationDigest,
            reviewedDigest: grant.reviewedDigest,
            serverInspectionDigest: try XCTUnwrap(invocation.mcpInspectionDigests[configuration.extensionID]),
            sessionExtensionFingerprint: invocation.fingerprint,
            runtimeStoreRootPath: store.rootURL.path,
            workspacePath: workspace,
            cancellationRequestPath: root.appendingPathComponent("cancel.request").path,
            receiptPath: root.appendingPathComponent("receipt.json").path,
            proxyExecutablePath: proxy.path,
            proxyExecutableDigest: proxy.digest,
            serverExecutablePath: configuration.executablePath,
            serverExecutableDigest: configuration.executableDigest,
            serverArguments: configuration.arguments,
            serverEntrypointPins: configuration.entrypointPins,
            allowedTools: configuration.allowedTools,
            startupTimeoutSeconds: configuration.startupTimeoutSeconds,
            toolTimeoutSeconds: configuration.toolTimeoutSeconds,
            maximumToolCallsPerRun: 2,
            maximumToolResponseBytes: configuration.maximumToolResponseBytes,
            maximumTotalToolResponseBytes: configuration.maximumTotalToolResponseBytes,
            launchConfiguration: configuration.launchConfiguration,
            expiresAt: Date().addingTimeInterval(120)
        )
        try store.validateProxyTicket(ticket)
        let ticketDirectory = root.appendingPathComponent("tickets", isDirectory: true)
        try FileManager.default.createDirectory(at: ticketDirectory, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(ticketDirectory.path, 0o700), 0)
        let ticketURL = ticketDirectory.appendingPathComponent("runtime.json")
        try MCPProxyTicketFile.write(ticket, to: ticketURL)
        let storedTicket = try MCPProxyTicketFile.read(from: ticketURL)
        XCTAssertEqual(storedTicket.ticketID, ticket.ticketID)
        XCTAssertEqual(storedTicket.reviewedDigest, ticket.reviewedDigest)
        XCTAssertEqual(storedTicket.maximumToolCallsPerRun, 2)
        XCTAssertEqual(storedTicket.runtimeStoreRootPath, store.rootURL.path)
        XCTAssertEqual(storedTicket.workspacePath, workspace)

        guard let cliTicketAliasRange = ticketURL.path.range(of: "/private/var/") else {
            throw XCTSkip("This regression fixture requires the macOS canonical /private/var temporary path.")
        }
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildRoot = repositoryRoot.appendingPathComponent("build", isDirectory: true)
        let buildDirectories = (try? FileManager.default.contentsOfDirectory(
            at: buildRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        var cliCandidates: [(url: URL, modifiedAt: Date)] = []
        for buildDirectory in buildDirectories {
            let targetDirectories = (try? FileManager.default.contentsOfDirectory(
                at: buildDirectory,
                includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            for targetDirectory in targetDirectories {
                let candidate = targetDirectory
                    .appendingPathComponent("debug", isDirectory: true)
                    .appendingPathComponent("agentbridge")
                guard FileManager.default.isExecutableFile(atPath: candidate.path) else { continue }
                let modifiedAt = (try? FileManager.default.attributesOfItem(atPath: candidate.path)[.modificationDate] as? Date) ?? .distantPast
                cliCandidates.append((candidate, modifiedAt))
            }
        }
        guard let cliURL = cliCandidates.max(by: { $0.modifiedAt < $1.modifiedAt })?.url else {
            throw XCTSkip("The built AgentBridge CLI was not found under the repository build directory.")
        }
        func runCLI(ticketPath: String) throws -> (Int32, String) {
            let process = Process()
            process.executableURL = cliURL
            process.arguments = ["mcp-proxy", "--ticket", ticketPath]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            let standardError = Pipe()
            process.standardError = standardError
            try process.run()
            let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: errorData, as: UTF8.self))
        }
        let (canonicalStatus, _) = try runCLI(ticketPath: ticketURL.path)
        XCTAssertNotEqual(canonicalStatus, EXIT_SUCCESS)
        let cliReceipt = try MCPProxyReceiptFile.read(from: URL(fileURLWithPath: ticket.receiptPath))
        XCTAssertEqual(cliReceipt.status, .failed)
        XCTAssertEqual(cliReceipt.failureCode, .executableChanged)

        let aliasTicketPath = ticketURL.path.replacingCharacters(in: cliTicketAliasRange, with: "/var/")
        let (aliasStatus, aliasError) = try runCLI(ticketPath: aliasTicketPath)
        XCTAssertNotEqual(aliasStatus, EXIT_SUCCESS)
        XCTAssertTrue(aliasError.contains("symlink or missing directory"))
        XCTAssertEqual(try MCPProxyReceiptFile.read(from: URL(fileURLWithPath: ticket.receiptPath)), cliReceipt)

        let receipt = try MCPProxyReceipt(ticket: ticket, status: .initialized, toolCallCount: 2)
        let receiptURL = URL(fileURLWithPath: ticket.receiptPath)
        try MCPProxyReceiptFile.write(receipt, to: receiptURL)
        let storedReceipt = try MCPProxyReceiptFile.read(from: receiptURL)
        XCTAssertEqual(storedReceipt.ticketID, ticket.ticketID)
        XCTAssertEqual(storedReceipt.extensionID, configuration.extensionID)
        XCTAssertEqual(storedReceipt.status, .initialized)
        XCTAssertEqual(storedReceipt.toolCallCount, 2)

        let changedDefinitions = serverDefinitions.replacingOccurrences(of: "Fixture description", with: "Updated server description")
        let changedInspection = MCPServerInspection(
            extensionID: configuration.extensionID,
            configurationDigest: configuration.configurationDigest,
            toolNames: serverTools,
            toolDefinitionsJSON: changedDefinitions,
            inspectionDigest: MCPServerInspection.makeDigest(configurationDigest: configuration.configurationDigest, toolNames: serverTools, toolDefinitionsJSON: changedDefinitions),
            diagnostics: ["same tool names, changed reviewed schema"],
            inspectedAt: Date()
        )
        XCTAssertTrue(try store.recordInspection(changedInspection))
        XCTAssertThrowsError(try store.validateProxyTicket(ticket))
        let changedReview = try store.preview(extensionID: configuration.extensionID, projectID: projectID, provider: .codex, profileID: profileID)
        let changedGrant = try store.enable(
            extensionID: configuration.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            reviewedDigest: changedReview.reviewedDigest,
            explicitExecutionConsent: true,
            grantedBy: "test"
        )
        let changedInvocation = try store.invocation(
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            workspacePath: workspace,
            selectedExtensionIDs: [configuration.extensionID]
        )
        XCTAssertNotEqual(changedInvocation.fingerprint, invocation.fingerprint)
        XCTAssertEqual(changedInvocation.mcpInspectionDigests[configuration.extensionID], changedInspection.inspectionDigest)
        XCTAssertThrowsError(try store.validateProxyTicket(ticket))

        XCTAssertTrue(try store.disable(
            extensionID: configuration.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            disabledBy: "test"
        ))
        XCTAssertThrowsError(try store.validateProxyTicket(ticket))
        let renewedGrant = try store.enable(
            extensionID: configuration.extensionID,
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            reviewedDigest: changedReview.reviewedDigest,
            explicitExecutionConsent: true,
            grantedBy: "test"
        )
        let renewedInvocation = try store.invocation(
            projectID: projectID,
            provider: .codex,
            profileID: profileID,
            workspacePath: workspace,
            selectedExtensionIDs: [configuration.extensionID]
        )
        XCTAssertNotEqual(renewedGrant.grantID, changedGrant.grantID)
        XCTAssertNotEqual(renewedInvocation.fingerprint, changedInvocation.fingerprint)
        XCTAssertThrowsError(try store.validateProxyTicket(ticket))
    }

    func testMacControlRequiresSeparateScreenAndInputConsentAndUsesFixedActions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try MCPExecutableValidation.resolveAndDigest("/usr/bin/true")
        let configuration = try ActiveMCPConfiguration(
            macControlTargetBundleID: "com.example.editor",
            accessMode: .control,
            helperPath: executable.path,
            helperDigest: executable.digest,
            proxyExecutablePath: executable.path,
            proxyExecutableDigest: executable.digest,
            version: "1"
        )
        XCTAssertFalse(MacControlActionPolicy.isAllowedTarget("com.apple.systempreferences"))
        XCTAssertFalse(MacControlActionPolicy.isAllowedTarget("COM.APPLE.SYSTEMPREFERENCES"))
        XCTAssertFalse(MacControlActionPolicy.isAllowedTarget("ORG.AGENTBRIDGE.APP"))
        XCTAssertFalse(MacControlActionPolicy.isAllowedTarget("TW.COM.EAMAN.MACCONTROL"))
        XCTAssertTrue(configuration.allowedTools.contains("mac_mouse"))
        XCTAssertEqual(configuration.maximumToolCallsPerRun, 8)

        let store = try ActiveExtensionRuntimeStore(rootURL: root.appendingPathComponent("extension-runtime", isDirectory: true))
        try store.importMCP(configuration)
        let definitions = try toolDefinitionsJSON(names: configuration.allowedTools)
        try store.recordInspection(MCPServerInspection(
            extensionID: configuration.extensionID,
            configurationDigest: configuration.configurationDigest,
            toolNames: configuration.allowedTools,
            toolDefinitionsJSON: definitions,
            inspectionDigest: MCPServerInspection.makeDigest(configurationDigest: configuration.configurationDigest, toolNames: configuration.allowedTools, toolDefinitionsJSON: definitions),
            diagnostics: ["offline preset fixture"],
            inspectedAt: Date()
        ))
        let profileID = AccountProfile.defaultID(for: .claude)
        let review = try store.preview(extensionID: configuration.extensionID, projectID: "project-mac", provider: .claude, profileID: profileID)
        XCTAssertTrue(review.requiresScreenCaptureConsent)
        XCTAssertTrue(review.requiresInputControlConsent)
        XCTAssertThrowsError(try store.enable(
            extensionID: configuration.extensionID,
            projectID: "project-mac",
            provider: .claude,
            profileID: profileID,
            reviewedDigest: review.reviewedDigest,
            explicitExecutionConsent: true,
            grantedBy: "test"
        )) { error in XCTAssertEqual(error as? ActiveExtensionRuntimeError, .screenCaptureConsentRequired) }
        XCTAssertThrowsError(try store.enable(
            extensionID: configuration.extensionID,
            projectID: "project-mac",
            provider: .claude,
            profileID: profileID,
            reviewedDigest: review.reviewedDigest,
            explicitExecutionConsent: true,
            explicitScreenCaptureConsent: true,
            grantedBy: "test"
        )) { error in XCTAssertEqual(error as? ActiveExtensionRuntimeError, .inputControlConsentRequired) }
        XCTAssertNoThrow(try store.enable(
            extensionID: configuration.extensionID,
            projectID: "project-mac",
            provider: .claude,
            profileID: profileID,
            reviewedDigest: review.reviewedDigest,
            explicitExecutionConsent: true,
            explicitScreenCaptureConsent: true,
            explicitInputControlConsent: true,
            grantedBy: "test"
        ))
    }

    /// Watchdogs started by this test process, found by the arguments they run with.
    private func watchdogsForThisProcess() throws -> Int {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "command"]
        let output = Pipe()
        ps.standardOutput = output
        try ps.run()
        let listing = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        return listing.split(separator: "\n").filter { $0.contains("agentbridge-watchdog \(getpid()) ") }.count
    }

    func testAnMCPServerInItsOwnGroupIsWatchedOnlyWhileConnected() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try MCPExecutableValidation.resolveAndDigest(pythonExecutable())
        let configuration = try ActiveMCPConfiguration(
            manifest: MCPRuntimeImportManifest(
                id: "fixture.watchdog",
                name: "Watchdog fixture",
                version: "1",
                summary: "Offline fake MCP server",
                command: python.path,
                args: ["-u", "-c", FakeMCPServer.program],
                allowedTools: ["echo"],
                startupTimeoutSeconds: 10,
                toolTimeoutSeconds: 10,
                maximumToolCallsPerRun: 2,
                maximumToolResponseBytes: 4 * 1_024 * 1_024,
                maximumTotalToolResponseBytes: 5 * 1_024 * 1_024
            ),
            sourceReference: "offline test fixture",
            resolvedExecutablePath: python.path,
            executableDigest: python.digest
        )
        let before = try watchdogsForThisProcess()
        for createsProcessGroup in [true, false] {
            let connection = try MCPStdioConnection(
                configuration: configuration,
                environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
                createsProcessGroup: createsProcessGroup
            )
            _ = try connection.initializeAndListTools()
            // A server sharing a provider run's group is covered by that run's watchdog.
            XCTAssertEqual(try watchdogsForThisProcess(), before + (createsProcessGroup ? 1 : 0))
            connection.close()
            XCTAssertEqual(try watchdogsForThisProcess(), before, "The watchdog outlived its connection.")
        }
    }

    func testOfflineMCPWireClientHandlesPaginationCallsAndImageContent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try MCPExecutableValidation.resolveAndDigest(pythonExecutable())
        let configuration = try ActiveMCPConfiguration(
            manifest: MCPRuntimeImportManifest(
                id: "fixture.wire",
                name: "Wire fixture",
                version: "1",
                summary: "Offline fake MCP server",
                command: python.path,
                args: ["-u", "-c", FakeMCPServer.program],
                allowedTools: ["echo", "image_echo"],
                startupTimeoutSeconds: 10,
                toolTimeoutSeconds: 10,
                maximumToolCallsPerRun: 2,
                maximumToolResponseBytes: 4 * 1_024 * 1_024,
                maximumTotalToolResponseBytes: 5 * 1_024 * 1_024
            ),
            sourceReference: "offline test fixture",
            resolvedExecutablePath: python.path,
            executableDigest: python.digest
        )
        let connection = try MCPStdioConnection(
            configuration: configuration,
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
            createsProcessGroup: true
        )
        defer { connection.close() }

        XCTAssertEqual(try connection.initializeAndListTools(), ["echo", "image_echo", "slow"])
        let definitions = try JSONSerialization.jsonObject(with: connection.listToolDefinitions()) as? [String: Any]
        XCTAssertEqual((definitions?["tools"] as? [[String: Any]])?.count, 3)
        let echoArgs = try JSONSerialization.data(withJSONObject: ["text": "bounded hello"])
        let echoReply = try connection.callTool(name: "echo", argumentsJSON: echoArgs)
        let echoJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: echoReply) as? [String: Any])
        let echoContent = try XCTUnwrap(echoJSON["content"] as? [[String: Any]])
        XCTAssertEqual(echoContent.first?["text"] as? String, "echo:bounded hello")

        let imageReply = try connection.callTool(name: "image_echo", argumentsJSON: Data("{}".utf8))
        let imageJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: imageReply) as? [String: Any])
        let imageContent = try XCTUnwrap(imageJSON["content"] as? [[String: Any]])
        XCTAssertEqual(imageContent.first?["type"] as? String, "image")
        let base64 = try XCTUnwrap(imageContent.first?["data"] as? String)
        XCTAssertEqual(Data(base64Encoded: base64)?.count, 2 * 1_024 * 1_024)
        XCTAssertThrowsError(try connection.callTool(name: "unapproved", argumentsJSON: Data("{}".utf8)))

        let limitedConfiguration = try ActiveMCPConfiguration(
            manifest: MCPRuntimeImportManifest(
                id: "fixture.wire-limited",
                name: "Wire fixture limited",
                version: "1",
                summary: "Response above the per-call cap must fail.",
                command: python.path,
                args: ["-u", "-c", FakeMCPServer.program],
                allowedTools: ["echo", "image_echo", "slow"],
                startupTimeoutSeconds: 10,
                toolTimeoutSeconds: 10,
                maximumToolCallsPerRun: 1,
                maximumToolResponseBytes: 1 * 1_024 * 1_024,
                maximumTotalToolResponseBytes: 1 * 1_024 * 1_024
            ),
            sourceReference: "offline test fixture",
            resolvedExecutablePath: python.path,
            executableDigest: python.digest
        )
        let limitedConnection = try MCPStdioConnection(
            configuration: limitedConfiguration,
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
            createsProcessGroup: true
        )
        defer { limitedConnection.close() }
        XCTAssertThrowsError(try limitedConnection.callTool(name: "image_echo", argumentsJSON: Data("{}".utf8)))
    }

    func testMCPConnectionCancellationStopsWaitingForToolResponse() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try MCPExecutableValidation.resolveAndDigest(pythonExecutable())
        let configuration = try ActiveMCPConfiguration(
            manifest: MCPRuntimeImportManifest(
                id: "fixture.cancel",
                name: "Cancellation fixture",
                version: "1",
                summary: "An offline MCP response that never arrives promptly.",
                command: python.path,
                args: ["-u", "-c", FakeMCPServer.program],
                allowedTools: ["slow"],
                startupTimeoutSeconds: 10,
                toolTimeoutSeconds: 20,
                maximumToolCallsPerRun: 1,
                maximumToolResponseBytes: 64 * 1_024,
                maximumTotalToolResponseBytes: 64 * 1_024
            ),
            sourceReference: "offline cancellation fixture",
            resolvedExecutablePath: python.path,
            executableDigest: python.digest
        )
        let cancellation = CancellationFlag()
        let connection = try MCPStdioConnection(
            configuration: configuration,
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
            cancellation: cancellation,
            createsProcessGroup: true
        )
        XCTAssertEqual(try connection.initializeAndListTools(), ["echo", "image_echo", "slow"])
        let request = Task.detached {
            try connection.callTool(name: "slow", argumentsJSON: Data("{}".utf8))
        }
        try await Task.sleep(for: .milliseconds(150))
        cancellation.cancel()
        let outcome = await request.result
        connection.close()
        if case .success = outcome { XCTFail("Cancelled MCP call unexpectedly succeeded.") }
    }

    func testMCPInputSocketSuppressesSIGPIPEWhenServerClosesStdin() throws {
        var pair = try MCPStdioConnection.makeInputSocketPair()
        defer { for descriptor in pair where descriptor >= 0 { _ = close(descriptor) } }

        var blockedSignals = sigset_t()
        var originalSignals = sigset_t()
        sigemptyset(&blockedSignals)
        sigaddset(&blockedSignals, SIGPIPE)
        XCTAssertEqual(pthread_sigmask(SIG_BLOCK, &blockedSignals, &originalSignals), 0)
        var generatedSIGPIPE = false
        defer {
            var pendingSignals = sigset_t()
            _ = sigpending(&pendingSignals)
            generatedSIGPIPE = sigismember(&pendingSignals, SIGPIPE) == 1
            if generatedSIGPIPE {
                var receivedSignal: Int32 = 0
                _ = sigwait(&blockedSignals, &receivedSignal)
            }
            _ = pthread_sigmask(SIG_SETMASK, &originalSignals, nil)
            XCTAssertFalse(generatedSIGPIPE)
        }

        _ = close(pair[1])
        pair[1] = -1
        var byte: UInt8 = 0
        let written = withUnsafeBytes(of: &byte) { bytes in
            Darwin.write(pair[0], bytes.baseAddress!, bytes.count)
        }
        XCTAssertEqual(written, -1)
        XCTAssertEqual(errno, EPIPE)
    }

    func testMCPConnectionSurvivesServerClosingStdinDuringLargeRequest() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = try MCPExecutableValidation.resolveAndDigest(pythonExecutable())
        let configuration = try ActiveMCPConfiguration(
            manifest: MCPRuntimeImportManifest(
                id: "fixture.closed-stdin",
                name: "Closed stdin fixture",
                version: "1",
                summary: "Close the client input while it is sending a bounded request.",
                command: python.path,
                args: ["-u", "-c", EarlyCloseMCPServer.program],
                allowedTools: ["echo"],
                startupTimeoutSeconds: 5,
                toolTimeoutSeconds: 5,
                maximumToolCallsPerRun: 1,
                maximumToolResponseBytes: 64 * 1_024,
                maximumTotalToolResponseBytes: 64 * 1_024
            ),
            sourceReference: "offline early-close fixture",
            resolvedExecutablePath: python.path,
            executableDigest: python.digest
        )
        let connection = try MCPStdioConnection(
            configuration: configuration,
            environment: ["HOME": root.path, "PATH": "/usr/bin:/bin"],
            createsProcessGroup: true
        )
        defer { connection.close() }
        XCTAssertEqual(try connection.initializeAndListTools(), ["echo"])
        let arguments = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "x", count: 512 * 1_024)])
        XCTAssertThrowsError(try connection.callTool(name: "echo", argumentsJSON: arguments))
    }

    func testClaudeMCPToolAliasLengthIsRejectedInsteadOfSilentlyDroppingAllowlist() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try MCPExecutableValidation.resolveAndDigest("/usr/bin/true")
        let longName = String(repeating: "a", count: 110)
        let configuration = try ActiveMCPConfiguration(
            manifest: MCPRuntimeImportManifest(
                id: "example.long-tools",
                name: "Long tool fixture",
                version: "1",
                summary: "The Claude MCP alias exceeds its supported length.",
                command: executable.path,
                args: [],
                allowedTools: [longName]
            ),
            sourceReference: "offline provider configuration fixture",
            resolvedExecutablePath: executable.path,
            executableDigest: executable.digest
        )
        let server = try MCPServerCommandConfiguration(
            configuration: configuration,
            proxyExecutablePath: executable.path,
            ticketURL: root.appendingPathComponent("ticket.json"),
            receiptURL: root.appendingPathComponent("receipt.json"),
            ticketID: UUID(),
            inspectionDigest: configuration.configurationDigest
        )
        XCTAssertThrowsError(try ProviderCommandBuilder.claudeReadOnlyArguments(
            workspacePath: root.path,
            sessionID: UUID(),
            activeMCPServers: [server],
            mcpWorkingDirectory: root.path
        ))
    }

    func testClaudeMCPNamesStayOutOfBuiltinToolsFlagAndInExactAllowedTools() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = try MCPExecutableValidation.resolveAndDigest("/usr/bin/true")
        let manifest = try MCPRuntimeImportManifest(
            id: "example.claude-tools",
            name: "Claude tool flag fixture",
            version: "1",
            summary: "Check Claude's built-in and MCP tool flags independently.",
            command: executable.path,
            args: [],
            allowedTools: ["read", "search"]
        )
        let configuration = try ActiveMCPConfiguration(
            manifest: manifest,
            sourceReference: "offline provider configuration fixture",
            resolvedExecutablePath: executable.path,
            executableDigest: executable.digest
        )
        let server = try MCPServerCommandConfiguration(
            configuration: configuration,
            proxyExecutablePath: executable.path,
            ticketURL: root.appendingPathComponent("ticket.json"),
            receiptURL: root.appendingPathComponent("receipt.json"),
            ticketID: UUID(),
            inspectionDigest: configuration.configurationDigest
        )
        let approvedMCPNames = [
            "mcp__\(server.serverID)__read",
            "mcp__\(server.serverID)__search"
        ]

        func assertClaudeArguments(
            _ arguments: [String],
            builtInTools: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let toolsIndex = try XCTUnwrap(arguments.firstIndex(of: "--tools"), file: file, line: line)
            XCTAssertEqual(arguments[toolsIndex + 1], builtInTools, file: file, line: line)
            XCTAssertFalse(arguments[toolsIndex + 1].contains("mcp__"), file: file, line: line)

            let allowedIndex = try XCTUnwrap(arguments.firstIndex(of: "--allowedTools"), file: file, line: line)
            let allowedNames = Array(arguments.dropFirst(allowedIndex + 1).prefix { !$0.hasPrefix("--") })
            XCTAssertEqual(allowedNames, approvedMCPNames, file: file, line: line)
        }

        try assertClaudeArguments(
            ProviderCommandBuilder.claudeReadOnlyArguments(
                workspacePath: root.path,
                sessionID: UUID(),
                activeMCPServers: [server],
                mcpWorkingDirectory: root.path
            ),
            builtInTools: "Read,Glob,Grep"
        )
        try assertClaudeArguments(
            ProviderCommandBuilder.claudeChangeArguments(
                workspacePath: root.path,
                sessionID: UUID(),
                activeMCPServers: [server],
                mcpWorkingDirectory: root.path
            ),
            builtInTools: "Read,Glob,Grep,Edit,Write"
        )
        try assertClaudeArguments(
            ProviderCommandBuilder.claudeAPIArguments(
                workspacePath: root.path,
                budgetUSD: 1,
                activeMCPServers: [server],
                mcpWorkingDirectory: root.path
            ),
            builtInTools: "Read,Glob,Grep"
        )
    }

    func testCodexMCPArgumentsQuoteCommandTicketAndEnvironmentValues() throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("AgentBridge MCP \"quoted\"-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace \"quoted\".directory", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let executable = try MCPExecutableValidation.resolveAndDigest("/usr/bin/true")
        let configuration = try ActiveMCPConfiguration(
            manifest: MCPRuntimeImportManifest(
                id: "example.toml",
                name: "TOML fixture",
                version: "1",
                summary: "Exercise per-run TOML string escaping.",
                command: executable.path,
                args: [],
                allowedTools: ["read"]
            ),
            sourceReference: "offline TOML fixture",
            resolvedExecutablePath: executable.path,
            executableDigest: executable.digest
        )
        let proxyPath = root.appendingPathComponent("agentbridge \"proxy\"").path
        let ticketPath = root.appendingPathComponent("ticket \"quoted\".json").path
        let server = try MCPServerCommandConfiguration(
            configuration: configuration,
            proxyExecutablePath: proxyPath,
            ticketURL: URL(fileURLWithPath: ticketPath),
            receiptURL: root.appendingPathComponent("receipt.json"),
            ticketID: UUID(),
            inspectionDigest: configuration.configurationDigest
        )
        let environmentValue = "quote \" slash \\ and newline\n"
        let mcpWorkingDirectory = root.appendingPathComponent("mcp cwd \"quoted\".directory", isDirectory: true).path
        let arguments = try ProviderCommandBuilder.codexRunArguments(
            workspacePath: workspace.path,
            activeMCPServers: [server],
            mcpWorkingDirectory: mcpWorkingDirectory,
            mcpEnvironment: ["FIXTURE_VALUE": environmentValue]
        )
        let escapedWorkspace = workspace.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let projectTrust = try XCTUnwrap(arguments.first { $0.hasPrefix("projects.") })
        XCTAssertEqual(projectTrust, "projects.\"\(escapedWorkspace)\".trust_level=\"untrusted\"")

        let mcpAssignments = arguments.filter { $0.hasPrefix("mcp_servers=") }
        XCTAssertEqual(mcpAssignments.count, 1)
        let serverTable = try XCTUnwrap(mcpAssignments.first)
        XCTAssertTrue(serverTable.contains("\(server.serverID) = {"))
        let escapedWorkingDirectory = mcpWorkingDirectory
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        XCTAssertTrue(serverTable.contains("cwd = \"\(escapedWorkingDirectory)\""))
        let escapedProxyPath = proxyPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTicketPath = ticketPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        XCTAssertTrue(serverTable.contains("command = \"\(escapedProxyPath)\""))
        XCTAssertTrue(serverTable.contains("args = [\"mcp-proxy\", \"--ticket\", \"\(escapedTicketPath)\"]"))
        let escapedEnvironmentValue = environmentValue
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        XCTAssertTrue(serverTable.contains("env = { FIXTURE_VALUE = \"\(escapedEnvironmentValue)\" }"))
        XCTAssertTrue(serverTable.contains("enabled_tools = [\"read\"]"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("mcp_servers.\(server.serverID).") })

        let changeArguments = try ProviderCommandBuilder.codexChangeArguments(
            workspacePath: workspace.path,
            activeMCPServers: [server],
            mcpWorkingDirectory: mcpWorkingDirectory,
            mcpEnvironment: ["FIXTURE_VALUE": environmentValue]
        )
        XCTAssertEqual(changeArguments.first { $0.hasPrefix("projects.") }, projectTrust)
        XCTAssertEqual(changeArguments.filter { $0.hasPrefix("mcp_servers=") }, [serverTable])
    }

    func testCodexManagedCallsDisableWorkspaceProjectConfigurationWithoutActiveMCP() throws {
        let workspacePath = "/tmp/AgentBridge managed \"quoted\".workspace"
        let expectedTrust = "projects.\"/tmp/AgentBridge managed \\\"quoted\\\".workspace\".trust_level=\"untrusted\""

        let readOnly = try ProviderCommandBuilder.codexRunArguments(workspacePath: workspacePath)
        let changes = try ProviderCommandBuilder.codexChangeArguments(workspacePath: workspacePath)
        for arguments in [readOnly, changes] {
            XCTAssertTrue(arguments.contains("--ignore-user-config"))
            XCTAssertEqual(arguments.filter { $0.hasPrefix("projects.") }, [expectedTrust])
            XCTAssertFalse(arguments.contains { $0.hasPrefix("mcp_servers=") })
        }
    }

    func testMCPRunControlPlaneIsPrivateAndOutsideProviderWriteRoots() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspaces/project", isDirectory: true)
        let providerTemporaryDirectory = root.appendingPathComponent("tmp/provider-run", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: providerTemporaryDirectory, withIntermediateDirectories: true)

        let lease = try MCPRunDirectoryLease(
            applicationSupportRoot: root,
            providerWriteRoots: [workspace, providerTemporaryDirectory]
        )
        let ticketID = UUID()
        let ticketURL = lease.directoryURL.appendingPathComponent("ticket-\(ticketID.uuidString.lowercased()).json")
        let receiptURL = lease.directoryURL.appendingPathComponent("receipt-\(ticketID.uuidString.lowercased()).json")
        let proxyHomeURL = lease.directoryURL.appendingPathComponent("proxy-home-\(ticketID.uuidString.lowercased())", isDirectory: true)

        XCTAssertTrue(lease.directoryURL.path.hasPrefix(root.appendingPathComponent("mcp-runs").path + "/"))
        for controlPath in [lease.directoryURL, ticketURL, receiptURL, proxyHomeURL] {
            XCTAssertFalse(controlPath.path == workspace.path || controlPath.path.hasPrefix(workspace.path + "/"))
            XCTAssertFalse(controlPath.path == providerTemporaryDirectory.path || controlPath.path.hasPrefix(providerTemporaryDirectory.path + "/"))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: lease.directoryURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertThrowsError(try MCPRunDirectoryLease(applicationSupportRoot: root, providerWriteRoots: [root]))

        lease.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.directoryURL.path))
    }

    private func pythonExecutable() throws -> String {
        let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("A local Python 3 executable is required for the offline stdio fixture.")
        }
        return path
    }

    private func temporaryDirectory() throws -> URL {
        // Foundation's URL path helpers keep macOS's `/var` alias in this
        // XCTest environment. The file readers intentionally reject every
        // symlink path component, so anchor fixtures at realpath's canonical
        // temporary directory path.
        var canonicalPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolvedPath = FileManager.default.temporaryDirectory.path.withCString {
            realpath($0, &canonicalPath)
        }
        guard resolvedPath != nil else {
            throw AgentBridgeError.persistence("Could not resolve the test temporary directory.")
        }
        let temporaryRoot = URL(fileURLWithPath: String(cString: canonicalPath), isDirectory: true)
        let root = temporaryRoot
            .appendingPathComponent("AgentBridge-ActiveExtensions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(root.path, 0o700), 0)
        return root
    }

    private func toolDefinitionsJSON(names: [String]) throws -> String {
        let tools = names.map { [
            "name": $0,
            "description": "Fixture description for \($0)",
            "inputSchema": ["type": "object"]
        ] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["tools": tools], options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func runGit(_ arguments: [String]) throws {
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
                domain: "ActiveExtensionRuntimeTests.Git",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)]
            )
        }
    }
}

private enum FakeMCPServer {
    static let program = #"""
# coding: utf-8
import json, sys
for line in sys.stdin:
    try:
        message = json.loads(line)
    except Exception:
        continue
    method = message.get("method")
    request_id = message.get("id")
    if request_id is None:
        continue
    if method == "initialize":
        result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "offline-fixture", "version": "1"}}
    elif method == "tools/list":
        if message.get("params", {}).get("cursor") is None:
            result = {"tools": [{"name": "echo", "description": "Echo input", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}], "nextCursor": "page-two"}
        elif message["params"].get("cursor") == "page-two":
            result = {"tools": [{"name": "image_echo", "description": "Return image data", "inputSchema": {"type": "object"}}, {"name": "slow", "description": "Wait before returning", "inputSchema": {"type": "object"}}]}
        else:
            result = {"tools": []}
    elif method == "tools/call":
        name = message.get("params", {}).get("name")
        if name == "echo":
            value = message["params"].get("arguments", {}).get("text", "")
            result = {"content": [{"type": "text", "text": "echo:" + value}], "isError": False}
        elif name == "image_echo":
            import base64
            payload = base64.b64encode(b"x" * (2 * 1024 * 1024)).decode()
            result = {"content": [{"type": "image", "data": payload, "mimeType": "image/png"}], "isError": False}
        elif name == "slow":
            import time
            time.sleep(20)
            result = {"content": [{"type": "text", "text": "late"}], "isError": False}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "unknown tool"}}), flush=True)
            continue
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "unsupported"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}, separators=(",", ":")), flush=True)
"""#
}

private enum EarlyCloseMCPServer {
    static let program = #"""
import json, os, sys, time
def next_message():
    data = bytearray()
    while True:
        byte = os.read(0, 1)
        if not byte:
            return None
        data.extend(byte)
        if b'tools/call' in data:
            os.close(0)
            time.sleep(1)
            os._exit(0)
        if byte == b'\n':
            return json.loads(data)
def reply(request_id, result):
    sys.stdout.write(json.dumps({"jsonrpc":"2.0", "id":request_id, "result":result}, separators=(",", ":")) + "\n")
    sys.stdout.flush()
while True:
    message = next_message()
    if message is None:
        break
    method = message.get("method")
    request_id = message.get("id")
    if request_id is None:
        continue
    if method == "initialize":
        reply(request_id, {"protocolVersion":"2025-03-26", "capabilities":{"tools":{}}, "serverInfo":{"name":"early-close", "version":"1"}})
    elif method == "tools/list":
        reply(request_id, {"tools":[{"name":"echo", "description":"Echo", "inputSchema":{"type":"object"}}]})
    else:
        reply(request_id, {"content":[{"type":"text", "text":"unexpected"}], "isError":False})
"""#
}
