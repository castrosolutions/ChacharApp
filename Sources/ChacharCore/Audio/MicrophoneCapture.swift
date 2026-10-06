@preconcurrency import AVFoundation
import AudioToolbox
import CoreMedia
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
/// Two capture paths. Following the system default (the norm) it is `AVAudioEngine`, whose input
/// node tracks the default device. A mic the user *pinned* is captured with an `AVCaptureSession`
/// on that device instead: forcing a non-default device into `AVAudioEngine` (via its I/O unit)
/// leaves the node reporting the old device's format — a tap with it receives nothing — and can
/// wedge AVFAudio's own I/O queue, hanging any caller that asks it for a format. A capture session
/// is Apple's API for "record from *this* device", and it hands back 16 kHz mono directly.
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
    /// The capture session while a pinned mic is recording (nil on the engine path).
    private var session: AVCaptureSession?
    /// Delegate queue for the session's sample buffers — serial, so appends stay in order.
    private let sessionQueue = DispatchQueue(label: "app.chachar.mic-session")
    private var sessionSink: SessionSink?

    /// Observer token for `.AVAudioEngineConfigurationChange` (see `init`).
    private var configChangeObserver: (any NSObjectProtocol)?
    /// Observer token for a pinned capture device being unplugged (see `init`).
    private var disconnectObserver: (any NSObjectProtocol)?
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
    /// Loudness of the most recent buffer (0…1), for the on-screen level meter. Guarded by
    /// `bufferLock` alongside the samples it is derived from: written on the RT thread, read from
    /// the main thread ~30×/s. One `Float` is a far shorter hold than the sample append next to it.
    private var level: Float = 0
    /// Whether this utterance has delivered a single non-zero sample. A live mic always carries
    /// some noise floor, so a stretch of exact zeros means the device is connected but dead — the
    /// built-in mic with the MacBook lid closed (Apple silicon cuts it in hardware), a Continuity
    /// iPhone mic that isn't awake. Guarded by `bufferLock`.
    private var heardSignal = false

    /// UID of the input the user pinned (see ``setPreferredInput(uid:)``); nil follows the system
    /// default. Guarded by `stateLock` — it is only read while (re)building the engine.
    private var preferredInputUID: String?
    /// The device the running engine actually captures from, for display. Its own lock, not
    /// `stateLock`: the overlay polls this ~30×/s from the main thread, and `stateLock` is held
    /// across `engine.start()`, which can take a few hundred ms on a Bluetooth mic.
    private let deviceLock = NSLock()
    private var activeInput: AudioInputDevice?

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
        // The session path's equivalent: a pinned mic unplugged mid-capture. Restart, which falls
        // back to the system default until it returns.
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil
        ) { [weak self] notification in
            guard let self, let device = notification.object as? AVCaptureDevice else { return }
            let uid = device.uniqueID
            self.configChangeQueue.async { self.handleDisconnect(uid: uid) }
        }
    }

    deinit {
        for observer in [configChangeObserver, disconnectObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
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

        // A pinned mic records through its own capture session (see the type's doc). When it
        // isn't connected — or its session won't open — fall back to the system default rather
        // than failing: a dictation from the "wrong" mic beats no dictation, and the overlay
        // names the one in use.
        if let uid = preferredInputUID {
            if let device = AVCaptureDevice(uniqueID: uid), device.isConnected {
                do {
                    try startSession(on: device)
                    return
                } catch {
                    chacharLog("capture session on \(device.localizedName) FAILED: \(error) — using the system default")
                }
            } else {
                chacharLog("preferred mic \(uid) not connected — using the system default")
            }
        }

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
        // Following the system default, the I/O unit reports the engine's private aggregate rather
        // than the mic inside it — name the default input instead, which is what is recording.
        let current = currentDevice(of: input).flatMap { id in
            AudioInputDevices.isPrivateAggregate(id)
                ? AudioInputDevices.systemDefault()
                : AudioInputDevices.device(for: id)
        }
        setActiveInput(current)
    }

    /// Record from one specific device. The output asks for Whisper's format outright (16 kHz mono
    /// Float32), so no converter is involved; `collect(_:)` re-checks each buffer anyway.
    private func startSession(on device: AVCaptureDevice) throws {
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw MicrophoneCaptureError.inputUnavailable }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let sink = SessionSink { [weak self] buffer in self?.receive(buffer) }
        output.setSampleBufferDelegate(sink, queue: sessionQueue)
        guard session.canAddOutput(output) else { throw MicrophoneCaptureError.inputUnavailable }
        session.addOutput(output)
        session.startRunning() // blocks until running (~50 ms; longer while Bluetooth reroutes)
        guard session.isRunning else { throw MicrophoneCaptureError.inputUnavailable }
        self.session = session
        sessionSink = sink
        isRunning = true
        setActiveInput(AudioInputDevice(uid: device.uniqueID, name: device.localizedName))
    }

    private func setActiveInput(_ device: AudioInputDevice?) {
        deviceLock.lock(); activeInput = device; deviceLock.unlock()
    }

    /// The device the input node's I/O unit is really bound to.
    private func currentDevice(of input: AVAudioInputNode) -> AudioDeviceID? {
        guard let unit = input.audioUnit else { return nil }
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// The actual stop sequence. Callers must hold `stateLock` and have checked `isRunning`.
    private func stopLocked() {
        if let session {
            session.stopRunning()
            self.session = nil
            sessionSink = nil
        } else {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
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
        guard engineID == ObjectIdentifier(engine), isRunning, session == nil else { return }
        stopLocked()
        // Best effort: if the device is still settling this throws and the mic stays closed until
        // the next push-to-talk press() retries — press() always attempts start(), in both mic
        // modes, so a failed rebuild here is recovered on the next dictation. If the restart
        // itself triggers another configuration change (format renegotiation), that posts a new
        // notification and we converge in a pass or two.
        try? startLocked()
    }

    /// A pinned mic went away while its session was recording: restart, which falls back to the
    /// system default (and picks the pinned mic up again on a later start once it is back). Runs
    /// on `configChangeQueue`.
    private func handleDisconnect(uid: String) {
        stateLock.lock(); defer { stateLock.unlock() }
        guard isRunning, session != nil, uid == preferredInputUID else { return }
        chacharLog("pinned mic disconnected — falling back to the system default")
        stopLocked()
        try? startLocked() // a failure here is retried by the next press(), as for the engine
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

    /// Choose the input device: a UID pins that mic, nil follows the system default. Persisting it
    /// is what stops the app from silently switching to AirPods the moment they connect.
    ///
    /// Takes effect immediately when the mic is open — including mid-utterance: collection is
    /// independent of the capture path, so the words before and after the swap land in the same
    /// dictation. Blocks for the restart; call it off the main thread. Throws if the restart
    /// fails, leaving the mic closed until the next `start()` retries.
    public func setPreferredInput(uid: String?) throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard uid != preferredInputUID else { return }
        preferredInputUID = uid
        guard isRunning else { return } // the next start() picks it up
        stopLocked()
        try startLocked()
    }

    /// The device the engine last captured from (nil until the first successful start). Kept
    /// after a stop, so a closed mic still reports the one it will most likely reopen.
    public var currentInput: AudioInputDevice? {
        deviceLock.lock(); defer { deviceLock.unlock() }
        return activeInput
    }

    /// Begin accumulating samples for one utterance (call on push-to-talk key down).
    public func beginUtterance() {
        bufferLock.lock()
        collected.removeAll(keepingCapacity: true)
        isCollecting = true
        heardSignal = false
        level = 0
        bufferLock.unlock()
    }

    /// Stop accumulating and return the captured 16 kHz mono samples (call on key up).
    public func endUtterance() -> AudioSamples {
        bufferLock.lock()
        isCollecting = false
        let values = collected
        collected.removeAll(keepingCapacity: true)
        level = 0
        bufferLock.unlock()
        return AudioSamples(values: values, sampleRate: Int(Self.targetSampleRate))
    }

    /// Loudness of the most recent buffer, 0…1 (see ``AudioLevelMeter``). Drives the recording
    /// indicator's level meter; 0 whenever no utterance is being collected.
    public var inputLevel: Float {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return level
    }

    /// True once the current utterance has collected `minimumSeconds` of audio that is all exact
    /// zeros — a device sending digital silence (see `heardSignal`), worth telling the user about
    /// while they're still speaking into it.
    public func isSendingSilence(after minimumSeconds: Double = 0.6) -> Bool {
        bufferLock.lock(); defer { bufferLock.unlock() }
        return isCollecting && !heardSignal
            && Double(collected.count) >= minimumSeconds * Self.targetSampleRate
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
        collect(UnsafeBufferPointer(start: channel[0], count: frames))
    }

    /// Called on `sessionQueue` for each buffer the pinned mic's capture session delivers.
    private func receive(_ sampleBuffer: CMSampleBuffer) {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mSampleRate == Self.targetSampleRate, format.mChannelsPerFrame == 1,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32
        else {
            chacharLog("capture session delivered an unexpected format — buffer dropped")
            return
        }
        var bufferList = AudioBufferList()
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &bufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr, let data = bufferList.mBuffers.mData else { return }
        let count = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        withExtendedLifetime(block) {
            collect(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
    }

    /// Keep one chunk of 16 kHz mono audio, from either capture path.
    private func collect(_ samples: UnsafeBufferPointer<Float>) {
        // Measure the same converted samples we keep, so the meter shows exactly what the ASR
        // will hear (a stale level after the last buffer would keep the bars twitching after the
        // key is released).
        let measured = AudioLevelMeter.level(of: samples)

        bufferLock.lock()
        if isCollecting {
            collected.append(contentsOf: samples)
            level = measured
            if !heardSignal, samples.contains(where: { $0 != 0 }) { heardSignal = true }
        }
        bufferLock.unlock()
    }
}

/// Receives a capture session's sample buffers and hands them to `MicrophoneCapture`. A separate
/// object because the delegate must be an `NSObject`, which `MicrophoneCapture` isn't.
private final class SessionSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let onBuffer: (CMSampleBuffer) -> Void

    init(onBuffer: @escaping (CMSampleBuffer) -> Void) {
        self.onBuffer = onBuffer
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onBuffer(sampleBuffer)
    }
}
