import Darwin
import Foundation

extension BridgeService {
    /// Uses the currently selected Claude profile when no profile ID is given.
    /// The built-in profile keeps the historical monthly cap; custom profiles
    /// must configure a local monthly cap.
    public func budgetSnapshot(profileID: UUID? = nil, now: Date = Date()) throws -> BudgetSnapshot {
        let id = try profileID ?? accountProfileStore.selected(provider: .claude).id
        let controls = try usageControlStore.settings(provider: .claude, accountProfileID: id)
        return try spendLedger(for: id).budgetSnapshot(
            monthlyLimitUSD: apiSpendLimits(for: id, controls: controls).monthlyUSD,
            now: now
        )
    }

    public func usageControlSettings(provider: AgentProvider, profileID: UUID) throws -> UsageControlSettings {
        let profile = try accountProfile(id: profileID)
        guard profile.provider == provider else { throw AccountProfileError.providerMismatch(profileID, provider) }
        return try usageControlStore.settings(provider: provider, accountProfileID: profileID)
    }

    public func saveUsageControlSettings(
        _ settings: UsageControlSettings,
        provider: AgentProvider,
        profileID: UUID
    ) throws {
        let profile = try accountProfile(id: profileID)
        guard profile.provider == provider else { throw AccountProfileError.providerMismatch(profileID, provider) }
        try settings.validate()
        if provider == .claude, profileID == AccountProfile.defaultID(for: .claude),
           let configuredLimit = settings.apiMonthlyLimitUSD,
           configuredLimit != monthlyAPILimitUSD {
            throw UsageControlError.invalidAPIDollarLimit
        }
        if provider == .claude, profileID != AccountProfile.defaultID(for: .claude) {
            let existingSettings = try usageControlStore.settings(provider: provider, accountProfileID: profileID)
            if let existingLimit = existingSettings.apiMonthlyLimitUSD,
               settings.apiMonthlyLimitUSD != existingLimit {
                throw UsageControlError.invalidAPIDollarLimit
            }
            if let monthlyLimit = settings.apiMonthlyLimitUSD, existingSettings.apiMonthlyLimitUSD == nil {
                // Fixes the cap in the ledger on first configuration and rejects
                // a ledger that already holds a different cap before settings are saved.
                try spendLedger(for: profileID).bindMonthlyLimit(monthlyLimit)
            }
        }
        try usageControlStore.save(settings, provider: provider, accountProfileID: profileID)
    }

