import CryptoKit
import Darwin
import Foundation

public struct ActiveExtensionRuntimeStore: Sendable {
    public let rootURL: URL

    private static let fileName = "active-extensions.json"
    private static let maximumStoredBytes = 16 * 1_024 * 1_024
    private static let maximumConfigurations = 128
    private static let maximumGrants = 8_192
    private static let maximumInspections = 128
    private static let maximumSessionBindings = 20_000
    private static let maximumAuditEvents = 4_096
    public static let executionTrustWarning = "Approved MCP stdio processes run as your macOS user and can access files, network resources, and credentials available to that account. The exact tool allowlist limits which MCP tools the agent can select; it is not an operating-system sandbox for the process. Common interpreter entry scripts are pinned by content digest, but imported modules, packages, dynamic libraries, and other transitive code are not sealed. Skill content is instructions only and cannot grant additional tools or change AgentBridge approvals."

    public init(rootURL: URL) throws {
        guard rootURL.isFileURL, let path = ActiveExtensionValidation.preservedAbsolutePath(rootURL.path) else {
            throw AgentBridgeError.invalidInput("Active extension runtime storage path is invalid.")
        }
        self.rootURL = URL(fileURLWithPath: path, isDirectory: true)
    }

    public func importSkill(_ snapshot: ActiveSkillSnapshot) throws {
        try withDocument { document in
            try Self.replaceConfiguration(.skill(snapshot), in: &document)
            document.auditEvents.append(StoredExtensionRuntimeAudit(action: "imported", extensionID: snapshot.extensionID, projectID: nil, provider: nil, profileID: nil, digest: snapshot.configurationDigest, occurredAt: Date()))
            Self.trimAudit(&document.auditEvents)
        }
    }

    public func importMCP(_ configuration: ActiveMCPConfiguration) throws {
        try withDocument { document in
            try Self.replaceConfiguration(.mcp(configuration), in: &document)
            document.auditEvents.append(StoredExtensionRuntimeAudit(action: "imported", extensionID: configuration.extensionID, projectID: nil, provider: nil, profileID: nil, digest: configuration.configurationDigest, occurredAt: Date()))
            Self.trimAudit(&document.auditEvents)
        }
    }

    public func configurations() throws -> [ActiveExtensionConfigurationSummary] {
        try withDocument { document in document.configurations.map(Self.summary).sorted { $0.id < $1.id } }
    }

    func skillSnapshot(extensionID: String) throws -> ActiveSkillSnapshot? {
        let id = try ActiveExtensionValidation.identifier(extensionID, label: "extension ID")
        return try withDocument { document in
            guard let configuration = document.configurations.first(where: { Self.extensionID(of: $0) == id }),
                  case .skill(let skill) = configuration else { return nil }
            return skill
        }
    }

    func mcpConfiguration(extensionID: String) throws -> ActiveMCPConfiguration? {
        let id = try ActiveExtensionValidation.identifier(extensionID, label: "extension ID")
        return try withDocument { document in
            guard let configuration = document.configurations.first(where: { Self.extensionID(of: $0) == id }),
                  case .mcp(let mcp) = configuration else { return nil }
            return mcp
        }
    }

    @discardableResult
    public func recordInspection(_ inspection: MCPServerInspection) throws -> Bool {
        try withDocument { document in
            guard let configuration = document.configurations.first(where: { Self.extensionID(of: $0) == inspection.extensionID }),
                  case .mcp(let mcp) = configuration,
                  mcp.configurationDigest == inspection.configurationDigest,
                  inspection.toolNames.count <= 512,
                  inspection.toolNames == inspection.toolNames.sorted(),
                  Set(inspection.toolNames).count == inspection.toolNames.count,
                  inspection.toolNames.allSatisfy(ActiveExtensionValidation.isToolName),
                  MCPServerInspection.isValidToolDefinitionsJSON(inspection.toolDefinitionsJSON, toolNames: inspection.toolNames),
                  inspection.inspectionDigest == MCPServerInspection.makeDigest(configurationDigest: inspection.configurationDigest, toolNames: inspection.toolNames, toolDefinitionsJSON: inspection.toolDefinitionsJSON),
                  Set(mcp.allowedTools).isSubset(of: Set(inspection.toolNames)) else {
                throw ActiveExtensionRuntimeError.inspectionMismatch(inspection.extensionID)
            }
            let priorDigest = document.inspections.first(where: { $0.extensionID == inspection.extensionID })?.inspectionDigest
            let changed = priorDigest.map { $0 != inspection.inspectionDigest } ?? false
            document.inspections.removeAll { $0.extensionID == inspection.extensionID }
            document.inspections.append(StoredExtensionInspection(inspection))
            if changed {
                document.grants.removeAll { $0.extensionID == inspection.extensionID }
                document.auditEvents.append(StoredExtensionRuntimeAudit(
                    action: "inspection_changed",
                    extensionID: inspection.extensionID,
                    projectID: nil,
                    provider: nil,
                    profileID: nil,
                    digest: inspection.inspectionDigest,
                    occurredAt: Date()
                ))
                Self.trimAudit(&document.auditEvents)
            }
            return changed
        }
    }

