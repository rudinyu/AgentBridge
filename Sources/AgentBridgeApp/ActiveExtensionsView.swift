import AppKit
import AgentBridgeCore
import SwiftUI
import UniformTypeIdentifiers

/// Skills & MCP: one row per imported Skill, MCP server, or Mac Control preset,
/// each with one main button for its state. Adding goes through the Add menu,
/// enabling through `ExtensionReviewSheet`, and the scope is one line with its
/// controls behind Change… (`ExtensionScopeSheet`).
struct ActiveExtensionsView: View {
    @Bindable var model: AppModel

    /// A scope session picked under Change…; nil follows the selected project session.
    @State private var chosenScopeSessionID: UUID?
    @State private var rowStates: [String: ExtensionRowState] = [:]
    @State private var controlSessions: [String: [SessionRecord]] = [:]
    @State private var isImportingSkill = false
    @State private var isImportingMCP = false
    @State private var skillDraft: SkillImportDraft?
    @State private var isShowingMacControlSetup = false
    @State private var isShowingScopeSheet = false
    @State private var reviewTarget: ExtensionReviewTarget?
    @State private var pendingTest: ActiveExtensionConfigurationSummary?
    @State private var pendingDisable: ActiveExtensionConfigurationSummary?
    @State private var testingID: String?
    @State private var localError: String?
    @State private var localStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            scopeLine
            configurationList
            messages
        }
        .fileImporter(
            isPresented: $isImportingSkill,
            allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText],
            allowsMultipleSelection: false,
            onCompletion: chooseSkillFile
        )
        .fileImporter(
            isPresented: $isImportingMCP,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: importMCP
        )
        .sheet(item: $skillDraft) { draft in
            SkillImportSheet(model: model, draft: draft) { snapshot in
                localError = nil
                localStatus = model.localizedFormat("Imported Skill instructions with SHA-256 %@. No script was executed.", snapshot.contentDigest)
                refreshRows()
            }
            .environment(\.locale, model.appLanguage.locale)
        }
        .sheet(isPresented: $isShowingMacControlSetup) {
            MacControlPresetSetupView(model: model) { _ in
                localError = nil
                localStatus = ""
                refreshRows()
            }
            .environment(\.locale, model.appLanguage.locale)
        }
        .sheet(isPresented: $isShowingScopeSheet) {
            ExtensionScopeSheet(model: model, currentScope: scopeSession) { sessionID in
                chosenScopeSessionID = sessionID
            }
            .environment(\.locale, model.appLanguage.locale)
        }
        .sheet(item: $reviewTarget) { target in
            ExtensionReviewSheet(model: model, configurationID: target.id, scopeSession: scopeSession) { status in
                localError = nil
                localStatus = status
                refreshRows()
            }
            .environment(\.locale, model.appLanguage.locale)
        }
        .confirmationDialog(
            model.localized("Start the selected MCP process?"),
            isPresented: Binding(get: { pendingTest != nil }, set: { if !$0 { pendingTest = nil } }),
            titleVisibility: .visible,
            presenting: pendingTest
        ) { configuration in
            Button(model.localized("Test connection"), role: .destructive) { testConnection(configuration) }
            Button(model.localized("Cancel"), role: .cancel) { }
        } message: { configuration in
            Text(model.localized(ExtensionRowKind(configuration) == .macControl
                ? "Test Connection checks this exact Mac Control preset with initialize and tools/list only. It does not capture the screen, send input, call a Mac Control action, or contact a model."
                : "The configured executable will run as your macOS user. It may access files, network resources, and credentials available to that account. Test Connection performs initialize and tools/list only; it does not call an MCP tool or a model. The tool allowlist is not an operating-system sandbox."))
        }
        .confirmationDialog(
            model.localized("Disable this extension for the selected scope?"),
            isPresented: Binding(get: { pendingDisable != nil }, set: { if !$0 { pendingDisable = nil } }),
            titleVisibility: .visible,
            presenting: pendingDisable
        ) { configuration in
            Button(model.localized("Disable"), role: .destructive) { disable(configuration) }
            Button(model.localized("Cancel"), role: .cancel) { }
        }
        .onChange(of: model.appLanguage) { _, _ in
            localStatus = ""
            localError = nil
        }
        .onAppear {
            model.extensions.refreshActiveExtensionConfigurations()
            model.refresh()
            refreshRows()
        }
        .onChange(of: model.extensions.activeExtensionConfigurations) { _, _ in refreshRows() }
        .onChange(of: model.sessions) { _, _ in refreshRows() }
        .onChange(of: scopeSession?.id) { _, _ in refreshRows() }
    }

    private var heading: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Skills & MCP")
                    .font(.title2.weight(.semibold))
                Text("Importing never runs anything. MCP servers run only when you test them, and nothing is used by a provider until you review and enable it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                model.extensions.refreshActiveExtensionConfigurations()
                refreshRows()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            addMenu
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Skill from SKILL.md…") { isImportingSkill = true }
            Button("MCP server from JSON…") { isImportingMCP = true }
            Button("Mac Control preset…") { isShowingMacControlSetup = true }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .fixedSize()
        .disabled(!model.canStartAutonomousWorkflow)
        .help(model.localized("Skill imports keep only the SKILL.md text, up to 64 KiB. MCP imports read a JSON manifest with an absolute executable, separate arguments, and exact allowed tools; no shell is used."))
    }

    private var scopeLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
                .foregroundStyle(.secondary)
            if let scope = scopeSession {
                Text(model.localizedFormat(
                    "Applies to %@ · %@ · %@",
                    URL(fileURLWithPath: scope.sourceRepositoryPath).lastPathComponent,
                    scope.provider == .codex ? "Codex" : "Claude",
                    model.profileName(for: scope)
                ))
                .font(.callout)
                if let profile = model.boundProfile(for: scope), !profile.allowsSharedMemory {
                    Image(systemName: "hand.raised")
                        .foregroundStyle(.orange)
                        .help(model.localized("This account has not allowed shared memory. Cross-provider task and diff transfer will be blocked by its consent setting."))
                }
            } else {
                Text("No project session to enable extensions for. Choose or create one.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Button("Change…") { isShowingScopeSheet = true }
                .disabled(model.hasActiveAutonomousWorkflow)
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var configurationList: some View {
        let configurations = model.extensions.activeExtensionConfigurations
        if configurations.isEmpty {
            Text("Nothing imported yet. Use Add to import a Skill, an MCP server, or a Mac Control preset.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 0) {
                ForEach(configurations) { configuration in
                    row(configuration)
                    if configuration.id != configurations.last?.id { Divider() }
                }
            }
            .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func row(_ configuration: ActiveExtensionConfigurationSummary) -> some View {
        let state = rowState(configuration)
        let action = state.primaryAction
        return HStack(spacing: 10) {
            Image(systemName: state.kind.systemImage)
                .frame(width: 22)
                .foregroundStyle(state.isEnabled ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(ExtensionRowTitle.title(configuration, language: model.appLanguage))
                    .font(.callout.weight(.semibold))
                Text(state.statusLine(language: model.appLanguage))
                    .font(.caption)
                    .foregroundStyle(state.isEnabled ? Color.green : Color.secondary)
            }
            Spacer()
            if testingID == configuration.id {
                ProgressView().controlSize(.small)
            }
            Button(model.localized(action.title), role: action == .disable || action == .stopControl ? .destructive : nil) {
                perform(action, on: configuration)
            }
            .buttonStyle(.borderedProminent)
            .tint(action == .disable || action == .stopControl ? .red : .accentColor)
            .disabled(!isEnabled(action))
            rowMenu(configuration, state: state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func rowMenu(_ configuration: ActiveExtensionConfigurationSummary, state: ExtensionRowState) -> some View {
        Menu {
            Button("Show details") { reviewTarget = ExtensionReviewTarget(id: configuration.id) }
            if state.kind.needsConnectionTest && state.isTested {
                Button("Test connection again") { pendingTest = configuration }
                    .disabled(!model.canStartAutonomousWorkflow || testingID != nil)
            }
            // Control can be enabled for other scopes too; each can be stopped here.
            ForEach(controlSessions[configuration.id] ?? []) { session in
                Button(model.localizedFormat("Stop Control · %@", String(session.id.uuidString.prefix(8)))) {
                    stopControl(configuration, sessionID: session.id)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(model.localized("More actions"))
    }

    @ViewBuilder
    private var messages: some View {
        if let error = localError ?? model.extensions.activeExtensionError {
            Label(model.localized(error), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        if !localStatus.isEmpty || !model.extensions.activeExtensionStatus.isEmpty {
            Label(model.localized(localStatus.isEmpty ? model.extensions.activeExtensionStatus : localStatus), systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: State

    private var scopeSession: SessionRecord? {
        let provider: AgentProvider = .codex
        let fallback = ExtensionScopeResolver.matchingSessions(
            model.sessions,
            repositoryPath: model.repositoryPath,
            provider: provider,
            profileID: model.selectedProfileIDs[provider]
        )
        return ExtensionScopeResolver.resolve(
            chosenSessionID: chosenScopeSessionID,
            selectedSession: model.selectedSession,
            fallback: fallback,
            sessions: model.sessions
        )
    }

    private func rowState(_ configuration: ActiveExtensionConfigurationSummary) -> ExtensionRowState {
        rowStates[configuration.id] ?? ExtensionRowState(configuration: configuration, isTested: false, isEnabled: false)
    }

    private func isEnabled(_ action: ExtensionRowAction) -> Bool {
        switch action {
        case .testConnection: model.canStartAutonomousWorkflow && testingID == nil
        case .reviewAndEnable: scopeSession != nil && testingID == nil
        case .disable: scopeSession != nil && !model.hasActiveAutonomousWorkflow
        case .stopControl: scopeSession != nil
        }
    }

    /// Reads, for each row, whether its current digest was tested and whether
    /// it is enabled for the scope, without starting anything.
    private func refreshRows() {
        let configurations = model.extensions.activeExtensionConfigurations
        var enabledIDs = Set<String>()
        if let scopeSession {
            do {
                enabledIDs = Set(try model.extensions.activeExtensionsForSession(sessionID: scopeSession.id).extensionIDs)
            } catch {
                localError = error.localizedDescription
            }
        }
        var states: [String: ExtensionRowState] = [:]
        var control: [String: [SessionRecord]] = [:]
        for configuration in configurations {
            let kind = ExtensionRowKind(configuration)
            let tested = kind.needsConnectionTest
                ? ((try? model.extensions.activeExtensionInspection(extensionID: configuration.id)) ?? nil) != nil
                : true
            states[configuration.id] = ExtensionRowState(configuration: configuration, isTested: tested, isEnabled: enabledIDs.contains(configuration.id))
            if configuration.macControlAccessMode == .control {
                control[configuration.id] = model.sessions.filter { session in
                    guard let invocation = try? model.extensions.activeExtensionsForSession(sessionID: session.id) else { return false }
                    return invocation.mcpServers.contains { $0.extensionID == configuration.id }
                }
            }
        }
        rowStates = states
        controlSessions = control
    }

    // MARK: Actions

    private func perform(_ action: ExtensionRowAction, on configuration: ActiveExtensionConfigurationSummary) {
        switch action {
        case .testConnection: pendingTest = configuration
        case .reviewAndEnable: reviewTarget = ExtensionReviewTarget(id: configuration.id)
        case .disable: pendingDisable = configuration
        case .stopControl:
            if let scopeSession { stopControl(configuration, sessionID: scopeSession.id) }
        }
    }

    private func chooseSkillFile(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            guard url.lastPathComponent == "SKILL.md" else {
                throw AgentBridgeError.invalidInput("Choose a file named SKILL.md.")
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            // Only for pre-filling the fields; the import reads the file again itself.
            let contents = (try? BoundedDescriptorFileReader.read(at: url)).map { String(decoding: $0, as: UTF8.self) }
            localError = nil
            skillDraft = SkillImportDraft.prefill(fileURL: url, contents: contents)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func importMCP(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let configuration = try model.extensions.importMCPRuntimeManifest(at: url)
            localError = nil
            localStatus = model.localizedFormat("Imported MCP configuration %@. The process has not been started.", configuration.configurationDigest)
            refreshRows()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func testConnection(_ configuration: ActiveExtensionConfigurationSummary) {
        let kind = ExtensionRowKind(configuration)
        testingID = configuration.id
        localError = nil
        localStatus = model.localized(kind == .macControl
            ? "Testing the selected Mac Control preset's initialize and tools/list handshake…"
            : "Testing the selected MCP's initialize and tools/list handshake…")
        Task { @MainActor in
            defer {
                testingID = nil
                refreshRows()
            }
            do {
                let result = try await model.extensions.testRuntimeConnection(configuration)
                localStatus = kind == .macControl
                    ? model.localizedFormat("Mac Control Test Connection succeeded. Discovered %@ tools. No screenshot was captured, no input or Mac Control action was sent, and no model was contacted.", String(result.toolNames.count))
                    : model.localizedFormat("Test Connection succeeded. Discovered %@ tools; no tool or model was called.", String(result.toolNames.count))
            } catch {
                localError = error.localizedDescription
                localStatus = ""
            }
        }
    }

    private func disable(_ configuration: ActiveExtensionConfigurationSummary) {
        guard let scopeSession else { return }
        do {
            _ = try model.extensions.disableExtensionRuntime(extensionID: configuration.id, sessionID: scopeSession.id)
            localError = nil
            localStatus = model.localized("The extension was disabled for the selected project/provider/profile scope.")
            model.refresh()
            refreshRows()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func stopControl(_ configuration: ActiveExtensionConfigurationSummary, sessionID: UUID) {
        do {
            let cancelled = try model.extensions.stopMacControl(extensionID: configuration.id, sessionID: sessionID)
            localError = nil
            localStatus = cancelled.isEmpty
                ? model.localized("Control was revoked. No active provider workflow used this exact scope.")
                : model.localizedFormat("Control was revoked and cancellation was sent to %@ affected provider session(s).", String(cancelled.count))
            refreshRows()
        } catch {
            localError = error.localizedDescription
        }
    }
}

struct ExtensionReviewTarget: Identifiable {
    let id: String
}
