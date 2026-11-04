import Darwin
import Foundation

/// Locally configured run limits for one provider account profile.
/// A missing limit means unlimited. These counters describe AgentBridge-managed
/// starts and do not represent provider quota or usage in other applications.
public struct UsageControlSettings: Codable, Equatable, Sendable {
    public var subscriptionFiveHourRunLimit: Int?
    public var subscriptionDailyRunLimit: Int?
    public var subscriptionWeeklyRunLimit: Int?
    public var subscriptionSessionRunLimit: Int?
    public var apiDailyRunLimit: Int?
    public var apiSessionRunLimit: Int?
    public var apiMonthlyLimitUSD: Double?
    public var apiDailyLimitUSD: Double?
    public var apiSessionLimitUSD: Double?
    public var disableFutureAPI: Bool
    public var macOSNotificationsEnabled: Bool
    public var notifiedThresholds: [String: Date]

    public init(
        subscriptionFiveHourRunLimit: Int? = nil,
        subscriptionDailyRunLimit: Int? = nil,
        subscriptionWeeklyRunLimit: Int? = nil,
        subscriptionSessionRunLimit: Int? = nil,
        apiDailyRunLimit: Int? = nil,
        apiSessionRunLimit: Int? = nil,
        apiMonthlyLimitUSD: Double? = nil,
        apiDailyLimitUSD: Double? = nil,
        apiSessionLimitUSD: Double? = nil,
        disableFutureAPI: Bool = false,
        macOSNotificationsEnabled: Bool = false,
        notifiedThresholds: [String: Date] = [:]
    ) {
        self.subscriptionFiveHourRunLimit = subscriptionFiveHourRunLimit
        self.subscriptionDailyRunLimit = subscriptionDailyRunLimit
        self.subscriptionWeeklyRunLimit = subscriptionWeeklyRunLimit
        self.subscriptionSessionRunLimit = subscriptionSessionRunLimit
        self.apiDailyRunLimit = apiDailyRunLimit
        self.apiSessionRunLimit = apiSessionRunLimit
        self.apiMonthlyLimitUSD = apiMonthlyLimitUSD
        self.apiDailyLimitUSD = apiDailyLimitUSD
        self.apiSessionLimitUSD = apiSessionLimitUSD
        self.disableFutureAPI = disableFutureAPI
        self.macOSNotificationsEnabled = macOSNotificationsEnabled
        self.notifiedThresholds = notifiedThresholds
    }

    public func validate() throws {
        let runLimits = [
            subscriptionFiveHourRunLimit,
            subscriptionDailyRunLimit,
            subscriptionWeeklyRunLimit,
            subscriptionSessionRunLimit,
            apiDailyRunLimit,
            apiSessionRunLimit
        ]
        guard runLimits.allSatisfy({ $0 == nil || (1...100_000).contains($0!) }) else {
            throw UsageControlError.invalidRunLimit
        }
        for limit in [apiMonthlyLimitUSD, apiDailyLimitUSD, apiSessionLimitUSD].compactMap({ $0 }) {
            guard limit.isFinite, (0.01...100_000).contains(limit) else {
                throw UsageControlError.invalidAPIDollarLimit
            }
        }
        guard notifiedThresholds.count <= 64,
              notifiedThresholds.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 160 }) else {
            throw UsageControlError.persistence("門檻提醒記錄格式不正確。")
        }
    }
}

public enum UsageControlError: Error, LocalizedError, Equatable {
    case invalidRunLimit
    case invalidAPIDollarLimit
    case apiMonthlyLimitRequired(UUID)
    case apiDisabled(UUID)
    case apiMonthlyLimitReached
    case apiReconciliationConfirmationRequired
    case apiReconciliationNotFound(UUID)
    case runLimitReached(window: UsageLimitWindow, used: Int, limit: Int)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRunLimit:
            "本機執行上限必須是 1 到 100000 的整數；留空代表不限。"
        case .invalidAPIDollarLimit:
            "Claude API 本機 USD 上限必須是 US$0.01 到 US$100000 之間的有限金額。"
        case .apiMonthlyLimitRequired(let profileID):
            "Claude 帳戶 \(profileID.uuidString) 尚未設定本機 API 月上限；設定前不會啟用 API 執行。"
        case .apiDisabled:
            "此 Claude 帳戶已停用後續 API 執行。"
        case .apiMonthlyLimitReached:
            "AgentBridge 本機 Claude API 月上限已用完；本次不會呼叫模型服務。"
        case .apiReconciliationConfirmationRequired:
            "手動結算前必須明確確認金額已對照 Anthropic provider 帳單。"
        case .apiReconciliationNotFound(let sessionID):
            "找不到工作階段 \(sessionID.uuidString) 的未結算 Claude API 預留紀錄。"
        case .runLimitReached(let window, let used, let limit):
            "已達 AgentBridge 本機\(window.displayName)執行上限（\(used)/\(limit)）；請等候用量離開此期間或調整本機上限。"
        case .persistence(let message):
            "無法安全讀寫本機用量控制：\(message)"
        }
    }
}

