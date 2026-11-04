import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class APISpendLedgerTests: XCTestCase {
    func testReservationRequiresExplicitConsentAndValidPositiveBudget() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try APISpendLedger(rootURL: root)
        let sessionID = UUID()

        XCTAssertThrowsError(try ledger.reserve(
            sessionID: sessionID,
            requestedUSD: 1,
            explicitlyAuthorized: false,
            limits: monthly(140)
        )) { XCTAssertEqual($0 as? BudgetLedgerError, .authorizationRequired) }

        for invalid in [0.0, -1.0, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try ledger.reserve(
                sessionID: UUID(),
                requestedUSD: invalid,
                explicitlyAuthorized: true,
                limits: monthly(140)
            )) { XCTAssertEqual($0 as? BudgetLedgerError, .invalidRequestedBudget) }
        }
        XCTAssertThrowsError(try ledger.reserve(
            sessionID: UUID(),
            requestedUSD: 1,
            explicitlyAuthorized: true,
            limits: APISpendLimits(monthlyUSD: 140, dailyUSD: 0.001)
        )) { XCTAssertEqual($0 as? APICostLedgerError, .invalidAmount) }
    }

    func testReservationUsesTwiceRequestedAmountAndNilReconciliationKeepsItCharged() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try APISpendLedger(rootURL: root)

        let reservation = try ledger.reserve(sessionID: UUID(), requestedUSD: 10, explicitlyAuthorized: true, limits: monthly(30))
        XCTAssertEqual(reservation.requestedUSD, 10, accuracy: 0.000_001)
        XCTAssertEqual(reservation.reservedUSD, 20, accuracy: 0.000_001)
        try ledger.reconcile(reservationID: reservation.id, actualUSD: nil)

        let snapshot = try ledger.budgetSnapshot(monthlyLimitUSD: 30)
        XCTAssertEqual(snapshot.usedUSD, 0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.reservedUSD, 20, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.availableUSD, 10, accuracy: 0.000_001)
        XCTAssertThrowsError(try ledger.reserve(sessionID: UUID(), requestedUSD: 1, explicitlyAuthorized: true, limits: monthly(30))) {
            XCTAssertEqual($0 as? APICostLedgerError, .unresolvedCall)
        }
        XCTAssertThrowsError(try ledger.reconcile(reservationID: UUID(), actualUSD: nil)) {
            XCTAssertTrue($0 is BudgetLedgerError)
        }
    }

    func testAReservationCannotBeDuplicatedForTheSameSession() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try APISpendLedger(rootURL: root)
        let sessionID = UUID()
        let reservation = try ledger.reserve(sessionID: sessionID, requestedUSD: 1, explicitlyAuthorized: true, limits: monthly(140))
        try ledger.reconcile(reservationID: reservation.id, actualUSD: 0.5)

        XCTAssertThrowsError(try ledger.reserve(sessionID: sessionID, requestedUSD: 1, explicitlyAuthorized: true, limits: monthly(140))) {
            XCTAssertEqual($0 as? BudgetLedgerError, .duplicateSession(sessionID))
        }
        XCTAssertThrowsError(try ledger.checkReservation(sessionID: sessionID, requestedUSD: 1, limits: monthly(140))) {
            XCTAssertEqual($0 as? BudgetLedgerError, .duplicateSession(sessionID))
        }
    }

    func testOverspendIsRecordedAndBlocksFurtherRuns() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try APISpendLedger(rootURL: root)
        let reservation = try ledger.reserve(sessionID: UUID(), requestedUSD: 10, explicitlyAuthorized: true, limits: monthly(30))

        try ledger.reconcile(reservationID: reservation.id, actualUSD: 35)
        let snapshot = try ledger.budgetSnapshot(monthlyLimitUSD: 30)
        XCTAssertEqual(snapshot.usedUSD, 35, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.reservedUSD, 0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.availableUSD, 0, accuracy: 0.000_001)
        XCTAssertThrowsError(try ledger.reserve(sessionID: UUID(), requestedUSD: 1, explicitlyAuthorized: true, limits: monthly(30))) { error in
            guard case BudgetLedgerError.insufficientBudget = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testReconciliationIsIdempotentButCannotChangeRecordedCost() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try APISpendLedger(rootURL: root)
        let reservation = try ledger.reserve(sessionID: UUID(), requestedUSD: 2, explicitlyAuthorized: true, limits: monthly(140))

        try ledger.reconcile(reservationID: reservation.id, actualUSD: 1.25)
        try ledger.reconcile(reservationID: reservation.id, actualUSD: 1.25)
        XCTAssertEqual(try ledger.budgetSnapshot(monthlyLimitUSD: 140).usedUSD, 1.25, accuracy: 0.000_001)

        XCTAssertThrowsError(try ledger.reconcile(reservationID: reservation.id, actualUSD: 1.5)) {
            XCTAssertEqual($0 as? BudgetLedgerError, .conflictingReconciliation(reservation.id))
        }
        for invalid in [-0.01, .infinity, .nan] {
            XCTAssertThrowsError(try ledger.reconcile(reservationID: reservation.id, actualUSD: invalid)) {
                XCTAssertEqual($0 as? BudgetLedgerError, .invalidActualCost)
            }
        }
    }

    func testManualSessionSettlementListsPendingReservationAndIsIdempotent() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try APISpendLedger(rootURL: root)
        let sessionID = UUID()
        let reservation = try ledger.reserve(sessionID: sessionID, requestedUSD: 2, explicitlyAuthorized: true, limits: monthly(25))

        XCTAssertEqual(try ledger.unresolvedReservations().map(\.sessionID), [sessionID])
        XCTAssertTrue(try ledger.validateSessionReconciliation(sessionID: sessionID, actualUSD: 1.25))
        XCTAssertFalse(try ledger.validateSessionReconciliation(sessionID: UUID(), actualUSD: 1.25))
        XCTAssertTrue(try ledger.reconcile(sessionID: sessionID, actualUSD: 1.25))
        XCTAssertTrue(try ledger.reconcile(sessionID: sessionID, actualUSD: 1.25))
        XCTAssertFalse(try ledger.reconcile(sessionID: UUID(), actualUSD: 1.25))
        XCTAssertTrue(try ledger.unresolvedReservations().isEmpty)
        XCTAssertEqual(try ledger.budgetSnapshot(monthlyLimitUSD: 25).usedUSD, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(try ledger.budgetSnapshot(monthlyLimitUSD: 25).reservedUSD, 0, accuracy: 0.000_001)
        XCTAssertThrowsError(try ledger.validateSessionReconciliation(sessionID: sessionID, actualUSD: 1.5)) {
            XCTAssertEqual($0 as? BudgetLedgerError, .conflictingReconciliation(reservation.id))
        }
        XCTAssertThrowsError(try ledger.reconcile(sessionID: sessionID, actualUSD: 1.5)) {
            XCTAssertEqual($0 as? BudgetLedgerError, .conflictingReconciliation(reservation.id))
        }
        for invalid in [-0.01, .infinity, .nan] {
            XCTAssertThrowsError(try ledger.reconcile(sessionID: sessionID, actualUSD: invalid)) {
                XCTAssertEqual($0 as? BudgetLedgerError, .invalidActualCost)
            }
        }
    }

    func testOutstandingReservationCarriesAcrossMonthAndCostUsesReconciliationMonth() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try APISpendLedger(rootURL: root)
        let october = date("2026-10-31T23:59:00Z")
        let november = date("2026-11-01T00:01:00Z")
        let reservation = try ledger.reserve(
            sessionID: UUID(), requestedUSD: 50, explicitlyAuthorized: true, limits: monthly(140), now: october
        )

        let novemberPending = try ledger.budgetSnapshot(monthlyLimitUSD: 140, now: november)
        XCTAssertEqual(novemberPending.month, "2026-11")
        XCTAssertEqual(novemberPending.reservedUSD, 100, accuracy: 0.000_001)
        XCTAssertEqual(novemberPending.availableUSD, 40, accuracy: 0.000_001)

        try ledger.reconcile(reservationID: reservation.id, actualUSD: 80, now: november)
        let novemberSettled = try ledger.budgetSnapshot(monthlyLimitUSD: 140, now: november)
        XCTAssertEqual(novemberSettled.usedUSD, 80, accuracy: 0.000_001)
        XCTAssertEqual(novemberSettled.reservedUSD, 0, accuracy: 0.000_001)
        XCTAssertEqual(novemberSettled.availableUSD, 60, accuracy: 0.000_001)
        // The UTC-day cap counts the call on the day it was reserved.
        let octoberDay = try ledger.costControlSnapshot(sessionID: UUID(), dailyLimitUSD: 200, sessionLimitUSD: nil, now: october)
        XCTAssertEqual(octoberDay.dailyUsedUSD, 80, accuracy: 0.000_001)
        let novemberDay = try ledger.costControlSnapshot(sessionID: UUID(), dailyLimitUSD: 200, sessionLimitUSD: nil, now: november)
        XCTAssertEqual(novemberDay.dailyUsedUSD, 0, accuracy: 0.000_001)
    }

    func testDailyAndSessionCapsAreCheckedWithTheMonthlyCap() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let firstClient = try APISpendLedger(rootURL: root)
        let secondClient = try APISpendLedger(rootURL: root)
        let limits = APISpendLimits(monthlyUSD: 140, dailyUSD: 10, sessionUSD: 10)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessionID = UUID()
        let reservation = try firstClient.reserve(
            sessionID: sessionID, requestedUSD: 4, explicitlyAuthorized: true, limits: limits, now: now
        )
        XCTAssertEqual(reservation.reservedUSD, 8)

        try firstClient.reconcile(reservationID: reservation.id, actualUSD: 5, now: now)
        let snapshot = try secondClient.costControlSnapshot(sessionID: sessionID, dailyLimitUSD: 10, sessionLimitUSD: 10, now: now)
        XCTAssertEqual(snapshot.dailyUsedUSD, 5)
        XCTAssertEqual(snapshot.dailyReservedUSD, 0)
        XCTAssertEqual(snapshot.sessionUsedUSD, 5)
        XCTAssertFalse(snapshot.hasUnresolvedCall)
        XCTAssertEqual(try secondClient.budgetSnapshot(monthlyLimitUSD: 140, now: now).usedUSD, 5)

        XCTAssertThrowsError(try secondClient.reserve(
            sessionID: UUID(), requestedUSD: 3, explicitlyAuthorized: true, limits: limits, now: now
        )) { error in
            guard case APICostLedgerError.dollarLimitReached(let scope, let limit, let committed) = error else {
                return XCTFail("Unexpected API daily cap error: \(error)")
            }
            XCTAssertEqual(scope, "UTC 每日")
            XCTAssertEqual(limit, 10)
            XCTAssertEqual(committed, 11)
        }
        XCTAssertThrowsError(try secondClient.reserve(
            sessionID: UUID(), requestedUSD: 3, explicitlyAuthorized: true,
            limits: APISpendLimits(monthlyUSD: 140, sessionUSD: 5), now: now
        )) { error in
            guard case APICostLedgerError.dollarLimitReached(let scope, _, let committed) = error else {
                return XCTFail("Unexpected API session cap error: \(error)")
            }
            XCTAssertEqual(scope, "目前工作階段")
            XCTAssertEqual(committed, 6)
        }
        // A refused reservation records nothing.
        XCTAssertTrue(try secondClient.unresolvedReservations().isEmpty)
    }

    func testCompetingLedgerInstancesAllowOnlyOneUnresolvedCall() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledgers = try (0..<8).map { _ in try APISpendLedger(rootURL: root) }
        let counts = ConcurrentCounts()
        let group = DispatchGroup()

        for ledger in ledgers {
            group.enter()
            DispatchQueue.global().async {
                do {
                    _ = try ledger.reserve(sessionID: UUID(), requestedUSD: 1, explicitlyAuthorized: true, limits: APISpendLimits(monthlyUSD: 140))
                    counts.record(success: true)
                } catch {
                    counts.record(success: false)
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(counts.successes, 1)
        XCTAssertEqual(counts.failures, 7)
        XCTAssertEqual(try ledgers[0].budgetSnapshot(monthlyLimitUSD: 140).reservedUSD, 2, accuracy: 0.000_001)
    }

    func testLedgerAndLockFilesUsePrivatePermissions() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try APISpendLedger(rootURL: root)
        _ = try ledger.reserve(sessionID: UUID(), requestedUSD: 1, explicitlyAuthorized: true, limits: monthly(140))

        XCTAssertEqual(try permissions(root), 0o700)
        XCTAssertEqual(try permissions(root.appendingPathComponent("api-spend-ledger.json")), 0o600)
        XCTAssertEqual(try permissions(root.appendingPathComponent(".coordination.lock")), 0o600)
    }

    func testSymlinkedRootAndLedgerAreRejected() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let parent = root.deletingLastPathComponent()
        let realRoot = parent.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let rootLink = parent.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: realRoot)
        XCTAssertThrowsError(try APISpendLedger(rootURL: rootLink))

        let stateRoot = parent.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let outsideFile = parent.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: stateRoot.appendingPathComponent("api-spend-ledger.json"),
            withDestinationURL: outsideFile
        )
        XCTAssertThrowsError(try APISpendLedger(rootURL: stateRoot))
    }

    func testCorruptOrOverflowingLedgerFailsClosed() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        _ = try APISpendLedger(rootURL: root)
        let ledgerURL = root.appendingPathComponent("api-spend-ledger.json")
        try Data("{ not valid JSON".utf8).write(to: ledgerURL)
        XCTAssertThrowsError(try APISpendLedger(rootURL: root)) {
            XCTAssertEqual($0 as? BudgetLedgerError, .invalidLedger)
        }

        func reservation(actualMicros: Int64?) -> [String: Any] {
            var value: [String: Any] = [
                "id": UUID().uuidString, "sessionID": UUID().uuidString,
                "requestedMicros": 1, "reservedMicros": 2,
                "month": "2026-10", "utcDay": "2026-10-27", "createdAt": "2026-10-27T00:00:00Z"
            ]
            if let actualMicros {
                value["actualMicros"] = actualMicros
                value["reconciledAt"] = "2026-10-27T00:00:00Z"
                value["chargedMonth"] = "2026-10"
            }
            return value
        }
        let overflowing: [String: Any] = [
            "schemaVersion": 1,
            "reservations": [reservation(actualMicros: Int64.max), reservation(actualMicros: 1)]
        ]
        try JSONSerialization.data(withJSONObject: overflowing).write(to: ledgerURL)
        XCTAssertThrowsError(try APISpendLedger(rootURL: root)) {
            XCTAssertEqual($0 as? BudgetLedgerError, .invalidLedger)
        }
    }

    func testChangingMonthlyLimitFailsClosed() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try APISpendLedger(rootURL: root)
        try ledger.bindMonthlyLimit(140)
        try ledger.bindMonthlyLimit(140)

        XCTAssertThrowsError(try ledger.bindMonthlyLimit(150)) {
            XCTAssertEqual($0 as? BudgetLedgerError, .invalidLedger)
        }
        XCTAssertThrowsError(try ledger.budgetSnapshot(monthlyLimitUSD: 150)) {
            XCTAssertEqual($0 as? BudgetLedgerError, .invalidLedger)
        }
        XCTAssertThrowsError(try ledger.reserve(sessionID: UUID(), requestedUSD: 1, explicitlyAuthorized: true, limits: monthly(150))) {
            XCTAssertEqual($0 as? BudgetLedgerError, .invalidLedger)
        }
    }

    // MARK: - Legacy import

    func testFirstOpenMergesBothLegacyLedgersBySessionAndLeavesThemUnchanged() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let parent = root.deletingLastPathComponent()
        let monthlyRoot = parent.appendingPathComponent("legacy-monthly", isDirectory: true)
        let costRoot = parent.appendingPathComponent("legacy-cost", isDirectory: true)
        let now = date("2026-11-04T12:00:00Z")

        let settledInBoth = UUID()
        let settledOnlyMonthly = UUID()
        let settledOnlyCost = UUID()
        let monthlyOnly = UUID()
        let costOnly = UUID()
        try writeLegacyMonthly(at: monthlyRoot, limitMicros: 140_000_000, reservations: [
            legacyMonthly(settledInBoth, requestedMicros: 1_000_000, created: "2026-10-01T00:00:00Z", actualMicros: 400_000, chargedMonth: "2026-10"),
            legacyMonthly(settledOnlyMonthly, requestedMicros: 1_000_000, created: "2026-11-02T00:00:00Z", actualMicros: 700_000, chargedMonth: "2026-11"),
            legacyMonthly(settledOnlyCost, requestedMicros: 1_000_000, created: "2026-11-03T00:00:00Z"),
            legacyMonthly(monthlyOnly, requestedMicros: 2_000_000, created: "2026-09-15T00:00:00Z", actualMicros: 900_000, chargedMonth: "2026-09")
        ])
        try writeLegacyCost(at: costRoot, reservations: [
            legacyCost(settledInBoth, requestedMicros: 1_000_001, day: "2026-10-01", created: "2026-10-01T00:00:00Z", actualMicros: 400_000),
            legacyCost(settledOnlyMonthly, requestedMicros: 1_000_000, day: "2026-11-02", created: "2026-11-02T00:00:00Z"),
            legacyCost(settledOnlyCost, requestedMicros: 1_000_000, day: "2026-11-03", created: "2026-11-03T00:00:00Z", actualMicros: 300_000),
            legacyCost(costOnly, requestedMicros: 500_000, day: "2026-11-04", created: "2026-11-04T00:00:00Z")
        ])
        let monthlyBefore = try Data(contentsOf: monthlyRoot.appendingPathComponent(".budget-ledger.json"))
        let costBefore = try Data(contentsOf: costRoot.appendingPathComponent(".api-cost-ledger.json"))

        let ledger = try APISpendLedger(rootURL: root, legacyMonthlyRootURL: monthlyRoot, legacyCostRootURL: costRoot, now: now)

        // Only the cost-only reservation remains unresolved; a session settled
        // in either legacy ledger is settled.
        XCTAssertEqual(try ledger.unresolvedReservations().map(\.sessionID), [costOnly])
        XCTAssertEqual(try ledger.unresolvedReservations().first?.reservedUSD ?? 0, 1, accuracy: 0.000_001)
        let november = try ledger.budgetSnapshot(monthlyLimitUSD: 140, now: now)
        XCTAssertEqual(november.usedUSD, 1.0, accuracy: 0.000_001, "0.7 settled in November plus 0.3 charged on import")
        XCTAssertEqual(november.reservedUSD, 1, accuracy: 0.000_001)
        XCTAssertEqual(try ledger.budgetSnapshot(monthlyLimitUSD: 140, now: date("2026-10-15T00:00:00Z")).usedUSD, 0.4, accuracy: 0.000_001)
        let octoberFirst = try ledger.costControlSnapshot(
            sessionID: settledInBoth, dailyLimitUSD: nil, sessionLimitUSD: nil, now: date("2026-10-01T12:00:00Z")
        )
        XCTAssertEqual(octoberFirst.dailyUsedUSD, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(octoberFirst.sessionUsedUSD, 0.4, accuracy: 0.000_001)
        // A monthly-only reservation keeps its creation day for the daily cap.
        let septemberDay = try ledger.costControlSnapshot(
            sessionID: monthlyOnly, dailyLimitUSD: nil, sessionLimitUSD: nil, now: date("2026-09-15T12:00:00Z")
        )
        XCTAssertEqual(septemberDay.dailyUsedUSD, 0.9, accuracy: 0.000_001)
        // The imported monthly cap is fixed.
        XCTAssertThrowsError(try ledger.bindMonthlyLimit(25))

        XCTAssertEqual(try Data(contentsOf: monthlyRoot.appendingPathComponent(".budget-ledger.json")), monthlyBefore)
        XCTAssertEqual(try Data(contentsOf: costRoot.appendingPathComponent(".api-cost-ledger.json")), costBefore)

        // Later legacy writes are not imported again.
        try writeLegacyCost(at: costRoot, reservations: [])
        let reopened = try APISpendLedger(rootURL: root, legacyMonthlyRootURL: monthlyRoot, legacyCostRootURL: costRoot, now: now)
        XCTAssertEqual(try reopened.unresolvedReservations().map(\.sessionID), [costOnly])
    }

    func testMissingLegacyLedgersCreateAnEmptyUnboundLedger() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let parent = root.deletingLastPathComponent()
        let ledger = try APISpendLedger(
            rootURL: root,
            legacyMonthlyRootURL: parent.appendingPathComponent("missing-monthly", isDirectory: true),
            legacyCostRootURL: parent.appendingPathComponent("missing-cost", isDirectory: true)
        )
        XCTAssertEqual(try ledger.budgetSnapshot(monthlyLimitUSD: 25).monthlyLimitUSD, 25)
        XCTAssertTrue(try ledger.unresolvedReservations().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("missing-monthly").path))
    }

    func testCorruptLegacyLedgerFailsClosedWithoutCreatingTheNewLedger() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let costRoot = root.deletingLastPathComponent().appendingPathComponent("legacy-cost", isDirectory: true)
        try FileManager.default.createDirectory(at: costRoot, withIntermediateDirectories: true)
        try Data("{ malformed".utf8).write(to: costRoot.appendingPathComponent(".api-cost-ledger.json"))

        XCTAssertThrowsError(try APISpendLedger(rootURL: root, legacyCostRootURL: costRoot)) {
            XCTAssertEqual($0 as? BudgetLedgerError, .invalidLedger)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("api-spend-ledger.json").path))
    }

    // MARK: - Helpers

    private func monthly(_ usd: Double) -> APISpendLimits {
        APISpendLimits(monthlyUSD: usd)
    }

    private func legacyMonthly(
        _ sessionID: UUID,
        requestedMicros: Int64,
        created: String,
        actualMicros: Int64? = nil,
        chargedMonth: String? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": UUID().uuidString, "sessionID": sessionID.uuidString,
            "requestedMicros": requestedMicros, "reservedMicros": requestedMicros * 2,
            "month": String(created.prefix(7)), "createdAt": created
        ]
        if let actualMicros, let chargedMonth {
            value["actualMicros"] = actualMicros
            value["reconciledAt"] = created
            value["chargedMonth"] = chargedMonth
        }
        return value
    }

    private func legacyCost(
        _ sessionID: UUID,
        requestedMicros: Int64,
        day: String,
        created: String,
        actualMicros: Int64? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": UUID().uuidString, "sessionID": sessionID.uuidString,
            "requestedMicros": requestedMicros, "reservedMicros": requestedMicros * 2,
            "utcDay": day, "createdAt": created
        ]
        if let actualMicros { value["actualMicros"] = actualMicros }
        return value
    }

    private func writeLegacyMonthly(at root: URL, limitMicros: Int64, reservations: [[String: Any]]) throws {
        try writePrivateJSON(
            ["schemaVersion": 1, "monthlyLimitMicros": limitMicros, "reservations": reservations],
            to: root.appendingPathComponent(".budget-ledger.json")
        )
    }

    private func writeLegacyCost(at root: URL, reservations: [[String: Any]]) throws {
        try writePrivateJSON(
            ["schemaVersion": 1, "reservations": reservations],
            to: root.appendingPathComponent(".api-cost-ledger.json")
        )
    }

    private func writePrivateJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }

    private func permissions(_ url: URL) throws -> Int? {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private func makeTemporaryRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-APISpendLedgerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        return parent.appendingPathComponent("ledger", isDirectory: true)
    }

    private func removeTemporaryRoot(_ root: URL) {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}

private final class ConcurrentCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var successCount = 0
    private var failureCount = 0

    var successes: Int {
        lock.lock()
        defer { lock.unlock() }
        return successCount
    }

    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failureCount
    }

    func record(success: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if success { successCount += 1 } else { failureCount += 1 }
    }
}
