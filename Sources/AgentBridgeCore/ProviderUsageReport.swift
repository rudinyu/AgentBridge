import Foundation

/// Best-effort values recognized from the visible provider `/usage` TUI.
/// This report is a presentation model, not a stable provider API. Only these
/// parsed fields are ever saved (see `ProviderUsageReportStore`), never screen text.
public struct ProviderUsageReport: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case recognizedFields
        case noRecognizedFields
    }

    public struct Window: Codable, Equatable, Sendable, Identifiable {
        public let id: String
        public let label: String
        public let percentageUsed: Double?
        public let resetText: String?

        public init(id: String, label: String, percentageUsed: Double?, resetText: String?) {
            self.id = id
            self.label = label
            self.percentageUsed = percentageUsed
            self.resetText = resetText
        }
    }

    public let provider: AgentProvider
    public let accountProfileID: UUID
    public let accountName: String
    public let plan: String?
    public let usageWindows: [Window]
    public let capturedAt: Date
    public let source: String
    public let status: Status

    public init(
        provider: AgentProvider,
        accountProfileID: UUID,
        accountName: String,
        plan: String?,
        usageWindows: [Window],
        capturedAt: Date,
        source: String,
        status: Status
    ) {
        self.provider = provider
        self.accountProfileID = accountProfileID
        self.accountName = accountName
        self.plan = plan
        self.usageWindows = usageWindows
        self.capturedAt = capturedAt
        self.source = source
        self.status = status
    }
}

/// Parses only explicit provider usage sections from a bounded visible screen.
/// Unrecognized text and percentages remain absent; raw screen text is never
/// included in the returned report.
public enum ProviderUsageReportParser {
    public static let maximumScreenBytes = 16 * 1_024

    private struct WindowLabel {
        let id: String
        let label: String
    }

    public static func parse(
        screenText: String,
        provider: AgentProvider,
        accountProfileID: UUID,
        accountName: String,
        capturedAt: Date = Date()
    ) -> ProviderUsageReport {
        guard provider != .local else {
            return ProviderUsageReport(
                provider: .local,
                accountProfileID: accountProfileID,
                accountName: accountName,
                plan: nil,
                usageWindows: [],
                capturedAt: capturedAt,
                source: "Local model endpoint (provider plan usage is unsupported)",
                status: .noRecognizedFields
            )
        }
        let boundedText = bounded(screenText, maximumUTF8Bytes: maximumScreenBytes)
        let lines = boundedText
            .split(whereSeparator: \.isNewline)
            .map { normalizedLine(String($0)) }
            .filter { !$0.isEmpty }
        let plan = recognizedPlan(in: lines)
        let windows = recognizedWindows(in: lines, provider: provider)
        let hasRecognizedValues = plan != nil || !windows.isEmpty

        return ProviderUsageReport(
            provider: provider,
            accountProfileID: accountProfileID,
            accountName: accountName,
            plan: plan,
            usageWindows: windows,
            capturedAt: capturedAt,
            source: provider == .codex ? "Codex CLI /usage screen" : "Claude Code /usage screen",
            status: hasRecognizedValues ? .recognizedFields : .noRecognizedFields
        )
    }

    private static func bounded(_ value: String, maximumUTF8Bytes: Int) -> String {
        var result = ""
        result.reserveCapacity(min(value.utf8.count, maximumUTF8Bytes))
        var count = 0
        for character in value {
            let characterBytes = String(character).utf8.count
            guard count + characterBytes <= maximumUTF8Bytes else { break }
            result.append(character)
            count += characterBytes
        }
        return result
    }

