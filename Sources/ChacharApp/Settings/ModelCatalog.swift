import ChacharCore
import Foundation

/// Curated metadata for a selectable model, shown as a capabilities table in the Models tab. Numbers
/// are seeded from our own benchmarks where available (turbo RTF, 7B tok/s) and are otherwise rough
/// estimates — flagged in `note`.
struct ModelDescriptor: Identifiable, Hashable {
    enum Kind { case asr, cleanup }

    let id: String          // model id: WhisperKit folder/repo name, or HF id for MLX cleanup models
    let kind: Kind
    let name: String        // display name
    let sizeText: String    // on-disk footprint, human-readable
    let ramText: String     // approx resident RAM
    let speedText: String   // RTF (ASR) or tok/s (cleanup)
    let quality: String
    let languages: String
    let note: String?
    let bundled: Bool       // the built-in default (always listed; excluded from the download section)

    var subtitle: String { id }
}

/// The models ChacharApp knows about. Selection of the cleanup model is live (downloads via MLX on
/// first use); ASR selection is informational for now (Phase 2 — see roadmap Epic B).
enum ModelCatalog {
    /// The bundled ASR model id (folder name under Models/), also the WhisperKit transcriber default.
    static let bundledASRId = DefaultModels.bundledASRFolderName
    /// Default cleanup model id (matches `MLXTextCleaner.Configuration` default).
    static let defaultCleanupId = DefaultModels.cleanupModelId

    static let asr: [ModelDescriptor] = [
        ModelDescriptor(
            id: bundledASRId, kind: .asr, name: "Whisper large-v3-turbo",
            sizeText: "626 MB", ramText: "~1.5 GB", speedText: "RTF 0.10–0.15×",
            quality: "Great (ES + jargon)", languages: "Multilingual",
            note: "Default — downloaded on first run. Fast; does not support glossary prompt "
                + "biasing (Layer 0).",
            bundled: true
        ),
        ModelDescriptor(
            id: "openai_whisper-large-v3", kind: .asr, name: "Whisper large-v3",
            sizeText: "~1.5 GB", ramText: "~3 GB", speedText: "RTF ~0.3–0.5× (est.)",
            quality: "Best", languages: "Multilingual",
            note: "Downloadable. Conditions on prompts reliably → could re-enable Layer 0 biasing.",
            bundled: false
        ),
        ModelDescriptor(
            id: "openai_whisper-small", kind: .asr, name: "Whisper small",
            sizeText: "~250 MB", ramText: "~0.7 GB", speedText: "RTF ~0.05× (est.)",
            quality: "Lower", languages: "Multilingual",
            note: "Download required (Phase 2). For low-resource machines.",
            bundled: false
        ),
    ]

    static let cleanup: [ModelDescriptor] = [
        ModelDescriptor(
            id: defaultCleanupId, kind: .cleanup, name: "Qwen2.5 7B Instruct (4-bit)",
            sizeText: "~4.3 GB", ramText: "~4–5 GB", speedText: "~65 tok/s",
            quality: "Best cleanup", languages: "ES / EN",
            note: "Benchmarked. Resident while the app runs.",
            bundled: false
        ),
        ModelDescriptor(
            id: "mlx-community/Qwen2.5-3B-Instruct-4bit", kind: .cleanup,
            name: "Qwen2.5 3B Instruct (4-bit)",
            sizeText: "~1.9 GB", ramText: "~2 GB", speedText: "~100 tok/s (est.)",
            quality: "Good, lighter", languages: "ES / EN",
            note: "Faster and lighter; slightly weaker self-correction. Downloads on first use.",
            bundled: false
        ),
        ModelDescriptor(
            id: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", kind: .cleanup,
            name: "Qwen2.5 1.5B Instruct (4-bit)",
            sizeText: "~1 GB", ramText: "~1.2 GB", speedText: "~150 tok/s (est.)",
            quality: "Basic", languages: "ES / EN",
            note: "Smallest; fastest. May over/under-correct. Downloads on first use.",
            bundled: false
        ),
    ]

    static func cleanupModel(id: String) -> ModelDescriptor? { cleanup.first { $0.id == id } }
}
