import Darwin
import Foundation

/// A point-in-time view of API spend for a UTC calendar month.
///
/// `reservedUSD` includes every unresolved reservation, including reservations
/// created in an earlier month. This keeps a run that spans a month boundary
/// from freeing its budget before its cost has been recorded.
public struct BudgetSnapshot: Codable, Sendable {
    public let monthlyLimitUSD: Double
    public let usedUSD: Double
    public let reservedUSD: Double
    public let availableUSD: Double
    public let month: String

    public init(monthlyLimitUSD: Double, usedUSD: Double, reservedUSD: Double, availableUSD: Double, month: String) {
        self.monthlyLimitUSD = monthlyLimitUSD
        self.usedUSD = usedUSD
        self.reservedUSD = reservedUSD
        self.availableUSD = availableUSD
        self.month = month
    }
}

/// Local USD caps checked for one Claude API reservation. The monthly cap is
/// required; the UTC-day and AgentBridge-session caps are optional.
public struct APISpendLimits: Equatable, Sendable {
    public var monthlyUSD: Double
    public var dailyUSD: Double?
    public var sessionUSD: Double?

    public init(monthlyUSD: Double, dailyUSD: Double? = nil, sessionUSD: Double? = nil) {
        self.monthlyUSD = monthlyUSD
        self.dailyUSD = dailyUSD
        self.sessionUSD = sessionUSD
    }
}

/// A durable authorization reservation for one paid API call. A session may
/// hold several, settled one at a time.
public struct APISpendReservation: Codable, Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let requestedUSD: Double
    public let reservedUSD: Double
    public let month: String
    public let utcDay: String

    public init(id: UUID, sessionID: UUID, requestedUSD: Double, reservedUSD: Double, month: String, utcDay: String) {
        self.id = id
        self.sessionID = sessionID
        self.requestedUSD = requestedUSD
        self.reservedUSD = reservedUSD
        self.month = month
        self.utcDay = utcDay
    }
}

public enum BudgetLedgerError: Error, LocalizedError, Equatable {
    case invalidMonthlyLimit
    case invalidRequestedBudget
    case authorizationRequired
    case insufficientBudget(requiredUSD: Double, availableUSD: Double)
    case reservationNotFound(UUID)
    case invalidActualCost
    case conflictingReconciliation(UUID)
    case invalidLedger
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMonthlyLimit:
            "The monthly API budget limit must be a finite amount greater than zero."
        case .invalidRequestedBudget:
            "The budget for this API run must be a finite amount greater than zero."
        case .authorizationRequired:
            "Explicitly authorize this run and its budget before calling the API."
        case .insufficientBudget(let requiredUSD, let availableUSD):
            String(format: "Insufficient budget: this run requires a reservation of US$%.6f, available now: US$%.6f.", requiredUSD, availableUSD)
        case .reservationNotFound(let id):
            "Could not find budget reservation \(id.uuidString)."
        case .invalidActualCost:
            "The actual API charge must be a finite amount greater than or equal to zero."
        case .conflictingReconciliation(let id):
            "Budget reservation record \(id.uuidString) was settled with a different amount."
        case .invalidLedger:
            "The budget record is malformed or does not match the current limit. New API runs stopped to prevent overspending."
        case .persistence(let message):
            "Could not safely read or write the budget record: \(message)"
        }
    }
}

/// One private, cross-process-safe ledger per Claude account for explicit API
/// run budgets. Each reservation is checked against the account's monthly cap
/// and its optional UTC-day and AgentBridge-session caps in a single write, so
/// there is one record to settle per paid call. A session can make several
/// paid calls; the session cap counts all of them.
///
/// The requested run budget is only a soft provider-side estimate, so twice
/// the requested amount is reserved. A canceled, interrupted, or otherwise
/// unreconciled reservation remains charged, and blocks further paid calls,
/// until a validated cost is recorded. For the monthly cap, reconciled cost is
/// assigned to the UTC month in which reconciliation occurs and unresolved
/// reservations carry across month boundaries; the daily cap counts a call on
/// the UTC day it was reserved. Cost inputs are rounded up, and caps down, to
/// the nearest micro-dollar. The monthly cap is fixed once recorded so
/// changing it cannot reinterpret earlier spend.
public final class APISpendLedger: @unchecked Sendable {
    public let rootURL: URL

