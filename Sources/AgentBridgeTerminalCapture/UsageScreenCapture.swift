import AgentBridgeCore
@preconcurrency import SwiftTerm

/// What the usage report reads from the terminal. The usage screen can be taller
/// than the terminal: Claude Code 2.1.311 prints the session and weekly limits first,
/// and a small terminal scrolls them off before they can be read. So the capture
/// starts at the row that was on top when /usage was sent, and keeps the newest rows
/// within the row and byte bounds. The text is kept only in memory, for parsing.
public enum UsageScreenCapture {
    public static let maximumRows = 120

    /// The top visible row counted from the start of the scrollback, or nil once
    /// the terminal has dropped old lines and rows can no longer be counted that way.
    public static func topRow(of terminal: Terminal) -> Int? {
        // Row 0 exists only while no line has been dropped; then a scroll-invariant
        // row is simply the display offset plus the visible row.
        terminal.getScrollInvariantLine(row: 0) != nil ? terminal.getTopVisibleRow() : nil
    }

    public static func text(of terminal: Terminal, firstRow: Int?) -> String {
        let columnCount = min(max(terminal.cols, 0), 240)
        let visibleRows = max(terminal.rows, 0)
        let maximumBytes = ProviderUsageReportParser.maximumScreenBytes
        let rows: [BufferLine]
        if let top = topRow(of: terminal) {
            let end = top + visibleRows
            let start = max(min(firstRow ?? top, top), end - maximumRows, 0)
            rows = (start..<end).compactMap { terminal.getScrollInvariantLine(row: $0) }
        } else {
            rows = (0..<min(visibleRows, maximumRows)).compactMap { terminal.getLine(row: $0) }
        }

        // Newest rows first, so the byte bound drops the oldest ones.
        var lines: [String] = []
        var totalBytes = 0
        for line in rows.reversed() {
            // A TUI often moves the cursor instead of printing spaces, and SwiftTerm
            // renders the cells it skipped as NUL. They are blank on screen, so they
            // become spaces here, or "Current session" would not match its label.
            let rendered = line.translateToString(
                trimRight: true,
                startCol: 0,
                endCol: columnCount,
                skipNullCellsFollowingWide: true,
                characterProvider: { terminal.getCharacter(for: $0) }
            ).replacingOccurrences(of: "\u{0}", with: " ")
            let lineBytes = rendered.utf8.count + 1
            guard totalBytes + lineBytes <= maximumBytes else { break }
            lines.append(rendered)
            totalBytes += lineBytes
        }
        return lines.reversed().joined(separator: "\n")
    }
}
