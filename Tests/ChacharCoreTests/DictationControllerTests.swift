import XCTest
@testable import ChacharCore

/// Level-2 integration tests (docs/testing.md): drive `press()`/`release()` and assert the whole
/// pipeline — capture → transcribe → Layer 1 → inject → history — with fakes at the seams, so no
/// microphone, ANE, or TCC is involved. These pin the failure modes of the AirPods device-switch
/// fix: a mic that fails to open must be retried on the next press (in both mic modes), must be
/// reported, and must not end with the app claiming "Ready".
final class DictationControllerTests: XCTestCase {

    // MARK: Fakes

    /// Capture fake: canned samples, scriptable `start()` failure, no AVAudioEngine.
    private final class FakeCapture: AudioCapturing, @unchecked Sendable {
        private let lock = NSLock()
        private var startError: Error?
        private var samples: [Float]
        private var _startCalls = 0
        private var _onStartAttempt: (@Sendable () -> Void)?

        init(samples: [Float] = [], startError: Error? = nil) {
            self.samples = samples
            self.startError = startError
        }

        var startCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return _startCalls
        }

        /// Fired after each `start()` attempt (success or failure) — lets tests await the
        /// off-thread mic-control hop deterministically instead of sleeping. Set it BEFORE the
        /// press() that should trigger it (the mic queue runs concurrently with the test).
        var onStartAttempt: (@Sendable () -> Void)? {
            get { lock.withLock { _onStartAttempt } }
            set { lock.withLock { _onStartAttempt = newValue } }
        }

        func start() throws {
            lock.lock()
            _startCalls += 1
            let error = startError
            let handler = _onStartAttempt
            lock.unlock()
            defer { handler?() }
            if let error { throw error }
        }

