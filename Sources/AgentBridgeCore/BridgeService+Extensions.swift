import Darwin
import Foundation

extension BridgeService {
    public func extensionDescriptors() throws -> [ExtensionDescriptor] {
        try extensionPolicyStore.listDescriptors()
    }

    public func extensionGrant(extensionID: String, projectID: String) throws -> ExtensionGrant? {
        try extensionPolicyStore.grant(forExtensionID: extensionID, projectID: projectID)
    }

    public func extensionProjectID(sessionID: UUID) throws -> String {
        let session = try loadSession(sessionID)
        let repository = try ProjectMemoryRepositoryScope(repositoryPath: session.sourceRepositoryPath)
        return "project-\(repository.key.prefix(48))"
    }

    @discardableResult
    public func importExtensionDescriptor(
        _ descriptor: ExtensionDescriptor,
        source: ExtensionImportSource,
        sourceReference: String
    ) throws -> ExtensionProvenance {
        try extensionPolicyStore.importDescriptor(
            descriptor,
            source: source,
            sourceReference: sourceReference,
            importedBy: "AgentBridge App"
        )
    }

    @discardableResult
    public func grantExtensionPermissions(
        extensionID: String,
        projectID: String,
        permissions: [ExtensionPermission],
        allowedRelativePaths: [String] = [],
        allowedHosts: [String] = []
    ) throws -> ExtensionGrant {
        try extensionPolicyStore.grant(
            extensionID: extensionID,
            projectID: projectID,
            permissions: permissions,
            allowedRelativePaths: allowedRelativePaths,
            allowedHosts: allowedHosts,
            grantedBy: "AgentBridge App"
        )
    }

    @discardableResult
    public func revokeExtensionPermissions(extensionID: String, projectID: String) throws -> Bool {
        try extensionPolicyStore.revoke(
            extensionID: extensionID,
            projectID: projectID,
            revokedBy: "AgentBridge App"
        )
    }

    public func activeExtensionConfigurations() throws -> [ActiveExtensionConfigurationSummary] {
        try activeExtensionRuntimeStore.configurations()
    }

    /// Returns the last explicit, bounded MCP Test Connection result without
    /// starting the server again. The saved definitions remain tied to their
    /// imported executable/configuration digest.
    public func activeExtensionInspection(extensionID: String) throws -> MCPServerInspection? {
        try activeExtensionRuntimeStore.inspection(extensionID: extensionID)
    }

    public func macControlPresetStatus(
        targetBundleID: String? = nil,
        accessMode: MacControlAccessMode = .observe
    ) -> MacControlPresetStatus {
        let helper = try? MCPExecutableValidation.resolveAndDigest(AgentBridgeHelperExecutable.installedMacControlHelperPath)
        let proxy = try? resolvedRuntimeProxyExecutable()
        let validTarget = targetBundleID.map(MacControlActionPolicy.isAllowedTarget) ?? true
        let message: String
        if !validTarget {
            message = "Choose an app outside protected settings, credential, AgentBridge, MacControl, and terminal apps."
        } else if helper == nil {
            message = "The installed MacControl helper was not found at its trusted application path."
        } else if proxy == nil {
            message = "The AgentBridge MCP proxy executable is unavailable."
        } else {
            message = "The trusted helper and AgentBridge proxy are available. Test permission status and review the target before enabling."
        }
        return MacControlPresetStatus(
            targetBundleID: targetBundleID,
            accessMode: accessMode,
            helperAvailable: helper != nil,
            helperPath: helper?.path,
            helperDigest: helper?.digest,
            proxyAvailable: proxy != nil,
            proxyExecutablePath: proxy?.path,
            proxyExecutableDigest: proxy?.digest,
            message: message
        )
    }

