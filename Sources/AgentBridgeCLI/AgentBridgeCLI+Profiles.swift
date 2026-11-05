import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func profilesCommand(_ arguments: [String], service: BridgeService) throws {
        guard let action = arguments.first else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge profiles list|create|select|memory ...")
        }
        switch action {
        case "list":
            guard arguments.count <= 2 else { throw AgentBridgeError.invalidInput("Usage: agentbridge profiles list [codex|claude|local]") }
            let providers = arguments.count == 2 ? [try parseProvider(arguments[1])] : AgentProvider.allCases
            for provider in providers {
                let selectedID = try service.selectedAccountProfile(provider: provider).id
                for profile in try service.accountProfiles(provider: provider) {
                    let selectedMarker = profile.id == selectedID ? "*" : " "
                    let loginKind = provider == .local ? "Local modelAccount" : (profile.usesExistingLogin ? "Current local login" : "separate sign-in")
                    let memory = profile.allowsSharedMemory ? "shared memory on" : "shared memory off"
                    print("\(selectedMarker) \(profile.id.uuidString.lowercased())  \(provider.rawValue)  \(profile.name)  \(loginKind)  \(memory)")
                }
            }
        case "create":
            try profilesCreate(arguments, service: service)
        case "select":
            guard arguments.count == 4, arguments[1] == "--provider",
                  let provider = AgentProvider(rawValue: arguments[2]),
                  let profileID = UUID(uuidString: arguments[3]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge profiles select --provider codex|claude|local PROFILE-ID")
            }
            try service.selectAccountProfile(id: profileID, provider: provider)
            print("Selected \(provider.rawValue) account profile \(profileID.uuidString.lowercased()). New sessions will be bound to this account.")
        case "memory":
            guard arguments.count == 3, let profileID = UUID(uuidString: arguments[1]),
                  arguments[2] == "on" || arguments[2] == "off" else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge profiles memory PROFILE-ID on|off")
            }
            try service.setAccountSharedMemoryAllowed(id: profileID, allowed: arguments[2] == "on")
            print("Updated the account's shared-memory setting.")
        default:
            throw AgentBridgeError.invalidInput("Unknown profiles subcommand.")
        }
    }

    static func profileLoginCommand(_ arguments: [String], service: BridgeService) async throws {
        guard arguments.count == 1, let profileID = UUID(uuidString: arguments[0]) else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge profile-login PROFILE-ID")
        }
        let profile = try service.accountProfile(id: profileID)
        guard profile.provider != .local else {
            throw AgentBridgeError.invalidInput("Local model accounts do not use CLI sign-in.")
        }
        let cancellation = CancellationFlag()
        let signalSources = makeCancellationSignalSources(cancellation)
        defer { signalSources.forEach { $0.cancel() } }
        _ = try await service.loginAccountProfile(profileID: profileID, cancellation: cancellation) { message in
            FileHandle.standardError.write(Data("• \(message)\n".utf8))
        }
    }

    static func profilesCreate(_ arguments: [String], service: BridgeService) throws {
        var provider: AgentProvider?
        var name: String?
        var allowsSharedMemory = true
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--provider":
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("--provider needs codex, claude or local.") }
                provider = try parseProvider(arguments[index])
            case "--name":
                index += 1
                guard index < arguments.count else { throw AgentBridgeError.invalidInput("--name needs an account name.") }
                name = arguments[index]
            case "--share-memory":
                allowsSharedMemory = true
            default:
                throw AgentBridgeError.invalidInput("Unknown profiles create option \(arguments[index]).")
            }
            index += 1
        }
        guard let provider, let name else { throw AgentBridgeError.invalidInput("Specify --provider and --name.") }
        let profile = try service.createAccountProfile(name: name, provider: provider, allowsSharedMemory: allowsSharedMemory)
        print("Created a separate account profile: \(profile.id.uuidString.lowercased()) (\(provider.rawValue), shared memory \(allowsSharedMemory ? "on" : "off")).")
        if provider == .local {
            print("Local accounts do not use a CLI sign-in or credential folder.")
        } else {
            print("To sign in, run in an interactive Terminal: agentbridge profile-login \(profile.id.uuidString.lowercased())")
        }
    }
}