    public func inspection(extensionID: String) throws -> MCPServerInspection? {
        let id = try ActiveExtensionValidation.identifier(extensionID, label: "extension ID")
        return try withDocument { document in
            guard let inspection = document.inspections.first(where: { $0.extensionID == id }),
                  let configuration = document.configurations.first(where: { Self.extensionID(of: $0) == id }),
                  case .mcp(let mcp) = configuration,
                  inspection.configurationDigest == mcp.configurationDigest else { return nil }
            return inspection.publicValue
        }
    }

    public func preview(
        extensionID: String,
        projectID: String,
        provider: AgentProvider,
        profileID: UUID
    ) throws -> ActiveExtensionActivationReview {
        let id = try ActiveExtensionValidation.identifier(extensionID, label: "extension ID")
        let scope = try ActiveExtensionValidation.identifier(projectID, label: "project ID")
        return try withDocument { document in
            try Self.makeReview(extensionID: id, projectID: scope, provider: provider, profileID: profileID, document: document)
        }
    }

    public func enable(
        extensionID: String,
        projectID: String,
        provider: AgentProvider,
        profileID: UUID,
        reviewedDigest: String,
        explicitExecutionConsent: Bool,
        explicitScreenCaptureConsent: Bool = false,
        explicitInputControlConsent: Bool = false,
        grantedBy: String
    ) throws -> ActiveExtensionGrant {
        guard explicitExecutionConsent else { throw ActiveExtensionRuntimeError.executionConsentRequired }
        let id = try ActiveExtensionValidation.identifier(extensionID, label: "extension ID")
        let scope = try ActiveExtensionValidation.identifier(projectID, label: "project ID")
        let actor = try ActiveExtensionValidation.text(grantedBy, label: "granting actor", maximumBytes: 256, allowEmpty: false)
        guard ActiveExtensionValidation.isSHA256(reviewedDigest) else { throw ActiveExtensionRuntimeError.reviewDigestMismatch }
        return try withDocument { document in
            let review = try Self.makeReview(extensionID: id, projectID: scope, provider: provider, profileID: profileID, document: document)
            guard review.reviewedDigest == reviewedDigest.lowercased() else { throw ActiveExtensionRuntimeError.reviewDigestMismatch }
            if review.requiresScreenCaptureConsent && !explicitScreenCaptureConsent {
                throw ActiveExtensionRuntimeError.screenCaptureConsentRequired
            }
            if review.requiresInputControlConsent && !explicitInputControlConsent {
                throw ActiveExtensionRuntimeError.inputControlConsentRequired
            }
            let grant = StoredActiveExtensionGrant(
                grantID: UUID(),
                extensionID: id,
                projectID: scope,
                provider: provider,
                profileID: profileID,
                configurationDigest: review.configurationDigest,
                reviewedDigest: review.reviewedDigest,
                grantedBy: actor,
                grantedAt: Date()
            )
            document.grants.removeAll { $0.matches(id: id, projectID: scope, provider: provider, profileID: profileID) }
            guard document.grants.count < Self.maximumGrants else { throw AgentBridgeError.persistence("The active extension grant registry has reached its limit.") }
            document.grants.append(grant)
            document.auditEvents.append(StoredExtensionRuntimeAudit(action: "enabled", extensionID: id, projectID: scope, provider: provider, profileID: profileID, digest: review.reviewedDigest, occurredAt: grant.grantedAt))
            Self.trimAudit(&document.auditEvents)
            return grant.publicValue
        }
    }

