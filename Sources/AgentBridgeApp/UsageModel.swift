import AgentBridgeCore
import Foundation
import Observation
import UserNotifications

/// Local usage controls, Claude API ledger views, manual settlement and
/// threshold alerts for the selected account. Settings, account selection
/// and the selected session stay on `AppModel`, read through `app`.
@MainActor
@Observable
final class UsageModel {
    var localModelUsageStatistics: UsageStatisticsSnapshot?
    var budgetSnapshot: BudgetSnapshot?
    var apiCostSnapshot: APICostControlSnapshot?
    var usageStatistics: UsageStatisticsSnapshot?
    var usageControls = UsageControlSettings()
    var apiMonthlyLimitInput = ""
    var apiDailyLimitInput = ""
    var apiSessionLimitInput = ""
    var usageControlStatus = ""
    var usageAlerts: [String] = []
    var apiReconciliationCandidates: [APIReconciliationCandidate] = []
    var apiReconciliationSessionID: UUID?
    var apiReconciliationActualUSD = ""
    var apiReconciliationConfirmed = false
    /// The status the view shows in a calm color; any other status is a prompt or an error.
    static let reconciliationSettledMessage = "Cost settled manually."
    var apiReconciliationStatus = ""
    @ObservationIgnored var loadedUsageControlsScopeKey: String?
    @ObservationIgnored private var refreshedUsageStatisticsScopeKey: String?
    @ObservationIgnored private var lastUsageStatisticsRefresh: Date?
    @ObservationIgnored private var refreshedLocalModelUsageScopeKey: String?
    @ObservationIgnored private var lastLocalModelUsageRefresh: Date?
    @ObservationIgnored private var refreshedAPIReconciliationScopeKey: String?
    @ObservationIgnored private var lastAPIReconciliationRefresh: Date?

    /// Reloads usage controls, ledgers, reconciliation candidates and run
    /// statistics for the selected account; called from `AppModel.refresh`.
    func refresh(service: BridgeService, force forceUsageStatistics: Bool) throws {
        refreshUsageControlsIfNeeded(service: service)
        if app.settings.defaultProvider == .claude, let profileID = app.selectedProfileIDs[.claude] {
            do {
                budgetSnapshot = try service.budgetSnapshot(profileID: profileID)
            } catch UsageControlError.apiMonthlyLimitRequired {
                budgetSnapshot = nil
            }
            if let session = app.selectedSession,
               session.provider == .claude,
               (session.accountProfileID ?? AccountProfile.defaultID(for: .claude)) == profileID {
                apiCostSnapshot = try service.apiCostControlSnapshot(profileID: profileID, sessionID: session.id)
            } else {
                apiCostSnapshot = nil
            }
            try refreshAPIReconciliationCandidatesIfNeeded(
                service: service,
                profileID: profileID,
                force: forceUsageStatistics
            )
            if app.settings.usageMode == .api { evaluateAPIBudgetThresholds() }
        } else {
            budgetSnapshot = nil
            apiCostSnapshot = nil
            apiReconciliationCandidates = []
            apiReconciliationSessionID = nil
        }
        try refreshUsageStatisticsIfNeeded(service: service, force: forceUsageStatistics)
        try refreshLocalModelUsageStatisticsIfNeeded(service: service, force: forceUsageStatistics)
    }

    private var localUsageProfileID: UUID? {
        if let discussion = app.chats.selectedDiscussion, discussion.provider == .local {
            return discussion.accountProfileID
        }
        if let session = app.selectedSession, session.provider == .local {
            return session.accountProfileID ?? AccountProfile.defaultID(for: .local)
        }
        if app.chats.newDiscussionProvider == .local, let newDiscussionProfileID = app.chats.newDiscussionProfileID {
            return newDiscussionProfileID
        }
        return app.selectedProfileIDs[.local]
    }

