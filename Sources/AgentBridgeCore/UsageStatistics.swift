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
    /// Total reported tokens, in every usage mode. A run cannot know its tokens
    /// before it starts, so the last run allowed below a limit can pass it.
    public var fiveHourTokenLimit: Int?
    public var dailyTokenLimit: Int?
    public var weeklyTokenLimit: Int?
    public var sessionTokenLimit: Int?

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
        notifiedThresholds: [String: Date] = [:],
        fiveHourTokenLimit: Int? = nil,
        dailyTokenLimit: Int? = nil,
        weeklyTokenLimit: Int? = nil,
        sessionTokenLimit: Int? = nil
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
        self.fiveHourTokenLimit = fiveHourTokenLimit
        self.dailyTokenLimit = dailyTokenLimit
        self.weeklyTokenLimit = weeklyTokenLimit
        self.sessionTokenLimit = sessionTokenLimit
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
        let tokenLimits = [fiveHourTokenLimit, dailyTokenLimit, weeklyTokenLimit, sessionTokenLimit]
        guard tokenLimits.allSatisfy({ $0 == nil || (1_000...10_000_000_000).contains($0!) }) else {
            throw UsageControlError.invalidTokenLimit
        }
        for limit in [apiMonthlyLimitUSD, apiDailyLimitUSD, apiSessionLimitUSD].compactMap({ $0 }) {
            guard limit.isFinite, (0.01...100_000).contains(limit) else {
                throw UsageControlError.invalidAPIDollarLimit
            }
        }
        guard notifiedThresholds.count <= 64,
              notifiedThresholds.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 160 }) else {
            throw UsageControlError.persistence("The threshold alert record is malformed.")
        }
    }
}

