import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class LocalPatchModeTests: XCTestCase {
    func testStrictPatchParserAcceptsSchemaAndRejectsMalformedOrUnsafeResponses() throws {
        let accepted = #"{"summary":"Updated one file","files":[{"path":"src/main.swift","action":"modify","content":"print(\"ok\")\n"},{"path":"docs/new.md","action":"create","content":"hello"},{"path":"old.txt","action":"delete","content":null}]}"#
        let parsed = try LocalPatchResponseParser.parse(accepted)
        XCTAssertEqual(parsed.summary, "Updated one file")
        XCTAssertEqual(parsed.files.map(\.action), [.modify, .create, .delete])
        XCTAssertNil(parsed.files.last?.content)

        let fences = String(repeating: String(UnicodeScalar(96)!), count: 3)
        let malformed = [
            #"{"summary":"a","summary":"b","files":[]}"#,
            #"{"summary":"a","files":[],"extra":true}"#,
            fences + "json\n{\"summary\":\"a\",\"files\":[]}\n" + fences,
            #"{"summary":"a","files":[{"path":"x","action":"delete","content":"not allowed"}]}"#,
            #"{"summary":"a","files":[{"path":"x","action":"modify"}]}"#,
            #"{"summary":"a","files":[{"path":"x","action":"modify","content":"a"},{"path":"x","action":"delete"}]}"#,
            #"{"summary":"a","files":[{"path":"/absolute","action":"create","content":"a"}]}"#,
            #"{"summary":"a","files":[{"path":"../outside","action":"create","content":"a"}]}"#,
            #"{"summary":"a","files":[{"path":".git/config","action":"create","content":"a"}]}"#,
            #"{"summary":"a","files":[{"path":"x","action":"modify","content":"a","unexpected":1}]}"#
        ]
        for value in malformed {
            XCTAssertThrowsError(try LocalPatchResponseParser.parse(value), "Accepted malformed response: \(value)")
        }

        let nul = String(UnicodeScalar(0)!)
        let nulResponse = try jsonString(["summary": "x", "files": [["path": "x", "action": "modify", "content": "a\(nul)b"]]])
        XCTAssertThrowsError(try LocalPatchResponseParser.parse(nulResponse))

        let tooLarge = String(repeating: "x", count: LocalPatchResponseParser.maximumFileBytes + 1)
        let largeResponse = try jsonString(["summary": "x", "files": [["path": "x", "action": "create", "content": tooLarge]]])
        XCTAssertThrowsError(try LocalPatchResponseParser.parse(largeResponse))

        let maxContent = String(repeating: "x", count: LocalPatchResponseParser.maximumFileBytes)
        var totalEntries: [[String: String]] = (0..<4).map { ["path": "file-\($0)", "action": "create", "content": maxContent] }
        totalEntries.append(["path": "file-extra", "action": "create", "content": "x"])
        XCTAssertThrowsError(try LocalPatchResponseParser.parse(jsonString(["summary": "x", "files": totalEntries])))
        let tooManyEntries = (0...LocalPatchResponseParser.maximumFiles).map {
            ["path": "file-\($0)", "action": "create", "content": ""]
        }
        XCTAssertThrowsError(try LocalPatchResponseParser.parse(jsonString(["summary": "x", "files": tooManyEntries])))

    }

    func testSelectedPathRulesAtomicWritesAndRollback() throws {
        let root = try makeRoot("LocalPatchPaths")
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = root.appendingPathComponent("selected.txt")
        let unselected = root.appendingPathComponent("unselected.txt")
        try Data("original\n".utf8).write(to: selected)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: selected.path)
        try Data("leave me\n".utf8).write(to: unselected)
        let target = root.appendingPathComponent("target.txt")
        try Data("target\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.txt").path, withDestinationPath: target.path)
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link-dir").path, withDestinationPath: linkedDirectory.path)
        try Data([0xFF, 0xFE]).write(to: root.appendingPathComponent("binary.txt"))

        XCTAssertThrowsError(try LocalPatchWorkspace.readText(path: "link.txt", root: root))
        XCTAssertThrowsError(try LocalPatchWorkspace.readText(path: "link-dir/target.txt", root: root))
        XCTAssertThrowsError(try LocalPatchWorkspace.readText(path: "binary.txt", root: root))
        XCTAssertFalse(LocalPatchWorkspace.isNormalizedRelativePath("/absolute"))
        XCTAssertFalse(LocalPatchWorkspace.isNormalizedRelativePath("a/../b"))
        XCTAssertFalse(LocalPatchWorkspace.isNormalizedRelativePath(".git/config"))

        try LocalPatchWorkspace.writeAll(
            [
                LocalPatchFileOutput(path: "selected.txt", action: .modify, content: "patched\n"),
                LocalPatchFileOutput(path: "nested/new.txt", action: .create, content: "new\n")
            ],
            selectedPaths: ["selected.txt"],
            newPaths: ["nested/new.txt"],
            expectedFileContents: ["selected.txt": Data("original\n".utf8)],
            root: root
        )
        XCTAssertEqual(try Data(contentsOf: selected), Data("patched\n".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("nested/new.txt")), Data("new\n".utf8))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: selected.path)[.posixPermissions] as? NSNumber, NSNumber(value: 0o640))

        assertRejected {
            try LocalPatchWorkspace.writeAll(
                [LocalPatchFileOutput(path: "unselected.txt", action: .modify, content: "bad")],
                selectedPaths: ["selected.txt"],
                newPaths: [],
                expectedFileContents: ["selected.txt": Data("patched\n".utf8)],
                root: root
            )
        }
        assertRejected {
            try LocalPatchWorkspace.writeAll(
                [
                    LocalPatchFileOutput(path: "selected.txt", action: .modify, content: "partial"),
                    LocalPatchFileOutput(path: "unselected.txt", action: .modify, content: "bad")
                ],
                selectedPaths: ["selected.txt"],
                newPaths: [],
                expectedFileContents: ["selected.txt": Data("patched\n".utf8)],
                root: root
            )
        }
        XCTAssertEqual(try Data(contentsOf: selected), Data("patched\n".utf8), "Validation must reject the entire response before the first write.")
        assertRejected {
            try LocalPatchWorkspace.writeAll(
                [LocalPatchFileOutput(path: "selected.txt", action: .delete, content: nil)],
                selectedPaths: [],
                newPaths: [],
                expectedFileContents: [:],
                root: root
            )
        }
        assertRejected {
            try LocalPatchWorkspace.writeAll(
                [LocalPatchFileOutput(path: "selected.txt", action: .create, content: "overwrite")],
                selectedPaths: [],
                newPaths: ["selected.txt"],
                expectedFileContents: [:],
                root: root
            )
        }

        let blocked = root.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }
        do {
            try LocalPatchWorkspace.writeAll(
                [
                    LocalPatchFileOutput(path: "selected.txt", action: .modify, content: "must roll back\n"),
                    LocalPatchFileOutput(path: "blocked/new.txt", action: .create, content: "cannot write")
                ],
                selectedPaths: ["selected.txt"],
                newPaths: ["blocked/new.txt"],
                expectedFileContents: ["selected.txt": Data("patched\n".utf8)],
                root: root
            )
            XCTFail("The second write should fail so the first write is rolled back.")
        } catch let error as LocalPatchApplicationError {
            XCTAssertEqual(error, .writeFailed(rollbackFailed: false))
        }
        XCTAssertEqual(try Data(contentsOf: selected), Data("patched\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocked.appendingPathComponent("new.txt").path))
    }

    private func assertRejected(_ operation: () throws -> Void, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), line: line) { error in
            XCTAssertTrue(error is LocalPatchApplicationError, "Unexpected error: \(error)", line: line)
        }
    }

    private func jsonString(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeRoot(_ prefix: String) throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = packageRoot.appendingPathComponent("build/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
}

final class LocalPatchServiceTests: XCTestCase {
    func testLocalPlanGateSelectedFileRunFixRoundAndAuditAccounting() async throws {
        let root = try makeRoot("LocalPatchService")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("Original README\n".utf8).write(to: source.appendingPathComponent("README.md"))
        try Data("private marker content\n".utf8).write(to: source.appendingPathComponent("private.txt"))
        let ci = source.appendingPathComponent(".codex/ci.sh")
        try FileManager.default.createDirectory(at: ci.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: ci)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ci.path)
        try FixtureGit.run(["init", "-q", source.path])
        try FixtureGit.run(["-C", source.path, "add", "README.md", "private.txt", ".codex/ci.sh"])
        try FixtureGit.run(["-C", source.path, "commit", "-q", "-m", "initial"])

        let draft = #"{"title":"Update README","summary":"Refresh the selected project overview.","steps":["Rewrite README.md using its current content."]}"#
        let patch = #"{"summary":"Updated README and added a result note.","files":[{"path":"README.md","action":"modify","content":"Updated README\n"},{"path":"docs/result.md","action":"create","content":"Local patch result\n"}]}"#
        let fix = #"{"summary":"Fixed the verification failure.","files":[{"path":"README.md","action":"modify","content":"Verified README\n"},{"path":"docs/result.md","action":"delete"}]}"#
        let replies = ReplyQueue([
            try ollamaStream(draft),
            try ollamaStream(patch),
            try ollamaStream(fix)
        ])
        let modelList = Data(#"{"models":[{"name":"fixture-local"}]}"#.utf8)
        let server = try LoopbackHTTPServer { request in
            request.method == "GET" ? .json(modelList) : .stream(replies.next())
        }
        defer { server.stop() }

        let dataRoot = root.appendingPathComponent("workspace-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let store = try AuditStore(
            rootURL: root.appendingPathComponent("state", isDirectory: true),
            workspaceRootURL: dataRoot,
            managedWorkspaceRoots: []
        )
        let service = try BridgeService(store: store)
        var settings = try service.settings()
        settings.defaultProvider = .claude
        settings.usageMode = .api
        settings.localModel = LocalModelSettings(
            backend: .ollama,
            endpoint: "http://127.0.0.1:\(server.port)",
            model: "fixture-local",
            contextWindowTokens: 8_192,
            maxOutputTokens: 1_024
        )
        try service.saveSettings(settings)
        let session = try await service.createSession(sourcePath: source.path, provider: .local, accessMode: .isolatedChanges)
        XCTAssertEqual(session.policy.accessMode, .isolatedChanges)
        XCTAssertFalse(session.policy.workspaceReadOnly)
        XCTAssertEqual(try service.settings().usageMode, .api, "Local isolated changes must not require or change subscription mode.")

        let drafted = try await service.draftChangePlan(sessionID: session.id, request: "Update the README from the selected file.")
        XCTAssertEqual(drafted.title, "Update README")
        let planRequest = try XCTUnwrap(server.requests.last?.jsonBody)
        let planPrompt = try XCTUnwrap((planRequest["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertTrue(planPrompt.contains("README.md"))
        XCTAssertTrue(planPrompt.contains("private.txt"))
        XCTAssertFalse(planPrompt.contains("private marker content"))

        let plan = try service.createChangePlan(sessionID: session.id, title: drafted.title, summary: drafted.summary, steps: drafted.steps)
        let noFiles = Set(try await service.localChangeFileCandidates(sessionID: session.id).map(\.path))
        XCTAssertEqual(noFiles, [".codex/ci.sh", "README.md", "private.txt"])
        do {
            _ = try await service.previewLocalChangeInput(
                sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest,
                request: "Update it.", filePaths: ["README.md"], newFilePaths: ["docs/result.md"]
            )
            XCTFail("The plan gate must apply to previews too.")
        } catch let error as AgentBridgeError {
            guard case .changePlanRequired = error else { return XCTFail("Unexpected preview error: \(error)") }
        }
        do {
            _ = try await service.runLocalChanges(
                sessionID: session.id, request: "Update it.", planID: plan.id,
                reviewedDigest: plan.reviewDigest, filePaths: ["README.md"]
            )
            XCTFail("An unapproved Local plan ran.")
        } catch let error as AgentBridgeError {
            guard case .changePlanRequired = error else { return XCTFail("Unexpected run error: \(error)") }
        }
        XCTAssertEqual(server.requests.count, 2, "Plan-gate failures must not contact the model.")

        _ = try service.approveChangePlan(sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest)
        var tinyBudgetSettings = try service.settings()
        tinyBudgetSettings.localModel.contextWindowTokens = 1_024
        tinyBudgetSettings.localModel.maxOutputTokens = 511
        try service.saveSettings(tinyBudgetSettings)
        let overBudget = try await service.previewLocalChangeInput(
            sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest,
            request: "This request cannot fit.", filePaths: ["README.md"]
        )
        XCTAssertFalse(overBudget.fitsBudget)
        XCTAssertEqual(overBudget.budgetBytes, 1)
        do {
            _ = try await service.runLocalChanges(
                sessionID: session.id, request: "This request cannot fit.", planID: plan.id,
                reviewedDigest: plan.reviewDigest, filePaths: ["README.md"]
            )
            XCTFail("An over-budget Local prompt must be refused before contacting the server.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput(let message) = error, message.contains("over budget by") else {
                return XCTFail("Unexpected budget error: \(error)")
            }
        }
        XCTAssertEqual(server.requests.count, 2, "Over-budget refusal must happen before model discovery.")
        var normalBudgetSettings = try service.settings()
        normalBudgetSettings.localModel.contextWindowTokens = 8_192
        normalBudgetSettings.localModel.maxOutputTokens = 1_024
        try service.saveSettings(normalBudgetSettings)
        let candidates = try await service.localChangeFileCandidates(sessionID: session.id)
        XCTAssertTrue(candidates.first(where: { $0.path == "README.md" })?.isSelectable == true)
        let preview = try await service.previewLocalChangeInput(
            sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest,
            request: "Update the README.", filePaths: ["README.md"], newFilePaths: ["docs/result.md"]
        )
        XCTAssertTrue(preview.fitsBudget)
        XCTAssertEqual(preview.files.map(\.path), ["README.md"])
        XCTAssertGreaterThan(preview.files[0].byteCount, 0)
        XCTAssertEqual(server.requests.count, 2, "Preview must not send a request.")

        let run = try await service.runLocalChanges(
            sessionID: session.id, request: "Update the README.", planID: plan.id,
            reviewedDigest: plan.reviewDigest, filePaths: ["README.md"], newFilePaths: ["docs/result.md"]
        )
        XCTAssertEqual(run.summary, "Updated README and added a result note.")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: session.workspacePath).appendingPathComponent("README.md"), encoding: .utf8), "Updated README\n")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: session.workspacePath).appendingPathComponent("docs/result.md"), encoding: .utf8), "Local patch result\n")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("README.md"), encoding: .utf8), "Original README\n")
        let runPrompt = try XCTUnwrap((server.requests.last?.jsonBody?["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertTrue(runPrompt.contains("USER REQUEST"))
        XCTAssertTrue(runPrompt.contains("Original README"))
        XCTAssertFalse(runPrompt.contains("private marker content"))
        XCTAssertTrue(runPrompt.contains(#"{"summary":"what changed","files":[{"path":"relative/path","action":"modify|create|delete","content":"full new file content"}]}"#))

        let diff = try await service.changesDiff(sessionID: session.id)
        XCTAssertEqual(Set(diff.files.map(\.path)), ["README.md", "docs/result.md"])
        var failedVerification = try XCTUnwrap(store.session(id: session.id))
        let changeAt = try XCTUnwrap(failedVerification.lastChangeRunAt)
        failedVerification.verificationPassed = false
        failedVerification.verificationDiffDigest = diff.digest
        failedVerification.verificationCompletedAt = changeAt.addingTimeInterval(1)
        try store.saveSession(failedVerification)
        _ = try service.approveChangePlan(sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest)
        let secretOutput = "verification failed; secret=sk-test-0123456789abcdefghijklmnop\n"
        let fixed = try await service.fixLocalChanges(
            sessionID: session.id,
            failure: LocalHelperVerificationFailure(commandLabel: ".codex/ci.sh", exitCode: 1, output: secretOutput),
            note: "Keep the result focused."
        )
        XCTAssertEqual(fixed.summary, "Fixed the verification failure.")
        let fixPrompt = try XCTUnwrap((server.requests.last?.jsonBody?["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertTrue(fixPrompt.contains("verification failed"))
        XCTAssertTrue(fixPrompt.contains("<redacted>"))
        XCTAssertFalse(fixPrompt.contains("sk-test-0123456789abcdefghijklmnop"))
        XCTAssertTrue(fixPrompt.contains("Keep the result focused."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: session.workspacePath).appendingPathComponent("docs/result.md").path))
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: session.workspacePath).appendingPathComponent("README.md"), encoding: .utf8), "Verified README\n")

        let saved = try XCTUnwrap(store.session(id: session.id))
        XCTAssertEqual(saved.status, .completed)
        XCTAssertNotNil(saved.lastChangeRunAt)
        XCTAssertNil(saved.verificationPassed, "A new Local run invalidates the previous verification.")
        XCTAssertNil(saved.approvedChangePlanDigest, "Every Local round consumes the approval.")
        let usage = try service.usageStatistics(provider: .local, profileID: AccountProfile.defaultID(for: .local), selectedSessionID: session.id)
        XCTAssertEqual(usage.localDailyRuns, 3)
        XCTAssertEqual(usage.localSessionRuns, 3)
        let changeEvents = try store.events(sessionID: session.id).filter { $0.kind.hasPrefix("local.change.") }
        XCTAssertTrue(changeEvents.contains(where: { $0.kind == "local.change.started" }))
        XCTAssertTrue(changeEvents.contains(where: { $0.kind == "local.change.applied" }))
        XCTAssertTrue(changeEvents.allSatisfy { !$0.message.contains("Original README") && !$0.message.contains("Updated README") && !$0.message.contains("verification failed") })

        _ = try service.approveChangePlan(sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest)
        for _ in 0..<(LocalModelClient.defaultSessionRunLimit - usage.localSessionRuns) {
            try store.appendEvent(AuditEvent(sessionID: session.id, kind: "local.run.started", message: "fixture usage-limit attempt"))
        }
        let requestCountBeforeLimit = server.requests.count
        do {
            _ = try await service.runLocalChanges(
                sessionID: session.id, request: "This attempt must be blocked.", planID: plan.id,
                reviewedDigest: plan.reviewDigest, filePaths: ["README.md"]
            )
            XCTFail("The Local per-session limit must be enforced before model discovery.")
        } catch let error as UsageControlError {
            guard case .runLimitReached(window: .currentSession, used: 50, limit: 50) = error else {
                return XCTFail("Unexpected Local usage limit error: \(error)")
            }
        }
        XCTAssertEqual(server.requests.count, requestCountBeforeLimit)
    }

    func testLocalChangeCancellationRecordsCancelledStateWithoutWritingPartialOutput() async throws {
        let root = try makeRoot("LocalPatchCancellation")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("Original\n".utf8).write(to: source.appendingPathComponent("README.md"))
        try FixtureGit.run(["init", "-q", source.path])
        try FixtureGit.run(["-C", source.path, "add", "README.md"])
        try FixtureGit.run(["-C", source.path, "commit", "-q", "-m", "initial"])

        let gate = StallGate()
        let modelList = Data(#"{"models":[{"name":"fixture-local"}]}"#.utf8)
        let server = try LoopbackHTTPServer { request in
            if request.method == "GET" { return .json(modelList) }
            return .stalled(Data(#"{"message":{"role":"assistant","content":"partial"#.utf8), declaredLength: 256, gate: gate)
        }
        defer { server.stop(); gate.release() }

        let dataRoot = root.appendingPathComponent("workspace-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let store = try AuditStore(
            rootURL: root.appendingPathComponent("state", isDirectory: true),
            workspaceRootURL: dataRoot,
            managedWorkspaceRoots: []
        )
        let service = try BridgeService(store: store)
        var settings = try service.settings()
        settings.localModel = LocalModelSettings(
            backend: .ollama,
            endpoint: "http://127.0.0.1:\(server.port)",
            model: "fixture-local",
            contextWindowTokens: 8_192,
            maxOutputTokens: 1_024
        )
        try service.saveSettings(settings)
        let session = try await service.createSession(sourcePath: source.path, provider: .local, accessMode: .isolatedChanges)
        let plan = try service.createChangePlan(sessionID: session.id, title: "Update README", summary: "Replace its text.", steps: ["Update the selected file."])
        _ = try service.approveChangePlan(sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest)

        let cancellation = CancellationFlag()
        let run = Task {
            try await service.runLocalChanges(
                sessionID: session.id,
                request: "Update the README.",
                planID: plan.id,
                reviewedDigest: plan.reviewDigest,
                filePaths: ["README.md"],
                cancellation: cancellation
            )
        }
        XCTAssertTrue(server.waitForRequestCount(2), "The Local request did not reach the fixture server.")
        XCTAssertTrue(gate.waitUntilStarted(), "The fixture response did not stall.")
        cancellation.cancel()
        do {
            _ = try await run.value
            XCTFail("The cancelled Local run returned partial output.")
        } catch let error as AgentBridgeError {
            XCTAssertEqual(error, .processCancelled)
        }

        let saved = try XCTUnwrap(store.session(id: session.id))
        XCTAssertEqual(saved.status, .cancelled)
        XCTAssertNil(saved.lastChangeRunAt, "A cancelled round wrote nothing, so it is not recorded as a change.")
        XCTAssertNil(saved.approvedChangePlanDigest)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: session.workspacePath).appendingPathComponent("README.md"), encoding: .utf8), "Original\n")
        XCTAssertEqual(server.requests.map(\.method), ["GET", "POST"])
        let events = try store.events(sessionID: session.id).filter { $0.kind.hasPrefix("local.change.") }
        XCTAssertTrue(events.contains(where: { $0.kind == "local.change.started" }))
        XCTAssertTrue(events.contains(where: { $0.kind == "local.change.failed" && $0.message.contains("cancelled=true") }))
        XCTAssertTrue(events.allSatisfy { !$0.message.contains("partial") && !$0.message.contains("Update the README") })
        gate.release()
    }

    private func ollamaStream(_ answer: String) throws -> Data {
        let encoder = JSONSerialization.self
        let message = try encoder.data(withJSONObject: ["message": ["role": "assistant", "content": answer], "done": false])
        let done = try encoder.data(withJSONObject: ["prompt_eval_count": 20, "eval_count": 4, "done": true, "done_reason": "stop"])
        var stream = Data()
        stream.append(message)
        stream.append(0x0A)
        stream.append(done)
        stream.append(0x0A)
        return stream
    }

    private func makeRoot(_ prefix: String) throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = packageRoot.appendingPathComponent("build/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
}

/// Review follow-ups: rounds that write nothing keep verification state, the
/// output reserve is checked, previews never hold the run lease, and fixes skip
/// changed files that cannot be sent.
final class LocalPatchRoundStateTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let source: URL
        let store: AuditStore
        let service: BridgeService
        let server: LoopbackHTTPServer
        let session: SessionRecord
        let plan: ChangePlan

        var workspace: URL { URL(fileURLWithPath: session.workspacePath, isDirectory: true) }

        func approve() throws {
            _ = try service.approveChangePlan(sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest)
        }

        func saved() throws -> SessionRecord { try XCTUnwrap(store.session(id: session.id)) }

        var postCount: Int { server.requests.filter { $0.method == "POST" }.count }

        func recordFailedVerification() async throws {
            let diff = try await service.changesDiff(sessionID: session.id)
            var record = try saved()
            let changeAt = try XCTUnwrap(record.lastChangeRunAt)
            record.verificationPassed = false
            record.verificationDiffDigest = diff.digest
            record.verificationCompletedAt = changeAt.addingTimeInterval(1)
            try store.saveSession(record)
        }

        func recordPassedVerificationAndAcceptance() async throws {
            let diff = try await service.changesDiff(sessionID: session.id)
            var record = try saved()
            let changeAt = try XCTUnwrap(record.lastChangeRunAt)
            record.verificationPassed = true
            record.verificationDiffDigest = diff.digest
            record.verificationCompletedAt = changeAt.addingTimeInterval(1)
            record.changesAcceptedAt = changeAt.addingTimeInterval(2)
            try store.saveSession(record)
        }
    }

    private static let failure = LocalHelperVerificationFailure(commandLabel: ".codex/ci.sh", exitCode: 1, output: "fixture failure\n")

    func testRoundsThatWriteNothingKeepVerificationStateAndAFixCanBeRetried() async throws {
        let fixture = try await makeFixture(
            "LocalPatchNoOpRounds",
            files: ["README.md": Data("Original\n".utf8), "other.txt": Data("Other\n".utf8)],
            replies: [
                #"{"summary":"First","files":[{"path":"README.md","action":"modify","content":"First\n"}]}"#,
                "this is not JSON",
                #"{"summary":"Fixed","files":[{"path":"README.md","action":"modify","content":"Fixed\n"}]}"#,
                "still not JSON",
                #"{"summary":"Wrong file","files":[{"path":"other.txt","action":"modify","content":"bad\n"}]}"#
            ]
        )
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }

        _ = try await fixture.service.runLocalChanges(
            sessionID: fixture.session.id, request: "Update the README.", planID: fixture.plan.id,
            reviewedDigest: fixture.plan.reviewDigest, filePaths: ["README.md"]
        )
        try await fixture.recordFailedVerification()
        let failed = try fixture.saved()

        // A fix whose answer is not valid JSON writes nothing.
        try fixture.approve()
        do {
            _ = try await fixture.service.fixLocalChanges(sessionID: fixture.session.id, failure: Self.failure)
            XCTFail("An invalid answer must not be applied.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let afterInvalid = try fixture.saved()
        XCTAssertEqual(afterInvalid.verificationPassed, false, "The workspace is unchanged, so the failed verification still describes it.")
        XCTAssertEqual(afterInvalid.verificationDiffDigest, failed.verificationDiffDigest)
        XCTAssertEqual(afterInvalid.verificationCompletedAt, failed.verificationCompletedAt)
        XCTAssertEqual(afterInvalid.lastChangeRunAt, failed.lastChangeRunAt)
        XCTAssertNil(afterInvalid.approvedChangePlanDigest, "The approval is consumed when the round starts.")
        XCTAssertEqual(afterInvalid.status, .failed)
        XCTAssertEqual(try String(contentsOf: fixture.workspace.appendingPathComponent("README.md"), encoding: .utf8), "First\n")

        // After approving again, the fix can be retried and its write resets the state.
        try fixture.approve()
        let fixed = try await fixture.service.fixLocalChanges(sessionID: fixture.session.id, failure: Self.failure)
        XCTAssertEqual(fixed.summary, "Fixed")
        let afterFix = try fixture.saved()
        XCTAssertNil(afterFix.verificationPassed, "A round that writes invalidates the earlier verification.")
        XCTAssertNil(afterFix.verificationDiffDigest)
        XCTAssertNil(afterFix.verificationCompletedAt)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(afterFix.lastChangeRunAt), try XCTUnwrap(failed.lastChangeRunAt))

        // A verified, accepted workspace keeps that state after rounds that write nothing.
        try await fixture.recordPassedVerificationAndAcceptance()
        let verified = try fixture.saved()
        for _ in 0..<2 {
            try fixture.approve()
            do {
                _ = try await fixture.service.runLocalChanges(
                    sessionID: fixture.session.id, request: "Try again.", planID: fixture.plan.id,
                    reviewedDigest: fixture.plan.reviewDigest, filePaths: ["README.md"]
                )
                XCTFail("An invalid or out-of-scope answer must not be applied.")
            } catch {}
            let unchanged = try fixture.saved()
            XCTAssertEqual(unchanged.verificationPassed, true)
            XCTAssertEqual(unchanged.verificationDiffDigest, verified.verificationDiffDigest)
            XCTAssertEqual(unchanged.verificationCompletedAt, verified.verificationCompletedAt)
            XCTAssertEqual(unchanged.changesAcceptedAt, verified.changesAcceptedAt)
            XCTAssertEqual(unchanged.lastChangeRunAt, verified.lastChangeRunAt)
            XCTAssertNil(unchanged.approvedChangePlanDigest)
        }
        XCTAssertEqual(try String(contentsOf: fixture.workspace.appendingPathComponent("other.txt"), encoding: .utf8), "Other\n")
        XCTAssertEqual(fixture.postCount, 5)
    }

    func testOutputReserveMustHoldTheSelectedFilesInFull() async throws {
        let readme = String(repeating: "r", count: 1_000) + "\n"
        let fixture = try await makeFixture(
            "LocalPatchOutputReserve",
            files: ["README.md": Data(readme.utf8)],
            replies: [],
            maxOutputTokens: 256
        )
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }

        let preview = try await fixture.service.previewLocalChangeInput(
            sessionID: fixture.session.id, planID: fixture.plan.id, reviewedDigest: fixture.plan.reviewDigest,
            request: "Rewrite it.", filePaths: ["README.md"], newFilePaths: ["docs/new.md"]
        )
        let expected = LocalChangeInputPreview.outputResponseAllowanceBytes
            + readme.utf8.count + "README.md".utf8.count + LocalChangeInputPreview.outputFileEntryAllowanceBytes
            + "docs/new.md".utf8.count + LocalChangeInputPreview.outputFileEntryAllowanceBytes
        XCTAssertTrue(preview.fitsBudget)
        XCTAssertEqual(preview.estimatedOutputBytes, expected)
        XCTAssertEqual(preview.outputBudgetBytes, 256)
        XCTAssertFalse(preview.fitsOutputBudget)
        XCTAssertFalse(preview.fitsAllBudgets)
        XCTAssertEqual(preview.overOutputBudgetBytes, expected - 256)

        let before = try fixture.saved()
        do {
            _ = try await fixture.service.runLocalChanges(
                sessionID: fixture.session.id, request: "Rewrite it.", planID: fixture.plan.id,
                reviewedDigest: fixture.plan.reviewDigest, filePaths: ["README.md"], newFilePaths: ["docs/new.md"]
            )
            XCTFail("A round whose answer cannot fit the output reserve must be refused.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput(let message) = error, message.contains("output reserve"), message.contains("--max-output") else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(fixture.server.requests.isEmpty, "The refusal happens before the model is contacted.")
        let after = try fixture.saved()
        XCTAssertEqual(after.approvedChangePlanDigest, before.approvedChangePlanDigest, "A refused round keeps the approval.")
        XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.lastChangeRunAt, before.lastChangeRunAt)
        let rejected = try fixture.store.events(sessionID: fixture.session.id).filter { $0.kind == "local.change.rejected" }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected[0].message.contains("reason=output_over_budget"))
        XCTAssertFalse(rejected[0].message.contains("rrrr"))

        var settings = try fixture.service.settings()
        settings.localModel.maxOutputTokens = 2_048
        try fixture.service.saveSettings(settings)
        let fits = try await fixture.service.previewLocalChangeInput(
            sessionID: fixture.session.id, planID: fixture.plan.id, reviewedDigest: fixture.plan.reviewDigest,
            request: "Rewrite it.", filePaths: ["README.md"], newFilePaths: ["docs/new.md"]
        )
        XCTAssertTrue(fits.fitsOutputBudget)
        XCTAssertEqual(fits.overOutputBudgetBytes, 0)
        XCTAssertTrue(fits.fitsAllBudgets)
    }

    func testPreviewsAndFileListsDoNotTakeTheRunLease() async throws {
        let fixture = try await makeFixture(
            "LocalPatchPreviewLease",
            files: ["README.md": Data("Original\n".utf8)],
            replies: [#"{"summary":"Done","files":[{"path":"README.md","action":"modify","content":"Done\n"}]}"#]
        )
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }

        // While a run holds the lease, previews and the file list still work.
        do {
            let lease = try fixture.store.acquireRunLease(for: fixture.session.id)
            defer { withExtendedLifetime(lease) {} }
            let candidates = try await fixture.service.localChangeFileCandidates(sessionID: fixture.session.id)
            XCTAssertEqual(candidates.map(\.path), ["README.md"])
            let preview = try await fixture.service.previewLocalChangeInput(
                sessionID: fixture.session.id, planID: fixture.plan.id, reviewedDigest: fixture.plan.reviewDigest,
                request: "Update it.", filePaths: ["README.md"]
            )
            XCTAssertEqual(preview.files.map(\.path), ["README.md"])
        }

        // Previews running alongside a run never make it fail.
        let service = fixture.service
        let session = fixture.session
        let plan = fixture.plan
        let previews = Task {
            for _ in 0..<20 {
                _ = try? await service.previewLocalChangeInput(
                    sessionID: session.id, planID: plan.id, reviewedDigest: plan.reviewDigest,
                    request: "Update it.", filePaths: ["README.md"]
                )
            }
        }
        let result = try await service.runLocalChanges(
            sessionID: session.id, request: "Update it.", planID: plan.id,
            reviewedDigest: plan.reviewDigest, filePaths: ["README.md"]
        )
        await previews.value
        XCTAssertEqual(result.changedPaths, ["README.md"])
    }

    func testFixSkipsChangedFilesThatCannotBeSentAndReportsThem() async throws {
        let fixture = try await makeFixture(
            "LocalPatchFixSkips",
            files: ["README.md": Data("Original\n".utf8), "logo.bin": Data("plain for now\n".utf8)],
            replies: [
                #"{"summary":"Touch binary","files":[{"path":"logo.bin","action":"modify","content":"text\n"}]}"#,
                #"{"summary":"Fixed README","files":[{"path":"README.md","action":"modify","content":"Fixed\n"}]}"#
            ]
        )
        defer { fixture.server.stop(); try? FileManager.default.removeItem(at: fixture.root) }

        // Changes made earlier in the session: a text edit, a binary file and an oversized new file.
        try Data("Changed\n".utf8).write(to: fixture.workspace.appendingPathComponent("README.md"))
        try Data([0x00, 0xFF, 0x10, 0x00]).write(to: fixture.workspace.appendingPathComponent("logo.bin"))
        try Data(String(repeating: "x", count: LocalPatchResponseParser.maximumFileBytes + 1).utf8)
            .write(to: fixture.workspace.appendingPathComponent("big.txt"))
        var record = try fixture.saved()
        record.lastChangeRunAt = Date()
        try fixture.store.saveSession(record)
        try await fixture.recordFailedVerification()

        let preview = try await fixture.service.previewLocalFixInput(sessionID: fixture.session.id, failure: Self.failure)
        XCTAssertEqual(preview.files.map(\.path), ["README.md"])
        XCTAssertEqual(preview.skippedChangedPaths, ["big.txt", "logo.bin"])

        // An explicitly selected file that cannot be sent is still refused.
        do {
            _ = try await fixture.service.fixLocalChanges(sessionID: fixture.session.id, failure: Self.failure, filePaths: ["logo.bin"])
            XCTFail("An unselectable explicit path must be refused.")
        } catch {}
        XCTAssertEqual(fixture.postCount, 0)
        XCTAssertNotNil(try fixture.saved().approvedChangePlanDigest, "Refusing the input does not consume the approval.")

        // Skipped files are not modifiable this round.
        do {
            _ = try await fixture.service.fixLocalChanges(sessionID: fixture.session.id, failure: Self.failure)
            XCTFail("The model must not modify a skipped file.")
        } catch let error as LocalPatchApplicationError {
            XCTAssertEqual(error, .rejectedPaths(["logo.bin"]))
        }
        XCTAssertEqual(try Data(contentsOf: fixture.workspace.appendingPathComponent("logo.bin")), Data([0x00, 0xFF, 0x10, 0x00]))
        XCTAssertEqual(try fixture.saved().verificationPassed, false)

        try fixture.approve()
        let fixed = try await fixture.service.fixLocalChanges(sessionID: fixture.session.id, failure: Self.failure)
        XCTAssertEqual(fixed.changedPaths, ["README.md"])
        XCTAssertEqual(fixed.skippedChangedPaths, ["big.txt", "logo.bin"])
        let prompt = try XCTUnwrap((fixture.server.requests.last?.jsonBody?["messages"] as? [[String: Any]])?.first?["content"] as? String)
        XCTAssertTrue(prompt.contains("Changed\\n"))
        XCTAssertFalse(prompt.contains("xxxxxxxx"))
        XCTAssertEqual(try String(contentsOf: fixture.workspace.appendingPathComponent("README.md"), encoding: .utf8), "Fixed\n")
    }

    private func makeFixture(
        _ prefix: String,
        files: [String: Data],
        replies: [String],
        maxOutputTokens: Int = 1_024
    ) async throws -> Fixture {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let parent = packageRoot.appendingPathComponent("build/test-fixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let root = parent.appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (path, data) in files { try data.write(to: source.appendingPathComponent(path)) }
        try FixtureGit.run(["init", "-q", source.path])
        try FixtureGit.run(["-C", source.path, "add"] + files.keys.sorted())
        try FixtureGit.run(["-C", source.path, "commit", "-q", "-m", "initial"])

        let queue = ReplyQueue(try replies.map(Self.ollamaStream))
        let modelList = Data(#"{"models":[{"name":"fixture-local"}]}"#.utf8)
        let server = try LoopbackHTTPServer { request in
            request.method == "GET" ? .json(modelList) : .stream(queue.next())
        }
        let dataRoot = root.appendingPathComponent("workspace-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let store = try AuditStore(
            rootURL: root.appendingPathComponent("state", isDirectory: true),
            workspaceRootURL: dataRoot,
            managedWorkspaceRoots: []
        )
        let service = try BridgeService(store: store)
        var settings = try service.settings()
        settings.localModel = LocalModelSettings(
            backend: .ollama,
            endpoint: "http://127.0.0.1:\(server.port)",
            model: "fixture-local",
            contextWindowTokens: 8_192,
            maxOutputTokens: maxOutputTokens
        )
        try service.saveSettings(settings)
        let session = try await service.createSession(sourcePath: source.path, provider: .local, accessMode: .isolatedChanges)
        let plan = try service.createChangePlan(sessionID: session.id, title: "Update files", summary: "Edit the selected files.", steps: ["Make the requested edit."])
        let fixture = Fixture(root: root, source: source, store: store, service: service, server: server, session: session, plan: plan)
        try fixture.approve()
        return fixture
    }

    private static func ollamaStream(_ answer: String) throws -> Data {
        let message = try JSONSerialization.data(withJSONObject: ["message": ["role": "assistant", "content": answer], "done": false])
        let done = try JSONSerialization.data(withJSONObject: ["prompt_eval_count": 20, "eval_count": 4, "done": true, "done_reason": "stop"])
        var stream = Data()
        stream.append(message)
        stream.append(0x0A)
        stream.append(done)
        stream.append(0x0A)
        return stream
    }
}

private final class ReplyQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Data]

    init(_ replies: [Data]) { self.replies = replies }

    func next() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return replies.isEmpty ? Data() : replies.removeFirst()
    }
}
