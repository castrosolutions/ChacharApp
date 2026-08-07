import AppKit
import ApplicationServices
import AVFoundation
import ChacharCore
import SwiftUI

/// The step the setup guide is on. A wizard rather than one long checklist because the last step is
/// a live dictation the user has to *perform* — it needs the window to itself, and the three
/// preceding decisions are cheaper to make one at a time than as a wall of controls.
enum SetupStep: Int, CaseIterable {
    /// The two TCC grants and the one-time model download.
    case permissions
    /// Which language will be spoken (the app must not assume the author's).
    case language
    /// Push-to-talk vs. hands-free.
    case mode
    /// Say something and watch it land — the step that proves the other three worked.
    case practice

    var title: String {
        switch self {
        case .permissions: "Permissions"
        case .language: "Language"
        case .mode: "How you'll dictate"
        case .practice: "Try it"
        }
    }
}

/// How the hands-on final step is going. Drives the coach card next to the scratchpad.
enum PracticeState: Equatable {
    /// Nothing has happened yet — the coach is asking for the key.
    case waiting
    /// The mic is open right now.
    case listening
    /// Key released; the pipeline is running.
    case working
    /// The attempt produced nothing usable. Carries what to try differently; retryable.
    case failed(String)
    /// Words landed in the scratchpad. The only state that unlocks "Start Dictating".
    case done
}

/// Owns the first-run setup window (see ``OnboardingView``) and the live state behind it: the two
/// permission grants, the one-time model download, the two first-run choices (language and
/// push-to-talk mode), and the outcome of the hands-on practice dictation.
///
/// TCC grants have no change-notification API, so permissions are polled once per second while the
/// window is visible — each row flips to green the moment its requirement is met, without
/// relaunching.
///
/// `AppDelegate` opens it on launch whenever setup is incomplete (first run, a revoked permission,
/// a missing model) and the user can reopen it any time from the status menu ("Setup Guide…").
@MainActor
final class OnboardingController: NSObject, ObservableObject, NSWindowDelegate {
    /// Microphone TCC state, simplified for the view (keeps AVFoundation out of the SwiftUI layer).
    enum MicPermission { case undetermined, granted, denied }

    @Published private(set) var micPermission: MicPermission
    @Published private(set) var axTrusted = false
    @Published private(set) var step: SetupStep = .permissions
    @Published private(set) var practice: PracticeState = .waiting
    /// Whether the push-to-talk key is held right now, so the keyboard diagram can sink its cap.
    @Published private(set) var isKeyDown = false
    /// What the user has dictated (and may have typed) into the practice scratchpad. Bound to the
    /// editor, so the synthetic ⌘V lands here like it would in any other app.
    @Published var practiceText = ""
    /// Failed attempts at the practice step. After a couple of them the guide stops insisting —
    /// a broken mic or a noisy room shouldn't trap someone in the setup window forever.
    @Published private(set) var practiceAttempts = 0

    /// Re-attempt the first-run model download after a failure (wired by `AppDelegate` to its
    /// model loader, which falls back to downloading the default model).
    var retryModel: () -> Void = {}
    /// Fires once when the Microphone permission flips to granted, so the app can rebuild the
    /// stale pre-grant audio engine live — no relaunch, nothing visible to the user.
    var onMicGranted: () -> Void = {}
    /// Fires when the guide opens or closes. The floating status overlay steps aside while this
    /// window is up (it shows the same model download), and takes over again once it closes.
    var onVisibilityChanged: () -> Void = {}

    let store: SettingsStore
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

    /// Everything the app needs to dictate is in place. Note this is about *capability*, not about
    /// the wizard being finished — the practice step is a lesson, not a requirement, so a revoked
    /// permission reopens the guide but a skipped practice doesn't.
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

    /// The trigger the keyboard diagram should point at: the first enabled one, or Right ⌘ (the
    /// default) if the set is somehow empty.
    var primaryTrigger: PushToTalkTrigger {
        let triggers = store.settings.pttTriggers
        return PTTOption.catalog.first { triggers.contains($0.trigger) }?.trigger
            ?? .modifier(KeyCode.rightCommand)
    }

    // MARK: Window

    func show() {
        refresh()
        if window == nil {
            let hosting = NSHostingController(
                rootView: OnboardingView(controller: self, status: runtimeStatus, store: store))
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
        onVisibilityChanged()
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
        // `windowWillClose` runs while the window is still on screen, so `isVisible` would still
        // report true to an observer asking right now. Let them re-evaluate on the next turn.
        Task { @MainActor [weak self] in self?.onVisibilityChanged() }
    }

    // MARK: Navigation

    /// Whether the current step's requirement is met. Only the permissions step truly gates: the
    /// two choices have working defaults, and the practice step gates the finish button instead.
    var canAdvance: Bool {
        switch step {
        case .permissions: isComplete
        case .language, .mode, .practice: true
        }
    }

    func advance() {
        guard let next = SetupStep(rawValue: step.rawValue + 1) else { return finish() }
        step = next
        if step == .practice { resetPractice() }
    }

    func goBack() {
        guard let previous = SetupStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    // MARK: Practice step

    /// Follow the real dictation pipeline while the practice step is on screen.
    ///
    /// Wired by `AppDelegate` to the same `onPhase` stream the floating overlay listens to, so the
    /// practice run is an ordinary dictation in every respect — same mic, same model, same paste.
    /// Nothing here is simulated; that is the point of the step.
    func notePhase(_ phase: DictationPhase) {
        guard isVisible, step == .practice else { return }
        switch phase {
        case .listening:
            isKeyDown = true
            practice = .listening
        case .transcribing, .cleaningUp:
            isKeyDown = false
            practice = .working
        case .finished:
            isKeyDown = false
            practice = .done
        case .noSpeech:
            isKeyDown = false
            fail("I didn't catch anything — hold the key, speak for a couple of seconds, "
                 + "then let go.")
        case .notInserted:
            // The words were transcribed but the paste had nowhere to land: focus left the
            // scratchpad. Say that, rather than blaming the microphone.
            isKeyDown = false
            fail("Click inside the notepad above first, so the text has somewhere to land.")
        case .failed(let reason):
            isKeyDown = false
            fail(reason)
        case .cancelled:
            // ESC is a legitimate thing to try here; don't count it as a failed attempt.
            isKeyDown = false
            practice = .waiting
        case .idle:
            break
        }
    }

    private func fail(_ reason: String) {
        practiceAttempts += 1
        practice = .failed(reason)
    }

    private func resetPractice() {
        practice = .waiting
        practiceAttempts = 0
        isKeyDown = false
        practiceText = ""
    }

    /// Let the user move on without a successful practice run. Offered only after repeated
    /// failures — see ``practiceAttempts``.
    var canSkipPractice: Bool { practiceAttempts >= 2 }

    // MARK: Permissions

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
