import AppKit
import AgentBridgeCore
import Charts
import SwiftUI

extension MainWindowView {
    var usagePanel: some View {
        GroupBox(model.settings.defaultProvider == .claude && model.settings.usageMode == .api
            ? "Claude API Local Budget"
            : "Subscription Activity Estimates") {
            VStack(alignment: .leading, spacing: 8) {
                if model.settings.defaultProvider == .claude && model.settings.usageMode == .api {
                    apiUsageDashboard
                } else {
                    subscriptionUsageDashboard
                }
                if model.settings.defaultProvider == .claude {
                    apiReconciliationPanel
                }
                if let alert = model.usage.usageAlerts.first {
                    Label(model.localized(alert), systemImage: "bell.badge")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("macOS Threshold Notifications (notification permission required)", isOn: Binding(
                    get: { model.usage.usageControls.macOSNotificationsEnabled },
                    set: { model.usage.setMacOSUsageNotificationsEnabled($0) }
                ))
                .font(.caption2)
                if !model.usage.usageControlStatus.isEmpty {
                    Text(model.localized(model.usage.usageControlStatus))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    var apiReconciliationPanel: some View {
        if !model.usage.apiReconciliationCandidates.isEmpty {
            GroupBox("Manually Settle Unconfirmed Claude API Charges") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Choose a session bound to this account and enter the actual charge shown on the Anthropic bill. This only updates the local ledger and does not call the provider. Enter 0 only when the bill explicitly shows no charge. If the session still appears to be running, AgentBridge first checks for an active run lock; only an interrupted stale run is marked failed and settled. If one ledger finishes first, retry with the same amount.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: model.localized("Account: %@"), model.selectedAccountProfile?.name ?? "Claude"))
                        .font(.caption2.weight(.semibold))
                    ForEach(model.usage.apiReconciliationCandidates) { candidate in
                        Button {
                            model.usage.apiReconciliationSessionID = candidate.session.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: candidate.session.id == model.usage.apiReconciliationSessionID ? "largecircle.fill.circle" : "circle")
                                    Text(URL(fileURLWithPath: candidate.session.sourceRepositoryPath).lastPathComponent)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text(model.localized(candidate.session.status.rawValue.capitalized))
                                        .foregroundStyle(candidate.session.status == .running ? .orange : .secondary)
                                }
                                Text(candidate.session.id.uuidString.lowercased())
                                    .font(.system(size: 8, design: .monospaced)).foregroundStyle(.tertiary)
                                Text(String(format: model.localized("Unsettled reservation: US$%.2f"), candidate.reservedUSD))
                                    .font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    HStack {
                        Text("Actual Bill Amount (USD)").font(.caption2)
                        TextField("For example, 1.25", text: Bindable(model.usage).apiReconciliationActualUSD)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 105)
                        Button("Use reserved amount") { model.usage.useReservedAmountForSelectedAPICost() }
                            .controlSize(.small)
                            .disabled(model.usage.selectedAPIReconciliationCandidate == nil)
                    }
                    Text("If the bill isn't available yet, settle at the full reserved amount to resume API runs now. The amount can't be changed afterwards, and the local ledger may overstate this call's cost.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("I checked the Anthropic bill and confirm this is the actual charge for the selected session.", isOn: Bindable(model.usage).apiReconciliationConfirmed)
                        .font(.caption2)
                    Button("Settle Confirmed Charge") { model.usage.reconcileSelectedAPICost() }
                        .controlSize(.small)
                        .disabled(model.usage.selectedAPIReconciliationCandidate == nil
                            || !model.usage.apiReconciliationConfirmed)
                    if !model.usage.apiReconciliationStatus.isEmpty {
                        Text(model.localized(model.usage.apiReconciliationStatus))
                            .font(.caption2)
                            .foregroundStyle(model.usage.apiReconciliationStatus == UsageModel.reconciliationSettledMessage ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        } else if (model.usage.budgetSnapshot?.reservedUSD ?? 0) > 0 {
            Label("The monthly ledger includes older reservations that cannot be safely tied to the selected Claude account. They cannot be settled here because that could assign charges to the wrong account.", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var subscriptionUsageDashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let activity = model.usage.usageStatistics {
                HStack(spacing: 6) {
                    usageMetric("Last 5 Hours", value: "\(activity.subscriptionFiveHourRuns)", detail: "local starts")
                    usageMetric("Last 7 Days", value: "\(activity.subscriptionSevenDayRuns)", detail: "local starts")
                }
                Chart(activity.sevenDayBuckets) { bucket in
                    BarMark(
                        x: .value(model.localized("24-hour period"), bucket.index),
                        y: .value(model.localized("AgentBridge Runs"), bucket.runCount)
                    )
                    .foregroundStyle(Color.accentColor.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: activity.sevenDayBuckets.map(\.index)) { value in
                        AxisValueLabel {
                            if let index = value.as(Int.self),
                               let bucket = activity.sevenDayBuckets.first(where: { $0.index == index }) {
                                Text(model.localized(bucket.label)).font(.system(size: 8))
                            }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 82)
                Text(String(format: model.localized("Last 24 hours: %@ runs · Current AgentBridge session: %@ runs. Counts only local run attempts for the %@ account, not provider limits or total account usage; turns in interactive terminals are not read."),
                            String(activity.subscriptionDailyRuns),
                            String(activity.subscriptionSessionRuns),
                            activity.provider.rawValue.capitalized))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                tokenUsageSummary(activity)
                Text(String(format: model.localized("Local statistics updated %@"),
                            activity.generatedAt.formatted(Date.FormatStyle(time: .shortened).locale(model.appLanguage.locale))))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            } else {
                ProgressView("Loading local activity…").controlSize(.small)
            }
            Label("After you select “Send /usage,” the app makes a best-effort attempt to read the plan, usage percentages, and reset time from the visible official CLI screen. Unknown fields show “Not provided.” Verify the report against the original TUI, which should remain open.", systemImage: "terminal")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Official CLI Usage Terminal") { model.terminal.openSubscriptionUsageTUI() }
                    .controlSize(.small)
                    .disabled(model.terminal.terminalLaunch != nil || model.isSwitchingTarget)
                Text("Wait until the terminal shows an input prompt and sign-in is complete, then select “Send /usage.”")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = model.terminal.providerUsageReport,
               report.provider == model.settings.defaultProvider,
               report.accountProfileID == model.selectedProfileIDs[model.settings.defaultProvider] {
                providerUsageReportCard(report)
            }
            DisclosureGroup("AgentBridge Local Run Limits") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Leave a field empty or enter 0 for no limit. Limits count AgentBridge-managed read-only runs and interactive session launches; they do not represent provider limits or turns inside a TUI.")
                        .font(.caption2).foregroundStyle(.secondary)
                    usageLimitRow("Last 5 Hours", keyPath: \.subscriptionFiveHourRunLimit)
                    usageLimitRow("Last 24 Hours", keyPath: \.subscriptionDailyRunLimit)
                    usageLimitRow("Last 7 Days", keyPath: \.subscriptionWeeklyRunLimit)
                    usageLimitRow("Current Session", keyPath: \.subscriptionSessionRunLimit)
                    Button("Save Local Limits") { model.usage.saveUsageControlSettings() }
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }
        }
    }

    var apiUsageDashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let budget = model.usage.budgetSnapshot {
                let committed = budget.usedUSD + budget.reservedUSD
                HStack(spacing: 5) {
                    usageMetric("Used This Month", value: String(format: "$%.2f", budget.usedUSD), detail: "Local Ledger")
                    usageMetric("Reserved", value: String(format: "$%.2f", budget.reservedUSD), detail: "Unsettled Runs")
                }
                HStack {
                    Text("Available")
                    Spacer()
                    Text(String(format: "$%.2f", budget.availableUSD)).fontWeight(.semibold)
                }
                .font(.caption)
                ProgressView(value: min(1, committed / budget.monthlyLimitUSD))
                    .tint(committed >= budget.monthlyLimitUSD ? .red : .accentColor)
                if committed >= budget.monthlyLimitUSD {
                    Label("The AgentBridge local monthly limit has been reached. New API runs are blocked.", systemImage: "xmark.octagon.fill")
                        .font(.caption2).foregroundStyle(.red)
                }
                let builtInLedgerNote = model.selectedAccountProfile?.id == AccountProfile.defaultID(for: .claude)
                    ? "The built-in account uses the existing ledger, whose older records cannot be assigned to accounts. Each new account has its own ledger."
                    : "This Claude account has a separate ledger shared by the app and CLI."
                Text(String(format: model.localized("UTC %@ · Local monthly limit $%.2f. This ledger is separate from Anthropic provider credits and billing. %@"), budget.month, budget.monthlyLimitUSD, model.localized(builtInLedgerNote)))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("No local monthly API limit is set for this Claude account. API runs remain disabled until one is configured.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let activity = model.usage.usageStatistics {
                Text(String(format: model.localized("This account's API runs in the last 24 hours: %@ · current session: %@ runs"),
                            String(activity.apiDailyRuns),
                            String(activity.apiSessionRuns)))
                    .font(.caption2).foregroundStyle(.secondary)
                tokenUsageSummary(activity)
                Text(String(format: model.localized("Local statistics updated %@"),
                            activity.generatedAt.formatted(Date.FormatStyle(time: .shortened).locale(model.appLanguage.locale))))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            if let costs = model.usage.apiCostSnapshot {
                if let limit = costs.dailyLimitUSD {
                    apiDollarCapRow(
                        title: "UTC Daily API Spending Limit",
                        used: costs.dailyUsedUSD,
                        reserved: costs.dailyReservedUSD,
                        limit: limit
                    )
                }
                if let limit = costs.sessionLimitUSD {
                    apiDollarCapRow(
                        title: "API Spending Limit for This AgentBridge Session",
                        used: costs.sessionUsedUSD,
                        reserved: costs.sessionReservedUSD,
                        limit: limit
                    )
                }
                if costs.hasUnresolvedCall {
                    Label("The previous API run has an unconfirmed charge. New paid runs remain blocked.", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            DisclosureGroup("Claude API Local Controls") {
                VStack(alignment: .leading, spacing: 6) {
                    if model.selectedAccountProfile?.id == AccountProfile.defaultID(for: .claude) {
                        Text("The built-in Claude account keeps its existing US$140 AgentBridge monthly ledger, shared by the app and CLI. Older records have no account field and may span accounts, so they cannot be split retroactively.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("Local Monthly Limit (USD)")
                            TextField("For example, 25", text: Bindable(model.usage).apiMonthlyLimitInput)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.usage.usageControls.apiMonthlyLimitUSD != nil)
                                .frame(width: 95)
                        }
                        if model.usage.usageControls.apiMonthlyLimitUSD != nil {
                            Text("This account's monthly ledger already exists. Its limit cannot be changed because that could affect recorded spending.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("USD Limits (reservations are twice the per-run budget)")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    apiDollarLimitInputRow("UTC Daily USD Limit", text: Bindable(model.usage).apiDailyLimitInput)
                    apiDollarLimitInputRow("Session USD Limit", text: Bindable(model.usage).apiSessionLimitInput)
                    Text("Optional API Run Count Limits (separate from USD limits)")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    usageLimitRow("Runs in the Last 24 Hours", keyPath: \.apiDailyRunLimit)
                    usageLimitRow("Runs in the Current Session", keyPath: \.apiSessionRunLimit)
                    Toggle("Disable Future Claude API Runs for This Account", isOn: Binding(
                        get: { model.usage.usageControls.disableFutureAPI },
                        set: { value in model.usage.updateUsageControls { $0.disableFutureAPI = value } }
                    ))
                    .font(.caption2)
                    Button("Save Local Controls") { model.usage.saveUsageControlSettings() }
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }
            Text("The USD budget entered for each run is that run's limit. The local monthly budget, API run counts, and provider credits are separate limits. Disabling future API runs only blocks future AgentBridge API runs for this account; it does not switch accounts or modes.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("The Claude API local ledger does not show subscription usage. To check Claude subscription usage, switch back to official CLI subscription mode and open the usage terminal from the Subscription Activity panel.", systemImage: "terminal")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Tokens are shown in every usage mode, because they come from the CLI's own
    /// report rather than from AgentBridge's run count.
    func tokenUsageSummary(_ activity: UsageStatisticsSnapshot) -> some View {
        let locale = model.appLanguage.locale
        let count: (Int) -> String = { $0.formatted(.number.locale(locale)) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                usageMetric("Tokens, Last 5 Hours", value: count(activity.fiveHourTokens.totalTokens), detail: "reported by the CLI")
                usageMetric("Tokens, Last 7 Days", value: count(activity.sevenDayTokens.totalTokens), detail: "reported by the CLI")
            }
            Text(String(format: model.localized("Last 24 hours: %@ input, %@ cached input, %@ cache write and %@ output tokens. Current AgentBridge session: %@ tokens. Only AgentBridge runs whose CLI reported tokens are counted, not interactive terminals or other apps."),
                        count(activity.dailyTokens.inputTokens),
                        count(activity.dailyTokens.cachedInputTokens),
                        count(activity.dailyTokens.cacheWriteTokens),
                        count(activity.dailyTokens.outputTokens),
                        count(activity.sessionTokens.totalTokens)))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func usageMetric(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.localized(title)).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            Text(model.localized(detail)).font(.system(size: 8)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
    }

    func apiDollarLimitInputRow(_ title: String, text: Binding<String>) -> some View {
        HStack {
            Text(model.localized(title)).font(.caption2)
            Spacer(minLength: 4)
            TextField("No Limit", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 95)
        }
    }

    func providerUsageReportCard(_ report: ProviderUsageReport) -> some View {
        GroupBox("Official /usage Summary · Best Effort") {
            VStack(alignment: .leading, spacing: 5) {
                usageReportField("Provider", report.provider.rawValue.capitalized)
                usageReportField("Selected Account", report.accountName)
                usageReportField("Plan", report.plan ?? "Not provided", localizeValue: report.plan == nil)
                if report.usageWindows.isEmpty {
                    usageReportField("Usage Windows", "Not provided", localizeValue: true)
                } else {
                    ForEach(report.usageWindows) { window in
                        Divider()
                        Text(model.localized(window.label)).font(.caption.weight(.semibold))
                        usageReportField(
                            "Used",
                            formattedUsagePercentage(window.percentageUsed),
                            localizeValue: window.percentageUsed == nil
                        )
                        usageReportField(
                            "Reset",
                            window.resetText ?? "Not provided",
                            localizeValue: window.resetText == nil
                        )
                    }
                }
                usageReportField("Source", model.localized(report.source))
                usageReportField(
                    "Status",
                    report.status == .recognizedFields
                        ? "Some fields recognized"
                        : "No fields recognized",
                    localizeValue: true
                )
                usageReportField("Captured", report.capturedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(model.appLanguage.locale)))
                Text("Best-effort screen reading, not a stable API. Keep the official TUI visible to verify these fields.")
                    .font(.system(size: 8)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func usageReportField(_ title: String, _ value: String, localizeValue: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(model.localized(title)).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(localizeValue ? model.localized(value) : value).font(.caption2.monospacedDigit()).multilineTextAlignment(.trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func formattedUsagePercentage(_ value: Double?) -> String {
        guard let value else { return "Not provided" }
        return value.rounded() == value ? String(format: "%.0f%%", value) : String(format: "%.1f%%", value)
    }

    func apiDollarCapRow(title: String, used: Double, reserved: Double, limit: Double) -> some View {
        let committed = used + reserved
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(model.localized(title))
                Spacer(minLength: 4)
                Text(String(format: "$%.2f / $%.2f", committed, limit)).fontWeight(.semibold)
            }
            .font(.caption2)
            ProgressView(value: min(1, committed / limit))
                .tint(committed >= limit ? .red : .accentColor)
            Text(String(format: model.localized("Used $%.2f · Reserved $%.2f · Available $%.2f"), used, reserved, max(0, limit - committed)))
                .font(.system(size: 8)).foregroundStyle(.secondary)
            if committed >= limit {
                Label("The local USD limit has been reached. New API runs are blocked.", systemImage: "xmark.octagon.fill")
                    .font(.system(size: 8)).foregroundStyle(.red)
            }
        }
    }

    func usageLimitRow(_ title: String, keyPath: WritableKeyPath<UsageControlSettings, Int?>) -> some View {
        HStack {
            Text(model.localized(title)).font(.caption2)
            Spacer(minLength: 4)
            TextField("0 = No Limit", value: usageLimitBinding(keyPath), format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 75)
        }
    }

    func usageLimitBinding(_ keyPath: WritableKeyPath<UsageControlSettings, Int?>) -> Binding<Int> {
        Binding(
            get: { model.usage.usageControls[keyPath: keyPath] ?? 0 },
            set: { value in
                model.usage.updateUsageControls { settings in
                    settings[keyPath: keyPath] = value == 0 ? nil : value
                }
            }
        )
    }
}
