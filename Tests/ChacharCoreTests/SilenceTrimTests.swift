import XCTest
@testable import ChacharCore

final class SilenceTrimTests: XCTestCase {
    private let speechLen = 16_000            // 1 s of "speech"
    private func speech(_ n: Int) -> [Float] { Array(repeating: 0.5, count: n) }
    private func silence(_ n: Int) -> [Float] { Array(repeating: 0, count: n) }

    func testTrimsTrailingSilenceKeepingSpeechPlusMargin() {
        let samples = AudioSamples(values: speech(speechLen) + silence(16_000))
        let trimmed = samples.trimmingTrailingSilence()
        // Something was cut, all the speech survived, and only a small margin of tail remains.
        XCTAssertLessThan(trimmed.values.count, samples.values.count)
        XCTAssertGreaterThanOrEqual(trimmed.values.count, speechLen)
        XCTAssertLessThan(trimmed.values.count, speechLen + 4_000)
    }

    func testLeavesAudioThatRunsToTheEndUntouched() {
        let samples = AudioSamples(values: speech(speechLen))
        let trimmed = samples.trimmingTrailingSilence()
        XCTAssertEqual(trimmed.values.count, samples.values.count)
    }

    func testPureSilenceIsReturnedUnchanged() {
        let samples = AudioSamples(values: silence(8_000))
        let trimmed = samples.trimmingTrailingSilence()
        XCTAssertEqual(trimmed.values.count, samples.values.count)
    }

    func testEmptyIsReturnedUnchanged() {
        let trimmed = AudioSamples(values: []).trimmingTrailingSilence()
        XCTAssertTrue(trimmed.values.isEmpty)
    }

    func testPreservesSampleRate() {
        let samples = AudioSamples(values: speech(speechLen) + silence(8_000), sampleRate: 16_000)
        XCTAssertEqual(samples.trimmingTrailingSilence().sampleRate, 16_000)
    }
}