    private static let fileName = "api-spend-ledger.json"
    private static let legacyMonthlyFileName = ".budget-ledger.json"
    private static let legacyCostFileName = ".api-cost-ledger.json"
    fileprivate static let schemaVersion = 1
    private static let maximumStoredBytes = 8 * 1_024 * 1_024
    private static let maximumLegacyBytes = 4 * 1_024 * 1_024
    private static let maximumReservations = 20_000
    private static let microsPerUSD: Int64 = 1_000_000

    /// Opens the ledger, creating it on first use. A new ledger first merges,
    /// by session ID, the records of the separate monthly and day/session
    /// ledgers that earlier releases kept. Those legacy files are only read;
    /// one that cannot be validated fails closed instead of being skipped.
    public init(
        rootURL: URL,
        legacyMonthlyRootURL: URL? = nil,
        legacyCostRootURL: URL? = nil,
        now: Date = Date()
    ) throws {
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/"),
              !rootURL.path.split(separator: "/", omittingEmptySubsequences: true).contains("..") else {
            throw BudgetLedgerError.persistence("The budget directory path is invalid.")
        }
        let standardizedRoot = rootURL.standardizedFileURL
        guard standardizedRoot.path != "/" else {
            throw BudgetLedgerError.persistence("The filesystem root cannot be used as a budget directory.")
        }
        self.rootURL = standardizedRoot

        try AgentBridgePrivateJSONDocument.withLockedRoot(rootURL: standardizedRoot) { directoryDescriptor in
            if try Self.readDocument(directoryDescriptor: directoryDescriptor) != nil { return }
            let imported = try Self.importLegacy(
                monthlyRootURL: legacyMonthlyRootURL,
                costRootURL: legacyCostRootURL,
                now: now
            )
            try Self.writeDocument(imported, directoryDescriptor: directoryDescriptor)
        }
    }

    /// Records the monthly cap on first configuration and rejects a ledger
    /// that already holds a different cap.
    public func bindMonthlyLimit(_ monthlyLimitUSD: Double) throws {
        let limit = try Self.monthlyLimitMicros(monthlyLimitUSD)
        try withDocument { document in try Self.bind(limit, to: &document) }
    }

    public func budgetSnapshot(monthlyLimitUSD: Double, now: Date = Date()) throws -> BudgetSnapshot {
        let limit = try Self.monthlyLimitMicros(monthlyLimitUSD)
        return try withDocument { document in
            try Self.checkBinding(limit, in: document)
            let currentMonth = Self.monthKey(now)
            let totals = try Self.monthlyTotals(document, month: currentMonth)
            let committed = try Self.checkedAdd(totals.used, totals.reserved)
            return BudgetSnapshot(
                monthlyLimitUSD: Self.usd(limit),
                usedUSD: Self.usd(totals.used),
                reservedUSD: Self.usd(totals.reserved),
                availableUSD: Self.usd(max(0, limit - min(limit, committed))),
                month: currentMonth
            )
        }
    }

    public func costControlSnapshot(
        sessionID: UUID,
        dailyLimitUSD: Double?,
        sessionLimitUSD: Double?,
        now: Date = Date()
    ) throws -> APICostControlSnapshot {
        try withDocument { document in
            let day = Self.utcDayKey(now)
            let daily = try Self.windowTotals(document.reservations.filter { $0.utcDay == day })
            let session = try Self.windowTotals(document.reservations.filter { $0.sessionID == sessionID })
            return APICostControlSnapshot(
                dailyLimitUSD: dailyLimitUSD,
                dailyUsedUSD: Self.usd(daily.used),
                dailyReservedUSD: Self.usd(daily.reserved),
                sessionLimitUSD: sessionLimitUSD,
                sessionUsedUSD: Self.usd(session.used),
                sessionReservedUSD: Self.usd(session.reserved),
                hasUnresolvedCall: document.reservations.contains(where: { $0.actualMicros == nil })
            )
        }
    }