public enum UsageControlError: Error, LocalizedError, Equatable {
    case invalidRunLimit
    case invalidTokenLimit
    case invalidAPIDollarLimit
    case apiMonthlyLimitRequired(UUID)
    case apiDisabled(UUID)
    case apiMonthlyLimitReached
    case apiReconciliationConfirmationRequired
    case apiReconciliationNotFound(UUID)
    case runLimitReached(window: UsageLimitWindow, used: Int, limit: Int)
    case tokenLimitReached(window: UsageLimitWindow, used: Int, limit: Int)
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRunLimit:
            "A local run limit must be an integer from 1 to 100000. Leave it empty for no limit."
        case .invalidTokenLimit:
            "A local token limit must be an integer from 1000 to 10000000000. Leave it empty for no limit."
        case .invalidAPIDollarLimit:
            "A Claude API local USD limit must be a finite amount between US$0.01 and US$100000."
        case .apiMonthlyLimitRequired(let profileID):
            "Claude account \(profileID.uuidString) has no local monthly API limit set. API runs remain disabled until one is configured."
        case .apiDisabled:
            "Further API runs are disabled for this Claude account."
        case .apiMonthlyLimitReached:
            "The AgentBridge local Claude API monthly limit has been used. No model service was called."
        case .apiReconciliationConfirmationRequired:
            "Before manual settlement, explicitly confirm that the amount was checked against the Anthropic bill."
        case .apiReconciliationNotFound(let sessionID):
            "Could not find session \(sessionID.uuidString) has no unsettled Claude API reservation record."
        case .runLimitReached(let window, let used, let limit):
            "AgentBridge local \(window.displayName) run limit reached (\(used)/\(limit)); wait for usage to leave this window or adjust the local limit."
        case .tokenLimitReached(let window, let used, let limit):
            "AgentBridge local \(window.displayName) token limit reached (\(used)/\(limit)); wait for usage to leave this window or adjust the local limit."
        case .persistence(let message):
            "Could not safely read or write local usage controls: \(message)"
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
        case .fiveHours: "Last 5 Hours"
        case .rolling24Hours: "Last 24 Hours"
        case .rollingSevenDays: "Last 7 Days"
        case .currentSession: "Current Session"
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
    /// Tokens the provider reported for AgentBridge runs, in every usage mode.
    public let fiveHourTokens: TokenUsage
    public let dailyTokens: TokenUsage
    public let sevenDayTokens: TokenUsage
    public let sessionTokens: TokenUsage

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
        sevenDayBuckets: [UsageActivityBucket],
        fiveHourTokens: TokenUsage = .zero,
        dailyTokens: TokenUsage = .zero,
        sevenDayTokens: TokenUsage = .zero,
        sessionTokens: TokenUsage = .zero
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
        self.fiveHourTokens = fiveHourTokens
        self.dailyTokens = dailyTokens
        self.sevenDayTokens = sevenDayTokens
        self.sessionTokens = sessionTokens
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
        let tokenEvents = uniqueEvents.values.filter { $0.kind == "usage.tokens" && $0.tokenUsage != nil }
        let tokens: ((AuditEvent) -> Bool) -> TokenUsage = { include in
            tokenEvents.filter(include).reduce(.zero) { $0 + ($1.tokenUsage ?? .zero) }
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
            sevenDayBuckets: buckets,
            fiveHourTokens: tokens { $0.timestamp >= fiveHourStart },
            dailyTokens: tokens { $0.timestamp >= dayStart },
            sevenDayTokens: tokens { $0.timestamp >= weekStart },
            sessionTokens: tokens(sessionMatches)
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
                    throw UsageControlError.persistence("The maximum number of account profiles has been reached.")
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
            case .unavailable: UsageControlError.persistence("Could not open the lock file.")
            case .notPrivateFile: UsageControlError.persistence("The lock file is not a secure regular file.")
            case .lockFailed: UsageControlError.persistence("Could not lock the local usage settings.")
            }
        }, operation)
    }

    private func readDocument() throws -> UsageControlDocument {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT { return UsageControlDocument() }
            throw UsageControlError.persistence("Could not safely open the usage settings file.")
        }
        defer { _ = close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0, metadata.st_size <= off_t(Self.maximumFileSize) else {
            throw UsageControlError.persistence("The usage settings file format or size is unsafe.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw UsageControlError.persistence("Could not read the usage settings file.")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maximumFileSize else {
                throw UsageControlError.persistence("The usage settings file exceeds the size limit.")
            }
        }
        do {
            let document = try decoder.decode(UsageControlDocument.self, from: data)
            guard document.schemaVersion == 1, document.entries.count <= 256 else {
                throw UsageControlError.persistence("The usage settings file version or number of entries is unsupported.")
            }
            for entry in document.entries { try entry.settings.validate() }
            guard document.auditHistory.count <= Self.maximumAuditRecords,
                  document.auditHistory.allSatisfy({
                      !$0.kind.isEmpty && $0.kind.utf8.count <= 48
                          && !$0.details.isEmpty && $0.details.count <= 16
                          && $0.details.allSatisfy { !$0.isEmpty && $0.utf8.count <= 256 }
                  }) else {
                throw UsageControlError.persistence("The usage settings audit record is malformed.")
            }
            return document
        } catch let error as UsageControlError {
            throw error
        } catch {
            throw UsageControlError.persistence("The usage settings file is malformed.")
        }
    }

    private func writeDocument(_ document: UsageControlDocument) throws {
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw UsageControlError.persistence("Could not encode the usage settings.")
        }
        guard data.count <= Self.maximumFileSize else {
            throw UsageControlError.persistence("The usage settings file exceeds the size limit.")
        }
        let temporaryURL = rootURL.appendingPathComponent(".usage-controls-\(UUID().uuidString.lowercased()).tmp")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw UsageControlError.persistence("Could not create a temporary usage settings file.") }
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
                        throw UsageControlError.persistence("Could not write the usage settings file.")
                    }
                    guard count > 0 else { throw UsageControlError.persistence("The usage settings file write did not complete.") }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw UsageControlError.persistence("Could not synchronize the usage settings file.") }
            if fileManager.fileExists(atPath: fileURL.path) {
                var existing = stat()
                guard lstat(fileURL.path, &existing) == 0, (existing.st_mode & S_IFMT) == S_IFREG else {
                    throw UsageControlError.persistence("The usage settings file cannot be a symlink or a non-regular file.")
                }
            }
            guard rename(temporaryURL.path, fileURL.path) == 0 else {
                throw UsageControlError.persistence("Could not safely update the usage settings file.")
            }
        } catch let error as UsageControlError {
            throw error
        } catch {
            throw UsageControlError.persistence("Could not save the usage settings file.")
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
        recordOptional("fiveHourTokenLimit", oldValue: old.fiveHourTokenLimit, newValue: new.fiveHourTokenLimit)
        recordOptional("dailyTokenLimit", oldValue: old.dailyTokenLimit, newValue: new.dailyTokenLimit)
        recordOptional("weeklyTokenLimit", oldValue: old.weeklyTokenLimit, newValue: new.weeklyTokenLimit)
        recordOptional("sessionTokenLimit", oldValue: old.sessionTokenLimit, newValue: new.sessionTokenLimit)
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
            "A Claude API local USD budget must be a finite amount greater than zero."
        case .unresolvedCall:
            "The previous Claude API run has an unconfirmed charge. To avoid accumulating unknown charges, settle it under Manual settlement in the usage panel or with `agentbridge budget reconcile` before running again. If the bill isn't available yet, you can settle conservatively at the full reserved amount."
        case .dollarLimitReached(let scope, let limitUSD, let committedUSD):
            String(format: "Claude API local %@ limit is insufficient: US$%.2f / US$%.2f (including the new run's reservation). The model service will not be called.", scope, committedUSD, limitUSD)
        }
    }
}
