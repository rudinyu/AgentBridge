import Foundation

/// The last check before a provider process starts: per-account run limits and
/// API spend reservations. It holds no state of its own; the usage statistics
/// and spend ledger it reads come from the service that owns them.
struct RunGate {
    let store: AuditStore
    let usageControlStore: UsageControlStore
    let monthlyAPILimitUSD: Double
    let loadStatistics: (AgentProvider, UUID, UUID, Date) throws -> UsageStatisticsSnapshot
    let ledger: (UUID) throws -> APISpendLedger

    func authorizeManagedRun(
        runID: UUID,
        profile: AccountProfile,
        usageMode: UsageMode,
        requestedAPIUSD: Double? = nil,
        now: Date = Date()
    ) throws {
        try usageControlStore.withRunAuthorization(provider: profile.provider, accountProfileID: profile.id) { controls in
            do {
                let statistics = try loadStatistics(profile.provider, profile.id, runID, now)
                if usageMode == .api {
                    guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
                    guard !controls.disableFutureAPI else { throw UsageControlError.apiDisabled(profile.id) }
                    let limits = try apiSpendLimits(for: profile.id, controls: controls)
                    let ledger = try ledger(profile.id)
                    let budget = try ledger.budgetSnapshot(monthlyLimitUSD: limits.monthlyUSD, now: now)
                    guard budget.reservedUSD == 0 else { throw APICostLedgerError.unresolvedCall }
                    guard budget.usedUSD < budget.monthlyLimitUSD else {
                        throw UsageControlError.apiMonthlyLimitReached
                    }
                    if let requestedAPIUSD {
                        try ledger.checkReservation(sessionID: runID, requestedUSD: requestedAPIUSD, limits: limits, now: now)
                    }
                    try enforceRunLimit(used: statistics.apiDailyRuns, limit: controls.apiDailyRunLimit, window: .rolling24Hours)
                    try enforceRunLimit(used: statistics.apiSessionRuns, limit: controls.apiSessionRunLimit, window: .currentSession)
                } else {
                    try enforceRunLimit(
                        used: statistics.subscriptionFiveHourRuns,
                        limit: controls.subscriptionFiveHourRunLimit,
                        window: .fiveHours
                    )
                    try enforceRunLimit(
                        used: statistics.subscriptionDailyRuns,
                        limit: controls.subscriptionDailyRunLimit,
                        window: .rolling24Hours
                    )
                    try enforceRunLimit(
                        used: statistics.subscriptionSevenDayRuns,
                        limit: controls.subscriptionWeeklyRunLimit,
                        window: .rollingSevenDays
                    )
                    try enforceRunLimit(
                        used: statistics.subscriptionSessionRuns,
                        limit: controls.subscriptionSessionRunLimit,
                        window: .currentSession
                    )
                }
                try enforceTokenLimits(statistics, controls: controls)
                if usageMode == .subscription {
                    try store.appendEvent(AuditEvent(
                        sessionID: runID,
                        kind: "usage.subscription.reserved",
                        message: "account_profile_id=\(profile.id.uuidString.lowercased()); AgentBridge local usage preflight passed. This run attempt was added to the local count."
                    ))
                } else {
                    try store.appendEvent(AuditEvent(
                        sessionID: runID,
                        kind: "usage.api.reserved",
                        message: "AgentBridge local Claude API usage preflight passed. This paid run attempt was added to the local count."
                    ))
                }
            } catch let error as UsageControlError {
                try? store.appendEvent(AuditEvent(
                    sessionID: runID,
                    kind: "usage.run.blocked",
                    message: error.localizedDescription
                ))
                throw error
            } catch let error as APICostLedgerError {
                try? store.appendEvent(AuditEvent(
                    sessionID: runID,
                    kind: "usage.run.blocked",
                    message: error.localizedDescription
                ))
                throw error
            } catch let error as BudgetLedgerError {
                try? store.appendEvent(AuditEvent(
                    sessionID: runID,
                    kind: "usage.run.blocked",
                    message: error.localizedDescription
                ))
                throw error
            }
        }
    }

    func authorizeLocalModelRun(
        runID: UUID,
        profile: AccountProfile,
        settings: LocalModelSettings,
        now: Date = Date()
    ) throws {
        guard profile.provider == .local else {
            throw AccountProfileError.providerMismatch(profile.id, .local)
        }
        try usageControlStore.withRunAuthorization(provider: .local, accountProfileID: profile.id) { _ in
            do {
                let usage = try loadStatistics(.local, profile.id, runID, now)
                try enforceRunLimit(
                    used: usage.localDailyRuns,
                    limit: LocalModelClient.defaultDailyRunLimit,
                    window: .rolling24Hours
                )
                try enforceRunLimit(
                    used: usage.localSessionRuns,
                    limit: LocalModelClient.defaultSessionRunLimit,
                    window: .currentSession
                )
                try store.appendEvent(AuditEvent(
                    sessionID: runID,
                    kind: "local.run.started",
                    message: "account_profile_id=\(profile.id.uuidString.lowercased()); backend=\(settings.backend.rawValue); model=\(OutputRedactor.redact(settings.model)); local-only request passed AgentBridge local run limits."
                ))
            } catch let error as UsageControlError {
                try? store.appendEvent(AuditEvent(sessionID: runID, kind: "usage.run.blocked", message: error.localizedDescription))
                throw error
            }
        }
    }

    /// Tokens count in every usage mode, so one set of limits covers both.
    private func enforceTokenLimits(_ statistics: UsageStatisticsSnapshot, controls: UsageControlSettings) throws {
        for (used, limit, window) in [
            (statistics.fiveHourTokens, controls.fiveHourTokenLimit, UsageLimitWindow.fiveHours),
            (statistics.dailyTokens, controls.dailyTokenLimit, .rolling24Hours),
            (statistics.sevenDayTokens, controls.weeklyTokenLimit, .rollingSevenDays),
            (statistics.sessionTokens, controls.sessionTokenLimit, .currentSession)
        ] {
            guard let limit, used.totalTokens >= limit else { continue }
            throw UsageControlError.tokenLimitReached(window: window, used: used.totalTokens, limit: limit)
        }
    }

    private func enforceRunLimit(used: Int, limit: Int?, window: UsageLimitWindow) throws {
        guard let limit, used >= limit else { return }
        throw UsageControlError.runLimitReached(window: window, used: used, limit: limit)
    }

    /// The monthly cap comes from local controls; the built-in profile falls
    /// back to the historical cap, and other profiles must configure one.
    func apiSpendLimits(for profileID: UUID, controls: UsageControlSettings) throws -> APISpendLimits {
        let monthlyLimit = controls.apiMonthlyLimitUSD
            ?? (profileID == AccountProfile.defaultID(for: .claude) ? self.monthlyAPILimitUSD : nil)
        guard let monthlyLimit else { throw UsageControlError.apiMonthlyLimitRequired(profileID) }
        return APISpendLimits(
            monthlyUSD: monthlyLimit,
            dailyUSD: controls.apiDailyLimitUSD,
            sessionUSD: controls.apiSessionLimitUSD
        )
    }
}