    @discardableResult
    public func importMacControlPreset(
        targetBundleID: String,
        accessMode: MacControlAccessMode = .observe
    ) throws -> ActiveMCPConfiguration {
        guard MacControlActionPolicy.isAllowedTarget(targetBundleID) else {
            throw AgentBridgeError.invalidInput("Choose an app outside protected settings, credential, AgentBridge, MacControl, and terminal apps.")
        }
        let helper = try MCPExecutableValidation.resolveAndDigest(AgentBridgeHelperExecutable.installedMacControlHelperPath)
        let proxy = try resolvedRuntimeProxyExecutable()
        let extensionID = "mac-control.\(MCPServerIdentifier.make(extensionID: targetBundleID))"
        let oldDigest = try activeExtensionRuntimeStore.configurations().first(where: { $0.id == extensionID })?.configurationDigest
        let configuration = try ActiveMCPConfiguration(
            macControlTargetBundleID: targetBundleID,
            accessMode: accessMode,
            helperPath: helper.path,
            helperDigest: helper.digest,
            proxyExecutablePath: proxy.path,
            proxyExecutableDigest: proxy.digest,
            version: "1"
        )
        try activeExtensionRuntimeStore.importMCP(configuration)
        try cancelBoundExtensionSessionsIfChanged(extensionID: configuration.extensionID, previousDigest: oldDigest, newDigest: configuration.configurationDigest)
        return configuration
    }

