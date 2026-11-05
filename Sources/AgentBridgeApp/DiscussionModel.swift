import AgentBridgeCore
import Foundation
import Observation

/// Chat-first discussions: the list, the selected chat, the target for a new
/// chat, sending and cancelling messages, and project handoffs. Settings,
/// account profiles and the project session stay on `AppModel`, read
/// through `app`.
@MainActor
@Observable
final class DiscussionModel {
    var discussions: [DiscussionRecord] = []
    var selectedDiscussionID: UUID?
    var discussionProgress: [UUID: String] = [:]
    var isPreparingDiscussionHandoff = false
    var isApplyingDiscussionHandoff = false
    var newDiscussionProvider: AgentProvider = .codex
    var newDiscussionProfileID: UUID?
    var discussionProfilePreferences: [AgentProvider: UUID] = [:]
    @ObservationIgnored private var discussionCancellationFlags: [UUID: CancellationFlag] = [:]
    @ObservationIgnored private var hasInitializedNewDiscussionTarget = false

    private static let newDiscussionProviderPreferenceKey = "discussion.newProvider"

    private static let discussionProfilePreferencesKey = "discussion.profilePreferences"

    var hasActiveDiscussionOperation: Bool {
        !discussionCancellationFlags.isEmpty || isPreparingDiscussionHandoff || isApplyingDiscussionHandoff
            || discussions.contains(where: { $0.status.isInFlight })
    }

    func isDiscussionRunning(id: UUID) -> Bool {
        discussionCancellationFlags[id] != nil
            || discussions.first(where: { $0.id == id })?.status == .running
    }

    var selectedDiscussion: DiscussionRecord? {
        discussions.first(where: { $0.id == selectedDiscussionID })
    }

    func preferredDiscussionProfileID(for provider: AgentProvider) -> UUID? {
        discussionProfilePreferences[provider]
            ?? (newDiscussionProvider == provider ? newDiscussionProfileID : nil)
            ?? app.selectedProfileIDs[provider]
            ?? app.accountProfiles[provider]?.first?.id
    }

    func openDiscussion(_ id: UUID) {
        selectedDiscussionID = id
        app.isProjectConversationActive = false
    }

    func refreshDiscussions() {
        guard let service = app.service else {
            discussions = []
            return
        }
        applyDiscussions(Result { try service.discussions() })
    }

