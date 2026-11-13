import AgentBridgeCore
import SwiftUI

/// Everything about one imported Skill, MCP server, or Mac Control preset: its
/// exact configuration, its last Test Connection, and the activation review
/// for the screen's scope. The consent toggles are the confirmation for Enable.
struct ExtensionReviewSheet: View {
    @Bindable var model: AppModel
    let configurationID: String
    let scopeSession: SessionRecord?
    /// Called with a status line after the sheet enables something.
    var onChanged: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var review: ActiveExtensionActivationReview?
    @State private var inspection: MCPServerInspection?
    @State private var isEnabled = false
    @State private var executionConsent = false
    @State private var screenCaptureConsent = false
    @State private var inputControlConsent = false
    @State private var isTesting = false
    @State private var localError: String?
    @State private var localStatus = ""

    private var configuration: ActiveExtensionConfigurationSummary? {
        model.extensions.activeExtensionConfigurations.first(where: { $0.id == configurationID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let configuration {
                let kind = ExtensionRowKind(configuration)
                HStack(spacing: 10) {
                    Image(systemName: kind.systemImage).font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(configuration.name).font(.title3.weight(.semibold))
                        Text("\(configuration.kind.rawValue.uppercased()) · v\(configuration.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
                Divider()
                ScrollView {
                    content(configuration, kind: kind)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer(configuration, kind: kind)
                    .padding(12)
            } else {
                Text("This configuration is no longer imported.")
                    .padding(24)
                HStack { Spacer(); Button("Close") { dismiss() } }.padding(12)
            }
        }
        .frame(minWidth: 640, idealWidth: 700, minHeight: 520, idealHeight: 680)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private func content(_ configuration: ActiveExtensionConfigurationSummary, kind: ExtensionRowKind) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            scopeLine
            configurationDetails(configuration)
            if kind.needsConnectionTest && inspection == nil {
                testSection(configuration, kind: kind)
            } else if let inspection {
                DisclosureGroup(model.localizedFormat("MCP inspection · SHA-256 %@", inspection.inspectionDigest)) {
                    inspectionDetails(inspection).padding(.top, 4)
                }
                .font(.caption.weight(.semibold))
            }
            if let review {
                if kind == .macControl {
                    macControlReview(review)
                } else {
                    reviewDetails(review, kind: configuration.kind)
                }
                if isEnabled {
                    Label("Enabled for this exact scope", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                } else {
                    consents(configuration, kind: kind)
                }
                Text(kind == .macControl
                    ? "macOS Screen Recording and Accessibility permissions remain under your manual control. AgentBridge never requests them automatically."
                    : "Changes to the imported content, executable, argv, tool list, or scope change the digest and require a new review. New provider sessions receive the approved snapshot; existing sessions keep their original snapshot.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = localError {
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
    }

    private func footer(_ configuration: ActiveExtensionConfigurationSummary, kind: ExtensionRowKind) -> some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if review != nil && !isEnabled {
                Button("Enable") { enable(configuration, kind: kind) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canEnable(configuration, kind: kind))
            }
        }
    }

    @ViewBuilder
    private var scopeLine: some View {
        if let scopeSession {
            Text(model.localizedFormat(
                "Applies to %@ · %@ · %@",
                URL(fileURLWithPath: scopeSession.sourceRepositoryPath).lastPathComponent,
                scopeSession.provider == .codex ? "Codex" : "Claude",
                model.profileName(for: scopeSession)
            ))
            .font(.callout.weight(.medium))
        } else {
            Text("Choose or create a scope session first.")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    private func configurationDetails(_ configuration: ActiveExtensionConfigurationSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !configuration.summary.isEmpty {
                Text(configuration.summary).font(.caption).foregroundStyle(.secondary)
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
                if configuration.macControlTargetBundleID == nil {
                    Text("Exact allowed tools: \(configuration.allowedTools.joined(separator: ", "))")
                        .font(.caption2)
                        .textSelection(.enabled)
                }
                Text("Startup timeout: \(configuration.startupTimeoutSeconds ?? 0)s · tool timeout: \(configuration.toolTimeoutSeconds ?? 0)s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let targetBundleID = configuration.macControlTargetBundleID {
                Text("Target app bundle ID: \(targetBundleID)")
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                Text("Mac Control mode: \(configuration.macControlAccessMode?.rawValue.capitalized ?? model.localized("value.unknown")) · actions: \(configuration.macControlActionNames.joined(separator: ", "))")
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
                    Text(model.localizedFormat("Tool limits: %@ calls · %@ bytes per response · %@ bytes total", String(calls), String(responseBytes), String(totalBytes)))
                        .font(.caption2)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
    }

    /// The warning sits next to the button, so the user sees that testing runs
    /// the program before it runs.
    private func testSection(_ configuration: ActiveExtensionConfigurationSummary, kind: ExtensionRowKind) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Test this connection before reviewing it.")
                .font(.caption.weight(.semibold))
            Label(model.localized(kind == .macControl
                ? "Test Connection checks this exact Mac Control preset with initialize and tools/list only. It does not capture the screen, send input, call a Mac Control action, or contact a model."
                : "The configured executable will run as your macOS user. It may access files, network resources, and credentials available to that account. Test Connection performs initialize and tools/list only; it does not call an MCP tool or a model. The tool allowlist is not an operating-system sandbox."),
                systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                test(configuration, kind: kind)
            } label: {
                if isTesting { ProgressView().controlSize(.small) }
                else { Label("Test connection", systemImage: "bolt.horizontal.circle") }
            }
            .disabled(isTesting || !model.canStartAutonomousWorkflow)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private func inspectionDetails(_ inspection: MCPServerInspection) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model.localizedFormat("Configuration digest: %@", inspection.configurationDigest))
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
            Text(model.localizedFormat("Tools discovered: %@", inspection.toolNames.joined(separator: ", ")))
                .font(.caption2)
                .textSelection(.enabled)
            ForEach(Array(inspection.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Text(model.localized(diagnostic)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .font(.body.weight(.regular))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
                    toolDefinitions(definitions)
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

    private func macControlReview(_ review: ActiveExtensionActivationReview) -> some View {
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
            if let definitions = review.toolDefinitionsJSON {
                toolDefinitions(definitions)
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
                Text(model.localizedFormat("Budgets: %@ tool calls · %@ bytes per response · %@ bytes total", String(calls), String(responseBytes), String(totalBytes)))
                    .font(.caption2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private func toolDefinitions(_ definitions: String) -> some View {
        DisclosureGroup("Exact discovered MCP tool definitions and input schemas") {
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
        .font(.caption2.weight(.semibold))
    }

    /// Mac Control keeps its separate consents: running the tools, sending full
    /// screenshots, and, in Control mode, input to the target app.
    @ViewBuilder
    private func consents(_ configuration: ActiveExtensionConfigurationSummary, kind: ExtensionRowKind) -> some View {
        if kind == .macControl {
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
        } else {
            Toggle("I reviewed this exact content, digest, command, allowed tools, and project/provider/profile scope, and consent to enable it.", isOn: $executionConsent)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func canEnable(_ configuration: ActiveExtensionConfigurationSummary, kind: ExtensionRowKind) -> Bool {
        guard let review, scopeSession != nil else { return false }
        return ExtensionEnableRules.canEnable(ExtensionEnableRules.Inputs(
            kind: kind,
            isControlMode: configuration.macControlAccessMode == .control,
            executionConsent: executionConsent,
            screenCaptureConsent: screenCaptureConsent,
            inputControlConsent: inputControlConsent,
            reviewedConfigurationDigest: review.configurationDigest,
            configurationDigest: configuration.configurationDigest,
            testedConfigurationDigest: inspection?.configurationDigest,
            hasActiveWorkflow: model.hasActiveAutonomousWorkflow,
            canStartWorkflow: model.canStartAutonomousWorkflow
        ))
    }

    // MARK: Actions

    /// Reads the saved test result, the enabled state and the activation
    /// review for the scope. Nothing is started.
    private func load() {
        guard let configuration else { return }
        let kind = ExtensionRowKind(configuration)
        review = nil
        resetConsents()
        inspection = kind.needsConnectionTest ? ((try? model.extensions.activeExtensionInspection(extensionID: configuration.id)) ?? nil) : nil
        guard let scopeSession else { return }
        do {
            let invocation = try model.extensions.activeExtensionsForSession(sessionID: scopeSession.id)
            isEnabled = invocation.extensionIDs.contains(configuration.id)
            // An untested MCP cannot be previewed yet; the test section explains.
            if !kind.needsConnectionTest || inspection != nil {
                review = try model.extensions.previewExtensionActivation(extensionID: configuration.id, sessionID: scopeSession.id)
            }
            localError = nil
        } catch {
            localError = error.localizedDescription
        }
    }

    private func test(_ configuration: ActiveExtensionConfigurationSummary, kind: ExtensionRowKind) {
        isTesting = true
        localError = nil
        localStatus = kind == .macControl
            ? "Testing the selected Mac Control preset's initialize and tools/list handshake…"
            : "Testing the selected MCP's initialize and tools/list handshake…"
        Task { @MainActor in
            defer { isTesting = false }
            do {
                let result = try await model.extensions.testRuntimeConnection(configuration)
                load()
                localStatus = kind == .macControl
                    ? model.localizedFormat("Mac Control Test Connection succeeded. Discovered %@ tools. No screenshot was captured, no input or Mac Control action was sent, and no model was contacted.", String(result.toolNames.count))
                    : model.localizedFormat("Test Connection succeeded. Discovered %@ tools; no tool or model was called.", String(result.toolNames.count))
            } catch {
                localError = error.localizedDescription
                localStatus = ""
            }
        }
    }

    private func enable(_ configuration: ActiveExtensionConfigurationSummary, kind: ExtensionRowKind) {
        guard let review, let scopeSession, canEnable(configuration, kind: kind) else { return }
        do {
            let grant = try model.extensions.enableExtensionRuntime(
                extensionID: review.extensionID,
                sessionID: scopeSession.id,
                reviewedDigest: review.reviewedDigest,
                explicitExecutionConsent: executionConsent,
                explicitScreenCaptureConsent: kind == .macControl && screenCaptureConsent,
                explicitInputControlConsent: kind == .macControl && inputControlConsent
            )
            resetConsents()
            model.refresh()
            onChanged(kind == .macControl
                ? model.localizedFormat("Enabled Mac Control for project %@, %@, profile %@.", grant.projectID, grant.provider.rawValue, grant.profileID.uuidString.lowercased())
                : model.localizedFormat("Enabled for project %@, %@ profile %@.", grant.projectID, grant.provider.rawValue, grant.profileID.uuidString.lowercased()))
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func resetConsents() {
        executionConsent = false
        screenCaptureConsent = false
        inputControlConsent = false
    }
}
