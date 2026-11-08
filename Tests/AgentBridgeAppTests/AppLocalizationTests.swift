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

    func testTheTerminalPanelButtonsAreTranslated() {
        XCTAssertEqual(AppLocalization.display("Close terminal", language: .traditionalChinese), "關閉終端機")
        XCTAssertEqual(AppLocalization.display("End the CLI, then close", language: .traditionalChinese), "先結束 CLI 再關閉")
        XCTAssertEqual(AppLocalization.display("Cancel and close", language: .traditionalChinese), "取消並關閉")
    }

    /// A label chosen by `cond ? "A" : "B"` is never a literal the other checks
    /// see, so these went untranslated unnoticed.
    func testEveryLabelChosenByAConditionIsTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourcesURL = root.appendingPathComponent("Sources/AgentBridgeApp", isDirectory: true)
        let keys = Set(AppLocalization.chineseTable.keys)
        XCTAssertFalse(keys.isEmpty)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sourcesURL, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "No Swift files found under \(sourcesURL.path).")
        var problems: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            problems += SwiftLabelScanner.problems(in: source, keys: keys).map { "\(file.lastPathComponent): \($0)" }
        }
        XCTAssertTrue(problems.isEmpty, "Fix these, adding any new key to zh-Hant.lproj and en.lproj:\n" + problems.sorted().joined(separator: "\n"))
    }

    func testEverySheetSetsTheAppLanguage() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourcesURL = root.appendingPathComponent("Sources/AgentBridgeApp", isDirectory: true)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sourcesURL, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "No Swift files found under \(sourcesURL.path).")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(SwiftLabelScanner.sheetsWithoutLocale(in: source), 0, "\(file.lastPathComponent) has a sheet without .environment(\\.locale, ...).")
        }
    }

    func testLabelScannerFindsSheetsWithoutTheLocale() {
        XCTAssertEqual(SwiftLabelScanner.sheetsWithoutLocale(in: #".sheet(isPresented: $a) { Text("x") }"#), 1)
        XCTAssertEqual(SwiftLabelScanner.sheetsWithoutLocale(in: #".sheet(isPresented: $a) { Text("x").environment(\.locale, l) }"#), 0)
        XCTAssertEqual(SwiftLabelScanner.sheetsWithoutLocale(in: #"// .sheet(isPresented: $a) { Text("x") }"#), 0)
    }

    func testLabelScannerReportsConditionalLabels() {
        func problems(_ source: String) -> [String] {
            SwiftLabelScanner.problems(in: source, keys: ["Known", "Known %@"])
        }
        // Forms the first version of the check could not see.
        XCTAssertEqual(problems(#"model.localizedFormat(c ? "Missing %@" : "Known %@", x)"#), ["no translation: Missing %@"])
        XCTAssertEqual(problems(#"Button(c ? "Missing" : "Known") { }"#), ["no translation: Missing"])
        XCTAssertEqual(problems(#"Text(c ? "Known" : "Missing")"#), ["no translation: Missing"])
        // A parenthesis inside a string does not end the argument early.
        XCTAssertEqual(problems(#"model.localized(c ? "Retry :)" : "Other")"#), ["no translation: Other", "no translation: Retry :)"])
        // An interpolated label needs a matching template.
        XCTAssertEqual(problems(#"model.localized(c ? "Known \(n)" : "Failed \(n) times")"#), ["no translation: Failed %@ times"])
        // SwiftUI looks up a key only when the condition's branches are all literals.
        XCTAssertEqual(problems(#"Text(c ? "Known" : value)"#), ["SwiftUI shows this String as is, use model.localized: Known"])
        XCTAssertEqual(problems(#"Text(value ?? "Known")"#), ["SwiftUI shows this String as is, use model.localized: Known"])
        XCTAssertEqual(
            problems(#"Text("x \(c ? "Known" : "Known") y")"#),
            ["interpolated without model.localized: Known"]
        )
    }

    func testLabelScannerIgnoresTextThatIsNotAConditionalLabel() {
        func problems(_ source: String) -> [String] {
            SwiftLabelScanner.problems(in: source, keys: ["Known", "Known %@"])
        }
        XCTAssertEqual(problems(#"Label("Anything", systemImage: c ? "star" : "circle")"#), [])
        XCTAssertEqual(problems(#"// Text(c ? "Missing" : "Known")"#), [])
        XCTAssertEqual(problems(#"Text(verbatim: c ? "Missing" : "Known")"#), [])
        XCTAssertEqual(problems(#"Text(c ? model.localized("Known") : value)"#), [])
        XCTAssertEqual(problems(#"Text(a?.b == true ? "Known" : "Known")"#), [])
        XCTAssertEqual(problems(#"Text("x \(model.localized(c ? "Known" : "Known")) y")"#), [])
    }

    func testValueWordsDoNotRewriteTextThatIsExactlyThatWord() {
        // Agent text or an ID can be exactly one of these words.
        for word in ["yes", "no", "pending"] {
            XCTAssertEqual(AppLocalization.display(word, language: .traditionalChinese), word)
        }
        XCTAssertEqual(AppLocalization.display("pending · task-1", language: .traditionalChinese), "pending · task-1")
        XCTAssertEqual(AppLocalization.display("value.yes", language: .traditionalChinese), "有")
        XCTAssertEqual(AppLocalization.display("value.yes", language: .english), "yes")
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