public enum UsageLimitWindow: String, Codable, Sendable {
    case fiveHours
    case rolling24Hours
    case rollingSevenDays
    case currentSession

    public var displayName: String {
        switch self {
        case .fiveHours: "近 5 小時"
        case .rolling24Hours: "近 24 小時"
        case .rollingSevenDays: "近 7 天"
        case .currentSession: "目前工作階段"
        }
    }
}

public struct UsageActivityBucket: Identifiable, Equatable, Sendable {
    public let index: Int
    public let label: String
    public let runCount: Int
    public var id: Int { index }

    public init(index: Int, label: String, runCount: Int) {
        self.index = index
        self.label = label
        self.runCount = runCount
    }
}

public struct UsageStatisticsSnapshot: Equatable, Sendable {
    public let provider: AgentProvider
    public let accountProfileID: UUID
    public let generatedAt: Date
    public let subscriptionFiveHourRuns: Int
    public let subscriptionDailyRuns: Int
    public let subscriptionSevenDayRuns: Int
    public let subscriptionSessionRuns: Int
    public let apiDailyRuns: Int
    public let apiSessionRuns: Int
    public let localDailyRuns: Int
    public let localSessionRuns: Int
    public let sevenDayBuckets: [UsageActivityBucket]

    public init(
        provider: AgentProvider,
        accountProfileID: UUID,
        generatedAt: Date,
        subscriptionFiveHourRuns: Int,
        subscriptionDailyRuns: Int,
        subscriptionSevenDayRuns: Int,
        subscriptionSessionRuns: Int,
        apiDailyRuns: Int,
        apiSessionRuns: Int,
        localDailyRuns: Int = 0,
        localSessionRuns: Int = 0,
        sevenDayBuckets: [UsageActivityBucket]
    ) {
        self.provider = provider
        self.accountProfileID = accountProfileID
        self.generatedAt = generatedAt
        self.subscriptionFiveHourRuns = subscriptionFiveHourRuns
        self.subscriptionDailyRuns = subscriptionDailyRuns
        self.subscriptionSevenDayRuns = subscriptionSevenDayRuns
        self.subscriptionSessionRuns = subscriptionSessionRuns
        self.apiDailyRuns = apiDailyRuns
        self.apiSessionRuns = apiSessionRuns
        self.localDailyRuns = localDailyRuns
        self.localSessionRuns = localSessionRuns
        self.sevenDayBuckets = sevenDayBuckets
    }
}

/// Pure aggregation of persisted AgentBridge start events. TUI contents,
/// provider transcripts, credentials, and provider quota are never inspected.
public enum UsageStatisticsAggregator {
    private static let fiveHours: TimeInterval = 5 * 60 * 60
    private static let oneDay: TimeInterval = 24 * 60 * 60
    private static let oneWeek: TimeInterval = 7 * 24 * 60 * 60
    private static let subscriptionKinds: Set<String> = ["run.started", "interactive.started"]
    private static let subscriptionReservationKinds: Set<String> = ["usage.subscription.reserved"]
    private static let apiKinds: Set<String> = ["api.run.authorized"]
    private static let apiReservationKinds: Set<String> = ["usage.api.reserved"]
    private static let localKinds: Set<String> = ["local.run.started"]

