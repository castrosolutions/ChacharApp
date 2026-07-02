@preconcurrency import AVFoundation
import Foundation

/// Errors surfaced by `MicrophoneCapture`.
public enum MicrophoneCaptureError: Error, Sendable {
    case converterUnavailable
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
public final class MicrophoneCapture: @unchecked Sendable {
    /// Whisper's required sample rate (mirrors `AudioSamples.whisperSampleRate` as a `Double` for
    /// the audio format math).
    public static let targetSampleRate = Double(AudioSamples.whisperSampleRate)

    /// `var`, not `let`: an engine started before the Microphone TCC grant lands caches a bogus
    /// input format (0 Hz) and keeps delivering silence even after the user grants — the only cure
    /// is a fresh engine instance (see `reset()` and the self-heal in `start()`).
    private var engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var isRunning = false

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
    }

    /// Start the engine and install the input tap. Keeps the mic warm. Idempotent.
    public func start() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !isRunning else { return }
        var input = engine.inputNode
        var inputFormat = input.outputFormat(forBus: 0)

        // Self-heal: a 0 Hz / 0-channel input format means this engine was created while the mic
        // was not yet authorized (its first start is what triggers the TCC prompt). The stale
        // engine never recovers, so swap in a fresh one and re-read the real format.
        if inputFormat.sampleRate == 0 || inputFormat.channelCount == 0 {
            engine = AVAudioEngine()
            input = engine.inputNode
            inputFormat = input.outputFormat(forBus: 0)
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw MicrophoneCaptureError.converterUnavailable
        }
        self.converter = converter

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Stop the engine and remove the tap.
    public func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Tear the engine down and swap in a fresh instance. Call when the Microphone permission is
    /// granted mid-run: the engine whose start triggered the TCC prompt keeps delivering silence
    /// even after the grant (its input format/state is frozen pre-authorization), and only a new
    /// engine picks up the authorized input. The next `start()` rebuilds the tap and converter.
    public func reset() {
        stateLock.lock(); defer { stateLock.unlock() }
        if isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            isRunning = false
        }
        engine = AVAudioEngine()
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
