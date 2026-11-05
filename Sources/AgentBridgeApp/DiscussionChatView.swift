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
