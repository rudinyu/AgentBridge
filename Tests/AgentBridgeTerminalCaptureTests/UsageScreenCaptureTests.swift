import AgentBridgeCore
import SwiftTerm
import XCTest
import AgentBridgeTerminalCapture

final class UsageScreenCaptureTests: XCTestCase {
    private final class Sink: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    /// Laid out like Claude Code 2.1.311's /usage screen, which is taller than a small terminal.
    private let usageScreen = [
        "  Settings  Status   Config   Usage   Stats", "", "  Session", "",
        "  Total cost:            $0.0000", "",
        "  Current session", "  ██████████████▌            69% used", "  Resets 12:39pm (Asia/Taipei)", "",
        "  Current week (all models)", "  ██████▌                    31% used", "  Resets Nov 12 at 1:59pm (Asia/Taipei)", "",
        "  What's contributing to your limits usage?", "  Approximate · sessions on this machine only", "",
        "  Usage credits", "                             0% used", "  $0.00 / $100.00 spent", "", "  Esc to cancel"
    ]

    private func terminal(rows: Int, scrollback: Int = 2_000) -> Terminal {
        Terminal(delegate: Sink(), options: TerminalOptions(cols: 80, rows: rows, scrollback: scrollback))
    }

    /// Writes each space as a cursor move, as Claude Code's renderer does, so the
    /// skipped cells hold NUL rather than a space.
    private func feed(_ terminal: Terminal, _ lines: [String]) {
        terminal.feed(text: lines.map { $0.replacingOccurrences(of: " ", with: "\u{1b}[C") }.joined(separator: "\r\n"))
    }

    private func windows(_ text: String) -> [String: Double] {
        let report = ProviderUsageReportParser.parse(screenText: text, provider: .claude, accountProfileID: UUID(), accountName: "test")
        return Dictionary(uniqueKeysWithValues: report.usageWindows.compactMap { window in window.percentageUsed.map { (window.id, $0) } })
    }

    func testTheSessionLimitThatScrolledOffASmallTerminalIsStillRead() {
        let terminal = terminal(rows: 10)
        feed(terminal, ["Claude Code", "> /usage", ""])
        let firstRow = UsageScreenCapture.topRow(of: terminal)
        XCTAssertNotNil(firstRow)
        feed(terminal, usageScreen)

        let visibleOnly = UsageScreenCapture.text(of: terminal, firstRow: nil)
        XCTAssertFalse(visibleOnly.contains("Current session"), "The fixture must scroll the session limit off the screen.")
        XCTAssertNil(windows(visibleOnly)["current-session"])

        let sinceUsage = UsageScreenCapture.text(of: terminal, firstRow: firstRow)
        XCTAssertFalse(sinceUsage.contains("\u{0}"), "Cells skipped by a cursor move read as spaces.")
        XCTAssertTrue(sinceUsage.contains("  Current session"))
        XCTAssertEqual(windows(sinceUsage), ["current-session": 69, "current-week-all-models": 31])
        XCTAssertTrue(sinceUsage.hasSuffix("  Esc to cancel"), "The newest rows are kept.")
    }

    func testOnlyTheVisibleRowsAreReadOnceOldLinesHaveBeenDropped() {
        let terminal = terminal(rows: 10, scrollback: 5)
        feed(terminal, (0..<100).map { "filler \($0)" } + [""])
        XCTAssertNil(UsageScreenCapture.topRow(of: terminal))
        feed(terminal, usageScreen)
        let text = UsageScreenCapture.text(of: terminal, firstRow: 0)
        XCTAssertEqual(text.split(separator: "\n", omittingEmptySubsequences: false).count, 10)
        XCTAssertTrue(text.hasSuffix("  Esc to cancel"))
    }

    func testTheCaptureStaysWithinItsByteBoundAndKeepsTheNewestRows() {
        let terminal = terminal(rows: 40)
        let firstRow = UsageScreenCapture.topRow(of: terminal)
        feed(terminal, (0..<300).map { "row \($0) " + String(repeating: "界", count: 60) })
        let text = UsageScreenCapture.text(of: terminal, firstRow: firstRow)
        XCTAssertLessThanOrEqual(text.utf8.count, ProviderUsageReportParser.maximumScreenBytes)
        XCTAssertLessThanOrEqual(text.split(separator: "\n").count, UsageScreenCapture.maximumRows)
        XCTAssertTrue(text.contains("row 299 "))
        XCTAssertFalse(text.contains("row 0 "))
    }

    func testTheRecorderReadsFromTheScreenAtTheLastEnterInASmallTerminal() throws {
        let recorder = UsageTerminalRecorder(columns: 80, rows: 10)
        let profileID = UUID()
        func send(_ lines: [String]) {
            let text = lines.map { $0.replacingOccurrences(of: " ", with: "\u{1b}[C") }.joined(separator: "\r\n")
            recorder.recordOutput(ArraySlice(Array(text.utf8)))
        }
        // An older reading that had scrolled off before Enter was pressed.
        send(["  Current session", "  ███   99% used"] + (0..<30).map { "earlier \($0)" } + ["> /usage"])
        recorder.recordInput(ArraySlice(Array("\r".utf8)))
        send([""] + usageScreen)

        let report = try XCTUnwrap(recorder.usageReport(provider: .claude, accountProfileID: profileID, accountName: "Work"))
        XCTAssertEqual(report.accountProfileID, profileID)
        XCTAssertEqual(report.accountName, "Work")
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: report.usageWindows.compactMap { window in window.percentageUsed.map { (window.id, $0) } }),
            ["current-session": 69, "current-week-all-models": 31],
            "What scrolled off before the last Enter is not read, so the older 99% does not count."
        )
    }

    func testTheRecorderHasNoReportUntilTheScreenShowsALimit() {
        let recorder = UsageTerminalRecorder(columns: 80, rows: 24)
        recorder.recordOutput(ArraySlice(Array("Claude Code\r\n> ".utf8)))
        XCTAssertNil(recorder.usageReport(provider: .claude, accountProfileID: UUID(), accountName: "Work"))
    }

    func testAResizedRecorderStillReadsTheLimits() throws {
        let recorder = UsageTerminalRecorder(columns: 80, rows: 40)
        recorder.recordInput(ArraySlice(Array("\r".utf8)))
        recorder.resize(columns: 100, rows: 12)
        recorder.recordOutput(ArraySlice(Array(usageScreen.joined(separator: "\r\n").utf8)))
        let report = try XCTUnwrap(recorder.usageReport(provider: .claude, accountProfileID: UUID(), accountName: "Work"))
        XCTAssertEqual(report.usageWindows.first?.id, "current-session")
    }
}
