import Foundation

/// User vocabulary: terms to bias the recogniser toward (Layer 0) and deterministic
/// post-transcription fixes (Layer 1). Stored as JSON the user can hand-edit.
public struct Vocabulary: Codable, Sendable, Equatable {
    /// Layer 0 — terms fed to Whisper as a prompt so it spells them correctly up front.
    public var glossary: [String]
    /// Layer 1 — deterministic find/replace applied to the transcription, in order.
    public var replacements: [Replacement]

    public struct Replacement: Codable, Sendable, Equatable {
        public var from: String
        public var to: String
        /// Match case-sensitively. Default: false.
        public var caseSensitive: Bool?
        /// Match whole words only (word boundaries). Default: true.
        public var wholeWord: Bool?

        public init(from: String, to: String, caseSensitive: Bool? = nil, wholeWord: Bool? = nil) {
            self.from = from
            self.to = to
            self.caseSensitive = caseSensitive
            self.wholeWord = wholeWord
        }
    }

    public init(glossary: [String] = [], replacements: [Replacement] = []) {
        self.glossary = glossary
        self.replacements = replacements
    }

    /// Layer 0 prompt text (terms joined), or nil when the glossary is empty.
    public var glossaryPrompt: String? {
        let terms = glossary.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return terms.isEmpty ? nil : terms.joined(separator: ", ")
    }

    /// A starter vocabulary written on first run so the file shows the format and is useful.
    public static let seed = Vocabulary(
        glossary: ["AWS", "S3", "Kubernetes", "i3", "WhisperKit", "SwiftPM", "Xcode",
                   "CoreML", "ANE", "macOS", "Argmax", "MLX"],
        replacements: [
            Replacement(from: "cubernetes", to: "Kubernetes"),
            Replacement(from: "ese tres", to: "S3"),
        ]
    )
}