    /// Runs the checks `reserve` would apply without recording anything, so a
    /// run can be refused before its workspace and provider are prepared.
    public func checkReservation(
        sessionID: UUID,
        requestedUSD: Double,
        limits: APISpendLimits,
        now: Date = Date()
    ) throws {
        let requested = try Self.requestedMicros(requestedUSD)
        let caps = try Caps(limits)
        try withDocument { document in
            try Self.checkBinding(caps.monthly, in: document)
            try Self.checkCaps(document, sessionID: sessionID, requested: requested, caps: caps, now: now)
        }
    }

    /// Records an explicitly authorized run before any provider process starts.
    /// The run budget itself is not a hard provider limit; twice that amount is
    /// therefore reserved to retain conservative room for an estimated overrun.
    public func reserve(
        sessionID: UUID,
        requestedUSD: Double,
        explicitlyAuthorized: Bool,
        limits: APISpendLimits,
        now: Date = Date()
    ) throws -> APISpendReservation {
        guard explicitlyAuthorized else { throw BudgetLedgerError.authorizationRequired }
        let requested = try Self.requestedMicros(requestedUSD)
        let caps = try Caps(limits)

        return try withDocument { document in
            try Self.bind(caps.monthly, to: &document)
            try Self.checkCaps(document, sessionID: sessionID, requested: requested, caps: caps, now: now)
            guard document.reservations.count < Self.maximumReservations else {
                throw BudgetLedgerError.persistence("The number of budget records has reached the safety limit.")
            }
            let reservation = StoredSpendReservation(
                id: UUID(),
                sessionID: sessionID,
                requestedMicros: requested,
                reservedMicros: requested * 2,
                month: Self.monthKey(now),
                utcDay: Self.utcDayKey(now),
                createdAt: now,
                actualMicros: nil,
                reconciledAt: nil,
                chargedMonth: nil
            )
            document.reservations.append(reservation)
            return Self.publicReservation(reservation)
        }
    }

    /// Records validated, non-interactive cost output after a fresh API run.
    /// Passing `nil` deliberately leaves the reservation in place.
    public func reconcile(reservationID: UUID, actualUSD: Double?, now: Date = Date()) throws {
        let actual = try actualUSD.map(Self.actualMicros)
        try withDocument { document in
            guard let index = document.reservations.firstIndex(where: { $0.id == reservationID }) else {
                throw BudgetLedgerError.reservationNotFound(reservationID)
            }
            guard let actual else { return }
            _ = try Self.settle(&document.reservations[index], actual: actual, now: now)
        }
    }

    /// Returns unresolved reservations. The session ID is the stable recovery
    /// key shared with AgentBridge's audit records.
    public func unresolvedReservations() throws -> [APISpendReservation] {
        try withDocument { document in
            document.reservations.filter { $0.actualMicros == nil }.map(Self.publicReservation)
        }
    }

    /// Checks whether a session has a reservation and rejects a conflicting
    /// prior settlement without changing the ledger.
    public func validateSessionReconciliation(sessionID: UUID, actualUSD: Double) throws -> Bool {
        let actual = try Self.actualMicros(actualUSD)
        return try withDocument { document in
            guard let index = Self.reconciliationIndex(in: document, sessionID: sessionID) else { return false }
            let reservation = document.reservations[index]
            if let existing = reservation.actualMicros, existing != actual {
                throw BudgetLedgerError.conflictingReconciliation(reservation.id)
            }
            return true
        }
    }

