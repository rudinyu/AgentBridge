import Darwin
import Foundation
import AgentBridgeCore

extension AgentBridgeCLI {
    static func showBudget(service: BridgeService) throws {
        let snapshot = try service.budgetSnapshot()
        print("Month (UTC): \(snapshot.month)")
        print(String(format: "Monthly limit: US$%.2f", snapshot.monthlyLimitUSD))
        print(String(format: "Used: US$%.2f; reserved: US$%.2f; available: US$%.2f", snapshot.usedUSD, snapshot.reservedUSD, snapshot.availableUSD))
        print("The ledger counts only AgentBridge API calls; the final bill is what the provider shows.")
    }

    static func budgetCommand(_ arguments: [String], service: BridgeService) throws {
        guard arguments.first == "reconcile" else {
            guard arguments.isEmpty else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge budget reconcile SESSION-ID --profile PROFILE-ID (--actual-usd USD | --settle-at-reserved) --confirm")
            }
            try showBudget(service: service)
            return
        }
        let settlesAtReserved = arguments.count == 6 && arguments[4] == "--settle-at-reserved"
        guard arguments.count == 7 || settlesAtReserved,
              let sessionID = UUID(uuidString: arguments[1]),
              arguments[2] == "--profile",
              let profileID = UUID(uuidString: arguments[3]),
              settlesAtReserved || arguments[4] == "--actual-usd",
              arguments.last == "--confirm" else {
            throw AgentBridgeError.invalidInput("Usage: agentbridge budget reconcile SESSION-ID --profile PROFILE-ID (--actual-usd USD | --settle-at-reserved) --confirm")
        }
        let profile = try service.accountProfile(id: profileID)
        guard profile.provider == .claude else { throw AgentBridgeError.unsupportedAPIUsage }
        let actualUSD: Double
        if settlesAtReserved {
            // The full reservation is a conservative stand-in for a bill that
            // is not available yet; it cannot be changed afterwards.
            guard let candidate = try service.unresolvedAPICalls(profileID: profileID)
                .first(where: { $0.session.id == sessionID }) else {
                throw UsageControlError.apiReconciliationNotFound(sessionID)
            }
            actualUSD = candidate.reservedUSD
        } else {
            guard let amount = Double(arguments[5]) else {
                throw AgentBridgeError.invalidInput("Usage: agentbridge budget reconcile SESSION-ID --profile PROFILE-ID (--actual-usd USD | --settle-at-reserved) --confirm")
            }
            actualUSD = amount
        }
        try service.reconcileAPIUsageFromProviderBill(
            profileID: profileID,
            sessionID: sessionID,
            actualUSD: actualUSD,
            explicitlyConfirmed: true
        )
        if settlesAtReserved {
            print(String(format: "Settled conservatively at the full reserved amount of US$%.6f; it cannot be changed to another amount afterwards.", actualUSD))
        } else {
            print(String(format: "Settled manually at the Anthropic bill amount of US$%.6f that you confirmed.", actualUSD))
        }
        print("Claude Account: \(profile.name) (\(profile.id.uuidString.lowercased()))")
        print("Sessions: \(sessionID.uuidString.lowercased())")
    }
}
