import Foundation

/// The capture surface the dictation pipeline drives: open/close the audio engine and bracket one
/// utterance's samples. `MicrophoneCapture` is the real implementation (AVAudioEngine); tests use
/// a fake so the pipeline can be exercised with no microphone, hardware or TCC involved (see
/// docs/testing.md, level 2).
public protocol AudioCapturing: Sendable {
    /// Open the engine and start capturing. Idempotent; throws when no usable input is available
    /// (e.g. the device is mid-switch).
    func start() throws
    /// Close the engine and stop capturing.
    func stop()
    /// Begin accumulating samples for one utterance (push-to-talk key down).
    func beginUtterance()
    /// Stop accumulating and return the utterance's samples (key up).
    func endUtterance() -> AudioSamples
}