    @discardableResult
    public func disable(extensionID: String, projectID: String, provider: AgentProvider, profileID: UUID, disabledBy: String) throws -> Bool {
        let id = try ActiveExtensionValidation.identifier(extensionID, label: "extension ID")
        let scope = try ActiveExtensionValidation.identifier(projectID, label: "project ID")
        let actor = try ActiveExtensionValidation.text(disabledBy, label: "disabling actor", maximumBytes: 256, allowEmpty: false)
        return try withDocument { document in
            guard let removed = document.grants.first(where: { $0.matches(id: id, projectID: scope, provider: provider, profileID: profileID) }) else { return false }
            document.grants.removeAll { $0.matches(id: id, projectID: scope, provider: provider, profileID: profileID) }
            document.auditEvents.append(StoredExtensionRuntimeAudit(action: "disabled", extensionID: id, projectID: scope, provider: provider, profileID: profileID, digest: removed.reviewedDigest, actor: actor, occurredAt: Date()))
            Self.trimAudit(&document.auditEvents)
            return true
        }
    }

    public func invocation(
        projectID: String,
        provider: AgentProvider,
        profileID: UUID,
        workspacePath: String? = nil,
        selectedExtensionIDs: [String]? = nil
    ) throws -> ActiveExtensionInvocation {
        let scope = try ActiveExtensionValidation.identifier(projectID, label: "project ID")
        let validatedWorkspacePath = try workspacePath.map(ActiveExtensionValidation.absoluteExecutablePath)
        let selected = try selectedExtensionIDs.map { try $0.map { try ActiveExtensionValidation.identifier($0, label: "extension ID") } }
        guard selected.map({ Set($0).count == $0.count }) ?? true else {
            throw AgentBridgeError.invalidInput("Active extension selections must not contain duplicates.")
        }
        return try withDocument { document in
            let matchingGrants = document.grants.filter { $0.projectID == scope && $0.provider == provider && $0.profileID == profileID }
            let chosenGrants: [StoredActiveExtensionGrant]
            if let selected {
                guard Set(selected).isSubset(of: Set(matchingGrants.map(\.extensionID))) else {
                    let missing = selected.first { requested in !matchingGrants.contains { $0.extensionID == requested } } ?? "unknown"
                    throw ActiveExtensionRuntimeError.grantMissing(missing)
                }
                chosenGrants = selected.compactMap { id in matchingGrants.first { $0.extensionID == id } }
            } else {
                chosenGrants = matchingGrants
            }

            var skills: [ActiveSkillSnapshot] = []
            var mcpServers: [ActiveMCPConfiguration] = []
            var mcpInspectionDigests: [String: String] = [:]
            for grant in chosenGrants.sorted(by: { $0.extensionID < $1.extensionID }) {
                guard let config = document.configurations.first(where: { Self.extensionID(of: $0) == grant.extensionID }),
                      Self.configurationDigest(of: config) == grant.configurationDigest else {
                    throw ActiveExtensionRuntimeError.grantMissing(grant.extensionID)
                }
                let review = try Self.makeReview(extensionID: grant.extensionID, projectID: scope, provider: provider, profileID: profileID, document: document)
                guard grant.reviewedDigest == review.reviewedDigest else {
                    throw ActiveExtensionRuntimeError.grantMissing(grant.extensionID)
                }
                switch config {
                case .skill(let skill): skills.append(skill)
                case .mcp(let mcp):
                    guard let inspection = document.inspections.first(where: { $0.extensionID == grant.extensionID }) else {
                        throw ActiveExtensionRuntimeError.inspectionRequired(grant.extensionID)
                    }
                    mcpServers.append(mcp)
                    mcpInspectionDigests[grant.extensionID] = inspection.inspectionDigest
                }
            }
            let fingerprint = Self.fingerprint(projectID: scope, provider: provider, profileID: profileID, grants: chosenGrants)
            return ActiveExtensionInvocation(
                projectID: scope,
                provider: provider,
                profileID: profileID,
                workspacePath: validatedWorkspacePath,
                fingerprint: fingerprint,
                skills: skills,
                mcpServers: mcpServers,
                mcpInspectionDigests: mcpInspectionDigests
            )
        }
    }

