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

/// A durable authorization reservation for one fresh API session.
public struct BudgetReservation: Codable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let requestedUSD: Double
    public let reservedUSD: Double
    public let month: String

    public init(id: UUID, sessionID: UUID, requestedUSD: Double, reservedUSD: Double, month: String) {
        self.id = id
        self.sessionID = sessionID
        self.requestedUSD = requestedUSD
        self.reservedUSD = reservedUSD
        self.month = month
    }
}

public enum BudgetLedgerError: Error, LocalizedError, Equatable {
    case invalidMonthlyLimit
    case invalidRequestedBudget
    case authorizationRequired
    case insufficientBudget(requiredUSD: Double, availableUSD: Double)
    case duplicateSession(UUID)
    case reservationNotFound(UUID)
    case invalidActualCost
    case conflictingReconciliation(UUID)
    case invalidLedger
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidMonthlyLimit:
            "每月 API 預算上限必須是有限且大於零的金額。"
        case .invalidRequestedBudget:
            "這次 API 執行的預算必須是有限且大於零的金額。"
        case .authorizationRequired:
            "呼叫 API 前必須明確授權這次執行及其預算。"
        case .insufficientBudget(let requiredUSD, let availableUSD):
            String(format: "預算不足：本次需預留 US$%.6f，目前可用 US$%.6f。", requiredUSD, availableUSD)
        case .duplicateSession(let id):
            "工作階段 \(id.uuidString) 已有預算紀錄，請建立新的工作階段。"
        case .reservationNotFound(let id):
            "找不到預算預留紀錄 \(id.uuidString)。"
        case .invalidActualCost:
            "API 實際費用必須是有限且大於或等於零的金額。"
        case .conflictingReconciliation(let id):
            "預算預留紀錄 \(id.uuidString) 已使用不同費用完成結算。"
        case .invalidLedger:
            "預算紀錄格式錯誤或與目前的預算上限不一致；為避免超支，已停止新的 API 執行。"
        case .persistence(let message):
            "無法安全讀寫預算紀錄：\(message)"
        }
    }
}

/// A private, cross-process-safe ledger for explicit Claude API run budgets.
///
/// The requested run budget is only a soft provider-side estimate, so this
/// ledger reserves twice the requested amount against the monthly cap. A
/// canceled, interrupted, or otherwise unreconciled reservation remains
/// charged until a validated cost is recorded. Reconciled cost is assigned to
/// the UTC month in which reconciliation occurs, and unresolved reservations
/// carry across month boundaries. All cost inputs are rounded up to the nearest
/// micro-dollar before accounting.
public final class BudgetLedger: @unchecked Sendable {
    public let rootURL: URL

    private let ledgerURL: URL
    private let lockURL: URL
    private let monthlyLimitMicros: Int64
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let instanceLock = NSLock()

    fileprivate static let schemaVersion = 1
    private static let maximumFileSize = 4 * 1_024 * 1_024
    private static let maximumReservations = 20_000
    private static let microsPerUSD: Int64 = 1_000_000

    public init(rootURL: URL, monthlyLimitUSD: Double = 140, fileManager: FileManager = .default) throws {
        guard monthlyLimitUSD.isFinite, monthlyLimitUSD > 0,
              let limit = Self.microDollars(monthlyLimitUSD, rounding: .down), limit > 0 else {
            throw BudgetLedgerError.invalidMonthlyLimit
        }
        guard rootURL.isFileURL, rootURL.path.hasPrefix("/"),
              !rootURL.path.split(separator: "/", omittingEmptySubsequences: true).contains("..") else {
            throw BudgetLedgerError.persistence("預算資料夾路徑無效。")
        }

        let standardizedRoot = rootURL.standardizedFileURL
        guard standardizedRoot.path != "/" else {
            throw BudgetLedgerError.persistence("不能將檔案系統根目錄用作預算資料夾。")
        }
        self.rootURL = standardizedRoot
        self.ledgerURL = standardizedRoot.appendingPathComponent(".budget-ledger.json")
        self.lockURL = standardizedRoot.appendingPathComponent(".budget-ledger.lock")
        self.monthlyLimitMicros = limit
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601

        try Self.createPrivateDirectory(standardizedRoot, fileManager: fileManager)
        try Self.createPrivateFile(lockURL)

        // Validate an existing ledger during initialization so corrupted or
        // differently capped state fails closed before a run can be launched.
        _ = try withLedgerLock {
            let document = try readDocument(allowMissing: true)
            try writeDocument(document)
            return document
        }
    }

