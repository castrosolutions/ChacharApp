import AppKit
import ChacharCore
import Foundation

/// Drives one push-to-talk dictation from key-down to inserted text: capture → transcribe →
/// correct (Layer 1 + fuzzy + optional Layer 2) → inject → log.
///
/// Extracted from `AppDelegate` so the delegate is just wiring and menus, and the pipeline is a
/// single cohesive unit with one clear job. It owns nothing heavy — the models, mic, stores and
/// injector are shared references passed in — and reports back to the app through closures
/// (`onStatus`, `onDelivered`, `onWarning`) instead of reaching into the UI directly.
@MainActor
final class DictationController {
    private let capture: MicrophoneCapture
    private let transcriber: any Transcriber
    private let cleaner: any TextCleaner
    private let injector: any TextInjector
    private let vocabulary: VocabularyStore
    private let history: HistoryStore
    private let settings: SettingsStore

    /// Serial queue for opening/closing the mic engine OFF the event-tap (main run loop) thread.
    /// Starting AVAudioEngine synchronously inside the hotkey callback stalled the tap and could
    /// drop the modifier key's "release" event (push-to-talk got stuck recording).
    private let micControlQueue = DispatchQueue(label: "app.chachar.mic-control")

    /// When the last dictation was injected, and into which app (bundle id). Used to separate
    /// consecutive dictations with a space so two bursts into the same field don't run together
    /// ("primera frase" + "segunda frase" → "primera frase segunda frase"). See `deliver`.
    private var lastDeliveryDate: Date?
    private var lastDeliveryApp: String?
    /// Set when the user presses Return/Enter after a dictation: a newline or a submitted prompt
    /// (e.g. each turn in Claude Code's terminal) starts a fresh line, so the next dictation must
    /// not be joined to the previous one with a space. Reset on each delivery.
    private var contextBrokenSinceDelivery = false
    /// How long after a dictation a follow-up still counts as continuing the same text. Generous on
    /// purpose — people pause to think between bursts — but bounded so an unrelated dictation much
    /// later (even in the same app) doesn't inherit a stray leading space.
    private static let continuationWindow: TimeInterval = 180

    /// Whether Layer 2 cleanup is loaded and ready. Owned by the app (which manages model loading);
    /// the pipeline only reads it to decide whether to run cleanup.
    var isCleanupReady: () -> Bool = { false }
    /// Report a user-visible status line (menu-bar status item).
    var onStatus: (String) -> Void = { _ in }
    /// Called with the final text once it has been injected (e.g. to flash a HUD).
    var onDelivered: (String) -> Void = { _ in }
    /// Non-fatal warnings worth surfacing (e.g. a malformed `vocabulary.json` was ignored).
    var onWarning: (String) -> Void = { _ in }

    init(capture: MicrophoneCapture,
         transcriber: any Transcriber,
         cleaner: any TextCleaner,
         vocabulary: VocabularyStore,
         history: HistoryStore,
         settings: SettingsStore,
         injector: any TextInjector = PasteboardInjector()) {
        self.capture = capture
        self.transcriber = transcriber
        self.cleaner = cleaner
        self.injector = injector
        self.vocabulary = vocabulary
        self.history = history
        self.settings = settings
    }

    // MARK: Push-to-talk

    /// Key down: begin an utterance. In "only while dictating" mode the mic is closed at rest —
    /// open it now, but OFF the event-tap thread so the callback returns immediately (a blocking
    /// start here stalled the tap and dropped the modifier release → stuck recording). Collecting
    /// starts right away; buffers simply begin flowing once the engine is up (hidden by reaction
    /// time).
    func press() {
        if settings.settings.micOnlyWhileDictating {
            micControlQueue.async { try? self.capture.start() }
        }
        capture.beginUtterance()
        onStatus("● Listening…")
    }

    /// Key up: stop capturing and run the transcription pipeline on the recorded audio.
    func release() {
        let samples = capture.endUtterance()
        if settings.settings.micOnlyWhileDictating {
            micControlQueue.async { self.capture.stop() } // release mic (indicator off) off-thread
        }
        let peak = samples.values.map(abs).max() ?? 0
        chacharLog("captured \(samples.values.count) samples, peak=\(peak)")
        onStatus("… Transcribing")

        let vocab = vocabulary.reloadIfChanged()                 // pick up hand-edits
        if let parseError = vocabulary.lastParseError { onWarning(parseError) }
        let corrector = DictionaryCorrector(vocab.replacements)  // Layer 1
        let runCleanup = settings.settings.cleanupEnabled && isCleanupReady()

        Task { await runPipeline(samples: samples, vocab: vocab, corrector: corrector, runCleanup: runCleanup) }
    }