    /// Pins the extension selection for a provider session. A resumed context
    /// cannot silently lose or gain previously approved instructions or tools.
    public func validateAndBind(sessionID: UUID, invocation: ActiveExtensionInvocation) throws {
        guard ActiveExtensionValidation.isSHA256(invocation.fingerprint) else { throw ActiveExtensionRuntimeError.storeCorrupt }
        try withDocument { document in
            try Self.validateCurrentInvocation(invocation, document: document)
            if let binding = document.sessionBindings.first(where: { $0.sessionID == sessionID }) {
                guard binding.fingerprint == invocation.fingerprint,
                      binding.projectID == invocation.projectID,
                      binding.provider == invocation.provider,
                      binding.profileID == invocation.profileID,
                      binding.workspacePath == invocation.workspacePath,
                      binding.extensionIDs == invocation.extensionIDs else {
                    throw ActiveExtensionRuntimeError.sessionFingerprintChanged
                }
                return
            }
            guard document.sessionBindings.count < Self.maximumSessionBindings else {
                throw AgentBridgeError.persistence("The active extension session-binding limit has been reached.")
            }
            document.sessionBindings.append(StoredSessionRuntimeBinding(
                sessionID: sessionID,
                projectID: invocation.projectID,
                provider: invocation.provider,
                profileID: invocation.profileID,
                workspacePath: invocation.workspacePath,
                extensionIDs: invocation.extensionIDs.sorted(),
                fingerprint: invocation.fingerprint,
                boundAt: Date()
            ))
        }
    }

    /// Rechecks the exact grant set captured before provider startup against
    /// the current runtime document. Managed runs call this again after their
    /// session is marked running, closing the gap while authentication or
    /// other startup work is suspended.
    public func validateCurrentInvocation(_ invocation: ActiveExtensionInvocation) throws {
        try withDocument { document in
            try Self.validateCurrentInvocation(invocation, document: document)
        }
    }

    public func sessionIDsUsingExtension(extensionID: String, projectID: String, provider: AgentProvider, profileID: UUID) throws -> [UUID] {
        let id = try ActiveExtensionValidation.identifier(extensionID, label: "extension ID")
        let scope = try ActiveExtensionValidation.identifier(projectID, label: "project ID")
        return try withDocument { document in
            document.sessionBindings.filter {
                $0.projectID == scope && $0.provider == provider && $0.profileID == profileID && $0.extensionIDs.contains(id)
            }.map(\.sessionID)
        }
    }

    public func sessionIDsUsingExtension(extensionID: String) throws -> [UUID] {
        let id = try ActiveExtensionValidation.identifier(extensionID, label: "extension ID")
        return try withDocument { document in
            document.sessionBindings.filter { $0.extensionIDs.contains(id) }.map(\.sessionID)
        }
    }

    public func grant(extensionID: String, projectID: String, provider: AgentProvider, profileID: UUID) throws -> ActiveExtensionGrant? {
        let id = try ActiveExtensionValidation.identifier(extensionID, label: "extension ID")
        let scope = try ActiveExtensionValidation.identifier(projectID, label: "project ID")
        return try withDocument { document in
            document.grants.first(where: { $0.matches(id: id, projectID: scope, provider: provider, profileID: profileID) })?.publicValue
        }
    }