    public func snapshot(now: Date = Date()) throws -> BudgetSnapshot {
        try withLedgerLock {
            let document = try readDocument()
            return try makeSnapshot(document, now: now)
        }
    }

    /// Records an explicitly authorized run before any provider process starts.
    /// The run budget itself is not a hard provider limit; twice that amount is
    /// therefore reserved to retain conservative room for an estimated overrun.
    public func reserve(
        sessionID: UUID,
        requestedUSD: Double,
        explicitlyAuthorized: Bool,
        now: Date = Date()
    ) throws -> BudgetReservation {
        guard explicitlyAuthorized else { throw BudgetLedgerError.authorizationRequired }
        guard requestedUSD.isFinite, requestedUSD > 0,
              let requested = Self.microDollars(requestedUSD, rounding: .up), requested > 0,
              requested <= Int64.max / 2 else {
            throw BudgetLedgerError.invalidRequestedBudget
        }
        let reserved = requested * 2

        return try withLedgerLock {
            var document = try readDocument()
            guard !document.reservations.contains(where: { $0.sessionID == sessionID }) else {
                throw BudgetLedgerError.duplicateSession(sessionID)
            }
            guard document.reservations.count < Self.maximumReservations else {
                throw BudgetLedgerError.persistence("預算紀錄數量已達安全上限。")
            }

            let totals = try accountingTotals(document, month: Self.monthKey(now))
            let requiredTotal = try Self.checkedAdd(Self.checkedAdd(totals.used, totals.reserved), reserved)
            guard requiredTotal <= monthlyLimitMicros else {
                throw BudgetLedgerError.insufficientBudget(
                    requiredUSD: Self.usd(reserved),
                    availableUSD: Self.usd(max(0, monthlyLimitMicros - min(monthlyLimitMicros, totals.used + totals.reserved)))
                )
            }

            let reservation = StoredReservation(
                id: UUID(),
                sessionID: sessionID,
                requestedMicros: requested,
                reservedMicros: reserved,
                month: Self.monthKey(now),
                createdAt: now,
                actualMicros: nil,
                reconciledAt: nil,
                chargedMonth: nil
            )
            document.reservations.append(reservation)
            try writeDocument(document)
            return Self.publicReservation(reservation)
        }
    }

    /// Records validated, non-interactive cost output after a fresh API run.
    /// Passing `nil` deliberately leaves the reservation in place.
    public func reconcile(reservationID: UUID, actualUSD: Double?, now: Date = Date()) throws {
        let actual: Int64?
        if let actualUSD {
            guard actualUSD.isFinite, actualUSD >= 0,
                  let micros = Self.microDollars(actualUSD, rounding: .up) else {
                throw BudgetLedgerError.invalidActualCost
            }
            actual = micros
        } else {
            actual = nil
        }

        try withLedgerLock {
            var document = try readDocument()
            guard let index = document.reservations.firstIndex(where: { $0.id == reservationID }) else {
                throw BudgetLedgerError.reservationNotFound(reservationID)
            }
            guard let actual else { return }

            if let existing = document.reservations[index].actualMicros {
                guard existing == actual else {
                    throw BudgetLedgerError.conflictingReconciliation(reservationID)
                }
                return
            }

            document.reservations[index].actualMicros = actual
            document.reservations[index].reconciledAt = now
            document.reservations[index].chargedMonth = Self.monthKey(now)
            try writeDocument(document)
        }
    }

