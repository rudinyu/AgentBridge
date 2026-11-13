import AgentBridgeCore
import SwiftUI

/// Step 1: the repository, the goal, a short summary of the settings, and every
/// other setting behind Advanced settings with its usual default.
extension AutonomousWorkflowView {
    var goalStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Git repository path", text: $model.repositoryPath)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") { model.chooseRepository() }
                    .disabled(model.hasActiveAutonomousWorkflow || model.isSwitchingTarget)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Goal")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $goal)
                    .font(.body)
                    .frame(minHeight: 90, maxHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
            settingsSummary
            DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                advancedSettings
                    .padding(.top, 8)
            } label: {
                Text("Advanced settings")
                    .font(.subheadline.weight(.semibold))
            }
            diffSharingConsent
            generateControls
        }
    }

    /// Off by default and required to generate a plan, so it sits on the main
    /// step: the user gives this consent without opening Advanced settings.
    private var diffSharingConsent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Toggle("Share the exact implementation diff with the reviewer", isOn: $shareDiffWithReviewer)
                .disabled(!implementerAndReviewerAllowMemory && !shareDiffWithReviewer)
            Text("Required. The reviewer gets the complete, unchanged diff; both profiles must allow shared memory.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settingsSummary: some View {
        let language = model.appLanguage
        let roles = WorkflowRoleSelection.allCases.map { role in
            WorkflowSettingsSummary.RoleChoice(
                role: role.coreRole,
                provider: selectedProvider(for: role),
                profileName: selectedProfile(for: role).map { model.displayName(of: $0) },
                extensionCount: role == .planner ? 0 : selectedExtensionIDs[role, default: []].count
            )
        }
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(WorkflowSettingsSummary.rolesLine(roles, language: language))
                Text(WorkflowSettingsSummary.verificationLine(mode: verificationMode, customPath: customVerificationPath, language: language))
                Text(WorkflowSettingsSummary.limitsLine(
                    concurrentAgents: maxConcurrentAgents,
                    reviewRounds: maxReviewRounds,
                    durationMinutes: maxDurationMinutes,
                    providerCalls: maxProviderInvocations,
                    language: language
                ))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                checkSelectedProfiles()
            } label: {
                if isCheckingProfiles { ProgressView().controlSize(.small) }
                else { Label("Check subscription sign-in", systemImage: "checkmark.shield") }
            }
            .disabled(isCheckingProfiles || !makeRoleBindings().isValid)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 8))
    }

    private var generateControls: some View {
        let blockers = planBlockers
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Generate plan") { generatePlan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!blockers.isEmpty)
                if model.isPreparingAutonomousRun { ProgressView().controlSize(.small) }
                Spacer()
            }
            Text("Generate plan sends one real read-only request to the planner. It does not approve or start any work.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Show why the button is unavailable next to it, so nothing has to be hunted for.
            if !blockers.isEmpty && !model.isPreparingAutonomousRun {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(blockers, id: \.message) { blocker in
                        Label(model.localized(blocker.message), systemImage: "exclamationmark.circle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if blockers.contains(where: \.isInAdvancedSettings) && !isAdvancedExpanded {
                        Button("Show advanced settings") { isAdvancedExpanded = true }
                            .buttonStyle(.link)
                            .font(.caption2)
                    }
                }
            }
        }
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Role profiles")
                .font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.flexible(minimum: 240)), GridItem(.flexible(minimum: 240))], alignment: .leading, spacing: 10) {
                ForEach(WorkflowRoleSelection.allCases) { role in
                    roleCard(role)
                }
            }
            Text("Every planning and execution role is bound to this provider and profile. Global account selection is not changed.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if hasControlExtensionSelected {
                desktopControlDeclaration
            }

            Divider()
            Text("Limits and verification")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 12) {
                Stepper(model.localizedFormat("Concurrent agents: %@", String(maxConcurrentAgents)), value: $maxConcurrentAgents, in: 1...3)
                Stepper(model.localizedFormat("Review rounds: %@", String(maxReviewRounds)), value: $maxReviewRounds, in: 1...3)
            }
            HStack(spacing: 12) {
                Stepper(model.localizedFormat("Duration: %@ min", String(maxDurationMinutes)), value: $maxDurationMinutes, in: 1...60)
                Stepper(model.localizedFormat("Provider calls: %@", String(maxProviderInvocations)), value: $maxProviderInvocations, in: 1...24)
            }
            Picker("Verification", selection: $verificationMode) {
                Text("Project .codex/ci.sh").tag(AutonomousVerificationSelection.Mode.projectCI)
                Text("No verification command").tag(AutonomousVerificationSelection.Mode.none)
                Text("Approved executable and argv").tag(AutonomousVerificationSelection.Mode.custom)
            }
            if WorkflowPlanRules.showsCustomVerificationFields(verificationMode) {
                TextField("Absolute verification executable path", text: $customVerificationPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Arguments, one per line (no shell)", text: $customVerificationArguments)
                    .textFieldStyle(.roundedBorder)
                Text("The executable and every separate argument are included in the plan digest.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()
            Text("Shared memory consent")
                .font(.subheadline.weight(.semibold))
            Toggle("Allow task outputs to pass to dependent roles", isOn: $shareDependencyOutputs)
                .disabled(!allRoleProfilesAllowMemory && !shareDependencyOutputs)
            Text("Off by default. When enabled, every source and recipient profile on each dependency must already allow shared memory.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Toggle("Save the final workflow summary to project memory", isOn: $saveRunSummaryToMemory)
                .disabled(memoryDestinationProfiles.isEmpty && !saveRunSummaryToMemory)
            if WorkflowPlanRules.showsMemoryDestination(saveRunSummaryToMemory: saveRunSummaryToMemory) {
                Picker("Memory destination profile", selection: Binding(
                    get: { memoryDestinationProfileID ?? memoryDestinationProfiles.first?.id ?? UUID() },
                    set: { memoryDestinationProfileID = $0 }
                )) {
                    ForEach(memoryDestinationProfiles) { profile in
                        Text("\(profile.provider.rawValue) · \(model.displayName(of: profile))").tag(profile.id)
                    }
                }
                .disabled(memoryDestinationProfiles.isEmpty)
                Text("Only a bound profile that already allows shared memory can receive the final summary. This is off by default and part of the reviewed plan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func roleCard(_ role: WorkflowRoleSelection) -> some View {
        let provider = selectedProvider(for: role)
        let profiles = model.accountProfiles[provider] ?? []
        let selectedProfileID = profileIDs[role] ?? model.selectedProfileIDs[provider]
        let selectedProfile = profiles.first(where: { $0.id == selectedProfileID })
        let authentication = selectedProfile.flatMap { model.authStatus[$0.id] }
        return VStack(alignment: .leading, spacing: 7) {
            Text(model.localized(role.title))
                .font(.subheadline.weight(.semibold))
            Picker("Provider", selection: Binding(
                get: { providers[role] ?? .codex },
                set: { newProvider in
                    providers[role] = newProvider
                    profileIDs[role] = model.selectedProfileIDs[newProvider]
                    reviewAcknowledged = false
                }
            )) {
                Text("Codex").tag(AgentProvider.codex)
                Text("Claude").tag(AgentProvider.claude)
            }
            .pickerStyle(.segmented)
            Picker("Account profile", selection: Binding(
                get: { selectedProfileID ?? UUID() },
                set: { newID in profileIDs[role] = newID; reviewAcknowledged = false }
            )) {
                ForEach(profiles) { profile in
                    Text(model.displayName(of: profile)).tag(profile.id)
                }
            }
            .disabled(profiles.isEmpty)
            HStack(spacing: 5) {
                Image(systemName: authentication?.confirmedSubscription == true ? "checkmark.seal.fill" : "questionmark.circle")
                Text(authentication?.confirmedSubscription == true ? "Subscription sign-in confirmed" : "Subscription sign-in not checked")
                Spacer(minLength: 0)
                Text(selectedProfile?.allowsSharedMemory == true ? "Memory sharing on" : "Memory sharing off")
                    .foregroundStyle(selectedProfile?.allowsSharedMemory == true ? Color.secondary : Color.orange)
            }
            .font(.caption2)
            .foregroundStyle(authentication?.confirmedSubscription == true ? Color.secondary : Color.orange)
            if role == .planner {
                Text("Planner extensions are disabled for the planning request.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !model.extensions.activeExtensionConfigurations.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Approved Skills / MCP for this role")
                        .font(.caption2.weight(.semibold))
                    ForEach(model.extensions.activeExtensionConfigurations) { configuration in
                        Toggle(isOn: extensionBinding(role: role, id: configuration.id)) {
                            Text("\(configuration.kind.rawValue.uppercased()) · \(configuration.name)")
                                .font(.caption2)
                        }
                        .toggleStyle(.checkbox)
                        .disabled(configuration.macControlAccessMode == .control && role != .implementer)
                    }
                    Text("The selected IDs are checked against exact project/provider/profile grants when the plan is prepared.")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.23), in: RoundedRectangle(cornerRadius: 8))
    }

    private var desktopControlDeclaration: some View {
        GroupBox("Desktop control declaration") {
            VStack(alignment: .leading, spacing: 7) {
                Text("Control access is limited to the selected target app by the MCP proxy. It does not limit screenshot pixels: each screenshot contains the whole main display, may show other windows, and is sent to the selected provider.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Describe the exact desktop actions in scope", text: $desktopControlScope, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                Toggle("I confirm desktop control is separate from Git and source repository access.", isOn: $desktopControlSeparateFromGit)
                    .font(.caption)
                Text("Only the Implementer role may use Mac Control Control mode. Observe mode remains available to other execution roles.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
        }
    }
}