    /// Revalidates a proxy ticket against current configuration, grant, scope,
    /// and the exact extension set pinned to its provider session.
    public func validateProxyTicket(_ ticket: MCPProxyTicket) throws {
        try ticket.validate()
        guard ticket.runtimeStoreRootPath == rootURL.path else {
            throw ActiveExtensionRuntimeError.grantMissing(ticket.extensionID)
        }
        try withDocument { document in
            guard let binding = document.sessionBindings.first(where: { $0.sessionID == ticket.sessionID }),
                  binding.projectID == ticket.projectID,
                  binding.provider == ticket.provider,
                  binding.profileID == ticket.profileID,
                  binding.workspacePath == ticket.workspacePath,
                  binding.fingerprint == ticket.sessionExtensionFingerprint,
                  binding.extensionIDs.contains(ticket.extensionID) else {
                throw ActiveExtensionRuntimeError.sessionFingerprintChanged
            }
            let activeGrants = document.grants.filter {
                $0.projectID == binding.projectID && $0.provider == binding.provider && $0.profileID == binding.profileID
                    && binding.extensionIDs.contains($0.extensionID)
            }
            guard activeGrants.count == binding.extensionIDs.count,
                  Self.fingerprint(projectID: binding.projectID, provider: binding.provider, profileID: binding.profileID, grants: activeGrants) == binding.fingerprint,
                  let grant = activeGrants.first(where: { $0.extensionID == ticket.extensionID }),
                  grant.configurationDigest == ticket.configurationDigest,
                  grant.reviewedDigest == ticket.reviewedDigest,
                  let configuration = document.configurations.first(where: { Self.extensionID(of: $0) == ticket.extensionID }),
                  case .mcp(let mcp) = configuration,
                  let inspection = document.inspections.first(where: { $0.extensionID == ticket.extensionID }),
                  inspection.inspectionDigest == ticket.serverInspectionDigest,
                  mcp.configurationDigest == ticket.configurationDigest,
                  mcp.executablePath == ticket.serverExecutablePath,
                  mcp.executableDigest == ticket.serverExecutableDigest,
                  mcp.arguments == ticket.serverArguments,
                  mcp.entrypointPins == ticket.serverEntrypointPins,
                  mcp.allowedTools == ticket.allowedTools,
                  mcp.startupTimeoutSeconds == ticket.startupTimeoutSeconds,
                  mcp.toolTimeoutSeconds == ticket.toolTimeoutSeconds,
                  ticket.maximumToolCallsPerRun <= mcp.maximumToolCallsPerRun,
                  ticket.maximumToolResponseBytes <= mcp.maximumToolResponseBytes,
                  ticket.maximumTotalToolResponseBytes <= mcp.maximumTotalToolResponseBytes,
                  mcp.launchConfiguration == ticket.launchConfiguration else {
                throw ActiveExtensionRuntimeError.grantMissing(ticket.extensionID)
            }
            let currentReview = try Self.makeReview(
                extensionID: ticket.extensionID,
                projectID: binding.projectID,
                provider: binding.provider,
                profileID: binding.profileID,
                document: document
            )
            guard currentReview.reviewedDigest == grant.reviewedDigest else {
                throw ActiveExtensionRuntimeError.grantMissing(ticket.extensionID)
            }
        }
    }

    public func auditEvents() throws -> [ActiveExtensionRuntimeAudit] {
        try withDocument { $0.auditEvents.map(\.publicValue) }
    }

    private func withDocument<T>(_ operation: (inout ActiveExtensionRuntimeDocument) throws -> T) throws -> T {
        try AgentBridgePrivateJSONDocument.withLockedRoot(rootURL: rootURL) { directoryDescriptor in
            var document = try Self.readDocument(directoryDescriptor: directoryDescriptor)
            let originalData = try Self.encode(document)
            let result = try operation(&document)
            let updatedData = try Self.encode(document)
            if originalData != updatedData {
                try AgentBridgePrivateJSONDocument.write(updatedData, fileName: Self.fileName, maximumBytes: Self.maximumStoredBytes, directoryDescriptor: directoryDescriptor)
            }
            return result
        }
    }