    private func withLedgerLock<T>(_ operation: () throws -> T) throws -> T {
        instanceLock.lock()
        defer { instanceLock.unlock() }

        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw BudgetLedgerError.persistence("無法開啟鎖定檔。") }
        defer { _ = close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw BudgetLedgerError.persistence("鎖定檔不是安全的私有一般檔案。")
        }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno == EINTR { continue }
            throw BudgetLedgerError.persistence("無法鎖定預算紀錄。")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func readDocument(allowMissing: Bool = false) throws -> LedgerDocument {
        var pathMetadata = stat()
        if lstat(ledgerURL.path, &pathMetadata) != 0 {
            if errno == ENOENT, allowMissing {
                return LedgerDocument(monthlyLimitMicros: monthlyLimitMicros, reservations: [])
            }
            if errno == ENOENT { throw BudgetLedgerError.invalidLedger }
            throw BudgetLedgerError.persistence("無法檢查預算紀錄檔。")
        }
        guard (pathMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw BudgetLedgerError.persistence("預算紀錄不能是符號連結或非一般檔案。")
        }

        let descriptor = open(ledgerURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw BudgetLedgerError.persistence("無法安全開啟預算紀錄檔。") }
        defer { _ = close(descriptor) }

        var openedMetadata = stat()
        guard fstat(descriptor, &openedMetadata) == 0,
              (openedMetadata.st_mode & S_IFMT) == S_IFREG,
              openedMetadata.st_size >= 0,
              openedMetadata.st_size <= off_t(Self.maximumFileSize) else {
            throw BudgetLedgerError.persistence("預算紀錄檔格式或大小不安全。")
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw BudgetLedgerError.persistence("無法設定預算紀錄檔權限。")
        }

        var data = Data()
        data.reserveCapacity(Int(openedMetadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw BudgetLedgerError.persistence("無法讀取預算紀錄檔。")
            }
            if count == 0 { break }
            guard data.count + count <= Self.maximumFileSize else {
                throw BudgetLedgerError.persistence("預算紀錄檔超過大小上限。")
            }
            data.append(contentsOf: buffer[0..<count])
        }

        do {
            let document = try decoder.decode(LedgerDocument.self, from: data)
            try validate(document)
            return document
        } catch let error as BudgetLedgerError {
            throw error
        } catch {
            throw BudgetLedgerError.invalidLedger
        }
    }

    private func writeDocument(_ document: LedgerDocument) throws {
        try validate(document)
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw BudgetLedgerError.persistence("無法編碼預算紀錄。")
        }
        guard data.count <= Self.maximumFileSize else {
            throw BudgetLedgerError.persistence("預算紀錄檔超過大小上限。")
        }