    /// Cancel gesture (ESC): abort the in-progress utterance. Discard the captured audio, release
    /// the mic if it only runs while dictating, and skip the pipeline entirely — nothing is
    /// transcribed or injected. Driven by the hotkey monitor for both push-to-talk and hands-free
    /// sessions, so ESC always means "throw this one away".
    func cancel() {
        _ = capture.endUtterance() // drop the buffered samples without transcribing them
        if settings.settings.micOnlyWhileDictating {
            micControlQueue.async { self.capture.stop() }
        }
        onStatus("Cancelled")
    }

    // MARK: Pipeline

    /// The async correction chain, kept separate so `release()` stays at one level of abstraction
    /// (start/stop the capture) and this method expresses the layered pipeline.
    private func runPipeline(samples: AudioSamples, vocab: Vocabulary,
                             corrector: DictionaryCorrector, runCleanup: Bool) async {
        do {
            // Trim the near-silent tail before transcription: it reduces Whisper's end-of-audio
            // hallucinations (a stray "gracias"/"thank you") and shaves a little latency.
            let speech = samples.trimmingTrailingSilence()

            // Layer 0 (glossary prompt) DISABLED: passing promptTokens to WhisperKit 1.0 made it
            // return EMPTY transcriptions. Jargon is handled by Layer 1 (dictionary) for now;
            // revisit the prompt-biasing API before re-enabling.
            let result = try await transcriber.transcribe(speech, prompt: nil)
            chacharLog("transcribed [\(result.text)] in \(String(format: "%.2f", result.duration))s")

            var output = corrector.correct(result.text)         // Layer 1: deterministic fixes
            if settings.settings.fuzzyGlossaryEnabled {         // Layer 1 (fuzzy): misheard jargon
                output = FuzzyGlossaryCorrector(glossary: vocab.glossary).correct(output)
            }
            if settings.settings.trailingHallucinationFilter {  // Layer 1: strip end-of-audio "gracias"
                output = HallucinationFilter().correct(output)
            }
            var didCleanup = false
            if runCleanup {                                     // Layer 2: local LLM cleanup
                onStatus("… Cleaning up")
                if let cleaned = try? await cleaner.clean(output) { output = cleaned; didCleanup = true }
            }
            deliver(output)
            recordHistory(raw: result.text, inserted: output, cleanupApplied: didCleanup,
                          duration: result.duration)
            onStatus(String(format: "Ready  (last: %.1fs)", result.duration))
        } catch {
            onStatus("Transcription error")
            onWarning("Transcription failed: \(error.localizedDescription)")
        }
    }

    /// Inject the final text into the focused app (clipboard saved/restored), or report no speech.
    ///
    /// Consecutive dictations into the same app get a separating space prepended so successive
    /// push-to-talk bursts read as one continuous text instead of running together — the target
    /// field can't be inspected (that's why we paste), so this leans on the last-delivery timestamp
    /// and app rather than the character before the cursor.
    private func deliver(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onDelivered("(no speech detected)")
            return
        }
        let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let payload = continuesPreviousDictation(inApp: frontApp) ? " " + trimmed : trimmed
        chacharLog("inject [\(payload)]")
        injector.inject(payload)
        lastDeliveryDate = Date()
        lastDeliveryApp = frontApp
        contextBrokenSinceDelivery = false // start a fresh run; a Return before the next one ends it
        onDelivered(trimmed)
    }

    /// Note that the user pressed Return/Enter: the current dictation "run" is over, so the next
    /// dictation should start on its own line instead of being joined with a space. Cheap flag flip
    /// driven by the hotkey monitor; no effect on the transcription path.
    func noteContextBreak() { contextBrokenSinceDelivery = true }

    /// Whether this dictation should be prefixed with a space because it continues a recent one in
    /// the same app. False for the first dictation, after a Return/Enter (new line or submitted
    /// prompt), after switching apps, or after a long pause — so an isolated dictation never picks
    /// up a spurious leading space.
    private func continuesPreviousDictation(inApp app: String?) -> Bool {
        guard !contextBrokenSinceDelivery,
              let app, let lastApp = lastDeliveryApp, let last = lastDeliveryDate, app == lastApp
        else { return false }
        return Date().timeIntervalSince(last) <= Self.continuationWindow
    }

    /// Append the dictation to the local history log (best-effort; never blocks delivery). Skipped
    /// when the user disabled recording or nothing was inserted.
    private func recordHistory(raw: String, inserted: String, cleanupApplied: Bool, duration: Double) {
        guard settings.settings.historyEnabled else { return }
        guard !inserted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        history.append(DictationRecord(date: Date(), raw: raw, inserted: inserted,
                                       cleanupApplied: cleanupApplied, app: app, durationSeconds: duration))
    }
}
