import Foundation
import XCTest
@testable import AgentBridgeCore

final class AutonomousOrchestrationTests: XCTestCase {
    func testPlannerJSONMustBeStrictAndDAGMustBeValid() throws {
        let parsed = try AutonomousPlannerParser.parse(Self.validPlannerJSON)
        XCTAssertEqual(parsed.tasks.map(\.id), ["implement", "research", "review"])
        XCTAssertEqual(parsed.tasks.first(where: { $0.role == .reviewer })?.dependencies, ["implement"])

        XCTAssertThrowsError(try AutonomousPlannerParser.parse(Self.validPlannerJSON + " trailing prose"))
        XCTAssertThrowsError(try AutonomousPlannerParser.parse(Self.validPlannerJSON.replacingOccurrences(
            of: "\"dependencies\":[\"implement\"]",
            with: "\"dependencies\":[\"implement\"],\"unreviewed\":true"
        )))
        XCTAssertThrowsError(try AutonomousPlannerParser.parse(Self.validPlannerJSON.replacingOccurrences(
            of: "\"dependencies\":[\"implement\"]",
            with: "\"dependencies\":[\"missing\"]"
        )))
        XCTAssertThrowsError(try AutonomousPlannerParser.parse(Self.validPlannerJSON.replacingOccurrences(
            of: "\"dependencies\":[\"research\"]",
            with: "\"dependencies\":[\"review\"]"
        )))
    }

    func testPlanAndReviewDigestsAreBoundToExactContent() throws {
        let first = try makePlan(goal: "Update the greeting")
        let edited = try makePlan(goal: "Update the greeting safely", id: first.id)
        XCTAssertEqual(first.reviewDigest.count, 64)
        XCTAssertNotEqual(first.reviewDigest, edited.reviewDigest)

        let good = """
        {"version":1,"diffDigest":"\(String(repeating: "a", count: 64))","verdict":"pass","summary":"Clean.","findings":[]}
        """
        let review = try AutonomousReviewParser.parse(good, expectedDiffDigest: String(repeating: "a", count: 64))
        XCTAssertEqual(review.verdict, .pass)
        XCTAssertThrowsError(try AutonomousReviewParser.parse(
            good.replacingOccurrences(of: String(repeating: "a", count: 64), with: String(repeating: "b", count: 64)),
            expectedDiffDigest: String(repeating: "a", count: 64)
        ))
        XCTAssertThrowsError(try AutonomousReviewParser.parse(
            good.replacingOccurrences(of: "\"findings\":[]", with: "\"findings\":[{\"path\":\"x.swift\",\"severity\":\"high\",\"summary\":\"Issue\",\"inScope\":true}]"),
            expectedDiffDigest: String(repeating: "a", count: 64)
        ))
        let completeObject = good.trimmingCharacters(in: .whitespacesAndNewlines)
        let withUnknownTopLevelField = String(completeObject.dropLast()) + ",\"extra\":true}"
        XCTAssertNotEqual(withUnknownTopLevelField, completeObject)
        XCTAssertThrowsError(try AutonomousReviewParser.parse(
            withUnknownTopLevelField,
            expectedDiffDigest: String(repeating: "a", count: 64)
        ))
    }

    func testLimitsBoundConcurrencyReviewRoundsAndProviderInvocations() throws {
        XCTAssertThrowsError(try AutonomousRunLimits(maxConcurrentAgents: 4))
        XCTAssertThrowsError(try AutonomousRunLimits(maxReviewRounds: 4))
        XCTAssertThrowsError(try AutonomousRunLimits(maxMCPToolCallsPerServer: 129))
        let limits = try AutonomousRunLimits(maxConcurrentAgents: 2, maxReviewRounds: 3, maxDurationSeconds: 120, maxProviderInvocations: 10)
        XCTAssertNoThrow(try AutonomousValidation.validateInvocationBudget(researcherCount: 3, limits: limits))
        XCTAssertThrowsError(try AutonomousValidation.validateInvocationBudget(
            researcherCount: 1,
            limits: try AutonomousRunLimits(maxReviewRounds: 2, maxProviderInvocations: 5)
        ))
    }

    func testRequestRequiresEveryRoleAndDefersExtensionsUntilAfterPlanning() throws {
        let planner = try AutonomousRoleBinding(role: .planner, provider: .codex, accountProfileID: UUID())
        let researcher = try AutonomousRoleBinding(role: .researcher, provider: .codex, accountProfileID: UUID())
        let implementer = try AutonomousRoleBinding(role: .implementer, provider: .claude, accountProfileID: UUID())
        let reviewer = try AutonomousRoleBinding(role: .reviewer, provider: .codex, accountProfileID: UUID())
        let roleBindings = [researcher, implementer, reviewer]
        XCTAssertThrowsError(try AutonomousRunRequest(
            goal: "Update one file",
            sourceRepositoryPath: "/tmp/repository",
            planner: planner,
            roleBindings: [researcher],
            shareDiffWithReviewer: true
        ))
        XCTAssertThrowsError(try AutonomousRunRequest(
            goal: "Update one file",
            sourceRepositoryPath: "/tmp/repository",
            planner: try AutonomousRoleBinding(role: .planner, provider: .codex, accountProfileID: UUID(), extensionIDs: ["sample.skill"]),
            roleBindings: roleBindings,
            shareDiffWithReviewer: true
        ))
        XCTAssertThrowsError(try AutonomousRunRequest(
            goal: "Update one file",
            sourceRepositoryPath: "/tmp/repository",
            planner: planner,
            roleBindings: roleBindings,
            shareDiffWithReviewer: false
        ))
        let valid = try AutonomousRunRequest(
            goal: "  Update one file  ",
            sourceRepositoryPath: "/tmp/repository/.",
            planner: planner,
            roleBindings: roleBindings,
            shareDiffWithReviewer: true
        )
        XCTAssertEqual(valid.goal, "Update one file")
        XCTAssertEqual(valid.sourceRepositoryPath, "/tmp/repository")
    }

