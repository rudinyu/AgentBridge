import AppKit
import AgentBridgeCore
import SwiftUI

extension MainWindowView {
    var conversationPanel: some View {
        VStack(spacing: 10) {
            if let session = model.selectedSession {
                conversationHeader(session)
                memoryPanel(session)
                if session.provider == .local {
                    chatTimeline
                    composer(session)
                    activityTimeline
                } else if session.policy.accessMode == .readOnly {
                    chatTimeline
                    composer(session)
                    activityTimeline
                } else if session.policy.accessMode == .isolatedChanges {
                    changeWorkflowPanel(session)
                    activityTimeline
                } else {
                    interactivePanel(session)
                    activityTimeline
                }
            } else {
                ContentUnavailableView("選擇或建立工作階段", systemImage: "bubble.left.and.bubble.right", description: Text("先選擇 Git 儲存庫，再開始一段固定版本的專案對話。"))
                    .frame(maxWidth: .infinity, maxHeight: model.terminalLaunch == nil ? .infinity : 110)
            }
            if !model.setupWizard.isPresented, let launch = model.terminalLaunch {
                EmbeddedTerminalPanel(model: model, launch: launch)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func conversationHeader(_ session: SessionRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.provider == .codex ? "sparkle" : (session.provider == .local ? "desktopcomputer" : "message"))
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
            if session.provider == .local {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.settings.localModel.model.isEmpty ? model.localized("No model selected") : model.settings.localModel.model)
                        .font(.caption.weight(.medium))
                    Text(model.settings.localModel.endpoint)
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Text(model.localized(model.localModelStatus))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Button("本機終端機") { model.openLocalShell() }
                    .disabled(model.terminalLaunch != nil)
            }
            if session.provider != .local && session.policy.accessMode == .interactiveManualApproval {
                Button("開啟內嵌終端機") { model.openEmbeddedInteractiveTerminal() }
                    .disabled(model.terminalRunning)
                if session.status == .running { Button("取消工作階段") { model.cancelSession(session.id) } }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
    }

    func memoryPanel(_ session: SessionRecord) -> some View {
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
                if let profile = model.boundProfile(for: session), !profile.allowsSharedMemory {
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
                DisclosureGroup("明確交接至另一個提交版本") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("只會複製你選取的 App 聊天回合與備註。目標工作階段綁定的帳戶必須允許共用記憶；交接會以來源與目標提交版本標記，並作為明確的未信任歷史內容附加到目標提示。")
                            .font(.caption2).foregroundStyle(.secondary)
                        if model.memoryHandoffTargets.isEmpty {
                            Text("需要同一個儲存庫的另一個不同提交版本工作階段。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Picker("目標工作階段", selection: $model.memoryHandoffTargetSessionID) {
                                Text("選擇目標").tag(UUID?.none)
                                ForEach(model.memoryHandoffTargets) { target in
                                    Text("\(target.provider.rawValue.capitalized) · \(target.snapshotCommit.prefix(12)) · \(model.profileName(for: target))")
                                        .tag(Optional(target.id))
                                }
                            }
                            if model.memoryHandoffTargetSessionID != nil && !model.selectedMemoryTargetCanReceiveHandoff {
                                Label("Select the target session’s bound account and allow shared memory before creating this handoff.", systemImage: "lock.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            if let turns = model.memorySnapshot?.turns, !turns.isEmpty {
                                Text("選取要帶入的對話回合")
                                    .font(.caption.weight(.semibold))
                                ForEach(turns) { turn in
                                    Toggle(isOn: Binding(
                                        get: { model.selectedMemoryTurnIDs.contains(turn.id) },
                                        set: { selected in
                                            if selected { model.selectedMemoryTurnIDs.insert(turn.id) }
                                            else { model.selectedMemoryTurnIDs.remove(turn.id) }
                                        }
                                    )) {
                                        Text("\(turn.provider.rawValue.capitalized) · \(turn.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(turn.userText.prefix(72))")
                                            .font(.caption2).lineLimit(2)
                                    }
                                }
                            }
                            Toggle("包含目前已儲存的專案備註", isOn: $model.includeMemoryNotes)
                                .font(.caption)
                            Button("建立明確記憶交接") { model.carryForwardSelectedMemory() }
                                .disabled(model.memoryHandoffTargetSessionID == nil || !model.selectedMemoryTargetCanReceiveHandoff || (model.selectedMemoryTurnIDs.isEmpty && !model.includeMemoryNotes))
                        }
                        if !model.projectMemoryHandoffs.isEmpty {
                            Divider()
                            Text("此儲存庫的交接記錄")
                                .font(.caption.weight(.semibold))
                            ForEach(model.projectMemoryHandoffs.prefix(5)) { handoff in
                                Text("\(handoff.sourceCommit.prefix(12)) → \(handoff.targetCommit.prefix(12)) · \(handoff.turns.count) turns · \(handoff.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 5)
                }
            }
            .padding(.vertical, 2)
        }
    }

    var activityTimeline: some View {
        GroupBox("Activity timeline") {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ordered, redacted audit events. Progress, responses, and claims show what the underlying CLI reported; verification includes the process exit code and elapsed time.")
                    .font(.caption2).foregroundStyle(.secondary)
                if model.events.isEmpty {
                    Text("No activity recorded yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(model.events.sorted(by: { $0.timestamp < $1.timestamp }).suffix(80)) { event in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(event.kind).font(.caption.weight(.semibold).monospaced())
                                        Spacer()
                                        Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Text(event.message).font(.caption2).textSelection(.enabled)
                                }
                                .padding(7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
    }

    var taskBoardPanel: some View {
        GroupBox("Parallel session task records") {
            VStack(alignment: .leading, spacing: 6) {
                Text("These records track individual session launches. Autonomous Workflow creates a separate approved plan, coordinates several role profiles, and has its own review and cancellation state.")
                    .font(.caption2).foregroundStyle(.secondary)
                if model.taskRecords.isEmpty {
                    Text("No run records yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.taskRecords.prefix(12)) { task in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(task.status.rawValue).font(.caption.weight(.semibold))
                                Text(task.approvalState.rawValue).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                if task.status == .inProgress {
                                    Button("Cancel") { model.cancelSession(task.sessionID) }
                                }
                            }
                            Text(task.progressSummary).font(.caption2).textSelection(.enabled)
                            Text("Session \(task.sessionID.uuidString.lowercased())")
                                .font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                            ForEach(task.references, id: \.self) { reference in
                                Text("\(reference.kind.rawValue): \(reference.value)")
                                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }

    var extensionPolicyPanel: some View {
        GroupBox("Skills / MCP policy metadata") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Imports are inert descriptors. Grants are narrow per-project policy metadata only; they do not activate or execute provider extensions. Import never runs scripts.")
                    .font(.caption2).foregroundStyle(.orange)
                Button("Import descriptor JSON…") { model.isImportingExtensionDescriptor = true }
                if model.extensionDescriptors.isEmpty {
                    Text("No descriptors imported.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Descriptor", selection: $model.selectedExtensionID) {
                        Text("Select descriptor").tag("")
                        ForEach(model.extensionDescriptors) { descriptor in
                            Text("\(descriptor.kind.rawValue.uppercased()) · \(descriptor.name)").tag(descriptor.id)
                        }
                    }
                    if let descriptor = model.selectedExtensionDescriptor {
                        Text("\(descriptor.id) · v\(descriptor.version)\n\(descriptor.summary)")
                            .font(.caption2).textSelection(.enabled)
                        Text("Requested: \(descriptor.requestedPermissions.map(\.rawValue).joined(separator: ", "))")
                            .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                        if let grant = model.selectedExtensionGrant {
                            Text("Current project grant: \(grant.permissions.map(\.rawValue).joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.green)
                        } else {
                            Text("No grant for this project.").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(ExtensionPermission.allCases, id: \.self) { permission in
                            Toggle(permission.rawValue, isOn: Binding(
                                get: { model.selectedExtensionPermissions.contains(permission) },
                                set: { enabled in
                                    if enabled { model.selectedExtensionPermissions.insert(permission) }
                                    else { model.selectedExtensionPermissions.remove(permission) }
                                }
                            ))
                            .font(.caption2)
                            .disabled(!descriptor.requestedPermissions.contains(permission))
                        }
                        Text("Allowed relative paths · one normalized path per line")
                            .font(.caption2)
                        TextEditor(text: $model.extensionPathScopesText).frame(minHeight: 38, maxHeight: 70)
                        Text("Allowed exact hostnames · one per line")
                            .font(.caption2)
                        TextEditor(text: $model.extensionHostScopesText).frame(minHeight: 38, maxHeight: 70)
                        HStack {
                            Button("Grant selected scopes") { model.grantSelectedExtension() }
                            Button("Revoke for this project", role: .destructive) { model.revokeSelectedExtension() }
                        }
                    }
                }
            }
        }
    }

    var chatTimeline: some View {
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
                    if model.selectedSessionIsRunning {
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

    func messageBubble(label: String, text: String, alignment: HorizontalAlignment, color: Color, id: String) -> some View {
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

    func composer(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isClaudeAPIRunContext {
                Label("Claude API 會產生費用；每次執行都要輸入預算與確認。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                HStack {
                    TextField("本次預算（USD）", text: $model.apiBudget).frame(width: 160)
                    SecureField("Anthropic API key（只保留在記憶體）", text: $model.apiKey)
                    Toggle("確認這次付費呼叫", isOn: $model.confirmAPIRun).toggleStyle(.checkbox)
                }
                if let reservedUSD = model.apiReservationPreviewUSD {
                    Text(String(format: model.localized("執行前會預留 US$%.2f（本次預算的兩倍）；結算實際費用後釋放差額。"), reservedUSD))
                        .font(.caption2).foregroundStyle(.secondary)
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
                    .disabled(isLoadingContextPreview || model.selectedSessionIsRunning)
                VStack(spacing: 7) {
                    Button {
                        loadProjectContextPreview(session, showEvenWhenSafe: true)
                    } label: {
                        if isLoadingContextPreview { ProgressView().controlSize(.small) }
                        else { Label(model.localized("Preview context"), systemImage: "text.magnifyingglass") }
                    }
                    .disabled(!model.canStartAnotherRun || model.isSwitchingTarget || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (session.provider == .local && model.localModelSettingsAreDirty) || isLoadingContextPreview)
                    Button(model.localized(model.isClaudeAPIRunContext ? "執行 Claude API" : (session.provider == .local ? "Send to local model" : "傳送"))) {
                        submitProjectPrompt(session)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartAnotherRun || model.isSwitchingTarget || isLoadingContextPreview || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.settings.usageMode == .api && session.provider != .local && (!model.isClaudeAPIRunContext || model.usage.budgetSnapshot == nil)) || (model.isClaudeAPIRunContext && model.usage.usageControls.disableFutureAPI) || (session.provider == .local && model.localModelSettingsAreDirty))
                    if model.selectedSessionIsRunning { Button("取消") { model.cancelRun() } }
                }
            }
            Text(model.localized(session.provider == .local
                ? "Prompts and responses are stored in shared memory only after a successful turn. Context compression preserves recent turns and the exact current request."
                : "提示和回應只在成功完成後進入共用記憶；金鑰不會保存。"))
                .font(.caption2).foregroundStyle(.secondary)
            if session.provider == .local && model.localModelSettingsAreDirty {
                Label(model.localized("Save local model settings before sending."), systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if session.sourceWasDirty {
                Text("來源有未提交變更；此對話固定的工作區不包含那些變更。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $isShowingContextPreview) {
            if let contextPreview {
                ContextPreviewSheet(model: model, preview: contextPreview, settings: contextPreviewSettings)
                    .frame(minWidth: 760, minHeight: 620)
            }
        }
    }

    func loadProjectContextPreview(_ session: SessionRecord, showEvenWhenSafe: Bool) {
        let currentPrompt = model.prompt
        guard !currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoadingContextPreview = true
        Task { @MainActor in
            defer { isLoadingContextPreview = false }
            do {
                let preview = try await model.previewProjectContext(sessionID: session.id, currentPrompt: currentPrompt)
                contextPreview = preview
                contextPreviewSettings = session.provider == .local ? model.settings.localModel : nil
                if showEvenWhenSafe || preview.requiresReview { isShowingContextPreview = true }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    func submitProjectPrompt(_ session: SessionRecord) {
        guard !model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard session.provider != .local || !model.localModelSettingsAreDirty else {
            model.errorMessage = model.localized("Save local model settings before sending.")
            return
        }
        let currentPrompt = model.prompt
        isLoadingContextPreview = true
        Task { @MainActor in
            defer { isLoadingContextPreview = false }
            do {
                let preview = try await model.previewProjectContext(sessionID: session.id, currentPrompt: currentPrompt)
                if preview.requiresReview {
                    contextPreview = preview
                    contextPreviewSettings = session.provider == .local ? model.settings.localModel : nil
                    isShowingContextPreview = true
                    return
                }
                model.runPrompt()
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    func interactivePanel(_ session: SessionRecord) -> some View {
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
}
