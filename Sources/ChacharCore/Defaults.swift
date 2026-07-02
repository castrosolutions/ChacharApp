import Foundation

/// A Hugging Face model identifier for an MLX cleanup model (e.g.
/// `"mlx-community/Qwen2.5-7B-Instruct-4bit"`). A domain alias — same underlying `String`, but it
/// names the concept so it is searchable and reads as intent at API boundaries.
public typealias ModelId = String

/// An absolute path to a WhisperKit CoreML model folder on disk. Empty means "the bundled model".
public typealias ModelFolderPath = String

/// A spoken-language hint code passed to the recogniser (e.g. `"es"`, `"en"`); `nil` = auto-detect.
public typealias LanguageCode = String

/// Canonical default model identifiers, declared once so the app, the settings catalog, the cleaner
/// and the CLI tools all agree on what "the bundled model" and "the default cleanup model" are.
/// Changing a default here changes it everywhere instead of in three separate literals.
public enum DefaultModels {
    /// Folder name of the default ASR model (the always-available fallback). Dev builds bundle it
    /// via a symlink in Resources; distributed builds download it on first run.
    public static let bundledASRFolderName = "openai_whisper-large-v3-v20240930_626MB"

    /// Default MLX Layer-2 cleanup model (Hugging Face id).
    public static let cleanupModelId: ModelId = "mlx-community/Qwen2.5-7B-Instruct-4bit"
}