    public func usageStatistics(
        provider: AgentProvider,
        profileID: UUID? = nil,
        selectedSessionID: UUID? = nil,
        now: Date = Date()
    ) throws -> UsageStatisticsSnapshot {
        let profile = try profileID.map(accountProfile(id:)) ?? accountProfileStore.selected(provider: provider)
        guard profile.provider == provider else { throw AccountProfileError.providerMismatch(profile.id, provider) }
        let matchingSessions = try store.loadSessions().filter { session in
            session.provider == provider
                && (session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)) == profile.id
        }
        var events: [AuditEvent] = []
        for session in matchingSessions {
            events.append(contentsOf: try store.events(sessionID: session.id))
        }
        let matchingDiscussions = try discussionStore.list().filter { discussion in
            discussion.usageProfileIDs.contains(profile.id)
        }
        let discussionProfileMarker = "account_profile_id=\(profile.id.uuidString.lowercased())"
        for discussion in matchingDiscussions {
            events.append(contentsOf: try store.events(sessionID: discussion.id).filter { event in
                (event.kind == "run.started" || event.kind == "usage.subscription.reserved" || event.kind == "local.run.started")
                    && event.message.contains(discussionProfileMarker)
            })
        }
        return UsageStatisticsAggregator.aggregate(
            provider: provider,
            accountProfileID: profile.id,
            sessions: matchingSessions,
            events: events,
            additionalActivitySessionIDs: Set(matchingDiscussions.map(\.id)),
            selectedSessionID: selectedSessionID,
            now: now
        )
    }

    public func apiCostControlSnapshot(profileID: UUID, sessionID: UUID) throws -> APICostControlSnapshot {
        let profile = try accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
        let controls = try usageControlStore.settings(provider: .claude, accountProfileID: profileID)
        return try spendLedger(for: profileID).costControlSnapshot(
            sessionID: sessionID,
            dailyLimitUSD: controls.apiDailyLimitUSD,
            sessionLimitUSD: controls.apiSessionLimitUSD
        )
    }

    public func unresolvedAPICalls(profileID: UUID) throws -> [APIReconciliationCandidate] {
        let profile = try accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }

        let reservations = try spendLedger(for: profileID).unresolvedReservations()
        let candidateSessionIDs = Set(reservations.map(\.sessionID))
        let sessionsByID = Dictionary(uniqueKeysWithValues: try store.loadSessions().compactMap { session -> (UUID, SessionRecord)? in
            let boundProfileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
            guard session.provider == .claude, boundProfileID == profileID,
                  candidateSessionIDs.contains(session.id) else { return nil }
            return (session.id, session)
        })

        return reservations.compactMap { reservation in
            guard let session = sessionsByID[reservation.sessionID] else { return nil }
            return APIReconciliationCandidate(
                accountProfileID: profileID,
                session: session,
                requestedUSD: reservation.requestedUSD,
                reservedUSD: reservation.reservedUSD
            )
        }
        .sorted { $0.session.updatedAt > $1.session.updatedAt }
    }

    /// Manually records a bill-verified actual cost for a Claude API session
    /// that has no active run lease. Settlement is keyed by session ID, so
    /// repeating it with the same amount is safe.
    public func reconcileAPIUsageFromProviderBill(
        profileID: UUID,
        sessionID: UUID,
        actualUSD: Double,
        explicitlyConfirmed: Bool,
        now: Date = Date()
    ) throws {
        guard explicitlyConfirmed else { throw UsageControlError.apiReconciliationConfirmationRequired }
        guard actualUSD.isFinite, actualUSD >= 0 else { throw BudgetLedgerError.invalidActualCost }

        let profile = try accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
        var session = try loadSession(sessionID)
        try validateAPIReconciliationSession(session, accountProfileID: profileID)

        // Acquire the same nonblocking lease used by active runs before
        // interpreting `.running`. A free lease proves that status is stale
        // (for example, the app exited while a paid call was unresolved).
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        session = try loadSession(sessionID)
        try validateAPIReconciliationSession(session, accountProfileID: profileID)

        try usageControlStore.withRunAuthorization(provider: .claude, accountProfileID: profileID) { _ in
            let ledger = try spendLedger(for: profileID)
            guard try ledger.validateSessionReconciliation(sessionID: sessionID, actualUSD: actualUSD) else {
                throw UsageControlError.apiReconciliationNotFound(sessionID)
            }

            if session.status == .running {
                session.status = .failed
                session.updatedAt = now
                try store.saveSession(session)
                try store.appendEvent(AuditEvent(
                    timestamp: now,
                    sessionID: sessionID,
                    kind: "api.session.stale_run_recovered",
                    message: "未取得作用中的執行鎖；已將中斷後殘留的 Claude API 工作階段標記為失敗，接著進行帳單手動結算。"
                ))
            }

            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "api.cost.manual_reconciliation.attempted",
                message: String(format: "使用者確認將依 Anthropic 帳單，以 US$%.6f 結算此 Claude API 工作階段。", actualUSD)
            ))

            try ledger.reconcile(sessionID: sessionID, actualUSD: actualUSD, now: now)
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "api.cost.manual_reconciled",
                message: String(format: "使用者已對照 Anthropic 帳單，手動結算實際費用 US$%.6f。", actualUSD)
            ))
        }
    }

    private func validateAPIReconciliationSession(_ session: SessionRecord, accountProfileID: UUID) throws {
        guard session.provider == .claude else {
            throw AgentBridgeError.sessionMismatch("手動費用結算只適用於 Claude API 工作階段。")
        }
        let boundProfileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        guard boundProfileID == accountProfileID else {
            throw AgentBridgeError.sessionMismatch("所選帳戶不是此工作階段綁定的 Claude 帳戶。")
        }
        guard session.providerSessionID == nil else {
            throw AgentBridgeError.sessionMismatch("此工作階段具有訂閱模式 CLI 工作階段識別碼，不能手動結算 Claude API 費用。")
        }
    }

    func authorizeManagedRun(
        session: SessionRecord,
        profile: AccountProfile,
        usageMode: UsageMode,
        requestedAPIUSD: Double? = nil,
        now: Date = Date()
    ) throws {
        try authorizeManagedRun(
            runID: session.id,
            profile: profile,
            usageMode: usageMode,
            requestedAPIUSD: requestedAPIUSD,
            now: now
        )
    }

    func authorizeManagedRun(
        runID: UUID,
        profile: AccountProfile,
        usageMode: UsageMode,
        requestedAPIUSD: Double? = nil,
        now: Date = Date()
    ) throws {
        try usageControlStore.withRunAuthorization(provider: profile.provider, accountProfileID: profile.id) { controls in
            do {
                let statistics = try usageStatistics(
                    provider: profile.provider,
                    profileID: profile.id,
                    selectedSessionID: runID,
                    now: now
                )
                if usageMode == .api {
                    guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
                    guard !controls.disableFutureAPI else { throw UsageControlError.apiDisabled(profile.id) }
                    let limits = try apiSpendLimits(for: profile.id, controls: controls)
                    let ledger = try spendLedger(for: profile.id)
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
                if usageMode == .subscription {
                    try store.appendEvent(AuditEvent(
                        sessionID: runID,
                        kind: "usage.subscription.reserved",
                        message: "account_profile_id=\(profile.id.uuidString.lowercased()); AgentBridge 本機用量預檢通過；此次執行嘗試已計入本機計數。"
                    ))
                } else {
                    try store.appendEvent(AuditEvent(
                        sessionID: runID,
                        kind: "usage.api.reserved",
                        message: "AgentBridge 本機 Claude API 用量預檢通過；此次付費執行嘗試已計入本機計數。"
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
                let usage = try usageStatistics(
                    provider: .local,
                    profileID: profile.id,
                    selectedSessionID: runID,
                    now: now
                )
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

    private func enforceRunLimit(used: Int, limit: Int?, window: UsageLimitWindow) throws {
        guard let limit, used >= limit else { return }
        throw UsageControlError.runLimitReached(window: window, used: used, limit: limit)
    }

    /// The monthly cap comes from local controls; the built-in profile falls
    /// back to the historical cap, and other profiles must configure one.
    func apiSpendLimits(for profileID: UUID, controls: UsageControlSettings) throws -> APISpendLimits {
        let monthlyLimit = controls.apiMonthlyLimitUSD
            ?? (profileID == AccountProfile.defaultID(for: .claude) ? monthlyAPILimitUSD : nil)
        guard let monthlyLimit else { throw UsageControlError.apiMonthlyLimitRequired(profileID) }
        return APISpendLimits(
            monthlyUSD: monthlyLimit,
            dailyUSD: controls.apiDailyLimitUSD,
            sessionUSD: controls.apiSessionLimitUSD
        )
    }

    /// Opens the account's spend ledger. On first use it imports the earlier
    /// monthly ledger (kept in the private root for the built-in profile) and
    /// the day/session ledger; those files are left unchanged.
    func spendLedger(for profileID: UUID) throws -> APISpendLedger {
        let profile = try accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
        spendLedgerLock.lock()
        let cached = profileSpendLedgers[profileID]
        spendLedgerLock.unlock()
        if let cached { return cached }

        let directoryName = profileID.uuidString.lowercased()
        let legacyMonthlyRoot = profileID == AccountProfile.defaultID(for: .claude)
            ? store.rootURL
            : store.rootURL.appendingPathComponent("api-ledgers", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        let ledger = try APISpendLedger(
            rootURL: store.rootURL.appendingPathComponent("api-spend", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true),
            legacyMonthlyRootURL: legacyMonthlyRoot,
            legacyCostRootURL: store.rootURL.appendingPathComponent("api-cost-controls", isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        )
        spendLedgerLock.lock()
        defer { spendLedgerLock.unlock() }
        if let existing = profileSpendLedgers[profileID] { return existing }
        profileSpendLedgers[profileID] = ledger
        return ledger
    }
}
