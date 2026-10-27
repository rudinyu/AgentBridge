import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class BudgetLedgerTests: XCTestCase {
    func testReservationRequiresExplicitConsentAndValidPositiveBudget() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try BudgetLedger(rootURL: root)
        let sessionID = UUID()

        XCTAssertThrowsError(try ledger.reserve(
            sessionID: sessionID,
            requestedUSD: 1,
            explicitlyAuthorized: false
        )) { XCTAssertEqual($0 as? BudgetLedgerError, .authorizationRequired) }

        for invalid in [0.0, -1.0, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try ledger.reserve(
                sessionID: UUID(),
                requestedUSD: invalid,
                explicitlyAuthorized: true
            )) { XCTAssertEqual($0 as? BudgetLedgerError, .invalidRequestedBudget) }
        }
    }

    func testReservationUsesTwiceRequestedAmountAndNilReconciliationKeepsItCharged() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try BudgetLedger(rootURL: root, monthlyLimitUSD: 30)

        let reservation = try ledger.reserve(sessionID: UUID(), requestedUSD: 10, explicitlyAuthorized: true)
        XCTAssertEqual(reservation.requestedUSD, 10, accuracy: 0.000_001)
        XCTAssertEqual(reservation.reservedUSD, 20, accuracy: 0.000_001)
        try ledger.reconcile(reservationID: reservation.id, actualUSD: nil)

        let snapshot = try ledger.snapshot()
        XCTAssertEqual(snapshot.usedUSD, 0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.reservedUSD, 20, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.availableUSD, 10, accuracy: 0.000_001)
        XCTAssertThrowsError(try ledger.reserve(sessionID: UUID(), requestedUSD: 6, explicitlyAuthorized: true))
    }

    func testAReservationCannotBeDuplicatedForTheSameSession() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try BudgetLedger(rootURL: root)
        let sessionID = UUID()
        _ = try ledger.reserve(sessionID: sessionID, requestedUSD: 1, explicitlyAuthorized: true)

        XCTAssertThrowsError(try ledger.reserve(sessionID: sessionID, requestedUSD: 1, explicitlyAuthorized: true)) {
            XCTAssertEqual($0 as? BudgetLedgerError, .duplicateSession(sessionID))
        }
    }

    func testOverspendIsRecordedAndBlocksFurtherRuns() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try BudgetLedger(rootURL: root, monthlyLimitUSD: 30)
        let reservation = try ledger.reserve(sessionID: UUID(), requestedUSD: 10, explicitlyAuthorized: true)

        try ledger.reconcile(reservationID: reservation.id, actualUSD: 35)
        let snapshot = try ledger.snapshot()
        XCTAssertEqual(snapshot.usedUSD, 35, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.reservedUSD, 0, accuracy: 0.000_001)
        XCTAssertEqual(snapshot.availableUSD, 0, accuracy: 0.000_001)
        XCTAssertThrowsError(try ledger.reserve(sessionID: UUID(), requestedUSD: 1, explicitlyAuthorized: true))
    }

    func testReconciliationIsIdempotentButCannotChangeRecordedCost() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try BudgetLedger(rootURL: root)
        let reservation = try ledger.reserve(sessionID: UUID(), requestedUSD: 2, explicitlyAuthorized: true)

        try ledger.reconcile(reservationID: reservation.id, actualUSD: 1.25)
        try ledger.reconcile(reservationID: reservation.id, actualUSD: 1.25)
        XCTAssertEqual(try ledger.snapshot().usedUSD, 1.25, accuracy: 0.000_001)

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
        let ledger = try BudgetLedger(rootURL: root, monthlyLimitUSD: 25)
        let sessionID = UUID()
        let reservation = try ledger.reserve(sessionID: sessionID, requestedUSD: 2, explicitlyAuthorized: true)

        XCTAssertEqual(try ledger.unresolvedReservations().map(\.sessionID), [sessionID])
        XCTAssertTrue(try ledger.reconcile(sessionID: sessionID, actualUSD: 1.25))
        XCTAssertTrue(try ledger.reconcile(sessionID: sessionID, actualUSD: 1.25))
        XCTAssertFalse(try ledger.reconcile(sessionID: UUID(), actualUSD: 1.25))
        XCTAssertTrue(try ledger.unresolvedReservations().isEmpty)
        XCTAssertEqual(try ledger.snapshot().usedUSD, 1.25, accuracy: 0.000_001)
        XCTAssertEqual(try ledger.snapshot().reservedUSD, 0, accuracy: 0.000_001)
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
        let ledger = try BudgetLedger(rootURL: root, monthlyLimitUSD: 140)
        let october = date("2026-10-31T23:59:00Z")
        let november = date("2026-11-01T00:01:00Z")
        let reservation = try ledger.reserve(
            sessionID: UUID(), requestedUSD: 50, explicitlyAuthorized: true, now: october
        )

        let novemberPending = try ledger.snapshot(now: november)
        XCTAssertEqual(novemberPending.month, "2026-11")
        XCTAssertEqual(novemberPending.reservedUSD, 100, accuracy: 0.000_001)
        XCTAssertEqual(novemberPending.availableUSD, 40, accuracy: 0.000_001)

        try ledger.reconcile(reservationID: reservation.id, actualUSD: 80, now: november)
        let novemberSettled = try ledger.snapshot(now: november)
        XCTAssertEqual(novemberSettled.usedUSD, 80, accuracy: 0.000_001)
        XCTAssertEqual(novemberSettled.reservedUSD, 0, accuracy: 0.000_001)
        XCTAssertEqual(novemberSettled.availableUSD, 60, accuracy: 0.000_001)
    }

    func testCompetingLedgerInstancesCannotReserveBeyondMonthlyLimit() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledgers = try (0..<8).map { _ in try BudgetLedger(rootURL: root, monthlyLimitUSD: 140) }
        let counts = ConcurrentCounts()
        let group = DispatchGroup()

        for ledger in ledgers {
            group.enter()
            DispatchQueue.global().async {
                do {
                    _ = try ledger.reserve(sessionID: UUID(), requestedUSD: 50, explicitlyAuthorized: true)
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
        XCTAssertEqual(try ledgers[0].snapshot().reservedUSD, 100, accuracy: 0.000_001)
    }

    func testLedgerAndLockFilesUsePrivatePermissions() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        let ledger = try BudgetLedger(rootURL: root)
        _ = try ledger.reserve(sessionID: UUID(), requestedUSD: 1, explicitlyAuthorized: true)

        let rootPermissions = try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber
        let ledgerPermissions = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(".budget-ledger.json").path
        )[.posixPermissions] as? NSNumber
        let lockPermissions = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(".budget-ledger.lock").path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(rootPermissions?.intValue, 0o700)
        XCTAssertEqual(ledgerPermissions?.intValue, 0o600)
        XCTAssertEqual(lockPermissions?.intValue, 0o600)
    }

    func testSymlinkedRootAndLedgerAreRejected() throws {
        let parent = try makeTemporaryRoot()
        defer { removeTemporaryRoot(parent) }
        let realRoot = parent.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realRoot, withIntermediateDirectories: true)
        let rootLink = parent.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: realRoot)
        XCTAssertThrowsError(try BudgetLedger(rootURL: rootLink))

        let stateRoot = parent.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let outsideFile = parent.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: stateRoot.appendingPathComponent(".budget-ledger.json"),
            withDestinationURL: outsideFile
        )
        XCTAssertThrowsError(try BudgetLedger(rootURL: stateRoot))
    }

    func testCorruptLedgerFailsClosed() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        _ = try BudgetLedger(rootURL: root)
        try Data("{ not valid JSON".utf8).write(to: root.appendingPathComponent(".budget-ledger.json"))

        XCTAssertThrowsError(try BudgetLedger(rootURL: root)) {
            XCTAssertEqual($0 as? BudgetLedgerError, .invalidLedger)
        }
    }

    func testChangingMonthlyLimitFailsClosed() throws {
        let root = try makeTemporaryRoot()
        defer { removeTemporaryRoot(root) }
        _ = try BudgetLedger(rootURL: root, monthlyLimitUSD: 140)

        XCTAssertThrowsError(try BudgetLedger(rootURL: root, monthlyLimitUSD: 150)) {
            XCTAssertEqual($0 as? BudgetLedgerError, .invalidLedger)
        }
    }

    private func makeTemporaryRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-BudgetLedgerTests-\(UUID().uuidString)", isDirectory: true)
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
