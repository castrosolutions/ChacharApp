import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

/// Owns the first-run setup window (see ``OnboardingView``) and the live permission state behind
/// it. The window is a self-updating checklist: Microphone permission, Accessibility permission,
/// and the one-time speech-model download. TCC grants have no change-notification API, so both are
/// polled once per second while the window is visible — each row flips to green the moment its
/// requirement is met, without relaunching.
///
/// `AppDelegate` opens it on launch whenever setup is incomplete (first run, a revoked permission,
/// a missing model) and the user can reopen it any time from the status menu ("Setup Guide…").
@MainActor
final class OnboardingController: NSObject, ObservableObject, NSWindowDelegate {
    /// Microphone TCC state, simplified for the view (keeps AVFoundation out of the SwiftUI layer).
    enum MicPermission { case undetermined, granted, denied }

    @Published private(set) var micPermission: MicPermission
    @Published private(set) var axTrusted = false

    /// Re-attempt the first-run model download after a failure (wired by `AppDelegate` to its
    /// model loader, which falls back to downloading the default model).
    var retryModel: () -> Void = {}
    /// Fires once when the Microphone permission flips to granted, so the app can rebuild the
    /// stale pre-grant audio engine live — no relaunch, nothing visible to the user.
    var onMicGranted: () -> Void = {}

    private let store: SettingsStore
    let runtimeStatus: RuntimeStatus
    private var window: NSWindow?
    private var pollTask: Task<Void, Never>?

    init(store: SettingsStore, status: RuntimeStatus) {
        self.store = store
        self.runtimeStatus = status
        // Seed with the real status so the first refresh() can't mistake "already granted at
        // launch" for a fresh grant (which would fire onMicGranted spuriously).
        self.micPermission = Self.readMicPermission()
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Everything the app needs to dictate is in place.
    var isComplete: Bool {
        micPermission == .granted && axTrusted && runtimeStatus.asr == .ready
    }

    /// Short name of an enabled push-to-talk key (e.g. "Right ⌘"), for the "how to use" hint.
    var pttKeyName: String {
        let triggers = store.settings.pttTriggers
        guard let label = PTTOption.catalog.first(where: { triggers.contains($0.trigger) })?.label
        else { return "your push-to-talk key" }
        return label.components(separatedBy: " — ").first ?? label
    }

    func show() {
        refresh()
        if window == nil {
            let hosting = NSHostingController(
                rootView: OnboardingView(controller: self, status: runtimeStatus))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Set Up ChacharApp"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false // keep the instance so the guide can reopen
            win.delegate = self              // revert to accessory when the window closes
            win.center()
            window = win
        }
        // Surface as a regular app (Dock icon) while the guide is open — same pattern as Settings.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    /// "Start Dictating": record that setup finished so the guide stops auto-opening on launch.
    func finish() {
        store.settings.onboardingCompleted = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        pollTask?.cancel()
        pollTask = nil
        // Closing the window with everything green counts as finishing, button pressed or not.
        if isComplete { store.settings.onboardingCompleted = true }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Trigger the system Microphone prompt (first time) or open its Privacy pane (after a denial —
    /// macOS only shows the prompt once, so a re-grant has to happen in System Settings).
    func requestMicrophone() {
        if micPermission == .undetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
        } else {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    func openAccessibilitySettings() {
        openPrivacyPane("Privacy_Accessibility")
    }

    private func openPrivacyPane(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func refresh() {
        let wasGranted = micPermission == .granted
        micPermission = Self.readMicPermission()
        axTrusted = AXIsProcessTrusted()
        if !wasGranted, micPermission == .granted { onMicGranted() }
    }

    private static func readMicPermission() -> MicPermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.refresh()
            }
        }
    }
}