    /// Manually settles the session's unresolved reservation using an actual
    /// amount verified by the user against the provider bill. Returns false if
    /// the ledger has no reservation for the session. When the session has
    /// nothing unresolved, repeating the amount of its latest settlement is
    /// idempotent and a different amount is rejected.
    @discardableResult
    public func reconcile(sessionID: UUID, actualUSD: Double, now: Date = Date()) throws -> Bool {
        let actual = try Self.actualMicros(actualUSD)
        return try withDocument { document in
            guard let index = Self.reconciliationIndex(in: document, sessionID: sessionID) else { return false }
            return try Self.settle(&document.reservations[index], actual: actual, now: now)
        }
    }

    // MARK: - Accounting

    private struct Cap {
        let usd: Double
        let micros: Int64
    }

    private struct Caps {
        let monthly: Int64
        let daily: Cap?
        let session: Cap?

        init(_ limits: APISpendLimits) throws {
            monthly = try APISpendLedger.monthlyLimitMicros(limits.monthlyUSD)
            daily = try limits.dailyUSD.map(APISpendLedger.windowCap)
            session = try limits.sessionUSD.map(APISpendLedger.windowCap)
        }
    }

    /// The session's unresolved reservation, or else its most recent one, so a
    /// retried manual settlement finds the call it already settled.
    private static func reconciliationIndex(in document: SpendDocument, sessionID: UUID) -> Int? {
        document.reservations.firstIndex { $0.sessionID == sessionID && $0.actualMicros == nil }
            ?? document.reservations.lastIndex { $0.sessionID == sessionID }
    }

    private static func checkCaps(
        _ document: SpendDocument,
        sessionID: UUID,
        requested: Int64,
        caps: Caps,
        now: Date
    ) throws {
        guard !document.reservations.contains(where: { $0.actualMicros == nil }) else {
            throw APICostLedgerError.unresolvedCall
        }
        let reserved = requested * 2
        if let cap = caps.daily {
            let day = utcDayKey(now)
            let totals = try windowTotals(document.reservations.filter { $0.utcDay == day })
            let committed = try checkedAdd(checkedAdd(totals.used, totals.reserved), reserved)
            guard committed <= cap.micros else {
                throw APICostLedgerError.dollarLimitReached(scope: "UTC daily", limitUSD: cap.usd, committedUSD: usd(committed))
            }
        }
        if let cap = caps.session {
            let totals = try windowTotals(document.reservations.filter { $0.sessionID == sessionID })
            let committed = try checkedAdd(checkedAdd(totals.used, totals.reserved), reserved)
            guard committed <= cap.micros else {
                throw APICostLedgerError.dollarLimitReached(scope: "Current Session", limitUSD: cap.usd, committedUSD: usd(committed))
            }
        }
        let totals = try monthlyTotals(document, month: monthKey(now))
        let committed = try checkedAdd(totals.used, totals.reserved)
        guard try checkedAdd(committed, reserved) <= caps.monthly else {
            throw BudgetLedgerError.insufficientBudget(
                requiredUSD: usd(reserved),
                availableUSD: usd(max(0, caps.monthly - min(caps.monthly, committed)))
            )
        }
    }

    private static func settle(_ reservation: inout StoredSpendReservation, actual: Int64, now: Date) throws -> Bool {
        if let existing = reservation.actualMicros {
            guard existing == actual else { throw BudgetLedgerError.conflictingReconciliation(reservation.id) }
            return true
        }
        reservation.actualMicros = actual
        reservation.reconciledAt = now
        reservation.chargedMonth = monthKey(now)
        return true
    }

    private static func bind(_ limit: Int64, to document: inout SpendDocument) throws {
        try checkBinding(limit, in: document)
        document.monthlyLimitMicros = limit
    }

    private static func checkBinding(_ limit: Int64, in document: SpendDocument) throws {
        guard document.monthlyLimitMicros == nil || document.monthlyLimitMicros == limit else {
            throw BudgetLedgerError.invalidLedger
        }
    }

    private static func monthlyTotals(_ document: SpendDocument, month: String) throws -> (used: Int64, reserved: Int64) {
        var used: Int64 = 0
        var reserved: Int64 = 0
        for reservation in document.reservations {
            if let actual = reservation.actualMicros {
                if reservation.chargedMonth == month { used = try checkedAdd(used, actual) }
            } else {
                reserved = try checkedAdd(reserved, reservation.reservedMicros)
            }
        }
        return (used, reserved)
    }

