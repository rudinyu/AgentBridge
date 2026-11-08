import AppKit
import AgentBridgeCore
import Combine
import SwiftUI

struct MainWindowView: View {
    @Bindable var model: AppModel
    @State var mainArea: MainArea = .chats
    @State var isProjectConfigurationExpanded = false
    @State var contextPreview: ContextCompressionPreview?
    @State var contextPreviewSettings: LocalModelSettings?
    @State var isShowingContextPreview = false
    @State var isLoadingContextPreview = false

    enum MainArea: String, CaseIterable, Identifiable {
        case chats
        case conversation
        case autonomous
        case extensions

        var id: String { rawValue }
    }

    var body: some View {
        Group {
            if !model.workspaceRootIsConfigured {
                workspaceRootSetup
            } else {
                VStack(spacing: 0) {
                    header
                    mainAreaPicker
                    Divider()
                    HStack(spacing: 0) {
                        if mainArea == .chats {
                            chatsSidebar
                        } else {
                            projectSidebar
                        }
                        Divider()
                        mainAreaContent
                    }
                    Divider()
                    statusBar
                }
                .disabled(model.isChangingWorkspaceRoot)
            }
        }
        .frame(minWidth: 1160, minHeight: 780)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, model.appLanguage.locale)
        .sheet(isPresented: Bindable(model.setupWizard).isPresented) {
            SetupWizardView(model: model, wizard: model.setupWizard)
                .environment(\.locale, model.appLanguage.locale)
                .interactiveDismissDisabled(!model.workspaceRootIsConfigured || model.isChangingWorkspaceRoot || model.terminal.terminalLaunch != nil)
        }
        .alert("AgentBridge", isPresented: Binding(get: { model.errorMessage != nil && !model.setupWizard.isPresented }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.localized(model.errorMessage ?? ""))
        }
        .alert("Clear shared memory for this project?", isPresented: $model.confirmClearMemory) {
            Button("Clear Memory", role: .destructive) { model.clearSharedMemory() }
            Button("Cancel", role: .cancel) { model.confirmClearMemory = false }
        } message: {
            Text("This deletes chat memory and notes for this source repository and pinned commit. Native provider sessions will not be changed.")
        }
        .fileImporter(
            isPresented: Bindable(model.extensions).isImportingExtensionDescriptor,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: model.extensions.importExtensionDescriptor
        )
        .onChange(of: model.selectedSessionID) { _, _ in model.selectedSessionDidChange() }
        .onChange(of: model.isLocalProviderContext) { _, isLocal in
            if isLocal && (mainArea == .autonomous || mainArea == .extensions) { mainArea = .chats }
        }
        .onChange(of: model.extensions.selectedExtensionID) { _, _ in model.extensions.selectedExtensionDidChange() }
        .onChange(of: model.setupWizard.isPresented) { _, isPresented in
            if !isPresented { model.errorMessage = nil }
        }
        .onAppear { model.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in model.refreshInBackground() }
    }

    var workspaceRootSetup: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text("Choose workspace data root")
                .font(.title2.weight(.semibold))
            Text("Choose or create a folder before first use. AgentBridge stores isolated workspaces and shared memory there; app settings, dedicated CLI profile folders for separate accounts, and usage ledgers stay in Application Support. Built-in accounts continue to use their provider CLI's existing login folder.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 520)
            Button("Choose or create data root…") { model.chooseWorkspaceRoot() }
                .buttonStyle(.borderedProminent)
                .disabled(model.isChangingWorkspaceRoot)
            if model.isChangingWorkspaceRoot {
                ProgressView("Safely copying existing workspaces and shared memory…")
            }
            Text(model.localized(model.status))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.title2.weight(.semibold)).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("AgentBridge").font(.headline)
                Text("Start with a chat; hand off to Git when you’re ready.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Language", selection: $model.appLanguage) {
                Text("English").tag(AppLanguage.english)
                Text("Traditional Chinese").tag(AppLanguage.traditionalChinese)
            }
            .pickerStyle(.menu)
            Button(model.localized("Setup Wizard")) { model.setupWizard.open() }
                .disabled(!model.canPresentSetupWizard)
            if let session = model.selectedSession {
                if model.isProjectConversationActive {
                    Text("\(session.provider.rawValue.capitalized) · \(model.selectedSessionProfileName)")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary, in: Capsule())
                }
            }
            if model.chats.selectedDiscussionID == nil && !model.isLocalProviderContext {
                Button("Check Sign-in and Plan") { model.checkAuthentication() }
                    .disabled(model.hasActiveAutonomousWorkflow || model.chats.hasActiveDiscussionOperation)
            }
            Button("Refresh") { model.refresh() }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        // Clear the window buttons now that the title bar is hidden.
        .padding(.top, 20)
    }

    var mainAreaPicker: some View {
        HStack(spacing: 8) {
            mainAreaButton(.chats, title: "Chats", symbol: "bubble.left.and.bubble.right")
            mainAreaButton(.conversation, title: "Project Conversations", symbol: "text.bubble")
            if !model.isLocalProviderContext {
                mainAreaButton(.autonomous, title: "Autonomous Workflow", symbol: "point.3.connected.trianglepath.dotted")
                mainAreaButton(.extensions, title: "Skills & MCP", symbol: "puzzlepiece.extension")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    func mainAreaButton(_ area: MainArea, title: String, symbol: String) -> some View {
        Button {
            mainArea = area
            switch area {
            case .chats:
                model.isProjectConversationActive = false
            case .conversation:
                model.chats.selectedDiscussionID = nil
                model.isProjectConversationActive = model.selectedSessionID != nil
            case .autonomous, .extensions:
                model.chats.selectedDiscussionID = nil
                model.isProjectConversationActive = model.selectedSessionID != nil
            }
        } label: {
            Label(model.localized(title), systemImage: symbol)
                .font(.callout.weight(mainArea == area ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(mainArea == area ? Color.accentColor.opacity(0.14) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mainArea == area ? .isSelected : [])
    }

    @ViewBuilder
    var mainAreaContent: some View {
        switch mainArea {
        case .chats:
            chatsPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
        case .conversation:
            conversationPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(14)
        case .autonomous:
            if model.isLocalProviderContext {
                ContentUnavailableView("Not available for local models", systemImage: "desktopcomputer", description: Text("Local mode supports read-only project chat and discussion. Autonomy, write access, terminal, Skills, and MCP are unavailable for this local session."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AutonomousWorkflowView(model: model) { sessionID in
                    model.openProjectSession(sessionID)
                    mainArea = .conversation
                }
            }
        case .extensions:
            if model.isLocalProviderContext {
                ContentUnavailableView("Not available for local models", systemImage: "desktopcomputer", description: Text("Skills and MCP are unavailable for local sessions."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ActiveExtensionsView(model: model)
                        extensionPolicyPanel
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    var statusBar: some View {
        HStack(spacing: 8) {
            if model.isRunning || model.isSwitchingTarget || model.terminal.terminalRunning { ProgressView().controlSize(.small) }
            Text(model.localized(model.status)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(appVersionFooterText).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
    }

    var appVersionFooterText: String {
        let version = appBundleMetadata("CFBundleShortVersionString")
        let build = appBundleMetadata("CFBundleVersion")

        switch (version, build) {
        case let (.some(version), .some(build)):
            return model.localizedFormat("AgentBridge %@ · Build %@", version, build)
        case let (.some(version), .none):
            return model.localizedFormat("AgentBridge %@", version)
        case let (.none, .some(build)):
            return model.localizedFormat("AgentBridge · Build %@", build)
        case (.none, .none):
            return model.localized("AgentBridge")
        }
    }

    func appBundleMetadata(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}
