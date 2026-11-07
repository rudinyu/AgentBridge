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
                ["run.started", "usage.subscription.reserved", "local.run.started", "usage.tokens"].contains(event.kind)
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

    /// Records the tokens a provider reported. A run that reported none records
    /// nothing, and a failed write never fails a run that succeeded. The account
    /// marker is how a discussion's events are matched to an account.
    func recordTokenUsage(_ usage: TokenUsage?, runID: UUID, profileID: UUID) {
        guard let usage else { return }
        try? store.appendEvent(AuditEvent(
            sessionID: runID,
            kind: "usage.tokens",
            message: "account_profile_id=\(profileID.uuidString.lowercased()); tokens reported: input \(usage.inputTokens), cached input \(usage.cachedInputTokens), cache write \(usage.cacheWriteTokens), output \(usage.outputTokens).",
            tokenUsage: usage
        ))
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
                    message: "No active run lock was found. The stale interrupted Claude API session was marked failed and will proceed to manual bill settlement."
                ))
            }

            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "api.cost.manual_reconciliation.attempted",
                message: String(format: "The user confirmed settling this Claude API session per the Anthropic bill at US$%.6f.", actualUSD)
            ))

            try ledger.reconcile(sessionID: sessionID, actualUSD: actualUSD, now: now)
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "api.cost.manual_reconciled",
                message: String(format: "The user manually settled the actual charge against the Anthropic bill: US$%.6f.", actualUSD)
            ))
        }
    }

    private func validateAPIReconciliationSession(_ session: SessionRecord, accountProfileID: UUID) throws {
        guard session.provider == .claude else {
            throw AgentBridgeError.sessionMismatch("Manual charge settlement is available only for Claude API sessions.")
        }
        let boundProfileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        guard boundProfileID == accountProfileID else {
            throw AgentBridgeError.sessionMismatch("The selected account is not the Claude account bound to this session.")
        }
        guard session.providerSessionID == nil else {
            throw AgentBridgeError.sessionMismatch("This session has a subscription-mode CLI session ID, so Claude API charges cannot be settled manually.")
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
        try runGate.authorizeManagedRun(
            runID: runID,
            profile: profile,
            usageMode: usageMode,
            requestedAPIUSD: requestedAPIUSD,
            now: now
        )
    }

    func authorizeLocalModelRun(
        runID: UUID,
        profile: AccountProfile,
        settings: LocalModelSettings,
        now: Date = Date()
    ) throws {
        try runGate.authorizeLocalModelRun(runID: runID, profile: profile, settings: settings, now: now)
    }

    func apiSpendLimits(for profileID: UUID, controls: UsageControlSettings) throws -> APISpendLimits {
        try runGate.apiSpendLimits(for: profileID, controls: controls)
    }

    private var runGate: RunGate {
        RunGate(
            store: store,
            usageControlStore: usageControlStore,
            monthlyAPILimitUSD: monthlyAPILimitUSD,
            loadStatistics: { provider, profileID, runID, now in
                try self.usageStatistics(provider: provider, profileID: profileID, selectedSessionID: runID, now: now)
            },
            ledger: { try self.spendLedger(for: $0) }
        )
    }

    /// Opens the account's spend ledger. On first use it imports the earlier
    /// monthly ledger (kept in the private root for the built-in profile) and
    /// the day/session ledger; those files are left unchanged.
    func spendLedger(for profileID: UUID) throws -> APISpendLedger {
        let profile = try accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
        if let cached = spendLedgers.cached(for: profileID) { return cached }

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
        return spendLedgers.register(ledger, for: profileID)
    }
}
