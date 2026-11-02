import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class DiscussionWorkflowTests: XCTestCase {
    func testDiscussionCommandsDisableProjectToolsAndNativeHistory() throws {
        let workspace = "/private/tmp/AgentBridge discussion"
        let codex = ProviderCommandBuilder.codexDiscussionArguments(workspacePath: workspace)
        XCTAssertEqual(codex[codex.firstIndex(of: "--cd")! + 1], workspace)
        XCTAssertTrue(codex.contains("--skip-git-repo-check"))
        XCTAssertTrue(codex.contains("--ephemeral"))
        XCTAssertTrue(codex.contains("--sandbox"))
        XCTAssertTrue(codex.contains("read-only"))
        XCTAssertTrue(codex.contains("features.shell_tool=false"))
        XCTAssertTrue(codex.contains("features.multi_agent=false"))
        XCTAssertTrue(codex.contains("features.goals=false"))
        XCTAssertTrue(codex.contains("web_search=\"disabled\""))
        XCTAssertTrue(codex.contains("history.persistence=\"none\""))
        XCTAssertFalse(codex.contains("resume"))
        XCTAssertFalse(codex.contains("--mcp-config"))

        let claude = ProviderCommandBuilder.claudeDiscussionArguments()
        XCTAssertTrue(claude.contains("--no-session-persistence"))
        XCTAssertEqual(claude[claude.firstIndex(of: "--tools")! + 1], "")
        XCTAssertEqual(claude[claude.firstIndex(of: "--mcp-config")! + 1], "{\"mcpServers\":{}}")
        XCTAssertTrue(claude.contains("--strict-mcp-config"))
        XCTAssertTrue(claude.contains("--disable-slash-commands"))
        XCTAssertFalse(claude.contains("--resume"))
        XCTAssertFalse(claude.contains("--add-dir"))
    }

    func testDiscussionStorePersistsBoundedRedactedTranscriptIncludingOptedOutTurns() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DiscussionStore(rootURL: root.appendingPathComponent("discussions", isDirectory: true))
        let secret = "sk-test-0123456789abcdefghijklmnop"
        let record = DiscussionRecord(
            dataRootPath: root.path,
            provider: .codex,
            accountProfileID: AccountProfile.defaultID(for: .codex),
            turns: [
                DiscussionTurn(
                    provider: .codex,
                    accountProfileID: AccountProfile.defaultID(for: .codex),
                    sourceSharedMemoryConsent: true,
                    isShareable: false,
                    userText: "Keep this visible in the transcript: \(secret)",
                    assistantText: String(repeating: "🧭", count: 10_000)
                )
            ]
        )

        let saved = try store.create(record)
        let reloaded = try XCTUnwrap(store.record(id: saved.id))
        let persisted = try String(
            contentsOf: root.appendingPathComponent("discussions/\(saved.id.uuidString.lowercased()).json"),
            encoding: .utf8
        )

        XCTAssertEqual(reloaded.turns.count, 1)
        XCTAssertFalse(reloaded.turns[0].isShareable)
        XCTAssertTrue(reloaded.turns[0].userText.contains("Keep this visible"))
        XCTAssertTrue(reloaded.turns[0].userText.contains("<redacted>"))
        XCTAssertTrue(reloaded.turns[0].assistantText?.contains("…[truncated]…") == true)
        XCTAssertFalse(persisted.contains(secret))
        XCTAssertLessThanOrEqual(persisted.utf8.count, DiscussionStore.maximumRecordBytes)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("discussions/\(saved.id.uuidString.lowercased()).json").path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDiscussionNeedsNoGitAndUsesSubscriptionEvenWhenGlobalModeIsAPI() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var settings = try fixture.service.settings()
        settings.usageMode = .api
        try fixture.service.saveSettings(settings)

        let discussion = try fixture.service.createDiscussion(provider: .codex)
        let output = try await fixture.service.sendDiscussionMessage(
            id: discussion.id,
            prompt: "A project independent question",
            isShareable: false
        )
        let persisted = try fixture.service.discussion(id: discussion.id)
        let args = try String(contentsOf: fixture.root.appendingPathComponent("discussion-args-1"), encoding: .utf8)

        XCTAssertEqual(output.text, "answer-1")
        XCTAssertNil(output.providerSessionID)
        XCTAssertEqual(try fixture.service.settings().usageMode, .api, "Discussion must not rewrite global billing mode.")
        XCTAssertEqual(persisted.status, .completed)
        XCTAssertEqual(persisted.dataRootPath, fixture.dataRoot.path)
        XCTAssertEqual(persisted.turns.count, 1)
        XCTAssertFalse(persisted.turns[0].isShareable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.dataRoot.appendingPathComponent(".git").path))
        XCTAssertTrue(args.contains("--skip-git-repo-check"))
        XCTAssertTrue(args.contains("--ephemeral"))
        XCTAssertTrue(args.contains("features.shell_tool=false"))
        XCTAssertTrue(args.contains("history.persistence=\"none\""))
        let runDirectory = try String(contentsOf: fixture.root.appendingPathComponent("discussion-cwd-1"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let authDirectory = try String(contentsOf: fixture.root.appendingPathComponent("discussion-auth-cwd"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedDataRootMarker = "\(fixture.root.lastPathComponent)/user-data/tmp/"
        XCTAssertTrue(runDirectory.contains(selectedDataRootMarker), "Unexpected discussion CWD: \(runDirectory)")
        XCTAssertTrue(authDirectory.contains(selectedDataRootMarker), "Unexpected auth CWD: \(authDirectory)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: authDirectory))
        XCTAssertTrue(try fixture.store.events(sessionID: discussion.id).contains(where: {
            $0.kind == "usage.subscription.reserved"
        }))
    }

    func testDiscussionConsumesExistingProfileSubscriptionRunLimits() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var limits = try fixture.service.usageControlSettings(
            provider: .codex,
            profileID: AccountProfile.defaultID(for: .codex)
        )
        limits.subscriptionSessionRunLimit = 1
        try fixture.service.saveUsageControlSettings(
            limits,
            provider: .codex,
            profileID: AccountProfile.defaultID(for: .codex)
        )
        let discussion = try fixture.service.createDiscussion(provider: .codex)

        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "first allowed run")
        do {
            _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "blocked by local cap")
            XCTFail("Discussion sends must use existing local subscription run limits.")
        } catch let error as UsageControlError {
            guard case .runLimitReached(window: .currentSession, used: 1, limit: 1) = error else {
                return XCTFail("Unexpected usage-control error: \(error)")
            }
        }

        let statistics = try fixture.service.usageStatistics(
            provider: .codex,
            profileID: AccountProfile.defaultID(for: .codex),
            selectedSessionID: discussion.id
        )
        XCTAssertEqual(statistics.subscriptionSessionRuns, 1)
        XCTAssertEqual(try fixture.service.discussion(id: discussion.id).turns.count, 2)
        XCTAssertEqual(try fixture.service.discussion(id: discussion.id).status, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("discussion-started-2").path))
    }

    func testDiscussionSubscriptionLimitsRemainProfileScopedAfterTargetSwitch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let defaultProfileID = AccountProfile.defaultID(for: .codex)
        let secondProfile = try fixture.service.createAccountProfile(name: "Second usage profile", provider: .codex)
        for profileID in [defaultProfileID, secondProfile.id] {
            var limits = try fixture.service.usageControlSettings(provider: .codex, profileID: profileID)
            limits.subscriptionSessionRunLimit = 1
            try fixture.service.saveUsageControlSettings(limits, provider: .codex, profileID: profileID)
        }
        let discussion = try fixture.service.createDiscussion(provider: .codex)
        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "first profile run")
        _ = try fixture.service.setDiscussionTarget(id: discussion.id, provider: .codex, accountProfileID: secondProfile.id)
        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "second profile run")

        XCTAssertEqual(
            try fixture.service.usageStatistics(provider: .codex, profileID: defaultProfileID, selectedSessionID: discussion.id).subscriptionSessionRuns,
            1
        )
        XCTAssertEqual(
            try fixture.service.usageStatistics(provider: .codex, profileID: secondProfile.id, selectedSessionID: discussion.id).subscriptionSessionRuns,
            1
        )
        do {
            _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "second profile cap")
            XCTFail("A profile's own session cap must still block its next discussion run.")
        } catch let error as UsageControlError {
            guard case .runLimitReached(window: .currentSession, used: 1, limit: 1) = error else {
                return XCTFail("Unexpected usage-control error: \(error)")
            }
        }
        XCTAssertEqual(try fixture.service.discussion(id: discussion.id).usageProfileIDs, Set([defaultProfileID, secondProfile.id]))
    }

    func testOptOutAndSourceDestinationConsentFilterHistoryAcrossProfiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let noConsentProfile = try fixture.service.createAccountProfile(
            name: "No discussion memory",
            provider: .codex,
            allowsSharedMemory: false
        )
        let sharingProfile = try fixture.service.createAccountProfile(
            name: "Sharing discussion memory",
            provider: .codex,
            allowsSharedMemory: true
        )
        let sourceProfileID = AccountProfile.defaultID(for: .codex)
        let discussion = try fixture.service.createDiscussion(provider: .codex)
        XCTAssertEqual(try fixture.service.selectedAccountProfile(provider: .codex).id, AccountProfile.defaultID(for: .codex))

        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "first shared turn", isShareable: true)
        _ = try fixture.service.setDiscussionTarget(id: discussion.id, provider: .codex, accountProfileID: noConsentProfile.id)
        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "second opted out")
        let secondPrompt = try String(contentsOf: fixture.root.appendingPathComponent("discussion-prompt-2"), encoding: .utf8)
        XCTAssertTrue(secondPrompt.contains("second opted out"))
        XCTAssertFalse(secondPrompt.contains("first shared turn"))
        XCTAssertFalse(try fixture.service.discussion(id: discussion.id).turns[1].isShareable)

        _ = try fixture.service.setDiscussionTarget(id: discussion.id, provider: .codex, accountProfileID: sharingProfile.id)
        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "third profile allowed", isShareable: true)
        let thirdPrompt = try String(contentsOf: fixture.root.appendingPathComponent("discussion-prompt-3"), encoding: .utf8)
        XCTAssertTrue(thirdPrompt.contains("first shared turn"))
        XCTAssertTrue(thirdPrompt.contains("answer-1"))
        XCTAssertFalse(thirdPrompt.contains("second opted out"))

        try fixture.service.setAccountSharedMemoryAllowed(id: sourceProfileID, allowed: false)
        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "fourth after source revocation")
        let fourthPrompt = try String(contentsOf: fixture.root.appendingPathComponent("discussion-prompt-4"), encoding: .utf8)
        XCTAssertFalse(fourthPrompt.contains("first shared turn"), "Current source-profile consent revocation removes earlier turns.")
        XCTAssertTrue(fourthPrompt.contains("third profile allowed"), "Turns from the currently consenting profile remain available.")
        XCTAssertFalse(fourthPrompt.contains("--resume"))
        let fourthArgs = try String(contentsOf: fixture.root.appendingPathComponent("discussion-args-4"), encoding: .utf8)
        XCTAssertFalse(fourthArgs.contains("--resume"), "Each provider call must start a fresh native context.")
        XCTAssertEqual(try fixture.service.selectedAccountProfile(provider: .codex).id, AccountProfile.defaultID(for: .codex))
    }

    func testDiscussionPromptKeepsSharedHistoryChronological() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let discussion = try fixture.service.createDiscussion(provider: .codex)

        for index in 1...4 {
            _ = try await fixture.service.sendDiscussionMessage(
                id: discussion.id,
                prompt: "user-turn-\(index)",
                isShareable: true
            )
        }

        let prompt = try String(
            contentsOf: fixture.root.appendingPathComponent("discussion-prompt-4"),
            encoding: .utf8
        )
        let historyMarker = "Shared discussion history:\n"
        let historyStart = try XCTUnwrap(prompt.range(of: historyMarker)?.upperBound)
        let requestMarker = try XCTUnwrap(prompt.range(of: "Current user request:", range: historyStart..<prompt.endIndex)?.lowerBound)
        let historyText = prompt[historyStart..<requestMarker].trimmingCharacters(in: .whitespacesAndNewlines)
        let historyData = Data(historyText.utf8)
        let history = try XCTUnwrap(JSONSerialization.jsonObject(with: historyData) as? [String: Any])
        let turns = try XCTUnwrap(history["turns"] as? [[String: Any]])

        XCTAssertEqual(turns.compactMap { $0["userText"] as? String }, ["user-turn-1", "user-turn-2", "user-turn-3"])
        XCTAssertEqual(turns.compactMap { $0["assistantText"] as? String }, ["answer-1", "answer-2", "answer-3"])
    }

    func testDiscussionCancellationUsesExistingRunMarkerAndKeepsTranscript() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let discussion = try fixture.service.createDiscussion(provider: .codex)
        try Data("delay".utf8).write(to: fixture.root.appendingPathComponent("delay-discussion"))

        let run = Task {
            try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "cancel this turn")
        }
        try await waitForFile(fixture.root.appendingPathComponent("discussion-started-1"))
        try fixture.service.cancelDiscussion(id: discussion.id)

        do {
            _ = try await run.value
            XCTFail("Expected the discussion run to cancel.")
        } catch let error as AgentBridgeError {
            XCTAssertEqual(error, .processCancelled)
        }
        let cancelled = try fixture.service.discussion(id: discussion.id)
        XCTAssertEqual(cancelled.status, .cancelled)
        XCTAssertEqual(cancelled.turns.first?.userText, "cancel this turn")
        XCTAssertNil(cancelled.turns.first?.assistantText)
        XCTAssertTrue(try fixture.service.discussionEvents(id: discussion.id).contains(where: {
            $0.kind == "discussion.cancel.requested"
        }))
    }

    func testPersistedInterruptedDiscussionCanContinueAfterProcessExit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let discussion = try fixture.service.createDiscussion(provider: .codex)
        let discussionStore = try DiscussionStore(
            rootURL: fixture.dataRoot.appendingPathComponent("discussions", isDirectory: true)
        )
        var interrupted = try XCTUnwrap(discussionStore.record(id: discussion.id))
        interrupted.turns.append(DiscussionTurn(
            provider: .codex,
            accountProfileID: AccountProfile.defaultID(for: .codex),
            sourceSharedMemoryConsent: true,
            isShareable: false,
            userText: "unfinished before restart"
        ))
        interrupted.revision += 1
        interrupted.status = .running
        _ = try discussionStore.save(interrupted)

        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "continue after restart")

        let resumed = try fixture.service.discussion(id: discussion.id)
        XCTAssertEqual(resumed.status, .completed)
        XCTAssertEqual(resumed.turns.map(\.userText), ["unfinished before restart", "continue after restart"])
        XCTAssertTrue(try fixture.service.discussionEvents(id: discussion.id).contains(where: {
            $0.kind == "discussion.run.recovered"
        }))
    }

    func testDiscussionListAndReadRecoverOnlyUnleasedInFlightRecords() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let discussionStore = try DiscussionStore(
            rootURL: fixture.dataRoot.appendingPathComponent("discussions", isDirectory: true)
        )

        let staleRun = try fixture.service.createDiscussion(provider: .codex)
        var interruptedRun = try XCTUnwrap(discussionStore.record(id: staleRun.id))
        interruptedRun.status = .running
        _ = try discussionStore.save(interruptedRun)
        XCTAssertEqual(try fixture.service.discussion(id: staleRun.id).status, .failed)
        XCTAssertTrue(try fixture.service.discussionEvents(id: staleRun.id).contains(where: {
            $0.kind == "discussion.run.recovered"
        }))

        let staleTransition = try fixture.service.createDiscussion(provider: .codex)
        var interruptedTransition = try XCTUnwrap(discussionStore.record(id: staleTransition.id))
        interruptedTransition.status = .transitioning
        _ = try discussionStore.save(interruptedTransition)
        XCTAssertEqual(try XCTUnwrap(fixture.service.discussions().first(where: { $0.id == staleTransition.id })).status, .failed)
        XCTAssertTrue(try fixture.service.discussionEvents(id: staleTransition.id).contains(where: {
            $0.kind == "discussion.transition.recovered"
        }))

        let liveRun = try fixture.service.createDiscussion(provider: .codex)
        var activeRun = try XCTUnwrap(discussionStore.record(id: liveRun.id))
        activeRun.status = .running
        _ = try discussionStore.save(activeRun)
        let liveLease = try fixture.store.acquireRunLease(for: liveRun.id)
        defer { withExtendedLifetime(liveLease) {} }

        XCTAssertEqual(try fixture.service.discussion(id: liveRun.id).status, .running)
        XCTAssertEqual(try XCTUnwrap(fixture.service.discussions().first(where: { $0.id == liveRun.id })).status, .running)
        XCTAssertFalse(try fixture.service.discussionEvents(id: liveRun.id).contains(where: {
            $0.kind == "discussion.run.recovered"
        }))
    }

    func testExplicitCreateProjectMakesEmptyRepoAndMovesOnlyReviewedMemory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("AgentBridge-Discussion-New-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let discussion = try fixture.service.createDiscussion(provider: .codex)
        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "approved project context", isShareable: true)

        let handoff = try await fixture.service.prepareDiscussionProjectHandoff(
            discussionID: discussion.id,
            destinationPath: destination.path,
            mode: .createNew,
            targetProvider: .codex,
            targetProfileID: AccountProfile.defaultID(for: .codex),
            selectedTurnIDs: nil
        )
        XCTAssertEqual(handoff.selectedTurns.count, 1)
        XCTAssertTrue(handoff.selectedTurns[0].userText.contains("approved project context"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "Preview must not create a project.")

        do {
            _ = try await fixture.service.createOrAttachProjectFromDiscussion(
                handoffID: handoff.id,
                reviewedDigest: handoff.reviewedDigest,
                explicitConfirmation: false
            )
            XCTFail("Project creation must require explicit confirmation.")
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { return XCTFail("Unexpected refusal: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let session = try await fixture.service.createOrAttachProjectFromDiscussion(
            handoffID: handoff.id,
            reviewedDigest: handoff.reviewedDigest,
            explicitConfirmation: true
        )
        XCTAssertEqual(
            URL(fileURLWithPath: session.sourceRepositoryPath, isDirectory: true).resolvingSymlinksInPath().path,
            destination.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [".git"])
        XCTAssertTrue(try gitOutput(["-C", destination.path, "ls-tree", "-r", "--name-only", "HEAD"]).isEmpty)
        let scope = try SharedMemoryScope(repositoryPath: destination.path, snapshotCommit: session.snapshotCommit)
        let memory = try SharedMemoryStore(rootURL: fixture.dataRoot.appendingPathComponent("shared-memory", isDirectory: true))
            .snapshot(scope: scope)
        XCTAssertEqual(memory.turns.count, 1)
        XCTAssertEqual(memory.turns[0].userText, "approved project context")
        let linkedDiscussion = try fixture.service.discussion(id: discussion.id)
        XCTAssertEqual(linkedDiscussion.linkedSessionIDs, [session.id])
        XCTAssertEqual(linkedDiscussion.turns.count, 1, "Project linking preserves the original discussion transcript.")
        XCTAssertEqual(linkedDiscussion.handoffs.first?.consumedSessionID, session.id)
    }

    func testPrivateDiscussionCanCreateProjectWithExplicitZeroTurnHandoff() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("AgentBridge-Discussion-Private-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let profile = try fixture.service.createAccountProfile(
            name: "Private discussion only",
            provider: .codex,
            allowsSharedMemory: false
        )
        let discussion = try fixture.service.createDiscussion(provider: .codex, accountProfileID: profile.id)
        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "keep this only in the transcript")
        let stored = try fixture.service.discussion(id: discussion.id)
        XCTAssertFalse(stored.turns[0].isShareable)
        XCTAssertTrue(stored.turns[0].userText.contains("keep this only in the transcript"))

        let handoff = try await fixture.service.prepareDiscussionProjectHandoff(
            discussionID: discussion.id,
            destinationPath: destination.path,
            mode: .createNew,
            targetProvider: .codex,
            targetProfileID: profile.id,
            selectedTurnIDs: []
        )
        XCTAssertTrue(handoff.selectedTurns.isEmpty)
        XCTAssertTrue(handoff.hasValidDigest())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))

        let session = try await fixture.service.createOrAttachProjectFromDiscussion(
            handoffID: handoff.id,
            reviewedDigest: handoff.reviewedDigest,
            explicitConfirmation: true
        )
        let scope = try SharedMemoryScope(repositoryPath: destination.path, snapshotCommit: session.snapshotCommit)
        let memory = try SharedMemoryStore(rootURL: fixture.dataRoot.appendingPathComponent("shared-memory", isDirectory: true))
            .snapshot(scope: scope)
        XCTAssertTrue(memory.turns.isEmpty)
        XCTAssertEqual(try fixture.service.discussion(id: discussion.id).turns, stored.turns)
    }

    func testNewDiscussionRevisionRetiresStaleHandoffsAndAllowsAnotherPreview() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let discussion = try fixture.service.createDiscussion(provider: .codex)

        for index in 1...DiscussionStore.maximumHandoffsPerDiscussion {
            let destination = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
                .appendingPathComponent("AgentBridge-Stale-Preview-\(index)-\(UUID().uuidString.lowercased())", isDirectory: true)
            _ = try await fixture.service.prepareDiscussionProjectHandoff(
                discussionID: discussion.id,
                destinationPath: destination.path,
                mode: .createNew,
                targetProvider: .codex,
                targetProfileID: AccountProfile.defaultID(for: .codex),
                selectedTurnIDs: []
            )
        }

        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "advance the discussion revision")
        let destination = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("AgentBridge-Fresh-Preview-\(UUID().uuidString.lowercased())", isDirectory: true)
        let latest = try await fixture.service.prepareDiscussionProjectHandoff(
            discussionID: discussion.id,
            destinationPath: destination.path,
            mode: .createNew,
            targetProvider: .codex,
            targetProfileID: AccountProfile.defaultID(for: .codex),
            selectedTurnIDs: []
        )

        let persisted = try fixture.service.discussion(id: discussion.id)
        XCTAssertEqual(persisted.handoffs.map(\.id), [latest.id], "Older previews are unusable after a discussion revision changes.")
        XCTAssertEqual(persisted.handoffs.first?.discussionRevision, persisted.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "Preparing a preview must not create a project.")
    }

    func testConsentRevocationAfterPreviewPreventsMemoryHandoffMutation() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("AgentBridge-Discussion-Consent-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let discussion = try fixture.service.createDiscussion(provider: .codex)
        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "consented before preview")
        let handoff = try await fixture.service.prepareDiscussionProjectHandoff(
            discussionID: discussion.id,
            destinationPath: destination.path,
            mode: .createNew,
            targetProvider: .codex,
            targetProfileID: AccountProfile.defaultID(for: .codex)
        )
        try fixture.service.setAccountSharedMemoryAllowed(id: AccountProfile.defaultID(for: .codex), allowed: false)

        do {
            _ = try await fixture.service.createOrAttachProjectFromDiscussion(
                handoffID: handoff.id,
                reviewedDigest: handoff.reviewedDigest,
                explicitConfirmation: true
            )
            XCTFail("Revoked consent must invalidate a reviewed memory handoff.")
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { return XCTFail("Unexpected consent error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try fixture.service.sessions().isEmpty)
        XCTAssertEqual(try fixture.service.discussion(id: discussion.id).turns.count, 1)
    }

    func testAttachExistingRepositoryIsUntouchedAndStaleHeadRejectsHandoff() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = fixture.root.appendingPathComponent("existing-project", isDirectory: true)
        try makeGitRepository(at: repository, fileName: "README.txt", contents: "existing content")
        let discussion = try fixture.service.createDiscussion(provider: .codex)
        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "carry this decision", isShareable: true)
        let reviewedHead = try gitOutput(["-C", repository.path, "rev-parse", "HEAD"])
        let reviewedStatus = try gitOutput(["-C", repository.path, "status", "--porcelain=v1"])
        let handoff = try await fixture.service.prepareDiscussionProjectHandoff(
            discussionID: discussion.id,
            destinationPath: repository.path,
            mode: .attachExisting,
            targetProvider: .codex,
            targetProfileID: AccountProfile.defaultID(for: .codex),
            selectedTurnIDs: nil
        )

        let session = try await fixture.service.createOrAttachProjectFromDiscussion(
            handoffID: handoff.id,
            reviewedDigest: handoff.reviewedDigest,
            explicitConfirmation: true
        )
        XCTAssertEqual(session.sourceRepositoryPath, repository.path)
        XCTAssertEqual(try gitOutput(["-C", repository.path, "rev-parse", "HEAD"]), reviewedHead)
        XCTAssertEqual(try gitOutput(["-C", repository.path, "status", "--porcelain=v1"]), reviewedStatus)

        let staleDiscussion = try fixture.service.createDiscussion(provider: .codex)
        _ = try await fixture.service.sendDiscussionMessage(id: staleDiscussion.id, prompt: "stale context", isShareable: true)
        let stale = try await fixture.service.prepareDiscussionProjectHandoff(
            discussionID: staleDiscussion.id,
            destinationPath: repository.path,
            mode: .attachExisting,
            targetProvider: .codex,
            targetProfileID: AccountProfile.defaultID(for: .codex),
            selectedTurnIDs: nil
        )
        let newFile = repository.appendingPathComponent("change.txt")
        try Data("changed after preview".utf8).write(to: newFile)
        _ = try gitOutput(["-C", repository.path, "add", "change.txt"])
        _ = try gitOutput([
            "-C", repository.path,
            "-c", "user.name=Fixture",
            "-c", "user.email=fixture@example.invalid",
            "commit", "-m", "move reviewed head"
        ])
        let sessionCountBefore = try fixture.service.sessions().count
        do {
            _ = try await fixture.service.createOrAttachProjectFromDiscussion(
                handoffID: stale.id,
                reviewedDigest: stale.reviewedDigest,
                explicitConfirmation: true
            )
            XCTFail("A changed destination HEAD must invalidate the handoff.")
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { return XCTFail("Unexpected stale handoff error: \(error)") }
        }
        XCTAssertEqual(try fixture.service.sessions().count, sessionCountBefore)
    }

    func testNewProjectDestinationRejectsExistingDirectoryAndRepositoryNesting() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let repository = fixture.root.appendingPathComponent("repository", isDirectory: true)
        try makeGitRepository(at: repository, fileName: "file.txt", contents: "x")
        let nestedParent = repository.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedParent, withIntermediateDirectories: true)
        let discussion = try fixture.service.createDiscussion(provider: .codex)
        _ = try await fixture.service.sendDiscussionMessage(id: discussion.id, prompt: "shareable", isShareable: true)
        do {
            _ = try await fixture.service.prepareDiscussionProjectHandoff(
                discussionID: discussion.id,
                destinationPath: nestedParent.appendingPathComponent("new-project").path,
                mode: .createNew,
                targetProvider: .codex,
                targetProfileID: AccountProfile.defaultID(for: .codex),
                selectedTurnIDs: nil
            )
            XCTFail("A new project must not be nested inside an existing repository.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else { return XCTFail("Unexpected invalid destination error: \(error)") }
        }

        let existing = fixture.root.appendingPathComponent("already-exists", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        do {
            _ = try await fixture.service.prepareDiscussionProjectHandoff(
                discussionID: discussion.id,
                destinationPath: existing.path,
                mode: .createNew,
                targetProvider: .codex,
                targetProfileID: AccountProfile.defaultID(for: .codex),
                selectedTurnIDs: nil
            )
            XCTFail("A new project must not overwrite an existing directory.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else { return XCTFail("Unexpected existing destination error: \(error)") }
        }

        let symlinkParent = fixture.root.appendingPathComponent("repository-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkParent, withDestinationURL: nestedParent)
        do {
            _ = try await fixture.service.prepareDiscussionProjectHandoff(
                discussionID: discussion.id,
                destinationPath: symlinkParent.appendingPathComponent("new-project").path,
                mode: .createNew,
                targetProvider: .codex,
                targetProfileID: AccountProfile.defaultID(for: .codex),
                selectedTurnIDs: nil
            )
            XCTFail("A new project path must not traverse a symbolic link.")
        } catch let error as AgentBridgeError {
            guard case .invalidInput = error else { return XCTFail("Unexpected symlink destination error: \(error)") }
        }
    }

    private struct Fixture {
        let root: URL
        let dataRoot: URL
        let store: AuditStore
        let service: BridgeService
    }

    private func makeFixture() throws -> Fixture {
        let root = try temporaryDirectory()
        let dataRoot = root.appendingPathComponent("user-data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        let fakeCodex = root.appendingPathComponent("codex", isDirectory: false)
        let program = #"""
        #!/bin/sh
        if [ "$*" = "login status" ]; then
          pwd > "$HOME/discussion-auth-cwd"
          printf '%s\n' 'Logged in using ChatGPT'
          exit 0
        fi
        count=0
        if [ -f "$HOME/discussion-count" ]; then
          count=$(cat "$HOME/discussion-count")
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$HOME/discussion-count"
        cat > "$HOME/discussion-prompt-$count"
        printf '%s\n' "$@" > "$HOME/discussion-args-$count"
        pwd > "$HOME/discussion-cwd-$count"
        if [ -f "$HOME/delay-discussion" ]; then
          : > "$HOME/discussion-started-$count"
          sleep 30
        fi
        printf '%s\n' '{"type":"thread.started","thread_id":"3b12f1df-5232-4804-897e-917bf397618a"}'
        printf '{"type":"item.completed","item":{"type":"agent_message","text":"answer-%s"}}\n' "$count"
        printf '%s\n' '{"type":"turn.completed"}'
        """#
        try Data(program.utf8).write(to: fakeCodex)
        XCTAssertEqual(chmod(fakeCodex.path, mode_t(0o700)), 0)
        let store = try AuditStore(
            rootURL: root.appendingPathComponent("state", isDirectory: true),
            workspaceRootURL: dataRoot,
            managedWorkspaceRoots: []
        )
        let service = try BridgeService(
            store: store,
            baseEnvironment: ["HOME": root.path, "USER": "discussion-test", "PATH": "/usr/bin:/bin"]
        )
        var settings = try service.settings()
        settings.codexBinaryPath = fakeCodex.path
        settings.defaultProvider = .codex
        settings.usageMode = .subscription
        try service.saveSettings(settings)
        return Fixture(root: root, dataRoot: dataRoot, store: store, service: service)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-Discussion-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForFile(_ url: URL) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for \(url.lastPathComponent).")
    }

    private func makeGitRepository(at url: URL, fileName: String, contents: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try runGit(["-c", "init.defaultBranch=main", "init", "--quiet", "--", url.path])
        try Data(contents.utf8).write(to: url.appendingPathComponent(fileName))
        _ = try gitOutput(["-C", url.path, "add", fileName])
        _ = try gitOutput([
            "-C", url.path,
            "-c", "user.name=Fixture",
            "-c", "user.email=fixture@example.invalid",
            "-c", "core.hooksPath=/dev/null",
            "commit", "-m", "initial"
        ])
    }

    private func gitOutput(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.environment = [
            "HOME": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0"
        ]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let stdout = output.fileHandleForReading.readDataToEndOfFile()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let value = String(data: stdout, encoding: .utf8) else {
            throw NSError(domain: "DiscussionWorkflowTests.Git", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: String(data: stderr, encoding: .utf8) ?? "Git failed."
            ])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func runGit(_ arguments: [String]) throws {
        _ = try gitOutput(arguments)
    }
}
