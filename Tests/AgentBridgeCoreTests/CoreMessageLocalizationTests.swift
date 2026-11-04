import Foundation
import XCTest

/// Core messages are written in Traditional Chinese and translated by the
/// App's English string table, either whole or by fixed fragments around
/// interpolations. This test replays that lookup for every Chinese literal in
/// AgentBridgeCore so a new message cannot ship without an English entry.
final class CoreMessageLocalizationTests: XCTestCase {
    private static let ignoreMarker = "// l10n: content matcher"

    func testEveryChineseCoreMessageHasAnEnglishTranslation() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let englishTable = try loadTable(packageRoot.appendingPathComponent(
            "Sources/AgentBridgeApp/Resources/en.lproj/Localizable.strings"
        ))
        let chineseTable = try loadTable(packageRoot.appendingPathComponent(
            "Sources/AgentBridgeApp/Resources/zh-Hant.lproj/Localizable.strings"
        ))
        XCTAssertEqual(Set(englishTable.keys), Set(chineseTable.keys), "Both string tables must have the same keys.")

        let replacementKeys = englishTable.keys.sorted { $0.count > $1.count }
        let coreDirectory = packageRoot.appendingPathComponent("Sources/AgentBridgeCore", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: coreDirectory.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        var untranslated: [String] = []
        for file in files {
            let source = try String(contentsOf: coreDirectory.appendingPathComponent(file), encoding: .utf8)
            for (index, line) in source.components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//"), !line.contains(Self.ignoreMarker) else { continue }
                for fragments in Self.literalFragments(in: line) where fragments.contains(where: Self.containsHan) {
                    let display = Self.display(
                        fragments.joined(separator: " <value> "),
                        table: englishTable,
                        replacementKeys: replacementKeys
                    )
                    if Self.containsHan(display) {
                        untranslated.append("\(file):\(index + 1): \(fragments.joined(separator: "…"))")
                    }
                }
            }
        }
        XCTAssertTrue(
            untranslated.isEmpty,
            "Add en.lproj and zh-Hant.lproj entries for these Core messages:\n" + untranslated.joined(separator: "\n")
        )
    }

    /// Mirrors `AppLocalization.display` for English.
    private static func display(_ source: String, table: [String: String], replacementKeys: [String]) -> String {
        if let direct = table[source] { return direct }
        var translated = source
        for key in replacementKeys where source.contains(key) && !key.allSatisfy({ $0.isASCII && $0.isLetter }) {
            guard let value = table[key], value != key else { continue }
            translated = translated.replacingOccurrences(of: key, with: value)
        }
        return translated
    }

    /// Returns the fixed text of each ordinary string literal on a line, split
    /// around `\(...)` interpolations and printf specifiers. Raw strings
    /// (`#"..."#`) are regular expressions in Core and are skipped.
    private static func literalFragments(in line: String) -> [[String]] {
        let characters = Array(line)
        var results: [[String]] = []
        var index = 0
        while index < characters.count {
            if characters[index] == "#", index + 1 < characters.count, characters[index + 1] == "\"" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "\"" && characters[index + 1] == "#") { index += 1 }
                index += 2
                continue
            }
            guard characters[index] == "\"" else { index += 1; continue }
            index += 1
            var fragments: [String] = []
            var current = ""
            while index < characters.count, characters[index] != "\"" {
                if characters[index] == "\\", index + 1 < characters.count, characters[index + 1] == "(" {
                    var depth = 1
                    index += 2
                    while index < characters.count, depth > 0 {
                        if characters[index] == "(" { depth += 1 }
                        if characters[index] == ")" { depth -= 1 }
                        index += 1
                    }
                    fragments.append(current)
                    current = ""
                    continue
                }
                if characters[index] == "\\", index + 1 < characters.count {
                    current.append(characters[index])
                    current.append(characters[index + 1])
                    index += 2
                    continue
                }
                current.append(characters[index])
                index += 1
            }
            index += 1
            fragments.append(current)
            results.append(fragments.flatMap(splitFormatSpecifiers))
        }
        return results
    }

    private static func splitFormatSpecifiers(_ text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: #"%(?:\.\d+)?[@dfs]"#) else { return [text] }
        let range = NSRange(text.startIndex..., in: text)
        var parts: [String] = []
        var start = text.startIndex
        for match in expression.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            parts.append(String(text[start..<matchRange.lowerBound]))
            start = matchRange.upperBound
        }
        parts.append(String(text[start...]))
        return parts
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
