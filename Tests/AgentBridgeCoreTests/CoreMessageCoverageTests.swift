import Foundation
import XCTest

/// Core messages are written in English, and the App translates them for
/// Traditional Chinese. Many existed before that was enforced and have no
/// translation yet; those are frozen in `untranslated-core-messages.txt`. A new
/// message without a translation fails here, and a message that gets one must be
/// removed from the list, so the list only shrinks.
///
/// Regenerate the list with `UPDATE_L10N_BASELINE=1 swift test --filter CoreMessageCoverageTests`.
final class CoreMessageCoverageTests: XCTestCase {
    private static let baselinePath = "Tests/AgentBridgeCoreTests/Fixtures/untranslated-core-messages.txt"

    func testNoNewCoreMessageIsMissingItsChineseTranslation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let table = try loadTable(root.appendingPathComponent("Sources/AgentBridgeApp/Resources/zh-Hant.lproj/Localizable.strings"))
        let templates = Self.templates(from: table)
        let missing = try Self.coreMessages(in: root).filter { !Self.isTranslated($0, table: table, templates: templates) }
        let missingSet = Set(missing)

        let baselineURL = root.appendingPathComponent(Self.baselinePath)
        if ProcessInfo.processInfo.environment["UPDATE_L10N_BASELINE"] == "1" {
            try (missingSet.sorted().joined(separator: "\n") + "\n").write(to: baselineURL, atomically: true, encoding: .utf8)
            return
        }
        let baseline = Set(try String(contentsOf: baselineURL, encoding: .utf8).split(separator: "\n").map(String.init))

        let added = missingSet.subtracting(baseline).sorted()
        XCTAssertTrue(added.isEmpty, "Add these to zh-Hant.lproj (and en.lproj) so the App can translate them:\n" + added.joined(separator: "\n"))
        let nowTranslated = baseline.subtracting(missingSet).sorted()
        XCTAssertTrue(nowTranslated.isEmpty, "These now have a translation; remove them from untranslated-core-messages.txt:\n" + nowTranslated.joined(separator: "\n"))
    }

    // MARK: Finding messages

    /// Message-like string literals in Core: start with a capital letter, contain a
    /// space and end like a sentence. Interpolations become `%@`.
    private static func coreMessages(in root: URL) throws -> [String] {
        let directory = root.appendingPathComponent("Sources/AgentBridgeCore", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".swift") }.sorted()
        var messages: [String] = []
        for file in files {
            let source = try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8)
            for line in source.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                // Unified-log entries (os.Logger) are for developers reading
                // `log show`, never shown in the App, so they stay English. Any
                // receiver counts; Core has no other `.notice(` style methods.
                guard trimmed.range(of: #"\.(notice|info|debug|fault)\(""#, options: .regularExpression) == nil else { continue }
                for literal in stringLiterals(in: line) {
                    guard let first = literal.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first),
                          literal.contains(" "), literal.count >= 14,
                          let last = literal.last, ".:…?!)".contains(last) else { continue }
                    messages.append(literal)
                }
            }
        }
        return messages
    }

    /// The ordinary single-line string literals on a line, with each `\(...)` replaced by `%@`.
    private static func stringLiterals(in line: String) -> [String] {
        let characters = Array(line)
        var results: [String] = []
        var index = 0
        while index < characters.count {
            if characters[index] == "#", index + 1 < characters.count, characters[index + 1] == "\"" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "\"" && characters[index + 1] == "#") { index += 1 }
                index += 2
                continue
            }
            guard characters[index] == "\"" else { index += 1; continue }
            if index + 2 < characters.count, characters[index + 1] == "\"", characters[index + 2] == "\"" { return results }
            index += 1
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
                    current += "%@"
                    continue
                }
                if characters[index] == "\\", index + 1 < characters.count {
                    current.append(characters[index]); current.append(characters[index + 1])
                    index += 2
                    continue
                }
                current.append(characters[index])
                index += 1
            }
            index += 1
            results.append(current)
        }
        return results
    }

    // MARK: Translation lookup (mirrors AppLocalization)

    private static let specifier = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:lld|ld|d|f|@|s|u|x)"#)

    private static func templates(from table: [String: String]) -> [NSRegularExpression] {
        table.keys.compactMap { key -> NSRegularExpression? in
            let range = NSRange(key.startIndex..., in: key)
            guard specifier.firstMatch(in: key, range: range) != nil else { return nil }
            var parts: [String] = []
            var last = key.startIndex
            for match in specifier.matches(in: key, range: range) {
                guard let r = Range(match.range, in: key) else { continue }
                parts.append(String(key[last..<r.lowerBound])); last = r.upperBound
            }
            parts.append(String(key[last...]))
            return try? NSRegularExpression(pattern: "^" + parts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$", options: [.dotMatchesLineSeparators])
        }
    }

    private static func isTranslated(_ message: String, table: [String: String], templates: [NSRegularExpression]) -> Bool {
        if table[message] != nil { return true }
        // Fill the placeholders with a token so a template can match the sentence.
        var sample = message
        var index = 0
        while let r = sample.range(of: "%@") { sample.replaceSubrange(r, with: "S\(index)S"); index += 1 }
        if table[sample] != nil { return true }
        let range = NSRange(sample.startIndex..., in: sample)
        return templates.contains { $0.firstMatch(in: sample, range: range) != nil }
    }

    private func loadTable(_ url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
}
