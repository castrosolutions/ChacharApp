import CoreAudio
import Foundation

/// A Core Audio input device as the user knows it: a stable UID — it survives reboots and
/// reconnects, unlike the numeric `AudioDeviceID`, so it is what gets persisted — and the name
/// macOS shows in System Settings → Sound.
public struct AudioInputDevice: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let uid: String
    public let name: String
    public var id: String { uid }

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Read-only queries over the machine's audio inputs. Stateless on purpose: devices come and go
/// (AirPods, USB mics, a docked display's mic), so every caller asks Core Audio afresh rather than
/// trusting a list that may be minutes old.
public enum AudioInputDevices {
    /// Every visible device that offers at least one input stream, in Core Audio's order.
    public static func all() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            guard hasInput(id), !isHidden(id), !isPrivateAggregate(id) else { return nil }
            return device(for: id)
        }
    }

    /// The input macOS currently routes to apps that don't choose one (System Settings → Sound →
    /// Input). This is what changes under you when AirPods connect.
    public static func systemDefault() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return device(for: id)
    }

    /// The live `AudioDeviceID` for a persisted UID, or nil when that device isn't connected.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { hasInput($0) && string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// Describe a live device, or nil if it vanished between listing and asking.
    public static func device(for id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return AudioInputDevice(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid)
    }

    /// Whether this is an app's private aggregate — notably the `CADefaultDeviceAggregate-<pid>-<n>`
    /// that `AVAudioEngine` builds around the default input and output when it follows the system
    /// default. It is not hidden, so it lists like a real mic, and it is what the engine's I/O unit
    /// reports as its current device; neither is anything a user should see.
    public static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        // Plain devices don't have the property at all (the call fails): not an aggregate.
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let composition = value?.takeRetainedValue() as? [String: Any] else { return false }
        return (composition[kAudioAggregateDeviceIsPrivateKey] as? NSNumber)?.boolValue ?? false
    }

    // MARK: Core Audio plumbing

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    /// Whether the device has input streams — output-only devices (speakers, HDMI) list too.
    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    /// Hidden devices are drivers' private plumbing (aggregate helpers), never meant to be picked.
    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    /// A CFString-valued property. Core Audio hands these back retained (+1), hence
    /// `takeRetainedValue`.
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
