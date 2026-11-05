import Darwin
import Foundation

extension BridgeService {
    public func checkAuthentication(provider: AgentProvider, profileID: UUID? = nil) async throws -> AuthAssessment {
        let profile = try profileID.map(accountProfile(id:)) ?? accountProfileStore.selected(provider: provider)
        guard profile.provider == provider else {
            throw AccountProfileError.providerMismatch(profile.id, provider)
        }
        if provider == .local {
            do {
                let localSettings = try store.loadSettings().localModel
                _ = try await localModels(settings: localSettings)
                return AuthAssessment(
                    provider: .local,
                    confirmedSubscription: false,
                    message: "本機模型伺服器可連線；此狀態不是訂閱或雲端帳戶驗證。",
                    accountLabel: localSettings.model.isEmpty ? nil : localSettings.model,
                    planName: nil,
                    localEndpointReachable: true
                )
            } catch {
                return AuthAssessment(
                    provider: .local,
                    confirmedSubscription: false,
                    message: OutputRedactor.redact(error.localizedDescription),
                    accountLabel: nil,
                    planName: nil,
                    localEndpointReachable: false
                )
            }
        }
        let settings = try store.loadSettings()
        let executable = try RuntimeEnvironment.resolveExecutable(provider: provider, configuredPath: settings.binaryPath(for: provider))
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
        guard provider != .local else {
            throw AgentBridgeError.sessionMismatch("本機模型沒有訂閱用量終端；請使用本機模型連線檢查。")
        }
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

    func checkAuthentication(profile: AccountProfile, executable: URL) async throws -> AuthAssessment {
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
        onProgress: (@Sendable (String) -> Void)? = nil,
        extensionIDs: [String]? = nil,
        expectedExtensionFingerprint: String? = nil,
        allowBoundProfileWithoutGlobalSelection: Bool = false,
        allowSharedMemoryForRun: Bool = true,
        maximumMCPToolCallsPerServer: Int? = nil
    ) async throws -> ProviderOutput {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("請輸入要交給助理的內容。")
        }
        guard prompt.utf8.count <= 256_000 else {
            throw AgentBridgeError.invalidInput("提示內容最多 256 KiB。")
        }
        if let maximumMCPToolCallsPerServer, !(1...128).contains(maximumMCPToolCallsPerServer) {
            throw AgentBridgeError.invalidInput("The per-run MCP tool-call cap must be between 1 and 128.")
        }
        let initialSession = try loadSession(sessionID)
        if initialSession.provider == .local {
            guard apiRequest == nil else {
                throw AgentBridgeError.sessionMismatch("本機模型不使用 Claude API 預算或 API 金鑰。")
            }
            guard extensionIDs?.isEmpty ?? true,
                  expectedExtensionFingerprint == nil,
                  maximumMCPToolCallsPerServer == nil else {
                throw AgentBridgeError.sessionMismatch("本機模型目前不支援 Skills、MCP 或其他專案工具；本次尚未啟動。")
            }
        }
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        let settings = try store.loadSettings()
        let session = try loadSession(sessionID)
        guard session.provider == .codex || session.provider == .claude || session.provider == .local,
              session.policy.accessMode == .readOnly,
              session.policy.workspaceReadOnly else {
            throw AgentBridgeError.sessionMismatch("工作階段不是唯讀模式。")
        }
        let profile = try requireBoundProfile(for: session, allowUnselected: allowBoundProfileWithoutGlobalSelection)
        if session.provider == .local {
            return try await runLocalReadOnly(
                session: session,
                profile: profile,
                settings: settings.localModel,
                prompt: prompt,
                cancellation: cancellation,
                onProgress: onProgress,
                allowSharedMemory: allowSharedMemoryForRun
            )
        }
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
        let activeSpendLedger = apiMode ? try spendLedger(for: profile.id) : nil

        try await workspaceManager.validateWorkspace(for: session, accessMode: .readOnly)
        let executable = try RuntimeEnvironment.resolveExecutable(provider: session.provider, configuredPath: settings.binaryPath(for: session.provider))
        let temp = try makePrivateTemporaryDirectory(label: "run-\(sessionID.uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let extensionInvocation = try activeExtensionRuntimeStore.invocation(
            projectID: extensionProjectID(for: session),
            provider: session.provider,
            profileID: profile.id,
            workspacePath: session.workspacePath,
            selectedExtensionIDs: extensionIDs
        )
        if let expectedExtensionFingerprint {
            guard ActiveExtensionValidation.isSHA256(expectedExtensionFingerprint),
                  extensionInvocation.fingerprint == expectedExtensionFingerprint.lowercased() else {
                throw ActiveExtensionRuntimeError.reviewDigestMismatch
            }
        }
        for mcpServer in extensionInvocation.mcpServers {
            guard try MCPExecutableValidation.digestExecutable(at: mcpServer.executablePath) == mcpServer.executableDigest else {
                throw ActiveExtensionRuntimeError.invalidConfiguration("The MCP executable changed after it was imported and reviewed.")
            }
        }
        let mcpControlPlane = try makeMCPRunDirectoryLease(for: extensionInvocation, session: session, providerTemporaryDirectory: temp)
        defer { mcpControlPlane?.remove() }
        let (sharedPrompt, memoryContext, compression) = try promptWithSharedMemory(
            prompt,
            session: session,
            profile: profile,
            includeMemory: allowSharedMemoryForRun
        )
        let providerPrompt = extensionInvocation.skillPrompt + sharedPrompt
        guard providerPrompt.utf8.count <= 512_000 else {
            throw AgentBridgeError.invalidInput("The prompt plus approved Skill instructions exceed the 512 KiB run limit.")
        }
        let apiKey = apiRequest?.apiKey
        let environment = try providerEnvironment(profile: profile, privateTemporaryDirectory: temp, apiKey: apiKey)
        var reservation: APISpendReservation?
        if let apiRequest {
            guard let activeSpendLedger else { throw UsageControlError.apiMonthlyLimitRequired(profile.id) }
            do {
                let controls = try usageControlStore.settings(provider: .claude, accountProfileID: profile.id)
                reservation = try activeSpendLedger.reserve(
                    sessionID: sessionID,
                    requestedUSD: apiRequest.requestedBudgetUSD,
                    explicitlyAuthorized: apiRequest.explicitlyAuthorized,
                    limits: apiSpendLimits(for: profile.id, controls: controls)
                )
            } catch {
                try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "usage.run.blocked", message: OutputRedactor.redact(error.localizedDescription)))
                throw error
            }
        } else {
            let assessment = try await checkAuthentication(profile: profile, executable: executable)
            guard assessment.confirmedSubscription else {
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "auth.refused", message: "未確認訂閱登入；\(assessment.message)"))
                throw AgentBridgeError.unauthenticated(session.provider, assessment.message)
            }
        }

        var activeSession = session
        // App-owned compressed context is authoritative for every managed
        // read-only call; do not revive older opaque vendor history on failure.
        activeSession.providerSessionID = nil
        let emitter = ProgressEmitter(sessionID: sessionID, store: store, callback: onProgress)
        var taskID: UUID?
        var mcpServerCommands: [MCPServerCommandConfiguration] = []
        do {
            try activeExtensionRuntimeStore.validateAndBind(sessionID: sessionID, invocation: extensionInvocation)
            mcpServerCommands = try prepareMCPServerCommands(
                invocation: extensionInvocation,
                session: session,
                ticketDirectory: mcpControlPlane?.directoryURL,
                maximumToolCallsPerServer: maximumMCPToolCallsPerServer
            )
            _ = store.consumeCancellationRequest(for: sessionID)
            let startedTaskID = try beginTrackedRun(sessionID: sessionID, summary: "Read-only provider run started.")
            taskID = startedTaskID
            activeSession.status = .running
            activeSession.updatedAt = Date()
            try store.saveSession(activeSession)
            // Revalidate after publishing `.running`. A revoke before this
            // point fails the live grant check; a revoke after it can persist
            // a cancellation request that the provider/proxy will observe.
            // Do not consume cancellation requests after this boundary.
            try activeExtensionRuntimeStore.validateCurrentInvocation(extensionInvocation)
            if let reservation {
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "api.run.authorized", message: "已明確授權 Claude API 執行；單次上限 US$\(String(format: "%.2f", apiRequest?.requestedBudgetUSD ?? 0))，保留預算 US$\(String(format: "%.2f", reservation.reservedUSD))。實際費用仍以供應商帳單為準。"))
            } else {
                let extensionText = extensionInvocation.skills.isEmpty && extensionInvocation.mcpServers.isEmpty
                    ? "未使用已啟用的 Skills 或 MCP 工具。"
                    : "Extension fingerprint \(extensionInvocation.fingerprint.prefix(12)); Skills \(extensionInvocation.skills.count), MCP servers \(extensionInvocation.mcpServers.count)."
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.started", message: "以訂閱登入開始唯讀執行。\(extensionText) 每回合使用 AgentBridge 逐字稿與共享記憶組成新上下文，不續接 CLI 原生歷史。提示內容不會寫入稽核檔。"))
            }
            try? store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "context.compressed",
                message: Self.contextCompressionAuditSummary(compression.report)
            ))
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
                stateless: true,
                mcpServerCommands: mcpServerCommands,
                onProgress: { [weak self] message in
                    emitter.emit(message)
                    _ = try? self?.parallelTaskBoard.updateProgress(taskID: startedTaskID, summary: OutputRedactor.redact(message))
                },
                cancellation: cancellation
            )
            try recordMCPProxyReceipts(mcpServerCommands, sessionID: sessionID, failOnIncomplete: true)
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
                try activeSpendLedger?.reconcile(reservationID: reservation.id, actualUSD: output.actualCostUSD)
                if let actual = output.actualCostUSD, actual > reservation.requestedUSD {
                    try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "api.budget.exceeded", message: "Claude 回報費用高於單次上限；本次輸出不會標示為成功。費用以供應商帳單為準。"))
                    throw AgentBridgeError.providerFailed(.claude, "供應商回報費用超過單次上限。")
                }
            }
            activeSession.providerSessionID = nil
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
            if let taskID {
                try? finishTrackedRun(taskID: taskID, status: .completed, summary: "Provider CLI reported a completed response.")
            }
            if allowSharedMemoryForRun, profile.allowsSharedMemory {
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
            try? recordMCPProxyReceipts(mcpServerCommands, sessionID: sessionID, failOnIncomplete: false)
            activeSession.status = (error as? AgentBridgeError) == .processCancelled ? .cancelled : .failed
            activeSession.updatedAt = Date()
            try? store.saveSession(activeSession)
            let kind = activeSession.status == .cancelled ? "run.cancelled" : (reservation == nil ? "run.failed" : "api.run.failed")
            try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: kind, message: OutputRedactor.redact(error.localizedDescription)))
            if let taskID {
                try? finishTrackedRun(
                    taskID: taskID,
                    status: activeSession.status == .cancelled ? .cancelled : .failed,
                    summary: OutputRedactor.redact(error.localizedDescription)
                )
            }
            throw error
        }
    }

    private func runLocalReadOnly(
        session: SessionRecord,
        profile: AccountProfile,
        settings: LocalModelSettings,
        prompt: String,
        cancellation: CancellationFlag,
        onProgress: (@Sendable (String) -> Void)?,
        allowSharedMemory: Bool
    ) async throws -> ProviderOutput {
        guard profile.provider == .local else {
            throw AccountProfileError.providerMismatch(profile.id, .local)
        }
        try LocalModelClient.validateSettings(settings)
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("請先在本機模型設定中選擇一個模型。")
        }
        try await workspaceManager.validateWorkspace(for: session, accessMode: .readOnly)
        let (providerPrompt, memoryContext, compression) = try promptWithSharedMemory(
            prompt,
            session: session,
            profile: profile,
            includeMemory: allowSharedMemory,
            localSettings: settings
        )
        guard providerPrompt.utf8.count <= LocalModelClient.maximumResponseBytes else {
            throw AgentBridgeError.invalidInput("本機模型提示超過 2 MiB 上限；請縮短目前要求或減少固定背景內容。")
        }

        _ = store.consumeCancellationRequest(for: session.id)
        var activeSession = session
        let emitter = ProgressEmitter(sessionID: session.id, store: store, callback: onProgress)
        do {
            try authorizeLocalModelRun(runID: session.id, profile: profile, settings: settings)
            activeSession.status = .running
            activeSession.providerSessionID = nil
            activeSession.updatedAt = Date()
            try store.saveSession(activeSession)
            try store.appendEvent(AuditEvent(
                sessionID: session.id,
                kind: "local.context.prepared",
                message: Self.contextCompressionAuditSummary(compression.report)
            ))
            if let memoryContext {
                try store.appendEvent(AuditEvent(
                    sessionID: session.id,
                    kind: "memory.loaded",
                    message: "已載入共享記憶 revision \(memoryContext.revision)，\(Self.contextCompressionAuditSummary(compression.report))"
                ))
            }
            let response = try await localModelClient.generate(
                settings: settings,
                prompt: providerPrompt,
                cancellationRequestURL: store.cancellationRequestURL(for: session.id),
                cancellation: cancellation,
                onProgress: { emitter.emit($0) }
            )
            let output = ProviderOutput(text: response.text, providerSessionID: nil)
            activeSession.status = .completed
            activeSession.providerSessionID = nil
            activeSession.updatedAt = Date()
            try store.saveSession(activeSession)
            try store.appendEvent(AuditEvent(
                sessionID: session.id,
                kind: "run.output",
                message: String(output.text.prefix(200_000))
            ))
            let reportedTokens = "provider_input_tokens=\(response.usage.inputTokens.map(String.init) ?? "unavailable"); provider_output_tokens=\(response.usage.outputTokens.map(String.init) ?? "unavailable"); estimated_input_tokens_from_bytes=\(response.usage.estimatedInputTokens) (estimate, not exact tokenizer output)."
            try store.appendEvent(AuditEvent(
                sessionID: session.id,
                kind: "local.run.completed",
                message: "Local-only response completed. \(reportedTokens) \(Self.contextCompressionAuditSummary(compression.report))"
            ))
            if allowSharedMemory && profile.allowsSharedMemory {
                do {
                    try sharedMemoryStore.appendTurn(
                        scope: memoryScope(for: session),
                        provider: .local,
                        userText: prompt,
                        assistantText: output.text
                    )
                } catch {
                    try? store.appendEvent(AuditEvent(
                        sessionID: session.id,
                        kind: "memory.save.failed",
                        message: "本機模型回覆完成，但共享記憶已達安全儲存上限或無法保存；既有記憶未被改寫。"
                    ))
                }
            }
            return output
        } catch {
            activeSession.status = (error as? AgentBridgeError) == .processCancelled ? .cancelled : .failed
            activeSession.providerSessionID = nil
            activeSession.updatedAt = Date()
            try? store.saveSession(activeSession)
            try? store.appendEvent(AuditEvent(
                sessionID: session.id,
                kind: activeSession.status == .cancelled ? "local.run.cancelled" : "local.run.failed",
                message: OutputRedactor.redact(error.localizedDescription)
            ))
            throw error
        }
    }

    static func contextCompressionAuditSummary(_ report: ContextCompressionReport) -> String {
        let estimatedTokens = max(1, (report.sentBytes + 1) / 2)
        return "\(report.readableLabel) Original context: \(report.originalInputBytes) UTF-8 bytes; sent context: \(report.sentBytes) UTF-8 bytes; estimated input tokens from bytes: \(estimatedTokens) (not exact tokenizer output); excerpt sources: \(report.excerptSourceIDs.count); omitted turns: \(report.omittedTurnCount)."
    }

    @discardableResult
    public func runChanges(
        sessionID: UUID,
        prompt: String,
        planID: UUID,
        reviewedDigest: String,
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: (@Sendable (String) -> Void)? = nil,
        extensionIDs: [String]? = nil,
        expectedExtensionFingerprint: String? = nil,
        allowBoundProfileWithoutGlobalSelection: Bool = false,
        allowSharedMemoryForRun: Bool = true,
        maximumMCPToolCallsPerServer: Int? = nil
    ) async throws -> ProviderOutput {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw AgentBridgeError.invalidInput("請輸入要交給助理的內容。") }
        guard trimmedPrompt.utf8.count <= 256_000 else { throw AgentBridgeError.invalidInput("提示內容最多 256 KiB。") }
        if let maximumMCPToolCallsPerServer, !(1...128).contains(maximumMCPToolCallsPerServer) {
            throw AgentBridgeError.invalidInput("The per-run MCP tool-call cap must be between 1 and 128.")
        }

        let initialSession = try loadSession(sessionID)
        guard initialSession.provider != .local else {
            throw AgentBridgeError.sessionMismatch("本機模型目前只支援唯讀專案對話；尚未執行變更。")
        }

        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        let settings = try store.loadSettings()
        guard settings.usageMode == .subscription else {
            throw AgentBridgeError.sessionMismatch("隔離變更只支援已確認的訂閱登入；不會啟動 Claude API 付費操作。")
        }
        let session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        guard let plan = session.changePlan,
              plan.sessionID == sessionID,
              plan.id == planID,
              plan.reviewDigest == reviewedDigest.lowercased(),
              session.approvedChangePlanDigest == plan.reviewDigest else {
            try? store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "change.run.blocked",
                message: "未提供目前已核准的工作計畫識別碼與檢視摘要；檔案尚未寫入。"
            ))
            throw AgentBridgeError.changePlanRequired
        }
        let profile = try requireBoundProfile(for: session, allowUnselected: allowBoundProfileWithoutGlobalSelection)
        try authorizeManagedRun(session: session, profile: profile, usageMode: .subscription)
        try await workspaceManager.validateWorkspace(for: session, accessMode: .isolatedChanges)
        let executable = try RuntimeEnvironment.resolveExecutable(
            provider: session.provider,
            configuredPath: settings.binaryPath(for: session.provider)
        )
        let assessment = try await checkAuthentication(profile: profile, executable: executable)
        guard assessment.confirmedSubscription else {
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "auth.refused",
                message: "未確認 \(session.provider.rawValue) 訂閱登入；\(assessment.message)"
            ))
            throw AgentBridgeError.unauthenticated(session.provider, assessment.message)
        }

        let temp = try makePrivateTemporaryDirectory(label: "change-\(sessionID.uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let environment = try providerEnvironment(profile: profile, privateTemporaryDirectory: temp)
        let extensionInvocation = try activeExtensionRuntimeStore.invocation(
            projectID: extensionProjectID(for: session),
            provider: session.provider,
            profileID: profile.id,
            workspacePath: session.workspacePath,
            selectedExtensionIDs: extensionIDs
        )
        if let expectedExtensionFingerprint {
            guard ActiveExtensionValidation.isSHA256(expectedExtensionFingerprint),
                  extensionInvocation.fingerprint == expectedExtensionFingerprint.lowercased() else {
                throw ActiveExtensionRuntimeError.reviewDigestMismatch
            }
        }
        for mcpServer in extensionInvocation.mcpServers {
            guard try MCPExecutableValidation.digestExecutable(at: mcpServer.executablePath) == mcpServer.executableDigest else {
                throw ActiveExtensionRuntimeError.invalidConfiguration("The MCP executable changed after it was imported and reviewed.")
            }
        }
        let mcpControlPlane = try makeMCPRunDirectoryLease(for: extensionInvocation, session: session, providerTemporaryDirectory: temp)
        defer { mcpControlPlane?.remove() }
        let (promptWithMemory, memoryContext) = allowSharedMemoryForRun
            ? try legacyPromptWithSharedMemory(trimmedPrompt, session: session, profile: profile)
            : (trimmedPrompt, nil)
        let planText = ([
            "APPROVED CHANGE PLAN",
            "Title: \(plan.title)",
            "Summary: \(plan.summary)",
            "Steps:",
        ] + plan.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }).joined(separator: "\n")
        let providerPrompt = """
        \(extensionInvocation.skillPrompt)
        \(extensionInvocation.skillPrompt.isEmpty ? "" : "\n")
        \(planText)

        This plan is the user's authorization boundary. Make only the changes described by the approved plan in this isolated workspace. If the request requires work outside the plan, stop and explain what needs a new reviewed plan. Do not commit, push, merge, or change the source repository.

        USER REQUEST
        \(promptWithMemory)
        """

        var activeSession = session
        let emitter = ProgressEmitter(sessionID: sessionID, store: store, callback: onProgress)
        var taskID: UUID?
        var mcpServerCommands: [MCPServerCommandConfiguration] = []
        _ = store.consumeCancellationRequest(for: sessionID)
        do {
            try activeExtensionRuntimeStore.validateAndBind(sessionID: sessionID, invocation: extensionInvocation)
            mcpServerCommands = try prepareMCPServerCommands(
                invocation: extensionInvocation,
                session: session,
                ticketDirectory: mcpControlPlane?.directoryURL,
                maximumToolCallsPerServer: maximumMCPToolCallsPerServer
            )
            let startedTaskID = try beginTrackedRun(
                sessionID: sessionID,
                summary: "Approved change plan \(plan.reviewDigest.prefix(12)) is running.",
                approvedChange: true
            )
            taskID = startedTaskID
            activeSession.status = .running
            activeSession.approvedChangePlanDigest = nil
            activeSession.lastChangeRunAt = Date()
            activeSession.verificationPassed = nil
            activeSession.verificationDiffDigest = nil
            activeSession.verificationCompletedAt = nil
            activeSession.changesAcceptedAt = nil
            activeSession.updatedAt = Date()
            try store.saveSession(activeSession)
            // Match the read-only launch boundary: once `.running` is visible,
            // revokes either fail this exact live snapshot check or leave a
            // cancellation marker for the provider/proxy to observe.
            try activeExtensionRuntimeStore.validateCurrentInvocation(extensionInvocation)
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "change.run.started",
                message: "已在隔離工作區開始 \(session.provider.rawValue) 變更執行；計畫摘要雜湊 \(plan.reviewDigest)。不會寫入來源儲存庫。"
            ))
            if let memoryContext {
                try? store.appendEvent(AuditEvent(
                    sessionID: sessionID,
                    kind: "memory.loaded",
                    message: "已載入共享記憶 revision \(memoryContext.revision)，包含 \(memoryContext.includedTurnCount) 個先前回合\(memoryContext.wasTruncated ? "（內容已截短）" : "")."
                ))
            }
            let (processResult, parsedOutput) = try await adapter.runChanges(
                provider: session.provider,
                session: session,
                prompt: providerPrompt,
                executableURL: executable,
                environment: environment,
                cancellationRequestURL: store.cancellationRequestURL(for: sessionID),
                mcpServerCommands: mcpServerCommands,
                onProgress: { [weak self] message in
                    emitter.emit(message)
                    _ = try? self?.parallelTaskBoard.updateProgress(taskID: startedTaskID, summary: OutputRedactor.redact(message))
                },
                cancellation: cancellation
            )
            try recordMCPProxyReceipts(mcpServerCommands, sessionID: sessionID, failOnIncomplete: true)
            let output = ProviderOutput(
                text: parsedOutput.text,
                providerSessionID: parsedOutput.providerSessionID,
                actualCostUSD: parsedOutput.actualCostUSD
            )
            activeSession.providerSessionID = safeProviderSessionID(output.providerSessionID)
            activeSession.lastChangeRunAt = Date()
            activeSession.status = .completed
            activeSession.updatedAt = Date()
            try store.saveSession(activeSession)
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "change.run.completed",
                message: processResult.outputWasTruncated ? "隔離變更執行成功；部分非必要 CLI 輸出超過緩衝上限。" : "隔離變更執行完成；使用者可檢視檔案差異。"
            ))
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.output", message: String(output.text.prefix(200_000))))
            let currentChangeDiff = try await workspaceManager.diff(for: activeSession)
            if taskID != nil {
                try? finishTrackedRun(
                    taskID: startedTaskID,
                    status: .completed,
                    summary: "Provider CLI reported completion; isolated diff is ready for review.",
                    reference: try? ParallelTaskReference(kind: .diff, value: "sha256:\(currentChangeDiff.digest)")
                )
            }
            if allowSharedMemoryForRun, profile.allowsSharedMemory {
                do {
                    try sharedMemoryStore.appendTurn(
                        scope: memoryScope(for: session),
                        provider: session.provider,
                        userText: trimmedPrompt,
                        assistantText: output.text
                    )
                } catch {
                    try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "memory.save.failed", message: "本次成功回應未能寫入共享記憶。"))
                }
            }
            return output
        } catch {
            try? recordMCPProxyReceipts(mcpServerCommands, sessionID: sessionID, failOnIncomplete: false)
            activeSession.status = (error as? AgentBridgeError) == .processCancelled ? .cancelled : .failed
            activeSession.updatedAt = Date()
            try? store.saveSession(activeSession)
            let kind = activeSession.status == .cancelled ? "change.run.cancelled" : "change.run.failed"
            try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: kind, message: OutputRedactor.redact(error.localizedDescription)))
            if let taskID {
                try? finishTrackedRun(
                    taskID: taskID,
                    status: activeSession.status == .cancelled ? .cancelled : .failed,
                    summary: OutputRedactor.redact(error.localizedDescription)
                )
            }
            throw error
        }
    }

    @discardableResult
    public func runVerification(
        sessionID: UUID,
        customExecutableURL: URL? = nil,
        arguments: [String] = [],
        customCommandApproved: Bool = false,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> VerificationResult {
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        try await workspaceManager.validateWorkspace(for: session, accessMode: .isolatedChanges)
        let diffBeforeVerification = try await workspaceManager.diff(for: session)

        let workingDirectory = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        let executableURL: URL
        let commandArguments: [String]
        if let customExecutableURL {
            guard customCommandApproved else {
                throw AgentBridgeError.verificationCommandRejected("自訂程式必須先由使用者檢視並明確核准。")
            }
            let candidate = customExecutableURL.standardizedFileURL
            guard customExecutableURL.isFileURL,
                  candidate.path.hasPrefix("/"),
                  !candidate.path.contains("\0"),
                  !candidate.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  FileManager.default.isExecutableFile(atPath: candidate.path) else {
                throw AgentBridgeError.verificationCommandRejected("請選擇可執行的絕對路徑。")
            }
            guard arguments.count <= 128,
                  arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 8_192 }),
                  arguments.reduce(0, { $0 + $1.utf8.count }) <= 64 * 1_024 else {
                throw AgentBridgeError.verificationCommandRejected("自訂參數超過大小限制或包含無效字元。")
            }
            executableURL = candidate
            commandArguments = arguments
        } else {
            guard arguments.isEmpty, !customCommandApproved else {
                throw AgentBridgeError.verificationCommandRejected("預設驗證不接受額外參數或自訂指令核准旗標。")
            }
            let script = workingDirectory.appendingPathComponent(".codex/ci.sh")
            var metadata = stat()
            guard lstat(script.path, &metadata) == 0 else {
                if errno != ENOENT { throw AgentBridgeError.verificationCommandRejected("無法安全檢查 .codex/ci.sh。") }
                let result = VerificationResult(
                    command: nil,
                    exitCode: nil,
                    durationSeconds: 0,
                    standardOutput: "",
                    standardError: "",
                    wasCancelled: false,
                    timedOut: false,
                    skippedReason: "隔離工作區沒有可執行的 .codex/ci.sh。"
                )
                session.verificationPassed = nil
                session.verificationDiffDigest = nil
                session.changesAcceptedAt = nil
                session.verificationCompletedAt = Date()
                session.updatedAt = Date()
                try store.saveSession(session)
                try recordUnlaunchedTask(sessionID: sessionID, summary: result.skippedReason!)
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "verification.skipped", message: result.skippedReason!))
                return result
            }
            guard (metadata.st_mode & S_IFMT) == S_IFREG,
                  FileManager.default.isExecutableFile(atPath: script.path) else {
                throw AgentBridgeError.verificationCommandRejected(".codex/ci.sh 必須是一般且可執行的檔案。")
            }
            executableURL = script
            commandArguments = []
        }

        let command = VerificationCommand(
            executablePath: executableURL.path,
            arguments: commandArguments,
            workingDirectoryPath: workingDirectory.path
        )
        let temp = try makeFreshPrivateTemporaryDirectory(label: "verify-\(sessionID.uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let environment = [
            "HOME": temp.path,
            "TMPDIR": temp.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "TERM": "dumb",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0"
        ]
        let start = DispatchTime.now().uptimeNanoseconds
        let verificationTaskID = try beginTrackedRun(
            sessionID: sessionID,
            summary: "User started isolated verification."
        )
        let previousStatus: SessionStatus = session.status == .running ? .failed : session.status
        if session.status == .running {
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "verification.recovered_stale_session",
                message: "已取得工作階段執行鎖；先前的執行狀態沒有作用中的程序，已記錄為失敗後開始驗證。"
            ))
        }
        _ = store.consumeCancellationRequest(for: sessionID)
        session.verificationPassed = nil
        session.verificationDiffDigest = nil
        session.changesAcceptedAt = nil
        session.status = .running
        session.updatedAt = Date()
        try store.saveSession(session)
        try store.appendEvent(AuditEvent(
            sessionID: sessionID,
            kind: "verification.started",
            message: "執行 \(OutputRedactor.redact(executableURL.path)) \(OutputRedactor.redact(argumentsForAudit(commandArguments)))，工作目錄 \(workingDirectory.path)。"
        ))

        do {
            let processResult = try await runner.run(ProcessSpec(
                executableURL: executableURL,
                arguments: commandArguments,
                environment: environment,
                workingDirectoryURL: workingDirectory,
                standardInput: Data(),
                timeout: 3_600,
                outputLimit: 2 * 1_024 * 1_024,
                cancellationRequestURL: store.cancellationRequestURL(for: sessionID)
            ), cancellation: cancellation)
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            let stdout = String(decoding: processResult.standardOutput, as: UTF8.self)
            let stderr = String(decoding: processResult.standardError, as: UTF8.self)
            let diffAfterVerification = try await workspaceManager.diff(for: session)
            let result = VerificationResult(
                command: command,
                exitCode: processResult.exitCode,
                durationSeconds: duration,
                standardOutput: stdout,
                standardError: stderr,
                wasCancelled: processResult.wasCancelled,
                timedOut: processResult.timedOut,
                workspaceChangedDuringVerification: diffAfterVerification.digest != diffBeforeVerification.digest
            )
            try? finishTrackedRun(
                taskID: verificationTaskID,
                status: result.wasCancelled ? .cancelled : (result.succeeded ? .completed : .failed),
                summary: "Verification exit code \(processResult.exitCode); duration \(String(format: "%.3f", duration)) seconds; succeeded=\(result.succeeded).",
                reference: try? ParallelTaskReference(
                    kind: .verification,
                    value: "exit=\(processResult.exitCode); duration=\(String(format: "%.3f", duration))s; succeeded=\(result.succeeded)"
                )
            )
            session.status = previousStatus
            session.verificationPassed = result.succeeded
            session.verificationDiffDigest = result.succeeded ? diffBeforeVerification.digest : nil
            session.verificationCompletedAt = Date()
            if !result.succeeded { session.changesAcceptedAt = nil }
            session.updatedAt = Date()
            try store.saveSession(session)
            let kind = result.wasCancelled ? "verification.cancelled" : (result.succeeded ? "verification.completed" : "verification.failed")
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: kind,
                message: "結束代碼 \(processResult.exitCode)，耗時 \(String(format: "%.3f", duration)) 秒，標準輸出 \(result.standardOutput.utf8.count) 位元組，錯誤輸出 \(result.standardError.utf8.count) 位元組。"
            ))
            return result
        } catch {
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            let wasCancelled = (error as? AgentBridgeError) == .processCancelled
            try? finishTrackedRun(
                taskID: verificationTaskID,
                status: wasCancelled ? .cancelled : .failed,
                summary: "Verification did not complete after \(String(format: "%.3f", duration)) seconds: \(OutputRedactor.redact(error.localizedDescription))"
            )
            session.status = previousStatus
            session.verificationPassed = false
            session.verificationDiffDigest = nil
            session.verificationCompletedAt = Date()
            session.changesAcceptedAt = nil
            session.updatedAt = Date()
            try? store.saveSession(session)
            try? store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: wasCancelled ? "verification.cancelled" : "verification.failed",
                message: "驗證未完成；耗時 \(String(format: "%.3f", duration)) 秒。\(OutputRedactor.redact(error.localizedDescription))"
            ))
            if wasCancelled {
                return VerificationResult(
                    command: command,
                    exitCode: nil,
                    durationSeconds: duration,
                    standardOutput: "",
                    standardError: "",
                    wasCancelled: true,
                    timedOut: false
                )
            }
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
        let initialSession = try loadSession(sessionID)
        guard initialSession.provider != .local else {
            throw AgentBridgeError.sessionMismatch("本機模型不支援 Terminal 或互動控制；尚未啟動程序。")
        }
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

    func requireBoundSelectedProfile(for session: SessionRecord) throws -> AccountProfile {
        try requireBoundProfile(for: session, allowUnselected: false)
    }

    func requireBoundProfile(for session: SessionRecord, allowUnselected: Bool) throws -> AccountProfile {
        let boundID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        if !allowUnselected {
            let selected = try accountProfileStore.selected(provider: session.provider)
            guard selected.id == boundID else {
                throw AgentBridgeError.sessionMismatch("目前選取的帳戶與工作階段綁定帳戶不同；請建立新的隔離工作區後再執行。")
            }
        }
        let profile = try accountProfile(id: boundID)
        guard profile.provider == session.provider else {
            throw AgentBridgeError.sessionMismatch("工作階段綁定了不同供應商的帳戶。")
        }
        return profile
    }

    func extensionProjectID(for session: SessionRecord) throws -> String {
        let repository = try ProjectMemoryRepositoryScope(repositoryPath: session.sourceRepositoryPath)
        return "project-\(repository.key.prefix(48))"
    }

    private func argumentsForAudit(_ arguments: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed]),
              let value = String(data: data, encoding: .utf8) else { return "[]" }
        return OutputRedactor.redact(value)
    }

    func providerEnvironment(
        profile: AccountProfile,
        privateTemporaryDirectory: URL,
        apiKey: String? = nil
    ) throws -> [String: String] {
        guard profile.provider != .local else {
            throw AgentBridgeError.sessionMismatch("本機模型不會讀取 Codex 或 Claude CLI 環境與登入資料夾。")
        }
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

    func memoryScope(for session: SessionRecord) throws -> SharedMemoryScope {
        try SharedMemoryScope(repositoryPath: session.sourceRepositoryPath, snapshotCommit: session.snapshotCommit)
    }

    private func beginTrackedRun(
        sessionID: UUID,
        summary: String,
        approvedChange: Bool = false
    ) throws -> UUID {
        let task = try parallelTaskBoard.create(sessionID: sessionID, progressSummary: "Queued; provider process has not started.")
        if approvedChange {
            try parallelTaskBoard.setApproval(taskID: task.id, to: .requested)
            try parallelTaskBoard.setApproval(taskID: task.id, to: .approved)
        }
        _ = try parallelTaskBoard.transition(taskID: task.id, to: .inProgress)
        _ = try parallelTaskBoard.updateProgress(taskID: task.id, summary: summary)
        return task.id
    }

    private func recordUnlaunchedTask(sessionID: UUID, summary: String) throws {
        let task = try parallelTaskBoard.create(sessionID: sessionID, progressSummary: "Queued; verifier was not launched.")
        _ = try parallelTaskBoard.transition(taskID: task.id, to: .blocked)
        _ = try parallelTaskBoard.updateProgress(taskID: task.id, summary: summary)
    }

    private func finishTrackedRun(
        taskID: UUID,
        status: ParallelTaskStatus,
        summary: String,
        reference: ParallelTaskReference? = nil
    ) throws {
        _ = try parallelTaskBoard.updateProgress(taskID: taskID, summary: OutputRedactor.redact(summary))
        if let reference { _ = try parallelTaskBoard.addReference(taskID: taskID, kind: reference.kind, value: reference.value) }
        _ = try parallelTaskBoard.transition(taskID: taskID, to: status)
    }
}
