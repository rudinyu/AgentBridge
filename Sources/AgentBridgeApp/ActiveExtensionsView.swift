import AppKit
import AgentBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct ActiveExtensionsView: View {
    @Bindable var model: AppModel

    @State private var selectedExtensionID = ""
    @State private var skillID = ""
    @State private var skillName = ""
    @State private var skillSummary = ""
    @State private var isImportingSkill = false
    @State private var isImportingMCP = false
    @State private var selectedSkillContentURL: URL?
    @State private var targetProvider: AgentProvider = .codex
    @State private var targetProfileID: UUID?
    @State private var targetSessionID: UUID?
    @State private var review: ActiveExtensionActivationReview?
    @State private var inspection: MCPServerInspection?
    @State private var isCurrentlyEnabled = false
    @State private var isTesting = false
    @State private var isCreatingTarget = false
    @State private var executionConsent = false
    @State private var showTestConfirmation = false
    @State private var showEnableConfirmation = false
    @State private var showDisableConfirmation = false
    @State private var localError: String?
    @State private var localStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading
            importPanel
            configurationPanel
            targetScopePanel
            if let config = selectedConfiguration, !config.id.hasPrefix("mac-control.") {
                activationPanel(config)
            }
            MacControlPresetView(
                model: model,
                selectedConfigurationID: selectedExtensionID.hasPrefix("mac-control.") ? selectedExtensionID : nil,
                scopeSessionID: scopeSession?.id,
                onImported: { configurationID in
                    selectedExtensionID = configurationID
                    review = nil
                    executionConsent = false
                    refreshScopeState()
                }
            )
            if let error = localError ?? model.activeExtensionError {
                Label(model.localized(error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if !localStatus.isEmpty || !model.activeExtensionStatus.isEmpty {
                Label(model.localized(localStatus.isEmpty ? model.activeExtensionStatus : localStatus), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .fileImporter(
            isPresented: $isImportingSkill,
            allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText],
            allowsMultipleSelection: false,
            onCompletion: importSkill
        )
        .fileImporter(
            isPresented: $isImportingMCP,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: importMCP
        )
        .confirmationDialog(
            "Start the selected MCP process?",
            isPresented: $showTestConfirmation,
            titleVisibility: .visible
        ) {
            Button("Test Connection", role: .destructive) { testSelectedMCP() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The configured executable will run as your macOS user. It may access files, network resources, and credentials available to that account. Test Connection performs initialize and tools/list only; it does not call an MCP tool or a model. The tool allowlist is not an operating-system sandbox.")
        }
        .confirmationDialog(
            "Enable this exact extension configuration?",
            isPresented: $showEnableConfirmation,
            titleVisibility: .visible
        ) {
            Button("Enable for this scope", role: .destructive) { enableSelectedExtension() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enable only after reviewing the content, command, tool allowlist, digest, and selected project/provider/profile. Existing sessions keep their pinned extension snapshot.")
        }
        .confirmationDialog(
            "Disable this extension for the selected scope?",
            isPresented: $showDisableConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disable", role: .destructive) { disableSelectedExtension() }
            Button("Cancel", role: .cancel) { }
        }
        .onAppear {
            synchronizeTargetProfile()
            model.refreshActiveExtensionConfigurations()
            model.refresh()
        }
        .onChange(of: model.accountProfiles) { _, _ in synchronizeTargetProfile() }
        .onChange(of: model.repositoryPath) { _, _ in resetScopeReview() }
        .onChange(of: targetProvider) { _, _ in
            targetProfileID = model.selectedProfileIDs[targetProvider]
            targetSessionID = nil
            resetScopeReview()
        }
        .onChange(of: targetProfileID) { _, _ in
            targetSessionID = nil
            resetScopeReview()
        }
        .onChange(of: targetSessionID) { _, _ in
            resetScopeReview()
            refreshScopeState()
        }
        .onChange(of: selectedExtensionID) { _, _ in
            review = nil
            inspection = nil
            executionConsent = false
            localError = nil
            localStatus = ""
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Skills & MCP")
                .font(.title2.weight(.semibold))
            Text("Import bounded Skill instructions or a direct-argv MCP manifest. Inspect the exact contents and digest, test MCP explicitly, then enable the runtime for one project, provider, and account profile.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Imported configuration is not active. Older metadata grants never enable a runtime. No MCP process starts until you select Test Connection.", systemImage: "hand.raised")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var importPanel: some View {
        GroupBox("Import runtime configuration") {
            VStack(alignment: .leading, spacing: 9) {
                Text("Skill imports snapshot only SKILL.md instruction text, capped at 64 KiB. Referenced scripts, hooks, installers, and dependencies are never run.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Skill ID", text: $skillID)
                    TextField("Skill name", text: $skillName)
                    TextField("Summary (optional)", text: $skillSummary)
                    Button("Choose SKILL.md…") { isImportingSkill = true }
                        .disabled(!model.canStartAutonomousWorkflow)
                }
                Text("MCP configuration uses a JSON manifest with an absolute executable path, a JSON `args` array, exact `allowedTools`, and bounded startup/tool timeouts. Arguments are passed directly; no shell is used.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Import MCP JSON…") { isImportingMCP = true }
                        .disabled(!model.canStartAutonomousWorkflow)
                    Spacer()
                    Button("Refresh configurations") { model.refreshActiveExtensionConfigurations() }
                }
                if !model.activeExtensionConfigurations.isEmpty {
                    HStack(spacing: 12) {
                        Text("\(model.activeExtensionConfigurations.count) runtime configuration(s) imported")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Import does not enable or execute a runtime.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.vertical, 4)
        }
    }

    private var configurationPanel: some View {
        GroupBox("Imported runtime configurations") {
            VStack(alignment: .leading, spacing: 8) {
                if model.activeExtensionConfigurations.isEmpty {
                    Text("No active runtime configurations imported yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Configuration", selection: $selectedExtensionID) {
                        Text("Choose a Skill, MCP, or Mac Control preset").tag("")
                        ForEach(model.activeExtensionConfigurations) { configuration in
                            Text("\(configuration.kind.rawValue.uppercased()) · \(configuration.name)")
                                .tag(configuration.id)
                        }
                    }
                    ForEach(model.activeExtensionConfigurations) { configuration in
                        if selectedExtensionID.isEmpty || selectedExtensionID == configuration.id {
                            configurationSummary(configuration)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func configurationSummary(_ configuration: ActiveExtensionConfigurationSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(configuration.name) · v\(configuration.version)")
                .font(.caption.weight(.semibold))
            if !configuration.summary.isEmpty {
                Text(configuration.summary).font(.caption2).foregroundStyle(.secondary)
            }
            Text("ID: \(configuration.id) · configuration SHA-256: \(configuration.configurationDigest)")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            Text("Source: \(configuration.sourceReference)")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            if let skillDigest = configuration.skillDigest {
                Text("Skill content SHA-256: \(skillDigest)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let command = configuration.executablePath {
                Text("Command: \(command)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                Text("Arguments: \(configuration.arguments.map(\.debugDescription).joined(separator: " "))")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                ForEach(configuration.entrypointPins, id: \.path) { pin in
                    Text("Pinned entrypoint: \(pin.path) · SHA-256 \(pin.digest)")
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("Exact allowed tools: \(configuration.allowedTools.joined(separator: ", "))")
                    .font(.caption2)
                    .textSelection(.enabled)
                Text("Startup timeout: \(configuration.startupTimeoutSeconds ?? 0)s · tool timeout: \(configuration.toolTimeoutSeconds ?? 0)s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let targetBundleID = configuration.macControlTargetBundleID {
                Text("Target app bundle ID: \(targetBundleID)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                Text("Mac Control mode: \(configuration.macControlAccessMode?.rawValue.capitalized ?? "unknown") · actions: \(configuration.macControlActionNames.joined(separator: ", "))")
                    .font(.caption2)
                    .textSelection(.enabled)
                if let disclosure = configuration.screenCaptureDisclosure {
                    Label(disclosure, systemImage: "eye")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let calls = configuration.maximumToolCallsPerRun,
                   let responseBytes = configuration.maximumToolResponseBytes,
                   let totalBytes = configuration.maximumTotalToolResponseBytes {
                    Text("Tool limits: \(calls) calls · \(responseBytes) bytes per response · \(totalBytes) bytes total")
                        .font(.caption2)
                }
            }
            Divider()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var targetScopePanel: some View {
        GroupBox("Project, provider, and profile scope") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Git repository path", text: $model.repositoryPath)
                        .disabled(model.hasActiveAutonomousWorkflow)
                    Button("Choose…") { model.chooseRepository() }
                        .disabled(model.hasActiveAutonomousWorkflow)
                }
                HStack(spacing: 12) {
                    Picker("Provider", selection: $targetProvider) {
                        Text("Codex").tag(AgentProvider.codex)
                        Text("Claude").tag(AgentProvider.claude)
                    }
                    .pickerStyle(.segmented)
                    .disabled(model.hasActiveAutonomousWorkflow)
                    Picker("Profile", selection: Binding(
                        get: { targetProfileID ?? model.selectedProfileIDs[targetProvider] ?? UUID() },
                        set: { targetProfileID = $0 }
                    )) {
                        ForEach(model.accountProfiles[targetProvider] ?? []) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    .disabled((model.accountProfiles[targetProvider] ?? []).isEmpty || model.hasActiveAutonomousWorkflow)
                }
                if let targetProfile, !targetProfile.allowsSharedMemory {
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
                            .disabled(isCreatingTarget || model.repositoryPath.isEmpty || targetProfileID == nil || model.hasActiveAutonomousWorkflow)
                    }
                } else {
                    Picker("Scope session", selection: Binding(
                        get: { targetSessionID ?? matchingSessions.first?.id ?? UUID() },
                        set: { targetSessionID = $0 }
                    )) {
                        ForEach(matchingSessions) { session in
                            Text("\(URL(fileURLWithPath: session.sourceRepositoryPath).lastPathComponent) · \(session.provider.rawValue) · \(model.profileName(for: session)) · \(session.id.uuidString.prefix(8))")
                                .tag(session.id)
                        }
                    }
                    .disabled(model.hasActiveAutonomousWorkflow)
                    if let scopeSession {
                        Text("Selected scope: \(scopeSession.provider.rawValue) · \(model.profileName(for: scopeSession)) · session \(scopeSession.id.uuidString.lowercased())")
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                        if let projectID = try? model.extensionProjectID(sessionID: scopeSession.id) {
                            Text("Project ID: \(projectID)")
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            .padding(.vertical, 4)
        }
    }

    private func activationPanel(_ configuration: ActiveExtensionConfigurationSummary) -> some View {
        GroupBox("Inspect and enable") {
            VStack(alignment: .leading, spacing: 9) {
                if scopeSession != nil {
                    HStack {
                        Button("Preview exact contents and scope") { previewSelectedExtension() }
                        if configuration.kind == .mcp {
                            Button {
                                showTestConfirmation = true
                            } label: {
                                if isTesting { ProgressView().controlSize(.small) }
                                else { Label("Test Connection", systemImage: "bolt.horizontal.circle") }
                            }
                            .disabled(isTesting || !model.canStartAutonomousWorkflow)
                        }
                    }
                    Text(configuration.kind == .mcp
                        ? "Test Connection starts only this imported MCP executable. It performs initialize and tools/list, calls no tool, and does not contact a model."
                        : "Preview shows the exact bounded instruction snapshot. Skills are task-scoped guidance and cannot add tools or expand approvals.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let inspection {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("MCP inspection · SHA-256 \(inspection.inspectionDigest)")
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                            Text("Configuration digest: \(inspection.configurationDigest)")
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                            Text("Tools discovered: \(inspection.toolNames.joined(separator: ", "))")
                                .font(.caption2)
                                .textSelection(.enabled)
                            if !inspection.toolDefinitionsJSON.isEmpty {
                                Text("Exact discovered MCP tool definitions and input schemas")
                                    .font(.caption2.weight(.semibold))
                                ScrollView {
                                    Text(inspection.toolDefinitionsJSON)
                                        .font(.system(size: 9, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                }
                                .frame(maxHeight: 220)
                                .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 6))
                            }
                            ForEach(Array(inspection.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                                Text(model.localized(diagnostic)).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if let review {
                        reviewDetails(review, kind: configuration.kind)
                        Toggle("I reviewed this exact content, digest, command, allowed tools, and project/provider/profile scope, and consent to enable it.", isOn: $executionConsent)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            if isCurrentlyEnabled {
                                Label("Enabled for this exact scope", systemImage: "checkmark.shield.fill")
                                    .foregroundStyle(.green)
                                Spacer()
                                Button("Disable", role: .destructive) { showDisableConfirmation = true }
                                    .disabled(model.hasActiveAutonomousWorkflow)
                            } else {
                                Button("Enable for this project/profile") { showEnableConfirmation = true }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!executionConsent || model.hasActiveAutonomousWorkflow || (configuration.kind == .mcp && inspection?.configurationDigest != review.configurationDigest))
                            }
                        }
                        Text("Changes to the imported content, executable, argv, tool list, or scope change the digest and require a new review. New provider sessions receive the approved snapshot; existing sessions keep their original snapshot.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Preview the selected configuration before enabling. MCP must also pass Test Connection for its current digest.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Choose or create a scope session first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func reviewDetails(_ review: ActiveExtensionActivationReview, kind: ExtensionKind) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Activation review")
                .font(.caption.weight(.semibold))
            Text("Review digest: \(review.reviewedDigest)")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            Text("Configuration digest: \(review.configurationDigest)")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            Text("Scope: \(review.projectID) · \(review.provider.rawValue) · profile \(review.profileID.uuidString.lowercased())")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            if let skillDigest = review.skillDigest {
                Text("Skill content SHA-256: \(skillDigest)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let executable = review.executablePath {
                Text("Exact executable: \(executable)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                Text("Exact argv: \(review.arguments.map(\.debugDescription).joined(separator: " "))")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                ForEach(review.entrypointPins, id: \.path) { pin in
                    Text("Pinned entrypoint: \(pin.path) · SHA-256 \(pin.digest)")
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("Allowed MCP tools: \(review.allowedTools.joined(separator: ", "))")
                    .font(.caption2)
                    .textSelection(.enabled)
                Text("Discovered tools: \(review.inspectedTools.joined(separator: ", "))")
                    .font(.caption2)
                    .textSelection(.enabled)
                if let definitions = review.toolDefinitionsJSON {
                    Text("Exact discovered MCP tool definitions and input schemas")
                        .font(.caption2.weight(.semibold))
                    ScrollView {
                        Text(definitions)
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 220)
                    .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Text(model.localized(review.trustWarning))
                .font(.caption2)
                .foregroundStyle(kind == .mcp ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if kind == .skill, let instructionText = review.instructionText {
                Text("Exact imported Skill instructions")
                    .font(.caption.weight(.semibold))
                ScrollView {
                    Text(instructionText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 240)
                .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
    }

    private var selectedConfiguration: ActiveExtensionConfigurationSummary? {
        model.activeExtensionConfigurations.first(where: { $0.id == selectedExtensionID })
    }

    private var targetProfile: AccountProfile? {
        let id = targetProfileID ?? model.selectedProfileIDs[targetProvider]
        return model.accountProfiles[targetProvider]?.first(where: { $0.id == id })
    }

    private var matchingSessions: [SessionRecord] {
        guard !model.repositoryPath.isEmpty, let profile = targetProfile else { return [] }
        let path = URL(fileURLWithPath: model.repositoryPath, isDirectory: true).standardizedFileURL.path
        return model.sessions.filter {
            let sessionProfileID = $0.accountProfileID ?? AccountProfile.defaultID(for: $0.provider)
            return URL(fileURLWithPath: $0.sourceRepositoryPath, isDirectory: true).standardizedFileURL.path == path
                && $0.provider == targetProvider
                && sessionProfileID == profile.id
        }
    }

    private var scopeSession: SessionRecord? {
        matchingSessions.first(where: { $0.id == targetSessionID }) ?? matchingSessions.first
    }

    private func synchronizeTargetProfile() {
        if targetProfileID == nil || !(model.accountProfiles[targetProvider] ?? []).contains(where: { $0.id == targetProfileID }) {
            targetProfileID = model.selectedProfileIDs[targetProvider]
        }
        if targetSessionID == nil || !matchingSessions.contains(where: { $0.id == targetSessionID }) {
            targetSessionID = matchingSessions.first?.id
        }
    }

    private func resetScopeReview() {
        review = nil
        isCurrentlyEnabled = false
        executionConsent = false
        localError = nil
    }

    private func refreshScopeState() {
        guard let scopeSession, !selectedExtensionID.isEmpty else { return }
        do {
            let invocation = try model.activeExtensionsForSession(sessionID: scopeSession.id)
            isCurrentlyEnabled = invocation.skills.contains(where: { $0.extensionID == selectedExtensionID })
                || invocation.mcpServers.contains(where: { $0.extensionID == selectedExtensionID })
        } catch {
            localError = error.localizedDescription
        }
    }

    private func createScopeSession() {
        guard let profile = targetProfile else { return }
        isCreatingTarget = true
        localError = nil
        Task { @MainActor in
            defer { isCreatingTarget = false }
            do {
                let session = try await model.createExtensionTargetSession(sourcePath: model.repositoryPath, provider: targetProvider, profileID: profile.id)
                model.refresh()
                targetSessionID = session.id
                localStatus = model.localized("A read-only scope session was created. No provider model was started.")
            } catch {
                localError = error.localizedDescription
            }
        }
    }

    private func importSkill(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            guard url.lastPathComponent == "SKILL.md" else {
                throw AgentBridgeError.invalidInput("Choose a file named SKILL.md.")
            }
            let id = skillID.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = skillName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, !name.isEmpty else {
                throw AgentBridgeError.invalidInput("Enter a Skill ID and display name before importing.")
            }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let descriptor = try ExtensionDescriptor(
                id: id,
                kind: .skill,
                name: name,
                version: "1",
                summary: skillSummary.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            let snapshot = try model.importSkillRuntime(descriptor: descriptor, sourceReference: url.path, skillFileURL: url)
            selectedExtensionID = snapshot.extensionID
            skillID = ""
            skillName = ""
            skillSummary = ""
            inspection = nil
            review = nil
            localError = nil
            localStatus = model.localizedFormat("Imported Skill instructions with SHA-256 %@. No script was executed.", snapshot.contentDigest)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func importMCP(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let configuration = try model.importMCPRuntimeManifest(at: url)
            selectedExtensionID = configuration.extensionID
            inspection = nil
            review = nil
            localError = nil
            localStatus = model.localizedFormat("Imported MCP configuration %@. The process has not been started.", configuration.configurationDigest)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func testSelectedMCP() {
        guard let configuration = selectedConfiguration, configuration.kind == .mcp else { return }
        isTesting = true
        localError = nil
        localStatus = model.localized("Testing the selected MCP's initialize and tools/list handshake…")
        Task { @MainActor in
            defer { isTesting = false }
            do {
                let result = try await model.testMCPRuntime(extensionID: configuration.id)
                inspection = result
                review = nil
                executionConsent = false
                localStatus = model.localizedFormat("Test Connection succeeded. Discovered %@ tools; no tool or model was called.", String(result.toolNames.count))
            } catch {
                localError = error.localizedDescription
                localStatus = ""
            }
        }
    }

    private func previewSelectedExtension() {
        guard let scopeSession, let configuration = selectedConfiguration else { return }
        do {
            review = try model.previewExtensionActivation(extensionID: configuration.id, sessionID: scopeSession.id)
            executionConsent = false
            localError = nil
            refreshScopeState()
            localStatus = model.localized("Review the exact configuration and digest before enabling it.")
        } catch {
            localError = error.localizedDescription
        }
    }

    private func enableSelectedExtension() {
        guard let review, let scopeSession else { return }
        do {
            let grant = try model.enableExtensionRuntime(
                extensionID: review.extensionID,
                sessionID: scopeSession.id,
                reviewedDigest: review.reviewedDigest,
                explicitExecutionConsent: executionConsent
            )
            isCurrentlyEnabled = true
            executionConsent = false
            localError = nil
            localStatus = model.localizedFormat("Enabled for project %@, %@ profile %@.", grant.projectID, grant.provider.rawValue, grant.profileID.uuidString.lowercased())
            model.refresh()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func disableSelectedExtension() {
        guard let activationReview = review, let scopeSession else { return }
        do {
            _ = try model.disableExtensionRuntime(extensionID: activationReview.extensionID, sessionID: scopeSession.id)
            isCurrentlyEnabled = false
            self.review = nil
            executionConsent = false
            localError = nil
            localStatus = model.localized("The extension was disabled for the selected project/provider/profile scope.")
            model.refresh()
        } catch {
            localError = error.localizedDescription
        }
    }
}

private struct MacControlPresetView: View {
    @Bindable var model: AppModel
    let selectedConfigurationID: String?
    let scopeSessionID: UUID?
    var onImported: (String) -> Void

    @State private var targetBundleID = ""
    @State private var accessMode: MacControlAccessMode = .observe
    @State private var review: ActiveExtensionActivationReview?
    @State private var executionConsent = false
    @State private var screenCaptureConsent = false
    @State private var inputControlConsent = false
    @State private var isEnabled = false
    @State private var inspection: MCPServerInspection?
    @State private var isTestingConnection = false
    @State private var enabledControlSessions: [SessionRecord] = []
    @State private var localError: String?
    @State private var localStatus = ""

    var body: some View {
        GroupBox("Mac Control desktop preset") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Mac Control uses AgentBridge's typed proxy and the installed helper. It never passes the raw helper to a provider.", systemImage: "desktopcomputer")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Label("No helper process, screenshot, or input starts until you explicitly choose a status test or enable a reviewed preset. The status test reads macOS permission readiness only and never requests TCC access.", systemImage: "hand.raised")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    TextField("Target app bundle ID", text: $targetBundleID)
                        .textFieldStyle(.roundedBorder)
                        .disabled(model.hasActiveAutonomousWorkflow || model.isTestingMCPRuntime || isTestingConnection)
                    Button("Choose app…", action: chooseTargetApp)
                        .disabled(model.hasActiveAutonomousWorkflow || model.isTestingMCPRuntime || isTestingConnection)
                }
                Picker("Access mode", selection: $accessMode) {
                    Text("Observe").tag(MacControlAccessMode.observe)
                    Text("Control").tag(MacControlAccessMode.control)
                }
                .pickerStyle(.segmented)
                .disabled(model.hasActiveAutonomousWorkflow || model.isTestingMCPRuntime || isTestingConnection)
                Text(accessMode == .observe
                    ? "Observe allows only the built-in observation actions."
                    : "Control adds input actions for the selected app and requires its own explicit consent.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Check installed helper") {
                        model.refreshMacControlPresetStatus(
                            targetBundleID: trimmedTargetBundleID.isEmpty ? nil : trimmedTargetBundleID,
                            accessMode: accessMode
                        )
                    }
                    .disabled(model.hasActiveAutonomousWorkflow)
                    Button {
                        checkPermissionReadiness()
                    } label: {
                        if model.isCheckingMacControlPermissions { ProgressView().controlSize(.small) }
                        else { Label("Test permission readiness", systemImage: "checkmark.shield") }
                    }
                    .disabled(!canTestPermissionReadiness)
                    Spacer()
                    Button(accessMode == .observe ? "Import Observe preset" : "Import Control preset") {
                        importPreset()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canImportPreset)
                }

                if let status = model.detectedMacControlPresetStatus {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.localized(status.message))
                            .font(.caption2)
                            .foregroundStyle(status.helperAvailable && status.proxyAvailable ? Color.secondary : Color.orange)
                        if let path = status.helperPath {
                            Text("Trusted MacControl helper: \(path)")
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let digest = status.helperDigest {
                            Text("Helper SHA-256: \(digest)")
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let path = status.proxyExecutablePath {
                            Text("AgentBridge proxy: \(path)")
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        if let digest = status.proxyExecutableDigest {
                            Text("Proxy SHA-256: \(digest)")
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 6))
                }

                if let readiness = model.macControlPermissionReadiness,
                   readiness.targetBundleID == trimmedTargetBundleID {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Permission readiness · \(readiness.checkedAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption.weight(.semibold))
                        Text("Helper available: \(readiness.helperAvailable ? "yes" : "no") · status tool available: \(readiness.statusToolAvailable ? "yes" : "no")")
                            .font(.caption2)
                        Text(readiness.statusText.isEmpty ? "No permission status was returned." : readiness.statusText)
                            .font(.caption2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("If macOS permissions are missing, grant them manually in System Settings. AgentBridge never opens a TCC prompt automatically.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 6))
                }

                if let configuration = selectedConfiguration {
                    selectedPresetDetails(configuration)
                } else {
                    Text("Importing a preset stores a typed configuration only. Preview it for the selected project/provider/profile, inspect its digest and exact actions, then enable it explicitly.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let error = localError ?? model.macControlStatusError {
                    Label(model.localized(error), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !localStatus.isEmpty {
                    Label(model.localized(localStatus), systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear(perform: synchronizeSelectedConfiguration)
        .onChange(of: selectedConfigurationID) { _, _ in
            inspection = nil
            localStatus = ""
            synchronizeSelectedConfiguration()
        }
        .onChange(of: model.activeExtensionConfigurations) { _, _ in
            if let review, review.configurationDigest != selectedConfiguration?.configurationDigest {
                self.review = nil
                resetConsents()
            }
            if inspection?.extensionID != selectedConfiguration?.id
                || inspection?.configurationDigest != selectedConfiguration?.configurationDigest {
                inspection = nil
            }
            refreshEnabledState()
        }
        .onChange(of: model.sessions) { _, _ in refreshEnabledState() }
        .onChange(of: scopeSessionID) { _, _ in
            review = nil
            resetConsents()
            refreshEnabledState()
        }
        .onChange(of: accessMode) { _, _ in
            inspection = nil
            localStatus = ""
            review = nil
            resetConsents()
        }
        .onChange(of: targetBundleID) { _, _ in
            inspection = nil
            localStatus = ""
            if selectedConfiguration?.macControlTargetBundleID != trimmedTargetBundleID {
                review = nil
                resetConsents()
            }
        }
    }

    private var trimmedTargetBundleID: String {
        targetBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedConfiguration: ActiveExtensionConfigurationSummary? {
        guard let selectedConfigurationID else { return nil }
        return model.activeExtensionConfigurations.first(where: {
            $0.id == selectedConfigurationID && $0.macControlTargetBundleID != nil
        })
    }

    private var canTestPermissionReadiness: Bool {
        model.canStartAutonomousWorkflow
            && !isTestingConnection
            && !model.isTestingMCPRuntime
            && MacControlActionPolicy.isAllowedTarget(trimmedTargetBundleID)
    }

    private func canTestConnection(_ configuration: ActiveExtensionConfigurationSummary) -> Bool {
        model.canStartAutonomousWorkflow
            && !isTestingConnection
            && !model.isTestingMCPRuntime
            && !model.isCheckingMacControlPermissions
            && selectedConfiguration?.id == configuration.id
            && configuration.macControlTargetBundleID == trimmedTargetBundleID
            && configuration.macControlAccessMode == accessMode
    }

    private var canImportPreset: Bool {
        model.canStartAutonomousWorkflow
            && !isTestingConnection
            && !model.isTestingMCPRuntime
            && MacControlActionPolicy.isAllowedTarget(trimmedTargetBundleID)
            && model.detectedMacControlPresetStatus?.targetBundleID == trimmedTargetBundleID
            && model.detectedMacControlPresetStatus?.accessMode == accessMode
            && model.detectedMacControlPresetStatus?.helperAvailable == true
            && model.detectedMacControlPresetStatus?.proxyAvailable == true
    }

    private func synchronizeSelectedConfiguration() {
        if let configuration = selectedConfiguration, let target = configuration.macControlTargetBundleID {
            targetBundleID = target
            accessMode = configuration.macControlAccessMode ?? .observe
        }
        model.refreshMacControlPresetStatus(
            targetBundleID: trimmedTargetBundleID.isEmpty ? nil : trimmedTargetBundleID,
            accessMode: accessMode
        )
        refreshEnabledState()
    }

    private func chooseTargetApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Target App"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else {
            if panel.url != nil { localError = "The selected app does not have a bundle identifier." }
            return
        }
        targetBundleID = bundleID
        review = nil
        resetConsents()
        localError = nil
        localStatus = model.localizedFormat("Selected target %@ (%@).", url.lastPathComponent, bundleID)
        model.refreshMacControlPresetStatus(targetBundleID: bundleID, accessMode: accessMode)
    }

    private func importPreset() {
        localError = nil
        localStatus = ""
        do {
            let configuration = try model.importMacControlPreset(
                targetBundleID: trimmedTargetBundleID,
                accessMode: accessMode
            )
            review = nil
            resetConsents()
            onImported(configuration.extensionID)
            localStatus = model.localizedFormat("Imported %@ preset %@. No screen or input access is enabled.", accessMode.rawValue.capitalized, configuration.configurationDigest)
        } catch {
            localError = error.localizedDescription
        }
    }

    private func checkPermissionReadiness() {
        localError = nil
        localStatus = "Checking only the permission status reported by the installed helper…"
        Task { @MainActor in
            do {
                let result = try await model.testMacControlPermissions(targetBundleID: trimmedTargetBundleID)
                _ = result
                localStatus = model.localized("Permission readiness checked. This status-only test did not capture the screen, send input, or request macOS permission.")
            } catch {
                model.macControlStatusError = error.localizedDescription
                localStatus = ""
            }
        }
    }

    private func previewSelectedPreset() {
        guard let selectedConfiguration,
              selectedConfiguration.macControlTargetBundleID == trimmedTargetBundleID,
              selectedConfiguration.macControlAccessMode == accessMode,
              let scopeSessionID else { return }
        do {
            review = try model.previewExtensionActivation(extensionID: selectedConfiguration.id, sessionID: scopeSessionID)
            resetConsents()
            localError = nil
            localStatus = "Review the exact target, actions, screenshot disclosure, scope, and digest before enabling."
            refreshEnabledState()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func testSelectedPresetConnection(_ configuration: ActiveExtensionConfigurationSummary) {
        guard canTestConnection(configuration) else { return }
        isTestingConnection = true
        inspection = nil
        review = nil
        resetConsents()
        localError = nil
        localStatus = model.localized("Testing the selected Mac Control preset's initialize and tools/list handshake…")
        Task { @MainActor in
            defer { isTestingConnection = false }
            do {
                let result = try await model.testMCPRuntime(extensionID: configuration.id)
                guard selectedConfiguration?.id == configuration.id,
                      selectedConfiguration?.configurationDigest == configuration.configurationDigest,
                      configuration.macControlTargetBundleID == trimmedTargetBundleID,
                      configuration.macControlAccessMode == accessMode,
                      result.extensionID == configuration.id,
                      result.configurationDigest == configuration.configurationDigest else {
                    inspection = nil
                    review = nil
                    resetConsents()
                    localStatus = model.localized("The selected preset changed during testing. Select it and test again.")
                    return
                }
                inspection = result
                review = nil
                resetConsents()
                localStatus = model.localizedFormat(
                    "Mac Control Test Connection succeeded. Discovered %@ tools. No screenshot was captured, no input or Mac Control action was sent, and no model was contacted.",
                    String(result.toolNames.count)
                )
            } catch {
                if selectedConfiguration?.id == configuration.id {
                    localError = error.localizedDescription
                    localStatus = ""
                }
            }
        }
    }

    private func enableSelectedPreset() {
        guard let review, let scopeSessionID else { return }
        do {
            let grant = try model.enableExtensionRuntime(
                extensionID: review.extensionID,
                sessionID: scopeSessionID,
                reviewedDigest: review.reviewedDigest,
                explicitExecutionConsent: executionConsent,
                explicitScreenCaptureConsent: screenCaptureConsent,
                explicitInputControlConsent: inputControlConsent
            )
            isEnabled = true
            resetConsents()
            localError = nil
            localStatus = model.localizedFormat("Enabled Mac Control for project %@, %@, profile %@.", grant.projectID, grant.provider.rawValue, grant.profileID.uuidString.lowercased())
        } catch {
            localError = error.localizedDescription
        }
    }

    private func stopControl(sessionID: UUID) {
        guard let selectedConfiguration else { return }
        do {
            let cancelled = try model.stopMacControl(extensionID: selectedConfiguration.id, sessionID: sessionID)
            isEnabled = false
            enabledControlSessions = []
            review = nil
            resetConsents()
            localError = nil
            localStatus = cancelled.isEmpty
                ? model.localized("Control was revoked. No active provider workflow used this exact scope.")
                : model.localizedFormat("Control was revoked and cancellation was sent to %@ affected provider session(s).", String(cancelled.count))
        } catch {
            localError = error.localizedDescription
        }
    }

    private func refreshEnabledState() {
        guard let selectedConfiguration else {
            isEnabled = false
            enabledControlSessions = []
            return
        }
        enabledControlSessions = model.sessions.filter { session in
            guard let invocation = try? model.activeExtensionsForSession(sessionID: session.id) else { return false }
            return invocation.mcpServers.contains { $0.extensionID == selectedConfiguration.id }
        }
        guard let scopeSessionID else {
            isEnabled = false
            return
        }
        do {
            let invocation = try model.activeExtensionsForSession(sessionID: scopeSessionID)
            isEnabled = invocation.mcpServers.contains(where: { $0.extensionID == selectedConfiguration.id })
        } catch {
            localError = error.localizedDescription
        }
    }

    private func resetConsents() {
        executionConsent = false
        screenCaptureConsent = false
        inputControlConsent = false
    }

    @ViewBuilder
    private func selectedPresetDetails(_ configuration: ActiveExtensionConfigurationSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Selected typed preset")
                .font(.caption.weight(.semibold))
            Text("Target: \(configuration.macControlTargetBundleID ?? "unknown") · mode: \(configuration.macControlAccessMode?.rawValue.capitalized ?? "unknown")")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            Text("Configuration SHA-256: \(configuration.configurationDigest)")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            Text("Allowed actions: \(configuration.macControlActionNames.joined(separator: ", "))")
                .font(.caption2)
                .textSelection(.enabled)
            if let path = configuration.executablePath {
                Text("Fixed helper: \(path)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let disclosure = configuration.screenCaptureDisclosure {
                Label(disclosure, systemImage: "eye")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Test Connection checks this exact Mac Control preset with initialize and tools/list only. It does not capture the screen, send input, call a Mac Control action, or contact a model.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button {
                    testSelectedPresetConnection(configuration)
                } label: {
                    if isTestingConnection { ProgressView().controlSize(.small) }
                    else { Label("Test Connection", systemImage: "bolt.horizontal.circle") }
                }
                .disabled(!canTestConnection(configuration))
                Button("Preview exact scope and consent") { previewSelectedPreset() }
                    .disabled(scopeSessionID == nil
                        || isTestingConnection
                        || model.isTestingMCPRuntime
                        || configuration.macControlTargetBundleID != trimmedTargetBundleID
                        || configuration.macControlAccessMode != accessMode)
                if isEnabled {
                    Label("Enabled for this project/provider/profile", systemImage: "checkmark.shield.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Spacer()
                if configuration.macControlAccessMode == .control {
                    if enabledControlSessions.isEmpty {
                        Button("Stop Control", role: .destructive) {}
                            .disabled(true)
                    } else {
                        ForEach(enabledControlSessions) { session in
                            Button(model.localizedFormat("Stop Control · %@", String(session.id.uuidString.prefix(8))), role: .destructive) {
                                stopControl(sessionID: session.id)
                            }
                        }
                    }
                } else if isEnabled {
                    Button("Disable", role: .destructive, action: disableObserve)
                        .disabled(scopeSessionID == nil || model.hasActiveAutonomousWorkflow)
                }
            }

            if let inspection,
               inspection.extensionID == configuration.id,
               inspection.configurationDigest == configuration.configurationDigest,
               configuration.macControlTargetBundleID == trimmedTargetBundleID,
               configuration.macControlAccessMode == accessMode {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.localizedFormat("MCP inspection · SHA-256 %@", inspection.inspectionDigest))
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                    Text(model.localizedFormat("Configuration digest: %@", inspection.configurationDigest))
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                    Text(model.localizedFormat("Tools discovered: %@", inspection.toolNames.joined(separator: ", ")))
                        .font(.caption2)
                        .textSelection(.enabled)
                    if !inspection.toolDefinitionsJSON.isEmpty {
                        Text("Exact discovered MCP tool definitions and input schemas")
                            .font(.caption2.weight(.semibold))
                        ScrollView {
                            Text(inspection.toolDefinitionsJSON)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 180)
                        .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 6))
                    }
                    ForEach(Array(inspection.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Text(model.localized(diagnostic)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            }

            if let review {
                activationReview(review)
                Toggle("I reviewed this exact digest and authorize its tools for this project, provider, and account profile.", isOn: $executionConsent)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("I consent to sending full main-display screenshots to the selected provider. Screenshots may include other windows and cannot be cropped or redacted as text.", isOn: $screenCaptureConsent)
                    .font(.caption2)
                    .fixedSize(horizontal: false, vertical: true)
                if configuration.macControlAccessMode == .control {
                    Toggle("I separately consent to input actions targeting this app. The target restriction limits input only; it does not crop screenshot pixels.", isOn: $inputControlConsent)
                        .font(.caption2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if !isEnabled {
                        Button("Enable this reviewed preset") { enableSelectedPreset() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canEnable(configuration))
                    }
                }
                Text("macOS Screen Recording and Accessibility permissions remain under your manual control. AgentBridge never requests them automatically.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    private func canEnable(_ configuration: ActiveExtensionConfigurationSummary) -> Bool {
        guard model.canStartAutonomousWorkflow, executionConsent, screenCaptureConsent,
              configuration.macControlTargetBundleID == trimmedTargetBundleID,
              configuration.macControlAccessMode == accessMode,
              let review, review.configurationDigest == configuration.configurationDigest else { return false }
        return configuration.macControlAccessMode != .control || inputControlConsent
    }

    private func activationReview(_ review: ActiveExtensionActivationReview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Mac Control activation review")
                .font(.caption.weight(.semibold))
            Text("Review digest: \(review.reviewedDigest)")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            Text("Configuration digest: \(review.configurationDigest)")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            Text("Scope: \(review.projectID) · \(review.provider.rawValue) · profile \(review.profileID.uuidString.lowercased())")
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            if let target = review.macControlTargetBundleID {
                Text("Target app bundle ID: \(target) · mode: \(review.macControlAccessMode?.rawValue ?? "unknown")")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text("Exact allowed actions: \(review.macControlActionNames.joined(separator: ", "))")
                .font(.caption2)
                .textSelection(.enabled)
            if let path = review.executablePath {
                Text("Helper path: \(path)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
            }
            Text(model.localized(review.trustWarning))
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if let disclosure = review.screenCaptureDisclosure {
                Label(disclosure, systemImage: "eye")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let calls = review.maximumToolCallsPerRun,
               let responseBytes = review.maximumToolResponseBytes,
               let totalBytes = review.maximumTotalToolResponseBytes {
                Text("Budgets: \(calls) tool calls · \(responseBytes) bytes per response · \(totalBytes) bytes total")
                    .font(.caption2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private func disableObserve() {
        guard let selectedConfiguration, let scopeSessionID else { return }
        do {
            _ = try model.disableExtensionRuntime(extensionID: selectedConfiguration.id, sessionID: scopeSessionID)
            isEnabled = false
            review = nil
            localStatus = "Observe access was disabled for the selected scope."
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
}
