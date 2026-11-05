import AgentBridgeCore
import Foundation

/// Everything the periodic refresh reads from disk. It depends only on the
/// service and the selected session, so it can be loaded off the main thread
/// and applied on it afterwards. Each read keeps its own result so the apply
/// step reports errors exactly where the synchronous refresh did.
struct RefreshReads: Sendable {
    struct SelectedSession: Sendable {
        var events: [AuditEvent]
        var memory: SharedMemorySnapshot
        var handoffs: [ProjectMemoryHandoff]
    }

    /// The session the selected-session reads belong to: the selection, or the
    /// first session when nothing is selected yet.
    var sessionID: UUID?
    var settings: Result<BridgeSettings, Error>
    var accountProfiles: Result<[AgentProvider: [AccountProfile]], Error>
    var selectedProfileIDs: Result<[AgentProvider: UUID], Error>
    var sessions: Result<[SessionRecord], Error>
    var discussions: Result<[DiscussionRecord], Error>
    var taskRecords: Result<[ParallelTaskRecord], Error>
    var extensionDescriptors: Result<[ExtensionDescriptor], Error>
    var autonomousRuns: Result<[AutonomousRunRecord], Error>
    var activeExtensions: Result<[ActiveExtensionConfigurationSummary], Error>
    var selected: Result<SelectedSession, Error>?

    static func load(service: BridgeService, selectedSessionID: UUID?) -> RefreshReads {
        let sessions = Result { try service.sessions() }
        let sessionID = selectedSessionID ?? (try? sessions.get())?.first?.id
        let selected = sessionID.map { id in
            Result {
                SelectedSession(
                    events: try service.events(sessionID: id),
                    memory: try service.sharedMemory(sessionID: id),
                    handoffs: try service.projectMemoryHandoffs(sessionID: id)
                )
            }
        }
        return RefreshReads(
            sessionID: sessionID,
            settings: Result { try service.settings() },
            accountProfiles: Result {
                var profiles: [AgentProvider: [AccountProfile]] = [:]
                for provider in AgentProvider.allCases { profiles[provider] = try service.accountProfiles(provider: provider) }
                return profiles
            },
            selectedProfileIDs: Result {
                var ids: [AgentProvider: UUID] = [:]
                for provider in AgentProvider.allCases { ids[provider] = try service.selectedAccountProfile(provider: provider).id }
                return ids
            },
            sessions: sessions,
            discussions: Result { try service.discussions() },
            taskRecords: Result { try service.taskRecords() },
            extensionDescriptors: Result { try service.extensionDescriptors() },
            autonomousRuns: Result { try service.autonomousRuns() },
            activeExtensions: Result { try service.activeExtensionConfigurations() },
            selected: selected
        )
    }
}
