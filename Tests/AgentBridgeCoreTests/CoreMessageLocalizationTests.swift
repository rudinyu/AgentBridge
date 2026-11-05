import Foundation
import XCTest

/// Core messages are written in English. The App shows them as written for
/// English and translates them for Traditional Chinese, either whole or through
/// whole-sentence templates such as "Loaded %@ turn(s)". These tests keep the
/// source language and the two string tables consistent.
final class CoreMessageLocalizationTests: XCTestCase {
    /// Chinese text that Core must keep because it matches user content.
    private static let contentMatcherFiles: Set<String> = ["ContextCompression.swift"]

    func testCoreSourcesContainNoChineseMessages() throws {
        let coreDirectory = packageRoot().appendingPathComponent("Sources/AgentBridgeCore", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: coreDirectory.path)
            .filter { $0.hasSuffix(".swift") && !Self.contentMatcherFiles.contains($0) }.sorted()
        var offenders: [String] = []
        for file in files {
            let source = try String(contentsOf: coreDirectory.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() where Self.containsHan(line) {
                offenders.append("\(file):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "Write Core messages in English and add the Chinese text to zh-Hant.lproj:\n" + offenders.joined(separator: "\n")
        )
    }

    func testStringTablesShareKeysAndTemplatesKeepTheirPlaceholders() throws {
        let resources = packageRoot().appendingPathComponent("Sources/AgentBridgeApp/Resources", isDirectory: true)
        let english = try loadTable(resources.appendingPathComponent("en.lproj/Localizable.strings"))
        let chinese = try loadTable(resources.appendingPathComponent("zh-Hant.lproj/Localizable.strings"))
        XCTAssertEqual(Set(english.keys), Set(chinese.keys), "Both string tables must have the same keys.")

        let specifier = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:lld|ld|d|f|@|s|u|x)"#)
        func placeholderCount(_ text: String) -> Int {
            specifier.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
        }
        var mismatches: [String] = []
        for (key, value) in chinese where placeholderCount(key) != placeholderCount(value) {
            mismatches.append(key)
        }
        XCTAssertTrue(
            mismatches.isEmpty,
            "A translation must keep the same number of placeholders as its key:\n" + mismatches.sorted().joined(separator: "\n")
        )
    }

    func testLegacyTableTranslatesOnlyChineseKeys() throws {
        let resources = packageRoot().appendingPathComponent("Sources/AgentBridgeApp/Resources", isDirectory: true)
        let legacy = try loadTable(resources.appendingPathComponent("en.lproj/Legacy.strings"))
        XCTAssertFalse(legacy.isEmpty)
        let english = legacy.filter { $0.key.unicodeScalars.allSatisfy(\.isASCII) }
        XCTAssertTrue(english.isEmpty, "Legacy.strings is only for text saved before messages became English.")
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private func loadTable(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )
    }
}
