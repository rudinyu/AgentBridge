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
                            get: { model.newDiscussionProvider },
                            set: { model.selectNewDiscussionProvider($0) }
                        )) {
                            Text("Codex").tag(AgentProvider.codex)
                            Text("Claude").tag(AgentProvider.claude)
                            Text("Local").tag(AgentProvider.local)
                        }
                        if let profile = model.accountProfiles[model.newDiscussionProvider]?.first(where: {
                            $0.id == model.newDiscussionProfileID
                        }) {
                            Picker(model.newDiscussionProvider == .local ? "Memory account" : "Account", selection: Binding(
                                get: { model.newDiscussionProfileID ?? profile.id },
                                set: { model.selectNewDiscussionProfile($0) }
                            )) {
                                ForEach(model.accountProfiles[model.newDiscussionProvider] ?? []) { account in
                                    Text(account.name).tag(account.id)
                                }
                            }
                        } else {
                            Text("No account profile is available for this provider.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(model.newDiscussionProvider == .local
                            ? "Local chats use the configured model and separate local memory account. No API key or cloud fallback is used."
                            : "Chats use the provider’s official CLI subscription sign-in. Claude API usage is not available here.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.newDiscussionProvider == .local
                            || model.selectedDiscussion?.provider == .local
                            || model.settings.defaultProvider == .local {
                            LocalModelSettingsSection(model: model)
                        }
                        Button {
                            model.createDiscussion()
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
                    if model.discussions.isEmpty {
                        Text("No saved chats yet. Start a New Chat whenever you are ready.")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 5)
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.discussions) { discussion in
                                Button {
                                    model.openDiscussion(discussion.id)
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
                                    model.openProjectSession(session.id)
                                    mainArea = .conversation
                                } label: {
                                    projectSessionRow(session)
                                }
                                .buttonStyle(.plain)
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
        let isSelected = model.selectedDiscussionID == discussion.id
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
                discussion.updatedAt.formatted(date: .abbreviated, time: .shortened)
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
        if let discussion = model.selectedDiscussion {
            DiscussionChatView(model: model, discussionID: discussion.id) { session in
                model.openProjectSession(session.id)
                mainArea = .conversation
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
                    model.createDiscussion()
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
        GroupBox("助理") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("助理", selection: Binding(
                        get: { model.settings.defaultProvider },
                        set: { model.selectDefaultProvider($0) }
                    )) {
                        Text("Codex").tag(AgentProvider.codex)
                        Text("Claude").tag(AgentProvider.claude)
                        Text("Local").tag(AgentProvider.local)
                }
                if model.settings.defaultProvider == .claude {
                    Picker("Claude 使用模式", selection: Binding(
                            get: { model.settings.usageMode },
                            set: { model.selectUsageMode($0) }
                        )) {
                            Text("官方 CLI 訂閱登入").tag(UsageMode.subscription)
                            Text("Claude API（每次確認）").tag(UsageMode.api)
                    }
                } else if model.settings.defaultProvider == .local {
                    Label("Local mode uses a configured loopback model. No subscription quota, API key, or cloud fallback applies.", systemImage: "desktopcomputer")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Codex 使用官方 CLI 訂閱登入", systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.isClaudeAPIRunContext {
                    Label("Claude API 會產生費用；每次執行都要確認。", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if model.settings.defaultProvider == .local {
                    LocalModelSettingsSection(model: model)
                } else {
                    DisclosureGroup("CLI 執行檔") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("Codex CLI 自動尋找", text: $model.codexPath)
                            TextField("Claude CLI 自動尋找", text: $model.claudePath)
                            Button("儲存 CLI 路徑") { model.saveSettings() }
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(model.hasActiveAutonomousWorkflow || model.hasActiveDiscussionOperation)
    }

    var accountPanel: some View {
        GroupBox(model.settings.defaultProvider == .local ? "Local memory account" : "官方 CLI 帳戶") {
            VStack(alignment: .leading, spacing: 8) {
                if let profile = model.selectedAccountProfile {
                    Picker("帳戶", selection: Binding(
                        get: { model.selectedProfileIDs[model.settings.defaultProvider] ?? profile.id },
                        set: { model.selectAccountProfile($0) }
                    )) {
                        ForEach(model.accountProfiles[model.settings.defaultProvider] ?? []) { account in
                            Text(account.name).tag(account.id)
                        }
                    }
                    if model.settings.defaultProvider == .local {
                        Text("This account scopes local chat memory consent. It does not have a CLI login or provider plan.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let assessment = model.selectedProfileAuthentication {
                        Label(model.localized(assessment.message), systemImage: assessment.confirmedSubscription ? "checkmark.seal" : "exclamationmark.shield")
                            .font(.caption).foregroundStyle(assessment.confirmedSubscription ? Color.secondary : Color.orange)
                    } else {
                        Text("尚未檢查此帳戶的登入方式與方案。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("允許此帳戶載入與保存專案共用記憶", isOn: Binding(
                        get: { model.selectedAccountProfile?.allowsSharedMemory ?? false },
                        set: { model.setSelectedAccountMemorySharing($0) }
                    ))
                    .font(.caption)
                    if model.settings.defaultProvider == .local {
                        Text("Local models do not use sign-in or credential folders.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if !profile.usesExistingLogin {
                        Button("在 App 內登入此帳戶") { model.openProfileLoginTerminal() }
                            .disabled(model.terminalRunning)
                    } else {
                        Text("目前本機登入保持原狀；新增其他帳戶會使用獨立的 CLI 設定資料夾。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("正在載入帳戶設定…").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                TextField(model.settings.defaultProvider == .local ? "New local account name" : "新帳戶顯示名稱", text: $model.newProfileName)
                Toggle("建立後允許共用專案記憶（預設開啟）", isOn: $model.newProfileAllowsSharedMemory)
                    .font(.caption)
                Button("新增並切換帳戶") { model.createAccountProfile() }
                    .disabled(model.newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isSwitchingTarget)
            }
            .padding(.vertical, 2)
        }
        .disabled(model.hasActiveAutonomousWorkflow || model.hasActiveDiscussionOperation)
    }

    var workspacePanel: some View {
        GroupBox("Project") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("資料根目錄").font(.caption.weight(.semibold))
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
                    Button("變更…") { model.chooseWorkspaceRoot() }
                        .disabled(model.isChangingWorkspaceRoot || model.isRunning || model.terminalRunning)
                }
                TextField("Git 儲存庫路徑", text: $model.repositoryPath)
                Button("選擇儲存庫…") { model.chooseRepository() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                if model.settings.defaultProvider == .local {
                    Label("Local project chat is read-only. Editing, terminal, autonomy, Skills, and MCP are unavailable.", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Picker("新工作階段存取模式", selection: $model.requestedAccessMode) {
                        Text("唯讀（預設）").tag(AccessMode.readOnly)
                        Text("隔離變更（需先核准計畫）").tag(AccessMode.isolatedChanges)
                            .disabled(model.settings.usageMode == .api)
                        Text("原生互動終端").tag(AccessMode.interactiveManualApproval)
                            .disabled(model.settings.usageMode == .api)
                    }
                    .font(.caption)
                }
                if model.settings.usageMode == .api && model.settings.defaultProvider != .local {
                    Text("Claude API 只提供唯讀工作階段；隔離變更與互動終端僅支援官方 CLI 訂閱登入。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("建立同一專案的新工作階段") { model.createSession() }
                    .disabled(model.repositoryPath.isEmpty || model.isSwitchingTarget)
                Text(model.settings.defaultProvider == .local
                    ? "AgentBridge 固定提交版本並在自己的隔離工作區執行。Local 專案聊天只讀，並依綁定本機帳戶的同意設定共用記憶。"
                    : "AgentBridge 固定提交版本並在自己的隔離工作區執行。相同來源與提交版本在 Codex、Claude 間共用聊天記憶。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
        .disabled(model.hasActiveAutonomousWorkflow || model.hasActiveDiscussionOperation)
    }

    var sessionList: some View {
        GroupBox("工作階段") {
            if model.sessions.isEmpty {
                ContentUnavailableView("尚無工作階段", systemImage: "bubble.left.and.bubble.right")
                    .frame(minHeight: 120)
            } else {
                List(model.sessions, selection: Binding(
                    get: { model.selectedSessionID },
                    set: { if let id = $0 { model.openProjectSession(id) } }
                )) { session in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Image(systemName: session.provider == .codex ? "sparkle" : (session.provider == .local ? "desktopcomputer" : "message"))
                            Text(session.provider.rawValue.capitalized)
                                .font(.headline)
                            if session.policy.accessMode == .interactiveManualApproval {
                                Text("Terminal").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: Capsule())
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
                }
                .frame(minHeight: 120, maxHeight: 280)
            }
        }
    }
}
