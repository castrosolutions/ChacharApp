import Foundation

/// Layer 2 — semantic cleanup of a transcription: remove fillers/false starts and resolve
/// self-corrections ("el coche es rojo, no, verde" → "El coche es verde"), while preserving
/// meaning, language (Spanish + English code-switching) and jargon.
///
/// Async because real implementations run a language model. The default is a local LLM via MLX
/// (`ChacharCleanupMLX`), keeping the app 100% local. Kept as a separate protocol from
/// `Corrector` because it is asynchronous and optional.
public protocol TextCleaner: Sendable {
    /// Load/warm the model. Safe to call once; may download the model on first run.
    func prepare() async throws
    /// Clean the text. Implementations should fall back to the input on any doubt.
    func clean(_ text: String) async throws -> String
    /// Switch to a different model at runtime, releasing the current one and reporting download
    /// progress (0...1) on first use. On failure the cleaner is left unready.
    func reload(modelId: ModelId, progress: (@Sendable (Double) -> Void)?) async throws
    /// Run a tiny throwaway inference so the first real ``clean(_:)`` doesn't pay one-time costs
    /// (e.g. Metal pipeline compilation, cache priming). No-op if no model is loaded.
    func warmUp() async
    /// Release the loaded model to free memory — e.g. when the user turns cleanup off. Loading it
    /// again is a plain ``prepare()``/``reload(modelId:progress:)``.
    func unload() async
}

public extension TextCleaner {
    // Optional for cleaners with nothing to warm/release (e.g. a no-op or remote cleaner).
    func warmUp() async {}
    func unload() async {}
}
