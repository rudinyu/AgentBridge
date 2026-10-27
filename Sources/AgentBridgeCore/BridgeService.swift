import Darwin
import Foundation

public final class BridgeService: @unchecked Sendable {
    public let store: AuditStore
    public let workspaceManager: WorkspaceManager
    private let runner: SafeProcessRunner
    private let adapter: ProviderAdapter
    private let baseEnvironment: [String: String]
    private let legacyBudgetLedger: BudgetLedger
    private let monthlyAPILimitUSD: Double
    private let budgetLedgerLock = NSLock()
    private var profileBudgetLedgers: [UUID: BudgetLedger]
    private var profileAPICostLedgers: [UUID: APICostControlLedger] = [:]
    private let accountProfileStore: AccountProfileStore
    private let sharedMemoryStore: SharedMemoryStore
    private let usageControlStore: UsageControlStore

    public init(
        store: AuditStore,
        runner: SafeProcessRunner = SafeProcessRunner(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        monthlyAPILimitUSD: Double = 140
    ) throws {
        self.store = store
        self.runner = runner
        self.adapter = ProviderAdapter(runner: runner)
        self.baseEnvironment = baseEnvironment
        self.workspaceManager = WorkspaceManager(store: store, runner: runner, baseEnvironment: baseEnvironment)
        let legacyBudgetLedger = try BudgetLedger(rootURL: store.rootURL, monthlyLimitUSD: monthlyAPILimitUSD)
        self.legacyBudgetLedger = legacyBudgetLedger
        self.monthlyAPILimitUSD = monthlyAPILimitUSD
        self.profileBudgetLedgers = [AccountProfile.defaultID(for: .claude): legacyBudgetLedger]
        self.accountProfileStore = try AccountProfileStore(rootURL: store.rootURL)
        self.sharedMemoryStore = try SharedMemoryStore(rootURL: store.rootURL.appendingPathComponent("shared-memory", isDirectory: true))
        self.usageControlStore = try UsageControlStore(rootURL: store.rootURL)
    }

    public func settings() throws -> BridgeSettings { try store.loadSettings() }
    public func saveSettings(_ settings: BridgeSettings) throws { try store.saveSettings(settings) }
    public func sessions() throws -> [SessionRecord] { try store.loadSessions() }
    public func events(sessionID: UUID) throws -> [AuditEvent] { try store.events(sessionID: sessionID) }
    /// Uses the currently selected Claude profile when no profile ID is given.
    /// The built-in profile keeps the historical ledger location; custom
    /// profiles use separate ledgers and must configure a local monthly cap.
    public func budgetSnapshot(profileID: UUID? = nil, now: Date = Date()) throws -> BudgetSnapshot {
        let id = try profileID ?? accountProfileStore.selected(provider: .claude).id
        return try budgetLedger(for: id).snapshot(now: now)
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
            // This creates an empty ledger on first configuration and rejects
            // any pre-existing ledger with a different cap before settings are saved.
                let root = apiLedgerRoot(for: profileID)
                let configuredLedger = try BudgetLedger(rootURL: root, monthlyLimitUSD: monthlyLimit)
                budgetLedgerLock.lock()
                profileBudgetLedgers[profileID] = configuredLedger
                budgetLedgerLock.unlock()
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
        return UsageStatisticsAggregator.aggregate(
            provider: provider,
            accountProfileID: profile.id,
            sessions: matchingSessions,
            events: events,
            selectedSessionID: selectedSessionID,
            now: now
        )
    }

    public func apiCostControlSnapshot(profileID: UUID, sessionID: UUID) throws -> APICostControlSnapshot {
        let profile = try accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
        let controls = try usageControlStore.settings(provider: .claude, accountProfileID: profileID)
        return try apiCostLedger(for: profileID).snapshot(
            sessionID: sessionID,
            dailyLimitUSD: controls.apiDailyLimitUSD,
            sessionLimitUSD: controls.apiSessionLimitUSD
        )
    }

    public func unresolvedAPICalls(profileID: UUID) throws -> [APIReconciliationCandidate] {
        let profile = try accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }

        let monthlyReservations: [BudgetReservation]
        let controls = try usageControlStore.settings(provider: .claude, accountProfileID: profileID)
        if profileID == AccountProfile.defaultID(for: .claude)
            || controls.apiMonthlyLimitUSD != nil {
            monthlyReservations = try budgetLedger(for: profileID).unresolvedReservations()
        } else {
            monthlyReservations = []
        }
        let windowReservations = try apiCostLedger(for: profileID).unresolvedReservations()
        let monthlyBySession = Dictionary(uniqueKeysWithValues: monthlyReservations.map { ($0.sessionID, $0) })
        let windowBySession = Dictionary(uniqueKeysWithValues: windowReservations.map { ($0.sessionID, $0) })
        let candidateSessionIDs = Set(monthlyBySession.keys).union(windowBySession.keys)
        let sessionsByID = Dictionary(uniqueKeysWithValues: try store.loadSessions().compactMap { session -> (UUID, SessionRecord)? in
            let boundProfileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
            guard session.provider == .claude, boundProfileID == profileID,
                  candidateSessionIDs.contains(session.id) else { return nil }
            return (session.id, session)
        })

        return candidateSessionIDs.compactMap { sessionID in
            guard let session = sessionsByID[sessionID] else { return nil }
            let monthly = monthlyBySession[sessionID]
            let windows = windowBySession[sessionID]
            return APIReconciliationCandidate(
                accountProfileID: profileID,
                session: session,
                requestedUSD: windows?.requestedUSD ?? monthly?.requestedUSD,
                monthlyReservedUSD: monthly?.reservedUSD,
                dailySessionReservedUSD: windows?.reservedUSD,
                monthlyLedgerUnresolved: monthly != nil,
                dailySessionLedgerUnresolved: windows != nil
            )
        }
        .sorted { $0.session.updatedAt > $1.session.updatedAt }
    }

