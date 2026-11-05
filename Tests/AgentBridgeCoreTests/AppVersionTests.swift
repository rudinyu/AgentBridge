import XCTest
@testable import AgentBridgeCore

final class AppVersionTests: XCTestCase {
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testVersionLooksLikeASemanticVersionAndTheBuildIsPositive() {
        let parts = AppVersion.marketing.split(separator: ".")
        XCTAssertEqual(parts.count, 3, AppVersion.marketing)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil }, AppVersion.marketing)
        XCTAssertGreaterThan(AppVersion.build, 0)
    }

    func testThePackagingScriptReadsTheVersionInsteadOfHardcodingOne() throws {
        let script = try String(contentsOf: packageRoot().appendingPathComponent("scripts/package-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("AppVersion.swift"))
        let hardcoded = try NSRegularExpression(pattern: #"CFBundle(?:ShortVersionString|Version)</key><string>[0-9]"#)
        XCTAssertEqual(hardcoded.numberOfMatches(in: script, range: NSRange(script.startIndex..., in: script)), 0, "The version must come from AppVersion.swift.")
    }

    func testTheCLIReportsTheSharedVersion() throws {
        let sources = packageRoot().appendingPathComponent("Sources/AgentBridgeCLI", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") }
        var text = ""
        for file in files { text += try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8) }
        XCTAssertTrue(text.contains("AppVersion.marketing"))
        let literal = try NSRegularExpression(pattern: #"version\s*=\s*"[0-9]+\.[0-9]+\.[0-9]+""#)
        XCTAssertEqual(literal.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)), 0, "The CLI must not hardcode a version.")
    }
}
