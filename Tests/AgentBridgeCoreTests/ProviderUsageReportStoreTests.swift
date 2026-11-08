import Foundation
import XCTest
@testable import AgentBridgeCore

final class ProviderUsageReportStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentBridge-UsageReports-\(UUID().uuidString.lowercased())", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func report(profileID: UUID, percentage: Double = 69, capturedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> ProviderUsageReport {
        ProviderUsageReport(
            provider: .claude,
            accountProfileID: profileID,
            accountName: "Work",
            plan: nil,
            usageWindows: [
                .init(id: "current-session", label: "Current session", percentageUsed: percentage, resetText: "Resets 12:39pm"),
                .init(id: "current-week-all-models", label: "Current week (all models)", percentageUsed: 31, resetText: nil)
            ],
            capturedAt: capturedAt,
            source: ProviderUsageReportParser.externalTerminalSource(for: .claude),
            status: .recognizedFields
        )
    }

    func testTheLatestReportIsKeptPerAccountInAPrivateFile() throws {
        let store = try ProviderUsageReportStore(rootURL: root)
        let profileID = UUID()
        let otherProfileID = UUID()
        try store.save(report(profileID: profileID, percentage: 50))
        try store.save(report(profileID: profileID, percentage: 69))
        try store.save(report(profileID: otherProfileID, percentage: 10))

        XCTAssertEqual(store.latest(provider: .claude, accountProfileID: profileID), report(profileID: profileID, percentage: 69))
        XCTAssertEqual(store.latest(provider: .claude, accountProfileID: otherProfileID)?.usageWindows.first?.percentageUsed, 10)
        XCTAssertNil(store.latest(provider: .codex, accountProfileID: profileID))

        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(files.sorted(), ["claude-\(otherProfileID.uuidString.lowercased()).json", "claude-\(profileID.uuidString.lowercased()).json"].sorted())
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(file).path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testAReportWithoutRecognizedLimitsIsNotSaved() throws {
        let store = try ProviderUsageReportStore(rootURL: root)
        let empty = ProviderUsageReport(
            provider: .claude, accountProfileID: UUID(), accountName: "Work", plan: nil, usageWindows: [],
            capturedAt: Date(), source: "Claude Code /usage screen", status: .noRecognizedFields
        )
        XCTAssertThrowsError(try store.save(empty))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testAFileThatDoesNotMatchItsAccountOrBoundsIsIgnored() throws {
        let store = try ProviderUsageReportStore(rootURL: root)
        let profileID = UUID()
        let otherProfileID = UUID()
        try store.save(report(profileID: otherProfileID))
        let fileURL = root.appendingPathComponent("claude-\(profileID.uuidString.lowercased()).json")
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("claude-\(otherProfileID.uuidString.lowercased()).json"),
            to: fileURL
        )
        XCTAssertNil(store.latest(provider: .claude, accountProfileID: profileID), "A report filed under another account is not shown.")

        try FileManager.default.removeItem(at: fileURL)
        var tampered = try JSONSerialization.jsonObject(with: JSONEncoder.iso8601.encode(report(profileID: profileID))) as! [String: Any]
        tampered["accountName"] = "line\nbreak"
        try JSONSerialization.data(withJSONObject: tampered).write(to: fileURL)
        XCTAssertNil(store.latest(provider: .claude, accountProfileID: profileID))

        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createSymbolicLink(
            at: fileURL,
            withDestinationURL: root.appendingPathComponent("claude-\(otherProfileID.uuidString.lowercased()).json")
        )
        XCTAssertNil(store.latest(provider: .claude, accountProfileID: profileID), "A link is not followed.")
        XCTAssertThrowsError(try store.save(report(profileID: profileID)), "Nor is it replaced.")
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