    func testDesktopControlIsDigestBoundAndRestrictedToImplementer() throws {
        let observe = AutonomousExtensionActivationSnapshot(
            role: .reviewer,
            taskID: "review",
            roundIndex: 1,
            extensionID: "mac-control.test",
            kind: "macControl",
            name: "MacControl",
            version: "1",
            summary: "Observe fixture",
            configurationDigest: String(repeating: "a", count: 64),
            targetBundleID: "com.example.fixture",
            accessMode: "observe",
            allowedActions: ["mac_screenshot"]
        )
        let control = AutonomousExtensionActivationSnapshot(
            role: .implementer,
            taskID: "implement",
            extensionID: "mac-control.test",
            kind: "macControl",
            name: "MacControl",
            version: "1",
            summary: "Control fixture",
            configurationDigest: String(repeating: "b", count: 64),
            targetBundleID: "com.example.fixture",
            accessMode: "control",
            allowedActions: ["mac_mouse"]
        )
        XCTAssertThrowsError(try AutonomousValidation.validateDesktopControlConfiguration(
            activations: [control, observe], scope: nil, separateFromGit: false
        ))
        XCTAssertThrowsError(try AutonomousValidation.validateDesktopControlConfiguration(
            activations: [control, observe], scope: "Operate the safe fixture window", separateFromGit: false
        ))
        XCTAssertNoThrow(try AutonomousValidation.validateDesktopControlConfiguration(
            activations: [control, observe], scope: "Operate the safe fixture window", separateFromGit: true
        ))
        let reviewerControl = AutonomousExtensionActivationSnapshot(
            role: .reviewer,
            taskID: "review",
            roundIndex: 1,
            extensionID: control.extensionID,
            kind: control.kind,
            name: control.name,
            version: control.version,
            summary: control.summary,
            configurationDigest: control.configurationDigest,
            targetBundleID: control.targetBundleID,
            accessMode: control.accessMode,
            allowedActions: control.allowedActions
        )
        XCTAssertThrowsError(try AutonomousValidation.validateDesktopControlConfiguration(
            activations: [reviewerControl], scope: "Operate the safe fixture window", separateFromGit: true
        ))
    }