    public static func aggregate(
        provider: AgentProvider,
        accountProfileID: UUID,
        sessions: [SessionRecord],
        events: [AuditEvent],
        additionalActivitySessionIDs: Set<UUID> = [],
        selectedSessionID: UUID? = nil,
        now: Date = Date()
    ) -> UsageStatisticsSnapshot {
        let matchingSessionIDs = Set(sessions.compactMap { session -> UUID? in
            let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
            guard session.provider == provider, profileID == accountProfileID else { return nil }
            return session.id
        }).union(additionalActivitySessionIDs)
        let uniqueEvents = Dictionary(events
            .filter { matchingSessionIDs.contains($0.sessionID) && $0.timestamp <= now }
            .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let subscriptionStarts = uniqueEvents.values.filter {
            subscriptionKinds.contains($0.kind)
        }
        let subscriptionReservations = uniqueEvents.values.filter {
            subscriptionReservationKinds.contains($0.kind)
        }
        let apiStarts = uniqueEvents.values.filter {
            apiKinds.contains($0.kind)
        }
        let apiReservations = uniqueEvents.values.filter {
            apiReservationKinds.contains($0.kind)
        }
        let localEvents = uniqueEvents.values.filter { localKinds.contains($0.kind) }
        let subscriptionEvents = countedEvents(reservations: subscriptionReservations, starts: subscriptionStarts)
        let apiEvents = countedEvents(reservations: apiReservations, starts: apiStarts)

        let fiveHourStart = now.addingTimeInterval(-fiveHours)
        let dayStart = now.addingTimeInterval(-oneDay)
        let weekStart = now.addingTimeInterval(-oneWeek)
        let recentSubscriptionEvents = subscriptionEvents.filter { $0.timestamp >= weekStart }
        var bucketCounts = Array(repeating: 0, count: 7)
        for event in recentSubscriptionEvents {
            let offset = event.timestamp.timeIntervalSince(weekStart)
            let index = min(6, max(0, Int(offset / oneDay)))
            bucketCounts[index] += 1
        }
        let buckets = bucketCounts.enumerated().map { index, count in
            UsageActivityBucket(index: index, label: "\(6 - index)–\(7 - index)d", runCount: count)
        }
        let sessionMatches: (AuditEvent) -> Bool = { event in
            guard let selectedSessionID else { return false }
            return event.sessionID == selectedSessionID
        }

        return UsageStatisticsSnapshot(
            provider: provider,
            accountProfileID: accountProfileID,
            generatedAt: now,
            subscriptionFiveHourRuns: subscriptionEvents.filter { $0.timestamp >= fiveHourStart }.count,
            subscriptionDailyRuns: subscriptionEvents.filter { $0.timestamp >= dayStart }.count,
            subscriptionSevenDayRuns: recentSubscriptionEvents.count,
            subscriptionSessionRuns: subscriptionEvents.filter(sessionMatches).count,
            apiDailyRuns: apiEvents.filter { $0.timestamp >= dayStart }.count,
            apiSessionRuns: apiEvents.filter(sessionMatches).count,
            localDailyRuns: localEvents.filter { $0.timestamp >= dayStart }.count,
            localSessionRuns: localEvents.filter(sessionMatches).count,
            sevenDayBuckets: buckets
        )
    }

    private static func countedEvents(reservations: [AuditEvent], starts: [AuditEvent]) -> [AuditEvent] {
        var matchedStartIDs: Set<UUID> = []
        let startsBySession = Dictionary(grouping: starts, by: \.sessionID).mapValues {
            $0.sorted { $0.timestamp < $1.timestamp }
        }
        for reservation in reservations.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let candidate = startsBySession[reservation.sessionID]?.first(where: {
                $0.timestamp >= reservation.timestamp
                    && $0.timestamp.timeIntervalSince(reservation.timestamp) <= 5 * 60
                    && !matchedStartIDs.contains($0.id)
            }) else { continue }
            matchedStartIDs.insert(candidate.id)
        }
        return reservations + starts.filter { !matchedStartIDs.contains($0.id) }
    }
}

public struct UsageControlAuditRecord: Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let provider: AgentProvider
    public let accountProfileID: UUID
    public let kind: String
    public let details: [String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        provider: AgentProvider,
        accountProfileID: UUID,
        kind: String,
        details: [String]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.provider = provider
        self.accountProfileID = accountProfileID
        self.kind = kind
        self.details = details
    }
}

