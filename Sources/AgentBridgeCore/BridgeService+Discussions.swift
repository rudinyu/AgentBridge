import Darwin
import Foundation

private struct DiscussionPromptEnvelope: Encodable {
    let version: Int
    let contextTruncated: Bool
    let turns: [DiscussionPromptTurn]
}

private struct DiscussionPromptTurn: Encodable {
    let turnID: String
    let timestamp: String
    let provider: String
    let userText: String
    let assistantText: String
}


extension BridgeService {
    public func discussions() throws -> [DiscussionRecord] {
        try discussionStore.list().map(reconcileStaleDiscussionIfUnleased)
    }

    public func discussion(id: UUID) throws -> DiscussionRecord {
        try reconcileStaleDiscussionIfUnleased(rawDiscussion(id: id))
    }

    private func rawDiscussion(id: UUID) throws -> DiscussionRecord {
        guard let record = try discussionStore.record(id: id) else {
            throw AgentBridgeError.sessionMismatch("找不到這個討論。")
        }
        return record
    }

    private func reconcileStaleDiscussionIfUnleased(_ record: DiscussionRecord) throws -> DiscussionRecord {
        guard record.status.isInFlight else { return record }
        let lease: SessionRunLease
        do {
            lease = try store.acquireRunLease(for: record.id)
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { throw error }
            return record
        }
        defer { withExtendedLifetime(lease) {} }
        var current = try rawDiscussion(id: record.id)
        guard current.status.isInFlight else { return current }
        try recoverStaleDiscussionRun(&current)
        return current
    }

    public func discussionEvents(id: UUID) throws -> [AuditEvent] {
        _ = try discussion(id: id)
        return try store.events(sessionID: id)
    }

    public func previewDiscussionContext(
        id: UUID,
        currentPrompt: String,
        settings: LocalModelSettings? = nil
    ) throws -> ContextCompressionPreview {
        let record = try rawDiscussion(id: id)
        let profile = try requireDiscussionProfile(record)
        let cleanedPrompt = OutputRedactor.redact(currentPrompt)
        let compression = try discussionPrompt(
            record: record,
            currentTurnID: nil,
            destinationProfile: profile,
            currentPrompt: cleanedPrompt,
            localSettings: settings
        )
        let token = "discussion:\(record.id.uuidString.lowercased()):\(record.revision):\(profile.id.uuidString.lowercased()):\(settings?.contextWindowTokens ?? 0):\(settings?.maxOutputTokens ?? 0)"
        return ContextCompressionPreview(compressedContext: compression, stalenessToken: token)
    }

    public func previewProjectContext(
        sessionID: UUID,
        currentPrompt: String,
        settings: LocalModelSettings? = nil
    ) throws -> ContextCompressionPreview {
        let session = try loadSession(sessionID)
        let profile = try requireBoundProfile(for: session, allowUnselected: true)
        let compression = try projectContextCompression(
            currentPrompt: currentPrompt,
            session: session,
            profile: profile,
            includeMemory: profile.allowsSharedMemory,
            localSettings: settings
        )
        let token = "session:\(session.id.uuidString.lowercased()):\(session.snapshotCommit):\(profile.id.uuidString.lowercased()):\(settings?.contextWindowTokens ?? 0):\(settings?.maxOutputTokens ?? 0)"
        return ContextCompressionPreview(compressedContext: compression, stalenessToken: token)
    }

    public func createDiscussion(
        provider: AgentProvider,
        accountProfileID: UUID? = nil
    ) throws -> DiscussionRecord {
        guard let dataRoot = store.workspaceRootURL else {
            throw AgentBridgeError.invalidInput("尚未設定工作區資料根目錄；請先選擇使用者資料資料夾。")
        }
        let profileID: UUID
        if let accountProfileID {
            profileID = accountProfileID
        } else {
            profileID = try accountProfileStore.selected(provider: provider).id
        }
        let profile = try accountProfile(id: profileID)
        guard profile.provider == provider else { throw AccountProfileError.providerMismatch(profileID, provider) }
        let record = DiscussionRecord(
            dataRootPath: dataRoot.standardizedFileURL.path,
            provider: provider,
            accountProfileID: profile.id,
            usageProfileIDs: [profile.id]
        )
        let saved = try discussionStore.create(record)
        try store.appendEvent(AuditEvent(
            sessionID: saved.id,
            kind: "discussion.created",
            message: "已建立不綁定 Git 專案的討論；對話記憶由 AgentBridge 管理。"
        ))
        return saved
    }