    private static func windowTotals(_ reservations: [StoredSpendReservation]) throws -> (used: Int64, reserved: Int64) {
        var used: Int64 = 0
        var reserved: Int64 = 0
        for reservation in reservations {
            if let actual = reservation.actualMicros {
                used = try checkedAdd(used, actual)
            } else {
                reserved = try checkedAdd(reserved, reservation.reservedMicros)
            }
        }
        return (used, reserved)
    }

    // MARK: - Amounts

    private static func monthlyLimitMicros(_ usd: Double) throws -> Int64 {
        guard usd.isFinite, usd > 0, let micros = microDollars(usd, rounding: .down), micros > 0 else {
            throw BudgetLedgerError.invalidMonthlyLimit
        }
        return micros
    }

    private static func windowCap(_ usd: Double) throws -> Cap {
        guard usd.isFinite, usd >= 0.01, usd <= 100_000,
              let micros = microDollars(usd, rounding: .down) else {
            throw APICostLedgerError.invalidAmount
        }
        return Cap(usd: usd, micros: micros)
    }

    private static func requestedMicros(_ usd: Double) throws -> Int64 {
        guard usd.isFinite, usd > 0,
              let micros = microDollars(usd, rounding: .up), micros > 0, micros <= Int64.max / 2 else {
            throw BudgetLedgerError.invalidRequestedBudget
        }
        return micros
    }

    private static func actualMicros(_ usd: Double) throws -> Int64 {
        guard usd.isFinite, usd >= 0, let micros = microDollars(usd, rounding: .up) else {
            throw BudgetLedgerError.invalidActualCost
        }
        return micros
    }

    private static func microDollars(_ amount: Double, rounding: NSDecimalNumber.RoundingMode) -> Int64? {
        guard amount.isFinite, let decimal = Decimal(string: String(amount), locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        var scaled = decimal * Decimal(microsPerUSD)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, rounding)
        let number = NSDecimalNumber(decimal: rounded)
        guard number != .notANumber,
              number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending,
              number.compare(NSDecimalNumber(value: Int64.min)) != .orderedAscending else {
            return nil
        }
        return number.int64Value
    }

