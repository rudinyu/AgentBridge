import Foundation

public enum SetupWizardStep: String, CaseIterable, Codable, Sendable {
    case welcome
    case workspace
    case commandLine
    case account
    case usage
    case review

    public var next: SetupWizardStep? {
        guard let index = Self.allCases.firstIndex(of: self), index + 1 < Self.allCases.count else { return nil }
        return Self.allCases[index + 1]
    }

    public var previous: SetupWizardStep? {
        guard let index = Self.allCases.firstIndex(of: self), index > 0 else { return nil }
        return Self.allCases[index - 1]
    }
}

public enum SetupWizardRequirement: String, CaseIterable, Sendable {
    case workspace
    case commandLine
    case subscriptionLogin
}

public struct SetupWizardReadiness: Equatable, Sendable {
    public let workspaceConfigured: Bool
    public let commandLineAvailable: Bool
    public let commandLineSettingSaved: Bool
    public let subscriptionLoginConfirmed: Bool

    public init(
        workspaceConfigured: Bool,
        commandLineAvailable: Bool,
        commandLineSettingSaved: Bool = true,
        subscriptionLoginConfirmed: Bool
    ) {
        self.workspaceConfigured = workspaceConfigured
        self.commandLineAvailable = commandLineAvailable
        self.commandLineSettingSaved = commandLineSettingSaved
        self.subscriptionLoginConfirmed = subscriptionLoginConfirmed
    }

    public var unresolvedRequirements: [SetupWizardRequirement] {
        var unresolved: [SetupWizardRequirement] = []
        if !workspaceConfigured { unresolved.append(.workspace) }
        if !commandLineAvailable || !commandLineSettingSaved { unresolved.append(.commandLine) }
        if !subscriptionLoginConfirmed { unresolved.append(.subscriptionLogin) }
        return unresolved
    }

    public var subscriptionSetupReady: Bool { unresolvedRequirements.isEmpty }
}

public enum SetupWizardFlow {
    public static func shouldPresentAutomatically(
        workspaceRootConfigured: Bool,
        hasStarted: Bool,
        hasCompleted: Bool
    ) -> Bool {
        if !workspaceRootConfigured { return true }
        return hasStarted && !hasCompleted
    }

    public static func startingStep(savedStep: SetupWizardStep?, workspaceRootConfigured: Bool) -> SetupWizardStep {
        guard let savedStep else { return .welcome }
        if !workspaceRootConfigured,
           (savedStep == .commandLine || savedStep == .account || savedStep == .usage || savedStep == .review) {
            return .workspace
        }
        return savedStep
    }

    public static func reopeningStep(
        savedStep: SetupWizardStep?,
        hasCompleted: Bool,
        workspaceRootConfigured: Bool
    ) -> SetupWizardStep {
        guard !hasCompleted else { return .welcome }
        return startingStep(savedStep: savedStep, workspaceRootConfigured: workspaceRootConfigured)
    }

    public static func canAdvance(from step: SetupWizardStep, workspaceRootConfigured: Bool) -> Bool {
        step != .workspace || workspaceRootConfigured
    }

    public static func canDismiss(workspaceRootConfigured: Bool) -> Bool {
        workspaceRootConfigured
    }
}
