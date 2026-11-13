import AgentBridgeCore
import SwiftUI

/// Chooses which project, provider and profile the Skills & MCP screen enables
/// for. A grant is bound to a session's scope, so this picks a session, and can
/// create a read-only scope session when none matches.
struct ExtensionScopeSheet: View {
    @Bindable var model: AppModel
    let currentScope: SessionRecord?
    /// Called with the chosen scope session, or nil to follow the selected project session.
    var onChoose: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var repositoryPath = ""
    @State private var provider: AgentProvider = .codex
    @State private var profileID: UUID?
    @State private var sessionID: UUID?
    @State private var isCreating = false
    @State private var localError: String?
    @State private var localStatus = ""

    private var profile: AccountProfile? {
        let id = profileID ?? model.selectedProfileIDs[provider]
        return model.accountProfiles[provider]?.first(where: { $0.id == id })
    }

    private var matchingSessions: [SessionRecord] {
        ExtensionScopeResolver.matchingSessions(model.sessions, repositoryPath: repositoryPath, provider: provider, profileID: profile?.id)
    }

    private var chosenSession: SessionRecord? {
        matchingSessions.first(where: { $0.id == sessionID }) ?? matchingSessions.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project, provider, and profile scope")
                .font(.title3.weight(.semibold))
            Text("Extensions are enabled for one project, provider, and account profile at a time. New sessions with that scope receive them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Git repository path", text: $repositoryPath)
                Button("Choose…") {
                    model.chooseRepository()
                    repositoryPath = model.repositoryPath
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 12) {
                Picker("Provider", selection: Binding(
                    get: { provider },
                    set: { newProvider in
                        guard newProvider != provider else { return }
                        provider = newProvider
                        profileID = model.selectedProfileIDs[newProvider]
                        sessionID = nil
                    }
                )) {
                    Text("Codex").tag(AgentProvider.codex)
                    Text("Claude").tag(AgentProvider.claude)
                }
                .pickerStyle(.segmented)
                Picker("Profile", selection: Binding(
                    get: { profileID ?? model.selectedProfileIDs[provider] ?? UUID() },
                    set: { profileID = $0; sessionID = nil }
                )) {
                    ForEach(model.accountProfiles[provider] ?? []) { profile in
                        Text(model.displayName(of: profile)).tag(profile.id)
                    }
                }
                .disabled((model.accountProfiles[provider] ?? []).isEmpty)
            }
            if let profile, !profile.allowsSharedMemory {
                Label("This account has not allowed shared memory. Cross-provider task and diff transfer will be blocked by its consent setting.", systemImage: "hand.raised")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if matchingSessions.isEmpty {
                HStack {
                    Text("Create a local read-only session to review this project's exact provider/profile scope. This does not call a model or enable an extension.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Create scope session") { createScopeSession() }
                        .disabled(isCreating || repositoryPath.isEmpty || profile == nil || model.hasActiveAutonomousWorkflow)
                }
            } else {
                Picker("Scope session", selection: Binding(
                    get: { chosenSession?.id ?? UUID() },
                    set: { sessionID = $0 }
                )) {
                    ForEach(matchingSessions) { session in
                        Text("\(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent) · \(session.provider.rawValue) · \(model.profileName(for: session)) · \(session.id.uuidString.prefix(8))")
                            .tag(session.id)
                    }
                }
                if let chosenSession {
                    Text("Selected scope: \(chosenSession.provider.rawValue) · \(model.profileName(for: chosenSession)) · session \(chosenSession.id.uuidString.lowercased())")
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                    if let projectID = try? model.extensions.extensionProjectID(sessionID: chosenSession.id) {
                        Text("Project ID: \(projectID)")
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            if let localError {
                Label(model.localized(localError), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !localStatus.isEmpty {
                Label(model.localized(localStatus), systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Use the selected project session") {
                    onChoose(nil)
                    dismiss()
                }
                .disabled(model.selectedSession.map(ExtensionScopeResolver.isValidScope) != true)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Use this scope") {
                    onChoose(chosenSession?.id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(chosenSession == nil)
            }
        }
        .padding(18)
        .frame(width: 600)
        .disabled(model.hasActiveAutonomousWorkflow)
        .onAppear {
            repositoryPath = currentScope?.sourceRepositoryPath ?? model.repositoryPath
            if let currentScope, currentScope.provider != .local {
                provider = currentScope.provider
                profileID = currentScope.accountProfileID ?? AccountProfile.defaultID(for: currentScope.provider)
                sessionID = currentScope.id
            } else {
                profileID = model.selectedProfileIDs[provider]
            }
        }
    }

    private func createScopeSession() {
        guard let profile else { return }
        isCreating = true
        localError = nil
        Task { @MainActor in
            defer { isCreating = false }
            do {
                let session = try await model.extensions.createExtensionTargetSession(sourcePath: repositoryPath, provider: provider, profileID: profile.id)
                model.refresh()
                sessionID = session.id
                localStatus = model.localized("A read-only scope session was created. No provider model was started.")
            } catch {
                localError = error.localizedDescription
            }
        }
    }
}
