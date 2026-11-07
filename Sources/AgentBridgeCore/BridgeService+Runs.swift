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
                    message: "The local model server is reachable; this status is not a subscription or cloud account check.",
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
            throw AgentBridgeError.sessionMismatch("Local models have no subscription usage terminal; use the local model connection check.")
        }
        let settings = try store.loadSettings()
        guard settings.usageMode == .subscription else {
            throw AgentBridgeError.sessionMismatch("The official usage TUI supports subscription sign-in only. Switch back to subscription mode first.")
        }
        guard settings.defaultProvider == provider else {
            throw AgentBridgeError.sessionMismatch("The app's default provider has changed. Reopen the usage TUI from the current subscription usage panel.")
        }
        let profile = try accountProfile(id: profileID)
        guard profile.provider == provider else {
            throw AccountProfileError.providerMismatch(profile.id, provider)
        }
        let selectedProfile = try accountProfileStore.selected(provider: provider)
        guard selectedProfile.id == profile.id else {
            throw AgentBridgeError.sessionMismatch("The selected account has changed. Reopen the usage TUI from that account's subscription usage panel.")
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
        maximumMCPToolCallsPerServer: Int? = nil,
        waitsForRunSlot: Bool = false
    ) async throws -> ProviderOutput {
        try validateRunRequest(prompt: prompt, maximumMCPToolCallsPerServer: maximumMCPToolCallsPerServer)
        let initialSession = try loadSession(sessionID)
        if initialSession.provider == .local {
            guard apiRequest == nil else {
                throw AgentBridgeError.sessionMismatch("Local models do not use a Claude API budget or API key.")
            }
            guard extensionIDs?.isEmpty ?? true,
                  expectedExtensionFingerprint == nil,
                  maximumMCPToolCallsPerServer == nil else {
                throw AgentBridgeError.sessionMismatch("Local models do not support Skills, MCP or other project tools yet; nothing was started.")
            }
        }
        let lease = try await acquireProviderRunLease(for: sessionID, waitsForRunSlot: waitsForRunSlot, cancellation: cancellation)
        defer { withExtendedLifetime(lease) {} }
        let settings = try store.loadSettings()
        let session = try loadSession(sessionID)
        guard session.provider == .codex || session.provider == .claude || session.provider == .local,
              session.policy.accessMode == .readOnly,
              session.policy.workspaceReadOnly else {
            throw AgentBridgeError.sessionMismatch("The session is not in read-only mode.")
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
        try validateAPIRequest(apiRequest, apiMode: apiMode, session: session)
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
        try verifyExtensionInvocation(extensionInvocation, expectedFingerprint: expectedExtensionFingerprint)
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
        let reservation = try await reserveBudgetOrConfirmSignIn(
            apiRequest: apiRequest,
            activeSpendLedger: activeSpendLedger,
            session: session,
            profile: profile,
            executable: executable
        )

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
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "api.run.authorized", message: "Claude API run explicitly authorized; per-run cap US$\(String(format: "%.2f", apiRequest?.requestedBudgetUSD ?? 0)), reserved budget US$\(String(format: "%.2f", reservation.reservedUSD)). Actual charges are determined by the provider bill."))
            } else {
                let extensionText = extensionInvocation.skills.isEmpty && extensionInvocation.mcpServers.isEmpty
                    ? "No enabled Skills or MCP tools are used."
                    : "Extension fingerprint \(extensionInvocation.fingerprint.prefix(12)); Skills \(extensionInvocation.skills.count), MCP servers \(extensionInvocation.mcpServers.count)."
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.started", message: "Started a read-only run with subscription sign-in.\(extensionText) Each turn builds fresh context from the AgentBridge transcript and shared memory and does not resume native CLI history. Prompt content is not written to audit files."))
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
                    message: "Loaded shared memory revision \(memoryContext.revision), with \(memoryContext.includedTurnCount) earlier turn(s)\(memoryContext.wasTruncated ? " (content truncated)" : "")."
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
                    actualCostUSD: parsedOutput.actualCostUSD,
                    tokenUsage: parsedOutput.tokenUsage
                )
            } else {
                output = parsedOutput
            }
            if let reservation {
                try activeSpendLedger?.reconcile(reservationID: reservation.id, actualUSD: output.actualCostUSD)
                if let actual = output.actualCostUSD, actual > reservation.requestedUSD {
                    try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "api.budget.exceeded", message: "Claude reported a charge above the per-run limit. This output will not be marked successful. The provider bill is authoritative."))
                    throw AgentBridgeError.providerFailed(.claude, "The provider reported a charge above the per-run limit.")
                }
            }
            activeSession.providerSessionID = nil
            activeSession.status = .completed
            activeSession.updatedAt = Date()
            try store.saveSession(activeSession)
            let storedText = String(output.text.prefix(200_000))
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.output", message: storedText))
            recordTokenUsage(output.tokenUsage, runID: sessionID, profileID: profile.id)
            if reservation != nil {
                let costText = output.actualCostUSD.map { "Provider reported US$\(String(format: "%.4f", $0))." } ?? "The provider did not report the actual charge. The reserved budget will not be returned."
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "api.run.completed", message: costText))
            } else {
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "run.completed", message: processResult.outputWasTruncated ? "The response succeeded, but some nonessential CLI output exceeded the buffer limit." : "Response finished."))
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
                    try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "memory.save.failed", message: "This successful response could not be written to shared memory."))
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


    private func validateRunRequest(prompt: String, maximumMCPToolCallsPerServer: Int?) throws {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("Enter content to send to the assistant.")
        }
        guard prompt.utf8.count <= 256_000 else {
            throw AgentBridgeError.invalidInput("Prompts can contain up to 256 KiB.")
        }
        if let maximumMCPToolCallsPerServer, !(1...128).contains(maximumMCPToolCallsPerServer) {
            throw AgentBridgeError.invalidInput("The per-run MCP tool-call cap must be between 1 and 128.")
        }
    }

    private func validateAPIRequest(_ apiRequest: APIUsageRequest?, apiMode: Bool, session: SessionRecord) throws {
        guard apiMode == (apiRequest != nil) else {
            if apiMode { throw AgentBridgeError.sessionMismatch("Each API run requires a per-run budget, an API key, and explicit confirmation.") }
            throw AgentBridgeError.sessionMismatch("Choose API mode in Settings first, or use subscription sign-in mode.")
        }
        if apiMode {
            guard session.provider == .claude else { throw AgentBridgeError.sessionMismatch("API mode currently supports Claude only.") }
            guard session.providerSessionID == nil else { throw AgentBridgeError.sessionMismatch("API mode cannot resume a subscription-mode session.") }
            guard let apiRequest, apiRequest.explicitlyAuthorized else {
                throw AgentBridgeError.sessionMismatch("An API run requires explicit confirmation of its paid budget.")
            }
            guard apiRequest.requestedBudgetUSD.isFinite,
                  apiRequest.requestedBudgetUSD >= 0.01,
                  apiRequest.requestedBudgetUSD <= 140,
                  abs(((apiRequest.requestedBudgetUSD * 100).rounded() / 100) - apiRequest.requestedBudgetUSD) < 0.000_000_1,
                  !apiRequest.apiKey.isEmpty,
                  !apiRequest.apiKey.contains("\0") else {
                throw AgentBridgeError.invalidInput("API mode requires a valid API key and a per-run budget between US$0.01 and US$140 with at most two decimal places.")
            }
        }
    }

    private func verifyExtensionInvocation(
        _ extensionInvocation: ActiveExtensionInvocation,
        expectedFingerprint expectedExtensionFingerprint: String?
    ) throws {
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
    }

    /// An API run reserves its budget in the ledger; a subscription run needs a
    /// confirmed sign-in. Either way a refusal is audited before it is thrown.
    private func reserveBudgetOrConfirmSignIn(
        apiRequest: APIUsageRequest?,
        activeSpendLedger: APISpendLedger?,
        session: SessionRecord,
        profile: AccountProfile,
        executable: URL
    ) async throws -> APISpendReservation? {
        let sessionID = session.id
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
                try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "auth.refused", message: "Subscription sign-in not confirmed; \(assessment.message)"))
                throw AgentBridgeError.unauthenticated(session.provider, assessment.message)
            }
        }
        return reservation
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
            throw AgentBridgeError.invalidInput("Select a model in Local Model Settings first.")
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
            throw AgentBridgeError.invalidInput("The local model prompt exceeds the 2 MiB limit; shorten the current request or reduce pinned background content.")
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
                    message: "Loaded shared memory revision \(memoryContext.revision), \(Self.contextCompressionAuditSummary(compression.report))"
                ))
            }
            let response = try await localModelClient.generate(
                settings: settings,
                prompt: providerPrompt,
                cancellationRequestURL: store.cancellationRequestURL(for: session.id),
                cancellation: cancellation,
                onProgress: { emitter.emit($0) }
            )
            let output = ProviderOutput(text: response.text, providerSessionID: nil, tokenUsage: TokenUsage(local: response.usage))
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
            recordTokenUsage(output.tokenUsage, runID: session.id, profileID: profile.id)
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
                        message: "The local model reply completed, but shared memory reached its safe storage limit or could not be saved; existing memory was not rewritten."
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
        maximumMCPToolCallsPerServer: Int? = nil,
        waitsForRunSlot: Bool = false
    ) async throws -> ProviderOutput {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { throw AgentBridgeError.invalidInput("Enter content to send to the assistant.") }
        guard trimmedPrompt.utf8.count <= 256_000 else { throw AgentBridgeError.invalidInput("Prompts can contain up to 256 KiB.") }
        if let maximumMCPToolCallsPerServer, !(1...128).contains(maximumMCPToolCallsPerServer) {
            throw AgentBridgeError.invalidInput("The per-run MCP tool-call cap must be between 1 and 128.")
        }

        let initialSession = try loadSession(sessionID)
        guard initialSession.provider != .local else {
            throw AgentBridgeError.sessionMismatch("Local models currently support only read-only project conversations; no changes were run.")
        }

        let lease = try await acquireProviderRunLease(for: sessionID, waitsForRunSlot: waitsForRunSlot, cancellation: cancellation)
        defer { withExtendedLifetime(lease) {} }
        let settings = try store.loadSettings()
        guard settings.usageMode == .subscription else {
            throw AgentBridgeError.sessionMismatch("Isolated changes support only a confirmed subscription sign-in; no paid Claude API operation will start.")
        }
        let session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        let plan = try requireApprovedPlan(session: session, planID: planID, reviewedDigest: reviewedDigest)
        let profile = try requireBoundProfile(for: session, allowUnselected: allowBoundProfileWithoutGlobalSelection)
        try authorizeManagedRun(session: session, profile: profile, usageMode: .subscription)
        try await workspaceManager.validateWorkspace(for: session, accessMode: .isolatedChanges)
        let executable = try RuntimeEnvironment.resolveExecutable(
            provider: session.provider,
            configuredPath: settings.binaryPath(for: session.provider)
        )
        try await requireConfirmedSubscription(session: session, profile: profile, executable: executable)

        let temp = try makePrivateTemporaryDirectory(label: "change-\(sessionID.uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let environment = try providerEnvironment(profile: profile, privateTemporaryDirectory: temp)
        let commandWrapper = try claudeChangeSandbox(session: session, environment: environment, temporaryDirectory: temp)
        let extensionInvocation = try activeExtensionRuntimeStore.invocation(
            projectID: extensionProjectID(for: session),
            provider: session.provider,
            profileID: profile.id,
            workspacePath: session.workspacePath,
            selectedExtensionIDs: extensionIDs
        )
        try verifyExtensionInvocation(extensionInvocation, expectedFingerprint: expectedExtensionFingerprint)
        let mcpControlPlane = try makeMCPRunDirectoryLease(for: extensionInvocation, session: session, providerTemporaryDirectory: temp)
        defer { mcpControlPlane?.remove() }
        // Memory reaches a run that edits files only when the plan asked for it, and
        // only as approved.
        let includesMemory = allowSharedMemoryForRun && plan.includesSharedMemory
        if includesMemory {
            guard let approved = session.approvedChangePlanMemoryDigest,
                  try changeRunMemoryDigest(session: session, profile: profile) == approved else {
                throw AgentBridgeError.invalidChangePlan("The shared memory changed after this plan was approved. Approve the plan again to use the current memory.")
            }
        }
        let (promptWithMemory, memoryContext) = includesMemory
            ? try legacyPromptWithSharedMemory(trimmedPrompt, session: session, profile: profile)
            : (trimmedPrompt, nil)
        let providerPrompt = makeChangePrompt(plan: plan, extensionInvocation: extensionInvocation, promptWithMemory: promptWithMemory)

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
            activeSession.approvedChangePlanMemoryDigest = nil
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
                message: "Started \(session.provider.rawValue) change run in the isolated workspace; plan summary hash \(plan.reviewDigest). The source repository will not be written."
            ))
            if let memoryContext {
                try? store.appendEvent(AuditEvent(
                    sessionID: sessionID,
                    kind: "memory.loaded",
                    message: "Loaded shared memory revision \(memoryContext.revision), with \(memoryContext.includedTurnCount) earlier turn(s)\(memoryContext.wasTruncated ? " (content truncated)" : "")."
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
                wrapCommand: mcpServerCommands.isEmpty ? commandWrapper : nil,
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
                actualCostUSD: parsedOutput.actualCostUSD,
                tokenUsage: parsedOutput.tokenUsage
            )
            activeSession.providerSessionID = safeProviderSessionID(output.providerSessionID)
            activeSession.lastChangeRunAt = Date()
            activeSession.status = .completed
            activeSession.updatedAt = Date()
            try store.saveSession(activeSession)
            recordTokenUsage(output.tokenUsage, runID: sessionID, profileID: profile.id)
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "change.run.completed",
                message: processResult.outputWasTruncated ? "Isolated change run succeeded; some non-essential CLI output exceeded the buffer limit." : "Isolated change run completed; you can review the file diffs."
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
                    try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "memory.save.failed", message: "This successful response could not be written to shared memory."))
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

    /// The plan the user approved, or an audited refusal when the identifier or
    /// review digest does not match what is currently approved.
    private func requireApprovedPlan(session: SessionRecord, planID: UUID, reviewedDigest: String) throws -> ChangePlan {
        let sessionID = session.id
        guard let plan = session.changePlan,
              plan.sessionID == sessionID,
              plan.id == planID,
              plan.reviewDigest == reviewedDigest.lowercased(),
              session.approvedChangePlanDigest == plan.reviewDigest else {
            try? store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "change.run.blocked",
                message: "The currently approved work plan identifier and review digest were not provided; no files were written."
            ))
            throw AgentBridgeError.changePlanRequired
        }
        return plan
    }

    private func requireConfirmedSubscription(session: SessionRecord, profile: AccountProfile, executable: URL) async throws {
        let sessionID = session.id
        let assessment = try await checkAuthentication(profile: profile, executable: executable)
        guard assessment.confirmedSubscription else {
            try store.appendEvent(AuditEvent(
                sessionID: sessionID,
                kind: "auth.refused",
                message: "Could not confirm \(session.provider.rawValue) subscription sign-in; \(assessment.message)"
            ))
            throw AgentBridgeError.unauthenticated(session.provider, assessment.message)
        }
    }

    private func makeChangePrompt(plan: ChangePlan, extensionInvocation: ActiveExtensionInvocation, promptWithMemory: String) -> String {
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
        return providerPrompt
    }

    /// A user-approved custom verification program, checked before it is ever run:
    /// it must be approved, an absolute path to an executable file, and its
    /// arguments must stay within bounds.
    private func validatedCustomVerificationExecutable(
        _ customExecutableURL: URL,
        arguments: [String],
        customCommandApproved: Bool
    ) throws -> URL {
        guard customCommandApproved else {
            throw AgentBridgeError.verificationCommandRejected("A custom program must first be reviewed and explicitly approved by the user.")
        }
        let candidate = customExecutableURL.standardizedFileURL
        guard customExecutableURL.isFileURL,
              candidate.path.hasPrefix("/"),
              !candidate.path.contains("\0"),
              !candidate.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              FileManager.default.isExecutableFile(atPath: candidate.path) else {
            throw AgentBridgeError.verificationCommandRejected("Choose an executable absolute path.")
        }
        guard arguments.count <= 128,
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 8_192 }),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 64 * 1_024 else {
            throw AgentBridgeError.verificationCommandRejected("The custom arguments exceed the size limit or contain invalid characters.")
        }
        return candidate
    }

    @discardableResult
    public func runVerification(
        sessionID: UUID,
        customExecutableURL: URL? = nil,
        arguments: [String] = [],
        customCommandApproved: Bool = false,
        cancellation: CancellationFlag = CancellationFlag(),
        waitsForRunSlot: Bool = false
    ) async throws -> VerificationResult {
        let lease = try await acquireProviderRunLease(for: sessionID, waitsForRunSlot: waitsForRunSlot, cancellation: cancellation)
        defer { withExtendedLifetime(lease) {} }
        var session = try loadSession(sessionID)
        try requireIsolatedChangesSession(session)
        try await workspaceManager.validateWorkspace(for: session, accessMode: .isolatedChanges)
        let diffBeforeVerification = try await workspaceManager.diff(for: session)

        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true).standardizedFileURL
        let executableURL: URL
        let commandArguments: [String]
        if let customExecutableURL {
            executableURL = try validatedCustomVerificationExecutable(
                customExecutableURL,
                arguments: arguments,
                customCommandApproved: customCommandApproved
            )
            commandArguments = arguments
        } else {
            guard arguments.isEmpty, !customCommandApproved else {
                throw AgentBridgeError.verificationCommandRejected("The default verification does not accept extra arguments or a custom-command approval flag.")
            }
            let script = workspace.appendingPathComponent(".codex/ci.sh")
            var metadata = stat()
            guard lstat(script.path, &metadata) == 0 else {
                if errno != ENOENT { throw AgentBridgeError.verificationCommandRejected("Could not safely inspect .codex/ci.sh.") }
                let result = VerificationResult(
                    command: nil,
                    exitCode: nil,
                    durationSeconds: 0,
                    standardOutput: "",
                    standardError: "",
                    wasCancelled: false,
                    timedOut: false,
                    skippedReason: "The isolated workspace has no executable .codex/ci.sh."
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
                throw AgentBridgeError.verificationCommandRejected(".codex/ci.sh must be a regular, executable file.")
            }
            // Providers can edit this workspace, so a changed script is theirs, not the
            // project's, and running it by default would let a change pass its own gate.
            guard try await workspaceManager.projectVerificationScriptIsUnchanged(for: session) else {
                throw AgentBridgeError.verificationCommandRejected(".codex/ci.sh differs from the pinned commit. Review it, then restore it or run it as an approved custom command.")
            }
            executableURL = script
            commandArguments = []
        }

        let temp = try ProcessSandbox.makeWritableRoot(label: "verify-\(sessionID.uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let home = temp.appendingPathComponent("home", isDirectory: true)
        let temporaryFiles = temp.appendingPathComponent("tmp", isDirectory: true)
        try AuditStore.createPrivateDirectory(home)
        try AuditStore.createPrivateDirectory(temporaryFiles)
        let workingDirectory = temp.appendingPathComponent("checkout", isDirectory: true)
        try await workspaceManager.createVerificationCheckout(
            for: session,
            patch: diffBeforeVerification.patch,
            at: workingDirectory
        )
        // A program inside the workspace runs from the checkout, so what it does is
        // limited to the patch. An ignored file is not there, and is refused below.
        let workspacePrefix = workspace.path + "/"
        let runExecutableURL = executableURL.path.hasPrefix(workspacePrefix)
            ? workingDirectory.appendingPathComponent(String(executableURL.path.dropFirst(workspacePrefix.count)))
            : executableURL
        guard FileManager.default.isExecutableFile(atPath: runExecutableURL.path) else {
            throw AgentBridgeError.verificationCommandRejected("The program is not in the reviewed changes, so it cannot run in the verification checkout.")
        }
        let sandboxedCommand = try ProcessSandbox(
            writableRoots: [temp],
            protectedRoots: sandboxProtectedRoots(for: session)
        ).command(executable: runExecutableURL, arguments: commandArguments)

        let command = VerificationCommand(
            executablePath: executableURL.path,
            arguments: commandArguments,
            workingDirectoryPath: workingDirectory.path
        )
        let environment = [
            "HOME": home.path,
            "TMPDIR": temporaryFiles.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "C",
            "TERM": "dumb",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            ProcessSandbox.verificationMarker: "1"
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
                message: "Acquired the session run lock; the previous run state had no active process, so it was recorded as failed before verification started."
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
            message: "Running \(OutputRedactor.redact(executableURL.path)) \(OutputRedactor.redact(argumentsForAudit(commandArguments))), working directory \(workingDirectory.path)."
        ))

        do {
            let processResult = try await runner.run(ProcessSpec(
                executableURL: sandboxedCommand.executable,
                arguments: sandboxedCommand.arguments,
                environment: environment,
                workingDirectoryURL: workingDirectory,
                standardInput: Data(),
                timeout: 3_600,
                outputLimit: 2 * 1_024 * 1_024,
                cancellationRequestURL: store.cancellationRequestURL(for: sessionID),
                endsWithParent: true
            ), cancellation: cancellation)
            let duration = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
            let stdout = String(decoding: processResult.standardOutput, as: UTF8.self)
            let stderr = String(decoding: processResult.standardError, as: UTF8.self)
            let diffAfterVerification = try await workspaceManager.diff(for: session)
            let checkoutUnchanged = try await workspaceManager.verificationCheckoutMatches(
                workingDirectory,
                session: session,
                digest: diffBeforeVerification.digest
            )
            let result = VerificationResult(
                command: command,
                exitCode: processResult.exitCode,
                durationSeconds: duration,
                standardOutput: stdout,
                standardError: stderr,
                wasCancelled: processResult.wasCancelled,
                timedOut: processResult.timedOut,
                workspaceChangedDuringVerification: diffAfterVerification.digest != diffBeforeVerification.digest || !checkoutUnchanged
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
                message: "Exit code \(processResult.exitCode), took \(String(format: "%.3f", duration)) s, standard output \(result.standardOutput.utf8.count) bytes, error output \(result.standardError.utf8.count) bytes."
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
                message: "Verification did not finish; took \(String(format: "%.3f", duration)) s.\(OutputRedactor.redact(error.localizedDescription))"
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
            throw AgentBridgeError.sessionMismatch("Local models do not support Terminal or interactive control; no process was started.")
        }
        let lease = try store.acquireRunLease(for: sessionID)
        defer { withExtendedLifetime(lease) {} }
        let settings = try store.loadSettings()
        guard settings.usageMode == .subscription else {
            throw AgentBridgeError.sessionMismatch("The native interactive terminal uses subscription sign-in only. Paid API mode does not support it.")
        }
        var session = try loadSession(sessionID)
        guard session.provider == .codex || session.provider == .claude,
              session.policy.accessMode == .interactiveManualApproval,
              !session.policy.workspaceReadOnly else {
            throw AgentBridgeError.sessionMismatch("Create a session with interactive manual approval.")
        }
        let profile = try requireBoundSelectedProfile(for: session)
        if let profileID, profileID != profile.id {
            throw AgentBridgeError.sessionMismatch("The Terminal launch settings use a different account from the one bound to the session. Create a new session.")
        }
        try authorizeManagedRun(session: session, profile: profile, usageMode: .subscription)
        try await workspaceManager.validateWorkspace(for: session, accessMode: .interactiveManualApproval)
        let executable = try RuntimeEnvironment.resolveExecutable(provider: session.provider, configuredPath: settings.binaryPath(for: session.provider))
        let assessment = try await checkAuthentication(profile: profile, executable: executable)
        guard assessment.confirmedSubscription else {
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "auth.refused", message: "Could not confirm \(session.provider.rawValue) subscription sign-in; \(assessment.message)"))
            throw AgentBridgeError.unauthenticated(session.provider, assessment.message)
        }
        _ = store.consumeCancellationRequest(for: sessionID)
        onProgress?("Launching in Terminal: \(session.provider.rawValue) Interactive Session.")
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
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "interactive.launching", message: "Launching in Terminal: \(session.provider.rawValue); terminal activity and output will not be saved."))
            let temp = try makePrivateTemporaryDirectory(label: "interactive-\(sessionID.uuidString.lowercased())")
            defer { try? FileManager.default.removeItem(at: temp) }
            var environment = try providerEnvironment(profile: profile, privateTemporaryDirectory: temp)
            environment["TERM"] = "xterm-256color"
            contextFileURL = try writeInteractiveMemoryContext(session: invocationSession, profile: profile)
            if contextFileURL != nil {
                try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "memory.loaded", message: "A shared memory file was provided to the interactive terminal. Terminal history is not saved."))
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
                        try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "interactive.started", message: "\(invocationSession.provider.rawValue) launched in Terminal; terminal activity and output are not saved."))
                        onProgress?("\(invocationSession.provider.rawValue) interactive session started in Terminal.")
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
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: "interactive.completed", message: "\(session.provider.rawValue) interactive session ended; no terminal log was saved. Exit code \(result.exitCode)."))
            onProgress?("\(session.provider.rawValue) interactive session ended.")
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
        onProgress?("Complete sign-in for this new account on the official \(profile.provider.rawValue) sign-in screen.")
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
            throw AgentBridgeError.providerFailed(profile.provider, "Official sign-in process exit code \(result.exitCode).")
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
                throw AgentBridgeError.sessionMismatch("The selected account differs from the account bound to the session. Create a new isolated workspace before running.")
            }
        }
        let profile = try accountProfile(id: boundID)
        guard profile.provider == session.provider else {
            throw AgentBridgeError.sessionMismatch("The session is bound to an account from a different provider.")
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
            throw AgentBridgeError.sessionMismatch("Local models do not read the Codex or Claude CLI environment or sign-in folders.")
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
            throw AccountProfileError.persistence("The provider environment override does not match the account directory rules.")
        }
        environment.merge(overrides, uniquingKeysWith: { _, new in new })
        return environment
    }

    /// A run started by hand fails at once when every run slot is busy, so the user
    /// can choose what to stop. Work approved as a whole waits for a slot.
    func acquireProviderRunLease(
        for sessionID: UUID,
        waitsForRunSlot: Bool,
        cancellation: CancellationFlag
    ) async throws -> SessionRunLease {
        waitsForRunSlot
            ? try await store.acquireRunLeaseWaitingForSlot(for: sessionID, cancellation: cancellation)
            : try store.acquireRunLease(for: sessionID, countsTowardRunLimit: true)
    }

    /// What a sandboxed run must not read or write besides the home folder.
    func sandboxProtectedRoots(for session: SessionRecord) -> [URL] {
        store.managedWorkspaceRootURLs + [store.rootURL, URL(fileURLWithPath: session.sourceRepositoryPath, isDirectory: true)]
    }

    /// Claude's change tools run in its own process and decide for themselves which
    /// paths they may edit. This confines them to the workspace at the OS level, and
    /// keeps `.git` read-only; a change run has no shell to work around that. Codex
    /// runs its own Seatbelt sandbox, which cannot be nested. Runs with MCP servers
    /// are left out, because the AgentBridge MCP proxy reads the private data root.
    func claudeChangeSandbox(
        session: SessionRecord,
        environment: [String: String],
        temporaryDirectory: URL
    ) throws -> (@Sendable (URL, [String]) throws -> (URL, [String]))? {
        guard session.provider == .claude else { return nil }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let workspace = URL(fileURLWithPath: session.workspacePath, isDirectory: true)
        // A custom profile keeps `.claude.json` inside its configuration folder.
        let configuration = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let writableRoots = [workspace, temporaryDirectory, configuration ?? home.appendingPathComponent(".claude", isDirectory: true)]
        let writablePrefixes = configuration == nil ? [home.appendingPathComponent(".claude.json")] : []
        let protectedRoots = sandboxProtectedRoots(for: session)
        return { executable, arguments in
            // Claude keeps its sign-in in the login keychain, read through this file.
            let sandbox = ProcessSandbox(
                writableRoots: writableRoots,
                protectedRoots: protectedRoots,
                writablePrefixes: writablePrefixes,
                readableRoots: [
                    home.appendingPathComponent("Library/Keychains/login.keychain-db"),
                    URL(fileURLWithPath: ProcessSandbox.canonicalPath(executable)).deletingLastPathComponent()
                ],
                readOnlyRoots: [workspace.appendingPathComponent(".git", isDirectory: true)],
                allowsKeychain: true
            )
            let command = try sandbox.command(executable: executable, arguments: arguments)
            return (command.executable, command.arguments)
        }
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
