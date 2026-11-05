import XCTest
@testable import AgentBridgeApp

final class AppLocalizationTests: XCTestCase {
    func testEnglishShowsMessagesAsWritten() {
        let message = "The selected account settings could not be found."
        XCTAssertEqual(AppLocalization.display(message, language: .english), message)
    }

    func testChineseTranslatesWholeSentences() {
        XCTAssertEqual(
            AppLocalization.display("This session is already running in another window or terminal.", language: .traditionalChinese),
            "這個工作階段已在其他視窗或終端機執行。"
        )
    }

    func testChineseFillsTemplatesAndTranslatesTheirCapturedValues() {
        let shown = AppLocalization.display(
            "Loaded shared memory revision 7, with 3 earlier turn(s) (content truncated).",
            language: .traditionalChinese
        )
        XCTAssertEqual(shown, "已載入共享記憶 revision 7，包含 3 個先前回合（內容已截短）.")
    }

    func testChineseLeavesUnknownTextAlone() {
        let provider = "codex said: hello from the provider"
        XCTAssertEqual(AppLocalization.display(provider, language: .traditionalChinese), provider)
    }

    func testChineseDoesNotReplaceFragmentsInsideOtherSentences() {
        // Short English fragments must never be swapped out inside unrelated text.
        let text = "Stopped; started again, with no changes."
        XCTAssertEqual(AppLocalization.display(text, language: .traditionalChinese), text)
    }

    func testEnglishDisplayOfTextWithNoTranslationIsCheap() {
        // This used to sort and scan every table key on each call (about 50 ms).
        let text = "Some text from a provider that matches no entry at all, with a few words."
        _ = AppLocalization.display(text, language: .english)
        let started = Date()
        for _ in 0..<500 { XCTAssertEqual(AppLocalization.display(text, language: .english), text) }
        let each = Date().timeIntervalSince(started) / 500
        XCTAssertLessThan(each, 0.002, "English display of untranslated text took \(each * 1000) ms per call.")
    }

    func testStatusWordsAreStillRestyledButOnlyAsWholeStrings() {
        // Plain-word entries (status raw values) map a whole string, never text inside a sentence.
        XCTAssertEqual(AppLocalization.display("completed", language: .english), "Completed")
        let sentence = "The run completed without errors."
        XCTAssertEqual(AppLocalization.display(sentence, language: .english), sentence)
    }

    func testEnglishStillReadsOlderChineseHistory() {
        // Audit events saved before messages became English are still Chinese.
        let shown = AppLocalization.display("執行已取消。", language: .english)
        XCTAssertFalse(shown.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }, shown)
    }
}

/// Checks every entry of the Traditional Chinese table against the display logic,
/// so a new entry cannot be shadowed by a longer template and the matching code
/// cannot change without notice.
final class AppLocalizationTableTests: XCTestCase {
    private let specifier = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:lld|ld|d|f|@|s|u|x)"#
    )

    func testEveryWholeSentenceEntryTranslatesToItsOwnValue() {
        var wrong: [String] = []
        for (key, value) in AppLocalization.chineseTable where !hasPlaceholder(key) {
            let shown = AppLocalization.display(key, language: .traditionalChinese)
            if shown != value { wrong.append("\(key)\n   expected \(value)\n   got      \(shown)") }
        }
        XCTAssertTrue(wrong.isEmpty, "Entries that do not translate to their own value:\n" + wrong.sorted().joined(separator: "\n"))
    }

    func testEveryTemplateEntryRoundTripsWithSampleValues() {
        var wrong: [String] = []
        for (key, value) in AppLocalization.chineseTable where hasPlaceholder(key) {
            let sampledKey = fill(key)
            let expected = fill(value)
            let shown = AppLocalization.display(sampledKey, language: .traditionalChinese)
            if shown != expected { wrong.append("\(key)\n   expected \(expected)\n   got      \(shown)") }
        }
        XCTAssertTrue(wrong.isEmpty, "Templates another template matches first, or that do not round-trip:\n" + wrong.sorted().joined(separator: "\n"))
    }

    private func hasPlaceholder(_ text: String) -> Bool {
        specifier.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Replaces each placeholder with a distinct token, in order.
    private func fill(_ text: String) -> String {
        var result = ""
        var last = text.startIndex
        var index = 0
        for match in specifier.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound] + "S\(index)S"
            last = range.upperBound
            index += 1
        }
        return result + text[last...]
    }
}
