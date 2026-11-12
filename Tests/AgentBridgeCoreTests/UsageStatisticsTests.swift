import Foundation
import XCTest
@testable import AgentBridgeCore

final class UsageStatisticsTests: XCTestCase {
    func testAggregationIsProfileScopedAndDeduplicatesAcceptedRunMarkers() {
        let profileID = UUID()
        let otherProfileID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let selectedSessionID = UUID()
        let secondSessionID = UUID()
        let otherProfileSessionID = UUID()
        let otherProviderSessionID = UUID()
        let sessions = [
            makeSession(id: selectedSessionID, provider: .codex, profileID: profileID),
            makeSession(id: secondSessionID, provider: .codex, profileID: profileID),
            makeSession(id: otherProfileSessionID, provider: .codex, profileID: otherProfileID),
            makeSession(id: otherProviderSessionID, provider: .claude, profileID: profileID)
        ]
        let events = [
            makeEvent(selectedSessionID, "usage.subscription.reserved", hoursAgo: 1, now: now),
            makeEvent(selectedSessionID, "run.started", hoursAgo: 0.95, now: now),
            makeEvent(selectedSessionID, "run.started", hoursAgo: 6, now: now),
            makeEvent(secondSessionID, "interactive.started", hoursAgo: 25, now: now),
            makeEvent(selectedSessionID, "run.started", hoursAgo: 6 * 24, now: now),
            makeEvent(otherProviderSessionID, "usage.api.reserved", hoursAgo: 2, now: now),
            makeEvent(otherProviderSessionID, "api.run.authorized", hoursAgo: 1.95, now: now),
            makeEvent(otherProfileSessionID, "run.started", hoursAgo: 0.5, now: now),
            makeEvent(otherProviderSessionID, "run.started", hoursAgo: 0.3, now: now),
            makeEvent(selectedSessionID, "run.started", hoursAgo: -1, now: now)
        ]

        let snapshot = UsageStatisticsAggregator.aggregate(
            provider: .codex,
            accountProfileID: profileID,
            sessions: sessions,
            events: events,
            selectedSessionID: selectedSessionID,
            now: now
        )
        XCTAssertEqual(snapshot.subscriptionFiveHourRuns, 1)
        XCTAssertEqual(snapshot.subscriptionDailyRuns, 2)
        XCTAssertEqual(snapshot.subscriptionSevenDayRuns, 4)
        XCTAssertEqual(snapshot.subscriptionSessionRuns, 3)
        XCTAssertEqual(snapshot.apiDailyRuns, 0)
        XCTAssertEqual(snapshot.apiSessionRuns, 0)
        XCTAssertEqual(snapshot.sevenDayBuckets.count, 7)
        XCTAssertEqual(snapshot.sevenDayBuckets.reduce(0) { $0 + $1.runCount }, snapshot.subscriptionSevenDayRuns)

        let claudeSnapshot = UsageStatisticsAggregator.aggregate(
            provider: .claude,
            accountProfileID: profileID,
            sessions: sessions,
            events: events,
            selectedSessionID: otherProviderSessionID,
            now: now
        )
        XCTAssertEqual(claudeSnapshot.subscriptionFiveHourRuns, 1)
        XCTAssertEqual(claudeSnapshot.subscriptionSevenDayRuns, 1)
        XCTAssertEqual(claudeSnapshot.apiDailyRuns, 1)
        XCTAssertEqual(claudeSnapshot.apiSessionRuns, 1)

        let profileWideSnapshot = UsageStatisticsAggregator.aggregate(
            provider: .claude,
            accountProfileID: profileID,
            sessions: sessions,
            events: events,
            now: now
        )
        XCTAssertEqual(profileWideSnapshot.apiSessionRuns, 0, "Without a selected session, session-scoped counters must not sum the whole profile.")
    }

    func testUsageControlsRoundTripAndValidateRunLimits() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try UsageControlStore(rootURL: root)
        let profileID = UUID()
        let settings = UsageControlSettings(
            subscriptionFiveHourRunLimit: 4,
            apiDailyRunLimit: 8,
            apiMonthlyLimitUSD: 25,
            apiDailyLimitUSD: 40,
            apiSessionLimitUSD: 12,
            macOSNotificationsEnabled: true,
            notifiedThresholds: ["api:2026-10:50": Date(timeIntervalSince1970: 1_700_000_000)]
        )

