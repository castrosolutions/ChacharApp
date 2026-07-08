import ChacharCore
import CoreGraphics
import Foundation

/// Optional diagnostics: appends to ~/chachar-diag.log only when the env var CHACHARAPP_DEBUG is
/// set (off by default, so no disk writes during normal use).
func chacharLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["CHACHARAPP_DEBUG"] != nil else { return }
    let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("chachar-diag.log")
    guard let data = "\(message)\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        handle.write(data)
    } else {
        try? data.write(to: url)
    }
}

/// How a push-to-talk key is detected.
///
/// `Codable`/`Hashable` so the configured set of triggers can be persisted in the settings store
/// and bound to the settings UI.
enum PushToTalkTrigger: Equatable, Hashable, Codable {
    /// A normal key identified by keycode (e.g. F7 = 98). Detected via keyDown/keyUp and
    /// swallowed so it doesn't also fire its usual action.
    case key(CGKeyCode)
    /// A modifier key identified by keycode (e.g. Right Command = 54, Right Option = 61).
    /// Detected via flagsChanged and passed through (swallowing it would corrupt modifier state).
    case modifier(CGKeyCode)
}

/// Global push-to-talk hotkey via a `CGEventTap`, supporting several triggers at once so the
/// same gesture works across keyboards — e.g. F7 on the built-in keyboard plus a right-hand
/// modifier on an external keyboard whose function row is intercepted by its own software
/// (Logi Options+, etc.).
///
/// Requires Accessibility permission; `start()` returns `false` if the tap can't be created.
/// Used on the main thread only.
final class HotkeyMonitor {
    private let triggers: [PushToTalkTrigger]
    /// Hands-free: a press toggles the session on/off (release ignored). Default false = the press
    /// starts and the release stops (classic push-to-talk).
    private let toggleMode: Bool
    private let onPress: () -> Void
    private let onRelease: () -> Void
    /// Cancel gesture (ESC): abort the open session without delivering. Fires in both push-to-talk
    /// and hands-free (toggle) mode; the matching key release/toggle afterward becomes a no-op.
    private let onCancel: () -> Void
    /// The user pressed Return/Enter — a newline or a submitted prompt ends the current dictation
    /// "run", so the next dictation must not be joined to the previous one with a space.
    private let onContextBreak: () -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// The trigger currently holding the session open (nil = idle). Guarantees a matched
    /// press/release pair even if another trigger fires meanwhile.
    private var activeTrigger: PushToTalkTrigger?
    /// Physical down-state of modifier keys, to turn toggling flagsChanged events into press/release.
    private var modifiersDown: Set<CGKeyCode> = []

    init(triggers: [PushToTalkTrigger], toggleMode: Bool = false,
         onPress: @escaping () -> Void, onRelease: @escaping () -> Void,
         onCancel: @escaping () -> Void = {}, onContextBreak: @escaping () -> Void = {}) {
        self.triggers = triggers
        self.toggleMode = toggleMode
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel
        self.onContextBreak = onContextBreak
    }

