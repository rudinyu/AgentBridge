import XCTest
@testable import AgentBridgeCore

final class CLICompatibilityTests: XCTestCase {
    func testParsesVersionsFromBothCLIsAndRejectsText() {
        XCTAssertEqual(CLICompatibility.parseVersion("2.1.311 (Claude Code)"), "2.1.311")
        XCTAssertEqual(CLICompatibility.parseVersion("codex-cli 0.166.0\n"), "0.166.0")
        XCTAssertNil(CLICompatibility.parseVersion("no version here"))
    }

    func testVersionOrderingIsNumericNotLexical() {
        XCTAssertEqual(CLICompatibility.compare("2.1.311", "2.1.311"), .orderedSame)
        XCTAssertEqual(CLICompatibility.compare("2.1.9", "2.1.311"), .orderedAscending)
        XCTAssertEqual(CLICompatibility.compare("2.10.0", "2.9.99"), .orderedDescending)
    }

    func testTestedVersionWithAllFlagsNeedsNoAttention() throws {
        let profile = try XCTUnwrap(CLICompatibility.profile(for: .claude))
        let help = profile.probes[0].flags.joined(separator: "\n")
        let report = try XCTUnwrap(CLICompatibility.evaluate(
            provider: .claude, versionOutput: "2.1.311 (Claude Code)", helpOutputs: [help]
        ))
        XCTAssertEqual(report.versionStatus, .matchesTested)
        XCTAssertTrue(report.missingFlags.isEmpty)
        XCTAssertFalse(report.needsAttention)
    }

    func testNewerVersionIsInformationalButAMissingFlagIsNot() throws {
        let profile = try XCTUnwrap(CLICompatibility.profile(for: .claude))
        var flags = profile.probes[0].flags
        let removed = flags.removeFirst()
        let report = try XCTUnwrap(CLICompatibility.evaluate(
            provider: .claude, versionOutput: "9.0.0", helpOutputs: [flags.joined(separator: "\n")]
        ))
        XCTAssertEqual(report.versionStatus, .newerThanTested)
        XCTAssertEqual(report.missingFlags, [removed])
        XCTAssertTrue(report.needsAttention)

        let clean = try XCTUnwrap(CLICompatibility.evaluate(
            provider: .claude, versionOutput: "9.0.0", helpOutputs: [profile.probes[0].flags.joined(separator: "\n")]
        ))
        XCTAssertFalse(clean.needsAttention)
    }

    func testCodexChecksFlagsFromBothHelpScreens() throws {
        let profile = try XCTUnwrap(CLICompatibility.profile(for: .codex))
        let top = profile.probes[0].flags.joined(separator: " ")
        let report = try XCTUnwrap(CLICompatibility.evaluate(
            provider: .codex, versionOutput: "codex-cli 0.166.0", helpOutputs: [top, "--json"]
        ))
        XCTAssertEqual(Set(report.missingFlags), ["--ignore-user-config", "--ignore-rules"])
    }

    func testUnreadableHelpIsReportedInsteadOfPassing() throws {
        let report = try XCTUnwrap(CLICompatibility.evaluate(
            provider: .codex, versionOutput: nil, helpOutputs: [nil, nil]
        ))
        XCTAssertEqual(report.versionStatus, .unreadable)
        XCTAssertFalse(report.flagsWereChecked)
        XCTAssertTrue(report.needsAttention)
    }

    func testLocalModelsHaveNothingToCheck() {
        XCTAssertNil(CLICompatibility.profile(for: .local))
        XCTAssertNil(CLICompatibility.evaluate(provider: .local, versionOutput: nil, helpOutputs: []))
    }
}
