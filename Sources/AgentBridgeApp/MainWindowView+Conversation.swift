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
                ContentUnavailableView("Select or Create a Session", systemImage: "bubble.left.and.bubble.right", description: Text("Choose a Git repository first, then start a project conversation pinned to a commit."))
                    .frame(maxWidth: .infinity, maxHeight: model.terminal.terminalLaunch == nil ? .infinity : 110)
            }
            if !model.setupWizard.isPresented, let launch = model.terminal.terminalLaunch {
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
                Button("Local Terminal") { model.terminal.openLocalShell() }
                    .disabled(model.terminal.terminalLaunch != nil)
            }
            if session.provider != .local && session.policy.accessMode == .interactiveManualApproval {
                Button("Open Embedded Terminal") { model.terminal.openEmbeddedInteractiveTerminal() }
                    .disabled(model.terminal.terminalRunning)
                if session.status == .running { Button("Cancel Session") { model.cancelSession(session.id) } }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
    }

    func memoryPanel(_ session: SessionRecord) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Shared Project Memory", systemImage: "brain.head.profile")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let memory = model.memorySnapshot {
                        Text(String(format: model.localized("Revision %@ · %@ turns%@"),
                                    String(memory.revision),
                                    String(memory.turns.count),
                                    memory.wasTruncated ? model.localized(" · showing recent content") : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let memory = model.memorySnapshot {
                    Text(String(format: model.localized("Source %@ · Pinned commit %@"),
                                URL(fileURLWithPath: memory.scope.repositoryPath).lastPathComponent,
                                String(memory.scope.snapshotCommit.prefix(12))))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                if let profile = model.boundProfile(for: session), !profile.allowsSharedMemory {
                    Label("This account has not consented to sharing memory with assistants. Enable “Allow this account to load and save shared project memory” on the left to share it.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                DisclosureGroup("Memory Notes and Terminal Handoff") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("AgentBridge automatically saves successfully completed turns from app chats. TUI content in the embedded terminal is not imported; write key points here when handing work to another assistant.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $model.memoryNotes)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 54, maxHeight: 90)
                        HStack {
                            Button("Save Notes") { model.saveMemoryNotes() }
                            Button("Clear Memory for This Commit…", role: .destructive) { model.confirmClearMemory = true }
                            Spacer()
                        }
                    }
                    .padding(.top, 5)
                }
                DisclosureGroup("Explicit handoff to another commit") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Only the App chat turns and notes you select are copied. The target session’s bound account must allow shared memory. The handoff records its source and target commits and is added to the target prompt as explicit untrusted historical context.")
                            .font(.caption2).foregroundStyle(.secondary)
                        if model.memoryHandoffTargets.isEmpty {
                            Text("Choose another session for the same repository at a different commit.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Picker("Target session", selection: $model.memoryHandoffTargetSessionID) {
                                Text("Choose a target").tag(UUID?.none)
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
                                Text("Select conversation turns to carry forward")
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
                            Toggle("Include the currently saved project notes", isOn: $model.includeMemoryNotes)
                                .font(.caption)
                            Button("Create explicit memory handoff") { model.carryForwardSelectedMemory() }
                                .disabled(model.memoryHandoffTargetSessionID == nil || !model.selectedMemoryTargetCanReceiveHandoff || (model.selectedMemoryTurnIDs.isEmpty && !model.includeMemoryNotes))
                        }
                        if !model.projectMemoryHandoffs.isEmpty {
                            Divider()
                            Text("Handoffs for this repository")
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
                            Text(model.localizedFormat("value.session %@", task.sessionID.uuidString.lowercased()))
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
                Button("Import descriptor JSON…") { model.extensions.isImportingExtensionDescriptor = true }
                if model.extensions.extensionDescriptors.isEmpty {
                    Text("No descriptors imported.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker(model.localized("value.descriptor"), selection: Bindable(model.extensions).selectedExtensionID) {
                        Text("Select descriptor").tag("")
                        ForEach(model.extensions.extensionDescriptors) { descriptor in
                            Text("\(descriptor.kind.rawValue.uppercased()) · \(descriptor.name)").tag(descriptor.id)
                        }
                    }
                    if let descriptor = model.extensions.selectedExtensionDescriptor {
                        Text(verbatim: "\(descriptor.id) · v\(descriptor.version)\n\(descriptor.summary)")
                            .font(.caption2).textSelection(.enabled)
                        Text("Requested: \(descriptor.requestedPermissions.map(\.rawValue).joined(separator: ", "))")
                            .font(.system(size: 8, design: .monospaced)).foregroundStyle(.secondary)
                        if let grant = model.extensions.selectedExtensionGrant {
                            Text("Current project grant: \(grant.permissions.map(\.rawValue).joined(separator: ", "))")
                                .font(.caption2).foregroundStyle(.green)
                        } else {
                            Text("No grant for this project.").font(.caption2).foregroundStyle(.secondary)
                        }
                        ForEach(ExtensionPermission.allCases, id: \.self) { permission in
                            Toggle(permission.rawValue, isOn: Binding(
                                get: { model.extensions.selectedExtensionPermissions.contains(permission) },
                                set: { enabled in
                                    if enabled { model.extensions.selectedExtensionPermissions.insert(permission) }
                                    else { model.extensions.selectedExtensionPermissions.remove(permission) }
                                }
                            ))
                            .font(.caption2)
                            .disabled(!descriptor.requestedPermissions.contains(permission))
                        }
                        Text("Allowed relative paths · one normalized path per line")
                            .font(.caption2)
                        TextEditor(text: Bindable(model.extensions).extensionPathScopesText).frame(minHeight: 38, maxHeight: 70)
                        Text("Allowed exact hostnames · one per line")
                            .font(.caption2)
                        TextEditor(text: Bindable(model.extensions).extensionHostScopesText).frame(minHeight: 38, maxHeight: 70)
                        HStack {
                            Button("Grant selected scopes") { model.extensions.grantSelectedExtension() }
                            Button("Revoke for this project", role: .destructive) { model.extensions.revokeSelectedExtension() }
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
                            messageBubble(label: model.localized("You"), text: turn.userText, alignment: .trailing, color: Color.accentColor.opacity(0.12), id: "user-\(turn.id)")
                            messageBubble(label: turn.provider.rawValue.capitalized, text: turn.assistantText, alignment: .leading, color: Color(nsColor: .controlBackgroundColor), id: "assistant-\(turn.id)")
                        }
                    } else {
                        ContentUnavailableView("Start a Project Conversation", systemImage: "text.bubble", description: Text("Successfully completed conversations are saved to shared memory for this source repository and pinned commit."))
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
                Label("Claude API calls incur charges; enter a budget and confirm every run.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                HStack {
                    TextField("Budget for This Run (USD)", text: $model.apiBudget).frame(width: 160)
                    SecureField("Anthropic API Key (held in memory only)", text: $model.apiKey)
                    Toggle("Confirm This Paid Call", isOn: $model.confirmAPIRun).toggleStyle(.checkbox)
                }
                if let reservedUSD = model.apiReservationPreviewUSD {
                    Text(String(format: model.localized("Reserves US$%.2f (twice this run's budget) before launch; the difference is released when the actual cost is settled."), reservedUSD))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("Cancelling a run cannot reverse Anthropic charges that have already accrued.")
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
                    Button(model.localized(model.isClaudeAPIRunContext ? "Run Claude API" : (session.provider == .local ? "Send to local model" : "Send"))) {
                        submitProjectPrompt(session)
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canStartAnotherRun || model.isSwitchingTarget || isLoadingContextPreview || model.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (model.settings.usageMode == .api && session.provider != .local && (!model.isClaudeAPIRunContext || model.usage.budgetSnapshot == nil)) || (model.isClaudeAPIRunContext && model.usage.usageControls.disableFutureAPI) || (session.provider == .local && model.localModelSettingsAreDirty))
                    if model.selectedSessionIsRunning { Button("Cancel") { model.cancelRun() } }
                }
            }
            Text(model.localized(session.provider == .local
                ? "Prompts and responses are stored in shared memory only after a successful turn. Context compression preserves recent turns and the exact current request."
                : "Prompts and responses enter shared memory only after a successful completion. The key is not saved."))
                .font(.caption2).foregroundStyle(.secondary)
            if session.provider == .local && model.localModelSettingsAreDirty {
                Label(model.localized("Save local model settings before sending."), systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
            }
            if session.sourceWasDirty {
                Text("The source has uncommitted changes. This conversation's pinned workspace does not include them.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 12))
        .sheet(isPresented: $isShowingContextPreview) {
            if let contextPreview {
                ContextPreviewSheet(model: model, preview: contextPreview, settings: contextPreviewSettings)
                    .frame(minWidth: 760, minHeight: 620)
                    .environment(\.locale, model.appLanguage.locale)
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
            ContentUnavailableView("Interactive Session", systemImage: "terminal", description: Text("This session uses the provider's native interactive terminal. TUI conversations are not imported automatically; write key points in the shared memory notes above."))
                .frame(maxHeight: 200)
            HStack {
                Text("Approved commands may access files outside the workspace or the network.")
                    .font(.caption).foregroundStyle(.orange)
                Spacer()
                Button("Open Embedded Terminal") { model.terminal.openEmbeddedInteractiveTerminal() }
                    .disabled(model.terminal.terminalRunning)
                if session.status == .running { Button("Cancel Session") { model.cancelSession(session.id) } }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