    /// Create and enable the tap. Returns `false` if the OS denied it (missing permission).
    func start() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        // C-compatible (non-capturing) callback: recover `self` from the userInfo pointer.
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            chacharLog("hotkey tap FAILED to create — Accessibility not granted")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        chacharLog("hotkey tap started OK (triggers: \(triggers))")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap) // fully tear down the port so rebuilt monitors don't leak it
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS can disable a tap; re-enable it and pass the event through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .keyDown:
            // ESC while a session is open cancels it — in push-to-talk *and* hands-free (toggle)
            // mode, since `activeTrigger != nil` marks an open session in both. Swallow the ESC so
            // the focused app never sees it; when idle, ESC passes through untouched.
            if code == KeyCode.escape, activeTrigger != nil {
                cancelActiveSession()
                return nil
            }
            // Return/Enter ends a dictation "run": a newline or a submitted prompt (e.g. Claude Code
            // in the terminal) is not a continuation, so the next dictation must not inherit a
            // leading space. Notify and pass the key through untouched (the app still needs it).
            if code == KeyCode.returnKey || code == KeyCode.keypadEnter {
                onContextBreak()
            }
            if triggers.contains(.key(code)) {
                if toggleMode {
                    // Ignore auto-repeat keyDowns so holding the key doesn't flip on/off.
                    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                        toggleTrigger(.key(code))
                    }
                } else {
                    beginTrigger(.key(code))
                }
                return nil // swallow the PTT key
            }
        case .keyUp:
            if triggers.contains(.key(code)) {
                if !toggleMode { endTrigger(.key(code)) } // toggle mode ignores the release
                return nil
            }
        case .flagsChanged:
            chacharLog("flagsChanged code=\(code)")
            if triggers.contains(.modifier(code)) {
                // Read the modifier's *actual* down-state from the event's device-dependent flag
                // bit, not from event parity. A parity counter ("first event = down, next = up")
                // inverts permanently the moment the OS drops a single flagsChanged — which it does
                // whenever the tap is disabled by timeout (busy main thread) or coalesces events —
                // flipping push-to-talk so the mic opens on release and stays on at rest. Reading the
                // real bit is self-healing: a lost event just means the next one re-reads the truth.
                let isDown: Bool
                if let bit = Self.deviceFlag(forModifier: code) {
                    isDown = event.flags.contains(bit)
                } else {
                    // Modifiers without a device-dependent bit we map (Fn, Caps Lock): fall back to
                    // the parity heuristic. These are not realistic push-to-talk triggers.
                    isDown = !modifiersDown.contains(code)
                }
                if isDown { modifiersDown.insert(code) } else { modifiersDown.remove(code) }
                if toggleMode {
                    if isDown { toggleTrigger(.modifier(code)) } // toggle on press-down only
                } else {
                    if isDown { beginTrigger(.modifier(code)) } else { endTrigger(.modifier(code)) }
                }
                // Pass modifiers through (don't swallow).
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Hands-free press: start a session if idle, or end it if this same trigger owns it. The
    /// matching key release is ignored by the caller.
    private func toggleTrigger(_ trigger: PushToTalkTrigger) {
        if activeTrigger == nil {
            beginTrigger(trigger)
        } else if activeTrigger == trigger {
            endTrigger(trigger)
        }
    }

    private func beginTrigger(_ trigger: PushToTalkTrigger) {
        guard activeTrigger == nil else { return } // ignore auto-repeat / a second trigger
        activeTrigger = trigger
        chacharLog("PRESS \(trigger)")
        onPress()
    }

    private func endTrigger(_ trigger: PushToTalkTrigger) {
        guard activeTrigger == trigger else { return }
        activeTrigger = nil
        chacharLog("RELEASE \(trigger)")
        onRelease()
    }

    /// Abort the open session from a cancel gesture (ESC). Clearing `activeTrigger` first makes the
    /// trigger key's eventual release (push-to-talk) or next toggle (hands-free) a no-op — no
    /// `onRelease` fires — so the discarded utterance is never transcribed. The physical modifier's
    /// `modifiersDown` bookkeeping self-corrects on the next `flagsChanged`.
    private func cancelActiveSession() {
        guard let cancelled = activeTrigger else { return }
        activeTrigger = nil
        chacharLog("CANCEL (esc) \(cancelled)")
        onCancel()
    }

    /// The device-dependent modifier bit a `flagsChanged` event carries when the given left/right
    /// modifier keycode is physically down. These low bits (unlike the generic `.maskCommand` etc.)
    /// distinguish left from right, letting us read a modifier trigger's true state from `event.flags`
    /// instead of inferring it from event parity. Values are the NX device-dependent masks.
    private static func deviceFlag(forModifier keycode: CGKeyCode) -> CGEventFlags? {
        switch keycode {
        case 59: return CGEventFlags(rawValue: 0x0000_0001) // Left Control
        case 62: return CGEventFlags(rawValue: 0x0000_2000) // Right Control
        case 56: return CGEventFlags(rawValue: 0x0000_0002) // Left Shift
        case 60: return CGEventFlags(rawValue: 0x0000_0004) // Right Shift
        case 55: return CGEventFlags(rawValue: 0x0000_0008) // Left Command
        case 54: return CGEventFlags(rawValue: 0x0000_0010) // Right Command
        case 58: return CGEventFlags(rawValue: 0x0000_0020) // Left Option
        case 61: return CGEventFlags(rawValue: 0x0000_0040) // Right Option
        default: return nil                                 // Fn, Caps Lock, unknown
        }
    }
}
