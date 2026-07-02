import Foundation
import WhisperKit

/// Errors surfaced by a `Transcriber`.
public enum TranscriberError: Error, Sendable {
    /// `transcribe` was called before a successful `prepare()`.
    case notPrepared
}

/// On-device `Transcriber` backed by WhisperKit (CoreML/ANE) — the default engine
/// (see decisions/0001-asr-engine.md).
///
/// Implemented as an `actor` so it is `Sendable` and serialises access to the underlying
/// `WhisperKit` instance, which is kept alive (warm) for the whole app lifetime.
public actor WhisperKitTranscriber: Transcriber {
    public struct Configuration: Sendable {
        /// Absolute path to the model folder (the turbo `*_626MB` variant).
        public var modelFolder: ModelFolderPath
        /// Spoken-language hint. Spanish by default: forcing the language keeps English tech
        /// terms inline (code-switching) instead of detecting a language per utterance.
        /// `nil` lets Whisper auto-detect.
        public var language: LanguageCode?

        public init(modelFolder: ModelFolderPath, language: LanguageCode? = "es") {
            self.modelFolder = modelFolder
            self.language = language
        }
    }

    private var configuration: Configuration
    private var whisper: WhisperKit?

    /// Model load + warm-up wall-clock time from the last `prepare()`, in seconds.
    public private(set) var lastLoadDuration: TimeInterval = 0

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Change the spoken-language hint live (read per utterance in `makeDecodeOptions`). The model
    /// is language-agnostic, so this takes effect on the next transcription without a reload.
    public func update(language: LanguageCode?) {
        configuration.language = language
    }

    /// Switch to a different on-disk model folder at runtime: load + warm the new model, then swap
    /// it in. On failure the throw leaves the previously loaded model untouched (the caller can keep
    /// using it), so a bad folder never breaks dictation. The new model must be a valid WhisperKit
    /// CoreML folder (MelSpectrogram/AudioEncoder/TextDecoder); loading is offline (`download:false`).
    public func reload(modelFolder: ModelFolderPath) async throws {
        let start = Date()
        let kit = try await load(modelFolder: modelFolder)
        self.whisper = kit
        self.configuration.modelFolder = modelFolder
        self.lastLoadDuration = Date().timeIntervalSince(start)
    }

    public func prepare() async throws {
        guard whisper == nil else { return }
        let start = Date()
        self.whisper = try await load(modelFolder: configuration.modelFolder)
        self.lastLoadDuration = Date().timeIntervalSince(start)
    }

    /// Load and warm a WhisperKit model from a folder. Shared by `prepare()` (first launch) and
    /// `reload(modelFolder:)` (runtime model switch) so both pay the exact same warm-up cost once.
    private func load(modelFolder: ModelFolderPath) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            modelFolder: modelFolder,
            // Fetch the tokenizer (when the model folder lacks one) into our managed dir — the
            // default is ~/Documents/huggingface, which fires a Documents-access TCC prompt.
            tokenizerFolder: ASRModelManager.tokenizersDirectory(),
            verbose: false,   // verbose:false forces log level to .none internally
            prewarm: false,   // 64 GB box: skip the 2x-load prewarm, favour fast startup
            load: true,
            download: false   // model is local; never reach out for the heavy weights
        )
        let kit = try await WhisperKit(config)
        // Warm-up: a short silent buffer pays the CoreML specialization / first-inference cost here
        // instead of on the user's first real utterance (see docs/latency.md).
        let silence = [Float](repeating: 0, count: AudioSamples.whisperSampleRate) // ~1s at 16 kHz
        _ = try? await kit.transcribe(audioArray: silence, decodeOptions: makeDecodeOptions(prompt: nil))
        return kit
    }

    public func transcribe(_ samples: AudioSamples, prompt: String?) async throws -> Transcription {
        guard let whisper else { throw TranscriberError.notPrepared }
        let start = Date()
        let results = try await whisper.transcribe(
            audioArray: samples.values,
            decodeOptions: makeDecodeOptions(prompt: prompt)
        )
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Transcription(text: text, duration: Date().timeIntervalSince(start))
    }

    private func makeDecodeOptions(prompt: String?) -> DecodingOptions {
        // Layer 0 — bias the recogniser toward glossary terms by prepending them as decoder prompt
        // tokens (special tokens filtered out, per WhisperKit convention).
        //
        // KNOWN LIMITATION: with `large-v3-turbo`, passing a glossary prompt (a list of disjoint
        // proper nouns) makes the decoder collapse and emit an immediate end-of-text, returning an
        // EMPTY transcription. This is not a threshold artefact — nulling logProb/compressionRatio/
        // firstTokenLogProb/noSpeech thresholds does NOT recover it (measured). The turbo model was
        // distilled without robust "condition on previous text" training, so prompt biasing is
        // unreliable. See docs/layer0-glossary-findings.md. The app therefore calls this with
        // `prompt: nil`; jargon is handled by Layer 1 (dictionary). Kept wired for the spike harness
        // and for non-turbo models.
        var promptTokens: [Int]?
        if let prompt, !prompt.isEmpty, let tokenizer = whisper?.tokenizer {
            let begin = tokenizer.specialTokens.specialTokenBegin
            let tokens = tokenizer.encode(text: " " + prompt).filter { $0 < begin }
            promptTokens = tokens.isEmpty ? nil : tokens
        }
        return DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: configuration.language,
            usePrefillPrompt: true,
            detectLanguage: configuration.language == nil,
            promptTokens: promptTokens
        )
    }
}
