import XCTest
@testable import ChacharCore

/// Level-1 unit tests (docs/testing.md) for the recording indicator's level mapping. This is the
/// only part of the metering path that can be tested without a microphone — and the part that
/// decides whether the meter looks alive or dead, so it is worth pinning.
final class AudioLevelMeterTests: XCTestCase {

    func testSilenceIsZero() {
        XCTAssertEqual(AudioLevelMeter.level(of: [Float](repeating: 0, count: 128)), 0)
        XCTAssertEqual(AudioLevelMeter.level(rms: 0), 0)
    }

    /// No samples at all (a converter that produced nothing) must read as silence, not crash on a
    /// divide by zero.
    func testEmptyInputIsZero() {
        XCTAssertEqual(AudioLevelMeter.level(of: [Float]()), 0)
    }

    /// Anything at or below the floor pins to 0, anything at or above the ceiling pins to 1 — the
    /// meter never renders a bar outside its own track.
    func testClampsToBothEnds() {
        let belowFloor = pow(10, (AudioLevelMeter.floorDB - 10) / 20)
        let aboveCeiling = pow(10, (AudioLevelMeter.ceilingDB + 10) / 20)
        XCTAssertEqual(AudioLevelMeter.level(rms: belowFloor), 0)
        XCTAssertEqual(AudioLevelMeter.level(rms: aboveCeiling), 1)
        XCTAssertEqual(AudioLevelMeter.level(rms: 1.0), 1, "full-scale audio is full scale")
    }

    /// Halfway between floor and ceiling *in dB* is halfway up the meter: the mapping is
    /// logarithmic, which is the whole point of it.
    func testMidpointIsHalfway() {
        let midDB = (AudioLevelMeter.floorDB + AudioLevelMeter.ceilingDB) / 2
        XCTAssertEqual(AudioLevelMeter.level(rms: pow(10, midDB / 20)), 0.5, accuracy: 0.001)
    }

    /// Ordinary speech (well inside the band) must land in the meter's middle, not scraping the
    /// floor — the failure mode of a linear meter, and the reason this one works in dB.
    func testSpeechLevelSitsWellOffTheFloor() {
        // A ±0.05 tone: about -26 dBFS RMS, a normal dictation level.
        let tone = (0..<1000).map { Float(0.05 * sin(Double($0) * 0.3)) }
        let level = AudioLevelMeter.level(of: tone)
        XCTAssertGreaterThan(level, 0.3)
        XCTAssertLessThan(level, 0.9)
    }

    /// Louder input reads higher. Trivial to state, easy to break by flipping a sign in the dB math.
    func testLouderInputReadsHigher() {
        let quiet = AudioLevelMeter.level(of: [Float](repeating: 0.01, count: 64))
        let loud = AudioLevelMeter.level(of: [Float](repeating: 0.2, count: 64))
        XCTAssertGreaterThan(loud, quiet)
    }

    /// RMS, not mean: a signal that swings symmetrically must not cancel itself out to silence.
    func testNegativeSamplesCountTowardsLoudness() {
        let alternating: [Float] = (0..<64).map { $0.isMultiple(of: 2) ? 0.2 : -0.2 }
        XCTAssertEqual(AudioLevelMeter.level(of: alternating),
                       AudioLevelMeter.level(rms: 0.2),
                       accuracy: 0.0001)
    }
}
