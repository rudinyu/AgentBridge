import AppKit
import Combine
import Darwin
import AgentBridgeCore
import Charts
import SwiftUI
import UserNotifications

@main
struct AgentBridgeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 980, minHeight: 700)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: AppLanguage.preferenceKey) }
    }
    @Published var settings = BridgeSettings()
    @Published var sessions: [SessionRecord] = []
    @Published var events: [AuditEvent] = []
    @Published var selectedSessionID: UUID?
    @Published var repositoryPath = ""
    @Published var codexPath = ""
    @Published var claudePath = ""
    @Published var prompt = ""
    @Published var status = "就緒。"
    @Published var errorMessage: String?
    @Published var outputText = ""
    @Published var isRunning = false
    @Published var interactiveMode = false
    @Published var apiBudget = ""
    @Published var apiKey = ""
    @Published var confirmAPIRun = false
    @Published var budgetSnapshot: BudgetSnapshot?
    @Published var apiCostSnapshot: APICostControlSnapshot?
    @Published var usageStatistics: UsageStatisticsSnapshot?
    @Published var providerUsageReport: ProviderUsageReport?
    @Published var usageControls = UsageControlSettings()
    @Published var apiMonthlyLimitInput = ""
    @Published var apiDailyLimitInput = ""
    @Published var apiSessionLimitInput = ""
    @Published var usageControlStatus = ""
    @Published var usageAlerts: [String] = []
    @Published var apiReconciliationCandidates: [APIReconciliationCandidate] = []
    @Published var apiReconciliationSessionID: UUID?
    @Published var apiReconciliationActualUSD = ""
    @Published var apiReconciliationConfirmed = false
    @Published var apiReconciliationStatus = ""
    @Published var authStatus: [UUID: AuthAssessment] = [:]
    @Published var accountProfiles: [AgentProvider: [AccountProfile]] = [:]
    @Published var selectedProfileIDs: [AgentProvider: UUID] = [:]
    @Published var newProfileName = ""
    @Published var newProfileAllowsSharedMemory = true
    @Published var memorySnapshot: SharedMemorySnapshot?
    @Published var memoryNotes = ""
    @Published var confirmClearMemory = false
    @Published var terminalLaunch: TerminalLaunchSpec?
    @Published var terminalTitle = ""
    @Published var terminalRunning = false
    @Published var terminalIsProfileLogin = false
    @Published var terminalIsUsageTUI = false
    @Published var terminalNeedsManualStop = false
    @Published var usageCommandRequest = 0
    @Published var closeTerminalAfterCancellation = false
    @Published var isSwitchingTarget = false

    private var service: BridgeService?
    private var store: AuditStore?
    private var cancellation: CancellationFlag?
    private var activeRunSessionID: UUID?
    private var activeTerminalProfileID: UUID?
    private var activeTerminalSessionID: UUID?
    private var activeUsageProvider: AgentProvider?
    private var loadedUsageControlsScopeKey: String?
    private var refreshedUsageStatisticsScopeKey: String?
    private var lastUsageStatisticsRefresh: Date?
    private var refreshedAPIReconciliationScopeKey: String?
    private var lastAPIReconciliationRefresh: Date?

    var terminalSessionIDForView: UUID? { activeTerminalSessionID }

    func localized(_ source: String) -> String {
        AppLocalization.display(source, language: appLanguage)
    }

    var canSendUsageCommand: Bool {
        terminalIsUsageTUI
            && terminalRunning
            && settings.usageMode == .subscription
            && activeTerminalProfileID == selectedProfileIDs[settings.defaultProvider]
    }

    init() {
        appLanguage = AppLanguage.saved
        do {
            let root = try RuntimePaths.applicationSupportRoot()
            let store = try AuditStore(rootURL: root)
            let service = try BridgeService(store: store)
            self.store = store
            self.service = service
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var selectedSession: SessionRecord? {
        sessions.first(where: { $0.id == selectedSessionID })
    }

    var isClaudeAPIRunContext: Bool {
        settings.defaultProvider == .claude && settings.usageMode == .api && selectedSession?.provider == .claude
    }

    var selectedAccountProfile: AccountProfile? {
        guard let id = selectedProfileIDs[settings.defaultProvider] else { return nil }
        return accountProfiles[settings.defaultProvider]?.first(where: { $0.id == id })
    }

    var selectedSessionProfileName: String {
        guard let session = selectedSession else { return "" }
        return profileName(for: session)
    }

    var selectedSessionAuthentication: AuthAssessment? {
        guard let session = selectedSession else { return nil }
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        return authStatus[profileID]
    }

    var selectedProfileAuthentication: AuthAssessment? {
        guard let profile = selectedAccountProfile else { return nil }
        return authStatus[profile.id]
    }

    func profileName(for session: SessionRecord) -> String {
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        return accountProfiles[session.provider]?.first(where: { $0.id == profileID })?.name ?? localized("目前本機登入")
    }

    func refresh(forceUsageStatistics: Bool = false) {
        guard let service else { return }
        do {
            var loadedSettings = try service.settings()
            if loadedSettings.defaultProvider == .codex, loadedSettings.usageMode == .api {
                loadedSettings.usageMode = .subscription
                try service.saveSettings(loadedSettings)
                status = "Codex 使用官方 CLI 訂閱登入；已修正舊的不相容設定。"
                clearAPIAuthorization()
            }
            settings = loadedSettings
            codexPath = settings.codexBinaryPath ?? ""
            claudePath = settings.claudeBinaryPath ?? ""
            for provider in AgentProvider.allCases {
                accountProfiles[provider] = try service.accountProfiles(provider: provider)
                selectedProfileIDs[provider] = try service.selectedAccountProfile(provider: provider).id
            }
            sessions = try service.sessions()
            if selectedSessionID == nil, let first = sessions.first {
                selectedSessionID = first.id
                refreshSelectedEvents()
            } else if selectedSessionID != nil {
                refreshSelectedEvents()
            }
            refreshUsageControlsIfNeeded(service: service)
            if settings.defaultProvider == .claude, let profileID = selectedProfileIDs[.claude] {
                do {
                    budgetSnapshot = try service.budgetSnapshot(profileID: profileID)
                } catch UsageControlError.apiMonthlyLimitRequired {
                    budgetSnapshot = nil
                }
                if let session = selectedSession,
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
                if settings.usageMode == .api { evaluateAPIBudgetThresholds() }
            } else {
                budgetSnapshot = nil
                apiCostSnapshot = nil
                apiReconciliationCandidates = []
                apiReconciliationSessionID = nil
            }
            try refreshUsageStatisticsIfNeeded(service: service, force: forceUsageStatistics)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshUsageControlsIfNeeded(service: BridgeService) {
        let provider = settings.defaultProvider
        guard let profileID = selectedProfileIDs[provider] else { return }
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
            errorMessage = error.localizedDescription
        }
    }

    private func refreshUsageStatisticsIfNeeded(service: BridgeService, force: Bool) throws {
        let provider = settings.defaultProvider
        guard let profileID = selectedProfileIDs[provider] else { return }
        let scopeKey = "\(provider.rawValue):\(profileID.uuidString.lowercased()):\(selectedSessionID?.uuidString ?? "none")"
        let now = Date()
        if !force, refreshedUsageStatisticsScopeKey == scopeKey,
           let lastUsageStatisticsRefresh,
           now.timeIntervalSince(lastUsageStatisticsRefresh) < 30 {
            return
        }
        let snapshot = try service.usageStatistics(
            provider: provider,
            profileID: profileID,
            selectedSessionID: selectedSessionID,
            now: now
        )
        usageStatistics = snapshot
        refreshedUsageStatisticsScopeKey = scopeKey
        lastUsageStatisticsRefresh = now
        evaluateSubscriptionThresholds(snapshot: snapshot)
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

    func refreshSelectedEvents() {
        guard let service, let selectedSessionID else {
            events = []
            memorySnapshot = nil
            memoryNotes = ""
            return
        }
        do {
            events = try service.events(sessionID: selectedSessionID)
            outputText = events.last(where: { $0.kind == "run.output" })?.message ?? ""
            let snapshot = try service.sharedMemory(sessionID: selectedSessionID)
            if memorySnapshot?.scope.key != snapshot.scope.key { memoryNotes = snapshot.notes }
            memorySnapshot = snapshot
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectedSessionDidChange() {
        clearAPIAuthorization()
        refreshSelectedEvents()
        if let service {
            do {
                try refreshUsageStatisticsIfNeeded(service: service, force: true)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectDefaultProvider(_ provider: AgentProvider) {
        guard settings.defaultProvider != provider else { return }
        guard let service else { return }
        let previous = settings
        settings.defaultProvider = provider
        if provider == .codex, settings.usageMode == .api {
            settings.usageMode = .subscription
        }
        if provider == .codex { interactiveMode = false }
        clearAPIAuthorization()
        do {
            updateBinaryPathsInSettings()
            try service.saveSettings(settings)
            providerUsageReport = nil
            status = provider == .codex && previous.usageMode == .api
                ? "已切換至 Codex，並儲存為官方 CLI 訂閱登入模式。"
                : "新工作階段預設助理已儲存。"
            loadedUsageControlsScopeKey = nil
            refresh(forceUsageStatistics: true)
            if let anchor = selectedSession { selectOrCreateSession(for: provider, anchoredTo: anchor) }
        } catch {
            settings = previous
            errorMessage = error.localizedDescription
        }
    }

    func selectUsageMode(_ usageMode: UsageMode) {
        guard settings.defaultProvider == .claude,
              settings.usageMode != usageMode,
              let service else { return }
        let previous = settings
        settings.usageMode = usageMode
        if usageMode == .api { interactiveMode = false }
        clearAPIAuthorization()
        do {
            updateBinaryPathsInSettings()
            try service.saveSettings(settings)
            if usageMode == .api { providerUsageReport = nil }
            status = "Claude 使用模式已儲存。"
            refresh(forceUsageStatistics: true)
            if let anchor = selectedSession { selectOrCreateSession(for: .claude, anchoredTo: anchor) }
        } catch {
            settings = previous
            errorMessage = error.localizedDescription
        }
    }

    private func updateBinaryPathsInSettings() {
        settings.codexBinaryPath = codexPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : codexPath
        settings.claudeBinaryPath = claudePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : claudePath
    }

    func updateUsageControls(_ update: (inout UsageControlSettings) -> Void) {
        update(&usageControls)
    }

    func saveUsageControlSettings() {
        guard let service, let profile = selectedAccountProfile else {
            usageControlStatus = "找不到目前選取的帳戶設定。"
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
                usageControlStatus = "請輸入有效的 Claude API 月上限金額。"
                return
            }
        }
        var dailyLimit: Double?
        var sessionLimit: Double?
        guard parseOptionalDollarLimit(apiDailyLimitInput, into: &dailyLimit),
              parseOptionalDollarLimit(apiSessionLimitInput, into: &sessionLimit) else {
            usageControlStatus = "API 每日與工作階段 USD 上限必須是有效的正數，或留空代表不限。"
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
            usageControlStatus = "本機用量控制已儲存。"
            refresh(forceUsageStatistics: true)
        } catch {
            usageControlStatus = error.localizedDescription
        }
    }

    var selectedAPIReconciliationCandidate: APIReconciliationCandidate? {
        apiReconciliationCandidates.first(where: { $0.session.id == apiReconciliationSessionID })
    }

    func reconcileSelectedAPICost() {
        guard let service, let profile = selectedAccountProfile,
              profile.provider == .claude,
              let candidate = selectedAPIReconciliationCandidate else {
            apiReconciliationStatus = "請選擇此 Claude 帳戶中尚未結算的 API 工作階段。"
            return
        }
        let rawAmount = apiReconciliationActualUSD.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let actualUSD = Double(rawAmount), actualUSD.isFinite, actualUSD >= 0 else {
            apiReconciliationStatus = "請輸入 provider 帳單所列的有效實際 USD 金額。"
            return
        }
        guard apiReconciliationConfirmed else {
            apiReconciliationStatus = "結算前請確認金額已對照 provider 帳單。"
            return
        }
        do {
            let result = try service.reconcileAPIUsageFromProviderBill(
                profileID: profile.id,
                sessionID: candidate.session.id,
                actualUSD: actualUSD,
                explicitlyConfirmed: true
            )
            apiReconciliationStatus = String(format: "費用已手動結算：月度帳本 %@；每日/工作階段帳本 %@。", result.monthlyLedgerSettled ? "已更新" : "沒有對應預留", result.dailySessionLedgerSettled ? "已更新" : "沒有對應預留")
            apiReconciliationActualUSD = ""
            apiReconciliationConfirmed = false
            lastAPIReconciliationRefresh = nil
            refresh(forceUsageStatistics: true)
        } catch {
            apiReconciliationStatus = error.localizedDescription
            lastAPIReconciliationRefresh = nil
            refresh(forceUsageStatistics: true)
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
        guard let service, let profile = selectedAccountProfile else { return }
        if !enabled {
            var updated = usageControls
            updated.macOSNotificationsEnabled = false
            persistUsageControls(updated, service: service, profile: profile)
            return
        }
        let requestedSettings = usageControls
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                var updated = self.selectedAccountProfile?.id == profile.id ? self.usageControls : requestedSettings
                updated.macOSNotificationsEnabled = granted
                self.persistUsageControls(updated, service: service, profile: profile)
                if let error {
                    self.usageControlStatus = "無法啟用 macOS 通知：\(error.localizedDescription)"
                } else if !granted {
                    self.usageControlStatus = "未取得 macOS 通知權限；提醒仍會顯示在 App 內。"
                }
            }
        }
    }

    private func evaluateSubscriptionThresholds(snapshot: UsageStatisticsSnapshot) {
        let profileKey = "\(snapshot.provider.rawValue):\(snapshot.accountProfileID.uuidString.lowercased())"
        evaluateThreshold(
            title: "近 5 小時本機執行",
            used: snapshot.subscriptionFiveHourRuns,
            limit: usageControls.subscriptionFiveHourRunLimit,
            key: "\(profileKey):subscription-5h:\(usageAlertPeriodID(duration: 5 * 60 * 60, at: snapshot.generatedAt))"
        )
        evaluateThreshold(
            title: "近 24 小時本機執行",
            used: snapshot.subscriptionDailyRuns,
            limit: usageControls.subscriptionDailyRunLimit,
            key: "\(profileKey):subscription-24h:\(usageAlertPeriodID(duration: 24 * 60 * 60, at: snapshot.generatedAt))"
        )
        evaluateThreshold(
            title: "近 7 天本機執行",
            used: snapshot.subscriptionSevenDayRuns,
            limit: usageControls.subscriptionWeeklyRunLimit,
            key: "\(profileKey):subscription-7d:\(usageAlertPeriodID(duration: 7 * 24 * 60 * 60, at: snapshot.generatedAt))"
        )
        evaluateThreshold(
            title: "目前工作階段本機執行",
            used: snapshot.subscriptionSessionRuns,
            limit: usageControls.subscriptionSessionRunLimit,
            key: "\(profileKey):subscription-session:\(selectedSessionID?.uuidString ?? "none")"
        )
    }

    private func usageAlertPeriodID(duration: TimeInterval, at date: Date) -> Int64 {
        Int64(floor(date.timeIntervalSince1970 / duration))
    }

    private func evaluateAPIBudgetThresholds() {
        guard let budgetSnapshot else { return }
        let consumed = budgetSnapshot.usedUSD + budgetSnapshot.reservedUSD
        let ratio = consumed / budgetSnapshot.monthlyLimitUSD
        let profileID = selectedProfileIDs[.claude] ?? AccountProfile.defaultID(for: .claude)
        for threshold in [50, 75, 90, 100] {
            let key = "api:\(profileID.uuidString.lowercased()):\(budgetSnapshot.month):\(threshold)"
            if ratio >= Double(threshold) / 100 {
                recordUsageAlert(
                    key: key,
                    message: String(format: "Claude API 本機月預算已達 %d%%（已用與保留合計 US$%.2f / US$%.2f）。", threshold, consumed, budgetSnapshot.monthlyLimitUSD)
                )
            }
        }
        if let activity = usageStatistics {
            evaluateThreshold(
                title: "近 24 小時 Claude API 執行次數",
                used: activity.apiDailyRuns,
                limit: usageControls.apiDailyRunLimit,
                key: "api-count-24h:\(profileID.uuidString.lowercased()):\(ISO8601DateFormatter().string(from: Date()).prefix(10))"
            )
            evaluateThreshold(
                title: "目前工作階段 Claude API 執行次數",
                used: activity.apiSessionRuns,
                limit: usageControls.apiSessionRunLimit,
                key: "api-count-session:\(profileID.uuidString.lowercased()):\(selectedSessionID?.uuidString ?? "none")"
            )
        }
        if let costs = apiCostSnapshot {
            let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
            evaluateDollarThreshold(
                title: "Claude API UTC 每日 USD 上限",
                used: costs.dailyUsedUSD + costs.dailyReservedUSD,
                limit: usageControls.apiDailyLimitUSD,
                key: "api-usd-day:\(profileID.uuidString.lowercased()):\(day)"
            )
            evaluateDollarThreshold(
                title: "Claude API 工作階段 USD 上限",
                used: costs.sessionUsedUSD + costs.sessionReservedUSD,
                limit: usageControls.apiSessionLimitUSD,
                key: "api-usd-session:\(profileID.uuidString.lowercased()):\(selectedSessionID?.uuidString ?? "none")"
            )
        }
    }

    private func evaluateThreshold(title: String, used: Int, limit: Int?, key: String) {
        guard let limit, limit > 0 else { return }
        for threshold in [50, 75, 90, 100] {
            let alertKey = "\(key):\(threshold)"
            if Double(used) / Double(limit) >= Double(threshold) / 100 {
                recordUsageAlert(key: alertKey, message: "\(title)達到本機上限的 \(threshold)%（\(used)/\(limit)）。")
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
                    message: String(format: "%@達到本機上限的 %d%%（US$%.2f / US$%.2f）。", title, threshold, used, limit)
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
        guard let service, let profile = selectedAccountProfile else { return }
        persistUsageControls(updated, service: service, profile: profile, updateStatus: false)
        guard usageControls.macOSNotificationsEnabled else { return }
        let notificationTitle = localized("AgentBridge 用量提醒")
        let notificationBody = localized(message)
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
            if selectedProfileIDs[profile.provider] == profile.id, settings.defaultProvider == profile.provider {
                usageControls = updated
            }
            if updateStatus {
                usageControlStatus = updated.macOSNotificationsEnabled
                    ? "已啟用 macOS 門檻通知；提醒也會保留在 App 內。"
                    : "已關閉 macOS 通知；門檻提醒仍會保留在 App 內。"
            }
        } catch {
            if updateStatus { usageControlStatus = error.localizedDescription }
        }
    }

    private func clearAPIAuthorization() {
        apiBudget = ""
        apiKey = ""
        confirmAPIRun = false
    }

    func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = localized("選擇 Git 儲存庫根目錄")
        panel.message = localized("AgentBridge 會複製目前提交版本到私有隔離工作區。來源的未提交變更不會複製。")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { repositoryPath = url.path }
    }

    func saveSettings() {
        guard let service else { return }
        do {
            updateBinaryPathsInSettings()
            try service.saveSettings(settings)
            status = "設定已儲存。"
            refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func checkAuthentication() {
        guard let profile = selectedAccountProfile else { errorMessage = "找不到所選帳戶設定。"; return }
        checkAuthentication(for: profile)
    }

    private func checkAuthentication(for profile: AccountProfile) {
        guard let service else { return }
        status = "正在檢查官方 CLI 登入狀態…"
        Task {
            do {
                let assessment = try await service.checkAuthentication(provider: profile.provider, profileID: profile.id)
                authStatus[profile.id] = assessment
                status = assessment.message
            } catch {
                errorMessage = error.localizedDescription
                status = "登入檢查失敗。"
            }
        }
    }

    func createSession() {
        guard let service else { return }
        let provider = settings.defaultProvider
        guard !repositoryPath.isEmpty else { errorMessage = "請先選擇 Git 儲存庫。"; return }
        guard !interactiveMode || settings.usageMode == .subscription else { errorMessage = "互動模式目前只支援訂閱登入。"; return }
        do {
            try service.saveSettings(settings)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        status = "正在建立提交版本的隔離工作區…"
        let access: AccessMode = interactiveMode ? .interactiveManualApproval : .readOnly
        Task {
            do {
                let session = try await service.createSession(sourcePath: repositoryPath, provider: provider, accessMode: access)
                status = session.sourceWasDirty ? "工作階段已建立。來源未提交變更已排除。" : "工作階段已建立。"
                refresh()
                selectedSessionID = session.id
                refreshSelectedEvents()
            } catch {
                errorMessage = error.localizedDescription
                status = "無法建立工作階段。"
            }
        }
    }

    func runPrompt() {
        guard let service, let session = selectedSession else { errorMessage = "請選擇工作階段。"; return }
        var apiRequest: APIUsageRequest?
        if settings.usageMode == .api {
            guard isClaudeAPIRunContext else {
                errorMessage = "Claude API 只能用於 Claude 預設助理與 Claude 工作階段。"
                return
            }
            guard let budget = Double(apiBudget), budget.isFinite, budget > 0, !apiKey.isEmpty, confirmAPIRun else {
                errorMessage = "API 模式需要單次預算、API 金鑰，以及明確確認。"
                return
            }
            apiRequest = APIUsageRequest(requestedBudgetUSD: budget, explicitlyAuthorized: true, apiKey: apiKey)
        }
        let promptValue = prompt
        let cancellation = CancellationFlag()
        self.cancellation = cancellation
        activeRunSessionID = session.id
        isRunning = true
        errorMessage = nil
        outputText = ""
        status = settings.usageMode == .api ? "正在檢查並保留預算…" : "正在執行…"
        apiKey = ""
        confirmAPIRun = false
        Task { @MainActor [self] in
            defer {
                isRunning = false
                self.cancellation = nil
                activeRunSessionID = nil
                refresh(forceUsageStatistics: true)
                refreshSelectedEvents()
                apiKey = ""
            }
            do {
                let output = try await service.runReadOnly(sessionID: session.id, prompt: promptValue, apiRequest: apiRequest, cancellation: cancellation) { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.status = message
                        self?.refreshSelectedEvents()
                    }
                }
                outputText = output.text
                status = "回應完成。"
                prompt = ""
            } catch {
                errorMessage = error.localizedDescription
                status = "執行結束。"
            }
        }
    }

    func cancelRun() {
        if let activeRunSessionID { cancelSession(activeRunSessionID) }
    }

    func cancelSession(_ id: UUID) {
        if activeRunSessionID == id { cancellation?.cancel() }
        do {
            try service?.cancel(sessionID: id)
            status = "已送出取消請求…"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openEmbeddedInteractiveTerminal() {
        guard let session = selectedSession, session.policy.accessMode == .interactiveManualApproval else {
            errorMessage = "請先建立互動手動核准模式的工作階段。"
            return
        }
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        guard let spec = terminalLaunchSpec(
            title: "\(session.provider.rawValue.capitalized) · \(selectedSessionProfileName)",
            arguments: ["interactive", session.id.uuidString.lowercased(), "--profile", profileID.uuidString.lowercased()],
            workingDirectory: session.workspacePath
        ) else {
            errorMessage = "找不到 AgentBridge 命令列輔助程式。請先使用 scripts/package-app.sh 建立 .app。"
            return
        }
        terminalIsProfileLogin = false
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        terminalTitle = spec.title
        activeTerminalProfileID = profileID
        activeTerminalSessionID = session.id
        terminalNeedsManualStop = false
        closeTerminalAfterCancellation = false
        terminalLaunch = spec
        terminalRunning = true
        status = "已在 App 內啟動互動終端機。終端機文字不會自動加入共用記憶。"
    }

    func openSubscriptionUsageTUI() {
        guard settings.usageMode == .subscription else {
            errorMessage = "官方 usage TUI 只支援訂閱登入。"
            return
        }
        guard terminalLaunch == nil else {
            errorMessage = "請先關閉目前的 App 終端機。"
            return
        }
        let provider = settings.defaultProvider
        guard let profileID = selectedProfileIDs[provider],
              let profile = accountProfiles[provider]?.first(where: { $0.id == profileID }) else {
            errorMessage = "找不到目前選取的帳戶設定。"
            return
        }
        guard let spec = terminalLaunchSpec(
            title: "官方用量 · \(provider.rawValue.capitalized) · \(profile.name)",
            arguments: [
                "usage-tui",
                "--provider", provider.rawValue,
                "--profile", profile.id.uuidString.lowercased()
            ],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ) else {
            errorMessage = "找不到 AgentBridge 命令列輔助程式。請先使用 scripts/package-app.sh 建立 .app。"
            return
        }
        terminalIsProfileLogin = false
        terminalIsUsageTUI = true
        activeUsageProvider = provider
        providerUsageReport = nil
        terminalTitle = spec.title
        activeTerminalProfileID = profile.id
        activeTerminalSessionID = nil
        terminalNeedsManualStop = true
        closeTerminalAfterCancellation = false
        usageCommandRequest = 0
        terminalLaunch = spec
        terminalRunning = true
        status = "已啟動所選帳戶的官方 CLI 用量終端；請等待可輸入提示符並完成登入，再送出 /usage。"
    }

    func requestUsageCommand() {
        guard canSendUsageCommand else { return }
        usageCommandRequest &+= 1
        status = "已在目前官方 CLI 終端送出固定的 /usage 指令。"
    }

    func usageScreenDidUpdate(_ screenText: String, capturedAt: Date) -> Bool {
        guard terminalIsUsageTUI,
              let provider = activeUsageProvider,
              settings.defaultProvider == provider,
              settings.usageMode == .subscription,
              let profileID = activeTerminalProfileID,
              selectedProfileIDs[provider] == profileID,
              let profile = accountProfiles[provider]?.first(where: { $0.id == profileID }) else { return false }
        let report = ProviderUsageReportParser.parse(
            screenText: screenText,
            provider: provider,
            accountProfileID: profileID,
            accountName: profile.name,
            capturedAt: capturedAt
        )
        providerUsageReport = report
        return report.usageWindows.contains { $0.percentageUsed != nil || $0.resetText != nil }
    }

    func openProfileLoginTerminal() {
        guard let profile = selectedAccountProfile else { errorMessage = "找不到所選帳戶設定。"; return }
        guard !profile.usesExistingLogin else {
            errorMessage = "為避免登出或覆寫目前登入，請先新增獨立帳戶後再登入。"
            return
        }
        guard let spec = terminalLaunchSpec(
            title: "登入 · \(profile.provider.rawValue.capitalized) · \(profile.name)",
            arguments: ["profile-login", profile.id.uuidString.lowercased()],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        ) else {
            errorMessage = "找不到 AgentBridge 命令列輔助程式。請先使用 scripts/package-app.sh 建立 .app。"
            return
        }
        terminalIsProfileLogin = true
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        terminalTitle = spec.title
        activeTerminalProfileID = profile.id
        activeTerminalSessionID = nil
        terminalNeedsManualStop = true
        closeTerminalAfterCancellation = false
        terminalLaunch = spec
        terminalRunning = true
        status = "已在 App 內開啟官方 CLI 登入流程。登入由你在終端機完成。"
    }

    func openLocalShell() {
        guard let session = selectedSession else { errorMessage = "請先選擇工作階段。"; return }
        guard terminalLaunch == nil else { errorMessage = "請先關閉目前的 App 終端機。"; return }
        let spec = TerminalLaunchSpec(
            title: "本機終端 · \(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent)",
            executablePath: "/bin/sh",
            arguments: ["-f"],
            environment: sanitizedTerminalEnvironment(),
            workingDirectory: session.workspacePath
        )
        terminalIsProfileLogin = false
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        terminalNeedsManualStop = true
        activeTerminalProfileID = nil
        activeTerminalSessionID = nil
        closeTerminalAfterCancellation = false
        terminalTitle = spec.title
        terminalLaunch = spec
        terminalRunning = true
        status = "已在隔離工作區開啟本機 shell。Shell 命令仍以目前使用者權限執行。"
    }

    func closeEmbeddedTerminal() {
        if terminalRunning {
            if terminalNeedsManualStop {
                status = "請先在終端機按 Control-C 結束目前程序，再關閉終端面板。"
                return
            }
            guard let sessionID = activeTerminalSessionID else {
                status = "請先結束終端機中的工作，再關閉面板。"
                return
            }
            closeTerminalAfterCancellation = true
            cancelSession(sessionID)
            return
        }
        terminalLaunch = nil
        terminalRunning = false
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        activeTerminalProfileID = nil
        activeTerminalSessionID = nil
        terminalNeedsManualStop = false
        status = "已關閉 App 內終端機。"
    }

    func terminalDidTerminate(exitCode: Int32?) {
        terminalRunning = false
        terminalIsUsageTUI = false
        activeUsageProvider = nil
        if let exitCode, exitCode == 0 {
            status = "終端機工作已完成。"
        } else {
            status = "終端機工作已結束\(exitCode.map { "（代碼 \($0)）" } ?? "")。"
        }
        if terminalIsProfileLogin, let profileID = activeTerminalProfileID,
           let profile = accountProfiles.values.flatMap({ $0 }).first(where: { $0.id == profileID }) {
            checkAuthentication(for: profile)
        }
        refresh(forceUsageStatistics: true)
        if closeTerminalAfterCancellation {
            terminalLaunch = nil
            closeTerminalAfterCancellation = false
            activeTerminalProfileID = nil
            activeTerminalSessionID = nil
        }
    }

    private func terminalLaunchSpec(title: String, arguments: [String], workingDirectory: String) -> TerminalLaunchSpec? {
        guard let cli = interactiveCLIURL() else { return nil }
        return TerminalLaunchSpec(
            title: title,
            executablePath: cli.path,
            arguments: arguments,
            environment: sanitizedTerminalEnvironment(),
            workingDirectory: workingDirectory
        )
    }

    private func sanitizedTerminalEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        var safeEnvironment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "USER": NSUserName(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "xterm-256color"
        ]
        if let language = environment["LANG"], language.count <= 64 { safeEnvironment["LANG"] = language }
        if let temporaryDirectory = environment["TMPDIR"], temporaryDirectory.hasPrefix("/") { safeEnvironment["TMPDIR"] = temporaryDirectory }
        return safeEnvironment
    }

    private func interactiveCLIURL() -> URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/agentbridge")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        guard let argument = CommandLine.arguments.first else { return nil }
        let sibling = URL(fileURLWithPath: argument).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("agentbridge")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    private func selectOrCreateSession(for provider: AgentProvider, anchoredTo anchor: SessionRecord) {
        guard let profileID = selectedProfileIDs[provider], let service else { return }
        let access = anchor.policy.accessMode == .interactiveManualApproval && settings.usageMode == .subscription
            ? AccessMode.interactiveManualApproval
            : AccessMode.readOnly
        if let match = sessions.first(where: {
            $0.provider == provider
                && ($0.accountProfileID ?? AccountProfile.defaultID(for: provider)) == profileID
                && $0.sourceRepositoryPath == anchor.sourceRepositoryPath
                && $0.snapshotCommit == anchor.snapshotCommit
                && $0.policy.accessMode == access
        }) {
            selectedSessionID = match.id
            repositoryPath = match.sourceRepositoryPath
            status = "已切換至同一專案的 \(provider.rawValue.capitalized) 工作階段；共用記憶保持不變。"
            return
        }
        repositoryPath = anchor.sourceRepositoryPath
        interactiveMode = access == .interactiveManualApproval
        isSwitchingTarget = true
        status = "正在為所選助理與帳戶建立同一專案的隔離工作區…"
        Task {
            defer { isSwitchingTarget = false }
            do {
                let session = try await service.createSession(
                    sourcePath: anchor.sourceRepositoryPath,
                    provider: provider,
                    accessMode: access,
                    snapshotCommit: anchor.snapshotCommit
                )
                refresh()
                selectedSessionID = session.id
                refreshSelectedEvents()
                status = session.snapshotCommit == anchor.snapshotCommit
                    ? "已切換工作階段；同一提交版本的共用記憶可由已同意的帳戶載入。"
                    : "新工作階段已建立於目前提交版本；提交版本改變時會使用不同的共用記憶。"
            } catch {
                errorMessage = error.localizedDescription
                status = "無法切換工作階段。"
            }
        }
    }

    func selectAccountProfile(_ profileID: UUID) {
        guard let service else { return }
        let provider = settings.defaultProvider
        guard selectedProfileIDs[provider] != profileID else { return }
        let anchor = selectedSession
        clearAPIAuthorization()
        do {
            try service.selectAccountProfile(id: profileID, provider: provider)
            selectedProfileIDs[provider] = profileID
            providerUsageReport = nil
            accountProfiles[provider] = try service.accountProfiles(provider: provider)
            loadedUsageControlsScopeKey = nil
            refresh(forceUsageStatistics: true)
            if let anchor { selectOrCreateSession(for: provider, anchoredTo: anchor) }
            else { status = "已切換官方 CLI 帳戶。" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createAccountProfile() {
        guard let service else { return }
        let provider = settings.defaultProvider
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { errorMessage = "請為新帳戶輸入名稱。"; return }
        let anchor = selectedSession
        do {
            let profile = try service.createAccountProfile(name: name, provider: provider, allowsSharedMemory: newProfileAllowsSharedMemory)
            try service.selectAccountProfile(id: profile.id, provider: provider)
            newProfileName = ""
            newProfileAllowsSharedMemory = true
            selectedProfileIDs[provider] = profile.id
            providerUsageReport = nil
            accountProfiles[provider] = try service.accountProfiles(provider: provider)
            loadedUsageControlsScopeKey = nil
            refresh(forceUsageStatistics: true)
            authStatus.removeValue(forKey: profile.id)
            if let anchor { selectOrCreateSession(for: provider, anchoredTo: anchor) }
            else { status = "已建立隔離的 \(provider.rawValue.capitalized) 帳戶；請在 App 終端機登入。" }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setSelectedAccountMemorySharing(_ allowed: Bool) {
        guard let service, let profile = selectedAccountProfile else { return }
        do {
            try service.setAccountSharedMemoryAllowed(id: profile.id, allowed: allowed)
            accountProfiles[settings.defaultProvider] = try service.accountProfiles(provider: settings.defaultProvider)
            status = allowed ? "已允許此帳戶載入與保存專案共用記憶。" : "此帳戶不會載入或保存專案共用記憶。"
            refreshSelectedEvents()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveMemoryNotes() {
        guard let service, let session = selectedSession else { return }
        do {
            try service.setSharedMemoryNotes(sessionID: session.id, notes: memoryNotes)
            memorySnapshot = try service.sharedMemory(sessionID: session.id)
            status = "共用記憶備註已儲存。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearSharedMemory() {
        guard let service, let session = selectedSession else { return }
        do {
            try service.clearSharedMemory(sessionID: session.id)
            memorySnapshot = try service.sharedMemory(sessionID: session.id)
            memoryNotes = memorySnapshot?.notes ?? ""
            confirmClearMemory = false
            status = "此專案與提交版本的共用記憶已清除。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        settingsPanel
                        usagePanel
                        accountPanel
                        workspacePanel
                        sessionList
                    }
                    .padding(12)
                }
                .frame(width: 330)
                Divider()
                conversationPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(14)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 1160, minHeight: 780)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, model.appLanguage.locale)
        .alert("AgentBridge", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.localized(model.errorMessage ?? ""))
        }
        .alert("清除此專案的共用記憶？", isPresented: $model.confirmClearMemory) {
            Button("清除記憶", role: .destructive) { model.clearSharedMemory() }
            Button("取消", role: .cancel) { model.confirmClearMemory = false }
        } message: {
            Text("這會刪除此來源儲存庫與固定提交版本的對話記憶與備註。provider 原生工作階段不會被修改。")
        }
        .onChange(of: model.selectedSessionID) { _, _ in model.selectedSessionDidChange() }
        .onAppear { model.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2.weight(.semibold)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AgentBridge").font(.headline)
                Text("Codex 與 Claude 共用專案記憶").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("語言", selection: $model.appLanguage) {
                Text("English").tag(AppLanguage.english)
                Text("繁體中文").tag(AppLanguage.traditionalChinese)
            }
            .pickerStyle(.menu)
            if let session = model.selectedSession {
                Text("\(session.provider.rawValue.capitalized) · \(model.selectedSessionProfileName)")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
            Button("檢查登入與方案") { model.checkAuthentication() }
            Button("更新") { model.refresh() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var settingsPanel: some View {
        GroupBox("助理") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("助理", selection: Binding(
                        get: { model.settings.defaultProvider },
                        set: { model.selectDefaultProvider($0) }
                    )) {
                        Text("Codex").tag(AgentProvider.codex)
                        Text("Claude").tag(AgentProvider.claude)
                }
                if model.settings.defaultProvider == .claude {
                    Picker("Claude 使用模式", selection: Binding(
                            get: { model.settings.usageMode },
                            set: { model.selectUsageMode($0) }
                        )) {
                            Text("官方 CLI 訂閱登入").tag(UsageMode.subscription)
                            Text("Claude API（每次確認）").tag(UsageMode.api)
                    }
                } else {
                    Label("Codex 使用官方 CLI 訂閱登入", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.isClaudeAPIRunContext {
                    Label("Claude API 會產生費用；每次執行都要確認。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                DisclosureGroup("CLI 執行檔") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Codex CLI 自動尋找", text: $model.codexPath)
                        TextField("Claude CLI 自動尋找", text: $model.claudePath)
                        Button("儲存 CLI 路徑") { model.saveSettings() }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var usagePanel: some View {
        GroupBox(model.settings.defaultProvider == .claude && model.settings.usageMode == .api
            ? "Claude API 本機預算"
            : "訂閱活動估計") {
            VStack(alignment: .leading, spacing: 8) {
                if model.settings.defaultProvider == .claude && model.settings.usageMode == .api {
                    apiUsageDashboard
                } else {
                    subscriptionUsageDashboard
                }
                if model.settings.defaultProvider == .claude {
                    apiReconciliationPanel
                }
                if let alert = model.usageAlerts.first {
                    Label(model.localized(alert), systemImage: "bell.badge")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("macOS 門檻通知（需允許通知）", isOn: Binding(
                    get: { model.usageControls.macOSNotificationsEnabled },
                    set: { model.setMacOSUsageNotificationsEnabled($0) }
                ))
                .font(.caption2)
                if !model.usageControlStatus.isEmpty {
                    Text(model.localized(model.usageControlStatus))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private var apiReconciliationPanel: some View {
        if !model.apiReconciliationCandidates.isEmpty {
            GroupBox("手動結算未確認的 Claude API 費用") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("選擇此帳戶綁定的工作階段，並依 Anthropic 帳單輸入實際費用。這只更新本機帳本，不會呼叫 provider；只有帳單明確顯示零費用時才輸入 0。若狀態仍是執行中，系統會先確認沒有作用中的執行鎖；只有中斷後殘留的狀態才會標記失敗並結算。若一個帳本先完成，使用相同金額重試即可。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: model.localized("帳戶：%@"), model.selectedAccountProfile?.name ?? "Claude"))
                        .font(.caption2.weight(.semibold))
                    ForEach(model.apiReconciliationCandidates) { candidate in
                        Button {
                            model.apiReconciliationSessionID = candidate.session.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: candidate.session.id == model.apiReconciliationSessionID ? "largecircle.fill.circle" : "circle")
                                    Text(URL(fileURLWithPath: candidate.session.sourceRepositoryPath).lastPathComponent)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text(model.localized(candidate.session.status.rawValue.capitalized))
                                        .foregroundStyle(candidate.session.status == .running ? .orange : .secondary)
                                }
                                Text(candidate.session.id.uuidString.lowercased())
                                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(String(format: model.localized("月度預留：%@ · 每日/工作階段預留：%@"),
                                            model.localized(candidate.monthlyLedgerUnresolved ? "未結算" : "無待結算"),
                                            model.localized(candidate.dailySessionLedgerUnresolved ? "未結算" : "無待結算")))
                                    .font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    HStack {
                        Text("帳單實際費用（USD）").font(.caption2)
                        TextField("例如 1.25", text: $model.apiReconciliationActualUSD)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 105)
                    }
                    Toggle("我已對照 Anthropic provider 帳單，確認這是所選工作階段的實際費用。", isOn: $model.apiReconciliationConfirmed)
                        .font(.caption2)
                    Button("結算已確認的費用") { model.reconcileSelectedAPICost() }
                        .controlSize(.small)
                        .disabled(model.selectedAPIReconciliationCandidate == nil
                            || !model.apiReconciliationConfirmed)
                    if !model.apiReconciliationStatus.isEmpty {
                        Text(model.localized(model.apiReconciliationStatus))
                            .font(.caption2)
                            .foregroundStyle(model.apiReconciliationStatus.contains("已手動結算") ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        } else if (model.budgetSnapshot?.reservedUSD ?? 0) > 0 {
            Label("月度帳本包含無法安全歸屬到目前 Claude 帳戶的舊預留；為避免把費用分配給錯誤帳戶，這些預留目前不能由此處結算。", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subscriptionUsageDashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let activity = model.usageStatistics {
                HStack(spacing: 6) {
                    usageMetric("近 5 小時", value: "\(activity.subscriptionFiveHourRuns)", detail: "次本機啟動")
                    usageMetric("近 7 天", value: "\(activity.subscriptionSevenDayRuns)", detail: "次本機啟動")
                }
                Chart(activity.sevenDayBuckets) { bucket in
                    BarMark(
                        x: .value(model.localized("24 小時區間"), bucket.index),
                        y: .value(model.localized("AgentBridge 啟動"), bucket.runCount)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: activity.sevenDayBuckets.map(\.index)) { value in
                        AxisValueLabel {
                            if let index = value.as(Int.self),
                               let bucket = activity.sevenDayBuckets.first(where: { $0.index == index }) {
                                Text(model.localized(bucket.label)).font(.system(size: 8))
                            }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 82)
                Text(String(format: model.localized("近 24 小時：%@ 次 · 目前 AgentBridge 工作階段：%@ 次。只統計此 %@ 帳戶的本機執行嘗試，不是供應商額度或帳戶總用量；互動終端回合不會被讀取。"),
                            String(activity.subscriptionDailyRuns),
                            String(activity.subscriptionSessionRuns),
                            activity.provider.rawValue.capitalized))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(format: model.localized("本機統計更新於 %@"),
                            activity.generatedAt.formatted(Date.FormatStyle(time: .shortened).locale(model.appLanguage.locale))))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            } else {
                ProgressView("載入本機活動記錄…").controlSize(.small)
            }
            Label("按下「送出 /usage」後，App 會從官方 CLI 可見畫面盡力辨識方案、用量百分比與重置時間；未知欄位顯示「Not provided / 未提供」。請以仍開啟的原始 TUI 核對資料卡。", systemImage: "terminal")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("開啟官方 CLI 用量終端") { model.openSubscriptionUsageTUI() }
                    .controlSize(.small)
                    .disabled(model.terminalLaunch != nil || model.isSwitchingTarget)
                Text("等終端顯示可輸入提示符並完成登入後，再按「送出 /usage」。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = model.providerUsageReport,
               report.provider == model.settings.defaultProvider,
               report.accountProfileID == model.selectedProfileIDs[model.settings.defaultProvider] {
                providerUsageReportCard(report)
            }
            DisclosureGroup("AgentBridge 本機執行上限") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("留空或輸入 0 代表不限。上限計算 AgentBridge 管理的唯讀執行提示與互動工作階段啟動，不代表 provider 限額或 TUI 內的回合。")
                        .font(.caption2).foregroundStyle(.secondary)
                    usageLimitRow("近 5 小時", keyPath: \.subscriptionFiveHourRunLimit)
                    usageLimitRow("近 24 小時", keyPath: \.subscriptionDailyRunLimit)
                    usageLimitRow("近 7 天", keyPath: \.subscriptionWeeklyRunLimit)
                    usageLimitRow("目前工作階段", keyPath: \.subscriptionSessionRunLimit)
                    Button("儲存本機上限") { model.saveUsageControlSettings() }
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
    }

    private var apiUsageDashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let budget = model.budgetSnapshot {
                let committed = budget.usedUSD + budget.reservedUSD
                HStack(spacing: 5) {
                    usageMetric("本月已用", value: String(format: "$%.2f", budget.usedUSD), detail: "本機帳本")
                    usageMetric("已保留", value: String(format: "$%.2f", budget.reservedUSD), detail: "未結算執行")
                }
                HStack {
                    Text("可用")
                    Spacer()
                    Text(String(format: "$%.2f", budget.availableUSD)).fontWeight(.semibold)
                }
                .font(.caption)
                ProgressView(value: min(1, committed / budget.monthlyLimitUSD))
                    .tint(committed >= budget.monthlyLimitUSD ? .red : .accentColor)
                if committed >= budget.monthlyLimitUSD {
                    Label("已達 AgentBridge 本機月上限；新的 API 執行會被阻擋。", systemImage: "xmark.octagon.fill")
                        .font(.caption2).foregroundStyle(.red)
                }
                let builtInLedgerNote = model.selectedAccountProfile?.id == AccountProfile.defaultID(for: .claude)
                    ? "內建帳戶沿用舊版帳本；舊紀錄的帳戶歸屬無法還原。新帳戶各自使用獨立帳本。"
                    : "此 Claude 帳戶使用獨立帳本；App 與 CLI 共用。"
                Text(String(format: model.localized("UTC %@ · 本機月上限 $%.2f。此帳本與 Anthropic provider credit/帳單分開。%@"), budget.month, budget.monthlyLimitUSD, model.localized(builtInLedgerNote)))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("此 Claude 帳戶尚未設定本機 API 月上限；完成設定前不會啟用 API 執行。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let activity = model.usageStatistics {
                Text(String(format: model.localized("此帳戶近 24 小時 API 啟動：%@ 次 · 目前工作階段：%@ 次"),
                            String(activity.apiDailyRuns),
                            String(activity.apiSessionRuns)))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(String(format: model.localized("本機統計更新於 %@"),
                            activity.generatedAt.formatted(Date.FormatStyle(time: .shortened).locale(model.appLanguage.locale))))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            if let costs = model.apiCostSnapshot {
                if let limit = costs.dailyLimitUSD {
                    apiDollarCapRow(
                        title: "UTC 今日 API 費用上限",
                        used: costs.dailyUsedUSD,
                        reserved: costs.dailyReservedUSD,
                        limit: limit
                    )
                }
                if let limit = costs.sessionLimitUSD {
                    apiDollarCapRow(
                        title: "目前 AgentBridge 工作階段 API 費用上限",
                        used: costs.sessionUsedUSD,
                        reserved: costs.sessionReservedUSD,
                        limit: limit
                    )
                }
                if costs.hasUnresolvedCall {
                    Label("上一筆 API 執行費用尚未確認；新的付費執行會保持封鎖。", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            DisclosureGroup("Claude API 本機控制") {
                VStack(alignment: .leading, spacing: 6) {
                    if model.selectedAccountProfile?.id == AccountProfile.defaultID(for: .claude) {
                        Text("內建 Claude 帳戶沿用既有 AgentBridge 本機 US$140 月帳本；App 與 CLI 共用。舊版帳本沒有帳戶欄位，過去紀錄可能跨帳戶，無法回溯拆分。")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("本機月上限（USD）")
                            TextField("例如 25", text: $model.apiMonthlyLimitInput)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.usageControls.apiMonthlyLimitUSD != nil)
                                .frame(width: 95)
                        }
                        if model.usageControls.apiMonthlyLimitUSD != nil {
                            Text("此帳戶月帳本已建立；為保留既有支出，月上限不能再變更。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("美元上限（預留金額按單次預算的兩倍計算）")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    apiDollarLimitInputRow("UTC 每日 USD 上限", text: $model.apiDailyLimitInput)
                    apiDollarLimitInputRow("工作階段 USD 上限", text: $model.apiSessionLimitInput)
                    Text("選用 API 執行次數上限（獨立於美元上限）")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    usageLimitRow("近 24 小時執行次數", keyPath: \.apiDailyRunLimit)
                    usageLimitRow("目前工作階段執行次數", keyPath: \.apiSessionRunLimit)
                    Toggle("停用此帳戶後續 Claude API 執行", isOn: Binding(
                        get: { model.usageControls.disableFutureAPI },
                        set: { value in model.updateUsageControls { $0.disableFutureAPI = value } }
                    ))
                    .font(.caption2)
                    Button("儲存本機控制") { model.saveUsageControlSettings() }
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }
            Text("每次填寫的 USD 預算是本次 API 執行上限；本機月預算、API 執行次數及 provider credit 是不同限制。停用後續 API 只會阻止此帳戶未來的 AgentBridge API 執行，不會切換帳戶或模式。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Claude API 本機帳本不代表訂閱用量；若要查看 Claude 訂閱方案用量，請切回官方 CLI 訂閱登入模式，再由訂閱活動面板開啟用量終端。", systemImage: "terminal")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func usageMetric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.localized(title)).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            Text(model.localized(detail)).font(.system(size: 8)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }

    private func apiDollarLimitInputRow(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(model.localized(title)).font(.caption2)
            Spacer(minLength: 4)
            TextField("不限", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 95)
        }
    }

    private func providerUsageReportCard(_ report: ProviderUsageReport) -> some View {
        GroupBox("官方 /usage 摘要 · Best-effort") {
            VStack(alignment: .leading, spacing: 5) {
                usageReportField("Provider / 供應商", report.provider.rawValue.capitalized)
                usageReportField("Selected account / 選取帳戶", report.accountName)
                usageReportField("Plan / 方案", report.plan ?? "Not provided / 未提供", localizeValue: report.plan == nil)
                if report.usageWindows.isEmpty {
                    usageReportField("Usage windows / 用量視窗", "Not provided / 未提供", localizeValue: true)
                } else {
                    ForEach(report.usageWindows) { window in
                        Divider()
                        Text(model.localized(window.label)).font(.caption.weight(.semibold))
                        usageReportField(
                            "Used / 已使用",
                            formattedUsagePercentage(window.percentageUsed),
                            localizeValue: window.percentageUsed == nil
                        )
                        usageReportField(
                            "Reset / 重置",
                            window.resetText ?? "Not provided / 未提供",
                            localizeValue: window.resetText == nil
                        )
                    }
                }
                usageReportField("Source / 來源", model.localized(report.source))
                usageReportField(
                    "Status / 狀態",
                    report.status == .recognizedFields
                        ? "Some fields recognized / 已辨識部分欄位"
                        : "No recognized fields / 未辨識到欄位",
                    localizeValue: true
                )
                usageReportField("Captured / 擷取時間", report.capturedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(model.appLanguage.locale)))
                Text("Best-effort screen reading, not a stable API. Keep the official TUI visible to verify these fields. / 依畫面盡力辨識，非穩定 API；請保留官方 TUI 畫面核對。")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func usageReportField(_ title: String, _ value: String, localizeValue: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(model.localized(title)).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(localizeValue ? model.localized(value) : value).font(.caption2.monospacedDigit()).multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func formattedUsagePercentage(_ value: Double?) -> String {
        guard let value else { return "Not provided / 未提供" }
        return value.rounded() == value ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    private func apiDollarCapRow(title: String, used: Double, reserved: Double, limit: Double) -> some View {
        let committed = used + reserved
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model.localized(title))
                Spacer(minLength: 4)
                Text(String(format: "$%.2f / $%.2f", committed, limit)).fontWeight(.semibold)
            }
            .font(.caption2)
            ProgressView(value: min(1, committed / limit))
                .tint(committed >= limit ? .red : .accentColor)
            Text(String(format: model.localized("已用 $%.2f · 保留 $%.2f · 可用 $%.2f"), used, reserved, max(0, limit - committed)))
                .font(.system(size: 8)).foregroundStyle(.secondary)
            if committed >= limit {
                Label("已達本機 USD 上限；新的 API 執行會被阻擋。", systemImage: "xmark.octagon.fill")
                    .font(.system(size: 8)).foregroundStyle(.red)
            }
        }
    }

    private func usageLimitRow(_ title: String, keyPath: WritableKeyPath<UsageControlSettings, Int?>) -> some View {
        HStack {
            Text(model.localized(title)).font(.caption2)
            Spacer(minLength: 4)
            TextField("0 = 不限", value: usageLimitBinding(keyPath), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 75)
        }
    }

    private func usageLimitBinding(_ keyPath: WritableKeyPath<UsageControlSettings, Int?>) -> Binding<Int> {
        Binding(
            get: { model.usageControls[keyPath: keyPath] ?? 0 },
            set: { value in
                model.updateUsageControls { settings in
                    settings[keyPath: keyPath] = value == 0 ? nil : value
                }
            }
        )
    }

    private var accountPanel: some View {
        GroupBox("官方 CLI 帳戶") {
            VStack(alignment: .leading, spacing: 8) {
                if let profile = model.selectedAccountProfile {
                    Picker("帳戶", selection: Binding(
                        get: { model.selectedProfileIDs[model.settings.defaultProvider] ?? profile.id },
                        set: { model.selectAccountProfile($0) }
                    )) {
                        ForEach(model.accountProfiles[model.settings.defaultProvider] ?? []) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    if let assessment = model.selectedProfileAuthentication {
                        Label(model.localized(assessment.message), systemImage: assessment.confirmedSubscription ? "checkmark.seal" : "exclamationmark.shield")
                            .font(.caption).foregroundStyle(assessment.confirmedSubscription ? Color.secondary : Color.orange)
                    } else {
                        Text("尚未檢查此帳戶的登入方式與方案。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("允許此帳戶載入與保存專案共用記憶", isOn: Binding(
                        get: { model.selectedAccountProfile?.allowsSharedMemory ?? false },
                        set: { model.setSelectedAccountMemorySharing($0) }
                    ))
                    .font(.caption)
                    if !profile.usesExistingLogin {
                        Button("在 App 內登入此帳戶") { model.openProfileLoginTerminal() }
                            .disabled(model.terminalRunning)
                    } else {
                        Text("目前本機登入保持原狀；新增其他帳戶會使用獨立的 CLI 設定資料夾。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("正在載入帳戶設定…").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                TextField("新帳戶顯示名稱", text: $model.newProfileName)
                Toggle("建立後允許共用專案記憶（預設開啟）", isOn: $model.newProfileAllowsSharedMemory)
                    .font(.caption)
                Button("新增並切換帳戶") { model.createAccountProfile() }
                    .disabled(model.newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSwitchingTarget)
            }
            .padding(.vertical, 2)
        }
    }

    private var workspacePanel: some View {
        GroupBox("專案") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Git 儲存庫路徑", text: $model.repositoryPath)
                Button("選擇儲存庫…") { model.chooseRepository() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle("互動終端工作階段", isOn: $model.interactiveMode)
                    .disabled(model.settings.defaultProvider == .claude && model.settings.usageMode == .api)
                    .font(.caption)
                Button("建立同一專案的新工作階段") { model.createSession() }
                    .disabled(model.repositoryPath.isEmpty || model.isSwitchingTarget)
                Text("AgentBridge 固定提交版本並在自己的隔離工作區執行。相同來源與提交版本在 Codex、Claude 間共用聊天記憶。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var sessionList: some View {
        GroupBox("工作階段") {
            if model.sessions.isEmpty {
                ContentUnavailableView("尚無工作階段", systemImage: "bubble.left.and.bubble.right")
                    .frame(minHeight: 120)
            } else {
                List(model.sessions, selection: $model.selectedSessionID) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: session.provider == .codex ? "sparkle" : "message")
                            Text(session.provider.rawValue.capitalized)
                                .font(.headline)
                            if session.policy.accessMode == .interactiveManualApproval {
                                Text("Terminal").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: Capsule())
                            }
                        }
                        Text("\(model.profileName(for: session)) · \(model.localized(session.status.rawValue.capitalized))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(session.snapshotCommit.prefix(12)) · \(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .tag(session.id)
                }
                .frame(minHeight: 120, maxHeight: 280)
            }
        }
    }

    private var conversationPanel: some View {
        VStack(spacing: 10) {
            if let session = model.selectedSession {
                conversationHeader(session)
                memoryPanel(session)
                if session.policy.accessMode == .readOnly {
                    chatTimeline
                    composer(session)
                } else {
                    interactivePanel(session)
                }
            } else {
                ContentUnavailableView("選擇或建立工作階段", systemImage: "bubble.left.and.bubble.right", description: Text("先選擇 Git 儲存庫，再開始一段固定版本的專案對話。"))
                    .frame(maxWidth: .infinity, maxHeight: model.terminalLaunch == nil ? .infinity : 110)
            }
            if let launch = model.terminalLaunch {
                terminalPanel(launch)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func conversationHeader(_ session: SessionRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.provider == .codex ? "sparkle" : "message")
                .font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(session.provider.rawValue.capitalized) · \(model.profileName(for: session))")
                    .font(.headline)
                Text("\(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent) · \(session.snapshotCommit.prefix(12))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let assessment = model.selectedSessionAuthentication {
                Label(model.localized(assessment.message), systemImage: assessment.confirmedSubscription ? "checkmark.seal" : "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Button("本機終端機") { model.openLocalShell() }
                .disabled(model.terminalLaunch != nil)
            if session.policy.accessMode == .interactiveManualApproval {
                Button("開啟內嵌終端機") { model.openEmbeddedInteractiveTerminal() }
                    .disabled(model.terminalRunning)
                if session.status == .running { Button("取消工作階段") { model.cancelSession(session.id) } }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
    }

    private func memoryPanel(_ session: SessionRecord) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("專案共用記憶", systemImage: "brain.head.profile")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let memory = model.memorySnapshot {
                        Text(String(format: model.localized("修訂 %@ · %@ 則對話%@"),
                                    String(memory.revision),
                                    String(memory.turns.count),
                                    memory.wasTruncated ? model.localized(" · 顯示最近內容") : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let memory = model.memorySnapshot {
                    Text(String(format: model.localized("來源 %@ · 固定提交 %@"),
                                URL(fileURLWithPath: memory.scope.repositoryPath).lastPathComponent,
                                String(memory.scope.snapshotCommit.prefix(12))))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if let profile = model.selectedAccountProfile, !profile.allowsSharedMemory {
                    Label("此帳戶未同意把記憶傳給助理。開啟左側「允許此帳戶載入與保存」後才會共用。", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                DisclosureGroup("記憶備註與終端機交接") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("AgentBridge 會自動保存 App 聊天中成功完成的回合。內嵌 Terminal 的 TUI 內容不會自動匯入；請在這裡手動記下要交給另一個助理的重點。")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $model.memoryNotes)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 54, maxHeight: 90)
                        HStack {
                            Button("儲存備註") { model.saveMemoryNotes() }
                            Button("清除此提交的記憶…", role: .destructive) { model.confirmClearMemory = true }
                            Spacer()
                        }
                    }
                    .padding(.top, 5)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var chatTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let turns = model.memorySnapshot?.turns, !turns.isEmpty {
                        ForEach(turns) { turn in
                            messageBubble(label: model.localized("你"), text: turn.userText, alignment: .trailing, color: Color.accentColor.opacity(0.12), id: "user-\(turn.id)")
                            messageBubble(label: turn.provider.rawValue.capitalized, text: turn.assistantText, alignment: .leading, color: Color(nsColor: .controlBackgroundColor), id: "assistant-\(turn.id)")
                        }
                    } else {
                        ContentUnavailableView("開始專案對話", systemImage: "text.bubble", description: Text("成功完成的對話會依來源儲存庫與固定提交版本寫入共用記憶。"))
                            .frame(maxWidth: .infinity, minHeight: 180)
                    }
                    if model.isRunning {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.localized(model.status)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .id("running-indicator")
                    }
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: model.memorySnapshot?.revision) { _, _ in
                if let last = model.memorySnapshot?.turns.last {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("assistant-\(last.id)", anchor: .bottom) }
                }
            }
        }
    }

    private func messageBubble(label: String, text: String, alignment: HorizontalAlignment, color: Color, id: String) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(label.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: 720, alignment: alignment == .leading ? .leading : .trailing)
                .padding(12)
                .background(color, in: RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .id(id)
    }

    private func composer(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isClaudeAPIRunContext {
                Label("Claude API 會產生費用；每次執行都要輸入預算與確認。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                HStack {
                    TextField("本次預算（USD）", text: $model.apiBudget).frame(width: 160)
                    SecureField("Anthropic API key（只保留在記憶體）", text: $model.apiKey)
                    Toggle("確認這次付費呼叫", isOn: $model.confirmAPIRun).toggleStyle(.checkbox)
                }
                Text("取消執行無法撤回已產生的 Anthropic 費用。")
                    .font(.caption2).foregroundStyle(.orange)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextEditor(text: $model.prompt)
                    .font(.system(.body, design: .rounded))
                    .frame(minHeight: 78, maxHeight: 118)
                    .padding(5)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
                VStack(spacing: 7) {
                    Button(model.localized(model.isClaudeAPIRunContext ? "執行 Claude API" : "傳送")) { model.runPrompt() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isRunning || model.isSwitchingTarget || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.settings.usageMode == .api && (!model.isClaudeAPIRunContext || model.budgetSnapshot == nil)) || (model.isClaudeAPIRunContext && model.usageControls.disableFutureAPI))
                    if model.isRunning { Button("取消") { model.cancelRun() } }
                }
            }
            Text("提示和回應只在成功完成後進入共用記憶；金鑰不會保存。")
                .font(.caption2).foregroundStyle(.secondary)
            if session.sourceWasDirty {
                Text("來源有未提交變更；此對話固定的工作區不包含那些變更。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
    }

    private func interactivePanel(_ session: SessionRecord) -> some View {
        VStack(spacing: 8) {
            ContentUnavailableView("互動工作階段", systemImage: "terminal", description: Text("此工作階段使用 provider 原生互動終端。它不會自動匯入 TUI 對話；請將重點記在上方的共用記憶備註。"))
                .frame(maxHeight: 200)
            HStack {
                Text("已核准的指令可能存取工作區外的檔案或網路。")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("開啟內嵌終端機") { model.openEmbeddedInteractiveTerminal() }
                    .disabled(model.terminalRunning)
                if session.status == .running { Button("取消工作階段") { model.cancelSession(session.id) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func terminalPanel(_ launch: TerminalLaunchSpec) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                Text(model.localized(launch.title)).font(.subheadline.weight(.semibold))
                if model.terminalRunning { ProgressView().controlSize(.small) }
                Spacer()
                if model.terminalRunning && !model.terminalIsProfileLogin,
                   let sessionID = model.terminalSessionIDForView {
                    Button("取消工作階段") { model.cancelSession(sessionID) }
                }
                if model.canSendUsageCommand {
                    Button("送出 /usage") { model.requestUsageCommand() }
                        .help("只送出固定的 /usage 命令與 Enter；請先等待 CLI 顯示可輸入提示符並完成登入。")
                }
                Button(model.localized(model.terminalRunning ? (model.terminalNeedsManualStop ? "結束後關閉" : "取消並關閉") : "關閉終端")) { model.closeEmbeddedTerminal() }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            EmbeddedTerminalView(
                launch: launch,
                usageCommandRequest: model.usageCommandRequest,
                allowsUsageScreenCapture: model.terminalIsUsageTUI,
                onUsageScreenText: { screenText, capturedAt in
                    model.usageScreenDidUpdate(screenText, capturedAt: capturedAt)
                },
                onTermination: { exitCode in model.terminalDidTerminate(exitCode: exitCode) }
            )
            .id(launch.id)
            .frame(minHeight: 210, maxHeight: 340)
            if model.terminalIsUsageTUI && model.terminalRunning {
                Text("請先確認此終端已顯示所選帳戶的官方 CLI 提示符並完成登入，再按「送出 /usage」。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            Text("終端輸出只保留在目前畫面記憶體中；App 不會將 ANSI/TUI 逐字稿加入聊天記憶或稽核記錄。")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.bottom, 6)
            if model.terminalSessionIDForView == nil && !model.terminalIsProfileLogin {
                Text("本機 shell 位於 AgentBridge 複本，但仍以目前使用者權限執行。")
                    .font(.caption2).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if model.isRunning || model.isSwitchingTarget || model.terminalRunning { ProgressView().controlSize(.small) }
            Text(model.localized(model.status)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text("AgentBridge 0.4.0").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }
}