    public func setDiscussionTarget(
        id: UUID,
        provider: AgentProvider,
        accountProfileID: UUID
    ) throws -> DiscussionRecord {
        let lease = try store.acquireRunLease(for: id)
        defer { withExtendedLifetime(lease) {} }
        var record = try rawDiscussion(id: id)
        try recoverStaleDiscussionRun(&record)
        guard !record.status.isInFlight else {
            throw AgentBridgeError.sessionMismatch("討論仍在執行；請先停止目前回合再切換帳戶。")
        }
        let profile = try accountProfile(id: accountProfileID)
        guard profile.provider == provider else { throw AccountProfileError.providerMismatch(accountProfileID, provider) }
        guard record.provider != provider || record.accountProfileID != accountProfileID else { return record }
        guard record.revision < Int.max else { throw AgentBridgeError.persistence("討論版本計數已達上限。") }
        record.provider = provider
        record.accountProfileID = accountProfileID
        record.revision += 1
        record.updatedAt = Date()
        let saved = try discussionStore.save(record)
        try store.appendEvent(AuditEvent(
            sessionID: id,
            kind: "discussion.target.changed",
            message: "討論目標已切換為 \(provider.rawValue) 帳戶 \(accountProfileID.uuidString.lowercased())；不會續接其他帳戶或供應商的原生對話。"
        ))
        return saved
    }

    public func sendDiscussionMessage(
        id: UUID,
        prompt: String,
        isShareable: Bool = true,
        cancellation: CancellationFlag = CancellationFlag(),
        onProgress: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProviderOutput {
        let cleanedPrompt = try Self.boundedDiscussionText(OutputRedactor.redact(prompt))
        guard !cleanedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentBridgeError.invalidInput("請輸入要討論的內容。")
        }

        let lease = try store.acquireRunLease(for: id)
        defer { withExtendedLifetime(lease) {} }
        var record = try rawDiscussion(id: id)
        try recoverStaleDiscussionRun(&record)
        guard !record.status.isInFlight else {
            throw AgentBridgeError.sessionMismatch("討論已標示為執行中；請重新開啟後再試。")
        }
        let profile = try requireDiscussionProfile(record)
        let effectiveIsShareable = isShareable && profile.allowsSharedMemory
        guard record.turns.count < DiscussionStore.maximumTurnsPerDiscussion else {
            throw AgentBridgeError.invalidInput("此討論已達逐字稿安全回合上限；原有回合已保留，請另開討論繼續。")
        }
        guard record.usageProfileIDs.count < 128 || record.usageProfileIDs.contains(profile.id) else {
            throw AgentBridgeError.invalidInput("此討論已使用太多不同帳戶，請另開討論。")
        }
        guard record.revision < Int.max - 1 else {
            throw AgentBridgeError.persistence("討論版本計數已達上限。")
        }

        let bridgeSettings = try store.loadSettings()
        if profile.provider == .local {
            try LocalModelClient.validateSettings(bridgeSettings.localModel)
            guard !bridgeSettings.localModel.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentBridgeError.invalidInput("請先在本機模型設定中選擇一個模型。")
            }
        }

