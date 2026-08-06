import AppKit
import ChacharCore
import Combine
import SwiftUI

/// A small floating pill, bottom-centre of the active screen, that makes the app's three
/// otherwise-invisible waits explicit:
///
/// 1. **Loading** — the speech model is read from disk and warmed at launch (seconds on a cold
///    boot; see docs/latency.md), during which a push-to-talk press would go nowhere.
/// 2. **Listening** — the microphone is open, with a live level meter so you can see that your
///    voice is actually arriving (macOS's orange mic dot only says the mic is *on*).
/// 3. **Working** — the key is released and the pipeline is transcribing (and optionally cleaning
///    up) before the text appears.
///
/// It shows *state*, never dictated text: an earlier HUD previewed the transcription and got in
/// the way, which is why it was disabled. Keeping content out is what lets this one stay small.
///
/// The panel never takes focus (`.nonactivatingPanel`, never made key) and never takes clicks
/// (`ignoresMouseEvents`): the whole app depends on the frontmost app *staying* frontmost, since
/// that is where the text gets pasted.
@MainActor
final class StatusOverlayController: ObservableObject {

    /// Bars in the level meter. At `meterInterval` each, this window holds ~0.9 s of history.
    static let barCount = 27
    /// How often the meter samples the microphone. 30 Hz is smooth to the eye and costs orders of
    /// magnitude less than the audio it draws.
    private static let meterInterval = Duration.milliseconds(33)
    /// Grace period before the model-loading pill appears, so a load that resolves immediately
    /// (a warm relaunch, a model switch that fails fast) doesn't flash a pill on screen.
    private static let modelLoadingGrace = Duration.milliseconds(350)

    /// Panel geometry. Fixed on purpose: the window is transparent and click-through, so an
    /// oversized frame costs nothing, and *not* resizing per state removes a whole class of
    /// jitter (SwiftUI reports its new fitting size a runloop turn after the state changes). The
    /// pill lays itself out at the bottom of this frame — see ``StatusOverlayView``, whose bottom
    /// inset plus tallest pill must stay under this height.
    private static let panelSize = NSSize(width: 560, height: 200)

    @Published private(set) var content: OverlayContent?
    /// Rolling level history, oldest → newest, feeding the meter's bars.
    @Published private(set) var levels: [CGFloat] =
        Array(repeating: 0, count: StatusOverlayController.barCount)

    /// Master switch (the Settings toggle). Assigned by `AppDelegate` rather than read from the
    /// store: `applySettings` runs inside the `@Published` publisher's `willSet`, where the store
    /// still holds the *old* value (same trap as `makeHotkeyMonitor`).
    var isEnabled: Bool = true {
        didSet { if isEnabled != oldValue { render() } }
    }

    /// Current microphone loudness, 0…1 (wired to `MicrophoneCapture.inputLevel`).
    private let level: () -> Float
    /// True when another surface is already showing model progress — the first-run setup guide has
    /// its own download row, and stacking the pill on top of it just says the same thing twice.
    private let isSuppressed: () -> Bool

    private var panel: NSPanel?
    private var isShown = false
    /// Live pipeline state. Terminal outcomes never land here; they become a `notice` instead.
    private var phase: DictationPhase = .idle
    private var modelStatus: RuntimeStatus.ASRModel
    /// True once the model has been busy for longer than `modelLoadingGrace` — see `startModelGrace`.
    private var modelGraceElapsed = false
    private var modelGraceTask: Task<Void, Never>?
    private var notice: OverlayContent?
    private var noticeTask: Task<Void, Never>?
    /// Text that had nowhere to be inserted, held until the user copies or discards it. Outranks
    /// everything else on screen: it is the last chance to rescue words that would otherwise only
    /// exist in the history log.
    private var recovery: String?
    private var meterTask: Task<Void, Never>?
    private var smoothedLevel: CGFloat = 0
    private var statusCancellable: AnyCancellable?

    init(status: RuntimeStatus,
         level: @escaping () -> Float,
         isSuppressed: @escaping () -> Bool) {
        self.level = level
        self.isSuppressed = isSuppressed
        self.modelStatus = status.asr
        // `@Published` emits from `willSet`, so `status.asr` still holds the previous value when
        // this fires — take the state from the emission, never by reading back.
        statusCancellable = status.$asr.sink { [weak self] value in
            self?.setModelStatus(value)
        }
    }

    // MARK: Inputs

    /// Start observing and show whatever is already true (at launch: the speech model loading).
    /// Called once from `applicationDidFinishLaunching`; creating the panel this early also means
    /// the first push-to-talk press pays no window-creation cost.
    func start() {
        if Self.isBusy(modelStatus) { startModelGrace() }
        render()
    }