    /// Explicit, status-only readiness probe. It starts only the fixed trusted
    /// MacControl helper, calls `mac_status`, and never requests TCC access or
    /// captures a screenshot or sends input.
    public func testMacControlPermissions(
        targetBundleID: String,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> MacControlPermissionReadiness {
        guard MacControlActionPolicy.isAllowedTarget(targetBundleID) else {
            throw AgentBridgeError.invalidInput("Choose an app outside protected settings, credential, AgentBridge, MacControl, and terminal apps.")
        }
        let helper = try MCPExecutableValidation.resolveAndDigest(AgentBridgeHelperExecutable.installedMacControlHelperPath)
        let directory = try makePrivateTemporaryDirectory(label: "mac-control-status-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = try MCPRuntimeImportManifest(
            id: "mac-control-readiness",
            name: "MacControl status probe",
            version: "1",
            summary: "Status-only readiness probe.",
            command: helper.path,
            args: [],
            allowedTools: ["mac_status"],
            startupTimeoutSeconds: 15,
            toolTimeoutSeconds: 15,
            maximumToolCallsPerRun: 1,
            maximumToolResponseBytes: 64 * 1_024,
            maximumTotalToolResponseBytes: 64 * 1_024
        )
        let configuration = try ActiveMCPConfiguration(
            manifest: manifest,
            sourceReference: "builtin:mac-control-status-probe",
            resolvedExecutablePath: helper.path,
            executableDigest: helper.digest
        )
        let reply = try await Task.detached(priority: .userInitiated) { [baseEnvironment] in
            try MCPStdioRuntime.callToolForTesting(
                configuration: configuration,
                environment: baseEnvironment,
                privateDirectory: directory,
                toolName: "mac_status",
                arguments: [:],
                cancellation: cancellation
            )
        }.value
        let statusText = reply.text.joined(separator: "\n")
            .unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
            .map(String.init).joined()
        return MacControlPermissionReadiness(
            targetBundleID: targetBundleID,
            helperAvailable: true,
            statusToolAvailable: !reply.isError,
            statusText: String(OutputRedactor.redact(statusText).prefix(4_096)),
            checkedAt: Date()
        )
    }

    /// Imports only the bounded SKILL.md text. It does not run referenced
    /// scripts, hooks, installers, or dependencies.
    @discardableResult
    public func importSkillRuntime(
        descriptor: ExtensionDescriptor,
        sourceReference: String,
        skillFileURL: URL
    ) throws -> ActiveSkillSnapshot {
        guard descriptor.kind == .skill else {
            throw AgentBridgeError.invalidInput("Choose a Skill descriptor for SKILL.md import.")
        }
        let text = try ActiveSkillFileReader.read(at: skillFileURL)
        let snapshot = try ActiveSkillSnapshot(
            descriptor: descriptor,
            sourceReference: sourceReference,
            instructionText: text
        )
        let oldDigest = try activeExtensionRuntimeStore.configurations().first(where: { $0.id == snapshot.extensionID })?.configurationDigest
        try activeExtensionRuntimeStore.importSkill(snapshot)
        try cancelBoundExtensionSessionsIfChanged(extensionID: snapshot.extensionID, previousDigest: oldDigest, newDigest: snapshot.configurationDigest)
        return snapshot
    }

    @discardableResult
    public func importMCPRuntimeManifest(
        _ manifest: MCPRuntimeImportManifest,
        sourceReference: String
    ) throws -> ActiveMCPConfiguration {
        let oldDigest = try activeExtensionRuntimeStore.configurations().first(where: { $0.id == manifest.id })?.configurationDigest
        let executable = try MCPExecutableValidation.resolveAndDigest(manifest.command)
        let configuration = try ActiveMCPConfiguration(
            manifest: manifest,
            sourceReference: sourceReference,
            resolvedExecutablePath: executable.path,
            executableDigest: executable.digest
        )
        try activeExtensionRuntimeStore.importMCP(configuration)
        try cancelBoundExtensionSessionsIfChanged(extensionID: configuration.extensionID, previousDigest: oldDigest, newDigest: configuration.configurationDigest)
        return configuration
    }

    @discardableResult
    public func importMCPRuntimeManifest(
        at manifestURL: URL,
        maximumBytes: Int = 64 * 1_024
    ) throws -> ActiveMCPConfiguration {
        let data = try BoundedDescriptorFileReader.read(at: manifestURL, maximumBytes: maximumBytes)
        let manifest: MCPRuntimeImportManifest
        do { manifest = try JSONDecoder().decode(MCPRuntimeImportManifest.self, from: data) }
        catch { throw AgentBridgeError.invalidInput("The MCP runtime JSON manifest is invalid.") }
        return try importMCPRuntimeManifest(manifest, sourceReference: manifestURL.path)
    }

    /// Starts the selected MCP server only after the caller explicitly asks to
    /// test it. This performs initialize and bounded, paginated tools/list; it
    /// does not call an MCP tool or an AI/model API.
    public func testMCPRuntime(
        extensionID: String,
        cancellation: CancellationFlag = CancellationFlag()
    ) async throws -> MCPServerInspection {
        guard let configuration = try activeExtensionRuntimeStore.mcpConfiguration(extensionID: extensionID) else {
            throw ActiveExtensionRuntimeError.configurationMissing(extensionID)
        }
        let temporaryDirectory = try makePrivateTemporaryDirectory(label: "mcp-test-\(UUID().uuidString.lowercased())")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let inspection = try await MCPStdioRuntime.inspect(
            configuration: configuration,
            baseEnvironment: baseEnvironment,
            privateDirectory: temporaryDirectory,
            cancellation: cancellation
        )
        let inspectionChanged = try activeExtensionRuntimeStore.recordInspection(inspection)
        if inspectionChanged {
            let affected = try activeExtensionRuntimeStore.sessionIDsUsingExtension(extensionID: extensionID)
            _ = cancelRunningExtensionSessions(affected)
        }
        return inspection
    }

    public func previewExtensionActivation(
        extensionID: String,
        sessionID: UUID
    ) throws -> ActiveExtensionActivationReview {
        let session = try loadSession(sessionID)
        let profile = try requireBoundProfile(for: session, allowUnselected: true)
        return try activeExtensionRuntimeStore.preview(
            extensionID: extensionID,
            projectID: extensionProjectID(for: session),
            provider: session.provider,
            profileID: profile.id
        )
    }

    @discardableResult
    public func enableExtensionRuntime(
        extensionID: String,
        sessionID: UUID,
        reviewedDigest: String,
        explicitExecutionConsent: Bool,
        explicitScreenCaptureConsent: Bool = false,
        explicitInputControlConsent: Bool = false
    ) throws -> ActiveExtensionGrant {
        let session = try loadSession(sessionID)
        let profile = try requireBoundProfile(for: session, allowUnselected: true)
        return try activeExtensionRuntimeStore.enable(
            extensionID: extensionID,
            projectID: extensionProjectID(for: session),
            provider: session.provider,
            profileID: profile.id,
            reviewedDigest: reviewedDigest,
            explicitExecutionConsent: explicitExecutionConsent,
            explicitScreenCaptureConsent: explicitScreenCaptureConsent,
            explicitInputControlConsent: explicitInputControlConsent,
            grantedBy: "AgentBridge App"
        )
    }

    @discardableResult
    public func disableExtensionRuntime(extensionID: String, sessionID: UUID) throws -> Bool {
        let session = try loadSession(sessionID)
        let profile = try requireBoundProfile(for: session, allowUnselected: true)
        let projectID = try extensionProjectID(for: session)
        let matchingSessions = try activeExtensionRuntimeStore.sessionIDsUsingExtension(
            extensionID: extensionID,
            projectID: projectID,
            provider: session.provider,
            profileID: profile.id
        )
        let disabled = try activeExtensionRuntimeStore.disable(
            extensionID: extensionID,
            projectID: projectID,
            provider: session.provider,
            profileID: profile.id,
            disabledBy: "AgentBridge App"
        )
        if disabled { cancelRunningExtensionSessions(matchingSessions) }
        return disabled
    }

    @discardableResult
    public func stopMacControl(extensionID: String, sessionID: UUID) throws -> [UUID] {
        guard let configuration = try activeExtensionRuntimeStore.mcpConfiguration(extensionID: extensionID),
              configuration.macControlAccessMode == .control else {
            throw ActiveExtensionRuntimeError.configurationMissing(extensionID)
        }
        let session = try loadSession(sessionID)
        let profile = try requireBoundProfile(for: session, allowUnselected: true)
        let projectID = try extensionProjectID(for: session)
        let affected = try activeExtensionRuntimeStore.sessionIDsUsingExtension(
            extensionID: extensionID,
            projectID: projectID,
            provider: session.provider,
            profileID: profile.id
        )
        let revoked = try activeExtensionRuntimeStore.disable(
            extensionID: extensionID,
            projectID: projectID,
            provider: session.provider,
            profileID: profile.id,
            disabledBy: "AgentBridge Stop Control"
        )
        guard revoked else { return [] }
        return cancelRunningExtensionSessions(affected)
    }

    public func activeExtensionsForSession(
        sessionID: UUID,
        extensionIDs: [String]? = nil
    ) throws -> ActiveExtensionInvocation {
        let session = try loadSession(sessionID)
        let profileID = session.accountProfileID ?? AccountProfile.defaultID(for: session.provider)
        _ = try accountProfile(id: profileID)
        return try activeExtensionRuntimeStore.invocation(
            projectID: extensionProjectID(for: session),
            provider: session.provider,
            profileID: profileID,
            workspacePath: session.workspacePath,
            selectedExtensionIDs: extensionIDs
        )
    }

    public func activeExtensionRuntimeAuditEvents() throws -> [ActiveExtensionRuntimeAudit] {
        try activeExtensionRuntimeStore.auditEvents()
    }
    func makeMCPRunDirectoryLease(
        for invocation: ActiveExtensionInvocation,
        session: SessionRecord,
        providerTemporaryDirectory: URL
    ) throws -> MCPRunDirectoryLease? {
        guard !invocation.mcpServers.isEmpty else { return nil }
        return try MCPRunDirectoryLease(
            applicationSupportRoot: store.rootURL,
            providerWriteRoots: [
                URL(fileURLWithPath: session.workspacePath, isDirectory: true),
                providerTemporaryDirectory
            ]
        )
    }

    private func resolvedRuntimeProxyExecutable() throws -> (path: String, digest: String) {
        let resolved: (path: String, digest: String)
        if let runtimeProxyExecutableURL {
            resolved = try MCPExecutableValidation.resolveAndDigest(runtimeProxyExecutableURL.path)
        } else {
            let executable = try AgentBridgeHelperExecutable.resolve()
            resolved = try MCPExecutableValidation.resolveAndDigest(executable.path)
        }
        return resolved
    }

    func prepareMCPServerCommands(
        invocation: ActiveExtensionInvocation,
        session: SessionRecord,
        ticketDirectory: URL?,
        maximumToolCallsPerServer: Int?
    ) throws -> [MCPServerCommandConfiguration] {
        guard invocation.workspacePath == session.workspacePath else {
            throw ActiveExtensionRuntimeError.sessionFingerprintChanged
        }
        guard !invocation.mcpServers.isEmpty else { return [] }
        guard let ticketDirectory else {
            throw AgentBridgeError.persistence("The private MCP control-plane directory is unavailable.")
        }
        let proxy = try resolvedRuntimeProxyExecutable()
        return try invocation.mcpServers.map { configuration in
            guard let inspectionDigest = invocation.mcpInspectionDigests[configuration.extensionID] else {
                throw ActiveExtensionRuntimeError.inspectionRequired(configuration.extensionID)
            }
            guard try MCPExecutableValidation.digestExecutable(at: configuration.executablePath) == configuration.executableDigest else {
                throw ActiveExtensionRuntimeError.invalidConfiguration("The MCP executable changed after it was imported and reviewed.")
            }
            try MCPEntrypointIntegrity.validate(configuration.entrypointPins, workspacePath: session.workspacePath)
            let configuredProxy: (path: String, digest: String)
            switch configuration.launchConfiguration {
            case .stdio:
                configuredProxy = proxy
            case .macControlProxy(_, _, let path, let digest, _, _):
                guard try MCPExecutableValidation.digestExecutable(at: path) == digest,
                      proxy.path == path, proxy.digest == digest else {
                    throw ActiveExtensionRuntimeError.invalidConfiguration("The bundled AgentBridge proxy changed after the MacControl preset was reviewed.")
                }
                configuredProxy = (path, digest)
            }
            let grant = try activeExtensionRuntimeStore.grant(
                extensionID: configuration.extensionID,
                projectID: invocation.projectID,
                provider: invocation.provider,
                profileID: invocation.profileID
            )
            guard let grant, grant.configurationDigest == configuration.configurationDigest else {
                throw ActiveExtensionRuntimeError.grantMissing(configuration.extensionID)
            }
            let callLimit = min(configuration.maximumToolCallsPerRun, maximumToolCallsPerServer ?? configuration.maximumToolCallsPerRun)
            let ticketURL = ticketDirectory.appendingPathComponent(
                "mcp-proxy-\(MCPServerIdentifier.make(extensionID: configuration.extensionID)).json",
                isDirectory: false
            )
            let receiptURL = ticketDirectory.appendingPathComponent(
                "mcp-proxy-receipt-\(MCPServerIdentifier.make(extensionID: configuration.extensionID)).json",
                isDirectory: false
            )
            let ticket = try MCPProxyTicket(
                sessionID: session.id,
                extensionID: configuration.extensionID,
                projectID: invocation.projectID,
                provider: invocation.provider,
                profileID: invocation.profileID,
                configurationDigest: configuration.configurationDigest,
                reviewedDigest: grant.reviewedDigest,
                serverInspectionDigest: inspectionDigest,
                sessionExtensionFingerprint: invocation.fingerprint,
                runtimeStoreRootPath: activeExtensionRuntimeStore.rootURL.path,
                workspacePath: session.workspacePath,
                cancellationRequestPath: store.cancellationRequestURL(for: session.id).path,
                receiptPath: receiptURL.path,
                proxyExecutablePath: configuredProxy.path,
                proxyExecutableDigest: configuredProxy.digest,
                serverExecutablePath: configuration.executablePath,
                serverExecutableDigest: configuration.executableDigest,
                serverArguments: configuration.arguments,
                serverEntrypointPins: configuration.entrypointPins,
                allowedTools: configuration.allowedTools,
                startupTimeoutSeconds: configuration.startupTimeoutSeconds,
                toolTimeoutSeconds: configuration.toolTimeoutSeconds,
                maximumToolCallsPerRun: callLimit,
                maximumToolResponseBytes: configuration.maximumToolResponseBytes,
                maximumTotalToolResponseBytes: configuration.maximumTotalToolResponseBytes,
                launchConfiguration: configuration.launchConfiguration,
                expiresAt: Date().addingTimeInterval(1_200)
            )
            try MCPProxyTicketFile.write(ticket, to: ticketURL)
            return try MCPServerCommandConfiguration(
                configuration: configuration,
                proxyExecutablePath: configuredProxy.path,
                ticketURL: ticketURL,
                receiptURL: receiptURL,
                ticketID: ticket.ticketID,
                inspectionDigest: inspectionDigest,
                maximumToolCallsPerRun: callLimit
            )
        }
    }

    func recordMCPProxyReceipts(
        _ commands: [MCPServerCommandConfiguration],
        sessionID: UUID,
        failOnIncomplete: Bool
    ) throws {
        for command in commands {
            let receiptURL = URL(fileURLWithPath: command.receiptPath, isDirectory: false)
            guard FileManager.default.fileExists(atPath: receiptURL.path) else {
                try store.appendEvent(AuditEvent(
                    sessionID: sessionID,
                    kind: "mcp.proxy.not_initialized",
                    message: "Approved MCP server \(command.extensionID) was not initialized by the provider; no MCP call was reported."
                ))
                continue
            }
            let receipt: MCPProxyReceipt
            do { receipt = try MCPProxyReceiptFile.read(from: receiptURL) }
            catch {
                try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "mcp.proxy.receipt.invalid", message: "Approved MCP server \(command.extensionID) returned an invalid private receipt."))
                if failOnIncomplete { throw ActiveExtensionRuntimeError.proxyFailed(command.extensionID) }
                continue
            }
            guard receipt.ticketID == command.ticketID,
                  receipt.extensionID == command.extensionID,
                  receipt.configurationDigest == command.configurationDigest else {
                try? store.appendEvent(AuditEvent(sessionID: sessionID, kind: "mcp.proxy.receipt.invalid", message: "Approved MCP server \(command.extensionID) returned a receipt for another runtime configuration."))
                if failOnIncomplete { throw ActiveExtensionRuntimeError.proxyFailed(command.extensionID) }
                continue
            }
            guard receipt.status == .initialized else {
                try store.appendEvent(AuditEvent(
                    sessionID: sessionID,
                    kind: "mcp.proxy.failed",
                    message: "Approved MCP server \(command.extensionID) did not initialize successfully (\(receipt.failureCode?.rawValue ?? "incomplete"))."
                ))
                if failOnIncomplete { throw ActiveExtensionRuntimeError.proxyFailed(command.extensionID) }
                continue
            }
            let kind = receipt.toolCallCount == 0 ? "mcp.proxy.initialized_unused" : "mcp.proxy.used"
            let summary = receipt.toolCallCount == 0
                ? "Approved MCP server \(command.extensionID) initialized; the provider reported no tool calls."
                : "Approved MCP server \(command.extensionID) initialized and completed \(receipt.toolCallCount) allowlisted tool call(s)."
            try store.appendEvent(AuditEvent(sessionID: sessionID, kind: kind, message: summary))
        }
    }

    @discardableResult
    private func cancelRunningExtensionSessions(_ sessionIDs: [UUID]) -> [UUID] {
        sessionIDs.filter { id in
            guard let session = try? store.session(id: id), session.status == .running else { return false }
            do {
                try store.requestCancellation(for: id)
                return true
            } catch {
                return false
            }
        }
    }

    private func cancelBoundExtensionSessionsIfChanged(
        extensionID: String,
        previousDigest: String?,
        newDigest: String
    ) throws {
        guard let previousDigest, previousDigest != newDigest else { return }
        let affected = try activeExtensionRuntimeStore.sessionIDsUsingExtension(extensionID: extensionID)
        _ = cancelRunningExtensionSessions(affected)
    }
}
