import Foundation

/// Layer 1 safety net for a well-known Whisper failure mode: on near-silent or very short audio the
/// model hallucinates a stock phrase it saw all over its training data (YouTube captions) — most
/// often a trailing "gracias" / "thank you" / subtitle credit.
///
/// This removes such a phrase **only when it stands as the isolated final clause** of the text, so a
/// genuine "muchas gracias por tu ayuda" (where "gracias" sits mid-sentence) is left untouched. It
/// is deliberately deterministic and free — it runs even when the optional Layer 2 LLM cleanup is
/// off, which is the common case. Trimming the silent tail before transcription
/// (``AudioSamples/trimmingTrailingSilence(frame:silenceRatio:marginFrames:)``) tackles the same
/// problem at the source; this catches what still slips through.
public struct HallucinationFilter {
    /// Phrases (normalised: lowercased, letters + single spaces only) that are stripped when they
    /// form the whole trailing clause. Kept short and high-confidence to avoid deleting real speech.
    static let trailingPhrases: Set<String> = [
        "gracias",
        "muchas gracias",
        "gracias por ver",
        "gracias por ver el video",
        "gracias por ver el vídeo",
        "gracias por su atencion",
        "gracias por su atención",
        "thank you",
        "thanks",
        "thank you very much",
        "thanks for watching",
        "thank you for watching",
    ]

    public init() {}

    /// Return `text` with a trailing hallucinated clause removed, or `text` unchanged if the final
    /// clause isn't a known phrase.
    public func correct(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }

        let terminators: Set<Character> = [".", "!", "?", "…", "\n"]

        // End of the real content (skip the sentence's own trailing "." so we don't land on it).
        guard let contentEnd = trimmed.lastIndex(where: { !terminators.contains($0) && !$0.isWhitespace })
        else { return text } // only punctuation/whitespace — nothing to do

        // The final clause starts after the last terminator that precedes the content end. If there
        // is none, the whole text is the final clause. This guarantees a mid-sentence "gracias"
        // (followed by more words) is never considered.
        let prefix = trimmed[trimmed.startIndex...contentEnd]
        let clauseStart: String.Index
        if let termIdx = prefix.dropLast().lastIndex(where: { terminators.contains($0) }) {
            clauseStart = trimmed.index(after: termIdx)
        } else {
            clauseStart = trimmed.startIndex
        }

        let clause = Self.normalize(String(trimmed[clauseStart...]))
        guard Self.trailingPhrases.contains(clause) else { return text }

        // Drop the hallucinated clause; keep the preceding text (and its terminator) verbatim.
        return String(trimmed[..<clauseStart]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercase, keep only letters and spaces (drops punctuation, digits, emoji), collapse runs of
    /// whitespace. Accented letters are preserved so "vídeo" and "atención" match as written.
    static func normalize(_ s: String) -> String {
        let scalars = s.lowercased().unicodeScalars.filter {
            CharacterSet.letters.contains($0) || $0 == " "
        }
        return String(String.UnicodeScalarView(scalars))
            .split(separator: " ")
            .joined(separator: " ")
    }
}
