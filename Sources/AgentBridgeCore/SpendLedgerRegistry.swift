import Foundation
import os

/// Hands out one `APISpendLedger` per account profile. Two callers racing on a
/// profile must share the same ledger instance, because the ledger serializes
/// its own reservations in-process.
final class SpendLedgerRegistry: @unchecked Sendable {
    private let ledgers = OSAllocatedUnfairLock<[UUID: APISpendLedger]>(uncheckedState: [:])

    func cached(for profileID: UUID) -> APISpendLedger? {
        ledgers.withLockUnchecked { $0[profileID] }
    }

    /// Stores `ledger` unless another caller got there first, and returns the winner.
    func register(_ ledger: APISpendLedger, for profileID: UUID) -> APISpendLedger {
        ledgers.withLockUnchecked { ledgers in
            if let existing = ledgers[profileID] { return existing }
            ledgers[profileID] = ledger
            return ledger
        }
    }
}