    private static func normalizedLine(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "│┃╭╮╰╯┌┐└┘─━")))
    }

    private static func recognizedPlan(in lines: [String]) -> String? {
        for line in lines {
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let heading = line[..<separator].lowercased()
            guard heading.contains("plan") else { continue }
            let valueStart = line.index(after: separator)
            let value = line[valueStart...]
                .split(whereSeparator: { $0 == "│" || $0 == "┃" || $0 == "|" })
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "•·")))
            guard let value, !value.isEmpty, value.count <= 80,
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { continue }
            return value
        }
        return nil
    }

    /// The source of a report read from `agentbridge usage-tui` in the user's own terminal.
    public static func externalTerminalSource(for provider: AgentProvider) -> String {
        provider == .codex ? "Codex CLI /usage screen in your terminal" : "Claude Code /usage screen in your terminal"
    }

    private static func recognizedWindows(in lines: [String], provider: AgentProvider) -> [ProviderUsageReport.Window] {
        var result: [ProviderUsageReport.Window] = []
        var indicesByID: [String: Int] = [:]

        for index in lines.indices {
            guard let label = windowLabel(in: lines[index], provider: provider) else { continue }
            var recognizedPercentage = percentage(in: lines[index], isSectionHeading: true)
            var reset = resetText(in: lines[index])

            if index + 1 < lines.count {
                for nextIndex in (index + 1)..<min(lines.count, index + 4) {
                    if windowLabel(in: lines[nextIndex], provider: provider) != nil { break }
                    if recognizedPercentage == nil {
                        recognizedPercentage = percentage(in: lines[nextIndex], isSectionHeading: false)
                    }
                    if reset == nil {
                        reset = resetText(in: lines[nextIndex])
                    }
                }
            }

            if let existingIndex = indicesByID[label.id] {
                let existing = result[existingIndex]
                result[existingIndex] = ProviderUsageReport.Window(
                    id: existing.id,
                    label: existing.label,
                    percentageUsed: existing.percentageUsed ?? recognizedPercentage,
                    resetText: existing.resetText ?? reset
                )
            } else {
                indicesByID[label.id] = result.count
                result.append(ProviderUsageReport.Window(
                    id: label.id,
                    label: label.label,
                    percentageUsed: recognizedPercentage,
                    resetText: reset
                ))
            }
        }

        return result
    }

    private static func windowLabel(in line: String, provider: AgentProvider) -> WindowLabel? {
        let lower = line.lowercased()
        switch provider {
        case .codex:
            let hasUsageContext = ["usage", "limit", "window", "remaining", "reset", "quota", "allowance"]
                .contains { lower.contains($0) }
            guard hasUsageContext else { return nil }
            if containsRegex(#"(?<!\d)5(?:\s*-\s*|\s+)?(?:h|hours?)\b"#, in: lower) {
                return WindowLabel(id: "five-hour", label: "5-hour window")
            }
            if lower.contains("weekly") || containsRegex(#"(?<!\d)7(?:\s*-\s*|\s+)?days?\b"#, in: lower) {
                return WindowLabel(id: "weekly", label: "Weekly window")
            }
            return nil
        case .claude:
            if lower.contains("current session") {
                return WindowLabel(id: "current-session", label: "Current session")
            }
            if lower.contains("current week") {
                if lower.contains("sonnet") {
                    return WindowLabel(id: "current-week-sonnet", label: "Current week (Sonnet only)")
                }
                if lower.contains("all model") {
                    return WindowLabel(id: "current-week-all-models", label: "Current week (all models)")
                }
                return WindowLabel(id: "current-week", label: "Current week")
            }
            return nil
        case .local:
            return nil
        }
    }

    private static func percentage(in line: String, isSectionHeading: Bool) -> Double? {
        guard let percent = line.firstIndex(of: "%") else { return nil }
        let prefix = line[..<percent]
        let numericSuffix = prefix.split(whereSeparator: { !$0.isNumber && $0 != "." }).last
        guard let numericSuffix, let value = Double(numericSuffix), value.isFinite, (0...100).contains(value) else {
            return nil
        }
        guard isSectionHeading || qualifiesAsUsageValue(line) else { return nil }
        return percentageIsRemaining(in: line, percentPosition: percent) ? 100 - value : value
    }

    private static func percentageIsRemaining(in line: String, percentPosition: String.Index) -> Bool {
        let beforePercent = String(line[..<percentPosition].suffix(40)).lowercased()
        let afterPercent = String(line[line.index(after: percentPosition)...].prefix(40)).lowercased()
        return containsRegex(#"(?:remaining|left)\s*[:=]?\s*\d+(?:\.\d+)?\s*$"#, in: beforePercent)
            || containsRegex(#"^\s*(?:remaining|left)\b"#, in: afterPercent)
    }

    private static func qualifiesAsUsageValue(_ line: String) -> Bool {
        let lower = line.lowercased()
        return ["used", "usage", "remaining"].contains { lower.contains($0) }
            || ["█", "▓", "▒", "░", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
                .contains { line.contains($0) }
    }

    private static func containsRegex(_ pattern: String, in value: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func resetText(in line: String) -> String? {
        guard let range = line.range(of: "reset", options: [.caseInsensitive]) else { return nil }
        let text = String(line[range.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "•·│┃")))
        let value = String(text.prefix(80))
        return value.count > "reset".count ? value : nil
    }
}
