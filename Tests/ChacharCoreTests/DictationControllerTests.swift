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
        /// A recognisable engine failure, so tests can drive the pipeline's error path.
        struct Failure: LocalizedError { var errorDescription: String? { "the model gave up" } }

        private let lock = NSLock()
        private var _calls = 0
        private var _failNext = false
        private let canned: String

        init(returning text: String) { canned = text }

        var transcribeCalls: Int {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }

        /// Make the next `transcribe` throw.
        var failNext: Bool {
            get { lock.withLock { _failNext } }
            set { lock.withLock { _failNext = newValue } }
        }

        // Sync helper: NSLock.lock() is unavailable directly inside async methods.
        private func recordCall() -> Bool {
            lock.withLock {
                _calls += 1
                defer { _failNext = false }
                return _failNext
            }
        }

        func prepare() async throws {}
        func transcribe(_ samples: AudioSamples, prompt: String?) async throws -> Transcription {
            if recordCall() { throw Failure() }
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
        /// What the focused app is pretending to be: somewhere to type, or nowhere.
        var outcome: InjectionOutcome = .inserted

        @discardableResult
        func inject(_ text: String) -> InjectionOutcome {
            // Recorded either way: the controller must still *attempt* the insertion, so a bug
            // that stopped short of trying would show up here.
            injected.append(text)
            return outcome
        }
    }

    /// Collects everything the controller reports back to the app.
    @MainActor
    private final class Recorder {
        var statuses: [String] = []
        var delivered: [String] = []
        var warnings: [String] = []
        var phases: [DictationPhase] = []
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
        controller.onPhase = { recorder.phases.append($0) }
        controller.frontmostApp = { FrontmostApp(bundleID: "com.example.editor", name: "Editor") }
        return Harness(controller: controller, capture: capture, transcriber: transcriber,
                       injector: injector, recorder: recorder, history: history)
    }

    private static func options(micOnlyWhileDictating: Bool,
                                cleanupEnabled: Bool = false) -> DictationOptions {
        DictationOptions(micOnlyWhileDictating: micOnlyWhileDictating,
                         cleanupEnabled: cleanupEnabled,
                         fuzzyGlossaryEnabled: true,
                         trailingHallucinationFilter: true,
                         historyEnabled: true)
    }

    /// Wait until the controller reports `phase`, then return everything it reported. Phases are
    /// emitted from the async pipeline, so tests must synchronize on one rather than sleep.
    @MainActor
    private func awaitPhase(_ phase: DictationPhase,
                            in harness: Harness,
                            during action: () -> Void) async -> [DictationPhase] {
        let reached = expectation(description: "phase \(phase)")
        harness.controller.onPhase = { [recorder = harness.recorder] reported in
            recorder.phases.append(reported)
            if reported == phase { reached.fulfill() }
        }
        action()
        await fulfillment(of: [reached], timeout: 2)
        return harness.recorder.phases
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

    // MARK: Phases
    //
    // `onPhase` is what the floating status overlay renders, so these pin the *sequence*: a phase
    // that never arrives leaves the overlay stuck showing the previous one (a spinner that spins
    // forever), and a spurious one flashes a pill for something that didn't happen.

    /// The whole journey of one ordinary dictation, in order.
    @MainActor
    func testPhasesFollowOneDictationEndToEnd() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: [0.1, -0.2, 0.3]))
        await pressAndAwaitStartAttempt(harness)

        let phases = await awaitPhase(.finished, in: harness) { harness.controller.release() }
        XCTAssertEqual(phases, [.listening, .transcribing, .finished])
    }

    /// Layer 2 announces itself: without `.cleaningUp` the overlay would show "Transcribing…"
    /// through the seconds the LLM takes, which is the slowest wait in the app.
    @MainActor
    func testCleanupReportsItsOwnPhase() async {
        let harness = makeHarness(
            options: Self.options(micOnlyWhileDictating: true, cleanupEnabled: true),
            capture: FakeCapture(samples: [0.1, -0.2, 0.3]))
        harness.controller.isCleanupReady = { true }
        await pressAndAwaitStartAttempt(harness)

        let phases = await awaitPhase(.finished, in: harness) { harness.controller.release() }
        XCTAssertEqual(phases, [.listening, .transcribing, .cleaningUp, .finished])
    }

    /// An empty capture ends at `.noSpeech`, not `.finished` — nothing was inserted.
    @MainActor
    func testEmptyCaptureEndsAtNoSpeechPhase() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: []))
        await pressAndAwaitStartAttempt(harness)
        harness.controller.release()

        XCTAssertEqual(harness.recorder.phases, [.listening, .noSpeech])
    }

    /// A mic that delivers audio made only of exact zeros is connected but dead (a closed MacBook
    /// lid, a sleeping Continuity iPhone). That must be reported as a mic failure naming the fix —
    /// not transcribed, which would only end in "no speech" and blame the speaker.
    @MainActor
    func testDigitalSilenceIsReportedAsDeadMicNotTranscribed() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: [Float](repeating: 0, count: 16_000)))
        await pressAndAwaitStartAttempt(harness)
        harness.controller.release()

        XCTAssertEqual(harness.transcriber.transcribeCalls, 0, "dead-mic audio must not be transcribed")
        XCTAssertEqual(harness.recorder.phases, [.listening, .failed(DictationController.deadMicMessage)])
        XCTAssertEqual(harness.recorder.statuses.last, "Mic sent no sound")
        XCTAssertTrue(harness.injector.injected.isEmpty)
        XCTAssertTrue(harness.history.load().isEmpty)
    }

    /// A transcription that survives the correction layers as pure whitespace also ends at
    /// `.noSpeech`: the pipeline ran to completion, but nothing reached the focused app.
    @MainActor
    func testBlankTranscriptionEndsAtNoSpeechPhase() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: [0.1]),
                                  transcribing: "   ")
        await pressAndAwaitStartAttempt(harness)

        let phases = await awaitPhase(.noSpeech, in: harness) { harness.controller.release() }
        XCTAssertEqual(phases, [.listening, .transcribing, .noSpeech])
        XCTAssertTrue(harness.injector.injected.isEmpty)
    }

    /// A mic that won't open reports `.failed` carrying the reason, and `release()` must not
    /// follow it with `.noSpeech` — that would replace the cause with a symptom (the same
    /// masking the status line is guarded against).
    @MainActor
    func testMicStartFailureReportsFailedPhaseAndIsNotMasked() async {
        let harness = makeHarness(
            options: Self.options(micOnlyWhileDictating: true),
            capture: FakeCapture(samples: [], startError: MicrophoneCaptureError.inputUnavailable))

        let failed = expectation(description: "failure phase reported")
        harness.controller.onPhase = { [recorder = harness.recorder] phase in
            recorder.phases.append(phase)
            if case .failed = phase { failed.fulfill() }
        }
        harness.controller.press()
        await fulfillment(of: [failed], timeout: 2)

        harness.controller.release()

        XCTAssertEqual(harness.recorder.phases.count, 2, "got \(harness.recorder.phases)")
        XCTAssertEqual(harness.recorder.phases.first, .listening)
        guard case .failed(let reason) = harness.recorder.phases.last else {
            return XCTFail("expected a .failed phase, got \(harness.recorder.phases)")
        }
        XCTAssertTrue(reason.contains("microphone"), "the reason must name the cause: \(reason)")
    }

    /// ESC ends the dictation explicitly, so the overlay can stop listening rather than wait for a
    /// pipeline that will never run.
    @MainActor
    func testCancelReportsCancelledPhase() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: [0.5, 0.5]))
        await pressAndAwaitStartAttempt(harness)
        harness.controller.cancel()

        XCTAssertEqual(harness.recorder.phases, [.listening, .cancelled])
    }

    // MARK: Nowhere to insert
    //
    // A synthetic ⌘V into an app with no focused text field does nothing, silently — so these pin
    // the behaviour that used to be a lie: the dictation was announced as inserted, the words were
    // gone, and only the history log still had them.

    /// When the focused app has nowhere to put the text, the run ends at `.notInserted` carrying
    /// the words — never at `.finished`.
    @MainActor
    func testNoTextTargetEndsAtNotInsertedCarryingTheText() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: [0.1]),
                                  transcribing: "hola mundo")
        harness.injector.outcome = .noTextTarget
        await pressAndAwaitStartAttempt(harness)

        let reported = expectation(description: "not-inserted phase reported")
        harness.controller.onPhase = { [recorder = harness.recorder] phase in
            recorder.phases.append(phase)
            if case .notInserted = phase { reported.fulfill() }
        }
        harness.controller.release()
        await fulfillment(of: [reported], timeout: 2)

        XCTAssertEqual(harness.recorder.phases, [.listening, .transcribing, .notInserted("hola mundo")])
        XCTAssertEqual(harness.injector.injected, ["hola mundo"], "it must still attempt the paste")
        XCTAssertFalse(harness.recorder.delivered.contains("hola mundo"),
                       "nothing was delivered, so onDelivered must stay quiet")
    }

    /// Text that never landed is still logged: the history file is the second place it survives,
    /// after the overlay's copy button.
    @MainActor
    func testNoTextTargetStillRecordsHistory() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: [0.1]),
                                  transcribing: "rescátame")
        harness.injector.outcome = .noTextTarget
        await pressAndAwaitStartAttempt(harness)

        _ = await awaitPhase(.notInserted("rescátame"), in: harness) { harness.controller.release() }
        XCTAssertEqual(harness.history.load().last?.inserted, "rescátame")
    }

    /// The separating-space logic must not count a failed insertion as a delivery. Otherwise the
    /// next dictation into that app would open with a stray leading space, continuing text that
    /// was never there.
    @MainActor
    func testFailedInsertionDoesNotStartAContinuationRun() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: [0.1]),
                                  transcribing: "primera")
        harness.injector.outcome = .noTextTarget
        await pressAndAwaitStartAttempt(harness)
        _ = await awaitPhase(.notInserted("primera"), in: harness) { harness.controller.release() }

        // Same app, moments later — but the first dictation never landed, so this one starts clean.
        harness.injector.outcome = .inserted
        await pressAndAwaitStartAttempt(harness)
        _ = await awaitPhase(.finished, in: harness) { harness.controller.release() }

        XCTAssertEqual(harness.injector.injected, ["primera", "primera"],
                       "the second insertion must not be prefixed with a continuation space")
    }

    /// A transcription failure must end the run: `.failed` clears the spinner and names the cause.
    @MainActor
    func testTranscriptionFailureReportsFailedPhase() async {
        let harness = makeHarness(options: Self.options(micOnlyWhileDictating: true),
                                  capture: FakeCapture(samples: [0.1]),
                                  transcribing: "unused")
        harness.transcriber.failNext = true
        await pressAndAwaitStartAttempt(harness)

        let failed = expectation(description: "failure phase reported")
        harness.controller.onPhase = { [recorder = harness.recorder] phase in
            recorder.phases.append(phase)
            if case .failed = phase { failed.fulfill() }
        }
        harness.controller.release()
        await fulfillment(of: [failed], timeout: 2)

        XCTAssertEqual(harness.recorder.phases.count, 3, "got \(harness.recorder.phases)")
        guard case .failed(let reason) = harness.recorder.phases.last else {
            return XCTFail("expected a .failed phase, got \(harness.recorder.phases)")
        }
        XCTAssertTrue(reason.hasPrefix("Transcription failed:"), "got \(reason)")
        XCTAssertTrue(harness.injector.injected.isEmpty)
    }
}
