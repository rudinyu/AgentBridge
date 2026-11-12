import AppKit
import AgentBridgeCore
import SwiftUI

extension MainWindowView {
    var chatsSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Start a chat") {
                    VStack(alignment: .leading, spacing: 9) {
                        Picker("Provider", selection: Binding(
                            get: { model.chats.newDiscussionProvider },
                            set: { model.chats.selectNewDiscussionProvider($0) }
                        )) {
                            Text("Codex").tag(AgentProvider.codex)
                            Text("Claude").tag(AgentProvider.claude)
                            Text("Local").tag(AgentProvider.local)
                        }
                        if let profile = model.accountProfiles[model.chats.newDiscussionProvider]?.first(where: {
                            $0.id == model.chats.newDiscussionProfileID
                        }) {
                            Picker(model.chats.newDiscussionProvider == .local ? "Memory account" : "Account", selection: Binding(
                                get: { model.chats.newDiscussionProfileID ?? profile.id },
                                set: { model.chats.selectNewDiscussionProfile($0) }
                            )) {
                                ForEach(model.accountProfiles[model.chats.newDiscussionProvider] ?? []) { account in
                                    Text(model.displayName(of: account)).tag(account.id)
                                }
                            }
                        } else {
                            Text("No account profile is available for this provider.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(model.chats.newDiscussionProvider == .local
                            ? "Local chats use the configured model and separate local memory account. No API key or cloud fallback is used."
                            : "Chats use the provider’s official CLI subscription sign-in. Claude API usage is not available here.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.chats.newDiscussionProvider == .local
                            || model.chats.selectedDiscussion?.provider == .local
                            || model.settings.defaultProvider == .local {
                            LocalModelSettingsSection(model: model)
                        }
                        Button {
                            model.chats.createDiscussion()
                        } label: {
                            Label("New Chat", systemImage: "plus.bubble")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isChangingWorkspaceRoot)
                    }
                    .padding(.vertical, 2)
                }

                GroupBox("Chats") {
                    if model.chats.discussions.isEmpty {
                        Text("No saved chats yet. Start a New Chat whenever you are ready.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.chats.discussions) { discussion in
                                Button {
                                    model.chats.openDiscussion(discussion.id)
                                } label: {
                                    discussionRow(discussion)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                GroupBox("Project sessions") {
                    if model.sessions.isEmpty {
                        Text("Project sessions appear here after you create or link a Git project.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.sessions) { session in
                                Button {
                                    openProjectConversation(session.id)
                                } label: {
                                    projectSessionRow(session)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { removeSessionMenuItem(session) }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 300)
    }

    var projectSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                settingsPanel
                if model.isLocalProviderContext && model.settings.defaultProvider != .local {
                    LocalModelSettingsSection(model: model)
                }
                if model.settings.defaultProvider != .local { usagePanel }
                accountPanel
                DisclosureGroup("Project configuration", isExpanded: $isProjectConfigurationExpanded) {
                    workspacePanel
                        .padding(.top, 8)
                }
                sessionList
                if !model.isLocalProviderContext { taskBoardPanel }
            }
            .padding(12)
        }
        .frame(width: 330)
    }

    func discussionRow(_ discussion: DiscussionRecord) -> some View {
        let isSelected = model.chats.selectedDiscussionID == discussion.id
        let title = discussion.turns.first?.userText.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleText = title.flatMap { $0.isEmpty ? nil : String($0.prefix(46)) }
            ?? model.localized("New conversation")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: discussion.provider == .codex ? "sparkle" : (discussion.provider == .local ? "desktopcomputer" : "message"))
                Text(titleText)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if discussion.status.isInFlight {
                    ProgressView().controlSize(.small)
                }
            }
            Text(model.localizedFormat(
                "%@ · %@ · %@",
                discussion.provider.rawValue.capitalized,
                model.profileName(for: discussion.provider, profileID: discussion.accountProfileID),
                model.formattedDate(discussion.updatedAt, date: .abbreviated, time: .shortened)
            ))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    func projectSessionRow(_ session: SessionRecord) -> some View {
        let isSelected = model.isProjectConversationActive && model.selectedSessionID == session.id
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: session.provider == .codex ? "sparkle" : (session.provider == .local ? "desktopcomputer" : "message"))
            Text(model.localizedFormat(
                "%@ · %@",
                session.provider.rawValue.capitalized,
                URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent
            ))
                    .font(.callout.weight(.medium)).lineLimit(1)
            }
            Text(model.localizedFormat("%@ · %@", model.profileName(for: session), String(session.snapshotCommit.prefix(12))))
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    @ViewBuilder
    var chatsPanel: some View {
        if let discussion = model.chats.selectedDiscussion {
            DiscussionChatView(model: model, discussionID: discussion.id) { session in
                openProjectConversation(session.id)
            }
        } else {
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 36)).foregroundStyle(.secondary)
                Text("Start with a chat")
                    .font(.title2.weight(.semibold))
                Text("Discuss an idea first. You can create a Git project or link an existing one later, after reviewing exactly what to carry over.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
                Button {
                    model.chats.createDiscussion()
                } label: {
                    Label("New Chat", systemImage: "plus.bubble")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isChangingWorkspaceRoot)
                Text("Chats are saved under your selected workspace data root and stay separate from Git projects until you choose a handoff.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var settingsPanel: some View {
        GroupBox("Assistant") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Assistant", selection: Binding(
                        get: { model.settings.defaultProvider },
                        set: { model.selectDefaultProvider($0) }
                    )) {
                        Text("Codex").tag(AgentProvider.codex)
                        Text("Claude").tag(AgentProvider.claude)
                        Text("Local").tag(AgentProvider.local)
                }
                if model.settings.defaultProvider == .claude {
                    Picker("Claude Usage Mode", selection: Binding(
                            get: { model.settings.usageMode },
                            set: { model.selectUsageMode($0) }
                        )) {
                            Text("Official CLI Subscription").tag(UsageMode.subscription)
                            Text("Claude API (confirm each run)").tag(UsageMode.api)
                    }
                } else if model.settings.defaultProvider == .local {
                    Label("Local mode uses a configured loopback model. No subscription quota, API key, or cloud fallback applies.", systemImage: "desktopcomputer")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Codex uses an official CLI subscription.", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.isClaudeAPIRunContext {
                    Label("Claude API calls incur charges; each run requires confirmation.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.settings.defaultProvider == .local {
                    LocalModelSettingsSection(model: model)
                } else {
                    DisclosureGroup("CLI Executables") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Codex CLI (auto-detect)", text: $model.codexPath)
                            TextField("Claude CLI (auto-detect)", text: $model.claudePath)
                            Button("Save CLI Paths") { model.saveSettings() }
                            ForEach([AgentProvider.codex, .claude], id: \.self) { provider in
                                ForEach(model.cliCompatibilityWarnings(for: provider), id: \.self) { line in
                                    Label("\(provider.rawValue.capitalized): \(line)", systemImage: "exclamationmark.triangle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(model.hasActiveAutonomousWorkflow || model.chats.hasActiveDiscussionOperation)
    }

    var accountPanel: some View {
        GroupBox(model.settings.defaultProvider == .local ? "Local memory account" : "Official CLI Accounts") {
            VStack(alignment: .leading, spacing: 8) {
                if let profile = model.selectedAccountProfile {
                    Picker("Account", selection: Binding(
                        get: { model.selectedProfileIDs[model.settings.defaultProvider] ?? profile.id },
                        set: { model.selectAccountProfile($0) }
                    )) {
                        ForEach(model.accountProfiles[model.settings.defaultProvider] ?? []) { account in
                            Text(model.displayName(of: account)).tag(account.id)
                        }
                    }
                    if model.settings.defaultProvider == .local {
                        Text("This account scopes local chat memory consent. It does not have a CLI login or provider plan.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let assessment = model.selectedProfileAuthentication {
                        Label(model.localized(assessment.message), systemImage: assessment.confirmedSubscription ? "checkmark.seal" : "exclamationmark.shield")
                            .font(.caption).foregroundStyle(assessment.confirmedSubscription ? Color.secondary : Color.orange)
                    } else {
                        Text("This account's sign-in and plan have not been checked.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Allow this account to load and save shared project memory", isOn: Binding(
                        get: { model.selectedAccountProfile?.allowsSharedMemory ?? false },
                        set: { model.setSelectedAccountMemorySharing($0) }
                    ))
                    .font(.caption)
                    if model.settings.defaultProvider == .local {
                        Text("Local models do not use sign-in or credential folders.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if !profile.usesExistingLogin {
                        Button("Sign In to This Account in the App") { model.terminal.openProfileLoginTerminal() }
                            .disabled(model.terminal.terminalRunning)
                    } else {
                        Text("Your current local sign-in stays unchanged. Additional accounts use separate CLI configuration folders.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Loading account settings…").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                TextField(model.settings.defaultProvider == .local ? "New local account name" : "New Account Display Name", text: $model.newProfileName)
                Toggle("Allow shared project memory after creation (on by default)", isOn: $model.newProfileAllowsSharedMemory)
                    .font(.caption)
                Button("Add and Switch Account") { model.createAccountProfile() }
                    .disabled(model.newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSwitchingTarget)
            }
            .padding(.vertical, 2)
        }
        .disabled(model.hasActiveAutonomousWorkflow || model.chats.hasActiveDiscussionOperation)
    }

    var workspacePanel: some View {
        GroupBox("Project") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Data root").font(.caption.weight(.semibold))
                        Text(model.workspaceRootPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        if let warning = model.workspaceRootSyncWarning {
                            Label(warning, systemImage: "icloud.and.arrow.up")
                                .font(.caption2).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Change…") { model.chooseWorkspaceRoot() }
                        .disabled(model.isChangingWorkspaceRoot || model.isRunning || model.terminal.terminalRunning)
                }
                TextField("Git Repository Path", text: $model.repositoryPath)
                Button("Choose Repository…") { model.chooseRepository() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.settings.defaultProvider == .local {
                    Label("Local project chat is read-only. Editing, terminal, autonomy, Skills, and MCP are unavailable.", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Picker("New session access mode", selection: $model.requestedAccessMode) {
                        Text("Read-only (default)").tag(AccessMode.readOnly)
                        Text("Isolated changes (plan approval required)").tag(AccessMode.isolatedChanges)
                            .disabled(model.settings.usageMode == .api)
                        Text("Native interactive terminal").tag(AccessMode.interactiveManualApproval)
                            .disabled(model.settings.usageMode == .api)
                    }
                    .font(.caption)
                }
                if model.settings.usageMode == .api && model.settings.defaultProvider != .local {
                    Text("Claude API sessions are read-only; isolated changes and interactive terminal sessions require official CLI subscription mode.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Create a New Session for This Project") { model.createSession() }
                    .disabled(model.repositoryPath.isEmpty || model.isSwitchingTarget)
                Text(model.settings.defaultProvider == .local
                    ? "AgentBridge pins the commit and runs in its own isolated workspace. Local project chat is read-only and shares memory according to the bound local account's consent setting."
                    : "AgentBridge pins the commit and runs in its own isolated workspace. Codex and Claude share chat memory when they use the same source and commit.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .disabled(model.hasActiveAutonomousWorkflow || model.chats.hasActiveDiscussionOperation)
    }

    /// Removes the session after showing what that deletes.
    func removeSessionMenuItem(_ session: SessionRecord) -> some View {
        Button(model.localized("Remove Session…"), role: .destructive) {
            model.reviewSessionRemoval(session.id)
        }
        .disabled(model.isRemovingSession)
    }

    var sessionList: some View {
        GroupBox("Sessions") {
            if model.sessions.isEmpty {
                ContentUnavailableView("No Sessions Yet", systemImage: "bubble.left.and.bubble.right")
                    .frame(minHeight: 120)
            } else {
                List(model.sessions, selection: Binding(
                    get: { model.selectedSessionID },
                    set: { if let id = $0 { openProjectConversation(id) } }
                )) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: session.provider == .codex ? "sparkle" : (session.provider == .local ? "desktopcomputer" : "message"))
                            Text(session.provider.rawValue.capitalized)
                                .font(.headline)
                            if session.policy.accessMode == .interactiveManualApproval {
                                Text(model.localized("value.terminal")).font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: Capsule())
                            } else if session.policy.accessMode == .isolatedChanges {
                                Text("Isolated changes").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(.orange.opacity(0.14), in: Capsule())
                            }
                        }
                        Text("\(model.profileName(for: session)) · \(model.localized(session.status.rawValue.capitalized))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("\(session.snapshotCommit.prefix(12)) · \(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent)")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .tag(session.id)
                    .contextMenu { removeSessionMenuItem(session) }
                }
                .frame(minHeight: 120, maxHeight: 280)
            }
        }
    }
}
