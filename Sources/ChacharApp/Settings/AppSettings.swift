import ChacharCore
import Foundation

/// All user-configurable options, persisted as a single JSON blob by ``SettingsStore``.
///
/// Defaults are tuned for a fresh install: Right ⌘ as the push-to-talk trigger (universal across
/// keyboards), Spanish ASR, cleanup off, history on.
struct AppSettings: Codable, Equatable, Sendable {
    /// Layer 2 local-LLM cleanup on/off.
    var cleanupEnabled: Bool = false
    /// Active push-to-talk triggers. Default: Right ⌘ (universal — works on external keyboards
    /// whose function row is intercepted, e.g. MX Keys). F7 stays available in the settings catalog
    /// as an opt-in. At least one trigger is always kept (the UI enforces this).
    var pttTriggers: Set<PushToTalkTrigger> = [.modifier(KeyCode.rightCommand)]
    /// Hands-free mode: press once to start recording, press again to stop. Default false =
    /// classic push-to-talk (record only while the key is held).
    var pttToggleMode: Bool = false
    /// When true, open the microphone only while the PTT key is held (macOS shows its "mic in use"
    /// indicator only while dictating). When false, keep the mic warm for the lowest latency — at
    /// the cost of the indicator staying on. Default true (privacy-friendly: the indicator only
    /// appears while you dictate); flip it off in Settings for the fastest, always-warm response.
    var micOnlyWhileDictating: Bool = true
    /// Spoken-language hint for the ASR. `nil` = auto-detect.
    var asrLanguage: String? = "es"
    /// Phonetic/fuzzy matching of glossary terms (Layer 1) — catches misheard jargon without an
    /// exact replacement rule. On by default; the escape hatch if it ever over-corrects.
    var fuzzyGlossaryEnabled: Bool = true
    /// Strip a trailing hallucinated phrase (e.g. a stray "gracias"/"thank you") that Whisper emits
    /// on near-silent audio tails. Conservative (only an isolated final clause). On by default; the
    /// escape hatch if you routinely end dictations with a real standalone "gracias".
    var trailingHallucinationFilter: Bool = true
    /// Active cleanup model id. Read-only in the UI for now; switching models is Epic B.
    var cleanupModelId: ModelId = DefaultModels.cleanupModelId
    /// Record each dictation to the local history log.
    var historyEnabled: Bool = true
    /// Keep only the most recent N dictations (0 = unlimited).
    var historyRetentionLimit: Int = 0
    /// Active ASR model folder. Empty = the default turbo model (resolved at runtime); otherwise an
    /// absolute path to a downloaded or imported model folder.
    var asrModelPath: String = ""
    /// Where the default turbo model was auto-downloaded on first run (empty until then). Distinct
    /// from `asrModelPath`: `asrModelPath == ""` still means "use the default turbo"; this just
    /// remembers where that default lives once downloaded so a distributed build never re-fetches it.
    var defaultASRModelPath: String = ""
    /// Non-bundled ASR models the user has added (downloaded or imported), so they appear in the
    /// Models tab and can be re-selected.
    var installedASRModels: [InstalledASRModel] = []
    /// Whether the first-run setup guide was completed (or dismissed with everything green). The
    /// guide still auto-opens on launch if a requirement is missing again (a revoked permission, a
    /// deleted model) regardless of this flag.
    var onboardingCompleted: Bool = false

    init() {}

