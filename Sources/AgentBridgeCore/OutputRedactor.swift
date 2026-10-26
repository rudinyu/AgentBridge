import Foundation

public enum OutputRedactor {
    private static let patterns: [(String, String)] = [
        (#"(?i)\bBearer\s+[A-Za-z0-9._~+/-]{12,}=?"#, "Bearer <redacted>"),
        (#"(?i)(authorization\s*:\s*)(?:bearer\s+)?[^\s,;]{12,}"#, "$1<redacted>"),
        (#"(?i)(\b(?:api[_-]?key|access[_-]?token|refresh[_-]?token|secret|password)\b\s*[:=]\s*)[^\s\"'`,;]{8,}"#, "$1<redacted>"),
        (#"\bsk-ant-[A-Za-z0-9_-]{12,}"#, "<redacted>"),
        (#"\bsk-[A-Za-z0-9_-]{16,}"#, "<redacted>"),
        (#"\bgh[pousr]_[A-Za-z0-9]{20,}"#, "<redacted>"),
        (#"\bgithub_pat_[A-Za-z0-9_]{20,}"#, "<redacted>"),
        (#"\bxox[baprs]-[A-Za-z0-9-]{16,}"#, "<redacted>"),
        (#"\bAIza[A-Za-z0-9_-]{30,}"#, "<redacted>")
    ]

    public static func redact(_ text: String) -> String {
        patterns.reduce(text) { value, pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern.0) else { return value }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return expression.stringByReplacingMatches(in: value, range: range, withTemplate: pattern.1)
        }
    }

    public static func redact(_ text: String, knownSecrets: [String]) -> String {
        knownSecrets.filter { !$0.isEmpty }.reduce(text) { value, secret in
            value.replacingOccurrences(of: secret, with: "<redacted>")
        }
    }
}
