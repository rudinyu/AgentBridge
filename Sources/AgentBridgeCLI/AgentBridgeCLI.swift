import Darwin
import Foundation
import AgentBridgeCore

@main
enum AgentBridgeCLI {
    static let version = AppVersion.marketing

    static func main() async {
        do {
            try await dispatch(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("Error: \(OutputRedactor.redact(error.localizedDescription))\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func dispatch(_ arguments: [String]) async throws {
        guard let command = arguments.first else { printHelp(); return }
        if ["help", "--help", "-h"].contains(command) { printHelp(); return }
        if command == "version" || command == "--version" { print("AgentBridge \(version)"); return }
        if command == "mcp-proxy" || command == "mac-control-proxy" {
            try await internalMCPProxyCommand(Array(arguments.dropFirst()))
            return
        }
        if command == "chat" &&
            (arguments.count == 1 || (arguments.count == 2 && ["help", "--help", "-h"].contains(arguments[1]))) {
            printChatHelp()
            return
        }
        if command == "workspace" {
            try await workspaceCommand(Array(arguments.dropFirst()))
            return
        }

        _ = try RuntimePaths.requireWorkspaceRoot()
        let store = try RuntimePaths.makeAuditStore()
        let service = try BridgeService(store: store)

        switch command {
        case "doctor":
            try await doctor(service: service)
        case "settings":
            try settingsCommand(Array(arguments.dropFirst()), service: service)
        case "local":
            try await localModelCommand(Array(arguments.dropFirst()), service: service)
        case "profiles":
            try profilesCommand(Array(arguments.dropFirst()), service: service)
        case "profile-login":
            try await profileLoginCommand(Array(arguments.dropFirst()), service: service)
        case "memory":
            try memoryCommand(Array(arguments.dropFirst()), service: service)
        case "extensions":
            try await extensionsCommand(Array(arguments.dropFirst()), service: service)
        case "sessions":
            try listSessions(service: service)
        case "session":
            try await sessionCommand(Array(arguments.dropFirst()), service: service)
        case "changes":
            try await changesCommand(Array(arguments.dropFirst()), service: service)
        case "tasks":
            try tasksCommand(Array(arguments.dropFirst()), service: service)
        case "autonomous":
            try await autonomousCommand(Array(arguments.dropFirst()), service: service)
        case "run":
            try await runCommand(Array(arguments.dropFirst()), service: service)
        case "interactive":
            try await interactiveCommand(Array(arguments.dropFirst()), service: service)
        case "usage-tui":
            try await usageTUICommand(Array(arguments.dropFirst()), service: service)
        case "cancel":
            try cancelCommand(Array(arguments.dropFirst()), service: service)
        case "chat":
            try await chatCommand(Array(arguments.dropFirst()), service: service)
        case "events":
            try showEvents(Array(arguments.dropFirst()), service: service)
        case "budget":
            try budgetCommand(Array(arguments.dropFirst()), service: service)
        default:
            throw AgentBridgeError.invalidInput("Unknown command \(command). Run `agentbridge help` for usage.")
        }
    }

    /// Internal provider-facing endpoint. It accepts only a private ticket path;
    /// raw MCP commands, helper paths, tools, and target scopes never arrive in argv.
    static func internalMCPProxyCommand(_ arguments: [String]) async throws {
        guard arguments.count == 2,
              arguments[0] == "--ticket",
              arguments[1].hasPrefix("/"),
              !arguments[1].contains("\0") else {
            throw AgentBridgeError.invalidInput("This internal proxy accepts only --ticket /absolute/path/to/private-ticket.json.")
        }
        try await MCPServerProxy.run(ticketURL: URL(fileURLWithPath: arguments[1]))
    }

    static func printCLICompatibility(_ report: CLICompatibilityReport) {
        switch report.versionStatus {
        case .matchesTested:
            print("  CLI version: \(report.version ?? "?") (same as the version AgentBridge was verified with)")
        case .newerThanTested:
            print("  CLI version: \(report.version ?? "?") (newer than the verified \(report.testedVersion); if something misbehaves, please report it first)")
        case .olderThanTested:
            print("  Warning: CLI version \(report.version ?? "?") is older than the verified \(report.testedVersion); some features may not work.")
        case .unreadable:
            print("  Warning: could not read the CLI version; AgentBridge was verified with \(report.testedVersion).")
        }
        if !report.flagsWereChecked {
            print("  Warning: could not read the CLI help, so the required flags were not confirmed.")
        }
        if !report.missingFlags.isEmpty {
            print("  Warning: the CLI help does not list flags AgentBridge depends on: \(report.missingFlags.joined(separator: " ")). Related runs will fail closed; update AgentBridge or go back to the verified version.")
        }
    }

    static func doctor(service: BridgeService) async throws {
        print("AgentBridge \(version)")
        let settings = try service.settings()
        if settings.defaultProvider == .local {
            print("Current default: Local model (uses no API key or subscription usage)")
        } else {
            print("Sign-in mode: \(settings.usageMode == .subscription ? "official CLI subscription sign-in" : "Claude API (each run needs a one-run budget and confirmation)")")
        }
        for provider in AgentProvider.allCases {
            if provider == .local {
                let profile = try service.selectedAccountProfile(provider: .local)
                print("local (\(profile.name)): \(settings.localModel.backend.rawValue) · \(settings.localModel.model.isEmpty ? "no model selected yet" : settings.localModel.model)")
                print("  Endpoint: \(settings.localModel.endpoint)")
                print("  Local model status is not checked by doctor; run `agentbridge local test` explicitly.")
                continue
            }
            do {
                let executable = try RuntimeEnvironment.resolveExecutable(provider: provider, configuredPath: settings.binaryPath(for: provider))
                let profile = try service.selectedAccountProfile(provider: provider)
                let assessment = try await service.checkAuthentication(provider: provider, profileID: profile.id)
                print("\(provider.rawValue) (\(profile.name)): \(executable.path)")
                if let accountLabel = assessment.accountLabel { print("  Account: \(accountLabel)") }
                if let planName = assessment.planName { print("  Plan: \(planName)") }
                print("  \(assessment.message)")
                if let report = try await service.cliCompatibility(provider: provider, profileID: profile.id) {
                    printCLICompatibility(report)
                }
            } catch let error as AgentBridgeError {
                if case .missingExecutable = error { print("\(provider.rawValue): Could not find CLI") }
                else { print("\(provider.rawValue): \(error.localizedDescription)") }
            }
        }
        if settings.defaultProvider == .claude && settings.usageMode == .api {
            do {
                let snapshot = try service.budgetSnapshot()
                print(String(format: "Claude API monthly ledger (UTC month): used US$%.2f, reserved US$%.2f, available US$%.2f.", snapshot.usedUSD, snapshot.reservedUSD, snapshot.availableUSD))
            } catch UsageControlError.apiMonthlyLimitRequired {
                print("The selected Claude account has no local monthly API limit yet; API runs stay disabled until one is set.")
            }
        }
    }

    static func workspaceCommand(_ arguments: [String]) async throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge workspace show|set /absolute/path/to/root")
        }
        switch action {
        case "show":
            guard arguments.count == 1 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge workspace show")
            }
            let privateRoot = try RuntimePaths.applicationSupportRoot()
            if let configuration = try WorkspaceRootConfigurationStore.load(privateRootURL: privateRoot) {
                print(configuration.selectedRootURL.path)
                printSyncedRootWarning(configuration.selectedRootURL)
            } else {
                print("No workspace data root is set. Choose a folder in the App, or run: agentbridge workspace set /absolute/path/to/root")
            }
        case "set":
            guard arguments.count == 2 else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge workspace set /absolute/path/to/root")
            }
            guard arguments[1].hasPrefix("/") else {
                throw AgentBridgeError.invalidInput("Provide an absolute path, for example `agentbridge workspace set /Users/you/AgentBridgeData`.")
            }
            let requested = URL(fileURLWithPath: arguments[1], isDirectory: true)
            let privateRoot = try RuntimePaths.applicationSupportRoot()
            let selected = try await WorkspaceRootCoordinator.changeRoot(to: requested, privateRootURL: privateRoot)
            print("Workspace data root set: \(selected.path)")
            printSyncedRootWarning(selected)
        default:
            throw AgentBridgeError.invalidInput("Unknown workspace subcommand; usage: agentbridge workspace show|set /absolute/path/to/root")
        }
    }

    static func printSyncedRootWarning(_ root: URL) {
        guard let service = WorkspaceRootSyncCheck.syncedServiceName(for: root) else { return }
        FileHandle.standardError.write(Data("Note: this folder is in a \(service) synced location. Chat transcripts, shared memory and workspace copies will leave this Mac; file locks only protect this Mac, so using several Macs at once can cause conflicts. Prefer a local folder that is not synced.\n".utf8))
    }

}