    private static func makeReview(
        extensionID: String,
        projectID: String,
        provider: AgentProvider,
        profileID: UUID,
        document: ActiveExtensionRuntimeDocument
    ) throws -> ActiveExtensionActivationReview {
        guard let config = document.configurations.first(where: { Self.extensionID(of: $0) == extensionID }) else {
            throw ActiveExtensionRuntimeError.configurationMissing(extensionID)
        }
        let configDigest = Self.configurationDigest(of: config)
        var skillDigest: String?
        var instructionText: String?
        var executablePath: String?
        var arguments: [String] = []
        var entrypointPins: [MCPEntrypointPin] = []
        var allowedTools: [String] = []
        var inspectedTools: [String] = []
        var toolDefinitionsJSON: String?
        var maximumToolCallsPerRun: Int?
        var maximumToolResponseBytes: Int?
        var maximumTotalToolResponseBytes: Int?
        var macControlTargetBundleID: String?
        var macControlAccessMode: MacControlAccessMode?
        var macControlActionNames: [String] = []
        var screenCaptureDisclosure: String?
        var inspectionDigest = ""
        switch config {
        case .skill(let skill):
            skillDigest = skill.contentDigest
            instructionText = skill.instructionText
        case .mcp(let mcp):
            guard let inspection = document.inspections.first(where: { $0.extensionID == extensionID }),
                  inspection.configurationDigest == mcp.configurationDigest else {
                throw ActiveExtensionRuntimeError.inspectionRequired(extensionID)
            }
            guard Set(mcp.allowedTools).isSubset(of: Set(inspection.toolNames)) else {
                throw ActiveExtensionRuntimeError.inspectionMismatch(extensionID)
            }
            if provider == .claude {
                let serverID = MCPServerIdentifier.make(extensionID: extensionID)
                guard mcp.allowedTools.allSatisfy({ "mcp__\(serverID)__\($0)".utf8.count <= 128 }) else {
                    throw ActiveExtensionRuntimeError.invalidConfiguration("A fully qualified Claude MCP tool name exceeds Claude's 128-character limit.")
                }
            }
            executablePath = mcp.executablePath
            arguments = mcp.arguments
            entrypointPins = mcp.entrypointPins
            allowedTools = mcp.allowedTools
            inspectedTools = inspection.toolNames
            toolDefinitionsJSON = inspection.toolDefinitionsJSON
            maximumToolCallsPerRun = mcp.maximumToolCallsPerRun
            maximumToolResponseBytes = mcp.maximumToolResponseBytes
            maximumTotalToolResponseBytes = mcp.maximumTotalToolResponseBytes
            macControlTargetBundleID = mcp.macControlTargetBundleID
            macControlAccessMode = mcp.macControlAccessMode
            macControlActionNames = mcp.macControlActionNames
            screenCaptureDisclosure = mcp.screenCaptureDisclosure
            inspectionDigest = inspection.inspectionDigest
        }
        let reviewedDigest = ActiveExtensionDigest.make([
            "extension", extensionID, "project", projectID, "provider", provider.rawValue,
            "profile", profileID.uuidString.lowercased(), "configuration", configDigest,
            "inspection", inspectionDigest, "trustWarningVersion", "1"
        ])
        return ActiveExtensionActivationReview(
            extensionID: extensionID,
            projectID: projectID,
            provider: provider,
            profileID: profileID,
            configurationDigest: configDigest,
            reviewedDigest: reviewedDigest,
            skillDigest: skillDigest,
            instructionText: instructionText,
            executablePath: executablePath,
            arguments: arguments,
            entrypointPins: entrypointPins,
            allowedTools: allowedTools,
            inspectedTools: inspectedTools,
            toolDefinitionsJSON: toolDefinitionsJSON,
            maximumToolCallsPerRun: maximumToolCallsPerRun,
            maximumToolResponseBytes: maximumToolResponseBytes,
            maximumTotalToolResponseBytes: maximumTotalToolResponseBytes,
            trustWarning: Self.executionTrustWarning,
            macControlTargetBundleID: macControlTargetBundleID,
            macControlAccessMode: macControlAccessMode,
            macControlActionNames: macControlActionNames,
            screenCaptureDisclosure: screenCaptureDisclosure
        )
    }

    private static func replaceConfiguration(_ newConfig: RuntimeExtensionConfiguration, in document: inout ActiveExtensionRuntimeDocument) throws {
        let id = extensionID(of: newConfig)
        if let existing = document.configurations.first(where: { extensionID(of: $0) == id }),
           configurationDigest(of: existing) == configurationDigest(of: newConfig) {
            return
        }
        document.configurations.removeAll { extensionID(of: $0) == id }
        document.grants.removeAll { $0.extensionID == id }
        document.inspections.removeAll { $0.extensionID == id }
        guard document.configurations.count < maximumConfigurations else {
            throw AgentBridgeError.persistence("The active extension configuration limit has been reached.")
        }
        document.configurations.append(newConfig)
    }

    private static func extensionID(of configuration: RuntimeExtensionConfiguration) -> String {
        switch configuration { case .skill(let skill): skill.extensionID; case .mcp(let mcp): mcp.extensionID }
    }

    private static func configurationDigest(of configuration: RuntimeExtensionConfiguration) -> String {
        switch configuration { case .skill(let skill): skill.configurationDigest; case .mcp(let mcp): mcp.configurationDigest }
    }

    private static func fingerprint(projectID: String, provider: AgentProvider, profileID: UUID, grants: [StoredActiveExtensionGrant]) -> String {
        let sortedGrants = grants.sorted { $0.extensionID < $1.extensionID }
        return ActiveExtensionDigest.make([
            "project", projectID, "provider", provider.rawValue, "profile", profileID.uuidString.lowercased(),
            "grants.count", String(sortedGrants.count)
        ] + sortedGrants.flatMap {
            ["extension", $0.extensionID, "grant", $0.grantID.uuidString.lowercased(), "configuration", $0.configurationDigest, "review", $0.reviewedDigest]
        })
    }

