import Foundation

/// Turns a block of PCM samples into a 0…1 loudness value for the on-screen level meter.
///
/// Pure math, kept out of ``MicrophoneCapture`` on purpose: the mapping is the part worth
/// unit-testing, and the capture path itself can't be exercised without a real microphone
/// (docs/testing.md, level 1).
public enum AudioLevelMeter {
    /// Quietest level that still lifts the meter off the floor, in dBFS. Room tone and fan noise
    /// sit below this, so a silent room draws a flat line instead of a nervous flicker.
    public static let floorDB: Float = -55
    /// Level treated as "full scale" by the meter, in dBFS. Normal dictation peaks around
    /// -20…-12 dBFS, so anchoring the top here keeps the bars lively instead of pinned at 10%.
    public static let ceilingDB: Float = -12

    /// Root-mean-square loudness of `samples`, mapped logarithmically to 0…1.
    ///
    /// dB rather than raw amplitude because loudness is perceived logarithmically: a linear RMS
    /// meter hugs zero for ordinary speech and only visibly moves when shouted at.
    public static func level<S: Sequence<Float>>(of samples: S) -> Float {
        var sumOfSquares: Float = 0
        var count = 0
        for value in samples {
            sumOfSquares += value * value
            count += 1
        }
        guard count > 0 else { return 0 }
        return level(rms: (sumOfSquares / Float(count)).squareRoot())
    }

    /// Map an RMS amplitude (0…1) onto the meter's 0…1 range, clamped at both ends.
    public static func level(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(max((db - floorDB) / (ceilingDB - floorDB), 0), 1)
    }
}
