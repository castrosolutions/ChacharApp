import Foundation

/// Where one push-to-talk dictation is, right now.
///
/// ``DictationController`` already reports a human-readable status line (`onStatus`) for the
/// menu-bar item; this is the same journey expressed as *data*, so on-screen UI can react to the
/// pipeline without pattern-matching English strings. The two are always emitted together.
///
/// The cases split into two kinds: `listening` / `transcribing` / `cleaningUp` describe work in
/// flight and last until the next phase arrives, while `finished` / `noSpeech` / `cancelled` /
/// `failed` are one-shot outcomes — a UI showing them decides how long they stay on screen.
public enum DictationPhase: Equatable, Sendable {
    /// Nothing in flight; the app is waiting for the push-to-talk key.
    case idle
    /// The microphone is open and the utterance is being recorded.
    case listening
    /// Key released: the ASR is running on the captured audio.
    case transcribing
    /// Layer 2 (local LLM) cleanup is running.
    case cleaningUp
    /// The final text was injected into the focused app.
    case finished
    /// The utterance yielded nothing to insert — a press too short to capture audio, or silence.
    case noSpeech
    /// The user cancelled with ESC: the audio was discarded, nothing was transcribed or injected.
    case cancelled
    /// The dictation failed, carrying a reason worth showing the user.
    case failed(String)
}
