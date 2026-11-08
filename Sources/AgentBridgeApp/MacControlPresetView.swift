import AppKit
import AgentBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct MacControlPresetView: View {
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
                        .disabled(model.hasActiveAutonomousWorkflow || model.extensions.isTestingMCPRuntime || isTestingConnection)
                    Button("Choose app…", action: chooseTargetApp)
                        .disabled(model.hasActiveAutonomousWorkflow || model.extensions.isTestingMCPRuntime || isTestingConnection)
                }
                Picker("Access mode", selection: $accessMode) {
                    Text("Observe").tag(MacControlAccessMode.observe)
                    Text("Control").tag(MacControlAccessMode.control)
                }
                .pickerStyle(.segmented)
                .disabled(model.hasActiveAutonomousWorkflow || model.extensions.isTestingMCPRuntime || isTestingConnection)
                Text(accessMode == .observe
                    ? "Observe allows only the built-in observation actions."
                    : "Control adds input actions for the selected app and requires its own explicit consent.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Check installed helper") {
                        model.extensions.refreshMacControlPresetStatus(
                            targetBundleID: trimmedTargetBundleID.isEmpty ? nil : trimmedTargetBundleID,
                            accessMode: accessMode
                        )
                    }
                    .disabled(model.hasActiveAutonomousWorkflow)
                    Button {
                        checkPermissionReadiness()
                    } label: {
                        if model.extensions.isCheckingMacControlPermissions { ProgressView().controlSize(.small) }
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

                if let status = model.extensions.detectedMacControlPresetStatus {
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

                if let readiness = model.extensions.macControlPermissionReadiness,
                   readiness.targetBundleID == trimmedTargetBundleID {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Permission readiness · \(readiness.checkedAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption.weight(.semibold))
                        Text("Helper available: \(model.localizedYesNo(readiness.helperAvailable)) · status tool available: \(model.localizedYesNo(readiness.statusToolAvailable))")
                            .font(.caption2)
                        Text(model.localized(readiness.statusText.isEmpty ? "No permission status was returned." : readiness.statusText))
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

                if let error = localError ?? model.extensions.macControlStatusError {
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
        .onChange(of: model.extensions.activeExtensionConfigurations) { _, _ in
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
        return model.extensions.activeExtensionConfigurations.first(where: {
            $0.id == selectedConfigurationID && $0.macControlTargetBundleID != nil
        })
    }

    private var canTestPermissionReadiness: Bool {
        model.canStartAutonomousWorkflow
            && !isTestingConnection
            && !model.extensions.isTestingMCPRuntime
            && MacControlActionPolicy.isAllowedTarget(trimmedTargetBundleID)
    }

    private func canTestConnection(_ configuration: ActiveExtensionConfigurationSummary) -> Bool {
        model.canStartAutonomousWorkflow
            && !isTestingConnection
            && !model.extensions.isTestingMCPRuntime
            && !model.extensions.isCheckingMacControlPermissions
            && selectedConfiguration?.id == configuration.id
            && configuration.macControlTargetBundleID == trimmedTargetBundleID
            && configuration.macControlAccessMode == accessMode
    }

    private var canImportPreset: Bool {
        model.canStartAutonomousWorkflow
            && !isTestingConnection
            && !model.extensions.isTestingMCPRuntime
            && MacControlActionPolicy.isAllowedTarget(trimmedTargetBundleID)
            && model.extensions.detectedMacControlPresetStatus?.targetBundleID == trimmedTargetBundleID
            && model.extensions.detectedMacControlPresetStatus?.accessMode == accessMode
            && model.extensions.detectedMacControlPresetStatus?.helperAvailable == true
            && model.extensions.detectedMacControlPresetStatus?.proxyAvailable == true
    }

    private func synchronizeSelectedConfiguration() {
        if let configuration = selectedConfiguration, let target = configuration.macControlTargetBundleID {
            targetBundleID = target
            accessMode = configuration.macControlAccessMode ?? .observe
        }
        model.extensions.refreshMacControlPresetStatus(
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
        model.extensions.refreshMacControlPresetStatus(targetBundleID: bundleID, accessMode: accessMode)
    }

    private func importPreset() {
        localError = nil
        localStatus = ""
        do {
            let configuration = try model.extensions.importMacControlPreset(
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
                let result = try await model.extensions.testMacControlPermissions(targetBundleID: trimmedTargetBundleID)
                _ = result
                localStatus = model.localized("Permission readiness checked. This status-only test did not capture the screen, send input, or request macOS permission.")
            } catch {
                model.extensions.macControlStatusError = error.localizedDescription
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
            review = try model.extensions.previewExtensionActivation(extensionID: selectedConfiguration.id, sessionID: scopeSessionID)
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
                let result = try await model.extensions.testMCPRuntime(extensionID: configuration.id)
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
            let grant = try model.extensions.enableExtensionRuntime(
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
            let cancelled = try model.extensions.stopMacControl(extensionID: selectedConfiguration.id, sessionID: sessionID)
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
            guard let invocation = try? model.extensions.activeExtensionsForSession(sessionID: session.id) else { return false }
            return invocation.mcpServers.contains { $0.extensionID == selectedConfiguration.id }
        }
        guard let scopeSessionID else {
            isEnabled = false
            return
        }
        do {
            let invocation = try model.extensions.activeExtensionsForSession(sessionID: scopeSessionID)
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
            Text("Target: \(configuration.macControlTargetBundleID ?? model.localized("value.unknown")) · mode: \(configuration.macControlAccessMode?.rawValue.capitalized ?? model.localized("value.unknown"))")
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
                        || model.extensions.isTestingMCPRuntime
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
                Text("Target app bundle ID: \(target) · mode: \(review.macControlAccessMode?.rawValue ?? model.localized("value.unknown"))")
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
            _ = try model.extensions.disableExtensionRuntime(extensionID: selectedConfiguration.id, sessionID: scopeSessionID)
            isEnabled = false
            review = nil
            localStatus = "Observe access was disabled for the selected scope."
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }
}
