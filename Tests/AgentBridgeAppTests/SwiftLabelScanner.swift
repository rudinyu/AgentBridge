import Foundation

/// Finds user-visible labels chosen by a condition in Swift source and reports
/// the ones that would show untranslated. It tokenizes the source, so comments,
/// parentheses inside strings, and nested interpolation cannot confuse it.
enum SwiftLabelScanner {
    private indirect enum Token: Equatable {
        case word(String)
        case symbol(Character)
        /// The text with each interpolation written as `%@`, and the interpolations' own tokens.
        case literal(String, [[Token]])
    }

    private static let translatingCalls: Set<String> = ["localized", "localizedFormat"]
    private static let swiftUILabelCalls: Set<String> = [
        "Text", "Button", "Label", "Picker", "Toggle", "Stepper", "TextField", "SecureField", "Section", "Menu",
        "DisclosureGroup", "GroupBox", "LabeledContent", "help", "navigationTitle", "accessibilityLabel"
    ]
    private static let specifier = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:lld|ld|d|f|@|s|u|x)"#
    )

    /// One line per problem, sorted. `keys` are the translation table's keys.
    static func problems(in source: String, keys: Set<String>) -> [String] {
        let characters = Array(source)
        var position = 0
        var found = Set<String>()
        visit(tokens(characters, &position, untilClosingParenthesis: false), keys: Set(keys.map(normalized)), found: &found)
        return found.sorted()
    }

    /// Labels that are one literal, such as `Text("Approved")`, with no translation.
    static func untranslatedLabels(in source: String, keys: Set<String>) -> [String] {
        let characters = Array(source)
        var position = 0
        var found = Set<String>()
        collectUntranslated(tokens(characters, &position, untilClosingParenthesis: false), keys: Set(keys.map(normalized)), found: &found)
        return found.sorted()
    }

    private static func collectUntranslated(_ tokens: [Token], keys: Set<String>, found: inout Set<String>) {
        for (index, token) in tokens.enumerated() {
            if case .literal(_, let interpolations) = token {
                for interpolation in interpolations { collectUntranslated(interpolation, keys: keys, found: &found) }
            }
            guard case .word(let name) = token,
                  translatingCalls.contains(name) || swiftUILabelCalls.contains(name),
                  index + 1 < tokens.count, tokens[index + 1] == .symbol("(") else { continue }
            let argument = firstArgument(tokens, openingAt: index + 1)
            guard argument.count == 1, case .literal(let text, _) = argument[0],
                  placeholderFree(text).rangeOfCharacter(from: .letters) != nil,
                  !keys.contains(normalized(text)) else { continue }
            found.insert(text)
        }
    }

    /// Alerts and confirmation dialogs are presented outside the view tree, so
    /// their text goes through model.localized. Returns the calls that do not.
    static func dialogTextNotLocalized(in source: String) -> [String] {
        let characters = Array(source)
        var position = 0
        let all = tokens(characters, &position, untilClosingParenthesis: false)
        var found = Set<String>()
        for index in all.indices where (all[index] == .word("alert") || all[index] == .word("confirmationDialog"))
            && index + 1 < all.count && all[index + 1] == .symbol("(") {
            guard var end = closing(all, openingAt: index + 1) else { continue }
            if !isTranslated(firstArgument(all, openingAt: index + 1)) { found.insert("title of \(describe(firstArgument(all, openingAt: index + 1)))") }
            while end + 1 < all.count {
                var open = end + 1
                if all[open] == .word("message"), open + 2 < all.count, all[open + 1] == .symbol(":") { open += 2 }
                guard all[open] == .symbol("{"), let closure = closing(all, openingAt: open) else { break }
                for inner in open..<closure where (all[inner] == .word("Button") || all[inner] == .word("Text")) && all[inner + 1] == .symbol("(") {
                    let argument = firstArgument(all, openingAt: inner + 1)
                    if !isTranslated(argument) { found.insert(describe(argument)) }
                }
                end = closure
            }
        }
        return found.sorted()
    }

    private static func describe(_ argument: [Token]) -> String {
        if case .literal(let text, _)? = argument.first { return text }
        return "a non-literal argument"
    }

    /// A sheet does not pick up the locale set on the main window, so each one
    /// sets it on its own content. Returns how many do not.
    static func sheetsWithoutLocale(in source: String) -> Int {
        let characters = Array(source)
        var position = 0
        let all = tokens(characters, &position, untilClosingParenthesis: false)
        var missing = 0
        for index in all.indices where all[index] == .word("sheet") && index + 1 < all.count && all[index + 1] == .symbol("(") {
            guard let arguments = closing(all, openingAt: index + 1),
                  arguments + 1 < all.count, all[arguments + 1] == .symbol("{"),
                  let content = closing(all, openingAt: arguments + 1),
                  all[(arguments + 2)..<content].contains(.word("locale")) else {
                missing += 1
                continue
            }
        }
        return missing
    }

    private static func closing(_ tokens: [Token], openingAt opening: Int) -> Int? {
        var depth = 0
        for index in opening..<tokens.count {
            switch tokens[index] {
            case .symbol("("), .symbol("["), .symbol("{"):
                depth += 1
            case .symbol(")"), .symbol("]"), .symbol("}"):
                depth -= 1
                if depth == 0 { return index }
            default:
                break
            }
        }
        return nil
    }

    private static func visit(_ tokens: [Token], keys: Set<String>, found: inout Set<String>) {
        for (index, token) in tokens.enumerated() {
            if case .literal(_, let interpolations) = token {
                for interpolation in interpolations { visit(interpolation, keys: keys, found: &found) }
            }
            guard case .word(let name) = token,
                  translatingCalls.contains(name) || swiftUILabelCalls.contains(name),
                  index + 1 < tokens.count, tokens[index + 1] == .symbol("(") else { continue }
            let argument = firstArgument(tokens, openingAt: index + 1)
            guard argument.first != .word("verbatim") else { continue }
            check(argument, isSwiftUILabel: swiftUILabelCalls.contains(name), keys: keys, found: &found)
        }
    }

    private static func check(_ argument: [Token], isSwiftUILabel: Bool, keys: Set<String>, found: inout Set<String>) {
        let labels = conditionalLabels(in: argument)
        for label in labels where !keys.contains(normalized(label)) {
            found.insert("no translation: \(label)")
        }
        guard isSwiftUILabel, !isTranslated(argument) else { return }
        if producesPlainString(argument) {
            for label in labels { found.insert("SwiftUI shows this String as is, use model.localized: \(label)") }
        }
        for case .literal(_, let interpolations) in argument {
            for interpolation in interpolations where !isTranslated(interpolation) {
                for label in conditionalLabels(in: interpolation) {
                    found.insert("interpolated without model.localized: \(label)")
                }
            }
        }
    }

    /// Literals that are the result of a `?:` or `??` in these tokens.
    private static func conditionalLabels(in tokens: [Token]) -> [String] {
        guard tokens.contains(.symbol("?")) else { return [] }
        return tokens.indices.compactMap { index in
            guard index > 0, tokens[index - 1] == .symbol("?") || tokens[index - 1] == .symbol(":"),
                  case .literal(let text, _) = tokens[index],
                  placeholderFree(text).rangeOfCharacter(from: .letters) != nil else { return nil }
            return text
        }
    }

    /// A condition whose branches are all literals becomes a LocalizedStringKey.
    /// Anything else, such as a variable branch, `+`, or `??`, makes it a String,
    /// which SwiftUI shows without looking it up.
    private static func producesPlainString(_ argument: [Token]) -> Bool {
        guard let start = argument.indices.first(where: { index in
            argument[index] == .symbol("?") && (index + 1 == argument.count || argument[index + 1] != .symbol("."))
        }) else { return false }
        if start + 1 < argument.count, argument[start + 1] == .symbol("?") { return true }
        return argument[(start + 1)...].contains { token in
            if case .word = token { return true }
            return token == .symbol("+")
        }
    }

    private static func isTranslated(_ tokens: [Token]) -> Bool {
        tokens.contains { token in
            if case .word(let name) = token { return translatingCalls.contains(name) }
            return false
        }
    }

    /// The tokens from the parenthesis at `opening` up to its first top-level comma or its close.
    private static func firstArgument(_ tokens: [Token], openingAt opening: Int) -> [Token] {
        var depth = 0
        var index = opening + 1
        while index < tokens.count {
            switch tokens[index] {
            case .symbol("("), .symbol("["), .symbol("{"):
                depth += 1
            case .symbol(")"), .symbol("]"), .symbol("}"):
                if depth == 0 { return Array(tokens[(opening + 1)..<index]) }
                depth -= 1
            case .symbol(",") where depth == 0:
                return Array(tokens[(opening + 1)..<index])
            default:
                break
            }
            index += 1
        }
        return Array(tokens[(opening + 1)...])
    }

    private static func normalized(_ text: String) -> String {
        specifier.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "%@")
    }

    private static func placeholderFree(_ text: String) -> String {
        specifier.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    // MARK: Tokenizer

    private static func tokens(_ c: [Character], _ i: inout Int, untilClosingParenthesis: Bool) -> [Token] {
        var result: [Token] = []
        var depth = 0
        while i < c.count {
            let character = c[i]
            if character.isWhitespace {
                i += 1
            } else if character == "/", i + 1 < c.count, c[i + 1] == "/" {
                while i < c.count, !c[i].isNewline { i += 1 }
            } else if character == "/", i + 1 < c.count, c[i + 1] == "*" {
                skipBlockComment(c, &i)
            } else if let hashes = literalHashes(c, i) {
                i += hashes
                result.append(literal(c, &i, hashes: hashes))
            } else if character.isLetter || character.isNumber || character == "_" || character == "$" {
                let start = i
                while i < c.count, c[i].isLetter || c[i].isNumber || c[i] == "_" || c[i] == "$" { i += 1 }
                result.append(.word(String(c[start..<i])))
            } else {
                i += 1
                if untilClosingParenthesis {
                    if character == "(" { depth += 1 }
                    if character == ")" {
                        if depth == 0 { return result }
                        depth -= 1
                    }
                }
                result.append(.symbol(character))
            }
        }
        return result
    }

    private static func skipBlockComment(_ c: [Character], _ i: inout Int) {
        var depth = 0
        repeat {
            if i + 1 < c.count, c[i] == "/", c[i + 1] == "*" {
                depth += 1
                i += 2
            } else if i + 1 < c.count, c[i] == "*", c[i + 1] == "/" {
                depth -= 1
                i += 2
            } else {
                i += 1
            }
        } while depth > 0 && i < c.count
    }

    /// The number of `#` before an opening quote at `i`, or nil if no literal starts here.
    private static func literalHashes(_ c: [Character], _ i: Int) -> Int? {
        var end = i
        while end < c.count, c[end] == "#" { end += 1 }
        return end < c.count && c[end] == "\"" ? end - i : nil
    }

    private static func literal(_ c: [Character], _ i: inout Int, hashes: Int) -> Token {
        let quotes = i + 2 < c.count && c[i + 1] == "\"" && c[i + 2] == "\"" ? 3 : 1
        i += quotes
        var text = ""
        var interpolations: [[Token]] = []
        while i < c.count {
            if isRun(c, i, of: "\"", count: quotes), isRun(c, i + quotes, of: "#", count: hashes) {
                i += quotes + hashes
                break
            }
            guard c[i] == "\\", isRun(c, i + 1, of: "#", count: hashes), i + 1 + hashes < c.count else {
                text.append(c[i])
                i += 1
                continue
            }
            i += 1 + hashes
            let escaped = c[i]
            i += 1
            switch escaped {
            case "(":
                interpolations.append(tokens(c, &i, untilClosingParenthesis: true))
                text += "%@"
            case "n": text.append("\n")
            case "t": text.append("\t")
            case "u": text.append(unicodeEscape(c, &i))
            default: text.append(escaped)
            }
        }
        return .literal(text, interpolations)
    }

    private static func isRun(_ c: [Character], _ i: Int, of character: Character, count: Int) -> Bool {
        i + count <= c.count && c[i..<(i + count)].allSatisfy { $0 == character }
    }

    /// Reads `{2026}` after a `\u`.
    private static func unicodeEscape(_ c: [Character], _ i: inout Int) -> Character {
        var hex = ""
        i += 1
        while i < c.count, c[i] != "}" {
            hex.append(c[i])
            i += 1
        }
        i += 1
        return UInt32(hex, radix: 16).flatMap(Unicode.Scalar.init).map(Character.init) ?? "?"
    }
}