/// Private settings and run limits kept separately from APISpendLedger accounting.
/// This store uses a private directory, no-follow file opens, a cross-process
/// lock, bounded input, and atomic replacement.
public final class UsageControlStore: @unchecked Sendable {
    public let rootURL: URL
    private let fileURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let instanceLock = NSLock()
    private static let maximumFileSize = 1 * 1_024 * 1024

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.fileURL = rootURL.appendingPathComponent(".usage-controls.json")
        self.lockURL = rootURL.appendingPathComponent(".usage-controls.lock")
        self.fileManager = fileManager
        try AuditStore.createPrivateDirectory(self.rootURL, fileManager: fileManager)
        try withLock {
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try readDocument()
            } else {
                try writeDocument(UsageControlDocument())
            }
        }
    }

    public func settings(provider: AgentProvider, accountProfileID: UUID) throws -> UsageControlSettings {
        try withLock {
            try readDocument().entries.first(where: {
                $0.provider == provider && $0.accountProfileID == accountProfileID
            })?.settings ?? UsageControlSettings()
        }
    }

    public func save(
        _ settings: UsageControlSettings,
        provider: AgentProvider,
        accountProfileID: UUID
    ) throws {
        try settings.validate()
        try withLock {
            var document = try readDocument()
            let previousSettings: UsageControlSettings
            let entryIndex = document.entries.firstIndex(where: {
                $0.provider == provider && $0.accountProfileID == accountProfileID
            })
            if let entryIndex {
                previousSettings = document.entries[entryIndex].settings
            } else {
                previousSettings = UsageControlSettings()
            }
            let changes = Self.settingChanges(from: previousSettings, to: settings)
            let newThresholdKeys = settings.notifiedThresholds.compactMap { key, date in
                previousSettings.notifiedThresholds[key] == nil ? (key, date) : nil
            }
            if let entryIndex {
                document.entries[entryIndex].settings = settings
            } else {
                guard document.entries.count < 256 else {
                    throw UsageControlError.persistence("帳戶設定數量已達上限。")
                }
                document.entries.append(UsageControlEntry(
                    provider: provider,
                    accountProfileID: accountProfileID,
                    settings: settings
                ))
            }
            if !changes.isEmpty {
                document.auditHistory.append(UsageControlAuditRecord(
                    provider: provider,
                    accountProfileID: accountProfileID,
                    kind: "settings_changed",
                    details: changes
                ))
            }
            for (key, date) in newThresholdKeys {
                document.auditHistory.append(UsageControlAuditRecord(
                    timestamp: date,
                    provider: provider,
                    accountProfileID: accountProfileID,
                    kind: "threshold_reached",
                    details: [Self.safeThresholdAuditKey(key)]
                ))
            }
            if document.auditHistory.count > Self.maximumAuditRecords {
                document.auditHistory.removeFirst(document.auditHistory.count - Self.maximumAuditRecords)
            }
            try writeDocument(document)
        }
    }

    public func auditHistory(provider: AgentProvider, accountProfileID: UUID) throws -> [UsageControlAuditRecord] {
        try withLock {
            try readDocument().auditHistory.filter {
                $0.provider == provider && $0.accountProfileID == accountProfileID
            }
        }
    }

    /// Serializes a run-limit check and the caller's durable accepted-run
    /// marker under the same cross-process lock so concurrent sessions cannot
    /// pass a local run cap using the same stale count.
    public func withRunAuthorization<T>(
        provider: AgentProvider,
        accountProfileID: UUID,
        _ authorize: (UsageControlSettings) throws -> T
    ) throws -> T {
        try withLock {
            let settings = try readDocument().entries.first(where: {
                $0.provider == provider && $0.accountProfileID == accountProfileID
            })?.settings ?? UsageControlSettings()
            return try authorize(settings)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        return try PrivateLockFile.withLock(at: lockURL, error: { failure in
            switch failure {
            case .unavailable: UsageControlError.persistence("無法開啟鎖定檔。")
            case .notPrivateFile: UsageControlError.persistence("鎖定檔不是安全的一般檔案。")
            case .lockFailed: UsageControlError.persistence("無法鎖定本機用量設定。")
            }
        }, operation)
    }

    private func readDocument() throws -> UsageControlDocument {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return UsageControlDocument() }
            throw UsageControlError.persistence("無法安全開啟用量設定檔。")
        }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= off_t(Self.maximumFileSize) else {
            throw UsageControlError.persistence("用量設定檔格式或大小不安全。")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw UsageControlError.persistence("無法讀取用量設定檔。")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumFileSize else {
                throw UsageControlError.persistence("用量設定檔超過大小上限。")
            }
        }
        do {
            let document = try decoder.decode(UsageControlDocument.self, from: data)
            guard document.schemaVersion == 1, document.entries.count <= 256 else {
                throw UsageControlError.persistence("用量設定檔版本或項目數不支援。")
            }
            for entry in document.entries { try entry.settings.validate() }
            guard document.auditHistory.count <= Self.maximumAuditRecords,
                  document.auditHistory.allSatisfy({
                      !$0.kind.isEmpty && $0.kind.utf8.count <= 48
                          && !$0.details.isEmpty && $0.details.count <= 16
                          && $0.details.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
                  }) else {
                throw UsageControlError.persistence("用量設定稽核紀錄格式不正確。")
            }
            return document
        } catch let error as UsageControlError {
            throw error
        } catch {
            throw UsageControlError.persistence("用量設定檔格式錯誤。")
        }
    }

    private func writeDocument(_ document: UsageControlDocument) throws {
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw UsageControlError.persistence("無法編碼用量設定。")
        }
        guard data.count <= Self.maximumFileSize else {
            throw UsageControlError.persistence("用量設定檔超過大小上限。")
        }
        let temporaryURL = rootURL.appendingPathComponent(".usage-controls-\(UUID().uuidString.lowercased()).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw UsageControlError.persistence("無法建立暫存用量設定檔。") }
        defer {
            _ = close(descriptor)
            try? fileManager.removeItem(at: temporaryURL)
        }
        do {
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw UsageControlError.persistence("無法寫入用量設定檔。")
                    }
                    guard count > 0 else { throw UsageControlError.persistence("用量設定檔寫入未完成。") }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw UsageControlError.persistence("無法同步用量設定檔。") }
            if fileManager.fileExists(atPath: fileURL.path) {
                var existing = stat()
                guard lstat(fileURL.path, &existing) == 0, (existing.st_mode & S_IFMT) == S_IFREG else {
                    throw UsageControlError.persistence("用量設定檔不能是符號連結或非一般檔案。")
                }
            }
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                throw UsageControlError.persistence("無法安全更新用量設定檔。")
            }
        } catch let error as UsageControlError {
            throw error
        } catch {
            throw UsageControlError.persistence("無法儲存用量設定檔。")
        }
    }

    private static let maximumAuditRecords = 256

    private static func settingChanges(from old: UsageControlSettings, to new: UsageControlSettings) -> [String] {
        var changes: [String] = []
        func record<T: Equatable>(_ field: String, oldValue: T, newValue: T) {
            guard oldValue != newValue else { return }
            changes.append("\(field) changed")
        }
        func recordOptional<T: CustomStringConvertible & Equatable>(_ field: String, oldValue: T?, newValue: T?) {
            guard oldValue != newValue else { return }
            let oldText = oldValue.map(String.init(describing:)) ?? "unlimited/unset"
            let newText = newValue.map(String.init(describing:)) ?? "unlimited/unset"
            changes.append("\(field): \(oldText) -> \(newText)")
        }
        recordOptional("subscriptionFiveHourRunLimit", oldValue: old.subscriptionFiveHourRunLimit, newValue: new.subscriptionFiveHourRunLimit)
        recordOptional("subscriptionDailyRunLimit", oldValue: old.subscriptionDailyRunLimit, newValue: new.subscriptionDailyRunLimit)
        recordOptional("subscriptionWeeklyRunLimit", oldValue: old.subscriptionWeeklyRunLimit, newValue: new.subscriptionWeeklyRunLimit)
        recordOptional("subscriptionSessionRunLimit", oldValue: old.subscriptionSessionRunLimit, newValue: new.subscriptionSessionRunLimit)
        recordOptional("apiDailyRunLimit", oldValue: old.apiDailyRunLimit, newValue: new.apiDailyRunLimit)
        recordOptional("apiSessionRunLimit", oldValue: old.apiSessionRunLimit, newValue: new.apiSessionRunLimit)
        recordOptional("apiMonthlyLimitUSD", oldValue: old.apiMonthlyLimitUSD, newValue: new.apiMonthlyLimitUSD)
        recordOptional("apiDailyLimitUSD", oldValue: old.apiDailyLimitUSD, newValue: new.apiDailyLimitUSD)
        recordOptional("apiSessionLimitUSD", oldValue: old.apiSessionLimitUSD, newValue: new.apiSessionLimitUSD)
        record("disableFutureAPI", oldValue: old.disableFutureAPI, newValue: new.disableFutureAPI)
        record("macOSNotificationsEnabled", oldValue: old.macOSNotificationsEnabled, newValue: new.macOSNotificationsEnabled)
        return changes
    }

    private static func safeThresholdAuditKey(_ key: String) -> String {
        guard key.unicodeScalars.allSatisfy({ scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || ":-_".unicodeScalars.contains(scalar))
        }) else { return "nonstandard-threshold-key" }
        return key
    }
}

