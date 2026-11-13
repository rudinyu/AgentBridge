import AgentBridgeCore
import Foundation
import Observation

/// Active Skill and MCP runtimes and the Mac Control preset. Legacy descriptor
/// metadata is managed from the CLI (`extensions import/grant/revoke`) only. Every call goes through `BridgeService`, which
/// enforces consent; this model only holds what the extension screens show.
@MainActor
@Observable
final class ExtensionsModel {
    var isTestingMCPRuntime = false
    var activeExtensionConfigurations: [ActiveExtensionConfigurationSummary] = []
    var activeExtensionError: String?
    var activeExtensionStatus = ""
    var detectedMacControlPresetStatus: MacControlPresetStatus?
    var macControlPermissionReadiness: MacControlPermissionReadiness?
    var macControlStatusError: String?
    var isCheckingMacControlPermissions = false

    func refreshActiveExtensionConfigurations() {
        guard let service = app.service else { return }
        do {
            activeExtensionConfigurations = try service.activeExtensionConfigurations()
            activeExtensionError = nil
        } catch {
            activeExtensionError = error.localizedDescription
        }
    }

    func importSkillRuntime(descriptor: ExtensionDescriptor, sourceReference: String, skillFileURL: URL) throws -> ActiveSkillSnapshot {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        let snapshot = try service.importSkillRuntime(descriptor: descriptor, sourceReference: sourceReference, skillFileURL: skillFileURL)
        refreshActiveExtensionConfigurations()
        activeExtensionStatus = app.localized("Skill instructions were imported as a bounded snapshot; no script was executed.")
        return snapshot
    }

    func importMCPRuntimeManifest(at manifestURL: URL) throws -> ActiveMCPConfiguration {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        let configuration = try service.importMCPRuntimeManifest(at: manifestURL)
        refreshActiveExtensionConfigurations()
        activeExtensionStatus = app.localized("MCP configuration was imported. The process has not been started.")
        return configuration
    }

    func testMCPRuntime(extensionID: String) async throws -> MCPServerInspection {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        guard app.canStartAutonomousWorkflow else {
            throw AgentBridgeError.invalidInput("Wait for provider sessions and terminals to stop before testing an MCP process.")
        }
        isTestingMCPRuntime = true
        defer { isTestingMCPRuntime = false }
        return try await service.testMCPRuntime(extensionID: extensionID)
    }

    /// The last Test Connection result for this exact configuration, or nil
    /// when it has not been tested since it was imported or changed.
    func activeExtensionInspection(extensionID: String) throws -> MCPServerInspection? {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        return try service.activeExtensionInspection(extensionID: extensionID)
    }

    /// Tests a configuration and refuses the result when the configuration was
    /// replaced while the test ran, so a result is never shown for a digest it
    /// did not test.
    func testRuntimeConnection(_ configuration: ActiveExtensionConfigurationSummary) async throws -> MCPServerInspection {
        let result = try await testMCPRuntime(extensionID: configuration.id)
        refreshActiveExtensionConfigurations()
        let current = activeExtensionConfigurations.first(where: { $0.id == configuration.id })
        guard result.extensionID == configuration.id,
              result.configurationDigest == configuration.configurationDigest,
              current?.configurationDigest == configuration.configurationDigest else {
            throw AgentBridgeError.invalidInput("The configuration changed during testing. Test it again.")
        }
        return result
    }

    func refreshMacControlPresetStatus(targetBundleID: String?, accessMode: MacControlAccessMode) {
        guard let service = app.service else { return }
        detectedMacControlPresetStatus = service.macControlPresetStatus(
            targetBundleID: targetBundleID,
            accessMode: accessMode
        )
        macControlStatusError = nil
    }

    func importMacControlPreset(targetBundleID: String, accessMode: MacControlAccessMode) throws -> ActiveMCPConfiguration {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        guard app.canStartAutonomousWorkflow else {
            throw AgentBridgeError.invalidInput("Wait for provider sessions and terminals to stop before changing an extension runtime.")
        }
        let configuration = try service.importMacControlPreset(targetBundleID: targetBundleID, accessMode: accessMode)
        refreshActiveExtensionConfigurations()
        refreshMacControlPresetStatus(targetBundleID: targetBundleID, accessMode: accessMode)
        activeExtensionStatus = app.localized("The Mac Control preset was imported. Screen or input access is not enabled.")
        return configuration
    }