        let temporaryURL = rootURL.appendingPathComponent(".budget-ledger.\(UUID().uuidString.lowercased()).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw BudgetLedgerError.persistence("無法建立暫存預算紀錄。") }
        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary { _ = unlink(temporaryURL.path) }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw BudgetLedgerError.persistence("無法設定暫存檔案權限。")
        }

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let count = write(descriptor, baseAddress.advanced(by: written), rawBuffer.count - written)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw BudgetLedgerError.persistence("無法寫入暫存預算紀錄。")
                }
                guard count > 0 else { throw BudgetLedgerError.persistence("預算紀錄寫入未完成。") }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else { throw BudgetLedgerError.persistence("無法同步預算紀錄。") }
        guard rename(temporaryURL.path, ledgerURL.path) == 0 else {
            throw BudgetLedgerError.persistence("無法原子更新預算紀錄。")
        }
        shouldRemoveTemporary = false

        let directoryDescriptor = open(rootURL.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            defer { _ = close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else {
                throw BudgetLedgerError.persistence("無法同步預算資料夾。")
            }
        }
    }

    private func validate(_ document: LedgerDocument) throws {
        guard document.schemaVersion == Self.schemaVersion,
              document.monthlyLimitMicros == monthlyLimitMicros,
              document.reservations.count <= Self.maximumReservations else {
            throw BudgetLedgerError.invalidLedger
        }

        var reservationIDs = Set<UUID>()
        var sessionIDs = Set<UUID>()
        for reservation in document.reservations {
            guard reservation.requestedMicros > 0,
                  reservation.requestedMicros <= Int64.max / 2,
                  reservation.reservedMicros == reservation.requestedMicros * 2,
                  Self.isMonthKey(reservation.month),
                  reservationIDs.insert(reservation.id).inserted,
                  sessionIDs.insert(reservation.sessionID).inserted else {
                throw BudgetLedgerError.invalidLedger
            }
            switch (reservation.actualMicros, reservation.reconciledAt, reservation.chargedMonth) {
            case (nil, nil, nil):
                break
            case (.some(let actual), .some, .some(let month)) where actual >= 0 && Self.isMonthKey(month):
                break
            default:
                throw BudgetLedgerError.invalidLedger
            }
        }
    }

    private func makeSnapshot(_ document: LedgerDocument, now: Date) throws -> BudgetSnapshot {
        let currentMonth = Self.monthKey(now)
        let totals = try accountingTotals(document, month: currentMonth)
        let committed = try Self.checkedAdd(totals.used, totals.reserved)
        let available = max(0, monthlyLimitMicros - min(monthlyLimitMicros, committed))
        return BudgetSnapshot(
            monthlyLimitUSD: Self.usd(monthlyLimitMicros),
            usedUSD: Self.usd(totals.used),
            reservedUSD: Self.usd(totals.reserved),
            availableUSD: Self.usd(available),
            month: currentMonth
        )
    }

    private func accountingTotals(_ document: LedgerDocument, month: String) throws -> (used: Int64, reserved: Int64) {
        var used: Int64 = 0
        var reserved: Int64 = 0
        for reservation in document.reservations {
            if let actual = reservation.actualMicros, reservation.chargedMonth == month {
                used = try Self.checkedAdd(used, actual)
            } else if reservation.actualMicros == nil {
                reserved = try Self.checkedAdd(reserved, reservation.reservedMicros)
            }
        }
        return (used, reserved)
    }

    private static func createPrivateDirectory(_ url: URL, fileManager: FileManager) throws {
        do {
            var metadata = stat()
            if lstat(url.path, &metadata) != 0 {
                guard errno == ENOENT else { throw BudgetLedgerError.persistence("無法檢查預算資料夾。") }
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            }
            guard lstat(url.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
                  chmod(url.path, mode_t(0o700)) == 0 else {
                throw BudgetLedgerError.persistence("預算資料夾必須是私有資料夾，不能是符號連結。")
            }
        } catch let error as BudgetLedgerError {
            throw error
        } catch {
            throw BudgetLedgerError.persistence("無法建立私有預算資料夾。")
        }
    }

    private static func createPrivateFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw BudgetLedgerError.persistence("無法建立安全的鎖定檔。") }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              fchmod(descriptor, mode_t(0o600)) == 0 else {
            throw BudgetLedgerError.persistence("鎖定檔必須是私有一般檔案。")
        }
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

    private static func monthKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private static func isMonthKey(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]) else { return false }
        return year >= 1 && (1...12).contains(month)
    }

    private static func publicReservation(_ reservation: StoredReservation) -> BudgetReservation {
        BudgetReservation(
            id: reservation.id,
            sessionID: reservation.sessionID,
            requestedUSD: usd(reservation.requestedMicros),
            reservedUSD: usd(reservation.reservedMicros),
            month: reservation.month
        )
    }
}

private struct LedgerDocument: Codable {
    let schemaVersion: Int
    let monthlyLimitMicros: Int64
    var reservations: [StoredReservation]

    init(monthlyLimitMicros: Int64, reservations: [StoredReservation]) {
        self.schemaVersion = BudgetLedger.schemaVersion
        self.monthlyLimitMicros = monthlyLimitMicros
        self.reservations = reservations
    }
}

private struct StoredReservation: Codable {
    let id: UUID
    let sessionID: UUID
    let requestedMicros: Int64
    let reservedMicros: Int64
    let month: String
    let createdAt: Date
    var actualMicros: Int64?
    var reconciledAt: Date?
    var chargedMonth: String?
}
