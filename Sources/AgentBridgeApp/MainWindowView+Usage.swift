import AppKit
import AgentBridgeCore
import Charts
import SwiftUI

extension MainWindowView {
    var usagePanel: some View {
        GroupBox(model.settings.defaultProvider == .claude && model.settings.usageMode == .api
            ? "Claude API 本機預算"
            : "訂閱活動估計") {
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
                Toggle("macOS 門檻通知（需允許通知）", isOn: Binding(
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
            GroupBox("手動結算未確認的 Claude API 費用") {
                VStack(alignment: .leading, spacing: 7) {
                    Text("選擇此帳戶綁定的工作階段，並依 Anthropic 帳單輸入實際費用。這只更新本機帳本，不會呼叫 provider；只有帳單明確顯示零費用時才輸入 0。若狀態仍是執行中，系統會先確認沒有作用中的執行鎖；只有中斷後殘留的狀態才會標記失敗並結算。若一個帳本先完成，使用相同金額重試即可。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: model.localized("帳戶：%@"), model.selectedAccountProfile?.name ?? "Claude"))
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
                                Text(String(format: model.localized("未結算預留：US$%.2f"), candidate.reservedUSD))
                                    .font(.system(size: 8)).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    HStack {
                        Text("帳單實際費用（USD）").font(.caption2)
                        TextField("例如 1.25", text: Bindable(model.usage).apiReconciliationActualUSD)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 105)
                        Button("使用預留金額") { model.usage.useReservedAmountForSelectedAPICost() }
                            .controlSize(.small)
                            .disabled(model.usage.selectedAPIReconciliationCandidate == nil)
                    }
                    Text("帳單尚未顯示時，可用完整預留金額保守結算，立即恢復 API 執行。結算後不能改為其他金額，本機帳本可能高估這次費用。")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("我已對照 Anthropic provider 帳單，確認這是所選工作階段的實際費用。", isOn: Bindable(model.usage).apiReconciliationConfirmed)
                        .font(.caption2)
                    Button("結算已確認的費用") { model.usage.reconcileSelectedAPICost() }
                        .controlSize(.small)
                        .disabled(model.usage.selectedAPIReconciliationCandidate == nil
                            || !model.usage.apiReconciliationConfirmed)
                    if !model.usage.apiReconciliationStatus.isEmpty {
                        Text(model.localized(model.usage.apiReconciliationStatus))
                            .font(.caption2)
                            .foregroundStyle(model.usage.apiReconciliationStatus.contains("已手動結算") ? Color.secondary : Color.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        } else if (model.usage.budgetSnapshot?.reservedUSD ?? 0) > 0 {
            Label("月度帳本包含無法安全歸屬到目前 Claude 帳戶的舊預留；為避免把費用分配給錯誤帳戶，這些預留目前不能由此處結算。", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var subscriptionUsageDashboard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let activity = model.usage.usageStatistics {
                HStack(spacing: 6) {
                    usageMetric("近 5 小時", value: "\(activity.subscriptionFiveHourRuns)", detail: "次本機啟動")
                    usageMetric("近 7 天", value: "\(activity.subscriptionSevenDayRuns)", detail: "次本機啟動")
                }
                Chart(activity.sevenDayBuckets) { bucket in
                    BarMark(
                        x: .value(model.localized("24 小時區間"), bucket.index),
                        y: .value(model.localized("AgentBridge 啟動"), bucket.runCount)
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
                Text(String(format: model.localized("近 24 小時：%@ 次 · 目前 AgentBridge 工作階段：%@ 次。只統計此 %@ 帳戶的本機執行嘗試，不是供應商額度或帳戶總用量；互動終端回合不會被讀取。"),
                            String(activity.subscriptionDailyRuns),
                            String(activity.subscriptionSessionRuns),
                            activity.provider.rawValue.capitalized))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(String(format: model.localized("本機統計更新於 %@"),
                            activity.generatedAt.formatted(Date.FormatStyle(time: .shortened).locale(model.appLanguage.locale))))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            } else {
                ProgressView("載入本機活動記錄…").controlSize(.small)
            }
            Label("按下「送出 /usage」後，App 會從官方 CLI 可見畫面盡力辨識方案、用量百分比與重置時間；未知欄位顯示「Not provided / 未提供」。請以仍開啟的原始 TUI 核對資料卡。", systemImage: "terminal")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("開啟官方 CLI 用量終端") { model.openSubscriptionUsageTUI() }
                    .controlSize(.small)
                    .disabled(model.terminalLaunch != nil || model.isSwitchingTarget)
                Text("等終端顯示可輸入提示符並完成登入後，再按「送出 /usage」。")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let report = model.providerUsageReport,
               report.provider == model.settings.defaultProvider,
               report.accountProfileID == model.selectedProfileIDs[model.settings.defaultProvider] {
                providerUsageReportCard(report)
            }
            DisclosureGroup("AgentBridge 本機執行上限") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("留空或輸入 0 代表不限。上限計算 AgentBridge 管理的唯讀執行提示與互動工作階段啟動，不代表 provider 限額或 TUI 內的回合。")
                        .font(.caption2).foregroundStyle(.secondary)
                    usageLimitRow("近 5 小時", keyPath: \.subscriptionFiveHourRunLimit)
                    usageLimitRow("近 24 小時", keyPath: \.subscriptionDailyRunLimit)
                    usageLimitRow("近 7 天", keyPath: \.subscriptionWeeklyRunLimit)
                    usageLimitRow("目前工作階段", keyPath: \.subscriptionSessionRunLimit)
                    Button("儲存本機上限") { model.usage.saveUsageControlSettings() }
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
                    usageMetric("本月已用", value: String(format: "$%.2f", budget.usedUSD), detail: "本機帳本")
                    usageMetric("已保留", value: String(format: "$%.2f", budget.reservedUSD), detail: "未結算執行")
                }
                HStack {
                    Text("可用")
                    Spacer()
                    Text(String(format: "$%.2f", budget.availableUSD)).fontWeight(.semibold)
                }
                .font(.caption)
                ProgressView(value: min(1, committed / budget.monthlyLimitUSD))
                    .tint(committed >= budget.monthlyLimitUSD ? .red : .accentColor)
                if committed >= budget.monthlyLimitUSD {
                    Label("已達 AgentBridge 本機月上限；新的 API 執行會被阻擋。", systemImage: "xmark.octagon.fill")
                        .font(.caption2).foregroundStyle(.red)
                }
                let builtInLedgerNote = model.selectedAccountProfile?.id == AccountProfile.defaultID(for: .claude)
                    ? "內建帳戶沿用舊版帳本；舊紀錄的帳戶歸屬無法還原。新帳戶各自使用獨立帳本。"
                    : "此 Claude 帳戶使用獨立帳本；App 與 CLI 共用。"
                Text(String(format: model.localized("UTC %@ · 本機月上限 $%.2f。此帳本與 Anthropic provider credit/帳單分開。%@"), budget.month, budget.monthlyLimitUSD, model.localized(builtInLedgerNote)))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("此 Claude 帳戶尚未設定本機 API 月上限；完成設定前不會啟用 API 執行。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let activity = model.usage.usageStatistics {
                Text(String(format: model.localized("此帳戶近 24 小時 API 啟動：%@ 次 · 目前工作階段：%@ 次"),
                            String(activity.apiDailyRuns),
                            String(activity.apiSessionRuns)))
                    .font(.caption2).foregroundStyle(.secondary)
                Text(String(format: model.localized("本機統計更新於 %@"),
                            activity.generatedAt.formatted(Date.FormatStyle(time: .shortened).locale(model.appLanguage.locale))))
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            if let costs = model.usage.apiCostSnapshot {
                if let limit = costs.dailyLimitUSD {
                    apiDollarCapRow(
                        title: "UTC 今日 API 費用上限",
                        used: costs.dailyUsedUSD,
                        reserved: costs.dailyReservedUSD,
                        limit: limit
                    )
                }
                if let limit = costs.sessionLimitUSD {
                    apiDollarCapRow(
                        title: "目前 AgentBridge 工作階段 API 費用上限",
                        used: costs.sessionUsedUSD,
                        reserved: costs.sessionReservedUSD,
                        limit: limit
                    )
                }
                if costs.hasUnresolvedCall {
                    Label("上一筆 API 執行費用尚未確認；新的付費執行會保持封鎖。", systemImage: "lock.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }
            DisclosureGroup("Claude API 本機控制") {
                VStack(alignment: .leading, spacing: 6) {
                    if model.selectedAccountProfile?.id == AccountProfile.defaultID(for: .claude) {
                        Text("內建 Claude 帳戶沿用既有 AgentBridge 本機 US$140 月帳本；App 與 CLI 共用。舊版帳本沒有帳戶欄位，過去紀錄可能跨帳戶，無法回溯拆分。")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Text("本機月上限（USD）")
                            TextField("例如 25", text: Bindable(model.usage).apiMonthlyLimitInput)
                                .textFieldStyle(.roundedBorder)
                                .disabled(model.usage.usageControls.apiMonthlyLimitUSD != nil)
                                .frame(width: 95)
                        }
                        if model.usage.usageControls.apiMonthlyLimitUSD != nil {
                            Text("此帳戶月帳本已建立；為保留既有支出，月上限不能再變更。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("美元上限（預留金額按單次預算的兩倍計算）")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    apiDollarLimitInputRow("UTC 每日 USD 上限", text: Bindable(model.usage).apiDailyLimitInput)
                    apiDollarLimitInputRow("工作階段 USD 上限", text: Bindable(model.usage).apiSessionLimitInput)
                    Text("選用 API 執行次數上限（獨立於美元上限）")
                        .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    usageLimitRow("近 24 小時執行次數", keyPath: \.apiDailyRunLimit)
                    usageLimitRow("目前工作階段執行次數", keyPath: \.apiSessionRunLimit)
                    Toggle("停用此帳戶後續 Claude API 執行", isOn: Binding(
                        get: { model.usage.usageControls.disableFutureAPI },
                        set: { value in model.usage.updateUsageControls { $0.disableFutureAPI = value } }
                    ))
                    .font(.caption2)
                    Button("儲存本機控制") { model.usage.saveUsageControlSettings() }
                        .controlSize(.small)
                }
                .padding(.top, 4)
            }
            Text("每次填寫的 USD 預算是本次 API 執行上限；本機月預算、API 執行次數及 provider credit 是不同限制。停用後續 API 只會阻止此帳戶未來的 AgentBridge API 執行，不會切換帳戶或模式。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label("Claude API 本機帳本不代表訂閱用量；若要查看 Claude 訂閱方案用量，請切回官方 CLI 訂閱登入模式，再由訂閱活動面板開啟用量終端。", systemImage: "terminal")
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
            TextField("不限", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 95)
        }
    }

    func providerUsageReportCard(_ report: ProviderUsageReport) -> some View {
        GroupBox("官方 /usage 摘要 · Best-effort") {
            VStack(alignment: .leading, spacing: 5) {
                usageReportField("Provider / 供應商", report.provider.rawValue.capitalized)
                usageReportField("Selected account / 選取帳戶", report.accountName)
                usageReportField("Plan / 方案", report.plan ?? "Not provided / 未提供", localizeValue: report.plan == nil)
                if report.usageWindows.isEmpty {
                    usageReportField("Usage windows / 用量視窗", "Not provided / 未提供", localizeValue: true)
                } else {
                    ForEach(report.usageWindows) { window in
                        Divider()
                        Text(model.localized(window.label)).font(.caption.weight(.semibold))
                        usageReportField(
                            "Used / 已使用",
                            formattedUsagePercentage(window.percentageUsed),
                            localizeValue: window.percentageUsed == nil
                        )
                        usageReportField(
                            "Reset / 重置",
                            window.resetText ?? "Not provided / 未提供",
                            localizeValue: window.resetText == nil
                        )
                    }
                }
                usageReportField("Source / 來源", model.localized(report.source))
                usageReportField(
                    "Status / 狀態",
                    report.status == .recognizedFields
                        ? "Some fields recognized / 已辨識部分欄位"
                        : "No recognized fields / 未辨識到欄位",
                    localizeValue: true
                )
                usageReportField("Captured / 擷取時間", report.capturedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(model.appLanguage.locale)))
                Text("Best-effort screen reading, not a stable API. Keep the official TUI visible to verify these fields. / 依畫面盡力辨識，非穩定 API；請保留官方 TUI 畫面核對。")
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
        guard let value else { return "Not provided / 未提供" }
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
            Text(String(format: model.localized("已用 $%.2f · 保留 $%.2f · 可用 $%.2f"), used, reserved, max(0, limit - committed)))
                .font(.system(size: 8)).foregroundStyle(.secondary)
            if committed >= limit {
                Label("已達本機 USD 上限；新的 API 執行會被阻擋。", systemImage: "xmark.octagon.fill")
                    .font(.system(size: 8)).foregroundStyle(.red)
            }
        }
    }

    func usageLimitRow(_ title: String, keyPath: WritableKeyPath<UsageControlSettings, Int?>) -> some View {
        HStack {
            Text(model.localized(title)).font(.caption2)
            Spacer(minLength: 4)
            TextField("0 = 不限", value: usageLimitBinding(keyPath), format: .number)
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
