import AgentBridgeCore
import Foundation
@preconcurrency import SwiftTerm

/// A copy of the official usage TUI kept by `agentbridge usage-tui` when it runs in
/// the user's own terminal. The real terminal shows the session; this headless one
/// only replays the same output so the limits can be read from it, the way the
/// App's embedded terminal reads its own screen. Nothing it holds is written out.
public final class UsageTerminalRecorder {
    private final class Sink: TerminalDelegate {
        // The user's terminal answers the TUI's queries, so the copy must not.
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private let sink = Sink()
    private let terminal: Terminal
    private var firstRow: Int?

    public init(columns: Int, rows: Int) {
        terminal = Terminal(
            delegate: sink,
            options: TerminalOptions(cols: max(columns, 2), rows: max(rows, 2), scrollback: 1_000)
        )
    }

    public func recordOutput(_ bytes: ArraySlice<UInt8>) {
        terminal.feed(byteArray: Array(bytes))
    }

    /// Each Enter starts a new command, so its output is read from the row that was
    /// on top then, as the App does when it sends /usage.
    public func recordInput(_ bytes: ArraySlice<UInt8>) {
        if bytes.contains(13) || bytes.contains(10) {
            firstRow = UsageScreenCapture.topRow(of: terminal)
        }
    }

    public func resize(columns: Int, rows: Int) {
        terminal.resize(cols: max(columns, 2), rows: max(rows, 2))
    }

    public var screenText: String {
        UsageScreenCapture.text(of: terminal, firstRow: firstRow)
    }

    /// The report for this screen, or nil when it holds no usage percentage or reset time.
    public func usageReport(
        provider: AgentProvider,
        accountProfileID: UUID,
        accountName: String,
        capturedAt: Date = Date()
    ) -> ProviderUsageReport? {
        let report = ProviderUsageReportParser.parse(
            screenText: screenText,
            provider: provider,
            accountProfileID: accountProfileID,
            accountName: accountName,
            capturedAt: capturedAt
        )
        guard report.usageWindows.contains(where: { $0.percentageUsed != nil || $0.resetText != nil }) else { return nil }
        return report
    }
}