        func stop() {}
        func beginUtterance() {}
        func endUtterance() -> AudioSamples {
            lock.lock(); defer { lock.unlock() }
            return AudioSamples(values: samples)
        }
    }

    private final class FakeTranscriber: Transcriber, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private let canned: String

        init(returning text: String) { canned = text }

        var transcribeCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        // Sync helper: NSLock.lock() is unavailable directly inside async methods.
        private func recordCall() { lock.withLock { _calls += 1 } }

        func prepare() async throws {}
        func transcribe(_ samples: AudioSamples, prompt: String?) async throws -> Transcription {
            recordCall()
            return Transcription(text: canned, duration: 0.25)
        }
        func update(language: LanguageCode?) async {}
        func reload(modelFolder: ModelFolderPath) async throws {}
    }

    private struct NoopCleaner: TextCleaner {
        func prepare() async throws {}
        func clean(_ text: String) async throws -> String { text }
        func reload(modelId: ModelId, progress: (@Sendable (Double) -> Void)?) async throws {}
    }

    @MainActor
    private final class SpyInjector: TextInjector {
        var injected: [String] = []
        func inject(_ text: String) { injected.append(text) }
    }

    /// Collects everything the controller reports back to the app.
    @MainActor
    private final class Recorder {
        var statuses: [String] = []
        var delivered: [String] = []
        var warnings: [String] = []
    }

    // MARK: Harness

    @MainActor
    private struct Harness {
        let controller: DictationController
        let capture: FakeCapture
        let transcriber: FakeTranscriber
        let injector: SpyInjector
        let recorder: Recorder
        let history: HistoryStore
    }

    @MainActor
    private func makeHarness(options: DictationOptions,
                             capture: FakeCapture,
                             transcribing text: String = "hola mundo") -> Harness {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "chachar-dictation-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let transcriber = FakeTranscriber(returning: text)
        let injector = SpyInjector()
        let recorder = Recorder()
        let history = HistoryStore(url: dir.appending(path: "history.jsonl"))
        let controller = DictationController(
            capture: capture,
            transcriber: transcriber,
            cleaner: NoopCleaner(),
            vocabulary: VocabularyStore(url: dir.appending(path: "vocabulary.json")),
            history: history,
            options: { options },
            injector: injector
        )
        controller.onStatus = { recorder.statuses.append($0) }
        controller.onDelivered = { recorder.delivered.append($0) }
        controller.onWarning = { recorder.warnings.append($0) }
        controller.frontmostApp = { FrontmostApp(bundleID: "com.example.editor", name: "Editor") }
        return Harness(controller: controller, capture: capture, transcriber: transcriber,
                       injector: injector, recorder: recorder, history: history)
    }

    private static func options(micOnlyWhileDictating: Bool) -> DictationOptions {
        DictationOptions(micOnlyWhileDictating: micOnlyWhileDictating,
                         cleanupEnabled: false,
                         fuzzyGlossaryEnabled: true,
                         trailingHallucinationFilter: true,
                         historyEnabled: true)
    }

    /// Press and wait until the fake capture has seen the resulting `start()` attempt (press hops
    /// to the mic queue, so the test must synchronize with it before asserting).
    @MainActor
    private func pressAndAwaitStartAttempt(_ harness: Harness) async {
        let started = expectation(description: "mic start attempted")
        harness.capture.onStartAttempt = { started.fulfill() }
        harness.controller.press()
        await fulfillment(of: [started], timeout: 2)
        harness.capture.onStartAttempt = nil
    }

    // MARK: Tests

    /// Full happy path in cold-mic mode: press/release runs the pipeline and the transcription is
    /// injected, logged to history, and the status ends at "Ready".
    @MainActor
    func testColdModeTranscribesInjectsAndLogs() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: [0.1, -0.2, 0.3]))
        await pressAndAwaitStartAttempt(harness)

        let delivered = expectation(description: "text delivered")
        harness.controller.onDelivered = { [recorder = harness.recorder] in
            recorder.delivered.append($0)
            delivered.fulfill()
        }
        harness.controller.release()
        await fulfillment(of: [delivered], timeout: 2)

        XCTAssertEqual(harness.injector.injected, ["hola mundo"])
        XCTAssertEqual(harness.recorder.delivered, ["hola mundo"])
        XCTAssertEqual(harness.transcriber.transcribeCalls, 1)
        let record = harness.history.load().last
        XCTAssertEqual(record?.inserted, "hola mundo")
        XCTAssertEqual(record?.app, "Editor")
        // The pipeline hops back to report "Ready (last: …)" after delivering.
        XCTAssertTrue(harness.recorder.statuses.last?.hasPrefix("Ready") == true,
                      "expected a final Ready status, got \(harness.recorder.statuses)")
    }

    /// Regression (AirPods fix review, finding 1): in warm-mic mode `press()` must attempt
    /// `start()` too — it is the only retry path when a device-change rebuild failed and left the
    /// warm engine down. Before the fix, press() only started the mic in cold mode.
    @MainActor
    func testWarmModePressAttemptsMicStart() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: false),
                                  capture: FakeCapture(samples: [0.1]))
        await pressAndAwaitStartAttempt(harness)
        XCTAssertEqual(harness.capture.startCalls, 1)
    }

    /// Regression (AirPods fix review, findings 1+3): when the mic fails to open, the failure must
    /// be surfaced and must STICK — release() must not run the pipeline on the empty capture and
    /// overwrite "Mic error" with "Ready", making the app claim a health it doesn't have.
    @MainActor
    func testMicStartFailureSurfacesAndIsNotMaskedByRelease() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: [],
                                                       startError: MicrophoneCaptureError.inputUnavailable))

        let failed = expectation(description: "mic error reported")
        harness.controller.onStatus = { [recorder = harness.recorder] status in
            recorder.statuses.append(status)
            if status == "Mic error" { failed.fulfill() }
        }
        harness.controller.press()
        await fulfillment(of: [failed], timeout: 2)

        harness.controller.release()

        XCTAssertEqual(harness.transcriber.transcribeCalls, 0, "pipeline must not run on a failed mic")
        XCTAssertTrue(harness.injector.injected.isEmpty)
        XCTAssertEqual(harness.recorder.statuses.last, "Mic error",
                       "the error status must survive release(), got \(harness.recorder.statuses)")
        XCTAssertFalse(harness.recorder.warnings.isEmpty, "the failure must reach the user as a warning")
    }

    /// An empty capture with a healthy mic (press shorter than the engine spin-up) skips the
    /// pipeline and reports plain no-speech — no transcription, no bogus history entry.
    @MainActor
    func testEmptyCaptureWithHealthyMicReportsNoSpeech() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: []))
        await pressAndAwaitStartAttempt(harness)
        harness.controller.release()

        XCTAssertEqual(harness.transcriber.transcribeCalls, 0)
        XCTAssertEqual(harness.recorder.delivered, ["(no speech detected)"])
        XCTAssertEqual(harness.recorder.statuses.last, "Ready")
        XCTAssertTrue(harness.history.load().isEmpty)
    }

    /// ESC discards the utterance entirely: nothing transcribed, nothing injected.
    @MainActor
    func testCancelDiscardsUtterance() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: [0.5, 0.5]))
        await pressAndAwaitStartAttempt(harness)
        harness.controller.cancel()

        XCTAssertEqual(harness.transcriber.transcribeCalls, 0)
        XCTAssertTrue(harness.injector.injected.isEmpty)
        XCTAssertEqual(harness.recorder.statuses.last, "Cancelled")
    }
}