    /// Follow the dictation pipeline. Live phases stay on screen until the next one arrives;
    /// outcomes become a self-dismissing notice.
    func setPhase(_ next: DictationPhase) {
        switch next {
        case .idle, .listening, .transcribing, .cleaningUp:
            // A new dictation supersedes the previous one's outcome: pressing again while
            // "Inserted" fades must show the meter immediately. That includes an unrescued
            // recovery card — dictating again is a deliberate move on, and the text it held is
            // still in the history log.
            clearNotice()
            recovery = nil
            phase = next
            render()
        case .notInserted(let text):
            phase = .idle
            clearNotice()
            recovery = text
            render()
        case .finished:
            settle(.notice("Inserted", .success), for: .milliseconds(900))
        case .noSpeech:
            settle(.notice("No speech detected", .info), for: .milliseconds(1600))
        case .cancelled:
            settle(.notice("Cancelled", .info), for: .milliseconds(1000))
        case .failed(let reason):
            settle(.notice(reason, .failure), for: .seconds(4))
        }
    }

    /// Show a one-off message (a mic that won't open, a model that won't download). Errors the
    /// app used to only write to the log now have somewhere visible to land.
    func flash(_ message: String, kind: OverlayNotice = .failure) {
        settle(.notice(message, kind), for: .seconds(4))
    }

    /// Re-evaluate what should be on screen. Needed when something *outside* this controller
    /// changes the answer — the setup guide opening or closing over a model download.
    func refresh() {
        render()
    }

    // MARK: Recovery card actions

    /// Put the rescued text on the clipboard so the user can paste it wherever they meant to.
    ///
    /// Unlike the dictation path, this leaves it there: no save/restore, and no concealed-type
    /// marker — the user asked for this text to be in their clipboard, so clipboard managers may
    /// have it like any other copy.
    func copyRecovery() {
        guard let recovery else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(recovery, forType: .string)
        self.recovery = nil
        settle(.notice("Copied to the clipboard", .success), for: .milliseconds(1400))
    }

    /// Throw the rescued text away. It remains in the history log, which is where a change of mind
    /// gets served.
    func discardRecovery() {
        recovery = nil
        render()
    }

    // MARK: State machine

