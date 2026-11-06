import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case traditionalChinese = "zh-Hant"

    static let preferenceKey = "appLanguage"

    var id: String { rawValue }

    var locale: Locale { Locale(identifier: rawValue) }

    var swiftPackageLocalization: String {
        switch self {
        case .english: "en"
        case .traditionalChinese: "zh-Hant"
        }
    }

    static var saved: AppLanguage {
        guard let rawValue = UserDefaults.standard.string(forKey: preferenceKey),
              let language = AppLanguage(rawValue: rawValue) else {
            return .english
        }
        return language
    }
}

enum AppLocalization {
    /// Messages are written in English. English display only needs the table for
    /// the few entries that restyle a value (such as capitalized status words)
    /// and for older stored text: audit events and records saved before the
    /// source language changed are still Chinese, so those entries live in
    /// `Legacy.strings` and are translated by fragment.
    private static let englishStrings = loadStrings(table: "Localizable", localization: AppLanguage.english.swiftPackageLocalization)
        .merging(loadStrings(table: "Legacy", localization: AppLanguage.english.swiftPackageLocalization)) { current, _ in current }
    private static let chineseTemplates = loadChineseTemplates()

    static func string(_ key: String, language: AppLanguage) -> String {
        guard let bundle = language == .english ? englishBundle : chineseBundle else { return key }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    private static let englishBundle = localizationDirectory(AppLanguage.english.swiftPackageLocalization).flatMap(Bundle.init(url:))
    private static let chineseBundle = localizationDirectory(AppLanguage.traditionalChinese.swiftPackageLocalization).flatMap(Bundle.init(url:))

    /// The `.lproj` folder for a localization, matched without regard to case.
    /// SwiftPM's native build system writes `zh-hant.lproj` while the newer one
    /// keeps the source spelling `zh-Hant.lproj`, and on macOS 27 Bundle lookups
    /// are case-sensitive, so asking for one spelling misses the other.
    private static func localizationDirectory(_ localization: String) -> URL? {
        guard let resources = Bundle.module.resourceURL else { return nil }
        let wanted = "\(localization).lproj".lowercased()
        let contents = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        return contents.first { $0.lastPathComponent.lowercased() == wanted }
    }

    /// Localizes dynamic status and error strings while preserving provider output and identifiers.
    static func display(_ source: String, language: AppLanguage) -> String {
        if language == .traditionalChinese { return chineseDisplay(source, depth: 0) }
        if let direct = englishStrings[source] { return direct }
        // Messages are written in English, so only older stored text, which is still
        // Chinese, needs fragments replaced. Scanning every key for text that has no
        // Chinese in it did nothing and cost tens of milliseconds a call.
        guard containsChinese(source) else { return source }
        var translated = source
        for key in legacyFragmentKeys where source.contains(key) {
            guard let value = englishStrings[key], value != key else { continue }
            translated = translated.replacingOccurrences(of: key, with: value)
        }
        return translated
    }

    /// The Chinese keys, longest first so a longer phrase is replaced before the
    /// shorter ones inside it. Built once.
    private static let legacyFragmentKeys: [String] = englishStrings.keys
        .filter(containsChinese)
        .sorted { $0.count > $1.count }

    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value)
        }
    }

    /// Whole-sentence lookup first, then whole-sentence templates such as
    /// "Loaded shared memory revision %@, with %@ earlier turn(s)%@." Values
    /// captured by a template are translated in turn. Nothing is replaced
    /// inside a sentence, so short English fragments cannot corrupt other text.
    private static func chineseDisplay(_ source: String, depth: Int) -> String {
        let direct = string(source, language: .traditionalChinese)
        if direct != source { return direct }
        guard depth < 3 else { return source }
        let range = NSRange(source.startIndex..., in: source)
        for template in chineseTemplates {
            guard let match = template.regex.firstMatch(in: source, range: range) else { continue }
            var captures: [String] = []
            for index in 1..<match.numberOfRanges {
                guard let captured = Range(match.range(at: index), in: source) else { captures.append(""); continue }
                captures.append(chineseDisplay(String(source[captured]), depth: depth + 1))
            }
            return template.fill(captures)
        }
        return source
    }

    private struct ChineseTemplate {
        let regex: NSRegularExpression
        let translationParts: [String]

        func fill(_ captures: [String]) -> String {
            var result = translationParts[0]
            for (index, part) in translationParts.dropFirst().enumerated() {
                result += (index < captures.count ? captures[index] : "") + part
            }
            return result
        }
    }

    private static let specifier = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:lld|ld|d|f|@|s|u|x)"#
    )

    private static func split(_ text: String) -> [String] {
        var parts: [String] = []
        var last = text.startIndex
        for match in specifier.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            parts.append(String(text[last..<range.lowerBound]))
            last = range.upperBound
        }
        parts.append(String(text[last...]))
        return parts
    }

    private static func loadChineseTemplates() -> [ChineseTemplate] {
        let table = loadStrings(table: "Localizable", localization: AppLanguage.traditionalChinese.swiftPackageLocalization)
        var templates: [(weight: Int, template: ChineseTemplate)] = []
        for (key, value) in table {
            let keyParts = split(key)
            guard keyParts.count > 1 else { continue }
            let pattern = "^" + keyParts.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "(.*?)") + "$"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { continue }
            templates.append((keyParts.reduce(0) { $0 + $1.count }, ChineseTemplate(regex: regex, translationParts: split(value))))
        }
        return templates.sorted { $0.weight > $1.weight }.map(\.template)
    }

    /// The Traditional Chinese table, for tests that check every entry.
    static var chineseTable: [String: String] {
        loadStrings(table: "Localizable", localization: AppLanguage.traditionalChinese.swiftPackageLocalization)
    }

    private static func loadStrings(table: String, localization: String) -> [String: String] {
        guard let directory = localizationDirectory(localization),
              let data = try? Data(contentsOf: directory.appendingPathComponent("\(table).strings")),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else {
            return [:]
        }
        return dictionary
    }
}
