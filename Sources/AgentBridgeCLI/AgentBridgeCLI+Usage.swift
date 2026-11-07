import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func usageCommand(_ arguments: [String], service: BridgeService) throws {
        let usage = "Usage: agentbridge usage codex|claude|local [--profile PROFILE-ID]"
        guard let first = arguments.first, let provider = AgentProvider(rawValue: first) else {
            throw AgentBridgeError.invalidInput(usage)
        }
        var profileID: UUID?
        if arguments.count == 3, arguments[1] == "--profile", let candidate = UUID(uuidString: arguments[2]) {
            profileID = candidate
        } else if arguments.count != 1 {
            throw AgentBridgeError.invalidInput(usage)
        }
        let snapshot = try service.usageStatistics(provider: provider, profileID: profileID)
        print("Account profile: \(snapshot.accountProfileID.uuidString.lowercased())")
        if provider == .local {
            print("Runs in the last 24 hours: \(snapshot.localDailyRuns)")
        } else {
            print("Subscription runs: \(snapshot.subscriptionFiveHourRuns) in 5 hours, \(snapshot.subscriptionDailyRuns) in 24 hours, \(snapshot.subscriptionSevenDayRuns) in 7 days")
            if provider == .claude { print("Claude API runs in the last 24 hours: \(snapshot.apiDailyRuns)") }
        }
        let controls = try service.usageControlSettings(provider: provider, profileID: snapshot.accountProfileID)
        for (window, tokens, limit) in [
            ("5 hours", snapshot.fiveHourTokens, controls.fiveHourTokenLimit),
            ("24 hours", snapshot.dailyTokens, controls.dailyTokenLimit),
            ("7 days", snapshot.sevenDayTokens, controls.weeklyTokenLimit)
        ] {
            let limitText = limit.map { " of a \($0) local limit" } ?? ", no local limit"
            print("Tokens in the last \(window): \(tokens.totalTokens)\(limitText) (input \(tokens.inputTokens), cached input \(tokens.cachedInputTokens), cache write \(tokens.cacheWriteTokens), output \(tokens.outputTokens))")
        }
        print("Counts only AgentBridge runs whose CLI reported tokens, not interactive terminals, other apps or provider limits.")
    }
}
