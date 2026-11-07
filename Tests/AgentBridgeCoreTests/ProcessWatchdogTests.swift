import XCTest
@testable import AgentBridgeCore

final class ProcessWatchdogTests: XCTestCase {
    /// A process that leads a group of its own, as `SafeProcessRunner` starts a run.
    private func startGroupLeader(seconds: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", "setpgrp(0, 0); exec '/bin/sleep', '\(seconds)'"]
        try process.run()
        // Wait until the group exists before watching it.
        let deadline = Date().addingTimeInterval(3)
        while getpgid(process.processIdentifier) != process.processIdentifier, Date() < deadline { usleep(10_000) }
        XCTAssertEqual(getpgid(process.processIdentifier), process.processIdentifier)
        return process
    }

    private func waitForExit(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var status: Int32 = 0
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid { return true }
            usleep(50_000)
        }
        return false
    }

    func testARunIsEndedWhenAgentBridgeStops() throws {
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["30"]
        try parent.run()
        let run = try startGroupLeader(seconds: "30")
        defer { if run.isRunning { run.terminate() } }
        let watchdog = try XCTUnwrap(SafeProcessRunner.startParentWatchdog(parent: parent.processIdentifier, group: run.processIdentifier))

        parent.terminate()
        parent.waitUntilExit()
        let deadline = Date().addingTimeInterval(5)
        while run.isRunning, Date() < deadline { usleep(50_000) }
        XCTAssertFalse(run.isRunning, "The run outlived the process that was enforcing its timeout.")
        XCTAssertTrue(waitForExit(watchdog, within: 5))
    }

    func testTheWatchdogLeavesOnceTheRunHasEnded() throws {
        let run = try startGroupLeader(seconds: "0.3")
        let watchdog = try XCTUnwrap(SafeProcessRunner.startParentWatchdog(parent: getpid(), group: run.processIdentifier))
        run.waitUntilExit()
        XCTAssertTrue(waitForExit(watchdog, within: 4), "The watchdog kept running after its run ended.")
    }
}