    private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow, sum >= 0 else { throw BudgetLedgerError.invalidLedger }
        return sum
    }

    private static func usd(_ micros: Int64) -> Double {
        Double(micros) / Double(microsPerUSD)
    }

    private static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private static func monthKey(_ date: Date) -> String {
        let components = utcCalendar().dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private static func utcDayKey(_ date: Date) -> String {
        let components = utcCalendar().dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func isMonthKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]) else { return false }
        return year >= 1 && (1...12).contains(month)
    }

    private static func isUTCDayKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return false
        }
        let calendar = utcCalendar()
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return false }
        let actual = calendar.dateComponents([.year, .month, .day], from: date)
        return actual.year == year && actual.month == month && actual.day == day
    }

    private static func publicReservation(_ reservation: StoredSpendReservation) -> APISpendReservation {
        APISpendReservation(
            id: reservation.id,
            sessionID: reservation.sessionID,
            requestedUSD: usd(reservation.requestedMicros),
            reservedUSD: usd(reservation.reservedMicros),
            month: reservation.month,
            utcDay: reservation.utcDay
        )
    }

    // MARK: - Persistence

    private func withDocument<T>(_ operation: (inout SpendDocument) throws -> T) throws -> T {
        try AgentBridgePrivateJSONDocument.withLockedRoot(rootURL: rootURL) { directoryDescriptor in
            guard var document = try Self.readDocument(directoryDescriptor: directoryDescriptor) else {
                throw BudgetLedgerError.invalidLedger
            }
            let originalData = try Self.encode(document)
            let result = try operation(&document)
            if try Self.encode(document) != originalData {
                try Self.writeDocument(document, directoryDescriptor: directoryDescriptor)
            }
            return result
        }
    }

    private static func readDocument(directoryDescriptor: Int32) throws -> SpendDocument? {
        guard let data = try AgentBridgePrivateJSONDocument.read(
            fileName: fileName,
            maximumBytes: maximumStoredBytes,
            directoryDescriptor: directoryDescriptor
        ) else { return nil }
        let document: SpendDocument
        do {
            document = try makeDecoder().decode(SpendDocument.self, from: data)
        } catch {
            throw BudgetLedgerError.invalidLedger
        }
        try validate(document)
        return document
    }

    private static func writeDocument(_ document: SpendDocument, directoryDescriptor: Int32) throws {
        try validate(document)
        try AgentBridgePrivateJSONDocument.write(
            encode(document),
            fileName: fileName,
            maximumBytes: maximumStoredBytes,
            directoryDescriptor: directoryDescriptor
        )
    }

    private static func validate(_ document: SpendDocument) throws {
        guard document.schemaVersion == schemaVersion,
              (document.monthlyLimitMicros ?? 1) > 0,
              document.reservations.count <= maximumReservations else {
            throw BudgetLedgerError.invalidLedger
        }
        var reservationIDs = Set<UUID>()
        for reservation in document.reservations {
            guard reservation.requestedMicros > 0,
                  reservation.requestedMicros <= Int64.max / 2,
                  reservation.reservedMicros == reservation.requestedMicros * 2,
                  isMonthKey(reservation.month),
                  isUTCDayKey(reservation.utcDay),
                  reservationIDs.insert(reservation.id).inserted else {
                throw BudgetLedgerError.invalidLedger
            }
            switch (reservation.actualMicros, reservation.reconciledAt, reservation.chargedMonth) {
            case (nil, nil, nil):
                break
            case (.some(let actual), .some, .some(let month)) where actual >= 0 && isMonthKey(month):
                break
            default:
                throw BudgetLedgerError.invalidLedger
            }
        }
        // Every window total is a subset of this sum, so bounding it here
        // keeps later accounting free of overflow.
        _ = try document.reservations.reduce(Int64(0)) { try checkedAdd($0, $1.actualMicros ?? $1.reservedMicros) }
    }

    private static func encode(_ document: SpendDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(document)
        } catch {
            throw BudgetLedgerError.persistence("Could not encode the budget record.")
        }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Legacy import

    /// Merges the monthly ledger and the day/session ledger of earlier
    /// releases. A session in both keeps the larger requested amount and the
    /// larger settled cost; a cost settled only in the day/session ledger is
    /// charged to the current month because its settlement date was not kept.
    private static func importLegacy(monthlyRootURL: URL?, costRootURL: URL?, now: Date) throws -> SpendDocument {
        let monthly = try readLegacy(LegacyMonthlyDocument.self, fileName: legacyMonthlyFileName, in: monthlyRootURL)
        let cost = try readLegacy(LegacyCostDocument.self, fileName: legacyCostFileName, in: costRootURL)
        guard monthly.map({ $0.schemaVersion == 1 && $0.monthlyLimitMicros > 0 }) ?? true,
              cost.map({ $0.schemaVersion == 1 }) ?? true else {
            throw BudgetLedgerError.invalidLedger
        }

        var order: [UUID] = []
        var bySession: [UUID: StoredSpendReservation] = [:]
        for record in monthly?.reservations ?? [] {
            guard bySession[record.sessionID] == nil,
                  record.requestedMicros > 0, record.requestedMicros <= Int64.max / 2 else {
                throw BudgetLedgerError.invalidLedger
            }
            order.append(record.sessionID)
            bySession[record.sessionID] = StoredSpendReservation(
                id: record.id,
                sessionID: record.sessionID,
                requestedMicros: record.requestedMicros,
                reservedMicros: record.requestedMicros * 2,
                month: record.month,
                utcDay: utcDayKey(record.createdAt),
                createdAt: record.createdAt,
                actualMicros: record.actualMicros,
                reconciledAt: record.reconciledAt,
                chargedMonth: record.chargedMonth
            )
        }

        var costSessionIDs = Set<UUID>()
        for record in cost?.reservations ?? [] {
            guard costSessionIDs.insert(record.sessionID).inserted,
                  record.requestedMicros > 0, record.requestedMicros <= Int64.max / 2 else {
                throw BudgetLedgerError.invalidLedger
            }
            guard var merged = bySession[record.sessionID] else {
                order.append(record.sessionID)
                bySession[record.sessionID] = StoredSpendReservation(
                    id: record.id,
                    sessionID: record.sessionID,
                    requestedMicros: record.requestedMicros,
                    reservedMicros: record.requestedMicros * 2,
                    month: monthKey(record.createdAt),
                    utcDay: record.utcDay,
                    createdAt: record.createdAt,
                    actualMicros: record.actualMicros,
                    reconciledAt: record.actualMicros == nil ? nil : now,
                    chargedMonth: record.actualMicros == nil ? nil : monthKey(now)
                )
                continue
            }
            merged.requestedMicros = max(merged.requestedMicros, record.requestedMicros)
            merged.reservedMicros = merged.requestedMicros * 2
            merged.utcDay = record.utcDay
            merged.createdAt = min(merged.createdAt, record.createdAt)
            switch (merged.actualMicros, record.actualMicros) {
            case (.some(let monthlyActual), .some(let costActual)):
                merged.actualMicros = max(monthlyActual, costActual)
            case (nil, .some(let costActual)):
                merged.actualMicros = costActual
                merged.reconciledAt = now
                merged.chargedMonth = monthKey(now)
            default:
                break
            }
            bySession[record.sessionID] = merged
        }

        let document = SpendDocument(
            monthlyLimitMicros: monthly?.monthlyLimitMicros,
            reservations: order.compactMap { bySession[$0] }
        )
        try validate(document)
        return document
    }

    private static func readLegacy<T: Decodable>(_ type: T.Type, fileName: String, in rootURL: URL?) throws -> T? {
        guard let rootURL else { return nil }
        let directoryDescriptor = rootURL.standardizedFileURL.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw BudgetLedgerError.persistence("Could not safely open the budget record file.")
        }
        defer { _ = close(directoryDescriptor) }
        guard let data = try AgentBridgePrivateJSONDocument.read(
            fileName: fileName,
            maximumBytes: maximumLegacyBytes,
            directoryDescriptor: directoryDescriptor
        ) else { return nil }
        do {
            return try makeDecoder().decode(T.self, from: data)
        } catch {
            throw BudgetLedgerError.invalidLedger
        }
    }
}

