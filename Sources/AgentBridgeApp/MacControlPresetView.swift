import AppKit
import AgentBridgeCore
import SwiftUI

/// Sets up a Mac Control preset: target app, Observe or Control, the installed
/// helper check, an optional permission readiness test, and the import. Opened
/// from the Add menu. Testing, reviewing and enabling an imported preset happen
/// from its row, like any MCP server.
struct MacControlPresetSetupView: View {
    @Bindable var model: AppModel
    var onImported: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var targetBundleID = ""
    @State private var accessMode: MacControlAccessMode = .observe
    @State private var localError: String?
    @State private var localStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mac Control preset")
                .font(.title3.weight(.semibold))
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
                    .disabled(isBusy)
                Button("Choose app…", action: chooseTargetApp)
                    .disabled(isBusy)
            }
            Picker("Access mode", selection: $accessMode) {
                Text("Observe").tag(MacControlAccessMode.observe)
                Text("Control").tag(MacControlAccessMode.control)
            }
            .pickerStyle(.segmented)
            .disabled(isBusy)
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
                    Text("Permission readiness · \(model.formattedDate(readiness.checkedAt, date: .abbreviated, time: .standard))")
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

            Text("Importing a preset stores a typed configuration only. Preview it for the selected project/provider/profile, inspect its digest and exact actions, then enable it explicitly.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(accessMode == .observe ? "Import Observe preset" : "Import Control preset") {
                    importPreset()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canImportPreset)
            }
        }
        .padding(18)
        .frame(width: 600)
        .onAppear {
            model.extensions.refreshMacControlPresetStatus(
                targetBundleID: trimmedTargetBundleID.isEmpty ? nil : trimmedTargetBundleID,
                accessMode: accessMode
            )
        }
        .onChange(of: model.appLanguage) { _, _ in
            localStatus = ""
            localError = nil
        }
        .onChange(of: accessMode) { _, _ in localStatus = "" }
        .onChange(of: targetBundleID) { _, _ in localStatus = "" }
    }

    private var isBusy: Bool {
        model.hasActiveAutonomousWorkflow || model.extensions.isTestingMCPRuntime
    }

    private var trimmedTargetBundleID: String {
        targetBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canTestPermissionReadiness: Bool {
        model.canStartAutonomousWorkflow
            && !model.extensions.isTestingMCPRuntime
            && MacControlActionPolicy.isAllowedTarget(trimmedTargetBundleID)
    }

    /// Import needs a helper check for exactly this target and mode.
    private var canImportPreset: Bool {
        model.canStartAutonomousWorkflow
            && !model.extensions.isTestingMCPRuntime
            && MacControlActionPolicy.isAllowedTarget(trimmedTargetBundleID)
            && model.extensions.detectedMacControlPresetStatus?.targetBundleID == trimmedTargetBundleID
            && model.extensions.detectedMacControlPresetStatus?.accessMode == accessMode
            && model.extensions.detectedMacControlPresetStatus?.helperAvailable == true
            && model.extensions.detectedMacControlPresetStatus?.proxyAvailable == true
    }

    private func chooseTargetApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = model.localized("Choose Target App")
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else {
            if panel.url != nil { localError = "The selected app does not have a bundle identifier." }
            return
        }
        targetBundleID = bundleID
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
            onImported(configuration.extensionID)
            dismiss()
        } catch {
            localError = error.localizedDescription
        }
    }

    private func checkPermissionReadiness() {
        localError = nil
        localStatus = "Checking only the permission status reported by the installed helper…"
        Task { @MainActor in
            do {
                _ = try await model.extensions.testMacControlPermissions(targetBundleID: trimmedTargetBundleID)
                localStatus = model.localized("Permission readiness checked. This status-only test did not capture the screen, send input, or request macOS permission.")
            } catch {
                model.extensions.macControlStatusError = error.localizedDescription
                localStatus = ""
            }
        }
    }
}