    func testProjectMemorySnapshotIsFrozenRedactedAndBounded() throws {
        let scope = try SharedMemoryScope(repositoryPath: "/tmp/repository", snapshotCommit: String(repeating: "0", count: 40))
        let memory = try AutonomousProjectMemorySnapshot(SharedMemorySnapshot(
            scope: scope,
            turns: [SharedMemoryTurn(
                id: UUID(),
                provider: .codex,
                userText: "Keep the existing section title.",
                assistantText: "The section title is stable.",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)
            )],
            notes: "Project note: preserve terminology.",
            revision: 7,
            wasTruncated: false
        ))
        XCTAssertTrue(memory.isIntact)
        XCTAssertEqual(memory.snapshotCommit, scope.snapshotCommit)
        XCTAssertTrue(memory.promptContext().contains("Project note: preserve terminology."))
        XCTAssertTrue(memory.promptContext().contains("\"revision\":7"))
        XCTAssertNotEqual(memory.digest, try AutonomousProjectMemorySnapshot(SharedMemorySnapshot(
            scope: scope,
            turns: [],
            notes: "Changed note.",
            revision: 7,
            wasTruncated: false
        )).digest)
    }

    func testDependencyAndExactDiffSharingRequireProfileConsent() throws {
        let plan = try makePlan()
        var profiles = plan.roleProfiles
        let researcherIndex = try XCTUnwrap(profiles.firstIndex(where: { $0.binding.role == .researcher }))
        var researcherProfile = profiles[researcherIndex].profile
        researcherProfile.allowsSharedMemory = false
        profiles[researcherIndex] = AutonomousRoleProfileSnapshot(
            binding: profiles[researcherIndex].binding,
            profile: researcherProfile,
            extensionFingerprint: profiles[researcherIndex].extensionFingerprint
        )
        XCTAssertThrowsError(try AutonomousValidation.validateOutputSharing(
            tasks: plan.tasks,
            roleProfiles: profiles,
            shareOutputs: true,
            shareDiff: true
        ))
        XCTAssertNoThrow(try AutonomousValidation.validateOutputSharing(
            tasks: plan.tasks,
            roleProfiles: profiles,
            shareOutputs: false,
            shareDiff: true
        ))

        let reviewerIndex = try XCTUnwrap(profiles.firstIndex(where: { $0.binding.role == .reviewer }))
        var reviewerProfile = profiles[reviewerIndex].profile
        reviewerProfile.allowsSharedMemory = false
        profiles[reviewerIndex] = AutonomousRoleProfileSnapshot(
            binding: profiles[reviewerIndex].binding,
            profile: reviewerProfile,
            extensionFingerprint: profiles[reviewerIndex].extensionFingerprint
        )
        XCTAssertThrowsError(try AutonomousValidation.validateOutputSharing(
            tasks: plan.tasks,
            roleProfiles: profiles,
            shareOutputs: false,
            shareDiff: true
        ))
    }

    func testDAGSchedulesDependenciesAndNeverExceedsConcurrencyBound() async throws {
        let probe = AutonomousDAGProbe()
        let sourceProfileID = UUID()
        let tasks = [
            AutonomousTaskDefinition(id: "research-a", role: .researcher, title: "A", prompt: "A", dependencies: []),
            AutonomousTaskDefinition(id: "research-b", role: .researcher, title: "B", prompt: "B", dependencies: []),
            AutonomousTaskDefinition(id: "research-c", role: .researcher, title: "C", prompt: "C", dependencies: ["research-a"])
        ]
        let results = try await AutonomousDAGExecutor.run(
            tasks: tasks,
            maximumConcurrentTasks: 2,
            cancellation: CancellationFlag(),
            shareDependencyOutputs: true,
            profileIDForTask: { _ in sourceProfileID },
            operation: { task, dependencies in
                await probe.start(taskID: task.id, dependencyOutputs: dependencies)
                let delay: UInt64 = task.id == "research-b" ? 140_000_000 : 20_000_000
                try await Task.sleep(nanoseconds: delay)
                await probe.finish(taskID: task.id)
                return "output-\(task.id)"
            }
        )

        XCTAssertEqual(Set(results.keys), Set(["research-a", "research-b", "research-c"]))
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.maximumConcurrent, 2)
        XCTAssertLessThan(try XCTUnwrap(snapshot.events.firstIndex(of: "start:research-c")), try XCTUnwrap(snapshot.events.firstIndex(of: "finish:research-b")))
        XCTAssertEqual(snapshot.dependencyProfileID, sourceProfileID)
        XCTAssertEqual(snapshot.dependencyText, "output-research-a")
    }

    func testDAGCancellationDoesNotStartQueuedProviderWork() async throws {
        let probe = AutonomousDAGProbe()
        let cancellation = CancellationFlag()
        cancellation.cancel()
        let tasks = [
            AutonomousTaskDefinition(id: "research-a", role: .researcher, title: "A", prompt: "A", dependencies: []),
            AutonomousTaskDefinition(id: "research-b", role: .researcher, title: "B", prompt: "B", dependencies: ["research-a"])
        ]
        do {
            _ = try await AutonomousDAGExecutor.run(
                tasks: tasks,
                maximumConcurrentTasks: 1,
                cancellation: cancellation,
                shareDependencyOutputs: false,
                profileIDForTask: { _ in UUID() },
                operation: { task, _ in
                    await probe.start(taskID: task.id, dependencyOutputs: [])
                    return task.id
                }
            )
            XCTFail("A cancelled run started provider work.")
        } catch let error as AutonomousOrchestrationError {
            XCTAssertEqual(error, .cancelled)
        }
        let snapshot = await probe.snapshot()
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testAutonomousRunStoreReportsLiveForeignProcessAndDoesNotRewriteStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentbridge-autonomous-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recordStore = try AutonomousRunStore(rootURL: root, processIdentity: { _ in "owner-start-token" })
        var record = AutonomousRunRecord(
            plan: try makePlan(),
            createdEvent: AutonomousRunEvent(kind: "plan.generated", message: "generated")
        )
        record.status = .running
        record.approvedAt = Date()
        record.runningProcessID = Int32.max
        record.runningProcessStartToken = "owner-start-token"
        try recordStore.insert(record)

        let observedByOtherProcess = try AutonomousRunStore(rootURL: root, processIdentity: { _ in "owner-start-token" })
        XCTAssertEqual(try observedByOtherProcess.all().first?.status, .running)

        let observedAfterProcessExit = try AutonomousRunStore(rootURL: root, processIdentity: { _ in nil })
        XCTAssertEqual(try observedAfterProcessExit.all().first?.status, .interrupted)
        XCTAssertEqual(try observedAfterProcessExit.record(id: record.id)?.status, .running)
    }

    func testForeignStoreCancellationAtomicallyBlocksTheNextProviderReservation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentbridge-autonomous-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ownerStore = try AutonomousRunStore(rootURL: root, processIdentity: { _ in "owner-start-token" })
        let foreignStore = try AutonomousRunStore(rootURL: root, processIdentity: { _ in "owner-start-token" })
        var record = AutonomousRunRecord(
            plan: try makePlan(),
            status: .running,
            createdEvent: AutonomousRunEvent(kind: "plan.generated", message: "generated")
        )
        record.approvedAt = Date()
        record.startedAt = Date()
        record.runningProcessID = Int32.max
        record.runningProcessStartToken = "owner-start-token"
        try ownerStore.insert(record)

        let request = try foreignStore.requestCancellation(id: record.id)
        XCTAssertTrue(request.shouldCancelSessions)
        XCTAssertEqual(request.record.status, .running)
        XCTAssertTrue(try ownerStore.isCancellationRequested(id: record.id))
        XCTAssertThrowsError(try ownerStore.updateUnlessCancellationRequested(id: record.id) { run in
            run.providerInvocationsStarted += 1
        }) { error in
            XCTAssertEqual(error as? AutonomousOrchestrationError, .cancelled)
        }
        XCTAssertEqual(try ownerStore.record(id: record.id)?.providerInvocationsStarted, 1)

        var completed = AutonomousRunRecord(
            plan: try makePlan(id: UUID()),
            status: .completed,
            createdEvent: AutonomousRunEvent(kind: "plan.generated", message: "generated")
        )
        completed.approvedAt = Date()
        completed.finishedAt = Date()
        completed.reviewVerdict = .pass
        completed.diffDigest = String(repeating: "a", count: 64)
        completed.sourceRepositoryFingerprintAfter = completed.plan.sourceRepositoryFingerprint
        try ownerStore.insert(completed)
        let persistedCompleted = try XCTUnwrap(ownerStore.record(id: completed.id))
        let terminalRequest = try foreignStore.requestCancellation(id: completed.id)
        XCTAssertFalse(terminalRequest.shouldCancelSessions)
        XCTAssertEqual(terminalRequest.record.status, .completed)
        XCTAssertEqual(terminalRequest.record, persistedCompleted)
        XCTAssertFalse(try ownerStore.isCancellationRequested(id: completed.id))
    }

    func testForeignStoreCancellationDuringProviderCallPreventsTheNextAgent() async throws {
        let fixture = try makeWorkflowFixture(repairMode: false, blockResearch: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let profileID = AccountProfile.defaultID(for: .codex)
        let request = try makeWorkflowRequest(
            sourceURL: fixture.sourceURL,
            profileID: profileID,
            limits: AutonomousRunLimits(maxConcurrentAgents: 1, maxReviewRounds: 1, maxDurationSeconds: 120, maxProviderInvocations: 4)
        )
        let prepared = try await fixture.service.prepareAutonomousRun(request)
        try fixture.service.approveAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)

        let foreignProcessStore = try AutonomousRunStore(
            rootURL: fixture.auditStore.rootURL.appendingPathComponent("autonomous-runs", isDirectory: true)
        )
        let providerStartedURL = fixture.homeURL.appendingPathComponent("research-invocation-started")
        let providerReleasedURL = fixture.homeURL.appendingPathComponent("research-released")
        let releaseURL = fixture.homeURL.appendingPathComponent("release-research")
        func releaseResearch() {
            try? Data("release\n".utf8).write(to: releaseURL, options: .atomic)
        }
        var releaseFallback: Task<Void, Never>?
        defer {
            _ = try? foreignProcessStore.requestCancellation(id: prepared.id)
            releaseResearch()
            releaseFallback?.cancel()
        }

        let runTask = Task {
            try await fixture.service.runAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)
        }
        var providerStarted = false
        for _ in 0..<1_200 {
            if Task.isCancelled { break }
            if FileManager.default.fileExists(atPath: providerStartedURL.path) {
                providerStarted = true
                break
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        guard providerStarted else {
            _ = try? foreignProcessStore.requestCancellation(id: prepared.id)
            releaseResearch()
            _ = try? await runTask.value
            XCTFail("The fixture researcher did not reach its in-flight barrier within 30 seconds.")
            return
        }

        releaseFallback = Task.detached {
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return
            }
            try? Data("release\n".utf8).write(to: releaseURL, options: .atomic)
        }

        do {
            let cancellation = try foreignProcessStore.requestCancellation(id: prepared.id)
            guard cancellation.shouldCancelSessions else {
                releaseResearch()
                _ = try? await runTask.value
                XCTFail("The foreign cancellation request did not observe a running workflow.")
                return
            }

            let result = try await runTask.value
            XCTAssertEqual(result.status, .cancelled)
            XCTAssertEqual(result.providerInvocationsStarted, 2)
            XCTAssertEqual(try String(contentsOf: fixture.homeURL.appendingPathComponent("agent-invocations.txt"), encoding: .utf8), "2\n")
            let prompts = try String(contentsOf: fixture.homeURL.appendingPathComponent("provider-prompts.log"), encoding: .utf8)
            XCTAssertTrue(prompts.contains("Autonomous role: researcher"))
            XCTAssertFalse(prompts.contains("Autonomous role: implementer"))
            XCTAssertFalse(prompts.contains("You are a read-only independent reviewer"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: providerReleasedURL.path), "The owner should cancel the active provider before the test fallback releases it.")
        } catch {
            _ = try? foreignProcessStore.requestCancellation(id: prepared.id)
            releaseResearch()
            _ = try? await runTask.value
            throw error
        }
    }

    func testSubscriptionBackedCoordinatorRunsWithCustomProfileWithoutChangingGlobalSelection() async throws {
        let fixture = try makeWorkflowFixture(repairMode: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let selectedProfileBefore = try fixture.service.selectedAccountProfile(provider: .codex)
        let isolatedProfile = try fixture.service.createAccountProfile(name: "Autonomous isolated account", provider: .codex)
        XCTAssertFalse(isolatedProfile.usesExistingLogin)
        XCTAssertEqual(try fixture.service.selectedAccountProfile(provider: .codex), selectedProfileBefore)
        let profileID = isolatedProfile.id
        let seedSession = try await fixture.service.createSession(
            sourcePath: fixture.sourceURL.path,
            provider: .codex,
            accountProfileID: profileID
        )
        try fixture.service.setSharedMemoryNotes(sessionID: seedSession.id, notes: "KNOWN_MEMORY_NOTE: keep the greeting concise.")
        let sourceBefore = try await AutonomousRepositoryFingerprint.capture(sourceRepositoryPath: fixture.sourceURL.path)
        let limits = try AutonomousRunLimits(
            maxConcurrentAgents: 1,
            maxReviewRounds: 1,
            maxDurationSeconds: 120,
            maxProviderInvocations: 4,
            maxMCPToolCallsPerServer: 4
        )
        let request = try makeWorkflowRequest(
            sourceURL: fixture.sourceURL,
            profileID: profileID,
            limits: limits,
            saveRunSummaryToMemory: true
        )
        let prepared = try await fixture.service.prepareAutonomousRun(request)
        XCTAssertEqual(prepared.status, .awaitingApproval)
        XCTAssertEqual(prepared.sourceRepositoryFingerprintBefore, prepared.plan.sourceRepositoryFingerprint)
        XCTAssertEqual(prepared.plan.projectMemorySnapshot?.notes, "KNOWN_MEMORY_NOTE: keep the greeting concise.")
        XCTAssertTrue(prepared.plan.roleProfiles.allSatisfy(\.profile.allowsSharedMemory))
        try fixture.service.approveAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)
        let completed = try await fixture.service.runAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.providerInvocationsStarted, 4)
        XCTAssertEqual(completed.reviewVerdict, .pass)
        XCTAssertEqual(completed.memorySummarySaved, true)
        XCTAssertTrue(prepared.plan.roleProfiles.allSatisfy { $0.binding.accountProfileID == isolatedProfile.id })
        XCTAssertEqual(completed.sourceRepositoryFingerprintAfter, sourceBefore)
        XCTAssertEqual(try fixture.service.selectedAccountProfile(provider: .codex), selectedProfileBefore)
        XCTAssertEqual(try String(contentsOf: fixture.sourceURL.appendingPathComponent("greeting.txt"), encoding: .utf8), "Original greeting.\n")
        let writerSessionID = try XCTUnwrap(completed.writerSessionID)
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: XCTUnwrap(try fixture.service.sessions().first(where: { $0.id == writerSessionID })?.workspacePath)).appendingPathComponent("greeting.txt"), encoding: .utf8),
            "Updated greeting.\n"
        )
        let savedMemory = try fixture.service.sharedMemory(sessionID: seedSession.id)
        XCTAssertEqual(savedMemory.notes, "KNOWN_MEMORY_NOTE: keep the greeting concise.")
        XCTAssertEqual(savedMemory.turns.count, 1)
        XCTAssertTrue(savedMemory.turns[0].assistantText.contains(completed.diffDigest ?? "missing-diff-digest"))
        let prompts = try String(contentsOf: fixture.homeURL.appendingPathComponent("provider-prompts.log"), encoding: .utf8)
        XCTAssertTrue(prompts.contains("You are the read-only planner"))
        XCTAssertTrue(prompts.contains("Autonomous role: researcher"))
        XCTAssertTrue(prompts.contains("Autonomous role: implementer"))
        XCTAssertTrue(prompts.contains("You are a read-only independent reviewer"))
        XCTAssertTrue(prompts.contains("KNOWN_MEMORY_NOTE"))
        let sourceAfter = try await AutonomousRepositoryFingerprint.capture(sourceRepositoryPath: fixture.sourceURL.path)
        XCTAssertEqual(sourceAfter, sourceBefore)
    }

    func testSubscriptionCoordinatorRunsOneBoundedRepairRoundWithoutTouchingSource() async throws {
        let fixture = try makeWorkflowFixture(repairMode: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let profileID = AccountProfile.defaultID(for: .codex)
        let limits = try AutonomousRunLimits(
            maxConcurrentAgents: 1,
            maxReviewRounds: 2,
            maxDurationSeconds: 120,
            maxProviderInvocations: 6,
            maxMCPToolCallsPerServer: 4
        )
        let request = try makeWorkflowRequest(sourceURL: fixture.sourceURL, profileID: profileID, limits: limits)
        let prepared = try await fixture.service.prepareAutonomousRun(request)
        try fixture.service.approveAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)
        let completed = try await fixture.service.runAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.currentReviewRound, 2)
        XCTAssertEqual(completed.providerInvocationsStarted, 6)
        XCTAssertEqual(completed.reviewVerdict, .pass)
        XCTAssertTrue(completed.events.contains(where: { $0.kind == "review.changesRequested" }))
        XCTAssertEqual(try String(contentsOf: fixture.sourceURL.appendingPathComponent("greeting.txt"), encoding: .utf8), "Original greeting.\n")
        let sourceAfter = try await AutonomousRepositoryFingerprint.capture(sourceRepositoryPath: fixture.sourceURL.path)
        XCTAssertEqual(sourceAfter, prepared.plan.sourceRepositoryFingerprint)
    }

    func testRuntimeProviderInvocationLimitBlocksBeforeStartingNextAgent() async throws {
        let fixture = try makeWorkflowFixture(repairMode: false)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let profileID = AccountProfile.defaultID(for: .codex)
        let request = try makeWorkflowRequest(
            sourceURL: fixture.sourceURL,
            profileID: profileID,
            limits: AutonomousRunLimits(maxConcurrentAgents: 1, maxReviewRounds: 1, maxDurationSeconds: 120, maxProviderInvocations: 4)
        )
        let prepared = try await fixture.service.prepareAutonomousRun(request)
        try fixture.service.approveAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)
        let store = try AutonomousRunStore(rootURL: fixture.auditStore.rootURL.appendingPathComponent("autonomous-runs", isDirectory: true))
        _ = try store.update(id: prepared.id) { $0.providerInvocationsStarted = $0.plan.limits.maxProviderInvocations }

        let failed = try await fixture.service.runAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.providerInvocationsStarted, 4)
        XCTAssertEqual(failed.taskProgress.count, prepared.plan.tasks.count)
        XCTAssertTrue(failed.taskProgress.allSatisfy { $0.status == .failed })
        XCTAssertEqual(try String(contentsOf: fixture.homeURL.appendingPathComponent("agent-invocations.txt"), encoding: .utf8), "1\n")
        XCTAssertEqual(try String(contentsOf: fixture.sourceURL.appendingPathComponent("greeting.txt"), encoding: .utf8), "Original greeting.\n")
    }

    func testProjectCIVerificationPassesForThePinnedUnchangedScript() async throws {
        let fixture = try makeWorkflowFixture(repairMode: false, includeProjectCI: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let profileID = AccountProfile.defaultID(for: .codex)
        let limits = try AutonomousRunLimits(
            maxConcurrentAgents: 1,
            maxReviewRounds: 1,
            maxDurationSeconds: 120,
            maxProviderInvocations: 4,
            maxMCPToolCallsPerServer: 4
        )
        let request = try makeWorkflowRequest(
            sourceURL: fixture.sourceURL,
            profileID: profileID,
            limits: limits,
            verification: .projectCI
        )
        let prepared = try await fixture.service.prepareAutonomousRun(request)
        let writerSession = try XCTUnwrap(try fixture.service.sessions().first(where: {
            $0.id == prepared.plan.plannedAgents.first(where: { $0.role == .implementer })?.sessionID
        }))
        XCTAssertEqual(
            prepared.plan.verification.executablePath,
            URL(fileURLWithPath: writerSession.workspacePath).appendingPathComponent(".codex/ci.sh").path
        )
        XCTAssertEqual(prepared.plan.verification.executableDigest?.count, 64)
        XCTAssertTrue(prepared.plan.verification.executionTrustDisclosure?.contains("not an OS sandbox") == true)

        try fixture.service.approveAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)
        let completed = try await fixture.service.runAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)

        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.verificationPassed, true)
        let completedWriter = try XCTUnwrap(completed.writerSessionID)
        let workspacePath = try XCTUnwrap(try fixture.service.sessions().first(where: { $0.id == completedWriter })?.workspacePath)
        XCTAssertEqual(
            try String(contentsOf: URL(fileURLWithPath: workspacePath).appendingPathComponent(".ci-executed"), encoding: .utf8),
            "verified\n"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.appendingPathComponent(".ci-executed").path))
    }

    func testProjectCIRewriteByWriterBlocksWorkflowBeforeLaunchingVerifier() async throws {
        let fixture = try makeWorkflowFixture(repairMode: false, rewriteCIOnWrite: true, includeProjectCI: true)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let profileID = AccountProfile.defaultID(for: .codex)
        let limits = try AutonomousRunLimits(
            maxConcurrentAgents: 1,
            maxReviewRounds: 1,
            maxDurationSeconds: 120,
            maxProviderInvocations: 4,
            maxMCPToolCallsPerServer: 4
        )
        let request = try makeWorkflowRequest(
            sourceURL: fixture.sourceURL,
            profileID: profileID,
            limits: limits,
            verification: .projectCI
        )
        let prepared = try await fixture.service.prepareAutonomousRun(request)
        try fixture.service.approveAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)
        let blocked = try await fixture.service.runAutonomousRun(id: prepared.id, reviewedDigest: prepared.planDigest)

        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertNil(blocked.verificationPassed)
        XCTAssertTrue(blocked.resultSummary?.contains(".codex/ci.sh changed") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sourceURL.appendingPathComponent(".ci-executed").path))
        let writerSessionID = try XCTUnwrap(blocked.writerSessionID)
        let workspacePath = try XCTUnwrap(try fixture.service.sessions().first(where: { $0.id == writerSessionID })?.workspacePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: workspacePath).appendingPathComponent(".ci-executed").path))
        XCTAssertEqual(
            try String(contentsOf: fixture.sourceURL.appendingPathComponent(".codex/ci.sh"), encoding: .utf8),
            Self.projectCIScript
        )
    }

    private func makePlan(goal: String = "Goal", id: UUID = UUID()) throws -> AutonomousRunPlan {
        let planner = try binding(.planner, provider: .codex, shared: true)
        let researcher = try binding(.researcher, provider: .codex, shared: true)
        let implementer = try binding(.implementer, provider: .claude, shared: true)
        let reviewer = try binding(.reviewer, provider: .codex, shared: true)
        let scope = AutonomousChangeScope(title: "Small change", summary: "Change only one file.", steps: ["Edit the selected file."])
        let tasks = [
            AutonomousTaskDefinition(id: "research", role: .researcher, title: "Inspect", prompt: "Read the relevant code.", dependencies: []),
            AutonomousTaskDefinition(id: "implement", role: .implementer, title: "Change", prompt: "Implement the approved edit.", dependencies: ["research"]),
            AutonomousTaskDefinition(id: "review", role: .reviewer, title: "Review", prompt: "Review the exact diff.", dependencies: ["implement"])
        ]
        let limits = try AutonomousRunLimits(maxConcurrentAgents: 2, maxReviewRounds: 1, maxDurationSeconds: 60, maxProviderInvocations: 4)
        let bindings = [planner, researcher, implementer, reviewer]
        let snapshots = bindings.map { binding in
            AutonomousRoleProfileSnapshot(binding: binding, profile: profile(for: binding, shared: true), extensionFingerprint: String(repeating: "a", count: 64))
        }
        let agents = [
            AutonomousPlannedAgent(taskID: "research", sessionID: UUID(), role: .researcher, extensionFingerprint: String(repeating: "b", count: 64)),
            AutonomousPlannedAgent(taskID: "implement", sessionID: UUID(), role: .implementer, extensionFingerprint: String(repeating: "c", count: 64)),
            AutonomousPlannedAgent(taskID: "review", sessionID: UUID(), role: .reviewer, roundIndex: 1, extensionFingerprint: String(repeating: "d", count: 64))
        ]
        return AutonomousRunPlan(
            id: id,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            goal: goal,
            sourceRepositoryPath: "/tmp/repository",
            baseCommit: String(repeating: "0", count: 40),
            sourceWasDirty: false,
            plannerSessionID: UUID(),
            plannerBinding: planner,
            tasks: tasks,
            changeScope: scope,
            limits: limits,
            roleProfiles: snapshots,
            plannedAgents: agents,
            projectMemorySnapshot: try AutonomousProjectMemorySnapshot(SharedMemorySnapshot(
                scope: SharedMemoryScope(repositoryPath: "/tmp/repository", snapshotCommit: String(repeating: "0", count: 40)),
                turns: [],
                notes: "",
                revision: 0,
                wasTruncated: false
            )),
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

    private func binding(_ role: AutonomousRole, provider: AgentProvider, shared: Bool) throws -> AutonomousRoleBinding {
        try AutonomousRoleBinding(role: role, provider: provider, accountProfileID: profileID(for: role), extensionIDs: [])
    }

    private func profileID(for role: AutonomousRole) -> UUID {
        UUID(uuidString: [
            .planner: "00000000-0000-0000-0000-000000000001",
            .researcher: "00000000-0000-0000-0000-000000000002",
            .implementer: "00000000-0000-0000-0000-000000000003",
            .reviewer: "00000000-0000-0000-0000-000000000004"
        ][role]!)!
    }

    private func profile(for binding: AutonomousRoleBinding, shared: Bool) -> AccountProfile {
        AccountProfile(
            id: binding.accountProfileID,
            name: binding.role.rawValue,
            provider: binding.provider,
            usesExistingLogin: true,
            allowsSharedMemory: shared,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private static let validPlannerJSON = """
    {\"version\":1,\"tasks\":[
      {\"id\":\"research\",\"role\":\"researcher\",\"title\":\"Inspect\",\"prompt\":\"Read code.\",\"dependencies\":[]},
      {\"id\":\"implement\",\"role\":\"implementer\",\"title\":\"Change\",\"prompt\":\"Change code.\",\"dependencies\":[\"research\"]},
      {\"id\":\"review\",\"role\":\"reviewer\",\"title\":\"Review\",\"prompt\":\"Review exact diff.\",\"dependencies\":[\"implement\"]}
    ],\"changeScope\":{\"title\":\"Small edit\",\"summary\":\"Change one file.\",\"steps\":[\"Edit the selected file.\"]}}
    """

    private func makeWorkflowRequest(
        sourceURL: URL,
        profileID: UUID,
        limits: AutonomousRunLimits,
        saveRunSummaryToMemory: Bool = false,
        verification: AutonomousVerificationSelection = .none
    ) throws -> AutonomousRunRequest {
        let planner = try AutonomousRoleBinding(role: .planner, provider: .codex, accountProfileID: profileID)
        let researcher = try AutonomousRoleBinding(role: .researcher, provider: .codex, accountProfileID: profileID)
        let implementer = try AutonomousRoleBinding(role: .implementer, provider: .codex, accountProfileID: profileID)
        let reviewer = try AutonomousRoleBinding(role: .reviewer, provider: .codex, accountProfileID: profileID)
        return try AutonomousRunRequest(
            goal: "Update the greeting in an isolated workspace.",
            sourceRepositoryPath: sourceURL.path,
            planner: planner,
            roleBindings: [researcher, implementer, reviewer],
            limits: limits,
            shareOutputsWithDependencies: false,
            shareDiffWithReviewer: true,
            saveRunSummaryToMemory: saveRunSummaryToMemory,
            memoryDestinationProfileID: saveRunSummaryToMemory ? profileID : nil,
            verification: verification
        )
    }

    private func makeWorkflowFixture(
        repairMode: Bool,
        rewriteCIOnWrite: Bool = false,
        includeProjectCI: Bool = false,
        blockResearch: Bool = false
    ) throws -> AutonomousWorkflowFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridgeAutonomousCoordinator-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let appData = root.appendingPathComponent("app-data", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        for directory in [source, home, appData, bin] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("Original greeting.\n".utf8).write(to: source.appendingPathComponent("greeting.txt"))
        try Data(".ci-executed\n".utf8).write(to: source.appendingPathComponent(".gitignore"))
        if includeProjectCI {
            let codexDirectory = source.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
            let ciScript = codexDirectory.appendingPathComponent("ci.sh")
            try Data(Self.projectCIScript.utf8).write(to: ciScript)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ciScript.path)
        }
        try runFixtureCommand("/usr/bin/git", arguments: ["init", "-q", source.path])
        try runFixtureCommand("/usr/bin/git", arguments: ["-C", source.path, "config", "user.name", "AgentBridge Fixture"])
        try runFixtureCommand("/usr/bin/git", arguments: ["-C", source.path, "config", "user.email", "agentbridge-fixture@example.invalid"])
        try runFixtureCommand("/usr/bin/git", arguments: ["-C", source.path, "add", ".gitignore", "greeting.txt"] + (includeProjectCI ? [".codex/ci.sh"] : []))
        try runFixtureCommand("/usr/bin/git", arguments: ["-C", source.path, "commit", "-q", "-m", "fixture base"])

        let executable = bin.appendingPathComponent("codex")
        let executableSource = Self.fakeCodexExecutable
            .replacingOccurrences(of: "__REPAIR_MODE__", with: repairMode ? "1" : "0")
            .replacingOccurrences(of: "__REWRITE_CI__", with: rewriteCIOnWrite ? "1" : "0")
            .replacingOccurrences(of: "__BLOCK_RESEARCH__", with: blockResearch ? "1" : "0")
        try Data(executableSource.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let auditStore = try AuditStore(rootURL: appData, workspaceRootURL: appData, managedWorkspaceRoots: [])
        let service = try BridgeService(
            store: auditStore,
            baseEnvironment: [
                "HOME": home.path,
                "USER": NSUserName(),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEX_HOME": home.appendingPathComponent("codex-profile", isDirectory: true).path
            ]
        )
        var settings = try service.settings()
        settings.usageMode = .subscription
        settings.codexBinaryPath = executable.path
        try service.saveSettings(settings)
        return AutonomousWorkflowFixture(rootURL: root, sourceURL: source, homeURL: home, auditStore: auditStore, service: service)
    }

    private func runFixtureCommand(_ executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.temporaryDirectory.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0"
        ]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput + output, encoding: .utf8) ?? ""
            throw NSError(domain: "AutonomousOrchestrationTests", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    private static let fakeCodexExecutable = #"""
    #!/bin/sh
    set -eu
    if [ "${1:-}" = "login" ] && [ "${2:-}" = "status" ]; then
      printf 'Logged in using ChatGPT\n'
      exit 0
    fi

    PROMPT=$(/bin/cat)
    printf '%s\n' "$PROMPT" >> "$HOME/provider-prompts.log"
    INVOCATIONS=0
    if [ -f "$HOME/agent-invocations.txt" ]; then INVOCATIONS=$(/bin/cat "$HOME/agent-invocations.txt"); fi
    INVOCATIONS=$((INVOCATIONS + 1))
    printf '%s\n' "$INVOCATIONS" > "$HOME/agent-invocations.txt"

    emit_response() {
      printf '%s\n' '{"type":"thread.started","thread_id":"11111111-1111-4111-8111-111111111111"}'
      printf '%s\n' "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"$1\"}}"
      printf '%s\n' '{"type":"turn.completed"}'
    }

    if printf '%s' "$PROMPT" | /usr/bin/grep -Fq 'You are the read-only planner'; then
      emit_response '{\"version\":1,\"tasks\":[{\"id\":\"research\",\"role\":\"researcher\",\"title\":\"Inspect greeting\",\"prompt\":\"Read the isolated greeting file.\",\"dependencies\":[]},{\"id\":\"implement\",\"role\":\"implementer\",\"title\":\"Update greeting\",\"prompt\":\"Update greeting.txt in the isolated workspace.\",\"dependencies\":[\"research\"]},{\"id\":\"review\",\"role\":\"reviewer\",\"title\":\"Review the exact diff\",\"prompt\":\"Review only the exact diff snapshot.\",\"dependencies\":[\"implement\"]}],\"changeScope\":{\"title\":\"Update greeting\",\"summary\":\"Change only greeting.txt in the isolated workspace.\",\"steps\":[\"Replace the isolated greeting text.\"]}}'
    elif printf '%s' "$PROMPT" | /usr/bin/grep -Fq 'Autonomous role: researcher'; then
      if [ "__BLOCK_RESEARCH__" = "1" ]; then
        printf 'started\n' > "$HOME/research-invocation-started"
        while [ ! -f "$HOME/release-research" ]; do /bin/sleep 0.05; done
        printf 'released\n' > "$HOME/research-released"
      fi
      emit_response 'Research checked the isolated greeting file.'
    elif printf '%s' "$PROMPT" | /usr/bin/grep -Fq 'Autonomous role: implementer'; then
      printf 'Updated greeting.\n' > greeting.txt
      if [ "__REWRITE_CI__" = "1" ]; then
        cat > .codex/ci.sh <<'CI_SCRIPT'
    #!/bin/sh
    set -eu
    printf 'rewritten\n' > .ci-executed
    CI_SCRIPT
        chmod 700 .codex/ci.sh
      fi
      emit_response 'Updated greeting.txt in the isolated workspace.'
    elif printf '%s' "$PROMPT" | /usr/bin/grep -Fq 'You are a read-only independent reviewer'; then
      DIGEST=$(printf '%s' "$PROMPT" | /usr/bin/sed -n 's/.*"diffDigest":"\([0-9a-f][0-9a-f]*\)".*/\1/p' | /usr/bin/head -n 1)
      [ "${#DIGEST}" -eq 64 ] || exit 3
      REVIEW_COUNT=0
      if [ "__REPAIR_MODE__" = "1" ]; then
        if [ -f "$HOME/review-count.txt" ]; then REVIEW_COUNT=$(/bin/cat "$HOME/review-count.txt"); fi
        REVIEW_COUNT=$((REVIEW_COUNT + 1))
        printf '%s\n' "$REVIEW_COUNT" > "$HOME/review-count.txt"
      fi
      if [ "$REVIEW_COUNT" -eq 1 ]; then
        RESPONSE="{\\\"version\\\":1,\\\"diffDigest\\\":\\\"$DIGEST\\\",\\\"verdict\\\":\\\"changesRequested\\\",\\\"summary\\\":\\\"One bounded repair.\\\",\\\"findings\\\":[{\\\"path\\\":\\\"greeting.txt\\\",\\\"severity\\\":\\\"low\\\",\\\"summary\\\":\\\"Keep the approved punctuation.\\\",\\\"inScope\\\":true}]}"
      else
        RESPONSE="{\\\"version\\\":1,\\\"diffDigest\\\":\\\"$DIGEST\\\",\\\"verdict\\\":\\\"pass\\\",\\\"summary\\\":\\\"No findings.\\\",\\\"findings\\\":[]}"
      fi
      emit_response "$RESPONSE"
    else
      exit 4
    fi
    """#

    private static let projectCIScript = "#!/bin/sh\nset -eu\nprintf 'verified\\n' > .ci-executed\n"
}

private struct AutonomousWorkflowFixture {
    let rootURL: URL
    let sourceURL: URL
    let homeURL: URL
    let auditStore: AuditStore
    let service: BridgeService
}

private actor AutonomousDAGProbe {
    struct Snapshot {
        let events: [String]
        let maximumConcurrent: Int
        let dependencyProfileID: UUID?
        let dependencyText: String?
    }

    private var events: [String] = []
    private var active = 0
    private var maximumConcurrent = 0
    private var dependencyProfileID: UUID?
    private var dependencyText: String?

    func start(taskID: String, dependencyOutputs: [AutonomousDependencyOutput]) {
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        events.append("start:\(taskID)")
        if let dependency = dependencyOutputs.first {
            dependencyProfileID = dependency.profileID
            dependencyText = dependency.text
        }
    }

    func finish(taskID: String) {
        active -= 1
        events.append("finish:\(taskID)")
    }

    func snapshot() -> Snapshot {
        Snapshot(events: events, maximumConcurrent: maximumConcurrent, dependencyProfileID: dependencyProfileID, dependencyText: dependencyText)
    }
}
