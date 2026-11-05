import AppKit
import AgentBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct DiscussionHandoffReviewView: View {
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