private struct UsageControlDocument: Codable {
    var schemaVersion = 1
    var entries: [UsageControlEntry] = []
    var auditHistory: [UsageControlAuditRecord] = []

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case entries
        case auditHistory
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        entries = try container.decodeIfPresent([UsageControlEntry].self, forKey: .entries) ?? []
        auditHistory = try container.decodeIfPresent([UsageControlAuditRecord].self, forKey: .auditHistory) ?? []
    }
}

private struct UsageControlEntry: Codable {
    let provider: AgentProvider
    let accountProfileID: UUID
    var settings: UsageControlSettings
}

public struct APICostControlSnapshot: Equatable, Sendable {
    public let dailyLimitUSD: Double?
    public let dailyUsedUSD: Double
    public let dailyReservedUSD: Double
    public let sessionLimitUSD: Double?
    public let sessionUsedUSD: Double
    public let sessionReservedUSD: Double
    public let hasUnresolvedCall: Bool

    public var dailyAvailableUSD: Double? {
        dailyLimitUSD.map { max(0, $0 - dailyUsedUSD - dailyReservedUSD) }
    }

    public var sessionAvailableUSD: Double? {
        sessionLimitUSD.map { max(0, $0 - sessionUsedUSD - sessionReservedUSD) }
    }

    public init(
        dailyLimitUSD: Double?,
        dailyUsedUSD: Double,
        dailyReservedUSD: Double,
        sessionLimitUSD: Double?,
        sessionUsedUSD: Double,
        sessionReservedUSD: Double,
        hasUnresolvedCall: Bool
    ) {
        self.dailyLimitUSD = dailyLimitUSD
        self.dailyUsedUSD = dailyUsedUSD
        self.dailyReservedUSD = dailyReservedUSD
        self.sessionLimitUSD = sessionLimitUSD
        self.sessionUsedUSD = sessionUsedUSD
        self.sessionReservedUSD = sessionReservedUSD
        self.hasUnresolvedCall = hasUnresolvedCall
    }
}