    private func refreshUsageControlsIfNeeded(service: BridgeService) {
        let provider = app.settings.defaultProvider
        guard let profileID = app.selectedProfileIDs[provider] else { return }
        let key = "\(provider.rawValue):\(profileID.uuidString.lowercased())"
        guard loadedUsageControlsScopeKey != key else { return }
        do {
            usageControls = try service.usageControlSettings(provider: provider, profileID: profileID)
            apiMonthlyLimitInput = usageControls.apiMonthlyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            apiDailyLimitInput = usageControls.apiDailyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            apiSessionLimitInput = usageControls.apiSessionLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            usageAlerts = []
            usageControlStatus = ""
            loadedUsageControlsScopeKey = key
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    func refreshUsageStatisticsIfNeeded(service: BridgeService, force: Bool) throws {
        let provider = app.settings.defaultProvider
        guard let profileID = app.selectedProfileIDs[provider] else { return }
        let scopeKey = "\(provider.rawValue):\(profileID.uuidString.lowercased()):\(app.selectedSessionID?.uuidString ?? "none")"
        let now = Date()
        if !force, refreshedUsageStatisticsScopeKey == scopeKey,
           let lastUsageStatisticsRefresh,
           now.timeIntervalSince(lastUsageStatisticsRefresh) < 30 {
            return
        }
        let snapshot = try service.usageStatistics(
            provider: provider,
            profileID: profileID,
            selectedSessionID: app.selectedSessionID,
            now: now
        )
        usageStatistics = snapshot
        refreshedUsageStatisticsScopeKey = scopeKey
        lastUsageStatisticsRefresh = now
        if provider != .local { evaluateSubscriptionThresholds(snapshot: snapshot) }
    }

    func refreshLocalModelUsageStatisticsIfNeeded(service: BridgeService, force: Bool) throws {
        guard let profileID = localUsageProfileID else {
            localModelUsageStatistics = nil
            return
        }
        let currentLocalRunID: UUID?
        if let discussion = app.chats.selectedDiscussion, discussion.provider == .local,
           discussion.accountProfileID == profileID {
            currentLocalRunID = discussion.id
        } else if let session = app.selectedSession, session.provider == .local,
                  (session.accountProfileID ?? AccountProfile.defaultID(for: .local)) == profileID {
            currentLocalRunID = session.id
        } else {
            currentLocalRunID = nil
        }
        let scopeKey = "local:\(profileID.uuidString.lowercased()):\(currentLocalRunID?.uuidString.lowercased() ?? "none")"
        let now = Date()
        if !force, refreshedLocalModelUsageScopeKey == scopeKey,
           let lastLocalModelUsageRefresh,
           now.timeIntervalSince(lastLocalModelUsageRefresh) < 30 {
            return
        }
        localModelUsageStatistics = try service.usageStatistics(
            provider: .local,
            profileID: profileID,
            selectedSessionID: currentLocalRunID,
            now: now
        )
        refreshedLocalModelUsageScopeKey = scopeKey
        lastLocalModelUsageRefresh = now
    }

    private func refreshAPIReconciliationCandidatesIfNeeded(
        service: BridgeService,
        profileID: UUID,
        force: Bool
    ) throws {
        let scopeKey = profileID.uuidString.lowercased()
        if refreshedAPIReconciliationScopeKey != scopeKey {
            apiReconciliationSessionID = nil
            apiReconciliationActualUSD = ""
            apiReconciliationConfirmed = false
            apiReconciliationStatus = ""
            refreshedAPIReconciliationScopeKey = scopeKey
            lastAPIReconciliationRefresh = nil
        }
        let now = Date()
        if !force, let lastAPIReconciliationRefresh,
           now.timeIntervalSince(lastAPIReconciliationRefresh) < 30 {
            return
        }
        apiReconciliationCandidates = try service.unresolvedAPICalls(profileID: profileID)
        if !apiReconciliationCandidates.contains(where: { $0.session.id == apiReconciliationSessionID }) {
            apiReconciliationSessionID = apiReconciliationCandidates.first?.session.id
        }
        lastAPIReconciliationRefresh = now
    }

    func updateUsageControls(_ update: (inout UsageControlSettings) -> Void) {
        update(&usageControls)
    }

    func saveUsageControlSettings() {
        guard let service = app.service, let profile = app.selectedAccountProfile else {
            usageControlStatus = "The currently selected account settings could not be found."
            return
        }
        var updated = usageControls
        if profile.provider == .claude, profile.id != AccountProfile.defaultID(for: .claude) {
            let rawLimit = apiMonthlyLimitInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawLimit.isEmpty {
                updated.apiMonthlyLimitUSD = nil
            } else if let limit = Double(rawLimit), limit.isFinite {
                updated.apiMonthlyLimitUSD = limit
            } else {
                usageControlStatus = "Enter a valid Claude API monthly limit."
                return
            }
        }
        var dailyLimit: Double?
        var sessionLimit: Double?
        guard parseOptionalDollarLimit(apiDailyLimitInput, into: &dailyLimit),
              parseOptionalDollarLimit(apiSessionLimitInput, into: &sessionLimit) else {
            usageControlStatus = "Daily and session API USD limits must be positive numbers, or left empty for no limit."
            return
        }
        updated.apiDailyLimitUSD = dailyLimit
        updated.apiSessionLimitUSD = sessionLimit
        if profile.provider != .claude { updated.apiMonthlyLimitUSD = nil }
        do {
            try service.saveUsageControlSettings(updated, provider: profile.provider, profileID: profile.id)
            usageControls = updated
            apiMonthlyLimitInput = updated.apiMonthlyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            apiDailyLimitInput = updated.apiDailyLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            apiSessionLimitInput = updated.apiSessionLimitUSD.map { String(format: "%.2f", $0) } ?? ""
            usageControlStatus = "Local usage controls were saved."
            app.refresh(forceUsageStatistics: true)
        } catch {
            usageControlStatus = error.localizedDescription
        }
    }

    var selectedAPIReconciliationCandidate: APIReconciliationCandidate? {
        apiReconciliationCandidates.first(where: { $0.session.id == apiReconciliationSessionID })
    }

    /// Fills the amount with the selected call's full reservation, a
    /// conservative settlement for when the bill is not yet available.
    func useReservedAmountForSelectedAPICost() {
        guard let candidate = selectedAPIReconciliationCandidate else {
            apiReconciliationStatus = "Select an unsettled API session for this Claude account."
            return
        }
        apiReconciliationActualUSD = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), candidate.reservedUSD)
        apiReconciliationStatus = ""
    }

