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
            model.extensions.refreshActiveExtensionConfigurations()
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
                    Button("Refresh configurations") { model.extensions.refreshActiveExtensionConfigurations() }
                }
                if !model.extensions.activeExtensionConfigurations.isEmpty {
                    HStack(spacing: 12) {
                        Text("\(model.extensions.activeExtensionConfigurations.count) runtime configuration(s) imported")
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
                if model.extensions.activeExtensionConfigurations.isEmpty {
                    Text("No active runtime configurations imported yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Configuration", selection: $selectedExtensionID) {
                        Text("Choose a Skill, MCP, or Mac Control preset").tag("")
                        ForEach(model.extensions.activeExtensionConfigurations) { configuration in
                            Text("\(configuration.kind.rawValue.uppercased()) · \(configuration.name)")
                                .tag(configuration.id)
                        }
                    }
                    ForEach(model.extensions.activeExtensionConfigurations) { configuration in
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
                        if let projectID = try? model.extensions.extensionProjectID(sessionID: scopeSession.id) {
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
        model.extensions.activeExtensionConfigurations.first(where: { $0.id == selectedExtensionID })
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
            let invocation = try model.extensions.activeExtensionsForSession(sessionID: scopeSession.id)
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
                let session = try await model.extensions.createExtensionTargetSession(sourcePath: model.repositoryPath, provider: targetProvider, profileID: profile.id)
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
            let snapshot = try model.extensions.importSkillRuntime(descriptor: descriptor, sourceReference: url.path, skillFileURL: url)
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
            let configuration = try model.extensions.importMCPRuntimeManifest(at: url)
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
                let result = try await model.extensions.testMCPRuntime(extensionID: configuration.id)
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
            review = try model.extensions.previewExtensionActivation(extensionID: configuration.id, sessionID: scopeSession.id)
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
            let grant = try model.extensions.enableExtensionRuntime(
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
            _ = try model.extensions.disableExtensionRuntime(extensionID: activationReview.extensionID, sessionID: scopeSession.id)
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
