import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func extensionsCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge extensions list|import|grant|revoke ... or extensions runtime ...")
        }
        switch action {
        case "runtime":
            try await activeExtensionsCommand(Array(arguments.dropFirst()), service: service)
        case "list":
            guard arguments.count == 1 else { throw AgentBridgeError.invalidInput("Usage: agentbridge extensions list") }
            for descriptor in try service.extensionDescriptors() {
                print("\(descriptor.kind.rawValue.uppercased()) \(descriptor.id) v\(descriptor.version) — \(descriptor.name)")
                print("  requested: \(descriptor.requestedPermissions.map(\.rawValue).joined(separator: ", "))")
                if !descriptor.summary.isEmpty { print("  \(OutputRedactor.redact(descriptor.summary))") }
            }
            print("Descriptors and grants are policy metadata only; they do not activate or execute extensions.")
        case "import":
            guard arguments.count == 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge extensions import /path/to/descriptor.json") }
            let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let data = try BoundedDescriptorFileReader.read(at: url)
            let descriptor = try JSONDecoder().decode(ExtensionDescriptor.self, from: data)
            _ = try service.importExtensionDescriptor(descriptor, source: .localMetadata, sourceReference: url.path)
            print("Imported inert descriptor \(descriptor.id). No script was executed; no provider extension was activated.")
        case "grant":
            guard arguments.count >= 5,
                  let sessionID = UUID(uuidString: arguments[1]),
                  arguments.last == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions grant SESSION-ID EXTENSION-ID --permission PERMISSION [--path RELATIVE-PATH] [--host HOST] --confirm")
            }
            let extensionID = arguments[2]
            var permissions: [ExtensionPermission] = []
            var paths: [String] = []
            var hosts: [String] = []
            var index = 3
            while index < arguments.count - 1 {
                let option = arguments[index]
                index += 1
                guard index < arguments.count - 1 else { throw AgentBridgeError.invalidInput("\(option) needs a value.") }
                switch option {
                case "--permission":
                    guard let permission = ExtensionPermission(rawValue: arguments[index]) else {
                        throw AgentBridgeError.invalidInput("Unknown extension permission \(arguments[index]).")
                    }
                    permissions.append(permission)
                case "--path": paths.append(arguments[index])
                case "--host": hosts.append(arguments[index])
                default: throw AgentBridgeError.invalidInput("Unknown extensions grant option \(option).")
                }
                index += 1
            }
            let projectID = try service.extensionProjectID(sessionID: sessionID)
            let grant = try service.grantExtensionPermissions(
                extensionID: extensionID,
                projectID: projectID,
                permissions: permissions,
                allowedRelativePaths: paths,
                allowedHosts: hosts
            )
            print("Saved per-project metadata grant for \(grant.extensionID): \(grant.permissions.map(\.rawValue).joined(separator: ", ")). Extensions remain inactive and are not executed.")
        case "revoke":
            guard arguments.count == 4,
                  let sessionID = UUID(uuidString: arguments[1]),
                  arguments[3] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions revoke SESSION-ID EXTENSION-ID --confirm")
            }
            let projectID = try service.extensionProjectID(sessionID: sessionID)
            _ = try service.revokeExtensionPermissions(extensionID: arguments[2], projectID: projectID)
            print("Revoked the extension permission metadata for this project.")
        default:
            throw AgentBridgeError.invalidInput("Unknown extensions subcommand.")
        }
    }

    static func activeExtensionsCommand(_ arguments: [String], service: BridgeService) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime list|import-skill|import-mcp|test|inspect|enable|disable ...")
        }
        switch action {
        case "list":
            guard arguments.count == 1 || (arguments.count == 2 && arguments[1] == "--json") else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime list [--json]")
            }
            let configurations = try service.activeExtensionConfigurations()
            if arguments.last == "--json" {
                let values: [[String: Any]] = configurations.map { configuration in
                    [
                        "id": configuration.id,
                        "kind": configuration.kind.rawValue,
                        "name": configuration.name,
                        "version": configuration.version,
                        "summary": configuration.summary,
                        "sourceReference": configuration.sourceReference,
                        "configurationDigest": configuration.configurationDigest,
                        "skillDigest": configuration.skillDigest.map { $0 as Any } ?? NSNull(),
                        "executablePath": configuration.executablePath.map { $0 as Any } ?? NSNull(),
                        "arguments": configuration.arguments,
                        "entrypointPins": configuration.entrypointPins.map { ["path": $0.path, "digest": $0.digest] },
                        "allowedTools": configuration.allowedTools,
                        "startupTimeoutSeconds": configuration.startupTimeoutSeconds.map { $0 as Any } ?? NSNull(),
                        "toolTimeoutSeconds": configuration.toolTimeoutSeconds.map { $0 as Any } ?? NSNull(),
                        "maximumToolCallsPerRun": configuration.maximumToolCallsPerRun.map { $0 as Any } ?? NSNull(),
                        "maximumToolResponseBytes": configuration.maximumToolResponseBytes.map { $0 as Any } ?? NSNull(),
                        "maximumTotalToolResponseBytes": configuration.maximumTotalToolResponseBytes.map { $0 as Any } ?? NSNull(),
                        "macControlTargetBundleID": configuration.macControlTargetBundleID.map { $0 as Any } ?? NSNull(),
                        "macControlAccessMode": configuration.macControlAccessMode.map { $0.rawValue as Any } ?? NSNull(),
                        "macControlActionNames": configuration.macControlActionNames,
                        "screenCaptureDisclosure": configuration.screenCaptureDisclosure.map { $0 as Any } ?? NSNull()
                    ]
                }
                let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))
            } else if configurations.isEmpty {
                print("No active runtime configurations have been imported.")
            } else {
                for configuration in configurations {
                    print("\(configuration.kind.rawValue.uppercased()) \(configuration.id) v\(configuration.version) — \(configuration.name)")
                    print("  digest: \(configuration.configurationDigest)")
                    print("  source: \(configuration.sourceReference)")
                    if let skillDigest = configuration.skillDigest { print("  Skill SHA-256: \(skillDigest)") }
                    if let executablePath = configuration.executablePath {
                        print("  command: \(executablePath) \(configuration.arguments.map(\.debugDescription).joined(separator: " "))")
                        for pin in configuration.entrypointPins {
                            print("  pinned entrypoint: \(pin.path) · SHA-256 \(pin.digest)")
                        }
                        print("  allowed tools: \(configuration.allowedTools.joined(separator: ", "))")
                    }
                    if let targetBundleID = configuration.macControlTargetBundleID {
                        print("  Mac Control target: \(targetBundleID) · access: \(configuration.macControlAccessMode?.rawValue ?? "unknown")")
                        print("  actions: \(configuration.macControlActionNames.joined(separator: ", "))")
                        if let disclosure = configuration.screenCaptureDisclosure { print("  screen disclosure: \(OutputRedactor.redact(disclosure))") }
                        print("  tool budgets: \(configuration.maximumToolCallsPerRun ?? 0) calls · \(configuration.maximumToolResponseBytes ?? 0) bytes/response · \(configuration.maximumTotalToolResponseBytes ?? 0) bytes total")
                    }
                }
            }
        case "import-skill":
            guard arguments.count >= 2 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime import-skill /path/to/SKILL.md --id ID --name NAME [--version VERSION] [--summary SUMMARY]")
            }
            let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            var identifier: String?
            var name: String?
            var version = "1"
            var summary = ""
            var index = 2
            while index < arguments.count {
                let option = arguments[index]
                index += 1
                let value = try nextOptionValue(option, arguments: arguments, index: &index)
                switch option {
                case "--id": identifier = value
                case "--name": name = value
                case "--version": version = value
                case "--summary": summary = value
                default: throw AgentBridgeError.invalidInput("Unknown Skill import option \(option).")
                }
            }
            guard let identifier, let name else {
                throw AgentBridgeError.invalidInput("Skill import requires both --id and --name.")
            }
            let descriptor = try ExtensionDescriptor(id: identifier, kind: .skill, name: name, version: version, summary: summary)
            let snapshot = try service.importSkillRuntime(descriptor: descriptor, sourceReference: url.path, skillFileURL: url)
            print("Imported instructions-only Skill \(snapshot.extensionID) v\(snapshot.version).")
            print("Content SHA-256: \(snapshot.contentDigest)\nConfiguration digest: \(snapshot.configurationDigest)")
            print("Import did not run scripts, hooks, installers, or dependencies. Preview exact instructions and approve a project/provider/profile scope before enabling.")
        case "import-mcp":
            guard arguments.count == 2 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime import-mcp /path/to/mcp-runtime.json")
            }
            let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let configuration = try service.importMCPRuntimeManifest(at: url)
            print("Imported MCP \(configuration.extensionID) v\(configuration.version).")
            print("Command: \(configuration.executablePath) \(configuration.arguments.map(\.debugDescription).joined(separator: " "))")
            print("Allowed tools: \(configuration.allowedTools.joined(separator: ", "))")
            print("Configuration digest: \(configuration.configurationDigest)")
            print("The MCP server has not been started. Test Connection is an explicit action and the process runs with your macOS user permissions.")
        case "test":
            guard arguments.count == 3, arguments[2] == "--confirm-start" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime test EXTENSION-ID --confirm-start (starts the selected MCP process as your macOS user; allowlist is not an OS sandbox)")
            }
            let cancellation = CancellationFlag()
            let signalSources = makeCancellationSignalSources(cancellation)
            defer { signalSources.forEach { $0.cancel() } }
            let inspection = try await service.testMCPRuntime(extensionID: arguments[1], cancellation: cancellation)
            print("MCP initialization and tools/list succeeded for \(inspection.extensionID). No tool was called.")
            print("Configuration digest: \(inspection.configurationDigest)")
            print("Inspection digest: \(inspection.inspectionDigest)")
            print("Tools: \(inspection.toolNames.joined(separator: ", "))")
            print("\n--- Exact MCP tool definitions and input schemas ---\n\(inspection.toolDefinitionsJSON)\n--- End MCP tool definitions ---")
            for diagnostic in inspection.diagnostics { print("  \(OutputRedactor.redact(diagnostic))") }
            print("The exact allowlist must be reviewed and enabled separately for a project/provider/profile.")
        case "mac-control-status":
            let selection = try parseMacControlTargetOptions(Array(arguments.dropFirst()), requiredConfirmation: nil)
            let status = service.macControlPresetStatus(targetBundleID: selection.targetBundleID, accessMode: selection.accessMode)
            print("Mac Control preset status · target \(selection.targetBundleID) · mode \(selection.accessMode.rawValue)")
            print("\(OutputRedactor.redact(status.message))")
            if let path = status.helperPath { print("Fixed helper: \(path)") }
            if let digest = status.helperDigest { print("Helper SHA-256: \(digest)") }
            if let path = status.proxyExecutablePath { print("AgentBridge proxy: \(path)") }
            if let digest = status.proxyExecutableDigest { print("Proxy SHA-256: \(digest)") }
            print("Status detection hashes installed binaries only; it does not start the helper or access the screen.")
        case "mac-control-import":
            let selection = try parseMacControlTargetOptions(Array(arguments.dropFirst()), requiredConfirmation: "--confirm-import")
            let configuration = try service.importMacControlPreset(targetBundleID: selection.targetBundleID, accessMode: selection.accessMode)
            print("Imported typed Mac Control \(selection.accessMode.rawValue) preset \(configuration.extensionID).")
            print("Configuration digest: \(configuration.configurationDigest)")
            print("Target: \(configuration.macControlTargetBundleID ?? "unknown") · actions: \(configuration.macControlActionNames.joined(separator: ", "))")
            if let disclosure = configuration.screenCaptureDisclosure { print("Screen disclosure: \(OutputRedactor.redact(disclosure))") }
            print("Import does not start the helper, capture the screen, or enable input.")
        case "mac-control-test":
            let selection = try parseMacControlTargetOptions(Array(arguments.dropFirst()), requiredConfirmation: "--confirm-start")
            let cancellation = CancellationFlag()
            let signalSources = makeCancellationSignalSources(cancellation)
            defer { signalSources.forEach { $0.cancel() } }
            let readiness = try await service.testMacControlPermissions(targetBundleID: selection.targetBundleID, cancellation: cancellation)
            print("Mac Control permission readiness · target \(readiness.targetBundleID) · checked \(readiness.checkedAt.formatted())")
            print("Helper available: \(readiness.helperAvailable) · status tool available: \(readiness.statusToolAvailable)")
            print(OutputRedactor.redact(readiness.statusText))
            print("This status-only test never captures the screen, sends input, or requests macOS permission. Grant missing permissions manually in System Settings.")
        case "mac-control-stop":
            guard arguments.count == 4,
                  let sessionID = UUID(uuidString: arguments[1]),
                  arguments[3] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime mac-control-stop SESSION-ID EXTENSION-ID --confirm")
            }
            let cancelled = try service.stopMacControl(extensionID: arguments[2], sessionID: sessionID)
            print("Mac Control Control access was revoked for the exact project/provider/profile scope.")
            print("Cancellation requests sent to \(cancelled.count) affected provider session(s).")
        case "inspect":
            guard arguments.count == 3,
                  let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime inspect SESSION-ID EXTENSION-ID")
            }
            let review = try service.previewExtensionActivation(extensionID: arguments[2], sessionID: sessionID)
            print("Extension: \(review.extensionID)")
            print("Scope: project \(review.projectID) · \(review.provider.rawValue) profile \(review.profileID.uuidString.lowercased())")
            print("Configuration digest: \(review.configurationDigest)")
            print("Review digest: \(review.reviewedDigest)")
            if let skillDigest = review.skillDigest {
                print("Skill SHA-256: \(skillDigest)")
                print("\n--- Exact Skill instructions ---\n\(review.instructionText ?? "")\n--- End Skill instructions ---")
            }
            if let executablePath = review.executablePath {
                print("Command: \(executablePath) \(review.arguments.map(\.debugDescription).joined(separator: " "))")
                for pin in review.entrypointPins {
                    print("Pinned entrypoint: \(pin.path) · SHA-256 \(pin.digest)")
                }
                print("Allowed tools: \(review.allowedTools.joined(separator: ", "))")
                print("Tools discovered by Test Connection: \(review.inspectedTools.joined(separator: ", "))")
                if let definitions = review.toolDefinitionsJSON {
                    print("\n--- Exact MCP tool definitions and input schemas ---\n\(definitions)\n--- End MCP tool definitions ---")
                }
            }
            if let targetBundleID = review.macControlTargetBundleID {
                print("Mac Control target: \(targetBundleID) · access mode: \(review.macControlAccessMode?.rawValue ?? "unknown")")
                print("Mac Control actions: \(review.macControlActionNames.joined(separator: ", "))")
            }
            if let calls = review.maximumToolCallsPerRun,
               let response = review.maximumToolResponseBytes,
               let total = review.maximumTotalToolResponseBytes {
                print("Tool budgets: \(calls) calls · \(response) bytes/response · \(total) bytes total")
            }
            if let disclosure = review.screenCaptureDisclosure { print("Screen disclosure: \(OutputRedactor.redact(disclosure))") }
            print("\nTrust notice: \(OutputRedactor.redact(review.trustWarning))")
        case "enable":
            guard arguments.count >= 6,
                  let sessionID = UUID(uuidString: arguments[1]),
                  arguments[3] == "--digest",
                  arguments[5] == "--confirm-execution" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime enable SESSION-ID EXTENSION-ID --digest REVIEW-DIGEST --confirm-execution [--confirm-screen-capture] [--confirm-input-control]")
            }
            let consentFlags = Array(arguments.dropFirst(6))
            guard consentFlags.allSatisfy({ ["--confirm-screen-capture", "--confirm-input-control"].contains($0) }),
                  Set(consentFlags).count == consentFlags.count else {
                throw AgentBridgeError.invalidInput("Unknown or repeated Mac Control consent flag.")
            }
            let configuration = try service.activeExtensionConfigurations().first(where: { $0.id == arguments[2] })
            if configuration?.requiresScreenCaptureConsent == true,
               !consentFlags.contains("--confirm-screen-capture") {
                throw AgentBridgeError.invalidInput("Mac Control requires --confirm-screen-capture after reviewing that full-display screenshots are sent to the selected provider.")
            }
            if configuration?.requiresInputControlConsent == true,
               !consentFlags.contains("--confirm-input-control") {
                throw AgentBridgeError.invalidInput("Control mode requires the separate --confirm-input-control consent.")
            }
            let grant = try service.enableExtensionRuntime(
                extensionID: arguments[2],
                sessionID: sessionID,
                reviewedDigest: arguments[4].lowercased(),
                explicitExecutionConsent: true,
                explicitScreenCaptureConsent: consentFlags.contains("--confirm-screen-capture"),
                explicitInputControlConsent: consentFlags.contains("--confirm-input-control")
            )
            print("Enabled \(grant.extensionID) for project \(grant.projectID), \(grant.provider.rawValue) profile \(grant.profileID.uuidString.lowercased()).")
            print("Existing sessions keep their pinned extension snapshot; create a new session to use this exact approved configuration.")
        case "disable":
            guard arguments.count == 4,
                  let sessionID = UUID(uuidString: arguments[1]),
                  arguments[3] == "--confirm" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime disable SESSION-ID EXTENSION-ID --confirm")
            }
            _ = try service.disableExtensionRuntime(extensionID: arguments[2], sessionID: sessionID)
            print("Disabled the extension for the session's exact project/provider/profile scope.")
        case "status":
            guard arguments.count == 2, let sessionID = UUID(uuidString: arguments[1]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge extensions runtime status SESSION-ID")
            }
            let invocation = try service.activeExtensionsForSession(sessionID: sessionID)
            print("Scope: project \(invocation.projectID) · \(invocation.provider.rawValue) profile \(invocation.profileID.uuidString.lowercased())")
            print("Runtime fingerprint: \(invocation.fingerprint)")
            for skill in invocation.skills { print("Skill: \(skill.extensionID) · \(skill.configurationDigest)") }
            for mcp in invocation.mcpServers { print("MCP: \(mcp.extensionID) · \(mcp.configurationDigest) · tools \(mcp.allowedTools.joined(separator: ", "))") }
            if invocation.skills.isEmpty && invocation.mcpServers.isEmpty { print("No runtime extensions are active for this scope.") }
        default:
            throw AgentBridgeError.invalidInput("Unknown extensions runtime action. Use list, import-skill, import-mcp, test, inspect, enable, disable, or status.")
        }
    }

    static func parseMacControlTargetOptions(
        _ arguments: [String],
        requiredConfirmation: String?
    ) throws -> (targetBundleID: String, accessMode: MacControlAccessMode) {
        var targetBundleID: String?
        var accessMode: MacControlAccessMode = .observe
        var confirmed = false
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            switch option {
            case "--target":
                guard targetBundleID == nil else { throw AgentBridgeError.invalidInput("Only one --target may be supplied.") }
                targetBundleID = try nextOptionValue(option, arguments: arguments, index: &index)
            case "--mode":
                let value = try nextOptionValue(option, arguments: arguments, index: &index)
                guard let parsed = MacControlAccessMode(rawValue: value) else {
                    throw AgentBridgeError.invalidInput("Mac Control mode must be observe or control.")
                }
                accessMode = parsed
            case "--confirm-import", "--confirm-start":
                guard option == requiredConfirmation, !confirmed else {
                    throw AgentBridgeError.invalidInput("Unexpected or repeated confirmation flag \(option).")
                }
                confirmed = true
            default:
                throw AgentBridgeError.invalidInput("Unknown Mac Control option \(option).")
            }
        }
        guard let targetBundleID, !targetBundleID.isEmpty else {
            throw AgentBridgeError.invalidInput("Mac Control commands require --target BUNDLE-ID.")
        }
        if let requiredConfirmation, !confirmed {
            throw AgentBridgeError.invalidInput("This Mac Control action requires \(requiredConfirmation).")
        }
        return (targetBundleID, accessMode)
    }
}
