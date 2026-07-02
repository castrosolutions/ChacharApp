import XCTest
@testable import ChacharCore

final class ChacharCoreTests: XCTestCase {
    func testVersionIsNotEmpty() {
        XCTAssertFalse(ChacharCore.version.isEmpty)
    }

    func testAudioSamplesDefaultTo16k() {
        let samples = AudioSamples(values: [0, 0, 0])
        XCTAssertEqual(samples.sampleRate, 16_000)
        XCTAssertEqual(samples.values.count, 3)
    }
}