    /// Applies a read of the discussion list, made here or off the main thread.
    func applyDiscussions(_ result: Result<[DiscussionRecord], Error>) {
        do {
            discussions = try result.get()
            if let selectedDiscussionID,
               !discussions.contains(where: { $0.id == selectedDiscussionID }) {
                self.selectedDiscussionID = nil
            }
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func refreshDiscussion(id: UUID) -> DiscussionRecord? {
        guard let service = app.service else { return nil }
        do {
            let discussion = try service.discussion(id: id)
            if discussions.first(where: { $0.id == id }) != discussion {
                replaceDiscussion(discussion)
            }
            return discussion
        } catch {
            return nil
        }
    }

    func previewDiscussionContext(id: UUID, currentPrompt: String) async throws -> ContextCompressionPreview {
        guard let service = app.service else {
            throw AgentBridgeError.invalidInput(app.localized("Choose a workspace folder before previewing context."))
        }
        let localSettings = discussions.first(where: { $0.id == id })?.provider == .local ? app.settings.localModel : nil
        return try service.previewDiscussionContext(
            id: id,
            currentPrompt: currentPrompt,
            settings: localSettings
        )
    }

    func createDiscussion(provider: AgentProvider? = nil, profileID: UUID? = nil) {
        guard let service = app.service else { return }
        let targetProvider = provider ?? newDiscussionProvider
        let preferredProfileID = profileID
            ?? (targetProvider == newDiscussionProvider ? newDiscussionProfileID : nil)
            ?? discussionProfilePreferences[targetProvider]
            ?? app.selectedProfileIDs[targetProvider]
            ?? app.accountProfiles[targetProvider]?.first?.id
        guard let targetProfileID = preferredProfileID
            ?? (targetProvider == .local ? try? service.selectedAccountProfile(provider: .local).id : nil) else {
            app.errorMessage = app.localized("No account profile is available for this provider.")
            return
        }
        do {
            let discussion = try service.createDiscussion(provider: targetProvider, accountProfileID: targetProfileID)
            discussions = try service.discussions()
            discussionProfilePreferences[targetProvider] = targetProfileID
            persistDiscussionProfilePreferences()
            selectedDiscussionID = discussion.id
            app.isProjectConversationActive = false
            discussionProgress.removeValue(forKey: discussion.id)
            app.errorMessage = nil
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    func setDiscussionTarget(id: UUID, provider: AgentProvider, profileID: UUID) {
        guard !hasActiveDiscussionOperation else {
            app.errorMessage = app.localized("A discussion request or project handoff is already in progress.")
            return
        }
        if let discussion = discussions.first(where: { $0.id == id }), discussion.status.isInFlight {
            app.errorMessage = app.localized("A discussion request or project handoff is already in progress.")
            return
        }
        guard let service = app.service,
              app.accountProfiles[provider]?.contains(where: { $0.id == profileID }) == true else {
            app.errorMessage = app.localized("Choose an available account profile.")
            return
        }
        do {
            let discussion = try service.setDiscussionTarget(id: id, provider: provider, accountProfileID: profileID)
            replaceDiscussion(discussion)
            discussionProfilePreferences[provider] = profileID
            persistDiscussionProfilePreferences()
            discussionProgress.removeValue(forKey: id)
            app.errorMessage = nil
        } catch {
            app.errorMessage = error.localizedDescription
        }
    }

    func setDiscussionProvider(id: UUID, provider: AgentProvider) {
        guard let profileID = preferredDiscussionProfileID(for: provider) else {
            app.errorMessage = app.localized("No account profile is available for this provider.")
            return
        }
        setDiscussionTarget(id: id, provider: provider, profileID: profileID)
    }

    func selectNewDiscussionProvider(_ provider: AgentProvider) {
        newDiscussionProvider = provider
        UserDefaults.standard.set(provider.rawValue, forKey: Self.newDiscussionProviderPreferenceKey)
        let profileID = discussionProfilePreferences[provider]
            ?? app.selectedProfileIDs[provider]
            ?? app.accountProfiles[provider]?.first?.id
        newDiscussionProfileID = profileID
        if let profileID {
            discussionProfilePreferences[provider] = profileID
            persistDiscussionProfilePreferences()
        }
    }

    func selectNewDiscussionProfile(_ profileID: UUID) {
        guard app.accountProfiles[newDiscussionProvider]?.contains(where: { $0.id == profileID }) == true else { return }
        newDiscussionProfileID = profileID
        discussionProfilePreferences[newDiscussionProvider] = profileID
        persistDiscussionProfilePreferences()
    }

    func sendDiscussionMessage(
        id: UUID,
        prompt: String,
        isShareable: Bool,
        onCompletion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let service = app.service,
              let discussion = discussions.first(where: { $0.id == id }) else {
            onCompletion(false)
            return
        }
        let message = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            onCompletion(false)
            return
        }
        guard !hasActiveDiscussionOperation, !discussion.status.isInFlight,
              discussionCancellationFlags[id] == nil else {
            onCompletion(false)
            return
        }

        let hasConsent = app.profileAllowsSharedMemory(provider: discussion.provider, profileID: discussion.accountProfileID)
        let cancellation = CancellationFlag()
        discussionCancellationFlags[id] = cancellation
        discussionProgress[id] = app.localized(discussion.provider == .local
            ? "Sending to the configured local model…"
            : "Sending with the official CLI subscription sign-in…")
        app.errorMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            let startingRevision = discussion.revision
            let refreshTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, self.discussionCancellationFlags[id] != nil else { return }
                    if let latest = self.refreshDiscussion(id: id),
                       latest.revision != startingRevision || latest.status.isInFlight {
                        return
                    }
                    do {
                        try await Task.sleep(nanoseconds: 250_000_000)
                    } catch {
                        return
                    }
                }
            }
            defer {
                refreshTask.cancel()
                self.discussionCancellationFlags.removeValue(forKey: id)
                self.refreshDiscussions()
                if discussion.provider == .local {
                    try? self.app.usage.refreshLocalModelUsageStatisticsIfNeeded(service: service, force: true)
                }
            }
            do {
                _ = try await service.sendDiscussionMessage(
                    id: id,
                    prompt: message,
                    isShareable: isShareable && hasConsent,
                    cancellation: cancellation
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.refreshDiscussion(id: id)
                        guard self.selectedDiscussionID == id else { return }
                        self.discussionProgress[id] = progress
                    }
                }
                _ = self.refreshDiscussion(id: id)
                self.discussionProgress[id] = self.app.localized("Response complete.")
                onCompletion(true)
            } catch {
                let persistedDiscussion = self.refreshDiscussion(id: id)
                if cancellation.isCancelled || persistedDiscussion?.status == .cancelled {
                    self.discussionProgress[id] = self.app.localized("Cancellation requested…")
                } else {
                    self.discussionProgress[id] = error.localizedDescription
                    self.app.errorMessage = error.localizedDescription
                }
                onCompletion(false)
            }
        }
    }

    func cancelDiscussion(id: UUID) {
        guard let service = app.service else { return }
        let cancellation = discussionCancellationFlags[id]
        cancellation?.cancel()

        guard let latest = refreshDiscussion(id: id) else {
            if cancellation != nil {
                discussionProgress[id] = app.localized("Cancellation requested…")
            }
            return
        }
        guard latest.status == .running else {
            if latest.status == .completed {
                discussionProgress[id] = app.localized("Response complete.")
            } else if cancellation != nil {
                discussionProgress[id] = app.localized("Cancellation requested…")
            }
            return
        }

        do {
            try service.cancelDiscussion(id: id)
            discussionProgress[id] = app.localized("Cancellation requested…")
            refreshDiscussion(id: id)
        } catch {
            let updated = refreshDiscussion(id: id)
            if updated?.status == .completed {
                discussionProgress[id] = app.localized("Response complete.")
            } else if updated?.status == .cancelled || cancellation != nil {
                discussionProgress[id] = app.localized("Cancellation requested…")
            } else if updated?.status == .running {
                discussionProgress[id] = error.localizedDescription
            }
        }
    }

    func prepareDiscussionProjectHandoff(
        discussionID: UUID,
        destinationPath: String,
        mode: DiscussionProjectMode,
        targetProvider: AgentProvider,
        targetProfileID: UUID,
        selectedTurnIDs: Set<UUID>,
        accessMode: AccessMode = .readOnly
    ) async throws -> DiscussionProjectHandoff {
        guard let service = app.service else { throw AgentBridgeError.persistence("The workspace data root is not ready.") }
        isPreparingDiscussionHandoff = true
        defer { isPreparingDiscussionHandoff = false }
        let handoff = try await service.prepareDiscussionProjectHandoff(
            discussionID: discussionID,
            destinationPath: destinationPath,
            mode: mode,
            targetProvider: targetProvider,
            targetProfileID: targetProfileID,
            selectedTurnIDs: selectedTurnIDs,
            accessMode: accessMode
        )
        refreshDiscussions()
        return handoff
    }

    func createOrAttachProjectFromDiscussion(
        handoffID: UUID,
        reviewedDigest: String
    ) async throws -> SessionRecord {
        guard let service = app.service else { throw AgentBridgeError.persistence("The workspace data root is not ready.") }
        isApplyingDiscussionHandoff = true
        defer { isApplyingDiscussionHandoff = false }
        let session = try await service.createOrAttachProjectFromDiscussion(
            handoffID: handoffID,
            reviewedDigest: reviewedDigest,
            explicitConfirmation: true
        )
        app.refresh()
        refreshDiscussions()
        selectedDiscussionID = nil
        app.isProjectConversationActive = true
        app.selectedSessionID = session.id
        return session
    }

    private func replaceDiscussion(_ discussion: DiscussionRecord) {
        if let index = discussions.firstIndex(where: { $0.id == discussion.id }) {
            discussions[index] = discussion
        } else {
            discussions.insert(discussion, at: 0)
        }
        discussions.sort { $0.updatedAt > $1.updatedAt }
    }

    func reconcileNewDiscussionTarget() {
        if !hasInitializedNewDiscussionTarget {
            if UserDefaults.standard.string(forKey: Self.newDiscussionProviderPreferenceKey) == nil {
                newDiscussionProvider = app.settings.defaultProvider
            }
            hasInitializedNewDiscussionTarget = true
        }
        let availableProfiles = app.accountProfiles[newDiscussionProvider] ?? []
        if let newDiscussionProfileID,
           availableProfiles.contains(where: { $0.id == newDiscussionProfileID }) { return }
        let preferredProfileID = discussionProfilePreferences[newDiscussionProvider]
        let selectedProfileID = app.selectedProfileIDs[newDiscussionProvider]
        newDiscussionProfileID = [preferredProfileID, selectedProfileID, availableProfiles.first?.id]
            .compactMap { $0 }
            .first(where: { id in availableProfiles.contains(where: { $0.id == id }) })
        if let newDiscussionProfileID {
            discussionProfilePreferences[newDiscussionProvider] = newDiscussionProfileID
            persistDiscussionProfilePreferences()
        }
    }

    private func persistDiscussionProfilePreferences() {
        let values = Dictionary(uniqueKeysWithValues: discussionProfilePreferences.map {
            ($0.key.rawValue, $0.value.uuidString.lowercased())
        })
        UserDefaults.standard.set(values, forKey: Self.discussionProfilePreferencesKey)
    }

    /// Restores the saved provider and account choices for new chats.
    func loadSavedPreferences() {
        if let savedProvider = UserDefaults.standard.string(forKey: Self.newDiscussionProviderPreferenceKey)
            .flatMap(AgentProvider.init(rawValue:)) {
            newDiscussionProvider = savedProvider
        }
        if let savedProfiles = UserDefaults.standard.dictionary(forKey: Self.discussionProfilePreferencesKey) as? [String: String] {
            for (providerRawValue, profileRawValue) in savedProfiles {
                guard let provider = AgentProvider(rawValue: providerRawValue),
                      let profileID = UUID(uuidString: profileRawValue) else { continue }
                discussionProfilePreferences[provider] = profileID
            }
        }
        newDiscussionProfileID = discussionProfilePreferences[newDiscussionProvider]
    }

    @ObservationIgnored private weak var owner: AppModel?

    private var app: AppModel {
        guard let owner else { preconditionFailure("DiscussionModel outlived its AppModel.") }
        return owner
    }

    /// Connects this model to the `AppModel` that owns it; called once from `AppModel.init`.
    func attach(to app: AppModel) {
        owner = app
    }
}