        let turnID = UUID()
        record.turns.append(DiscussionTurn(
            id: turnID,
            provider: record.provider,
            accountProfileID: profile.id,
            sourceSharedMemoryConsent: profile.allowsSharedMemory,
            isShareable: effectiveIsShareable,
            userText: cleanedPrompt
        ))
        record.usageProfileIDs.insert(profile.id)
        let compression = try discussionPrompt(
            record: record,
            currentTurnID: turnID,
            destinationProfile: profile,
            currentPrompt: cleanedPrompt,
            localSettings: profile.provider == .local ? bridgeSettings.localModel : nil
        )
        guard let providerPrompt = compression.prompt else {
            throw AgentBridgeError.invalidInput(compression.report.refusalReason ?? "Discussion context could not be prepared safely; no request was sent.")
        }
        try discussionStore.ensureRunCompletionFits(record)
        record.revision += 1
        record.status = .running
        record.updatedAt = Date()
        record = try discussionStore.save(record)
        try store.appendEvent(AuditEvent(sessionID: id, kind: "discussion.turn.started", message: "已開始討論回合；提示內容不會寫入稽核事件。"))

        var activeRecord = record
        var runStarted = false
        do {
            if store.consumeCancellationRequest(for: id) {
                throw AgentBridgeError.processCancelled
            }
            let maximumPromptBytes = profile.provider == .local
                ? LocalModelClient.maximumResponseBytes
                : 512 * 1_024
            guard providerPrompt.utf8.count <= maximumPromptBytes else {
                throw AgentBridgeError.invalidInput("討論上下文超過安全大小上限；請縮短目前要求或固定備註。")
            }
            let emitter = ProgressEmitter(sessionID: id, store: store, callback: onProgress)
            if compression.report.originalTurnCount > 0 || compression.report.compressionApplied {
                try store.appendEvent(AuditEvent(
                    sessionID: id,
                    kind: "discussion.context.loaded",
                    message: Self.contextCompressionAuditSummary(compression.report)
                ))
            }
            let parsedOutput: ProviderOutput
            let processOutputWasTruncated: Bool
            var localUsageSummary: String?
            if profile.provider == .local {
                try authorizeLocalModelRun(runID: id, profile: profile, settings: bridgeSettings.localModel)
                runStarted = true
                let response = try await localModelClient.generate(
                    settings: bridgeSettings.localModel,
                    prompt: providerPrompt,
                    cancellationRequestURL: store.cancellationRequestURL(for: id),
                    cancellation: cancellation,
                    maximumOutputBytes: DiscussionStore.maximumTextBytes,
                    onProgress: { emitter.emit($0) }
                )
                parsedOutput = ProviderOutput(text: response.text, providerSessionID: nil)
                processOutputWasTruncated = false
                localUsageSummary = "provider_input_tokens=\(response.usage.inputTokens.map(String.init) ?? "unavailable"); provider_output_tokens=\(response.usage.outputTokens.map(String.init) ?? "unavailable"); estimated_input_tokens_from_bytes=\(response.usage.estimatedInputTokens) (estimate, not exact tokenizer output)."
            } else {
                try authorizeManagedRun(runID: id, profile: profile, usageMode: .subscription)
                let executable = try RuntimeEnvironment.resolveExecutable(
                    provider: profile.provider,
                    configuredPath: bridgeSettings.binaryPath(for: profile.provider)
                )
                let privateDirectory = try makeFreshDiscussionTemporaryDirectory(label: "discussion-\(id.uuidString.lowercased())")
                defer { try? FileManager.default.removeItem(at: privateDirectory) }
                var environment = try providerEnvironment(profile: profile, privateTemporaryDirectory: privateDirectory)
                if profile.provider == .claude {
                    environment["CLAUDE_CODE_SKIP_PROMPT_HISTORY"] = "1"
                }
                let assessment = try await checkDiscussionAuthentication(profile: profile, executable: executable)
                guard assessment.confirmedSubscription else {
                    try store.appendEvent(AuditEvent(sessionID: id, kind: "auth.refused", message: "未確認訂閱登入；\(assessment.message)"))
                    throw AgentBridgeError.unauthenticated(profile.provider, assessment.message)
                }
                try store.appendEvent(AuditEvent(
                    sessionID: id,
                    kind: "run.started",
                    message: "account_profile_id=\(profile.id.uuidString.lowercased()); 以官方訂閱登入開始不綁定 Git 的唯讀討論。未啟用 MCP、Skills、擴充功能或原生對話續接。"
                ))
                runStarted = true
                let (processResult, output) = try await adapter.runDiscussion(
                    provider: profile.provider,
                    discussionWorkspaceURL: privateDirectory,
                    prompt: providerPrompt,
                    executableURL: executable,
                    environment: environment,
                    cancellationRequestURL: store.cancellationRequestURL(for: id),
                    onProgress: { message in emitter.emit(message) },
                    cancellation: cancellation
                )
                parsedOutput = output
                processOutputWasTruncated = processResult.outputWasTruncated
            }
            let output = ProviderOutput(text: try Self.boundedDiscussionText(parsedOutput.text), providerSessionID: nil)
            guard let turnIndex = activeRecord.turns.firstIndex(where: { $0.id == turnID }) else {
                throw AgentBridgeError.persistence("討論回合在執行期間已消失。")
            }
            activeRecord.turns[turnIndex].assistantText = output.text
            activeRecord.revision += 1
            activeRecord.status = .completed
            activeRecord.updatedAt = Date()
            activeRecord = try discussionStore.save(activeRecord)
            try store.appendEvent(AuditEvent(sessionID: id, kind: "run.output", message: output.text))
            try store.appendEvent(AuditEvent(
                sessionID: id,
                kind: profile.provider == .local ? "local.run.completed" : "run.completed",
                message: localUsageSummary.map { "討論回合完成。 \($0)" }
                    ?? (processOutputWasTruncated ? "討論完成；部分非必要 CLI 輸出超過緩衝上限。" : "討論回合完成。")
            ))
            return output
        } catch {
            activeRecord.status = (error as? AgentBridgeError) == .processCancelled ? .cancelled : .failed
            activeRecord.updatedAt = Date()
            _ = try? discussionStore.save(activeRecord)
            try? store.appendEvent(AuditEvent(
                sessionID: id,
                kind: profile.provider == .local
                    ? (runStarted ? "local.run.failed" : "discussion.turn.failed")
                    : (runStarted ? "run.failed" : "discussion.turn.failed"),
                message: OutputRedactor.redact(error.localizedDescription)
            ))
            throw error
        }
    }

    public func cancelDiscussion(id: UUID) throws {
        let record = try discussion(id: id)
        guard record.status == .running else {
            throw AgentBridgeError.sessionMismatch("這個討論目前沒有執行中的回合。")
        }
        let activeLease: SessionRunLease?
        do {
            activeLease = try store.acquireRunLease(for: id)
        } catch let error as AgentBridgeError {
            guard case .sessionMismatch = error else { throw error }
            activeLease = nil
        }
        if let activeLease {
            defer { withExtendedLifetime(activeLease) {} }
            var interrupted = try rawDiscussion(id: id)
            try recoverStaleDiscussionRun(&interrupted)
            throw AgentBridgeError.sessionMismatch("這個討論沒有作用中的程序；已保留逐字稿並標記中斷回合。")
        }
        try store.requestCancellation(forRunID: id)
        try store.appendEvent(AuditEvent(sessionID: id, kind: "discussion.cancel.requested", message: "已要求停止目前討論回合。"))
    }

    public func prepareDiscussionProjectHandoff(
        discussionID: UUID,
        destinationPath: String,
        mode: DiscussionProjectMode,
        targetProvider: AgentProvider,
        targetProfileID: UUID,
        selectedTurnIDs: Set<UUID>? = nil,
        accessMode: AccessMode = .readOnly
    ) async throws -> DiscussionProjectHandoff {
        let lease = try store.acquireRunLease(for: discussionID)
        defer { withExtendedLifetime(lease) {} }
        var record = try rawDiscussion(id: discussionID)
        try recoverStaleDiscussionRun(&record)
        guard !record.status.isInFlight else {
            throw AgentBridgeError.sessionMismatch("討論仍在執行；完成或停止目前回合後再準備專案交接。")
        }
        // Reviewed previews from an older discussion revision can no longer
        // be applied, and consumed previews are also inert. Retire those before
        // enforcing the bound so old previews do not permanently block future
        // handoffs. Keep every still-valid, unconsumed preview intact.
        let currentDiscussionRevision = record.revision
        record.handoffs.removeAll {
            $0.consumedSessionID != nil || $0.discussionRevision != currentDiscussionRevision
        }
        guard accessMode == .readOnly || accessMode == .isolatedChanges else {
            throw AgentBridgeError.invalidInput("討論交接目前只支援唯讀或隔離變更工作階段。")
        }
        guard targetProvider != .local || accessMode == .readOnly else {
            throw AgentBridgeError.sessionMismatch("本機模型只支援唯讀專案工作階段；未建立交接預覽。")
        }
        guard record.handoffs.count < DiscussionStore.maximumHandoffsPerDiscussion else {
            throw AgentBridgeError.invalidInput("此討論已達交接預覽數量上限。")
        }
        let targetSettings = try store.loadSettings()
        guard targetSettings.usageMode != .api || targetProvider == .claude || targetProvider == .local else {
            throw AgentBridgeError.sessionMismatch("目前全域模式為 API；請先切換至訂閱登入模式，再為 Codex 建立專案工作階段。討論本身仍使用訂閱登入。")
        }
        let destinationProfile = try accountProfile(id: targetProfileID)
        guard destinationProfile.provider == targetProvider else {
            throw AccountProfileError.providerMismatch(targetProfileID, targetProvider)
        }
        let path: String
        let expectedCommit: String?
        switch mode {
        case .createNew:
            path = try workspaceManager.validateNewProjectDestination(path: destinationPath).path
            expectedCommit = nil
        case .attachExisting:
            let snapshot = try await workspaceManager.inspectProjectRepository(path: destinationPath)
            path = snapshot.repositoryRoot.path
            expectedCommit = snapshot.commit
        }

        let eligibleTurns = try record.turns.filter { turn in
            guard turn.isShareable, turn.sourceSharedMemoryConsent,
                  let assistantText = turn.assistantText else { return false }
            let sourceProfile = try accountProfile(id: turn.accountProfileID)
            return sourceProfile.provider == turn.provider && sourceProfile.allowsSharedMemory && !assistantText.isEmpty
        }
        let selectedIDs = selectedTurnIDs ?? Set(eligibleTurns.map(\.id))
        guard selectedIDs.count <= DiscussionStore.maximumTurnsPerHandoff else {
            throw AgentBridgeError.invalidInput("選取的討論回合數量超過上限。")
        }
        let selectedTurns = eligibleTurns.filter { selectedIDs.contains($0.id) }
        guard selectedTurns.count == selectedIDs.count else {
            throw AgentBridgeError.sessionMismatch("所選回合已取消分享、來源帳戶不同意，或目標帳戶不允許共享記憶。")
        }
        if !selectedTurns.isEmpty, !destinationProfile.allowsSharedMemory {
            throw AgentBridgeError.sessionMismatch("目標帳戶尚未允許共享記憶；請取消選取交接內容，或先檢視並啟用此帳戶的記憶同意設定。")
        }
        let handoff = DiscussionProjectHandoff(
            discussionID: discussionID,
            discussionRevision: record.revision,
            destinationPath: path,
            mode: mode,
            targetProvider: targetProvider,
            targetProfileID: destinationProfile.id,
            accessMode: accessMode,
            expectedRepositoryCommit: expectedCommit,
            selectedTurns: selectedTurns.compactMap { turn in
                guard let assistantText = turn.assistantText else { return nil }
                return DiscussionHandoffTurn(turn: turn, assistantText: assistantText)
            }
        )
        guard handoff.hasValidDigest() else {
            throw AgentBridgeError.persistence("無法產生有效的討論交接摘要。")
        }
        record.handoffs.append(handoff)
        record.updatedAt = Date()
        record = try discussionStore.save(record)
        try store.appendEvent(AuditEvent(
            sessionID: discussionID,
            kind: "discussion.handoff.prepared",
            message: "已準備 \(mode.rawValue) 專案交接預覽，包含 \(handoff.selectedTurns.count) 個已同意回合（摘要 \(handoff.reviewedDigest)）；尚未建立或連結專案。"
        ))
        return record.handoffs.first(where: { $0.id == handoff.id }) ?? handoff
    }

    public func createOrAttachProjectFromDiscussion(
        handoffID: UUID,
        reviewedDigest: String,
        explicitConfirmation: Bool
    ) async throws -> SessionRecord {
        guard explicitConfirmation else {
            throw AgentBridgeError.sessionMismatch("建立或連結專案前必須明確確認已檢視交接內容。")
        }
        guard let (recordID, _, initialHandoff) = try findDiscussionHandoff(id: handoffID) else {
            throw AgentBridgeError.sessionMismatch("找不到這份討論交接預覽。")
        }
        let lease = try store.acquireRunLease(for: recordID)
        defer { withExtendedLifetime(lease) {} }
        var record = try rawDiscussion(id: recordID)
        try recoverStaleDiscussionRun(&record)
        guard let handoffIndex = record.handoffs.firstIndex(where: { $0.id == handoffID }) else {
            throw AgentBridgeError.sessionMismatch("討論交接預覽已不存在。")
        }
        let handoff = record.handoffs[handoffIndex]
        guard handoff.discussionID == record.id,
              handoff.discussionRevision == record.revision,
              handoff.hasValidDigest(),
              handoff.reviewedDigest == reviewedDigest.lowercased(),
              handoff.reviewedDigest == initialHandoff.reviewedDigest else {
            throw AgentBridgeError.sessionMismatch("討論或交接內容在檢視後已改變；請重新產生交接預覽。")
        }
        guard handoff.consumedSessionID == nil else {
            throw AgentBridgeError.sessionMismatch("這份交接預覽已用於建立或連結專案。")
        }
        guard !record.status.isInFlight else {
            throw AgentBridgeError.sessionMismatch("討論仍在執行；請完成或停止回合後再轉入專案。")
        }
        guard record.linkedSessionIDs.count < 64 else {
            throw AgentBridgeError.invalidInput("此討論已連結太多專案工作階段。")
        }
        let currentSettings = try store.loadSettings()
        guard currentSettings.usageMode != .api || handoff.targetProvider == .claude || handoff.targetProvider == .local else {
            throw AgentBridgeError.sessionMismatch("目前全域模式為 API；請先切換至訂閱登入模式，再為 Codex 建立專案工作階段。")
        }
        let targetProfile = try accountProfile(id: handoff.targetProfileID)
        guard targetProfile.provider == handoff.targetProvider,
              handoff.selectedTurns.isEmpty || targetProfile.allowsSharedMemory else {
            throw AgentBridgeError.sessionMismatch("目標帳戶的共享記憶同意已變更；請重新檢視交接。")
        }
        for turn in handoff.selectedTurns {
            let sourceProfile = try accountProfile(id: turn.sourceAccountProfileID)
            guard sourceProfile.provider == turn.provider, sourceProfile.allowsSharedMemory else {
                throw AgentBridgeError.sessionMismatch("來源帳戶的共享記憶同意已變更；請重新檢視交接。")
            }
        }

        let importedMemoryTurns = handoff.selectedTurns.map { turn in
            SharedMemoryTurn(
                id: turn.id,
                provider: turn.provider,
                userText: turn.userText,
                assistantText: turn.assistantText,
                timestamp: turn.timestamp
            )
        }
        let attachSnapshot: WorkspaceSnapshot?
        switch handoff.mode {
        case .createNew:
            attachSnapshot = nil
            try SharedMemoryStore.validateImportCapacity(
                turns: importedMemoryTurns,
                repositoryPath: handoff.destinationPath
            )
        case .attachExisting:
            let current = try await workspaceManager.inspectProjectRepository(path: handoff.destinationPath)
            guard current.commit == handoff.expectedRepositoryCommit else {
                throw AgentBridgeError.sessionMismatch("目標儲存庫在預覽後已移動到其他提交；請重新檢視交接。")
            }
            attachSnapshot = current
            if !importedMemoryTurns.isEmpty {
                let destinationMemoryScope = try SharedMemoryScope(
                    repositoryPath: current.repositoryRoot.path,
                    snapshotCommit: current.commit
                )
                try sharedMemoryStore.preflightAppend(scope: destinationMemoryScope, turns: importedMemoryTurns)
            }
        }

        let previousDiscussionStatus = record.status
        record.status = .transitioning
        record.updatedAt = Date()
        record = try discussionStore.save(record)
        var transitionFinalized = false
        defer {
            if !transitionFinalized,
               var interrupted = try? discussionStore.record(id: recordID),
               interrupted.status == .transitioning {
                interrupted.status = previousDiscussionStatus
                interrupted.updatedAt = Date()
                _ = try? discussionStore.save(interrupted)
            }
        }

        let snapshot: WorkspaceSnapshot
        switch handoff.mode {
        case .createNew:
            _ = try workspaceManager.validateNewProjectDestination(path: handoff.destinationPath)
            snapshot = try await workspaceManager.createEmptyProjectRepository(path: handoff.destinationPath)
        case .attachExisting:
            guard let attachSnapshot else {
                throw AgentBridgeError.persistence("The reviewed target repository snapshot is unavailable.")
            }
            snapshot = attachSnapshot
        }

        let memoryScope = try SharedMemoryScope(
            repositoryPath: snapshot.repositoryRoot.path,
            snapshotCommit: snapshot.commit
        )
        if !handoff.selectedTurns.isEmpty {
            let consentProfileIDs = Set(
                [handoff.targetProfileID] + handoff.selectedTurns.map(\.sourceAccountProfileID)
            )
            try accountProfileStore.withSharedMemoryConsent(profileIDs: consentProfileIDs) {
                try sharedMemoryStore.appendTurns(scope: memoryScope, turns: importedMemoryTurns)
            }
        }
        let session = try await createSession(
            sourcePath: snapshot.repositoryRoot.path,
            provider: handoff.targetProvider,
            accessMode: handoff.accessMode,
            snapshotCommit: snapshot.commit,
            accountProfileID: handoff.targetProfileID
        )
        guard session.snapshotCommit == snapshot.commit else {
            throw AgentBridgeError.sessionMismatch("專案工作階段未固定在已檢視的目標提交。")
        }
        record.handoffs[handoffIndex].consumedSessionID = session.id
        if !record.linkedSessionIDs.contains(session.id) { record.linkedSessionIDs.append(session.id) }
        record.status = previousDiscussionStatus
        record.updatedAt = Date()
        record = try discussionStore.save(record)
        try store.appendEvent(AuditEvent(
            sessionID: recordID,
            kind: "discussion.project.linked",
            message: "已將原討論連結至 \(handoff.mode.rawValue) 專案工作階段 \(session.id.uuidString.lowercased())；原討論及其逐字稿保留。"
        ))
        transitionFinalized = true
        return session
    }

    private func requireDiscussionProfile(_ record: DiscussionRecord) throws -> AccountProfile {
        let profile = try accountProfile(id: record.accountProfileID)
        guard profile.provider == record.provider else {
            throw AccountProfileError.providerMismatch(record.accountProfileID, record.provider)
        }
        return profile
    }

    func recoverStaleDiscussionRun(_ record: inout DiscussionRecord) throws {
        guard record.status.isInFlight else { return }
        let recoveredTransition = record.status == .transitioning
        record.status = .failed
        record.updatedAt = Date()
        record = try discussionStore.save(record)
        try store.appendEvent(AuditEvent(
            sessionID: record.id,
            kind: recoveredTransition ? "discussion.transition.recovered" : "discussion.run.recovered",
            message: recoveredTransition
                ? "前一次專案交接中斷；原討論保留並可繼續。"
                : "前一個討論回合已中斷；保留逐字稿並允許繼續。"
        ))
    }

    private func discussionPrompt(
        record: DiscussionRecord,
        currentTurnID: UUID?,
        destinationProfile: AccountProfile,
        currentPrompt: String,
        localSettings: LocalModelSettings? = nil
    ) throws -> CompressedContext {
        var eligible: [ContextCompressionTurn] = []
        if destinationProfile.allowsSharedMemory {
            for turn in record.turns where turn.id != currentTurnID {
                guard turn.isShareable, turn.sourceSharedMemoryConsent,
                      let assistantText = turn.assistantText, !assistantText.isEmpty else { continue }
                guard let sourceProfile = try? accountProfile(id: turn.accountProfileID),
                      sourceProfile.provider == turn.provider,
                      sourceProfile.allowsSharedMemory else { continue }
                eligible.append(ContextCompressionTurn(
                    id: turn.id.uuidString.lowercased(),
                    provider: turn.provider.rawValue,
                    userText: turn.userText,
                    assistantText: assistantText,
                    timestamp: turn.timestamp
                ))
            }
        }
        var pinnedNotes: [String] = []
        let legacyMarker = "…[truncated]…"
        let legacyLossDetected = record.transcriptWasTruncated
            || record.turns.contains(where: {
                $0.userText.contains(legacyMarker) || ($0.assistantText?.contains(legacyMarker) == true)
            })
        if legacyLossDetected {
            pinnedNotes.append("\(Self.legacyTruncationNotice) This discussion transcript was already marked truncated by an older storage version; missing original turns cannot be recovered.")
        }
        let policy = try contextCompressionPolicy(
            currentPrompt: currentPrompt,
            localSettings: localSettings ?? (destinationProfile.provider == .local ? store.loadSettings().localModel : nil)
        )
        return ContextCompressor.compress(
            turns: eligible,
            pinnedNotes: pinnedNotes,
            currentPrompt: currentPrompt,
            policy: policy
        )
    }

    private func findDiscussionHandoff(
        id: UUID
    ) throws -> (UUID, DiscussionRecord, DiscussionProjectHandoff)? {
        for record in try discussionStore.list() {
            if let handoff = record.handoffs.first(where: { $0.id == id }) {
                return (record.id, record, handoff)
            }
        }
        return nil
    }

    private static func boundedDiscussionText(_ value: String) throws -> String {
        let text = OutputRedactor.redact(value)
        let maximumBytes = DiscussionStore.maximumTextBytes
        guard text.utf8.count <= maximumBytes else {
            throw AgentBridgeError.invalidInput("討論回合文字超過 \(maximumBytes / 1_024) KiB 儲存上限；已保留原文，請縮短後再送出。")
        }
        return text
    }

    private func makeFreshDiscussionTemporaryDirectory(label: String) throws -> URL {
        guard let workspaceRoot = store.workspaceRootURL else {
            throw AgentBridgeError.invalidInput("尚未設定工作區資料根目錄；請先選擇使用者資料資料夾。")
        }
        let root = workspaceRoot.appendingPathComponent("tmp", isDirectory: true)
        try AuditStore.createPrivateDirectory(root)
        let url = root.appendingPathComponent("\(label)-\(UUID().uuidString.lowercased())", isDirectory: true)
        guard mkdir(url.path, mode_t(0o700)) == 0 else {
            throw AgentBridgeError.persistence("無法建立全新的討論工作資料夾。")
        }
        guard chmod(url.path, mode_t(0o700)) == 0 else {
            try? FileManager.default.removeItem(at: url)
            throw AgentBridgeError.persistence("無法設定討論工作資料夾權限。")
        }
        return url
    }

    private func checkDiscussionAuthentication(
        profile: AccountProfile,
        executable: URL
    ) async throws -> AuthAssessment {
        let temp = try makeFreshDiscussionTemporaryDirectory(
            label: "discussion-auth-\(profile.id.uuidString.lowercased())"
        )
        defer { try? FileManager.default.removeItem(at: temp) }
        let environment = try providerEnvironment(profile: profile, privateTemporaryDirectory: temp)
        return try await adapter.checkAuthentication(
            provider: profile.provider,
            executableURL: executable,
            environment: environment,
            temporaryDirectory: temp
        )
    }
}
