import Foundation

/// Transforms a raw transcription into the final text. The swappable seam for correction layers
/// (Layer 1 dictionary now; a Layer 2 LLM cleanup can be another `Corrector` later).
public protocol Corrector: Sendable {
    func correct(_ text: String) -> String
}

/// Layer 1 — applies the user's deterministic find/replace rules, in order.
public struct DictionaryCorrector: Corrector {
    private let replacements: [Vocabulary.Replacement]

    public init(_ replacements: [Vocabulary.Replacement]) {
        self.replacements = replacements
    }

    public func correct(_ text: String) -> String {
        var result = text
        for rule in replacements where !rule.from.isEmpty {
            result = Self.apply(rule, to: result)
        }
        return result
    }

    private static func apply(_ rule: Vocabulary.Replacement, to text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: rule.from)
        let pattern = (rule.wholeWord ?? true) ? "\\b\(escaped)\\b" : escaped
        var options: NSRegularExpression.Options = []
        if !(rule.caseSensitive ?? false) { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        let template = NSRegularExpression.escapedTemplate(for: rule.to)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
