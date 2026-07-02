import Foundation

/// A Spanish-oriented phonetic key. Collapses the sounds that Whisper most often confuses when a
/// Spanish speaker says English/tech jargon, so a glossary term and its likely mishearing reduce to
/// the *same* string (e.g. `GicoCam` and `hikokam` both → `xikokam`). Letters only; digits and
/// punctuation are dropped.
///
/// Folding rules (pragmatic, recall-leaning):
/// - `b`/`v`/`w` → `b`; `z`/`s`/soft `c` → `s`; hard `c`/`k`/`q` → `k`
/// - `g`(before e/i)/`j`/`x`/`h` → `x` (the jota / aspiration class — the GicoCam↔hikokam case)
/// - digraph `ch` → `c`; `ll` → `y`; silent `u` in `qu`/`gue`/`gui` dropped
/// - accents stripped, consecutive duplicates collapsed
public enum PhoneticFold {
    public static func key(for text: String) -> String {
        let folded = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "es"))
            .lowercased()
        let chars = Array(folded)
        var out: [Character] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            switch c {
            case "a", "e", "i", "o", "u":
                out.append(c)
            case "b", "v", "w":
                out.append("b")
            case "c":
                if next == "h" {
                    out.append("c"); i += 1            // digraph "ch" (/tʃ/); 'c' in the key == this sound
                } else if let n = next, "ei".contains(n) {
                    out.append("s")                    // soft c
                } else {
                    out.append("k")                    // hard c
                }
            case "q":
                out.append("k")
                if next == "u" { i += 1 }              // "qu" → k, silent u
            case "k":
                out.append("k")
            case "g":
                if let n = next, "ei".contains(n) {
                    out.append("x")                    // g before e/i = jota sound
                } else if next == "u", i + 2 < chars.count, "ei".contains(chars[i + 2]) {
                    out.append("g"); i += 1            // "gue"/"gui" → g, silent u
                } else {
                    out.append("g")
                }
            case "j", "x":
                out.append("x")
            case "h":
                out.append("x")                        // silent h / aspiration → jota class
            case "l":
                if next == "l" { out.append("y"); i += 1 } else { out.append("l") } // "ll" → y
            case "y":
                out.append("y")
            case "z", "s":
                out.append("s")
            case "ñ", "n":
                out.append("n")
            case "d": out.append("d")
            case "f": out.append("f")
            case "m": out.append("m")
            case "p": out.append("p")
            case "r": out.append("r")
            case "t": out.append("t")
            default:
                break                                  // drop digits / punctuation / other scripts
            }
            i += 1
        }
        var key: [Character] = []
        for ch in out where key.last != ch { key.append(ch) }   // collapse consecutive duplicates
        return String(key)
    }
}

/// Layer 1 (fuzzy) — catches glossary terms that the ASR misheard, *without* needing the exact
/// misheard spelling as a replacement rule. Scans 1–`maxWindow` word windows, reduces each to a
/// phonetic key, and replaces a window with the canonical glossary term when their keys are within a
/// small edit distance. Conservative by design (short terms are skipped) to avoid clobbering
/// ordinary words; runs *after* the deterministic `DictionaryCorrector`.
public struct FuzzyGlossaryCorrector: Corrector {
    private struct Entry { let term: String; let key: String }
    private let entries: [Entry]
    /// Lowercased canonical terms, to detect words that are *already* correct (so a longer window
    /// can't absorb the following word).
    private let canonicalLowercased: Set<String>
    private let maxWindow: Int
    private let maxDistanceRatio: Double
    private let minKeyLength: Int

    /// - Parameters:
    ///   - glossary: canonical terms to match toward.
    ///   - maxWindow: longest run of words to merge into one term (e.g. "hiko cam" → "GicoCam").
    ///   - maxDistanceRatio: allowed phonetic edit distance as a fraction of the term key length.
    ///   - minKeyLength: skip terms whose phonetic key is shorter than this (too collision-prone).
    public init(glossary: [String], maxWindow: Int = 3, maxDistanceRatio: Double = 0.25,
                minKeyLength: Int = 4) {
        self.maxWindow = max(1, maxWindow)
        self.maxDistanceRatio = maxDistanceRatio
        self.minKeyLength = minKeyLength
        self.entries = glossary.compactMap { term in
            let key = PhoneticFold.key(for: term)
            return key.count >= minKeyLength ? Entry(term: term, key: key) : nil
        }
        self.canonicalLowercased = Set(glossary.map { $0.lowercased() })
    }

    public func correct(_ text: String) -> String {
        guard !entries.isEmpty else { return text }
        let words = Self.wordRanges(in: text)
        guard !words.isEmpty else { return text }

        var replacements: [(range: Range<String.Index>, term: String)] = []
        var wi = 0
        while wi < words.count {
            // A word that is already exactly a glossary term is correct: lock it so a longer window
            // can't swallow it together with the following word.
            if canonicalLowercased.contains(String(text[words[wi]]).lowercased()) {
                wi += 1
                continue
            }
            // Evaluate every window length at this position and keep the closest phonetic match;
            // on ties prefer the longer window (merge multi-word jargon like "hiko cam"). Picking
            // min-distance avoids a longer window swallowing an extra low-information trailing word.
            var choice: (size: Int, term: String, dist: Int)?
            let maxSize = min(maxWindow, words.count - wi)
            for size in 1...maxSize {
                let joined = (0..<size).map { String(text[words[wi + $0]]) }.joined()
                let key = PhoneticFold.key(for: joined)
                guard key.count >= minKeyLength, let match = bestMatch(forKey: key),
                      joined.compare(match.term, options: .caseInsensitive) != .orderedSame
                else { continue }
                if choice == nil || match.dist < choice!.dist
                    || (match.dist == choice!.dist && size > choice!.size) {
                    choice = (size, match.term, match.dist)
                }
            }
            if let choice {
                let range = words[wi].lowerBound..<words[wi + choice.size - 1].upperBound
                replacements.append((range, choice.term))
                wi += choice.size
            } else {
                wi += 1
            }
        }

        guard !replacements.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for replacement in replacements {
            result += text[cursor..<replacement.range.lowerBound]
            result += replacement.term
            cursor = replacement.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    private func bestMatch(forKey key: String) -> (term: String, dist: Int)? {
        var best: (term: String, dist: Int)?
        for entry in entries {
            let allowed = Int(Double(entry.key.count) * maxDistanceRatio)
            guard allowed >= 1, abs(entry.key.count - key.count) <= allowed else { continue }
            let dist = Self.levenshtein(key, entry.key)
            guard dist <= allowed else { continue }
            if best == nil || dist < best!.dist { best = (entry.term, dist) }
        }
        return best
    }

    /// Ranges of maximal letter/number runs (words), in order.
    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            if text[i].isLetter || text[i].isNumber {
                let start = i
                while i < text.endIndex, text[i].isLetter || text[i].isNumber {
                    i = text.index(after: i)
                }
                ranges.append(start..<i)
            } else {
                i = text.index(after: i)
            }
        }
        return ranges
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let s = Array(a), t = Array(b)
        if s.isEmpty { return t.count }
        if t.isEmpty { return s.count }
        var prev = Array(0...t.count)
        var curr = [Int](repeating: 0, count: t.count + 1)
        for i in 1...s.count {
            curr[0] = i
            for j in 1...t.count {
                let cost = s[i - 1] == t[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[t.count]
    }
}