    private static func validateCurrentInvocation(
        _ invocation: ActiveExtensionInvocation,
        document: ActiveExtensionRuntimeDocument
    ) throws {
        guard ActiveExtensionValidation.isSHA256(invocation.fingerprint),
              Set(invocation.extensionIDs).count == invocation.extensionIDs.count else {
            throw ActiveExtensionRuntimeError.storeCorrupt
        }
        let requestedIDs = Set(invocation.extensionIDs)
        let activeGrants = document.grants.filter {
            $0.projectID == invocation.projectID
                && $0.provider == invocation.provider
                && $0.profileID == invocation.profileID
                && requestedIDs.contains($0.extensionID)
        }
        guard activeGrants.count == requestedIDs.count else {
            let missingID = invocation.extensionIDs.first { requested in
                !activeGrants.contains(where: { $0.extensionID == requested })
            } ?? "unknown"
            throw ActiveExtensionRuntimeError.grantMissing(missingID)
        }
        guard Self.fingerprint(
            projectID: invocation.projectID,
            provider: invocation.provider,
            profileID: invocation.profileID,
            grants: activeGrants
        ) == invocation.fingerprint else {
            throw ActiveExtensionRuntimeError.sessionFingerprintChanged
        }

        for grant in activeGrants {
            guard let configuration = document.configurations.first(where: { Self.extensionID(of: $0) == grant.extensionID }),
                  Self.configurationDigest(of: configuration) == grant.configurationDigest else {
                throw ActiveExtensionRuntimeError.grantMissing(grant.extensionID)
            }
            let currentReview = try Self.makeReview(
                extensionID: grant.extensionID,
                projectID: invocation.projectID,
                provider: invocation.provider,
                profileID: invocation.profileID,
                document: document
            )
            guard currentReview.reviewedDigest == grant.reviewedDigest else {
                throw ActiveExtensionRuntimeError.grantMissing(grant.extensionID)
            }
            switch configuration {
            case .skill(let skill):
                guard invocation.skills.first(where: { $0.extensionID == grant.extensionID }) == skill,
                      !invocation.mcpServers.contains(where: { $0.extensionID == grant.extensionID }) else {
                    throw ActiveExtensionRuntimeError.sessionFingerprintChanged
                }
            case .mcp(let mcp):
                guard invocation.mcpServers.first(where: { $0.extensionID == grant.extensionID }) == mcp,
                      !invocation.skills.contains(where: { $0.extensionID == grant.extensionID }),
                      invocation.mcpInspectionDigests[grant.extensionID] == document.inspections.first(where: { $0.extensionID == grant.extensionID })?.inspectionDigest else {
                    throw ActiveExtensionRuntimeError.sessionFingerprintChanged
                }
            }
        }
    }

    private static func summary(_ configuration: RuntimeExtensionConfiguration) -> ActiveExtensionConfigurationSummary {
        switch configuration {
        case .skill(let skill):
            ActiveExtensionConfigurationSummary(id: skill.extensionID, kind: .skill, name: skill.name, version: skill.version, summary: skill.summary, sourceReference: skill.sourceReference, configurationDigest: skill.configurationDigest, skillDigest: skill.contentDigest, executablePath: nil, arguments: [], entrypointPins: [], allowedTools: [], startupTimeoutSeconds: nil, toolTimeoutSeconds: nil, maximumToolCallsPerRun: nil, maximumToolResponseBytes: nil, maximumTotalToolResponseBytes: nil, macControlTargetBundleID: nil, macControlAccessMode: nil, macControlActionNames: [], screenCaptureDisclosure: nil)
        case .mcp(let mcp):
            ActiveExtensionConfigurationSummary(id: mcp.extensionID, kind: .mcp, name: mcp.name, version: mcp.version, summary: mcp.summary, sourceReference: mcp.sourceReference, configurationDigest: mcp.configurationDigest, skillDigest: nil, executablePath: mcp.executablePath, arguments: mcp.arguments, entrypointPins: mcp.entrypointPins, allowedTools: mcp.allowedTools, startupTimeoutSeconds: mcp.startupTimeoutSeconds, toolTimeoutSeconds: mcp.toolTimeoutSeconds, maximumToolCallsPerRun: mcp.maximumToolCallsPerRun, maximumToolResponseBytes: mcp.maximumToolResponseBytes, maximumTotalToolResponseBytes: mcp.maximumTotalToolResponseBytes, macControlTargetBundleID: mcp.macControlTargetBundleID, macControlAccessMode: mcp.macControlAccessMode, macControlActionNames: mcp.macControlActionNames, screenCaptureDisclosure: mcp.screenCaptureDisclosure)
        }
    }

