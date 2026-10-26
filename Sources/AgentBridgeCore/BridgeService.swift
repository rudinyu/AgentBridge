import Foundation

public final class BridgeService: @unchecked Sendable {
    public let store: AuditStore
    public let workspaceManager: WorkspaceManager
    private let runner: SafeProcessRunner
    private let adapter: ProviderAdapter
    private let baseEnvironment: [String: String]
    private let budgetLedger: BudgetLedger
    private let accountProfileStore: AccountProfileStore
    private let sharedMemoryStore: SharedMemoryStore

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
        self.budgetLedger = try BudgetLedger(rootURL: store.rootURL, monthlyLimitUSD: monthlyAPILimitUSD)
        self.accountProfileStore = try AccountProfileStore(rootURL: store.rootURL)
        self.sharedMemoryStore = try SharedMemoryStore(rootURL: store.rootURL.appendingPathComponent("shared-memory", isDirectory: true))
    }

    public func settings() throws -> BridgeSettings { try store.loadSettings() }
    public func saveSettings(_ settings: BridgeSettings) throws { try store.saveSettings(settings) }
    public func sessions() throws -> [SessionRecord] { try store.loadSessions() }
    public func events(sessionID: UUID) throws -> [AuditEvent] { try store.events(sessionID: sessionID) }
    public func budgetSnapshot(now: Date = Date()) throws -> BudgetSnapshot { try budgetLedger.snapshot(now: now) }
    public func cancel(sessionID: UUID) throws { try store.requestCancellation(for: sessionID) }

    public func accountProfiles(provider: AgentProvider) throws -> [AccountProfile] {
        try accountProfileStore.profiles(provider: provider)
    }

    public func selectedAccountProfile(provider: AgentProvider) throws -> AccountProfile {
        try accountProfileStore.selected(provider: provider)
    }

    public func createAccountProfile(name: String, provider: AgentProvider, allowsSharedMemory: Bool = false) throws -> AccountProfile {
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
        if let apiRequest {
            reservation = try budgetLedger.reserve(
                sessionID: sessionID,
                requestedUSD: apiRequest.requestedBudgetUSD,
                explicitlyAuthorized: apiRequest.explicitlyAuthorized
            )
        } else {
            let assessment = try await checkAuthentication(profile: profile, executable: executable)
            guard assessment.confirmedSubscription else {
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "auth.refused", message: "未確認訂閱登入；\(assessment.message)"))
                throw AgentBridgeError.unauthenticated(session.provider, assessment.message)
            }
        }

        _ = store.consumeCancellationRequest(for: sessionID)
        var activeSession = session
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

        let emitter = ProgressEmitter(sessionID: sessionID, store: store, callback: onProgress)
        var reservationReconciled = false
        do {
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
                try budgetLedger.reconcile(reservationID: reservation.id, actualUSD: output.actualCostUSD)
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
            if let reservation, !reservationReconciled { try? budgetLedger.reconcile(reservationID: reservation.id, actualUSD: nil) }
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
