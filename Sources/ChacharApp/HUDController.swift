import AppKit

/// A small floating HUD panel that shows the latest transcription for a few seconds.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private var label: NSTextField?
    private var hideTask: Task<Void, Never>?

    func show(_ text: String) {
        let panel = ensurePanel()
        label?.stringValue = text
        position(panel)
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak panel] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { panel?.orderOut(nil) }
        }
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let frame = NSRect(x: 0, y: 0, width: 560, height: 96)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView(frame: frame)
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.autoresizingMask = [.width, .height]

        let label = NSTextField(wrappingLabelWithString: "")
        label.frame = effect.bounds.insetBy(dx: 18, dy: 14)
        label.autoresizingMask = [.width, .height]
        label.font = .systemFont(ofSize: 17, weight: .medium)
        label.textColor = .white
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        effect.addSubview(label)

        panel.contentView = effect
        self.panel = panel
        self.label = label
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 140))
    }
}