    /// End the current dictation and leave a self-dismissing notice behind.
    private func settle(_ content: OverlayContent, for duration: Duration) {
        phase = .idle
        notice = content
        render()
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.notice == content else { return }
            self.notice = nil
            self.render()
        }
    }

    private func clearNotice() {
        noticeTask?.cancel()
        noticeTask = nil
        notice = nil
    }

    /// The single place that decides what is on screen. Priority: unrescued text → a notice (the
    /// most recent thing that happened) → the live pipeline → the model still loading → nothing.
    ///
    /// The recovery card outranks the master switch too: turning the overlay off is a preference
    /// about *status*, and swallowing words the user hasn't recovered yet would be a data loss
    /// dressed up as a setting.
    private func render() {
        if let recovery { return apply(.recovery(recovery)) }
        guard isEnabled else { return hide() }
        if let notice { return apply(notice) }
        switch phase {
        case .listening:    return apply(.listening)
        case .transcribing: return apply(.working("Transcribing…"))
        case .cleaningUp:   return apply(.working("Cleaning up…"))
        default:            break
        }
        guard !isSuppressed(), modelGraceElapsed, let loading = modelContent() else { return hide() }
        apply(loading)
    }

    /// The pill for the ASR model's state, or nil when it needs no explanation.
    ///
    /// `.unavailable` deliberately returns nil: `AppDelegate` reports that failure through
    /// `flash(_:)` with the actual reason (which download or load failed), and a permanent
    /// "unavailable" pill would sit on the screen forever with less to say.
    private func modelContent() -> OverlayContent? {
        switch modelStatus {
        case .loading:
            return .working("Loading the speech model…")
        case .downloading(let fraction):
            return .progress("Downloading the speech model… \(Int(fraction * 100))%", fraction)
        case .ready, .unavailable:
            return nil
        }
    }

    // MARK: Model-loading grace period

    private static func isBusy(_ status: RuntimeStatus.ASRModel) -> Bool {
        switch status {
        case .loading, .downloading: true
        case .ready, .unavailable: false
        }
    }

    private func setModelStatus(_ status: RuntimeStatus.ASRModel) {
        let wasBusy = Self.isBusy(modelStatus)
        modelStatus = status
        switch (wasBusy, Self.isBusy(status)) {
        case (false, true): startModelGrace()
        case (_, false): cancelModelGrace()
        case (true, true): break // still the same wait (a download ticking) — don't restart it
        }
        render()
    }

    /// Hold the model pill back briefly, so a load that resolves at once never flashes on screen.
    ///
    /// The wait is timed from when the model *became* busy, not from the last update: a download
    /// reports progress many times a second, and re-arming the timer on each report would push the
    /// pill past the end of the very download it exists to explain.
    private func startModelGrace() {
        modelGraceElapsed = false
        modelGraceTask?.cancel()
        modelGraceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.modelLoadingGrace)
            guard !Task.isCancelled, let self else { return }
            self.modelGraceElapsed = true
            self.render()
        }
    }

    private func cancelModelGrace() {
        modelGraceTask?.cancel()
        modelGraceTask = nil
        modelGraceElapsed = false
    }

    // MARK: Panel

    /// Put `content` on screen, bringing the panel up if it isn't already.
    private func apply(_ content: OverlayContent) {
        let wasInteractive = self.content?.isInteractive ?? false
        self.content = content
        if case .listening = content { startMeter() } else { stopMeter() }
        let panel = ensurePanel()
        // The two layouts need different windows: a big click-through sheet for the pill, a
        // click-taking window sized to the card. Re-lay-out whenever we cross between them.
        if !isShown || wasInteractive != content.isInteractive {
            panel.ignoresMouseEvents = !content.isInteractive
            position(panel)
        }
        guard !isShown else { return }
        panel.orderFrontRegardless() // never `makeKey`: that would steal focus from the paste target
        isShown = true
    }

    private func hide() {
        stopMeter()
        guard isShown else { return }
        isShown = false
        // Keep `content` as it is: the window fades out over ~0.2 s and should fade out showing
        // what it showed, not an empty frame.
        panel?.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let frame = NSRect(origin: .zero, size: Self.panelSize)
        let hosting = ClickableHostingView(rootView: StatusOverlayHost(model: self))
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]

        let panel = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        // Above normal and floating windows so it stays visible over full-screen apps — which is
        // where dictation is most often used.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false          // the pill draws its own, sized to the pill and not the frame
        panel.ignoresMouseEvents = true  // clicks belong to whatever is underneath
        panel.animationBehavior = .utilityWindow // system fade in/out
        // The app forces a light appearance app-wide (`NSApp.appearance` in AppDelegate); this is
        // a HUD and stays dark, so it reads the same over any app.
        panel.appearance = NSAppearance(named: .darkAqua)
        self.panel = panel
        return panel
    }

    /// Bottom-centre of the screen the user is actually looking at.
    ///
    /// `NSScreen.main` is "the screen holding the key window", which is meaningless for a menu-bar
    /// app that never has one — with several displays it would pin the pill to the wrong one. The
    /// pointer is the better proxy for where attention is.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let interactive = content?.isInteractive ?? false
        let size = interactive ? StatusOverlayView.cardPanelSize : Self.panelSize
        // Both layouts put their visible bottom edge the same distance above the Dock, so the
        // card appears where the pill was rather than jumping.
        let y = interactive
            ? visible.minY + StatusOverlayView.bottomInset - StatusOverlayView.cardMargin
            : visible.minY
        panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: y,
                              width: size.width, height: size.height),
                       display: true)
    }

    // MARK: Level meter

    private func startMeter() {
        guard meterTask == nil else { return }
        levels = Array(repeating: 0, count: Self.barCount)
        smoothedLevel = 0
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.meterInterval)
                guard !Task.isCancelled, let self else { return }
                self.sampleLevel()
            }
        }
    }

    private func stopMeter() {
        meterTask?.cancel()
        meterTask = nil
    }

    /// Push one reading onto the meter's history.
    ///
    /// The mic delivers a buffer every ~85 ms while this samples every 33 ms, so raw readings
    /// arrive as a staircase. Fast attack + slow release turns that into a voice-shaped envelope:
    /// the bars jump on a syllable and ease back down, instead of stepping.
    private func sampleLevel() {
        let target = CGFloat(level())
        smoothedLevel += (target - smoothedLevel) * (target > smoothedLevel ? 0.55 : 0.18)
        var next = levels // one assignment = one SwiftUI update per tick, not two
        next.removeFirst()
        next.append(smoothedLevel)
        levels = next
    }
}

/// The only thing in the overlay that observes: it turns the controller's published state into the
/// plain values ``StatusOverlayView`` renders, keeping the view itself free of dependencies (and
/// therefore renderable in isolation).
private struct StatusOverlayHost: View {
    @ObservedObject var model: StatusOverlayController

    var body: some View {
        StatusOverlayView(content: model.content,
                          levels: model.levels,
                          onCopy: { model.copyRecovery() },
                          onDiscard: { model.discardRecovery() })
    }
}

/// A hosting view that acts on the very first click.
///
/// AppKit normally spends the first click on an inactive window just to focus it. This panel is
/// deliberately never key — focus belongs to whatever app the user is typing into — so *every*
/// click on it is a first click, and without this the recovery card's buttons would need two.
private final class ClickableHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    required init(rootView: Content) { super.init(rootView: rootView) }
}