    /// Imports a validated runtime document from the legacy user-root
    /// location when this private store has none yet.
    @discardableResult
    public func importLegacyDocument(from legacyRootURL: URL) throws -> Bool {
        try AgentBridgePrivateJSONDocument.importLegacyDocument(
            fileName: Self.fileName,
            maximumBytes: Self.maximumStoredBytes,
            from: legacyRootURL,
            into: rootURL
        ) { directoryDescriptor in
            guard try AgentBridgePrivateJSONDocument.read(fileName: Self.fileName, maximumBytes: Self.maximumStoredBytes, directoryDescriptor: directoryDescriptor) != nil else {
                return nil
            }
            return try Self.encode(Self.readDocument(directoryDescriptor: directoryDescriptor))
        }
    }

    private static func readDocument(directoryDescriptor: Int32) throws -> ActiveExtensionRuntimeDocument {
        guard let data = try AgentBridgePrivateJSONDocument.read(fileName: Self.fileName, maximumBytes: Self.maximumStoredBytes, directoryDescriptor: directoryDescriptor) else {
            return ActiveExtensionRuntimeDocument()
        }
        do {
            let document = try makeDecoder().decode(ActiveExtensionRuntimeDocument.self, from: data)
            guard document.schemaVersion == 1,
                  document.configurations.count <= maximumConfigurations,
                  document.grants.count <= maximumGrants,
                  document.inspections.count <= maximumInspections,
                  document.sessionBindings.count <= maximumSessionBindings,
                  document.auditEvents.count <= maximumAuditEvents,
                  Set(document.configurations.map(Self.extensionID(of:))).count == document.configurations.count,
                  Set(document.grants.map(\.key)).count == document.grants.count,
                  Set(document.inspections.map(\.extensionID)).count == document.inspections.count,
                  Set(document.sessionBindings.map(\.sessionID)).count == document.sessionBindings.count,
                  document.grants.allSatisfy({ grant in
                      guard let config = document.configurations.first(where: { Self.extensionID(of: $0) == grant.extensionID }) else { return false }
                      return grant.isValid && grant.configurationDigest == Self.configurationDigest(of: config)
                  }),
                  document.inspections.allSatisfy({ inspection in
                      guard let config = document.configurations.first(where: { Self.extensionID(of: $0) == inspection.extensionID }),
                            case .mcp(let mcp) = config else { return false }
                      return inspection.configurationDigest == mcp.configurationDigest
                          && inspection.toolNames.count <= 512
                          && inspection.toolNames == inspection.toolNames.sorted()
                          && Set(inspection.toolNames).count == inspection.toolNames.count
                          && inspection.toolNames.allSatisfy(ActiveExtensionValidation.isToolName)
                          && MCPServerInspection.isValidToolDefinitionsJSON(inspection.toolDefinitionsJSON, toolNames: inspection.toolNames)
                          && inspection.inspectionDigest == MCPServerInspection.makeDigest(configurationDigest: inspection.configurationDigest, toolNames: inspection.toolNames, toolDefinitionsJSON: inspection.toolDefinitionsJSON)
                          && Set(mcp.allowedTools).isSubset(of: Set(inspection.toolNames))
                  }),
                  document.sessionBindings.allSatisfy(\.isValid) else {
                throw ActiveExtensionRuntimeError.storeCorrupt
            }
            return document
        } catch let error as AgentBridgeError { throw error }
        catch let error as ActiveExtensionRuntimeError { throw error }
        catch { throw ActiveExtensionRuntimeError.storeCorrupt }
    }

    private static func encode(_ document: ActiveExtensionRuntimeDocument) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(document)
            guard data.count <= maximumStoredBytes else { throw AgentBridgeError.persistence("Active extension runtime storage exceeds its size limit.") }
            return data
        } catch let error as AgentBridgeError { throw error }
        catch { throw AgentBridgeError.persistence("Active extension runtime storage could not be encoded.") }
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func trimAudit(_ events: inout [StoredExtensionRuntimeAudit]) {
        if events.count > maximumAuditEvents { events.removeFirst(events.count - maximumAuditEvents) }
    }
}
