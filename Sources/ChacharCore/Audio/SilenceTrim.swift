import Foundation

public extension AudioSamples {
    /// Trim a low-energy trailing tail (near-silence) from the utterance.
    ///
    /// Whisper tends to hallucinate on a long silent tail — emitting a stray "gracias" / "thank you"
    /// / subtitle credit learned from its training data. Cutting the quiet end reduces that at the
    /// source and also shaves transcription latency. A short margin is kept after the last detected
    /// speech so the final phoneme is never clipped.
    ///
    /// Conservative by design: if it can't find a clear speech end (the clip is entirely quiet, or
    /// speech runs to the very end), it returns the samples unchanged.
    ///
    /// - Parameters:
    ///   - frame: analysis window length in samples (default 480 ≈ 30 ms at 16 kHz).
    ///   - silenceRatio: a frame counts as silence when its peak is below this fraction of the
    ///     whole clip's peak (default 0.02 = 2 %).
    ///   - marginFrames: how many frames of audio to keep after the last speech frame (default 5 ≈
    ///     150 ms) so trailing consonants survive.
    func trimmingTrailingSilence(frame: Int = 480,
                                 silenceRatio: Float = 0.02,
                                 marginFrames: Int = 5) -> AudioSamples {
        guard frame > 0, !values.isEmpty else { return self }
        let peak = values.reduce(Float(0)) { Swift.max($0, abs($1)) }
        guard peak > 0 else { return self } // pure digital silence — nothing meaningful to keep
        let threshold = peak * silenceRatio

        // Walk fixed-size frames backwards from the end; stop at the first (rightmost) frame whose
        // peak clears the threshold — that marks the end of speech.
        var idx = values.count
        var speechEnd: Int?
        while idx > 0 {
            let start = Swift.max(0, idx - frame)
            var framePeak: Float = 0
            for i in start..<idx { framePeak = Swift.max(framePeak, abs(values[i])) }
            if framePeak > threshold { speechEnd = idx; break }
            idx = start
        }
        guard let speechEnd else { return self } // all quiet → leave untouched

        let cut = Swift.min(values.count, speechEnd + frame * Swift.max(0, marginFrames))
        guard cut < values.count else { return self } // speech reaches the end → nothing to trim
        return AudioSamples(values: Array(values[0..<cut]), sampleRate: sampleRate)
    }
}
