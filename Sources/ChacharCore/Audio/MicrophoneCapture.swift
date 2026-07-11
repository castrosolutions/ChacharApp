@preconcurrency import AVFoundation
import Foundation

/// Errors surfaced by `MicrophoneCapture`.
public enum MicrophoneCaptureError: Error, Sendable {
    case converterUnavailable
    /// The input device reports no usable format (0 Hz / 0 channels) — typically mid-switch
    /// between devices (e.g. AirPods connecting) or before the Microphone TCC grant.
    case inputUnavailable
}

extension MicrophoneCaptureError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .converterUnavailable:
            return "the microphone's format can't be converted for transcription"
        case .inputUnavailable:
            return "no usable input device (it may still be switching — try again)"
        }
    }
}

/// Captures microphone audio via `AVAudioEngine` and converts it to 16 kHz mono Float — the
/// format Whisper expects.
///
/// The engine is kept running ("warm") so push-to-talk has no cold-start cost (see
/// docs/latency.md). Samples are only accumulated between `beginUtterance()` and
/// `endUtterance()`, so holding the engine open is cheap.
///
/// `@unchecked Sendable`: the audio tap fires on a real-time thread, so all shared state is
/// guarded by explicit locks rather than actor isolation (which can't be used on the RT thread).
public final class MicrophoneCapture: AudioCapturing, @unchecked Sendable {
    /// Whisper's required sample rate (mirrors `AudioSamples.whisperSampleRate` as a `Double` for
    /// the audio format math).
    public static let targetSampleRate = Double(AudioSamples.whisperSampleRate)

    /// `var`, not `let`: an `AVAudioEngine` instance caches its input device's format, and that
    /// cache goes stale whenever the environment changes under it — created before the Microphone
    /// TCC grant (bogus 0 Hz format, silence forever), or the default input device changed while
    /// stopped (AirPods in/out). Installing a tap with a stale format raises an Objective-C
    /// `NSException` that Swift cannot catch → SIGABRT. The only reliable cure is a fresh engine
    /// instance, which re-queries the hardware — `startLocked()` builds one on every start (see
    /// also `handleConfigurationChange(engineID:)`).
    private var engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var isRunning = false

    /// Observer token for `.AVAudioEngineConfigurationChange` (see `init`).
    private var configChangeObserver: (any NSObjectProtocol)?
    /// Serial queue where the configuration-change rebuild runs. The notification can be posted
    /// synchronously from inside `engine.start()` (Bluetooth mics renegotiate their format when
    /// capture actually begins), so the handler must hop queues — reacting inline would deadlock
    /// on `stateLock`.
    private let configChangeQueue = DispatchQueue(label: "app.chachar.mic-config-change")

    /// Guards the engine lifecycle (`isRunning`, `converter`, the engine itself). `start()`/
    /// `stop()` are called from the main thread (app startup, settings changes) *and* from the
    /// dictation controller's serial mic queue, so the transitions must be mutually exclusive —
    /// AVAudioEngine is not thread-safe. Never taken on the RT audio thread.
    private let stateLock = NSLock()

    // Accumulation state, guarded by `bufferLock` (touched from the RT audio thread).
    private let bufferLock = NSLock()
    private var isCollecting = false
    private var collected: [Float] = []