        try store.save(settings, provider: .claude, accountProfileID: profileID)

        XCTAssertEqual(try store.settings(provider: .claude, accountProfileID: profileID), settings)
        let historyAfterSettings = try store.auditHistory(provider: .claude, accountProfileID: profileID)
        let settingsChange = try XCTUnwrap(historyAfterSettings.first(where: { $0.kind == "settings_changed" }))
        XCTAssertTrue(settingsChange.details.contains(where: { $0.contains("apiMonthlyLimitUSD") }))
        XCTAssertTrue(settingsChange.details.contains(where: { $0.contains("macOSNotificationsEnabled") }))
        XCTAssertTrue(historyAfterSettings.contains(where: {
            $0.kind == "threshold_reached" && $0.details == ["api:2026-10:50"]
        }))
        var thresholdOnlyUpdate = settings
        thresholdOnlyUpdate.notifiedThresholds["codex:subscription-5h:2026-10-26:75"] = Date(timeIntervalSince1970: 1_700_000_001)
        thresholdOnlyUpdate.notifiedThresholds["claude:api:profile:2026-10:100"] = Date(timeIntervalSince1970: 1_700_000_002)
        try store.save(thresholdOnlyUpdate, provider: .claude, accountProfileID: profileID)
        let historyAfterThreshold = try store.auditHistory(provider: .claude, accountProfileID: profileID)
        XCTAssertEqual(historyAfterThreshold.filter({ $0.kind == "settings_changed" }).count, 1)
        XCTAssertEqual(historyAfterThreshold.filter({ $0.kind == "threshold_reached" }).count, 3)
        XCTAssertTrue(historyAfterThreshold.contains(where: {
            $0.kind == "threshold_reached" && $0.details == ["claude:api:profile:2026-10:100"]
        }))
        XCTAssertEqual(try store.settings(provider: .claude, accountProfileID: profileID), thresholdOnlyUpdate)
        XCTAssertThrowsError(try UsageControlSettings(subscriptionWeeklyRunLimit: 0).validate())
        XCTAssertThrowsError(try UsageControlSettings(subscriptionWeeklyRunLimit: -1).validate())
        XCTAssertThrowsError(try UsageControlSettings(apiMonthlyLimitUSD: .infinity).validate())
    }

    func testClaudeAPIBudgetsAreIsolatedForNewProfilesAndLegacyLedgerIsPreserved() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let auditStore = try AuditStore(rootURL: root.appendingPathComponent("AgentBridge", isDirectory: true))
        let service = try BridgeService(store: auditStore)
        let legacyID = AccountProfile.defaultID(for: .claude)
        let profile = try service.createAccountProfile(name: "API profile", provider: .claude)
        var settings = try service.usageControlSettings(provider: .claude, profileID: profile.id)
        settings.apiMonthlyLimitUSD = 25
        try service.saveUsageControlSettings(settings, provider: .claude, profileID: profile.id)

        XCTAssertEqual(try service.budgetSnapshot(profileID: profile.id).monthlyLimitUSD, 25)
        XCTAssertEqual(try service.budgetSnapshot(profileID: legacyID).monthlyLimitUSD, 140)
        var changedLimit = settings
        changedLimit.apiMonthlyLimitUSD = 30
        XCTAssertThrowsError(try service.saveUsageControlSettings(changedLimit, provider: .claude, profileID: profile.id))
        XCTAssertEqual(try service.budgetSnapshot(profileID: profile.id).monthlyLimitUSD, 25)
    }

    func testSubscriptionRunCapPreflightBlocksBeforeProviderLaunch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AuditStore(rootURL: root.appendingPathComponent("AgentBridge", isDirectory: true))
        let service = try BridgeService(store: store, baseEnvironment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "USER": "tester"])
        var controls = try service.usageControlSettings(provider: .codex, profileID: AccountProfile.defaultID(for: .codex))
        controls.subscriptionFiveHourRunLimit = 1
        try service.saveUsageControlSettings(controls, provider: .codex, profileID: AccountProfile.defaultID(for: .codex))

        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeGitRepository(at: source)
        let session = try await service.createSession(sourcePath: source.path, provider: .codex)
        try store.appendEvent(AuditEvent(sessionID: session.id, kind: "run.started", message: "existing local start"))

        do {
            _ = try await service.runReadOnly(sessionID: session.id, prompt: "must be blocked")
            XCTFail("Expected the local run cap to block this request.")
        } catch let error as UsageControlError {
            guard case .runLimitReached(window: .fiveHours, used: 1, limit: 1) = error else {
                return XCTFail("Unexpected usage control error: \(error)")
            }
        }

        XCTAssertTrue(try store.events(sessionID: session.id).contains(where: { $0.kind == "usage.run.blocked" }))
        XCTAssertFalse(try store.events(sessionID: session.id).contains(where: { $0.kind == "usage.subscription.reserved" }))
    }

    func testConcurrentAPIRunLimitPreflightSerializesDurableAttemptMarkers() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AuditStore(rootURL: root.appendingPathComponent("AgentBridge", isDirectory: true))
        let service = try BridgeService(store: store, baseEnvironment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "USER": "tester"])
        let profile = try service.createAccountProfile(name: "Capped Claude", provider: .claude)
        var controls = try service.usageControlSettings(provider: .claude, profileID: profile.id)
        controls.apiMonthlyLimitUSD = 25
        controls.apiDailyRunLimit = 1
        try service.saveUsageControlSettings(controls, provider: .claude, profileID: profile.id)

        let sessions = (0..<2).map { _ in
            SessionRecord(
                provider: .claude,
                sourceRepositoryPath: "/tmp/usage-capped-repository",
                workspacePath: "/tmp/usage-capped-workspace",
                snapshotCommit: String(repeating: "d", count: 40),
                sourceWasDirty: false,
                accountProfileID: profile.id
            )
        }
        for session in sessions { try store.saveSession(session) }

        let outcomes = await withTaskGroup(of: (accepted: Bool, capped: Bool).self, returning: [(accepted: Bool, capped: Bool)].self) { group in
            for session in sessions {
                group.addTask {
                    do {
                        try service.authorizeManagedRun(
                            session: session,
                            profile: profile,
                            usageMode: .api,
                            requestedAPIUSD: 0.01
                        )
                        return (true, false)
                    } catch let error as UsageControlError {
                        if case .runLimitReached(window: .rolling24Hours, used: 1, limit: 1) = error {
                            return (false, true)
                        }
                        return (false, false)
                    } catch {
                        return (false, false)
                    }
                }
            }
            var results: [(accepted: Bool, capped: Bool)] = []
            for await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(outcomes.filter(\.accepted).count, 1)
        XCTAssertEqual(outcomes.filter(\.capped).count, 1)
        let events = try sessions.flatMap { try store.events(sessionID: $0.id) }
        XCTAssertEqual(events.filter { $0.kind == "usage.api.reserved" }.count, 1)
        XCTAssertEqual(try service.usageStatistics(provider: .claude, profileID: profile.id).apiDailyRuns, 1)
    }

    func testAPIDailyDollarCapPreflightBlocksBeforeProviderLaunch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AuditStore(rootURL: root.appendingPathComponent("AgentBridge", isDirectory: true))
        let service = try BridgeService(store: store, baseEnvironment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "USER": "tester"])
        let profile = try service.createAccountProfile(name: "Paid Claude", provider: .claude)
        try service.selectAccountProfile(id: profile.id, provider: .claude)
        var settings = try service.settings()
        settings.defaultProvider = .claude
        settings.usageMode = .api
        try service.saveSettings(settings)
        var controls = try service.usageControlSettings(provider: .claude, profileID: profile.id)
        controls.apiMonthlyLimitUSD = 10
        controls.apiDailyLimitUSD = 1
        try service.saveUsageControlSettings(controls, provider: .claude, profileID: profile.id)

        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeGitRepository(at: source)
        let session = try await service.createSession(sourcePath: source.path, provider: .claude)

        do {
            _ = try await service.runReadOnly(
                sessionID: session.id,
                prompt: "must be blocked by the USD cap",
                apiRequest: APIUsageRequest(requestedBudgetUSD: 1, explicitlyAuthorized: true, apiKey: "test-api-key")
            )
            XCTFail("Expected the daily USD cap to block this request.")
        } catch let error as APICostLedgerError {
            guard case .dollarLimitReached(let scope, let limit, let committed) = error else {
                return XCTFail("Unexpected API dollar cap error: \(error)")
            }
            XCTAssertEqual(scope, "UTC daily")
            XCTAssertEqual(limit, 1)
            XCTAssertEqual(committed, 2)
        }

        XCTAssertTrue(try store.events(sessionID: session.id).contains(where: { $0.kind == "usage.run.blocked" }))
        XCTAssertFalse(try store.events(sessionID: session.id).contains(where: { $0.kind == "api.run.authorized" }))
        let budget = try service.budgetSnapshot(profileID: profile.id)
        XCTAssertEqual(budget.usedUSD, 0)
        XCTAssertEqual(budget.reservedUSD, 0)
    }

    func testBuiltInClaudeAPIRunsRetainLegacyMonthlyCapWhenLocalControlsOmitIt() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AuditStore(rootURL: root.appendingPathComponent("AgentBridge", isDirectory: true))
        let service = try BridgeService(store: store, baseEnvironment: ["HOME": root.path, "PATH": "/usr/bin:/bin", "USER": "tester"])
        var settings = try service.settings()
        settings.defaultProvider = .claude
        settings.usageMode = .api
        try service.saveSettings(settings)
        let profileID = AccountProfile.defaultID(for: .claude)
        var controls = try service.usageControlSettings(provider: .claude, profileID: profileID)
        controls.apiDailyLimitUSD = 0.01
        try service.saveUsageControlSettings(controls, provider: .claude, profileID: profileID)
        XCTAssertNil(try service.usageControlSettings(provider: .claude, profileID: profileID).apiMonthlyLimitUSD)
        XCTAssertEqual(try service.budgetSnapshot(profileID: profileID).monthlyLimitUSD, 140)

        let source = root.appendingPathComponent("source", isDirectory: true)
        try makeGitRepository(at: source)
        let session = try await service.createSession(sourcePath: source.path, provider: .claude)
        do {
            _ = try await service.runReadOnly(
                sessionID: session.id,
                prompt: "must use the retained legacy monthly ledger",
                apiRequest: APIUsageRequest(requestedBudgetUSD: 0.01, explicitlyAuthorized: true, apiKey: "test-api-key")
            )
            XCTFail("Expected the daily USD cap to block before provider launch.")
        } catch let error as APICostLedgerError {
            guard case .dollarLimitReached(let scope, let limit, let committed) = error else {
                return XCTFail("Unexpected API dollar cap error: \(error)")
            }
            XCTAssertEqual(scope, "UTC daily")
            XCTAssertEqual(limit, 0.01)
            XCTAssertEqual(committed, 0.02)
        }
    }

    func testManualAPISettlementRequiresConfirmationAndRejectsInvalidAmounts() throws {
        let fixture = try makeManualSettlementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        XCTAssertThrowsError(try fixture.service.reconcileAPIUsageFromProviderBill(
            profileID: fixture.profile.id,
            sessionID: fixture.session.id,
            actualUSD: 1.25,
            explicitlyConfirmed: false
        )) { XCTAssertEqual($0 as? UsageControlError, .apiReconciliationConfirmationRequired) }
        for invalid in [-0.01, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try fixture.service.reconcileAPIUsageFromProviderBill(
                profileID: fixture.profile.id,
                sessionID: fixture.session.id,
                actualUSD: invalid,
                explicitlyConfirmed: true
            )) { XCTAssertEqual($0 as? BudgetLedgerError, .invalidActualCost) }
        }
        XCTAssertEqual(try fixture.budget().reservedUSD, 4)
        XCTAssertTrue(try fixture.window().hasUnresolvedCall)
    }

    func testZeroCostSettlementRequiresBillConfirmationAndDoesNotReleaseAutomatically() throws {
        let fixture = try makeManualSettlementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        XCTAssertThrowsError(try fixture.service.reconcileAPIUsageFromProviderBill(
            profileID: fixture.profile.id,
            sessionID: fixture.session.id,
            actualUSD: 0,
            explicitlyConfirmed: false
        )) { XCTAssertEqual($0 as? UsageControlError, .apiReconciliationConfirmationRequired) }
        XCTAssertEqual(try fixture.budget().reservedUSD, 4)
        XCTAssertTrue(try fixture.window().hasUnresolvedCall)

        try fixture.service.reconcileAPIUsageFromProviderBill(
            profileID: fixture.profile.id,
            sessionID: fixture.session.id,
            actualUSD: 0,
            explicitlyConfirmed: true
        )
        XCTAssertEqual(try fixture.budget().usedUSD, 0)
        XCTAssertEqual(try fixture.budget().reservedUSD, 0)
        XCTAssertEqual(try fixture.window().dailyUsedUSD, 0)
    }

    func testManualAPISettlementRejectsWrongProviderAccountAndSession() throws {
        let fixture = try makeManualSettlementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let otherProfile = try fixture.service.createAccountProfile(name: "Other Claude", provider: .claude)

        XCTAssertThrowsError(try fixture.service.reconcileAPIUsageFromProviderBill(
            profileID: otherProfile.id,
            sessionID: fixture.session.id,
            actualUSD: 1.25,
            explicitlyConfirmed: true
        )) { XCTAssertEqual($0 as? AgentBridgeError, .sessionMismatch("The selected account is not the Claude account bound to this session.")) }

        let codexSession = SessionRecord(
            provider: .codex,
            sourceRepositoryPath: "/tmp/codex-repo",
            workspacePath: "/tmp/codex-workspace",
            snapshotCommit: String(repeating: "b", count: 40),
            sourceWasDirty: false,
            accountProfileID: fixture.profile.id
        )
        try fixture.store.saveSession(codexSession)
        XCTAssertThrowsError(try fixture.service.reconcileAPIUsageFromProviderBill(
            profileID: fixture.profile.id,
            sessionID: codexSession.id,
            actualUSD: 1.25,
            explicitlyConfirmed: true
        )) { XCTAssertEqual($0 as? AgentBridgeError, .sessionMismatch("Manual charge settlement is available only for Claude API sessions.")) }

        let missingSessionID = UUID()
        XCTAssertThrowsError(try fixture.service.reconcileAPIUsageFromProviderBill(
            profileID: fixture.profile.id,
            sessionID: missingSessionID,
            actualUSD: 1.25,
            explicitlyConfirmed: true
        )) { XCTAssertEqual($0 as? AgentBridgeError, .sessionNotFound(missingSessionID)) }
        XCTAssertEqual(try fixture.budget().reservedUSD, 4)
    }

    func testManualAPISettlementRejectsRunningSession() throws {
        let fixture = try makeManualSettlementFixture(status: .running)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let activeRunLease = try fixture.store.acquireRunLease(for: fixture.session.id)

        XCTAssertThrowsError(try fixture.service.reconcileAPIUsageFromProviderBill(
            profileID: fixture.profile.id,
            sessionID: fixture.session.id,
            actualUSD: 1.25,
            explicitlyConfirmed: true
        )) { XCTAssertEqual($0 as? AgentBridgeError, .sessionMismatch("This session is already running in another window or terminal.")) }
        XCTAssertEqual(try fixture.budget().reservedUSD, 4)
        XCTAssertTrue(try fixture.window().hasUnresolvedCall)
        withExtendedLifetime(activeRunLease) {}
    }

    func testManualAPISettlementRecoversStaleRunningSessionAfterAcquiringFreeLease() throws {
        let fixture = try makeManualSettlementFixture(status: .running)
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }

        try fixture.service.reconcileAPIUsageFromProviderBill(
            profileID: fixture.profile.id,
            sessionID: fixture.session.id,
            actualUSD: 1.25,
            explicitlyConfirmed: true
        )

        XCTAssertEqual(try fixture.store.session(id: fixture.session.id)?.status, .failed)
        XCTAssertTrue(try fixture.store.events(sessionID: fixture.session.id).contains(where: {
            $0.kind == "api.session.stale_run_recovered"
        }))
        XCTAssertEqual(try fixture.budget().usedUSD, 1.25, accuracy: 0.000_001)
        XCTAssertFalse(try fixture.window().hasUnresolvedCall)
    }

    func testManualAPISettlementUpdatesBothLedgersAuditsTheBillAmountAndIsIdempotent() throws {
        let fixture = try makeManualSettlementFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let candidates = try fixture.service.unresolvedAPICalls(profileID: fixture.profile.id)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].session.id, fixture.session.id)
        XCTAssertEqual(candidates[0].requestedUSD, 2)
        XCTAssertEqual(candidates[0].reservedUSD, 4)

        try fixture.service.reconcileAPIUsageFromProviderBill(
            profileID: fixture.profile.id,
            sessionID: fixture.session.id,
            actualUSD: 1.25,
            explicitlyConfirmed: true
        )
        XCTAssertEqual(try fixture.budget().usedUSD, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(try fixture.budget().reservedUSD, 0)
        let windowSnapshot = try fixture.window()
        XCTAssertEqual(windowSnapshot.dailyUsedUSD, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(windowSnapshot.sessionUsedUSD, 1.25, accuracy: 0.000_001)
        XCTAssertFalse(windowSnapshot.hasUnresolvedCall)
        XCTAssertTrue(try fixture.service.unresolvedAPICalls(profileID: fixture.profile.id).isEmpty)
        let events = try fixture.store.events(sessionID: fixture.session.id)
        XCTAssertTrue(events.contains(where: { $0.kind == "api.cost.manual_reconciliation.attempted" }))
        XCTAssertTrue(events.contains(where: { $0.kind == "api.cost.manual_reconciled" && $0.message.contains("US$1.250000") }))
        XCTAssertFalse(events.contains(where: { $0.message.contains("api-key") }))

        try fixture.service.reconcileAPIUsageFromProviderBill(
            profileID: fixture.profile.id,
            sessionID: fixture.session.id,
            actualUSD: 1.25,
            explicitlyConfirmed: true
        )
        XCTAssertThrowsError(try fixture.service.reconcileAPIUsageFromProviderBill(
            profileID: fixture.profile.id,
            sessionID: fixture.session.id,
            actualUSD: 1.5,
            explicitlyConfirmed: true
        )) { XCTAssertTrue($0 is BudgetLedgerError) }
    }

    func testServiceImportsLegacyLedgersFromTheirEarlierLocations() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AuditStore(rootURL: root.appendingPathComponent("AgentBridge", isDirectory: true))
        let service = try BridgeService(store: store)
        let profileID = AccountProfile.defaultID(for: .claude)
        let session = SessionRecord(
            provider: .claude,
            sourceRepositoryPath: "/tmp/legacy-repository",
            workspacePath: "/tmp/legacy-workspace",
            snapshotCommit: String(repeating: "d", count: 40),
            sourceWasDirty: false,
            status: .failed,
            accountProfileID: profileID
        )
        try store.saveSession(session)
        // Earlier releases settled the monthly ledger first; an interruption
        // could leave the day/session ledger unresolved for the same call.
        let created = "2026-11-01T00:00:00Z"
        let monthly: [String: Any] = [
            "schemaVersion": 1,
            "monthlyLimitMicros": 140_000_000,
            "reservations": [[
                "id": UUID().uuidString, "sessionID": session.id.uuidString,
                "requestedMicros": 2_000_000, "reservedMicros": 4_000_000,
                "month": "2026-11", "createdAt": created,
                "actualMicros": 1_250_000, "reconciledAt": created, "chargedMonth": "2026-11"
            ]]
        ]
        let unrelatedSessionID = UUID()
        let cost: [String: Any] = [
            "schemaVersion": 1,
            "reservations": [
                [
                    "id": UUID().uuidString, "sessionID": session.id.uuidString,
                    "requestedMicros": 2_000_000, "reservedMicros": 4_000_000,
                    "utcDay": "2026-11-01", "createdAt": created
                ],
                [
                    "id": UUID().uuidString, "sessionID": unrelatedSessionID.uuidString,
                    "requestedMicros": 1_000_000, "reservedMicros": 2_000_000,
                    "utcDay": "2026-11-01", "createdAt": created
                ]
            ]
        ]
        let costRoot = store.rootURL.appendingPathComponent("api-cost-controls", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: costRoot, withIntermediateDirectories: true)
        for (object, url) in [
            (monthly, store.rootURL.appendingPathComponent(".budget-ledger.json")),
            (cost, costRoot.appendingPathComponent(".api-cost-ledger.json"))
        ] {
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            XCTAssertEqual(chmod(url.path, 0o600), 0)
        }

        let budget = try service.budgetSnapshot(profileID: profileID, now: ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z")!)
        XCTAssertEqual(budget.usedUSD, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(budget.reservedUSD, 2, accuracy: 0.000_001)
        // The session settled in the monthly ledger is settled; the unrelated
        // reservation stays blocked and is not offered for this account.
        XCTAssertTrue(try service.unresolvedAPICalls(profileID: profileID).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.rootURL
            .appendingPathComponent("api-spend/\(profileID.uuidString.lowercased())/api-spend-ledger.json").path))
    }

    private func makeSession(id: UUID, provider: AgentProvider, profileID: UUID) -> SessionRecord {
        SessionRecord(
            id: id,
            provider: provider,
            sourceRepositoryPath: "/tmp/source",
            workspacePath: "/tmp/workspace",
            snapshotCommit: String(repeating: "a", count: 40),
            sourceWasDirty: false,
            accountProfileID: profileID
        )
    }

    private func makeEvent(_ sessionID: UUID, _ kind: String, hoursAgo: Double, now: Date) -> AuditEvent {
        AuditEvent(
            timestamp: now.addingTimeInterval(-hoursAgo * 60 * 60),
            sessionID: sessionID,
            kind: kind,
            message: "fixture"
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageStatisticsTests-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeGitRepository(at source: URL) throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FixtureGit.run(["init", "-q", source.path])
        try FixtureGit.run(["-C", source.path, "config", "user.name", "AgentBridge Test"])
        try FixtureGit.run(["-C", source.path, "config", "user.email", "agentbridge@example.invalid"])
        try Data("committed\n".utf8).write(to: source.appendingPathComponent("tracked.txt"))
        try FixtureGit.run(["-C", source.path, "add", "tracked.txt"])
        try FixtureGit.run(["-C", source.path, "commit", "-q", "-m", "snapshot"])
    }

    private func makeManualSettlementFixture(status: SessionStatus = .failed) throws -> ManualAPISettlementFixture {
        let root = try temporaryDirectory()
        let store = try AuditStore(rootURL: root.appendingPathComponent("AgentBridge", isDirectory: true))
        let service = try BridgeService(store: store)
        let profile = try service.createAccountProfile(name: "Claude billing profile", provider: .claude)
        var controls = try service.usageControlSettings(provider: .claude, profileID: profile.id)
        controls.apiMonthlyLimitUSD = 25
        controls.apiDailyLimitUSD = 10
        controls.apiSessionLimitUSD = 10
        try service.saveUsageControlSettings(controls, provider: .claude, profileID: profile.id)
        let session = SessionRecord(
            provider: .claude,
            sourceRepositoryPath: "/tmp/billing-repository",
            workspacePath: "/tmp/billing-workspace",
            snapshotCommit: String(repeating: "c", count: 40),
            sourceWasDirty: false,
            status: status,
            accountProfileID: profile.id
        )
        try store.saveSession(session)
        let spendLedger = try APISpendLedger(
            rootURL: store.rootURL.appendingPathComponent("api-spend", isDirectory: true)
                .appendingPathComponent(profile.id.uuidString.lowercased(), isDirectory: true)
        )
        _ = try spendLedger.reserve(
            sessionID: session.id,
            requestedUSD: 2,
            explicitlyAuthorized: true,
            limits: APISpendLimits(monthlyUSD: 25, dailyUSD: 10, sessionUSD: 10)
        )
        return ManualAPISettlementFixture(
            rootURL: root,
            store: store,
            service: service,
            profile: profile,
            session: session,
            spendLedger: spendLedger
        )
    }
}

private struct ManualAPISettlementFixture {
    let rootURL: URL
    let store: AuditStore
    let service: BridgeService
    let profile: AccountProfile
    let session: SessionRecord
    let spendLedger: APISpendLedger

    func budget() throws -> BudgetSnapshot {
        try spendLedger.budgetSnapshot(monthlyLimitUSD: 25)
    }

    func window() throws -> APICostControlSnapshot {
        try spendLedger.costControlSnapshot(sessionID: session.id, dailyLimitUSD: 10, sessionLimitUSD: 10)
    }
}