    func reconcileSelectedAPICost() {
        guard let service = app.service, let profile = app.selectedAccountProfile,
              profile.provider == .claude,
              let candidate = selectedAPIReconciliationCandidate else {
            apiReconciliationStatus = "Select an unsettled API session for this Claude account."
            return
        }
        let rawAmount = apiReconciliationActualUSD.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let actualUSD = Double(rawAmount), actualUSD.isFinite, actualUSD >= 0 else {
            apiReconciliationStatus = "Enter a valid actual USD amount from the provider bill."
            return
        }
        guard apiReconciliationConfirmed else {
            apiReconciliationStatus = "Confirm that the amount has been checked against the provider bill before settling."
            return
        }
        do {
            try service.reconcileAPIUsageFromProviderBill(
                profileID: profile.id,
                sessionID: candidate.session.id,
                actualUSD: actualUSD,
                explicitlyConfirmed: true
            )
            apiReconciliationStatus = Self.reconciliationSettledMessage
            apiReconciliationActualUSD = ""
            apiReconciliationConfirmed = false
            lastAPIReconciliationRefresh = nil
            app.refresh(forceUsageStatistics: true)
        } catch {
            apiReconciliationStatus = error.localizedDescription
            lastAPIReconciliationRefresh = nil
            app.refresh(forceUsageStatistics: true)
        }
    }

