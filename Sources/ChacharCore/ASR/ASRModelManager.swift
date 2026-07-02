import Foundation
import WhisperKit

/// Locates, validates and downloads on-device Whisper (WhisperKit CoreML) models.
///
/// - The **bundled** turbo model ships with the app and is the always-available fallback.
/// - **Downloaded** models live in a managed directory inside Application Support.
/// - **Imported** models are referenced in place (the user points at a folder they already have).
public enum ASRModelManager {
    /// The three CoreML sub-models a WhisperKit model folder must contain to load.
    private static let requiredModels = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]

    /// `~/Library/Application Support/ChacharApp/Models` — where downloaded models live.
    public static func managedModelsDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ChacharApp", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/ChacharApp/Tokenizers` — where WhisperKit fetches a model's
    /// tokenizer when the model folder doesn't carry one. Must be passed explicitly: WhisperKit's
    /// default is `~/Documents/huggingface`, and touching Documents fires a macOS "access files in
    /// your Documents folder" TCC prompt during first-run onboarding.
    public static func tokenizersDirectory() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ChacharApp", directoryHint: .isDirectory)
            .appending(path: "Tokenizers", directoryHint: .isDirectory)
    }

    /// Whether `url` looks like a loadable WhisperKit model folder: each required sub-model is
    /// present as either a compiled `.mlmodelc` or a source `.mlpackage`.
    public static func isValidModelFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        return requiredModels.allSatisfy { name in
            fm.fileExists(atPath: url.appendingPathComponent("\(name).mlmodelc").path)
                || fm.fileExists(atPath: url.appendingPathComponent("\(name).mlpackage").path)
        }
    }

    /// Whether the folder also carries its tokenizer, so it loads fully offline (no Hugging Face
    /// fetch). Informational — loading still works online without it.
    public static func hasOfflineTokenizer(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("tokenizer.json").path)
    }

    /// Download a known Whisper variant (e.g. "large-v3", "small") from the WhisperKit model repo
    /// into the managed directory, reporting progress (0...1). Returns the local model folder.
    /// Requires network. (Wired for Phase 2b.)
    public static func download(
        variant: String,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        let base = managedModelsDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try await WhisperKit.download(variant: variant, downloadBase: base) { p in
            progress?(p.fractionCompleted)
        }
    }
}