    /// Resilient decoding: any key missing from the stored blob falls back to its default instead of
    /// failing the whole decode. Without this, adding a new setting would silently reset *all* of a
    /// user's settings after an update (synthesized Codable throws on a missing non-optional key).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        cleanupEnabled = try container.decodeIfPresent(Bool.self, forKey: .cleanupEnabled) ?? defaults.cleanupEnabled
        pttTriggers = try container.decodeIfPresent(Set<PushToTalkTrigger>.self, forKey: .pttTriggers) ?? defaults.pttTriggers
        pttToggleMode = try container.decodeIfPresent(Bool.self, forKey: .pttToggleMode) ?? defaults.pttToggleMode
        micOnlyWhileDictating = try container.decodeIfPresent(Bool.self, forKey: .micOnlyWhileDictating) ?? defaults.micOnlyWhileDictating
        // asrLanguage is itself optional (nil = auto-detect), so distinguish "absent" from "null".
        asrLanguage = container.contains(.asrLanguage)
            ? try container.decode(String?.self, forKey: .asrLanguage)
            : defaults.asrLanguage
        fuzzyGlossaryEnabled = try container.decodeIfPresent(Bool.self, forKey: .fuzzyGlossaryEnabled) ?? defaults.fuzzyGlossaryEnabled
        trailingHallucinationFilter = try container.decodeIfPresent(Bool.self, forKey: .trailingHallucinationFilter) ?? defaults.trailingHallucinationFilter
        cleanupModelId = try container.decodeIfPresent(String.self, forKey: .cleanupModelId) ?? defaults.cleanupModelId
        historyEnabled = try container.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? defaults.historyEnabled
        historyRetentionLimit = try container.decodeIfPresent(Int.self, forKey: .historyRetentionLimit) ?? defaults.historyRetentionLimit
        asrModelPath = try container.decodeIfPresent(String.self, forKey: .asrModelPath) ?? defaults.asrModelPath
        defaultASRModelPath = try container.decodeIfPresent(String.self, forKey: .defaultASRModelPath) ?? defaults.defaultASRModelPath
        installedASRModels = try container.decodeIfPresent([InstalledASRModel].self, forKey: .installedASRModels) ?? defaults.installedASRModels
        onboardingCompleted = try container.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? defaults.onboardingCompleted
    }
}

/// A non-bundled ASR model the user has added (downloaded into the managed dir, or imported in place).
struct InstalledASRModel: Codable, Equatable, Hashable, Identifiable {
    var name: String
    var path: String
    var imported: Bool
    var id: String { path }
}

/// A selectable push-to-talk trigger presented in the settings UI. The catalog is curated to the
/// keys that work reliably as global push-to-talk (function keys + right-hand modifiers); arbitrary
/// key-capture recording is deferred to a later polish pass.
struct PTTOption: Identifiable, Hashable {
    let id: String
    let label: String
    let trigger: PushToTalkTrigger

    static let catalog: [PTTOption] = [
        .init(id: "f7", label: "F7 — built-in keyboard", trigger: .key(KeyCode.f7)),
        .init(id: "f6", label: "F6", trigger: .key(KeyCode.f6)),
        .init(id: "f8", label: "F8", trigger: .key(KeyCode.f8)),
        .init(id: "rcmd", label: "Right ⌘ — works on external keyboards", trigger: .modifier(KeyCode.rightCommand)),
        .init(id: "ropt", label: "Right ⌥ Option", trigger: .modifier(KeyCode.rightOption)),
        .init(id: "rctrl", label: "Right ⌃ Control", trigger: .modifier(KeyCode.rightControl)),
        .init(id: "rshift", label: "Right ⇧ Shift", trigger: .modifier(KeyCode.rightShift)),
    ]
}

/// Language choices for the ASR hint, mapped to Whisper language codes (`nil` = auto-detect).
struct ASRLanguageOption: Identifiable, Hashable {
    let id: String
    let label: String
    let code: String?

    static let catalog: [ASRLanguageOption] = [
        .init(id: "es", label: "Spanish", code: "es"),
        .init(id: "en", label: "English", code: "en"),
        .init(id: "nl", label: "Dutch", code: "nl"),
        .init(id: "de", label: "German", code: "de"),
        .init(id: "fr", label: "French", code: "fr"),
        .init(id: "it", label: "Italian", code: "it"),
        .init(id: "pt", label: "Portuguese", code: "pt"),
        // Forcing a language beats auto-detect: on short phrases or code-switching the detector can
        // guess wrong and collapse the transcription. Auto-detect stays available for mixed use.
        .init(id: "auto", label: "Auto-detect", code: nil),
    ]

    static func label(for code: String?) -> String {
        catalog.first { $0.code == code }?.label ?? (code ?? "Auto-detect")
    }
}
