import AppKit
import CoreGraphics

/// Inserts text into whatever application currently has keyboard focus.
@MainActor
public protocol TextInjector {
    func inject(_ text: String)
}

/// Universal injector: place the text on the pasteboard, synthesize ⌘V, then restore the user's
/// previous pasteboard contents.
///
/// This rides the standard paste path rather than the Accessibility text API, so it works in
/// virtually every app — native, Electron and web — where AX text fields are unreliable
/// (see decisions/0001 context and the project spec). Requires Accessibility permission to post
/// the synthetic key event (already needed for the global hotkey).
@MainActor
public final class PasteboardInjector: TextInjector {
    /// Delay before restoring the old pasteboard, giving the target app time to read the paste.
    private let restoreDelay: TimeInterval

    /// nspasteboard.org convention: marks the dictated text as concealed so clipboard managers
    /// (Alfred, Raycast, Maccy…) don't record everything the user dictates into their history.
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    public init(restoreDelay: TimeInterval = 0.2) {
        self.restoreDelay = restoreDelay
    }

    public func inject(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: Self.concealedType)
        let ourChangeCount = pasteboard.changeCount

        postCommandV()

        // Restore the user's clipboard after the target app has had time to paste — but only if
        // nobody else wrote to the pasteboard meanwhile (a copy in that window must win, not be
        // clobbered by our restore).
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(restoreDelay))
            guard pasteboard.changeCount == ourChangeCount else { return }
            restore(pasteboard, saved)
        }
    }

    // MARK: Pasteboard save / restore

    private func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        var items: [NSPasteboardItem] = []
        for original in pasteboard.pasteboardItems ?? [] {
            let copy = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            items.append(copy)
        }
        return items
    }

    private func restore(_ pasteboard: NSPasteboard, _ items: [NSPasteboardItem]) {
        pasteboard.clearContents()
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    // MARK: Synthetic ⌘V

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey = KeyCode.ansiV
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
