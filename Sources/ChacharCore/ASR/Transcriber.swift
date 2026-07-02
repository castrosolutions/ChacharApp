import Foundation

/// A chunk of mono PCM audio at 16 kHz, the rate Whisper expects.
public struct AudioSamples: Sendable {
    /// The sample rate Whisper expects, in Hz. The single source of truth for "16 kHz" across the
    /// mic capture, the transcriber warm-up buffer and this type's default.
    public static let whisperSampleRate = 16_000

    /// Normalised float samples in [-1, 1].
    public let values: [Float]
    /// Sample rate in Hz (expected: `whisperSampleRate`).
    public let sampleRate: Int

    public init(values: [Float], sampleRate: Int = AudioSamples.whisperSampleRate) {
        self.values = values
        self.sampleRate = sampleRate
    }
}

/// Result of a transcription pass.
public struct Transcription: Sendable {
    /// The transcribed text.
    public let text: String
    /// Wall-clock time spent transcribing — feeds the latency budget (see docs/latency.md).
    public let duration: TimeInterval

    public init(text: String, duration: TimeInterval) {
        self.text = text
        self.duration = duration
    }
}

/// A swappable speech-to-text backend.
///
/// The default implementation is `WhisperKitTranscriber` (on-device, local). Keeping this an
/// abstraction lets us drop in alternatives (the Parakeet plan B, or a cloud backend) without
/// touching the rest of the app — see decisions/0001-asr-engine.md.
public protocol Transcriber: Sendable {
    /// Load the model and warm it up. Call once at launch; keep the instance alive so the model
    /// stays hot and per-utterance latency excludes load time.
    func prepare() async throws

    /// Transcribe a full utterance. `prompt` carries the Layer-0 glossary bias (the terms the
    /// model should spell correctly), or `nil` for no biasing.
    func transcribe(_ samples: AudioSamples, prompt: String?) async throws -> Transcription

    /// Change the spoken-language hint applied to subsequent transcriptions (no reload needed).
    func update(language: LanguageCode?) async

    /// Switch to a different on-disk model folder at runtime. On failure the throw leaves the
    /// previously loaded model untouched, so a bad folder never breaks dictation.
    func reload(modelFolder: ModelFolderPath) async throws
}