public struct APIReconciliationCandidate: Equatable, Identifiable, Sendable {
    public let accountProfileID: UUID
    public let session: SessionRecord
    public let requestedUSD: Double
    public let reservedUSD: Double

    public var id: UUID { session.id }

    public init(accountProfileID: UUID, session: SessionRecord, requestedUSD: Double, reservedUSD: Double) {
        self.accountProfileID = accountProfileID
        self.session = session
        self.requestedUSD = requestedUSD
        self.reservedUSD = reservedUSD
    }
}

/// Errors for the optional UTC-day and session USD caps that
/// `APISpendLedger` checks alongside the monthly cap.
public enum APICostLedgerError: Error, LocalizedError, Equatable {
    case invalidAmount
    case unresolvedCall
    case dollarLimitReached(scope: String, limitUSD: Double, committedUSD: Double)

    public var errorDescription: String? {
        switch self {
        case .invalidAmount:
            "Claude API 本機 USD 預算必須是有限且大於零的金額。"
        case .unresolvedCall:
            "前一次 Claude API 執行的費用尚未確認；為避免累積未知支出，請先在用量面板的「手動結算」或 `agentbridge budget reconcile` 結算後再執行。帳單尚未顯示時，可用完整預留金額保守結算。"
        case .dollarLimitReached(let scope, let limitUSD, let committedUSD):
            String(format: "Claude API 本機%@上限不足：US$%.2f / US$%.2f（包含新執行的預留金額）。本次不會呼叫模型服務。", scope, committedUSD, limitUSD)
        }
    }
}