private struct SpendDocument: Codable {
    var schemaVersion = APISpendLedger.schemaVersion
    var monthlyLimitMicros: Int64?
    var reservations: [StoredSpendReservation] = []
}

private struct StoredSpendReservation: Codable {
    let id: UUID
    let sessionID: UUID
    var requestedMicros: Int64
    var reservedMicros: Int64
    let month: String
    var utcDay: String
    var createdAt: Date
    var actualMicros: Int64?
    var reconciledAt: Date?
    var chargedMonth: String?
}

private struct LegacyMonthlyDocument: Decodable {
    let schemaVersion: Int
    let monthlyLimitMicros: Int64
    let reservations: [LegacyMonthlyReservation]
}

private struct LegacyMonthlyReservation: Decodable {
    let id: UUID
    let sessionID: UUID
    let requestedMicros: Int64
    let month: String
    let createdAt: Date
    let actualMicros: Int64?
    let reconciledAt: Date?
    let chargedMonth: String?
}

private struct LegacyCostDocument: Decodable {
    let schemaVersion: Int
    let reservations: [LegacyCostReservation]
}

private struct LegacyCostReservation: Decodable {
    let id: UUID
    let sessionID: UUID
    let requestedMicros: Int64
    let utcDay: String
    let createdAt: Date
    let actualMicros: Int64?
}