    /// Manually records a bill-verified actual cost for a Claude API session
    /// that has no active run lease. The monthly and daily/session ledgers
    /// settle by session ID, making retries safe if one ledger write succeeds
    /// before another fails.
    public func reconcileAPIUsageFromProviderBill(
        profileID: UUID,
        sessionID: UUID,
        actualUSD: Double,
        explicitlyConfirmed: Bool,
        now: Date = Date()
    ) throws -> APIManualSettlementResult {
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

        return try usageControlStore.withRunAuthorization(provider: .claude, accountProfileID: profileID) { controls in
            let monthlyLimit = controls.apiMonthlyLimitUSD
                ?? (profileID == AccountProfile.defaultID(for: .claude) ? monthlyAPILimitUSD : nil)
            guard let monthlyLimit else { throw UsageControlError.apiMonthlyLimitRequired(profileID) }
            let monthlyLedger = try budgetLedger(for: profileID, configuredMonthlyLimit: monthlyLimit)
            let windowLedger = try apiCostLedger(for: profileID)
            let hasMonthlyReservation = try monthlyLedger.validateSessionReconciliation(
                sessionID: sessionID,
                actualUSD: actualUSD
            )
            let hasWindowReservation = try windowLedger.validateSessionReconciliation(
                sessionID: sessionID,
                actualUSD: actualUSD
            )
            guard hasMonthlyReservation || hasWindowReservation else {
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

            let monthlySettled = try monthlyLedger.reconcile(sessionID: sessionID, actualUSD: actualUSD, now: now)
            let windowSettled: Bool
            do {
                windowSettled = try windowLedger.reconcile(sessionID: sessionID, actualUSD: actualUSD, now: now)
            } catch {
                if monthlySettled {
                    try? store.appendEvent(AuditEvent(
                        sessionID: sessionID,
                        kind: "api.cost.manual_reconciliation.partial",
                        message: String(format: "部分結算：月度帳本已記錄 US$%.6f，但每日/工作階段帳本未完成。請以相同帳單金額重試。", actualUSD)
                    ))
                    throw UsageControlError.apiReconciliationPartial(sessionID)
                }
                throw error
            }

            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "api.cost.manual_reconciled",
                message: String(format: "使用者已對照 Anthropic 帳單，手動結算實際費用 US$%.6f。月度帳本：%@；每日/工作階段帳本：%@。", actualUSD, monthlySettled ? "已結算" : "無此預留", windowSettled ? "已結算" : "無此預留")
            ))
            return APIManualSettlementResult(
                monthlyLedgerSettled: monthlySettled,
                dailySessionLedgerSettled: windowSettled
            )
        }
    }

    public func cancel(sessionID: UUID) throws { try store.requestCancellation(for: sessionID) }

    public func accountProfiles(provider: AgentProvider) throws -> [AccountProfile] {
        try accountProfileStore.profiles(provider: provider)
    }

    public func selectedAccountProfile(provider: AgentProvider) throws -> AccountProfile {
        try accountProfileStore.selected(provider: provider)
    }

    public func createAccountProfile(name: String, provider: AgentProvider, allowsSharedMemory: Bool = true) throws -> AccountProfile {
        try accountProfileStore.create(name: name, provider: provider, allowsSharedMemory: allowsSharedMemory)
    }

    public func selectAccountProfile(id: UUID, provider: AgentProvider) throws {
        try accountProfileStore.select(id: id, provider: provider)
    }

    public func setAccountSharedMemoryAllowed(id: UUID, allowed: Bool) throws {
        try accountProfileStore.setSharedMemoryAllowed(id: id, allowed: allowed)
    }

    public func accountProfile(id: UUID) throws -> AccountProfile {
        for provider in AgentProvider.allCases {
            if let profile = try accountProfileStore.profiles(provider: provider).first(where: { $0.id == id }) {
                return profile
            }
        }
        throw AccountProfileError.profileNotFound(id)
    }

    public func sharedMemory(sessionID: UUID) throws -> SharedMemorySnapshot {
        let session = try loadSession(sessionID)
        return try sharedMemoryStore.snapshot(scope: memoryScope(for: session))
    }

    public func setSharedMemoryNotes(sessionID: UUID, notes: String) throws {
        let session = try loadSession(sessionID)
        try sharedMemoryStore.setNotes(scope: memoryScope(for: session), notes: notes)
    }

    public func clearSharedMemory(sessionID: UUID) throws {
        let session = try loadSession(sessionID)
        try sharedMemoryStore.clear(scope: memoryScope(for: session))
    }

    public func createSession(
        sourcePath: String,
        provider: AgentProvider,
        accessMode: AccessMode = .readOnly,
        snapshotCommit: String? = nil
    ) async throws -> SessionRecord {
        guard try store.loadSettings().usageMode != .api || provider == .claude else {
            throw AgentBridgeError.sessionMismatch("API 模式只支援 Claude；請先切換至訂閱登入模式以使用 Codex。")
        }
        let selectedProfile = try accountProfileStore.selected(provider: provider)
        return try await workspaceManager.createSnapshot(
            sourcePath: sourcePath,
            provider: provider,
            accessMode: accessMode,
            accountProfileID: selectedProfile.id,
            snapshotCommit: snapshotCommit
        )
    }

    public func checkAuthentication(provider: AgentProvider, profileID: UUID? = nil) async throws -> AuthAssessment {
        let settings = try store.loadSettings()
        let executable = try RuntimeEnvironment.resolveExecutable(provider: provider, configuredPath: settings.binaryPath(for: provider))
        let profile = try profileID.map(accountProfile(id:)) ?? accountProfileStore.selected(provider: provider)
        guard profile.provider == provider else {
            throw AccountProfileError.providerMismatch(profile.id, provider)
        }
        return try await checkAuthentication(profile: profile, executable: executable)
    }

    /// Opens the selected account's official subscription CLI in its native
    /// interactive TUI so the user can invoke its built-in /usage command.
    /// The core forwards the PTY only; it does not capture or persist screen text.
    @discardableResult
    public func runUsageTUI(
        provider: AgentProvider,
        profileID: UUID,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> ProcessResult {
        let settings = try store.loadSettings()
        guard settings.usageMode == .subscription else {
            throw AgentBridgeError.sessionMismatch("官方 usage TUI 只支援訂閱登入；請先切回訂閱模式。")
        }
        guard settings.defaultProvider == provider else {
            throw AgentBridgeError.sessionMismatch("目前 App 預設 provider 已變更；請從目前的訂閱用量面板重新開啟 usage TUI。")
        }
        let profile = try accountProfile(id: profileID)
        guard profile.provider == provider else {
            throw AccountProfileError.providerMismatch(profile.id, provider)
        }
        let selectedProfile = try accountProfileStore.selected(provider: provider)
        guard selectedProfile.id == profile.id else {
            throw AgentBridgeError.sessionMismatch("目前選取的帳戶已變更；請從該帳戶的訂閱用量面板重新開啟 usage TUI。")
        }

        let executable = try RuntimeEnvironment.resolveExecutable(
            provider: provider,
            configuredPath: settings.binaryPath(for: provider)
        )
        let assessment = try await checkAuthentication(profile: profile, executable: executable)
        guard assessment.confirmedSubscription else {
            throw AgentBridgeError.unauthenticated(profile.provider, assessment.message)
        }

        let temporaryDirectory = try makeFreshPrivateTemporaryDirectory(
            label: "usage-\(profile.provider.rawValue)-\(profile.id.uuidString.lowercased())"
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        var environment = try providerEnvironment(
            profile: profile,
            privateTemporaryDirectory: temporaryDirectory
        )
        environment["TERM"] = "xterm-256color"
        if profile.provider == .claude {
            environment["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
        }
        return try await adapter.runUsageTUI(
            provider: provider,
            executableURL: executable,
            environment: environment,
            workingDirectoryURL: temporaryDirectory,
            cancellation: cancellation
        )
    }

    private func checkAuthentication(profile: AccountProfile, executable: URL) async throws -> AuthAssessment {
        let temp = try makePrivateTemporaryDirectory(label: "auth-\(profile.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let environment = try providerEnvironment(profile: profile, privateTemporaryDirectory: temp)
        return try await adapter.checkAuthentication(provider: profile.provider, executableURL: executable, environment: environment, temporaryDirectory: temp)
    }

    @discardableResult
    public func runReadOnly(
        sessionID: UUID,
        prompt: String,
        apiRequest: APIUsageRequest? = nil,
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProviderOutput {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("請輸入要交給助理的內容。")
        }
        guard prompt.utf8.count <= 256_000 else {
            throw AgentBridgeError.invalidInput("提示內容最多 256 KiB。")
        }
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        let settings = try store.loadSettings()
        let session = try loadSession(sessionID)
        guard session.provider == .codex || session.provider == .claude,
              session.policy.accessMode == .readOnly,
              session.policy.workspaceReadOnly else {
            throw AgentBridgeError.sessionMismatch("工作階段不是唯讀模式。")
        }
        let profile = try requireBoundSelectedProfile(for: session)
        let apiMode = settings.usageMode == .api
        guard apiMode == (apiRequest != nil) else {
            if apiMode { throw AgentBridgeError.sessionMismatch("API 模式每次執行都需要輸入單次預算、API 金鑰及明確確認。") }
            throw AgentBridgeError.sessionMismatch("請先在設定中選擇 API 模式，或使用訂閱登入模式。")
        }
        if apiMode {
            guard session.provider == .claude else { throw AgentBridgeError.sessionMismatch("API 模式目前只支援 Claude。") }
            guard session.providerSessionID == nil else { throw AgentBridgeError.sessionMismatch("API 模式不支援續用訂閱模式的工作階段。") }
            guard let apiRequest, apiRequest.explicitlyAuthorized else {
                throw AgentBridgeError.sessionMismatch("API 執行需要明確確認本次付費預算。")
            }
            guard apiRequest.requestedBudgetUSD.isFinite,
                  apiRequest.requestedBudgetUSD >= 0.01,
                  apiRequest.requestedBudgetUSD <= 140,
                  abs(((apiRequest.requestedBudgetUSD * 100).rounded() / 100) - apiRequest.requestedBudgetUSD) < 0.000_000_1,
                  !apiRequest.apiKey.isEmpty,
                  !apiRequest.apiKey.contains("\0") else {
                throw AgentBridgeError.invalidInput("API 模式需要有效 API 金鑰，以及 US$0.01 至 US$140、最多兩位小數的單次預算。")
            }
        }
        try authorizeManagedRun(
            session: session,
            profile: profile,
            usageMode: settings.usageMode,
            requestedAPIUSD: apiRequest?.requestedBudgetUSD
        )
        let activeBudgetLedger = apiMode ? try budgetLedger(for: profile.id) : nil

        try await workspaceManager.validateWorkspace(for: session, accessMode: .readOnly)
        let executable = try RuntimeEnvironment.resolveExecutable(provider: session.provider, configuredPath: settings.binaryPath(for: session.provider))
        let temp = try makePrivateTemporaryDirectory(label: "run-\(sessionID.uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let (providerPrompt, memoryContext) = try promptWithSharedMemory(
            prompt,
            session: session,
            profile: profile
        )
        let apiKey = apiRequest?.apiKey
        let environment = try providerEnvironment(profile: profile, privateTemporaryDirectory: temp, apiKey: apiKey)
        var reservation: BudgetReservation?
        var apiCostReservation: APICostReservation?
        var activeAPICostLedger: APICostControlLedger?
        if let apiRequest {
            guard let activeBudgetLedger else { throw UsageControlError.apiMonthlyLimitRequired(profile.id) }
            let controls = try usageControlStore.settings(provider: .claude, accountProfileID: profile.id)
            let costLedger = try apiCostLedger(for: profile.id)
            let costReservation: APICostReservation
            do {
                costReservation = try costLedger.reserve(
                    sessionID: sessionID,
                    requestedUSD: apiRequest.requestedBudgetUSD,
                    dailyLimitUSD: controls.apiDailyLimitUSD,
                    sessionLimitUSD: controls.apiSessionLimitUSD
                )
                apiCostReservation = costReservation
                activeAPICostLedger = costLedger
                reservation = try activeBudgetLedger.reserve(
                    sessionID: sessionID,
                    requestedUSD: apiRequest.requestedBudgetUSD,
                    explicitlyAuthorized: apiRequest.explicitlyAuthorized
                )
            } catch {
                if let apiCostReservation { try? costLedger.cancelUnstarted(reservationID: apiCostReservation.id) }
                let reportedError: Error
                if let costError = error as? APICostLedgerError,
                   case .duplicateSession = costError {
                    // The monthly ledger remains the compatibility authority
                    // for refusing a second API run against one session.
                    reportedError = BudgetLedgerError.duplicateSession(sessionID)
                } else {
                    reportedError = error
                }
                try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "usage.run.blocked", message: OutputRedactor.redact(reportedError.localizedDescription)))
                throw reportedError
            }
        } else {
            let assessment = try await checkAuthentication(profile: profile, executable: executable)
            guard assessment.confirmedSubscription else {
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "auth.refused", message: "未確認訂閱登入；\(assessment.message)"))
                throw AgentBridgeError.unauthenticated(session.provider, assessment.message)
            }
        }

        var activeSession = session
        let emitter = ProgressEmitter(sessionID: sessionID, store: store, callback: onProgress)
        var reservationReconciled = false
        do {
            _ = store.consumeCancellationRequest(for: sessionID)
            activeSession.status = .running
            activeSession.updatedAt = Date()
            try store.saveSession(activeSession)
            if let reservation {
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "api.run.authorized", message: "已明確授權 Claude API 執行；單次上限 US$\(String(format: "%.2f", apiRequest?.requestedBudgetUSD ?? 0))，保留預算 US$\(String(format: "%.2f", reservation.reservedUSD))。實際費用仍以供應商帳單為準。"))
            } else {
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.started", message: "以訂閱登入開始唯讀執行。提示內容不會寫入稽核檔。"))
            }
            if let memoryContext {
                try? store.appendEvent(AuditEvent(
                    sessionID: sessionID,
                    kind: "memory.loaded",
                    message: "已載入共享記憶 revision \(memoryContext.revision)，包含 \(memoryContext.includedTurnCount) 個先前回合\(memoryContext.wasTruncated ? "（內容已截短）" : "")."
                ))
            }

            let (processResult, parsedOutput) = try await adapter.runReadOnly(
                provider: session.provider,
                session: session,
                prompt: providerPrompt,
                executableURL: executable,
                environment: environment,
                cancellationRequestURL: store.cancellationRequestURL(for: sessionID),
                apiBudgetUSD: apiRequest?.requestedBudgetUSD,
                onProgress: { emitter.emit($0) },
                cancellation: cancellation
            )
            let output: ProviderOutput
            if let apiRequest {
                output = ProviderOutput(
                    text: OutputRedactor.redact(parsedOutput.text, knownSecrets: [apiRequest.apiKey]),
                    providerSessionID: parsedOutput.providerSessionID,
                    actualCostUSD: parsedOutput.actualCostUSD
                )
            } else {
                output = parsedOutput
            }
            if let reservation {
                try activeBudgetLedger?.reconcile(reservationID: reservation.id, actualUSD: output.actualCostUSD)
                if let apiCostReservation {
                    try activeAPICostLedger?.reconcile(reservationID: apiCostReservation.id, actualUSD: output.actualCostUSD)
                }
                reservationReconciled = true
                if let actual = output.actualCostUSD, actual > reservation.requestedUSD {
                    try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "api.budget.exceeded", message: "Claude 回報費用高於單次上限；本次輸出不會標示為成功。費用以供應商帳單為準。"))
                    throw AgentBridgeError.providerFailed(.claude, "供應商回報費用超過單次上限。")
                }
            }
            activeSession.providerSessionID = reservation == nil ? safeProviderSessionID(output.providerSessionID) : nil
            activeSession.status = .completed
            activeSession.updatedAt = Date()
            try store.saveSession(activeSession)
            let storedText = String(output.text.prefix(200_000))
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.output", message: storedText))
            if reservation != nil {
                let costText = output.actualCostUSD.map { "供應商回報 US$\(String(format: "%.4f", $0))。" } ?? "供應商未提供實際費用；保留預算不退回。"
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "api.run.completed", message: costText))
            } else {
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.completed", message: processResult.outputWasTruncated ? "回應成功；部分非必要 CLI 輸出超過緩衝上限。" : "回應完成。"))
            }
            if profile.allowsSharedMemory {
                do {
                    try sharedMemoryStore.appendTurn(
                        scope: memoryScope(for: session),
                        provider: session.provider,
                        userText: prompt,
                        assistantText: output.text,
                        knownSecrets: apiRequest.map { [$0.apiKey] } ?? []
                    )
                } catch {
                    try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "memory.save.failed", message: "本次成功回應未能寫入共享記憶。"))
                }
            }
            return output
        } catch {
            if let reservation, !reservationReconciled { try? activeBudgetLedger?.reconcile(reservationID: reservation.id, actualUSD: nil) }
            if let apiCostReservation, !reservationReconciled {
                try? activeAPICostLedger?.reconcile(reservationID: apiCostReservation.id, actualUSD: nil)
            }
            activeSession.status = (error as? AgentBridgeError) == .processCancelled ? .cancelled : .failed
            activeSession.updatedAt = Date()
            try? store.saveSession(activeSession)
            let kind = activeSession.status == .cancelled ? "run.cancelled" : (reservation == nil ? "run.failed" : "api.run.failed")
            try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: kind, message: OutputRedactor.redact(error.localizedDescription)))
            throw error
        }
    }

    @discardableResult
    public func runInteractiveClaude(
        sessionID: UUID,
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try await runInteractive(sessionID: sessionID, cancellation: cancellation, onProgress: onProgress)
    }

    @discardableResult
    public func runInteractive(
        sessionID: UUID,
        profileID: UUID? = nil,
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        let settings = try store.loadSettings()
        guard settings.usageMode == .subscription else {
            throw AgentBridgeError.sessionMismatch("原生互動終端只使用訂閱登入模式；API 付費模式不支援互動終端。")
        }
        var session = try loadSession(sessionID)
        guard session.provider == .codex || session.provider == .claude,
              session.policy.accessMode == .interactiveManualApproval,
              !session.policy.workspaceReadOnly else {
            throw AgentBridgeError.sessionMismatch("請建立互動手動核准模式的工作階段。")
        }
        let profile = try requireBoundSelectedProfile(for: session)
        if let profileID, profileID != profile.id {
            throw AgentBridgeError.sessionMismatch("Terminal 啟動設定與工作階段綁定帳戶不同；請建立新的工作階段。")
        }
        try authorizeManagedRun(session: session, profile: profile, usageMode: .subscription)
        try await workspaceManager.validateWorkspace(for: session, accessMode: .interactiveManualApproval)
        let executable = try RuntimeEnvironment.resolveExecutable(provider: session.provider, configuredPath: settings.binaryPath(for: session.provider))
        let assessment = try await checkAuthentication(profile: profile, executable: executable)
        guard assessment.confirmedSubscription else {
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "auth.refused", message: "未確認 \(session.provider.rawValue) 訂閱登入；\(assessment.message)"))
            throw AgentBridgeError.unauthenticated(session.provider, assessment.message)
        }
        _ = store.consumeCancellationRequest(for: sessionID)
        onProgress?("正在 Terminal 啟動 \(session.provider.rawValue) 互動工作階段。")
        let workspacePath = session.workspacePath
        var contextFileURL: URL?
        defer {
            if let contextFileURL { removeWorkspaceContextFile(contextFileURL, workspacePath: workspacePath) }
        }
        do {
            session.status = .running
            session.updatedAt = Date()
            let invocationSession = session
            try store.saveSession(session)
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "interactive.launching", message: "正在 Terminal 啟動 \(session.provider.rawValue)；終端機操作與輸出不會被保存。"))
            let temp = try makePrivateTemporaryDirectory(label: "interactive-\(sessionID.uuidString.lowercased())")
            defer { try? FileManager.default.removeItem(at: temp) }
            var environment = try providerEnvironment(profile: profile, privateTemporaryDirectory: temp)
            environment["TERM"] = "xterm-256color"
            contextFileURL = try writeInteractiveMemoryContext(session: invocationSession, profile: profile)
            if contextFileURL != nil {
                try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "memory.loaded", message: "已提供共享記憶檔案給互動終端；終端機歷史不會被保存。"))
            }
            let result = try await adapter.runInteractive(
                provider: session.provider,
                session: invocationSession,
                executableURL: executable,
                environment: environment,
                cancellationRequestURL: store.cancellationRequestURL(for: sessionID),
                contextFilePath: contextFileURL?.path,
                cancellation: cancellation,
                onLaunched: { [store, invocationSession] in
                    var launchedSession = invocationSession
                    if launchedSession.provider == .claude {
                        launchedSession.providerSessionID = launchedSession.providerSessionID ?? launchedSession.id.uuidString.lowercased()
                    }
                    launchedSession.status = .running
                    launchedSession.updatedAt = Date()
                    do {
                        try store.saveSession(launchedSession)
                        try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "interactive.started", message: "\(invocationSession.provider.rawValue) 已在 Terminal 啟動；未保存終端機操作或輸出。"))
                        onProgress?("\(invocationSession.provider.rawValue) 互動工作階段已在 Terminal 中啟動。")
                        return true
                    } catch {
                        return false
                    }
                }
            )
            if session.provider == .claude {
                session.providerSessionID = session.id.uuidString.lowercased()
            }
            session.status = .completed
            session.updatedAt = Date()
            try store.saveSession(session)
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "interactive.completed", message: "\(session.provider.rawValue) 互動工作階段已結束；未保存終端機記錄。結束代碼 \(result.exitCode)。"))
            onProgress?("\(session.provider.rawValue) 互動工作階段已結束。")
            return result
        } catch {
            session = (try? loadSession(sessionID)) ?? session
            session.status = (error as? AgentBridgeError) == .processCancelled ? .cancelled : .failed
            session.updatedAt = Date()
            try? store.saveSession(session)
            try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: session.status == .cancelled ? "interactive.cancelled" : "interactive.failed", message: OutputRedactor.redact(error.localizedDescription)))
            onProgress?(OutputRedactor.redact(error.localizedDescription))
            throw error
        }
    }

    /// Starts an official interactive login for a new isolated profile. The
    /// provider CLI owns credential capture and browser completion; its output
    /// is attached directly to the caller's terminal and is never persisted.
    @discardableResult
    public func loginAccountProfile(
        profileID: UUID,
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let profile = try accountProfile(id: profileID)
        let arguments = try accountProfileStore.loginArguments(for: profile)
        let settings = try store.loadSettings()
        let executable = try RuntimeEnvironment.resolveExecutable(
            provider: profile.provider,
            configuredPath: settings.binaryPath(for: profile.provider)
        )
        let temp = try makePrivateTemporaryDirectory(label: "profile-login-\(profile.id.uuidString.lowercased())-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temp) }
        var environment = try providerEnvironment(profile: profile, privateTemporaryDirectory: temp)
        environment["TERM"] = "xterm-256color"
        onProgress?("請在官方 \(profile.provider.rawValue) 登入畫面完成這個新帳戶的登入。")
        let result = try await runner.runInteractive(
            executableURL: executable,
            arguments: arguments,
            environment: environment,
            workingDirectoryURL: store.rootURL,
            cancellationRequestURL: nil,
            cancellation: cancellation
        )
        if result.wasCancelled { throw AgentBridgeError.processCancelled }
        guard result.exitCode == 0 else {
            throw AgentBridgeError.providerFailed(profile.provider, "官方登入程序結束代碼 \(result.exitCode)。")
        }
        return result
    }

    private func requireBoundSelectedProfile(for session: SessionRecord) throws -> AccountProfile {
        let boundID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        let selected = try accountProfileStore.selected(provider: session.provider)
        guard selected.id == boundID else {
            throw AgentBridgeError.sessionMismatch("目前選取的帳戶與工作階段綁定帳戶不同；請建立新的隔離工作區後再執行。")
        }
        let profile = try accountProfile(id: boundID)
        guard profile.provider == session.provider else {
            throw AgentBridgeError.sessionMismatch("工作階段綁定了不同供應商的帳戶。")
        }
        return profile
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
        try usageControlStore.withRunAuthorization(provider: profile.provider, accountProfileID: profile.id) { controls in
            do {
                let statistics = try usageStatistics(
                    provider: profile.provider,
                    profileID: profile.id,
                    selectedSessionID: session.id,
                    now: now
                )
                if usageMode == .api {
                    guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
                    guard !controls.disableFutureAPI else { throw UsageControlError.apiDisabled(profile.id) }
                    let monthlyLimit = controls.apiMonthlyLimitUSD
                        ?? (profile.id == AccountProfile.defaultID(for: .claude) ? monthlyAPILimitUSD : nil)
                    guard let monthlyLimit else {
                        throw UsageControlError.apiMonthlyLimitRequired(profile.id)
                    }
                    let budget = try budgetLedger(for: profile.id, configuredMonthlyLimit: monthlyLimit).snapshot(now: now)
                    guard budget.reservedUSD == 0 else { throw APICostLedgerError.unresolvedCall }
                    guard budget.usedUSD + budget.reservedUSD < budget.monthlyLimitUSD else {
                        throw UsageControlError.apiMonthlyLimitReached
                    }
                    let costSnapshot = try apiCostLedger(for: profile.id).snapshot(
                        sessionID: session.id,
                        dailyLimitUSD: controls.apiDailyLimitUSD,
                        sessionLimitUSD: controls.apiSessionLimitUSD,
                        now: now
                    )
                    guard !costSnapshot.hasUnresolvedCall else { throw APICostLedgerError.unresolvedCall }
                    if let requestedAPIUSD {
                        let reservedUSD = requestedAPIUSD * 2
                        if let limit = costSnapshot.dailyLimitUSD,
                           costSnapshot.dailyUsedUSD + costSnapshot.dailyReservedUSD + reservedUSD > limit {
                            throw APICostLedgerError.dollarLimitReached(
                                scope: "UTC 每日",
                                limitUSD: limit,
                                committedUSD: costSnapshot.dailyUsedUSD + costSnapshot.dailyReservedUSD + reservedUSD
                            )
                        }
                        if let limit = costSnapshot.sessionLimitUSD,
                           costSnapshot.sessionUsedUSD + costSnapshot.sessionReservedUSD + reservedUSD > limit {
                            throw APICostLedgerError.dollarLimitReached(
                                scope: "目前工作階段",
                                limitUSD: limit,
                                committedUSD: costSnapshot.sessionUsedUSD + costSnapshot.sessionReservedUSD + reservedUSD
                            )
                        }
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
                        sessionID: session.id,
                        kind: "usage.subscription.reserved",
                        message: "AgentBridge 本機用量預檢通過；此次執行嘗試已計入本機計數。"
                    ))
                } else {
                    try store.appendEvent(AuditEvent(
                        sessionID: session.id,
                        kind: "usage.api.reserved",
                        message: "AgentBridge 本機 Claude API 用量預檢通過；此次付費執行嘗試已計入本機計數。"
                    ))
                }
            } catch let error as UsageControlError {
                try? store.appendEvent(AuditEvent(
                    sessionID: session.id,
                    kind: "usage.run.blocked",
                    message: error.localizedDescription
                ))
                throw error
            } catch let error as APICostLedgerError {
                try? store.appendEvent(AuditEvent(
                    sessionID: session.id,
                    kind: "usage.run.blocked",
                    message: error.localizedDescription
                ))
                throw error
            }
        }
    }

    private func enforceRunLimit(used: Int, limit: Int?, window: UsageLimitWindow) throws {
        guard let limit, used >= limit else { return }
        throw UsageControlError.runLimitReached(window: window, used: used, limit: limit)
    }

    private func budgetLedger(for profileID: UUID) throws -> BudgetLedger {
        let profile = try accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
        if profileID == AccountProfile.defaultID(for: .claude) { return legacyBudgetLedger }

        let controls = try usageControlStore.settings(provider: .claude, accountProfileID: profileID)
        guard let monthlyLimit = controls.apiMonthlyLimitUSD else {
            throw UsageControlError.apiMonthlyLimitRequired(profileID)
        }

        return try budgetLedger(for: profileID, configuredMonthlyLimit: monthlyLimit)
    }

    /// Variant for callers already holding UsageControlStore's run-authorization
    /// lock. It uses the validated settings passed by that locked operation,
    /// avoiding a recursive attempt to acquire the same non-recursive lock.
    private func budgetLedger(for profileID: UUID, configuredMonthlyLimit monthlyLimit: Double) throws -> BudgetLedger {
        let profile = try accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
        if profileID == AccountProfile.defaultID(for: .claude) { return legacyBudgetLedger }

        budgetLedgerLock.lock()
        let cached = profileBudgetLedgers[profileID]
        budgetLedgerLock.unlock()
        if let cached { return cached }

        let ledger = try BudgetLedger(rootURL: apiLedgerRoot(for: profileID), monthlyLimitUSD: monthlyLimit)
        budgetLedgerLock.lock()
        defer { budgetLedgerLock.unlock() }
        if let existing = profileBudgetLedgers[profileID] { return existing }
        profileBudgetLedgers[profileID] = ledger
        return ledger
    }

    private func apiLedgerRoot(for profileID: UUID) -> URL {
        store.rootURL
            .appendingPathComponent("api-ledgers", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
    }

    private func apiCostLedger(for profileID: UUID) throws -> APICostControlLedger {
        let profile = try accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
        budgetLedgerLock.lock()
        let cached = profileAPICostLedgers[profileID]
        budgetLedgerLock.unlock()
        if let cached { return cached }

        let root = store.rootURL
            .appendingPathComponent("api-cost-controls", isDirectory: true)
            .appendingPathComponent(profileID.uuidString.lowercased(), isDirectory: true)
        let ledger = try APICostControlLedger(rootURL: root)
        budgetLedgerLock.lock()
        defer { budgetLedgerLock.unlock() }
        if let existing = profileAPICostLedgers[profileID] { return existing }
        profileAPICostLedgers[profileID] = ledger
        return ledger
    }

    private func providerEnvironment(
        profile: AccountProfile,
        privateTemporaryDirectory: URL,
        apiKey: String? = nil
    ) throws -> [String: String] {
        var environment = RuntimeEnvironment.sanitized(
            base: baseEnvironment,
            provider: profile.provider,
            privateTemporaryDirectory: privateTemporaryDirectory,
            apiKey: apiKey
        )
        let overrides = try accountProfileStore.environmentOverrides(for: profile)
        let permittedKey = profile.provider == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        guard Set(overrides.keys).isSubset(of: [permittedKey]),
              overrides.values.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
            throw AccountProfileError.persistence("供應商環境變數覆寫不符合帳戶資料夾規則。")
        }
        environment.merge(overrides, uniquingKeysWith: { _, new in new })
        return environment
    }

    private func memoryScope(for session: SessionRecord) throws -> SharedMemoryScope {
        try SharedMemoryScope(repositoryPath: session.sourceRepositoryPath, snapshotCommit: session.snapshotCommit)
    }

    private func promptWithSharedMemory(
        _ prompt: String,
        session: SessionRecord,
        profile: AccountProfile
    ) throws -> (prompt: String, context: SharedMemoryContext?) {
        guard profile.allowsSharedMemory else { return (prompt, nil) }
        let scope = try memoryScope(for: session)
        let snapshot = try sharedMemoryStore.snapshot(scope: scope)
        guard !snapshot.notes.isEmpty || !snapshot.turns.isEmpty else { return (prompt, nil) }
        let context = try sharedMemoryStore.context(scope: scope, currentPrompt: prompt)
        return (context.prompt, context)
    }

    private func writeInteractiveMemoryContext(session: SessionRecord, profile: AccountProfile) throws -> URL? {
        guard profile.allowsSharedMemory else { return nil }
        let scope = try memoryScope(for: session)
        let snapshot = try sharedMemoryStore.snapshot(scope: scope)
        guard !snapshot.notes.isEmpty || !snapshot.turns.isEmpty else { return nil }
        let context = try sharedMemoryStore.context(
            scope: scope,
            currentPrompt: "This file contains prior user/assistant text and explicit notes for continuity only."
        )
        let filename = ".agentbridge-context-\(session.id.uuidString.lowercased())-\(UUID().uuidString.lowercased()).md"
        let workspaceURL = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        let directoryDescriptor = open(workspaceURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else {
            throw AgentBridgeError.sessionMismatch("無法安全開啟隔離工作區以提供共享記憶。")
        }
        defer { _ = close(directoryDescriptor) }
        let fileDescriptor = filename.withCString {
            openat(directoryDescriptor, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        }
        guard fileDescriptor >= 0 else {
            throw AgentBridgeError.persistence("無法安全建立互動記憶檔。")
        }
        var shouldRemove = true
        defer {
            _ = close(fileDescriptor)
            if shouldRemove { filename.withCString { _ = unlinkat(directoryDescriptor, $0, 0) } }
        }
        var metadata = stat()
        guard fstat(fileDescriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
              fchmod(fileDescriptor, mode_t(0o600)) == 0 else {
            throw AgentBridgeError.persistence("互動記憶檔不是安全的私有一般檔案。")
        }
        try Self.writeAll(Data(context.prompt.utf8), to: fileDescriptor)
        guard fsync(fileDescriptor) == 0 else {
            throw AgentBridgeError.persistence("無法同步互動記憶檔。")
        }
        shouldRemove = false
        return workspaceURL.appendingPathComponent(filename)
    }

    private func removeWorkspaceContextFile(_ url: URL, workspacePath: String) {
        let workspaceURL = URL(fileURLWithPath: workspacePath, isDirectory: true).standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL == workspaceURL,
              url.lastPathComponent.hasPrefix(".agentbridge-context-") else { return }
        let directoryDescriptor = open(workspaceURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryDescriptor >= 0 else { return }
        defer { _ = close(directoryDescriptor) }
        url.lastPathComponent.withCString { _ = unlinkat(directoryDescriptor, $0, 0) }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AgentBridgeError.persistence("無法寫入互動記憶檔。")
                }
                guard count > 0 else { throw AgentBridgeError.persistence("互動記憶檔寫入未完成。") }
                offset += count
            }
        }
    }

    private func loadSession(_ id: UUID) throws -> SessionRecord {
        guard let session = try store.session(id: id) else { throw AgentBridgeError.sessionNotFound(id) }
        return session
    }

    private func makePrivateTemporaryDirectory(label: String) throws -> URL {
        let url = store.rootURL.appendingPathComponent("tmp/\(label)", isDirectory: true)
        try AuditStore.createPrivateDirectory(url)
        return url
    }

    private func makeFreshPrivateTemporaryDirectory(label: String) throws -> URL {
        let root = store.rootURL.appendingPathComponent("tmp", isDirectory: true)
        try AuditStore.createPrivateDirectory(root)
        let url = root.appendingPathComponent("\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        guard mkdir(url.path, mode_t(0o700)) == 0 else {
            throw AgentBridgeError.persistence("無法建立全新的私有 usage TUI 工作資料夾。")
        }
        guard chmod(url.path, mode_t(0o700)) == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw AgentBridgeError.persistence("無法設定 usage TUI 工作資料夾權限。")
        }
        return url
    }

    private func safeProviderSessionID(_ value: String?) -> String? {
        guard let value, value.count <= 200, let uuid = UUID(uuidString: value) else { return nil }
        return uuid.uuidString.lowercased()
    }
}

private final class ProgressEmitter: @unchecked Sendable {
    private let sessionID: UUID
    private let store: AuditStore
    private let callback: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var previous: String?

    init(sessionID: UUID, store: AuditStore, callback: (@Sendable (String) -> Void)?) {
        self.sessionID = sessionID
        self.store = store
        self.callback = callback
    }

    func emit(_ message: String) {
        lock.lock()
        let isNew = previous != message
        previous = message
        lock.unlock()
        guard isNew else { return }
        try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.progress", message: message))
        callback?(message)
    }
}
