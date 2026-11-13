import Darwin
import Foundation
import XCTest
@testable import AgentBridgeCore

final class TerminalProcessDiagnosticsTests: XCTestCase {
    private func entry(_ pid: pid_t, parent: pid_t, group: pid_t, device: dev_t, name: String) -> TerminalProcessDiagnostics.Entry {
        TerminalProcessDiagnostics.Entry(
            pid: pid, parentPID: parent, processGroupID: group,
            terminalForegroundGroupID: group, terminalDevice: device, name: name
        )
    }

    func testRelatedFindsProcessesOnTheTerminalAndBelowTheFirstProcess() {
        let processes = [
            entry(10, parent: 1, group: 10, device: 7, name: "sh"),
            entry(11, parent: 10, group: 10, device: 7, name: "agentbridge"),
            entry(12, parent: 11, group: 12, device: 7, name: "codex"),
            // Left the group and the session, but still a descendant.
            entry(13, parent: 12, group: 13, device: 0, name: "codex-daemon"),
            // Restarted itself under launchd, still on the terminal.
            entry(14, parent: 1, group: 14, device: 7, name: "codex"),
            entry(20, parent: 1, group: 20, device: 9, name: "unrelated")
        ]
        let related = TerminalProcessDiagnostics.related(toTerminal: 7, rootPID: 10, in: processes)
        XCTAssertEqual(related.map(\.pid), [10, 11, 12, 13, 14])
        XCTAssertEqual(TerminalProcessDiagnostics.related(toTerminal: nil, rootPID: nil, in: processes), [])
        XCTAssertEqual(TerminalProcessDiagnostics.related(toTerminal: 0, rootPID: nil, in: processes), [])
    }

    func testTheSummaryHasIDsAndNamesOnly() {
        let summary = TerminalProcessDiagnostics.describe([entry(12, parent: 11, group: 12, device: 7, name: "codex")])
        XCTAssertEqual(summary, "12(ppid 11, pgid 12, fg 12, codex)")
        XCTAssertEqual(TerminalProcessDiagnostics.describe([]), "none")
    }

    func testTheKernelListIncludesARealChild() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate(); child.waitUntilExit() }
        let related = TerminalProcessDiagnostics.related(toTerminal: nil, rootPID: getpid())
        let found = try XCTUnwrap(related.first { $0.pid == child.processIdentifier })
        XCTAssertEqual(found.parentPID, getpid())
        XCTAssertEqual(found.name, "sleep")
    }
}
