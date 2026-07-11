import Foundation

/// The slice of the user settings the dictation pipeline reads, snapshotted fresh at each key
/// event so settings changes apply to the very next dictation. Kept separate from the app's full
/// `AppSettings` so `DictationController` can live in ChacharCore and be tested with plain values
/// (docs/testing.md, level 2).
public struct DictationOptions: Equatable, Sendable {
    /// Open the microphone only while the PTT key is held (vs. keeping it warm).
    public var micOnlyWhileDictating: Bool
    /// Layer 2 local-LLM cleanup on/off.
    public var cleanupEnabled: Bool
    /// Layer 1 fuzzy/phonetic glossary matching on/off.
    public var fuzzyGlossaryEnabled: Bool
    /// Layer 1 trailing-hallucination filter (end-of-audio "gracias") on/off.
    public var trailingHallucinationFilter: Bool
    /// Whether dictations are appended to the local history log.
    public var historyEnabled: Bool

    public init(micOnlyWhileDictating: Bool,
                cleanupEnabled: Bool,
                fuzzyGlossaryEnabled: Bool,
                trailingHallucinationFilter: Bool,
                historyEnabled: Bool) {
        self.micOnlyWhileDictating = micOnlyWhileDictating
        self.cleanupEnabled = cleanupEnabled
        self.fuzzyGlossaryEnabled = fuzzyGlossaryEnabled
        self.trailingHallucinationFilter = trailingHallucinationFilter
        self.historyEnabled = historyEnabled
    }
}

/// The application that will receive the injected text — bundle id for the consecutive-dictation
/// continuation heuristic, display name for the history log. Provided to `DictationController`
/// through a closure so ChacharCore never touches `NSWorkspace` and tests don't depend on the
/// test runner's frontmost app.
public struct FrontmostApp: Sendable {
    public let bundleID: String?
    public let name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }
}