    func testMacControlPermissions(targetBundleID: String) async throws -> MacControlPermissionReadiness {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        guard app.canStartAutonomousWorkflow else {
            throw AgentBridgeError.invalidInput("Wait for provider sessions and terminals to stop before checking Mac Control permissions.")
        }
        isTestingMCPRuntime = true
        isCheckingMacControlPermissions = true
        defer {
            isTestingMCPRuntime = false
            isCheckingMacControlPermissions = false
        }
        let readiness = try await service.testMacControlPermissions(targetBundleID: targetBundleID)
        macControlPermissionReadiness = readiness
        macControlStatusError = nil
        return readiness
    }

    func stopMacControl(extensionID: String, sessionID: UUID) throws -> [UUID] {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        let cancelledSessionIDs = try service.stopMacControl(extensionID: extensionID, sessionID: sessionID)
        activeExtensionStatus = cancelledSessionIDs.isEmpty
            ? app.localized("Mac Control Control access was revoked for this scope.")
            : app.localizedFormat("Mac Control was stopped and cancellation was requested for %@ affected session(s).", String(cancelledSessionIDs.count))
        refreshActiveExtensionConfigurations()
        return cancelledSessionIDs
    }

    func previewExtensionActivation(extensionID: String, sessionID: UUID) throws -> ActiveExtensionActivationReview {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        return try service.previewExtensionActivation(extensionID: extensionID, sessionID: sessionID)
    }

    func enableExtensionRuntime(
        extensionID: String,
        sessionID: UUID,
        reviewedDigest: String,
        explicitExecutionConsent: Bool,
        explicitScreenCaptureConsent: Bool = false,
        explicitInputControlConsent: Bool = false
    ) throws -> ActiveExtensionGrant {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        let grant = try service.enableExtensionRuntime(
            extensionID: extensionID,
            sessionID: sessionID,
            reviewedDigest: reviewedDigest,
            explicitExecutionConsent: explicitExecutionConsent,
            explicitScreenCaptureConsent: explicitScreenCaptureConsent,
            explicitInputControlConsent: explicitInputControlConsent
        )
        activeExtensionStatus = app.localized("The extension is enabled for this exact project, provider, and account profile. New sessions will receive this snapshot.")
        refreshActiveExtensionConfigurations()
        return grant
    }

    func disableExtensionRuntime(extensionID: String, sessionID: UUID) throws -> Bool {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        let disabled = try service.disableExtensionRuntime(extensionID: extensionID, sessionID: sessionID)
        activeExtensionStatus = app.localized("The extension was disabled for this exact project, provider, and account profile.")
        return disabled
    }

    func createExtensionTargetSession(sourcePath: String, provider: AgentProvider, profileID: UUID) async throws -> SessionRecord {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        return try await service.createSession(
            sourcePath: sourcePath,
            provider: provider,
            accessMode: .readOnly,
            accountProfileID: profileID
        )
    }

    func extensionProjectID(sessionID: UUID) throws -> String {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        return try service.extensionProjectID(sessionID: sessionID)
    }

    func activeExtensionsForSession(sessionID: UUID, extensionIDs: [String]? = nil) throws -> ActiveExtensionInvocation {
        guard let service = app.service else { throw AgentBridgeError.persistence("AgentBridge service is unavailable.") }
        return try service.activeExtensionsForSession(sessionID: sessionID, extensionIDs: extensionIDs)
    }

    @ObservationIgnored private weak var owner: AppModel?

    private var app: AppModel {
        guard let owner else { preconditionFailure("ExtensionsModel outlived its AppModel.") }
        return owner
    }

    /// Connects this model to the `AppModel` that owns it; called once from `AppModel.init`.
    func attach(to app: AppModel) {
        owner = app
    }
}