    public init() {
        // 16 kHz mono Float32, non-interleaved.
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        // A running engine stops itself — silently, no error — when its I/O configuration changes:
        // the default input device switches (AirPods connect/disconnect) or the device renegotiates
        // its format (Bluetooth mics drop to their hands-free profile the moment capture starts).
        // Without this observer the tap just stops firing and the utterance comes back empty
        // ("mic doesn't work"). Rebuild and restart so capture resumes mid-utterance.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self, let posted = notification.object as? AVAudioEngine else { return }
            let engineID = ObjectIdentifier(posted) // capture identity, not the non-Sendable engine
            self.configChangeQueue.async { self.handleConfigurationChange(engineID: engineID) }
        }
    }

    deinit {
        if let configChangeObserver {
            NotificationCenter.default.removeObserver(configChangeObserver)
        }
    }

    /// Start the engine and install the input tap. Keeps the mic warm. Idempotent.
    public func start() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        try startLocked()
    }

    /// The actual start sequence. Callers must hold `stateLock`.
    private func startLocked() throws {
        guard !isRunning else { return }

        // Always start from a FRESH engine: the previous instance's cached input format may be
        // stale (device switched while stopped, or pre-TCC-grant 0 Hz), and both AVAudioConverter
        // and installTap choke on a stale format — the latter with an uncatchable NSException
        // (SIGABRT). A new engine re-queries the hardware; its cost is a few ms, dwarfed by
        // `engine.start()` itself, so warm-mode latency is unaffected (start runs once) and
        // cold-mode latency is unchanged.
        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        // Even a fresh engine can report 0 Hz: mic not yet authorized (the first start is what
        // triggers the TCC prompt) or the input device is mid-switch. Fail cleanly — the next
        // start() retries with another fresh engine.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MicrophoneCaptureError.inputUnavailable
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicrophoneCaptureError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        // If this throws, the failed engine is simply abandoned: `isRunning` stays false, so
        // stop()/reset() won't touch it, and the next startLocked() replaces it with a fresh one.
        try engine.start()
        isRunning = true
    }

    /// The actual stop sequence. Callers must hold `stateLock` and have checked `isRunning`.
    private func stopLocked() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Reacts to `.AVAudioEngineConfigurationChange` (posted when the engine's input device or its
    /// format changes — e.g. AirPods becoming the default input, or a Bluetooth mic switching to
    /// its call profile once capture starts). At that point the engine has already stopped itself
    /// and its cached format is stale, so restarting the *same* instance risks the uncatchable
    /// `installTap` NSException — `startLocked()` swaps in a fresh engine instead. Runs on
    /// `configChangeQueue`.
    private func handleConfigurationChange(engineID: ObjectIdentifier) {
        stateLock.lock(); defer { stateLock.unlock() }
        // Ignore notifications from engines we've already replaced, and do nothing if we were
        // deliberately stopped (cold mode at rest) — the next start() builds fresh anyway.
        guard engineID == ObjectIdentifier(engine), isRunning else { return }
        stopLocked()
        // Best effort: if the device is still settling this throws and the mic stays closed until
        // the next push-to-talk press() retries — press() always attempts start(), in both mic
        // modes, so a failed rebuild here is recovered on the next dictation. If the restart
        // itself triggers another configuration change (format renegotiation), that posts a new
        // notification and we converge in a pass or two.
        try? startLocked()
    }

    /// Stop the engine and remove the tap.
    public func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard isRunning else { return }
        stopLocked()
    }

    /// Tear the capture down so the next `start()` re-queries the hardware. Call when the
    /// Microphone permission is granted mid-run: the engine whose start triggered the TCC prompt
    /// keeps delivering silence even after the grant (its input format/state is frozen
    /// pre-authorization). Stopping is enough — `startLocked()` always builds a fresh engine, so
    /// the next `start()` picks up the authorized input.
    public func reset() {
        stateLock.lock(); defer { stateLock.unlock() }
        if isRunning {
            stopLocked()
        }
        converter = nil
    }

    /// Begin accumulating samples for one utterance (call on push-to-talk key down).
    public func beginUtterance() {
        bufferLock.lock()
        collected.removeAll(keepingCapacity: true)
        isCollecting = true
        bufferLock.unlock()
    }

    /// Stop accumulating and return the captured 16 kHz mono samples (call on key up).
    public func endUtterance() -> AudioSamples {
        bufferLock.lock()
        isCollecting = false
        let values = collected
        collected.removeAll(keepingCapacity: true)
        bufferLock.unlock()
        return AudioSamples(values: values, sampleRate: Int(Self.targetSampleRate))
    }

    /// Whether the engine is currently running (mic warm).
    public var running: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return isRunning
    }

    /// One-shot holder so the `@Sendable` converter input block doesn't capture a mutable var
    /// or a non-Sendable buffer directly (Swift 6 strict concurrency).
    private final class ConverterInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var consumed = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    // Called on the real-time audio thread for each incoming buffer.
    private func process(_ buffer: AVAudioPCMBuffer) {
        bufferLock.lock()
        let collecting = isCollecting
        bufferLock.unlock()
        guard collecting, let converter else { return }

        // Convert this chunk to 16 kHz mono. Each tap buffer is converted independently; minor
        // boundary effects are irrelevant for ASR.
        let ratio = Self.targetSampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        // Hand the whole buffer to the converter exactly once.
        let inputBox = ConverterInput(buffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            guard !inputBox.consumed else {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputBox.consumed = true
            outStatus.pointee = .haveData
            return inputBox.buffer
        }

        var error: NSError?
        converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        guard error == nil, let channel = outBuffer.floatChannelData else { return }

        let frames = Int(outBuffer.frameLength)
        let samples = UnsafeBufferPointer(start: channel[0], count: frames)

        bufferLock.lock()
        if isCollecting {
            collected.append(contentsOf: samples)
        }
        bufferLock.unlock()
    }
}
