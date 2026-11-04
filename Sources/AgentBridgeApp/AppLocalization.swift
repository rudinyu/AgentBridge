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
        case .traditionalChinese: "zh-hant"
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
    private static let englishStrings = loadEnglishStrings()

    static func string(_ key: String, language: AppLanguage) -> String {
        guard let path = Bundle.module.path(forResource: language.swiftPackageLocalization, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    /// Localizes dynamic status and error strings while preserving provider output and identifiers.
    static func display(_ source: String, language: AppLanguage) -> String {
        if language == .traditionalChinese { return string(source, language: language) }
        if let direct = englishStrings[source] { return direct }
        var translated = source
        // Plain-word keys such as status raw values only match whole strings;
        // replacing them inside a sentence would corrupt translated text.
        for key in englishStrings.keys.sorted(by: { $0.count > $1.count })
        where source.contains(key) && !key.allSatisfy({ $0.isASCII && $0.isLetter }) {
            guard let value = englishStrings[key], value != key else { continue }
            translated = translated.replacingOccurrences(of: key, with: value)
        }
        return translated
    }

    private static func loadEnglishStrings() -> [String: String] {
        guard let url = Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: "en.lproj"),
              let data = try? Data(contentsOf: url),
              let dictionary = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String] else {
            return [:]
        }
        return dictionary
    }
}
