import AppKit
import AgentBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct DiscussionChatView: View {
    @Bindable var model: AppModel
    let discussionID: UUID
    let onOpenProject: (SessionRecord) -> Void

    @State private var prompt = ""
    @State private var isShareable = true
    @State private var isShowingHandoffReview = false
    @State private var isShowingContextPreview = false
    @State private var isLoadingContextPreview = false
    @State private var contextPreview: ContextCompressionPreview?
    @State private var contextPreviewSettings: LocalModelSettings?
    @State private var handoffMode: DiscussionProjectMode = .createNew

    private var discussion: DiscussionRecord? {
        model.chats.discussions.first(where: { $0.id == discussionID })
    }

    private var isRunning: Bool { model.chats.isDiscussionRunning(id: discussionID) }
    private var isBusy: Bool { isRunning || discussion?.status == .transitioning }

    private var currentProfileAllowsSharing: Bool {
        guard let discussion else { return false }
        return model.profileAllowsSharedMemory(provider: discussion.provider, profileID: discussion.accountProfileID)
    }

    private func isSourceProfileCurrentlyConsented(_ turn: DiscussionTurn) -> Bool {
        turn.sourceSharedMemoryConsent && turn.isShareable
            && model.profileAllowsSharedMemory(provider: turn.provider, profileID: turn.accountProfileID)
    }

    private func turnIsShareable(_ turn: DiscussionTurn) -> Bool {
        currentProfileAllowsSharing && isSourceProfileCurrentlyConsented(turn)
    }

    init(model: AppModel, discussionID: UUID, onOpenProject: @escaping (SessionRecord) -> Void) {
        self.model = model
        self.discussionID = discussionID
        self.onOpenProject = onOpenProject
        let record = model.chats.discussions.first(where: { $0.id == discussionID })
        _isShareable = State(initialValue: record.map {
            model.profileAllowsSharedMemory(provider: $0.provider, profileID: $0.accountProfileID)
        } ?? false)
    }

    var body: some View {
        Group {
            if let discussion {
                VStack(spacing: 12) {
                    header(discussion)
                    contextNotice(discussion)
                    transcript(discussion)
                    composer(discussion)
                }
            } else {
                ContentUnavailableView("Chat unavailable", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .sheet(isPresented: $isShowingHandoffReview) {
            DiscussionHandoffReviewView(
                model: model,
                discussionID: discussionID,
                initialMode: handoffMode,
                onOpenProject: onOpenProject
            )
            .frame(minWidth: 760, minHeight: 640)
        }
        .sheet(isPresented: $isShowingContextPreview) {
            if let contextPreview {
                ContextPreviewSheet(model: model, preview: contextPreview, settings: contextPreviewSettings)
                    .frame(minWidth: 760, minHeight: 620)
            }
        }
        .onChange(of: discussion?.accountProfileID) { _, _ in
            isShareable = currentProfileAllowsSharing
        }
        .onChange(of: discussion?.provider) { _, _ in
            isShareable = currentProfileAllowsSharing
        }
    }

    private func header(_ discussion: DiscussionRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: discussion.provider == .codex ? "sparkle" : (discussion.provider == .local ? "desktopcomputer" : "message"))
                    .font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat")
                        .font(.headline)
                    Text(model.localizedFormat(
                        "%@ · %@ turns",
                        discussion.updatedAt.formatted(date: .abbreviated, time: .shortened),
                        String(discussion.turns.count)
                    ))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusLabel(discussion)
                if isRunning {
                    Button("Cancel") { model.chats.cancelDiscussion(id: discussion.id) }
                        .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 10) {
                Picker("Provider", selection: Binding(
                    get: { discussion.provider },
                    set: { provider in
                        model.chats.setDiscussionProvider(id: discussion.id, provider: provider)
                        if let updated = model.chats.discussions.first(where: { $0.id == discussion.id }) {
                            isShareable = model.profileAllowsSharedMemory(
                                provider: updated.provider,
                                profileID: updated.accountProfileID
                            )
                        }
                    }
                )) {
                    Text("Codex").tag(AgentProvider.codex)
                    Text("Claude").tag(AgentProvider.claude)
                    Text("Local").tag(AgentProvider.local)
                }
                .pickerStyle(.menu)
                .frame(width: 150)
                .disabled(isBusy || model.chats.hasActiveDiscussionOperation)

                Picker(discussion.provider == .local ? "Memory account" : "Account", selection: Binding(
                    get: { discussion.accountProfileID },
                    set: { profileID in
                        model.chats.setDiscussionTarget(id: discussion.id, provider: discussion.provider, profileID: profileID)
                        isShareable = model.profileAllowsSharedMemory(provider: discussion.provider, profileID: profileID)
                    }
                )) {
                    ForEach(model.accountProfiles[discussion.provider] ?? []) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 240)
                .disabled(isBusy || model.chats.hasActiveDiscussionOperation)

                if discussion.provider == .local {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(model.localizedFormat("Local model · %@", model.settings.localModel.model.isEmpty
                            ? model.localized("No model selected")
                            : model.settings.localModel.model), systemImage: "desktopcomputer")
                            .font(.caption)
                        Text(model.settings.localModel.endpoint)
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text(model.localized(model.localModelStatus))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Label("Official CLI subscription", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Create Git Project…") { presentHandoffReview(.createNew) }
                    .disabled(isBusy || model.chats.hasActiveDiscussionOperation)
                Button("Link Existing Project…") { presentHandoffReview(.attachExisting) }
                    .disabled(isBusy || model.chats.hasActiveDiscussionOperation)
            }

            Text(discussion.provider == .local
                ? "Changing provider or account updates this chat only. Local mode uses the configured loopback model and does not use API keys, provider subscriptions, or cloud fallback."
                : "Changing provider or account updates this chat only. Discussions use official CLI subscription sign-in and never use Claude API billing.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func statusLabel(_ discussion: DiscussionRecord) -> some View {
        if isRunning {
            Label("Responding", systemImage: "ellipsis.bubble")
                .font(.caption).foregroundStyle(.tint)
        } else {
            switch discussion.status {
            case .ready:
                Label("Ready", systemImage: "circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .running:
                Label("Responding", systemImage: "ellipsis.bubble")
                    .font(.caption).foregroundStyle(.tint)
            case .transitioning:
                Label("Creating project session", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption).foregroundStyle(.tint)
            case .completed:
                Label("Complete", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed:
                Label("Failed", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            case .cancelled:
                Label("Cancelled", systemImage: "stop.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func contextNotice(_ discussion: DiscussionRecord) -> some View {
        if !currentProfileAllowsSharing {
            Label("This account has not enabled shared memory. New turns remain in this transcript and will not be loaded into future provider context or included in a project handoff.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else if discussion.transcriptWasTruncated {
            Label("This transcript was shortened to stay within the local storage limit.", systemImage: "text.badge.minus")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func transcript(_ discussion: DiscussionRecord) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if discussion.turns.isEmpty {
                        ContentUnavailableView(
                            "What would you like to discuss?",
                            systemImage: "bubble.left",
                            description: Text("This conversation is independent of any Git project. You can review a handoff before creating or linking a project.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 230)
                    }
                    ForEach(discussion.turns) { turn in
                        turnBubble(turn)
                    }
                    if isBusy, let progress = model.chats.discussionProgress[discussion.id], !progress.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(model.localized(progress))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .id("discussion-progress")
                    }
                    Color.clear.frame(height: 1).id("discussion-bottom")
                }
                .padding(.vertical, 8)
            }
            .onChange(of: discussion.turns.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("discussion-bottom", anchor: .bottom) }
            }
            .onChange(of: discussion.updatedAt) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("discussion-bottom", anchor: .bottom) }
            }
            .onChange(of: model.chats.discussionProgress[discussion.id]) { _, value in
                if value != nil {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("discussion-bottom", anchor: .bottom) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func turnBubble(_ turn: DiscussionTurn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Spacer(minLength: 80)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("You").font(.caption.weight(.semibold))
                        Spacer()
                        Text(turn.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(turn.userText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Label(
                        turnIsShareable(turn) ? "Available for future context and handoff" : "Transcript only",
                        systemImage: turnIsShareable(turn) ? "arrow.triangle.2.circlepath" : "lock"
                    )
                    .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(model.localizedFormat(
                            "%@ · %@",
                            turn.provider.rawValue.capitalized,
                            model.profileName(for: turn.provider, profileID: turn.accountProfileID)
                        ))
                            .font(.caption.weight(.semibold))
                        Spacer()
                    }
                    if let assistantText = turn.assistantText {
                        Text(assistantText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if isBusy, discussion?.turns.last?.id == turn.id {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Waiting for the response…").foregroundStyle(.secondary)
                        }
                    } else {
                        Label("No completed response was saved for this turn.", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.54), in: RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 80)
            }
        }
    }

    private func composer(_ discussion: DiscussionRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $prompt)
                .font(.body)
                .frame(minHeight: 78, maxHeight: 150)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .disabled(isBusy || model.chats.hasActiveDiscussionOperation || isLoadingContextPreview)
                .accessibilityLabel("Message")

            HStack(alignment: .center, spacing: 10) {
                Toggle("Use this turn in future context and project handoff", isOn: $isShareable)
                    .font(.caption)
                    .disabled(!currentProfileAllowsSharing || isBusy || model.chats.hasActiveDiscussionOperation)
                if !currentProfileAllowsSharing {
                    Text("Profile consent required")
                        .font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    loadContextPreview(for: prompt, discussion: discussion, showEvenWhenSafe: true)
                } label: {
                    if isLoadingContextPreview { ProgressView().controlSize(.small) }
                    else { Label("Preview context", systemImage: "text.magnifyingglass") }
                }
                .disabled(isBusy || model.chats.hasActiveDiscussionOperation || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoadingContextPreview || (discussion.provider == .local && model.localModelSettingsAreDirty))
                if let progress = model.chats.discussionProgress[discussion.id], !progress.isEmpty, !isBusy {
                    Text(model.localized(progress))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button {
                    submitMessage(discussion)
                } label: {
                    Label("Send", systemImage: "arrow.up.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isBusy || model.chats.hasActiveDiscussionOperation || isLoadingContextPreview || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (discussion.provider == .local && model.localModelSettingsAreDirty))
            }
        }
    }

    private func loadContextPreview(for prompt: String, discussion: DiscussionRecord, showEvenWhenSafe: Bool) {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoadingContextPreview = true
        Task { @MainActor in
            defer { isLoadingContextPreview = false }
            do {
                let preview = try await model.chats.previewDiscussionContext(id: discussionID, currentPrompt: prompt)
                contextPreview = preview
                contextPreviewSettings = discussion.provider == .local ? model.settings.localModel : nil
                if showEvenWhenSafe || preview.requiresReview {
                    isShowingContextPreview = true
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func submitMessage(_ discussion: DiscussionRecord) {
        guard !isLoadingContextPreview else { return }
        guard discussion.provider != .local || !model.localModelSettingsAreDirty else {
            model.errorMessage = model.localized("Save local model settings before sending.")
            return
        }
        let message = prompt
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isLoadingContextPreview = true
        Task { @MainActor in
            defer { isLoadingContextPreview = false }
            do {
                let preview = try await model.chats.previewDiscussionContext(id: discussion.id, currentPrompt: message)
                if preview.requiresReview {
                    contextPreview = preview
                    contextPreviewSettings = discussion.provider == .local ? model.settings.localModel : nil
                    isShowingContextPreview = true
                    return
                }
                model.chats.sendDiscussionMessage(id: discussion.id, prompt: message, isShareable: isShareable) { succeeded in
                    guard succeeded,
                          model.chats.selectedDiscussionID == discussion.id,
                          prompt == message else { return }
                    prompt = ""
                }
            } catch {
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func presentHandoffReview(_ mode: DiscussionProjectMode) {
        handoffMode = mode
        isShowingHandoffReview = true
    }
}

private struct DiscussionHandoffReviewView: View {
    @Bindable var model: AppModel
    let discussionID: UUID
    let onOpenProject: (SessionRecord) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var mode: DiscussionProjectMode
    @State private var destinationPath = ""
    @State private var targetProvider: AgentProvider
    @State private var targetProfileID: UUID?
    @State private var accessMode = AccessMode.readOnly
    @State private var selectedTurnIDs: Set<UUID>
    @State private var preparedHandoff: DiscussionProjectHandoff?
    @State private var preparedInputKey: String?
    @State private var isPreparing = false
    @State private var isCreating = false
    @State private var errorMessage: String?

    private var discussion: DiscussionRecord? {
        model.chats.discussions.first(where: { $0.id == discussionID })
    }

    private var targetProfileAllowsSharing: Bool {
        guard let targetProfileID else { return false }
        return model.profileAllowsSharedMemory(provider: targetProvider, profileID: targetProfileID)
    }

    private var eligibleTurns: [DiscussionTurn] {
        guard targetProfileAllowsSharing else { return [] }
        return discussion?.turns.filter {
            $0.assistantText != nil && isSourceProfileCurrentlyConsented($0)
        } ?? []
    }

    private var targetProfiles: [AccountProfile] {
        model.accountProfiles[targetProvider] ?? []
    }

    private var latestEligibleTurnIDs: Set<UUID> {
        Set(eligibleTurns.suffix(DiscussionStore.maximumTurnsPerHandoff).map(\.id))
    }

    private func isSourceProfileCurrentlyConsented(_ turn: DiscussionTurn) -> Bool {
        turn.sourceSharedMemoryConsent && turn.isShareable
            && model.profileAllowsSharedMemory(provider: turn.provider, profileID: turn.accountProfileID)
    }

    private var currentInputKey: String {
        let revision = discussion?.revision ?? 0
        let ids = discussion?.turns.filter { selectedTurnIDs.contains($0.id) }.map { $0.id.uuidString.lowercased() }.joined(separator: ",") ?? ""
        let consent = discussion?.turns.map {
            "\($0.id.uuidString.lowercased()):\(model.profileAllowsSharedMemory(provider: $0.provider, profileID: $0.accountProfileID))"
        }.joined(separator: ",") ?? ""
        return [
            String(revision), mode.rawValue, destinationPath, targetProvider.rawValue,
            targetProfileID?.uuidString.lowercased() ?? "", ids, consent,
            String(targetProfileAllowsSharing), accessMode.rawValue
        ].joined(separator: "|")
    }

    private var previewIsCurrent: Bool {
        preparedHandoff != nil && preparedInputKey == currentInputKey
    }

    init(
        model: AppModel,
        discussionID: UUID,
        initialMode: DiscussionProjectMode,
        onOpenProject: @escaping (SessionRecord) -> Void
    ) {
        self.model = model
        self.discussionID = discussionID
        self.onOpenProject = onOpenProject
        let record = model.chats.discussions.first(where: { $0.id == discussionID })
        let targetProvider = record?.provider ?? model.chats.newDiscussionProvider
        let targetProfileID = record?.accountProfileID ?? model.chats.preferredDiscussionProfileID(for: targetProvider)
        let canShareToTarget = targetProfileID.map {
            model.profileAllowsSharedMemory(provider: targetProvider, profileID: $0)
        } ?? false
        let eligibleIDs = canShareToTarget ? Set((record?.turns.filter {
            $0.assistantText != nil && $0.sourceSharedMemoryConsent && $0.isShareable
                && model.profileAllowsSharedMemory(provider: $0.provider, profileID: $0.accountProfileID)
        }.suffix(DiscussionStore.maximumTurnsPerHandoff).map(\.id) ?? [])) : []
        _mode = State(initialValue: initialMode)
        _targetProvider = State(initialValue: targetProvider)
        _targetProfileID = State(initialValue: targetProfileID)
        _selectedTurnIDs = State(initialValue: eligibleIDs)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(mode == .createNew ? "Create a Git project" : "Link an existing Git project")
                        .font(.title2.weight(.semibold))
                    Text("Review the destination and exact discussion turns before continuing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Destination") {
                        VStack(alignment: .leading, spacing: 10) {
                            Picker("Action", selection: $mode) {
                                Text("Create new Git project").tag(DiscussionProjectMode.createNew)
                                Text("Link existing Git project").tag(DiscussionProjectMode.attachExisting)
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: mode) { _, _ in
                                destinationPath = ""
                                clearPreview()
                            }
                            HStack(spacing: 8) {
                                TextField("Absolute destination path", text: $destinationPath)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: destinationPath) { _, _ in clearPreview() }
                                Button("Choose…") { chooseDestination() }
                            }
                            Text(mode == .createNew
                                ? "Choose a new absolute folder path. AgentBridge will create the folder only after you confirm."
                                : "Choose the root of an existing local Git repository. Linking will create an isolated project session.")
                                .font(.caption).foregroundStyle(.secondary)
                            if !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               !destinationPath.hasPrefix("/") {
                                Text("Enter an absolute path beginning with /.")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        .padding(.vertical, 3)
                    }

                    projectSessionSection
                    completedTurnsSection

                    if let preparedHandoff, previewIsCurrent {
                        handoffPreview(preparedHandoff)
                    }
                    if let errorMessage {
                        Label(model.localized(errorMessage), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }

            Divider()
            HStack(spacing: 10) {
                if isPreparing || isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("Prepare preview") { preparePreview() }
                    .disabled(isPreparing || isCreating || !destinationPath.hasPrefix("/") || targetProfileID == nil || (model.settings.usageMode == .api && targetProvider == .codex))
                Button(mode == .createNew ? "Create Git Project" : "Link Existing Project") {
                    createProject()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!previewIsCurrent || isPreparing || isCreating)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(isCreating)
        .interactiveDismissDisabled(isPreparing || isCreating)
        .onChange(of: discussion?.revision) { _, _ in clearPreview() }
        .onChange(of: model.accountProfiles) { _, _ in
            selectedTurnIDs = latestEligibleTurnIDs
            clearPreview()
        }
    }

    private var projectSessionSection: some View {
        GroupBox("Project session") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Provider", selection: $targetProvider) {
                    Text("Codex").tag(AgentProvider.codex)
                    Text("Claude").tag(AgentProvider.claude)
                    Text("Local").tag(AgentProvider.local)
                }
                .onChange(of: targetProvider) { _, provider in
                    targetProfileID = model.chats.preferredDiscussionProfileID(for: provider)
                    if provider == .local { accessMode = .readOnly }
                    selectedTurnIDs = eligibleTurnIDs(for: provider, profileID: targetProfileID)
                    clearPreview()
                }
                Picker("Account profile", selection: Binding(
                    get: { targetProfileID },
                    set: {
                        targetProfileID = $0
                        selectedTurnIDs = eligibleTurnIDs(for: targetProvider, profileID: $0)
                        clearPreview()
                    }
                )) {
                    ForEach(targetProfiles) { profile in
                        Text(profile.name).tag(Optional(profile.id))
                    }
                }
                .disabled(targetProfiles.isEmpty)
                if targetProvider == .local {
                    Label("Local project chat is read-only.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Session access", selection: $accessMode) {
                        Text("Read-only").tag(AccessMode.readOnly)
                        Text("Isolated changes · review and explicit approval required").tag(AccessMode.isolatedChanges)
                            .disabled(model.settings.usageMode == .api)
                    }
                    .onChange(of: accessMode) { _, _ in clearPreview() }
                }
                sessionAccessNotice
                sessionAvailabilityNotices
            }
            .padding(.vertical, 3)
        }
    }

    @ViewBuilder
    private var sessionAccessNotice: some View {
        if targetProvider == .local {
            Label("Read-only session · local model", systemImage: "desktopcomputer")
                .font(.caption).foregroundStyle(.secondary)
        } else if accessMode == .readOnly && targetProvider == .claude && model.settings.usageMode == .api {
            Label("Claude API runs stay behind the existing budget and explicit confirmation controls. This handoff does not call the provider.", systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else if accessMode == .readOnly {
            Label("Read-only session · official CLI subscription sign-in", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Label("Each change run will require an editable plan and your explicit approval. No autonomous workflow is started.", systemImage: "checkmark.shield")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sessionAvailabilityNotices: some View {
        if model.settings.usageMode == .api && targetProvider == .codex {
            Text("Codex project sessions are unavailable while Claude API mode is selected. Switch project usage mode to subscription before handing off to Codex.")
                .font(.caption2).foregroundStyle(.orange)
        }
        if model.settings.usageMode == .api && targetProvider != .local {
            Text("Isolated changes are unavailable while Claude API mode is selected.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        if !targetProfileAllowsSharing {
            Label("This target profile has not enabled shared memory. No discussion turns will be included.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private var completedTurnsSection: some View {
        GroupBox("Completed turns to include") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.localizedFormat(
                    "Up to %d completed turns can be included. The latest eligible turns are preselected; the original chat is retained. Review the exact selection before continuing.",
                    DiscussionStore.maximumTurnsPerHandoff
                ))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Select none") {
                        selectedTurnIDs.removeAll()
                        clearPreview()
                    }
                    Button(model.localizedFormat("Select latest %d", DiscussionStore.maximumTurnsPerHandoff)) {
                        selectedTurnIDs = latestEligibleTurnIDs
                        clearPreview()
                    }
                    Text(model.localizedFormat(
                        "%d of %d selected",
                        selectedTurnIDs.count,
                        DiscussionStore.maximumTurnsPerHandoff
                    ))
                    .font(.caption2).foregroundStyle(.secondary)
                }
                if let discussion {
                    if discussion.turns.isEmpty {
                        Text("This chat has no turns yet. You can still create or link a project with no discussion context.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if eligibleTurns.isEmpty {
                        Text("No completed shareable turn is eligible. You can continue with no discussion context, or choose profiles that allow shared memory.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if selectedTurnIDs.isEmpty {
                        Text("No turns are selected. The project preview will include no discussion context.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(discussion?.turns ?? []) { turn in
                    turnSelection(turn)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func turnSelection(_ turn: DiscussionTurn) -> some View {
        let eligible = isEligible(turn)
        return Toggle(isOn: Binding(
            get: { selectedTurnIDs.contains(turn.id) },
            set: { selected in
                if selected {
                    guard selectedTurnIDs.count < DiscussionStore.maximumTurnsPerHandoff else {
                        errorMessage = model.localizedFormat(
                            "A handoff can include at most %d turns.",
                            DiscussionStore.maximumTurnsPerHandoff
                        )
                        return
                    }
                    selectedTurnIDs.insert(turn.id)
                }
                else { selectedTurnIDs.remove(turn.id) }
                clearPreview()
            }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(turn.provider.rawValue.capitalized) · \(turn.timestamp.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption.weight(.medium))
                Text(String(turn.userText.prefix(150)))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                if !eligible {
                    turnIneligibleReason(turn)
                }
            }
        }
        .disabled(!eligible || isPreparing || isCreating
            || (!selectedTurnIDs.contains(turn.id) && selectedTurnIDs.count >= DiscussionStore.maximumTurnsPerHandoff))
    }

    @ViewBuilder
    private func turnIneligibleReason(_ turn: DiscussionTurn) -> some View {
        if turn.assistantText == nil {
            Text("Incomplete turns cannot be handed off.")
                .font(.caption2).foregroundStyle(.tertiary)
        } else if !targetProfileAllowsSharing {
            Text("The target profile must also consent before discussion turns can be included.")
                .font(.caption2).foregroundStyle(.tertiary)
        } else {
            Text("This turn is transcript-only or its source profile did not consent to sharing.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func handoffPreview(_ handoff: DiscussionProjectHandoff) -> some View {
        GroupBox("Exact handoff preview") {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.localizedFormat("Source discussion: %@ · revision %@", handoff.discussionID.uuidString, String(handoff.discussionRevision)))
                if let discussion {
                    Text(model.localizedFormat("Source data root: %@", discussion.dataRootPath))
                }
                Text(model.localizedFormat("Destination: %@", handoff.destinationPath))
                Text(model.localizedFormat("Action: %@", model.localized(handoff.mode == .createNew ? "Create new Git project" : "Link existing Git project")))
                Text(model.localizedFormat(
                    "Target: %@ · %@ · %@",
                    handoff.targetProvider.rawValue.capitalized,
                    model.profileName(for: handoff.targetProvider, profileID: handoff.targetProfileID),
                    model.localized(handoff.accessMode == .readOnly ? "Read-only" : "Isolated changes · review and explicit approval required")
                ))
                Text(model.localizedFormat(
                    "Expected repository commit: %@",
                    model.localized(handoff.expectedRepositoryCommit ?? "none; a new empty initial commit will be created")
                ))
                Text(model.localizedFormat("Selected completed turns: %@", String(handoff.selectedTurns.count)))
                Text(model.localizedFormat("Reviewed SHA-256 digest: %@", handoff.reviewedDigest))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)

                if !targetProfileAllowsSharing {
                    Label("No discussion turns will be copied because this target profile has not enabled shared-memory consent.", systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if handoff.mode == .createNew && handoff.selectedTurns.isEmpty {
                    Label("The initial Git commit is empty. No discussion turns will be copied to project memory.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if handoff.mode == .createNew {
                Label("The initial Git commit is empty. AgentBridge stores approved turns separately as app-owned project memory in the workspace data root, scoped to the repository and commit. That memory is not committed as source files.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if handoff.selectedTurns.isEmpty {
                    Label("The existing repository is read without changing its files. No discussion turns will be copied to project memory.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("The existing repository is read without changing its files. Approved turns are stored separately as app-owned project memory in the workspace data root, scoped to the repository and commit.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                DisclosureGroup("Exact selected payload") {
                    ScrollView {
                        Text(payloadText(for: handoff))
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 80, maxHeight: 230)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                }
                .font(.caption.weight(.semibold))
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
        }
    }

    private func payloadText(for handoff: DiscussionProjectHandoff) -> String {
        guard !handoff.selectedTurns.isEmpty else { return model.localized("No discussion turns selected.") }
        return handoff.selectedTurns.enumerated().map { index, turn in
            let profileName = model.profileName(for: turn.provider, profileID: turn.sourceAccountProfileID)
            return "\(model.localizedFormat("Turn %@ · %@", String(index + 1), turn.timestamp.formatted(date: .abbreviated, time: .shortened)))\n\(model.localizedFormat("Provider: %@ · source profile: %@", turn.provider.rawValue.capitalized, profileName))\n\(model.localized("User:"))\n\(turn.userText)\n\(model.localized("Assistant:"))\n\(turn.assistantText)"
        }
        .joined(separator: "\n\n────────────────────────\n\n")
    }

    private func isEligible(_ turn: DiscussionTurn) -> Bool {
        targetProfileAllowsSharing && turn.assistantText != nil && isSourceProfileCurrentlyConsented(turn)
    }

    private func eligibleTurnIDs(for provider: AgentProvider, profileID: UUID?) -> Set<UUID> {
        guard let profileID,
              model.profileAllowsSharedMemory(provider: provider, profileID: profileID) else { return [] }
        return Set((discussion?.turns.filter {
            $0.assistantText != nil && isSourceProfileCurrentlyConsented($0)
        }.suffix(DiscussionStore.maximumTurnsPerHandoff).map(\.id) ?? []))
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        if mode == .createNew {
            panel.title = model.localized("Choose a parent folder for the new Git project")
            panel.message = model.localized("Select an existing folder. The new project folder will be created only after confirmation.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destinationPath = url.appendingPathComponent("New Project", isDirectory: true).standardizedFileURL.path
        } else {
            panel.title = model.localized("Choose an existing Git project")
            panel.message = model.localized("Select the root folder of an existing local Git repository.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destinationPath = url.standardizedFileURL.path
        }
        clearPreview()
    }

    private func preparePreview() {
        guard let discussion, let targetProfileID, destinationPath.hasPrefix("/") else { return }
        isPreparing = true
        errorMessage = nil
        preparedHandoff = nil
        let inputKey = currentInputKey
        let turnIDs = Set(discussion.turns.filter { selectedTurnIDs.contains($0.id) }.map(\.id))
        Task {
            defer { isPreparing = false }
            do {
                let handoff = try await model.chats.prepareDiscussionProjectHandoff(
                    discussionID: discussion.id,
                    destinationPath: destinationPath,
                    mode: mode,
                    targetProvider: targetProvider,
                    targetProfileID: targetProfileID,
                    selectedTurnIDs: turnIDs,
                    accessMode: accessMode
                )
                preparedHandoff = handoff
                preparedInputKey = inputKey
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func createProject() {
        guard let handoff = preparedHandoff, previewIsCurrent else { return }
        isCreating = true
        errorMessage = nil
        Task {
            defer { isCreating = false }
            do {
                let session = try await model.chats.createOrAttachProjectFromDiscussion(
                    handoffID: handoff.id,
                    reviewedDigest: handoff.reviewedDigest
                )
                dismiss()
                onOpenProject(session)
            } catch {
                errorMessage = error.localizedDescription
                preparedHandoff = nil
                preparedInputKey = nil
            }
        }
    }

    private func clearPreview() {
        preparedHandoff = nil
        preparedInputKey = nil
    }
}