    private func parseOptionalDollarLimit(_ rawValue: String, into output: inout Double?) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            output = nil
            return true
        }
        guard let number = Double(value), number.isFinite else { return false }
        output = number
        return true
    }

    func setMacOSUsageNotificationsEnabled(_ enabled: Bool) {
        guard let service = app.service, let profile = app.selectedAccountProfile else { return }
        if !enabled {
            var updated = usageControls
            updated.macOSNotificationsEnabled = false
            persistUsageControls(updated, service: service, profile: profile)
            return
        }
        let requestedSettings = usageControls
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var updated = self.app.selectedAccountProfile?.id == profile.id ? self.usageControls : requestedSettings
                updated.macOSNotificationsEnabled = granted
                self.persistUsageControls(updated, service: service, profile: profile)
                if let error {
                    self.usageControlStatus = "Could not enable macOS notifications: \(error.localizedDescription)"
                } else if !granted {
                    self.usageControlStatus = "macOS notification permission was not granted. Alerts will still appear in the app."
                }
            }
        }
    }

    private func evaluateSubscriptionThresholds(snapshot: UsageStatisticsSnapshot) {
        let profileKey = "\(snapshot.provider.rawValue):\(snapshot.accountProfileID.uuidString.lowercased())"
        evaluateThreshold(
            title: "Local Runs in the Last 5 Hours",
            used: snapshot.subscriptionFiveHourRuns,
            limit: usageControls.subscriptionFiveHourRunLimit,
            key: "\(profileKey):subscription-5h:\(usageAlertPeriodID(duration: 5 * 60 * 60, at: snapshot.generatedAt))"
        )
        evaluateThreshold(
            title: "Local Runs in the Last 24 Hours",
            used: snapshot.subscriptionDailyRuns,
            limit: usageControls.subscriptionDailyRunLimit,
            key: "\(profileKey):subscription-24h:\(usageAlertPeriodID(duration: 24 * 60 * 60, at: snapshot.generatedAt))"
        )
        evaluateThreshold(
            title: "Local Runs in the Last 7 Days",
            used: snapshot.subscriptionSevenDayRuns,
            limit: usageControls.subscriptionWeeklyRunLimit,
            key: "\(profileKey):subscription-7d:\(usageAlertPeriodID(duration: 7 * 24 * 60 * 60, at: snapshot.generatedAt))"
        )
        evaluateThreshold(
            title: "Local Runs in the Current Session",
            used: snapshot.subscriptionSessionRuns,
            limit: usageControls.subscriptionSessionRunLimit,
            key: "\(profileKey):subscription-session:\(app.selectedSessionID?.uuidString ?? "none")"
        )
    }

    private func usageAlertPeriodID(duration: TimeInterval, at date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / duration))
    }

    private func evaluateAPIBudgetThresholds() {
        guard let budgetSnapshot else { return }
        let consumed = budgetSnapshot.usedUSD + budgetSnapshot.reservedUSD
        let ratio = consumed / budgetSnapshot.monthlyLimitUSD
        let profileID = app.selectedProfileIDs[.claude] ?? AccountProfile.defaultID(for: .claude)
        for threshold in [50, 75, 90, 100] {
            let key = "api:\(profileID.uuidString.lowercased()):\(budgetSnapshot.month):\(threshold)"
            if ratio >= Double(threshold) / 100 {
                recordUsageAlert(
                    key: key,
                    message: String(format: "Claude API local monthly budget reached %d%% (used and reserved total US$%.2f / US$%.2f).", threshold, consumed, budgetSnapshot.monthlyLimitUSD)
                )
            }
        }
        if let activity = usageStatistics {
            evaluateThreshold(
                title: "Claude API Runs in the Last 24 Hours",
                used: activity.apiDailyRuns,
                limit: usageControls.apiDailyRunLimit,
                key: "api-count-24h:\(profileID.uuidString.lowercased()):\(ISO8601DateFormatter().string(from: Date()).prefix(10))"
            )
            evaluateThreshold(
                title: "Claude API Runs in the Current Session",
                used: activity.apiSessionRuns,
                limit: usageControls.apiSessionRunLimit,
                key: "api-count-session:\(profileID.uuidString.lowercased()):\(app.selectedSessionID?.uuidString ?? "none")"
            )
        }
        if let costs = apiCostSnapshot {
            let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
            evaluateDollarThreshold(
                title: "Claude API UTC Daily USD Limit",
                used: costs.dailyUsedUSD + costs.dailyReservedUSD,
                limit: usageControls.apiDailyLimitUSD,
                key: "api-usd-day:\(profileID.uuidString.lowercased()):\(day)"
            )
            evaluateDollarThreshold(
                title: "Claude API Session USD Limit",
                used: costs.sessionUsedUSD + costs.sessionReservedUSD,
                limit: usageControls.apiSessionLimitUSD,
                key: "api-usd-session:\(profileID.uuidString.lowercased()):\(app.selectedSessionID?.uuidString ?? "none")"
            )
        }
    }

    private func evaluateThreshold(title: String, used: Int, limit: Int?, key: String) {
        guard let limit, limit > 0 else { return }
        for threshold in [50, 75, 90, 100] {
            let alertKey = "\(key):\(threshold)"
            if Double(used) / Double(limit) >= Double(threshold) / 100 {
                recordUsageAlert(key: alertKey, message: "\(title)reached the local limit of \(threshold)% (\(used)/\(limit)).")
            }
        }
    }

    private func evaluateDollarThreshold(title: String, used: Double, limit: Double?, key: String) {
        guard let limit, limit > 0 else { return }
        for threshold in [50, 75, 90, 100] {
            let alertKey = "\(key):\(threshold)"
            if used / limit >= Double(threshold) / 100 {
                recordUsageAlert(
                    key: alertKey,
                    message: String(format: "%@reached the local limit of %d%% (US$%.2f / US$%.2f).", title, threshold, used, limit)
                )
            }
        }
    }

    private func recordUsageAlert(key: String, message: String) {
        if !usageAlerts.contains(message) {
            usageAlerts.insert(message, at: 0)
            usageAlerts = Array(usageAlerts.prefix(5))
        }
        guard usageControls.notifiedThresholds[key] == nil else { return }
        var updated = usageControls
        updated.notifiedThresholds[key] = Date()
        guard let service = app.service, let profile = app.selectedAccountProfile else { return }
        persistUsageControls(updated, service: service, profile: profile, updateStatus: false)
        guard usageControls.macOSNotificationsEnabled else { return }
        let notificationTitle = app.localized("AgentBridge Usage Alert")
        let notificationBody = app.localized(message)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = notificationTitle
            content.body = notificationBody
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    private func persistUsageControls(
        _ updated: UsageControlSettings,
        service: BridgeService,
        profile: AccountProfile,
        updateStatus: Bool = true
    ) {
        var updated = updated
        if updated.notifiedThresholds.count > 48 {
            let retainedKeys = updated.notifiedThresholds.sorted { $0.value > $1.value }.prefix(48).map(\.key)
            updated.notifiedThresholds = updated.notifiedThresholds.filter { retainedKeys.contains($0.key) }
        }
        do {
            try service.saveUsageControlSettings(updated, provider: profile.provider, profileID: profile.id)
            if app.selectedProfileIDs[profile.provider] == profile.id, app.settings.defaultProvider == profile.provider {
                usageControls = updated
            }
            if updateStatus {
                usageControlStatus = updated.macOSNotificationsEnabled
                    ? "macOS threshold notifications are enabled. Alerts will also remain in the app."
                    : "macOS notifications are disabled. Threshold alerts will still remain in the app."
            }
        } catch {
            if updateStatus { usageControlStatus = error.localizedDescription }
        }
    }

    @ObservationIgnored private weak var owner: AppModel?

    private var app: AppModel {
        guard let owner else { preconditionFailure("UsageModel outlived its AppModel.") }
        return owner
    }

    /// Connects the usage model to the model that owns it; called once from `AppModel.init`.
    func attach(to app: AppModel) {
        owner = app
    }
}
