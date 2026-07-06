import AppKit
import ApplicationServices
import AVFoundation
import ChacharCleanupMLX
import ChacharCore
import Combine
import Sparkle

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let modelVariant = DefaultModels.bundledASRFolderName

    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private let capture = MicrophoneCapture()
    private let transcriber: any Transcriber
    private var hotkey: HotkeyMonitor?
    /// True while a background task is polling for the Accessibility grant to arm the hotkey live.
    private var accessibilityPolling = false
    /// True only while the first-run default-model download is in flight. Stale progress callbacks
    /// check it before writing `runtimeStatus.asr`, so they can't clobber the terminal states.
    private var downloadingDefaultModel = false
    private let hud = HUDController()
    /// On-screen text-preview pop-up. DISABLED per UX preference — it blocks the view and
    /// dictation already works well (esp. with Right ⌘). HUDController code is kept; flip to
    /// `true` to re-enable, or repurpose the HUD later (e.g. a subtle recording indicator).
    private let showHUD = false
    private let vocabulary = VocabularyStore(url: VocabularyStore.defaultURL())
    private let history = HistoryStore(url: HistoryStore.defaultURL())   // local dictation log
    private let cleaner: any TextCleaner = MLXTextCleaner()            // Layer 2 (local LLM)

    /// The push-to-talk dictation pipeline (capture → transcribe → correct → inject → log). Shares
    /// the same mic/transcriber/cleaner/stores and reports back through closures wired below.
    private lazy var dictation = makeDictationController()

    // Settings: persisted user choices + live runtime status, surfaced in the settings window.
    private let settingsStore = SettingsStore()
    private let runtimeStatus = RuntimeStatus()
    private let settingsWindow = SettingsWindowController()
    /// First-run setup guide (permissions + model download as a live checklist). Auto-shown while
    /// setup is incomplete; reopenable from the status menu.
    private lazy var onboarding = OnboardingController(store: settingsStore, status: runtimeStatus)
    private lazy var asrController = ASRModelController(
        store: settingsStore,
        status: runtimeStatus,
        activate: { [weak self] path in _ = await self?.loadASRModel(path: path) }
    )
    private var settingsCancellable: AnyCancellable?
    /// Last settings applied to the running app, for diffing incoming changes.
    private var appliedSettings = AppSettings()

    private enum CleanupState { case idle, loading, ready, failed }
    /// `.idle` until we know whether cleanup is enabled; only enabled cleanup loads a model.
    private var cleanupState: CleanupState = .idle

    /// Sparkle auto-updater — distribution builds only. release.sh writes the SUFeedURL +
    /// SUPublicEDKey Info.plist keys this checks for; make-app.sh (dev) omits them, so dev builds
    /// never check for or offer updates (contributors update via git, and the appcast's release
    /// bundle wouldn't match the dev bundle id anyway). Sparkle asks the user before enabling
    /// scheduled checks and before installing anything — no silent updates.
    private let updater: SPUStandardUpdaterController? =
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
            ? SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
            : nil

    override init() {
        transcriber = WhisperKitTranscriber(
            // Placeholder folder; startUp() reloads the real model — an existing copy, or one it
            // downloads on first run — before any transcription, so this initial value is inert.
            configuration: .init(
                modelFolder: AppDelegate.existingDefaultModelFolder(downloadedPath: "") ?? "",
                language: "es"
            )
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Force a light (Aqua) appearance app-wide: the UI is designed for a white background and
        // should not follow the system into dark mode. Covers the settings window, the status-bar
        // dropdown menu and any alerts. Set before building the menu so it renders light too.
        NSApp.appearance = NSAppearance(named: .aqua)
        if quitIfRunningFromDiskImage() { return }
        appliedSettings = settingsStore.settings
        setupStatusItem()
        setStatus("Starting…")
        onboarding.retryModel = { [weak self] in
            guard let self else { return }
            Task { await self.loadASRModel(path: self.settingsStore.settings.asrModelPath) }
        }
        onboarding.onMicGranted = { [weak self] in
            guard let self else { return }
            // The engine whose start triggered the TCC prompt stays silent even after the grant —
            // swap in a fresh one now so dictation works without relaunching. Invisible to the
            // user; if the mic runs warm, restart it immediately.
            self.capture.reset()
            if !self.settingsStore.settings.micOnlyWhileDictating { try? self.capture.start() }
        }
        // React to settings changes from the window (drop the initial current-value emission).
        settingsCancellable = settingsStore.$settings
            .dropFirst()
            .sink { [weak self] settings in self?.applySettings(settings) }
        Task { await startUp() }
    }

    /// Rescue path for when the menu-bar icon is hidden. macOS clips third-party status items when
    /// the bar runs out of room (a wide app menu, many extras, or the notch), and there's no API to
    /// force one visible — so the icon can silently disappear on some displays. Relaunching the app
    /// from Finder/Spotlight while it's already running sends a reopen event here; route it to a real
    /// window (which flips the app to `.regular`, so a Dock icon appears too). Dictation itself never
    /// needs the icon — the push-to-talk key works regardless — so this only restores access to the
    /// settings/setup surfaces. Returns true: we've handled the reopen ourselves.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if onboarding.isVisible {
            onboarding.show() // mid first-run setup — bring that guide back rather than jump to Settings
        } else {
            openSettings()
        }
        return true
    }

    private func startUp() async {
        chacharLog("startUp begin — AXIsProcessTrusted=\(AXIsProcessTrusted())")
        // 0) Setup guide, shown before the mic prompt fires so the user has context for it.
        showOnboardingIfNeeded()

        // 1) Touch the mic once to prompt the Microphone permission on first run. Keep it warm
        //    unless the user wants it open only while dictating (then release it right away).
        do {
            try capture.start()
            if settingsStore.settings.micOnlyWhileDictating { capture.stop() }
            chacharLog("mic engine started, running=\(capture.running)")
        } catch {
            setStatus("Mic error")
            chacharLog("mic start FAILED: \(error)")
            flash("Microphone unavailable: \(error.localizedDescription)")
        }

        // 2) Load + warm the active ASR model — the bundled turbo, or a downloaded/imported one —
        //    falling back to the bundled model if that fails. Push the user's language choice first.
        await transcriber.update(language: settingsStore.settings.asrLanguage)
        guard await loadASRModel(path: settingsStore.settings.asrModelPath) else {
            setStatus("Model error")
            flash("Could not load the speech model.")
            return
        }

        // 3) Global push-to-talk hotkey (needs Accessibility permission).
        if hotkey == nil { // may already exist if a settings change rebuilt it during startup
            let monitor = makeHotkeyMonitor(Array(settingsStore.settings.pttTriggers),
                                            toggleMode: settingsStore.settings.pttToggleMode)
            if monitor.start() {
                hotkey = monitor
                setStatus("Ready — hold your push-to-talk key")
            } else {
                setStatus("Needs Accessibility permission")
                promptAccessibility()
                startAccessibilityPolling() // arm the hotkey the moment the grant lands
            }
        }

        // 4) If cleanup is enabled, load + pre-warm the Layer 2 model in the background so the first
        //    push-to-talk pays no load/compile delay. If it's off, don't hold ~4–5 GB resident for a
        //    feature the user hasn't asked for — it loads on demand when they enable it.
        if settingsStore.settings.cleanupEnabled {
            Task { await loadCleanupModel(settingsStore.settings.cleanupModelId) }
        } else {
            cleanupState = .idle
            runtimeStatus.cleanupModel = .idle
        }
    }

    /// (Re)load the active ASR model. On failure, fall back to the default turbo model so dictation
    /// keeps working (and revert the stored selection). The default model itself is downloaded on
    /// first run if no copy is on disk yet. Returns whether a usable model is loaded.
    @discardableResult
    private func loadASRModel(path: String) async -> Bool {
        runtimeStatus.asr = .loading

        // A user-selected model (downloaded or imported): load it offline; on failure fall through
        // to the default and clear the bad selection.
        if !path.isEmpty, ASRModelManager.isValidModelFolder(URL(fileURLWithPath: path)) {
            let name = URL(fileURLWithPath: path).lastPathComponent
            if await tryLoadASR(folder: path, name: name) { return true }
            settingsStore.settings.asrModelPath = ""
            flash("Couldn't load that model — reverting to the default one.")
        }

        // The default turbo model: an existing copy (bundled in Resources, previously downloaded, or
        // a dev checkout), otherwise download it into the managed dir on first run.
        guard let folder = await resolveOrDownloadDefaultModel() else {
            runtimeStatus.asr = .unavailable
            return false
        }
        return await tryLoadASR(folder: folder, name: ASRModelController.bundledName)
    }

    /// Load + warm a model folder into the transcriber, updating runtime status. Returns success.
    private func tryLoadASR(folder: String, name: String) async -> Bool {
        do {
            try await transcriber.reload(modelFolder: folder)
            runtimeStatus.asr = .ready
            chacharLog("ASR model loaded: \(name)")
            return true
        } catch {
            chacharLog("ASR model load FAILED for \(folder): \(error)")
            return false
        }
    }

    /// Locate the default turbo model on disk, or download it (first run) into the managed models
    /// directory with progress shown in the menu bar. Persists the download location so later
    /// launches load it offline. Returns the folder, or nil if it's absent and can't be downloaded.
    private func resolveOrDownloadDefaultModel() async -> String? {
        if let existing = Self.existingDefaultModelFolder(
            downloadedPath: settingsStore.settings.defaultASRModelPath) {
            return existing
        }
        setStatus("Downloading speech model…")
        runtimeStatus.asr = .downloading(0)
        downloadingDefaultModel = true
        chacharLog("no default model on disk — downloading \(DefaultModels.bundledASRFolderName)")
        do {
            let url = try await ASRModelManager.download(variant: DefaultModels.bundledASRFolderName) { fraction in
                // Progress arrives on a background queue and is re-dispatched as unstructured main-
                // actor tasks, so a straggler can land AFTER the download returns and the model
                // loads — without the guard it overwrites .loading/.ready and the setup guide
                // sticks at "Downloading 100%" with "Start Dictating" locked.
                Task { @MainActor in
                    guard self.downloadingDefaultModel else { return }
                    self.runtimeStatus.asr = .downloading(fraction)
                    self.setStatus("Downloading speech model… \(Int(fraction * 100))%")
                }
            }
            downloadingDefaultModel = false
            runtimeStatus.asr = .loading // download done; the load/warm-up phase reports from here
            settingsStore.settings.defaultASRModelPath = url.path
            chacharLog("default model downloaded to \(url.path)")
            return url.path
        } catch {
            downloadingDefaultModel = false
            chacharLog("default model download FAILED: \(error)")
            flash("Couldn't download the speech model: \(error.localizedDescription)")
            return nil
        }
    }

    /// (Re)load the cleanup model, surfacing download progress + readiness to the UI. Used at
    /// startup and whenever the user picks a different model in the Models tab. While loading,
    /// `cleanupState` is not `.ready`, so dictation simply skips Layer 2 instead of blocking.
    private func loadCleanupModel(_ id: String) async {
        cleanupState = .loading
        runtimeStatus.cleanupModel = .loading
        do {
            try await cleaner.reload(modelId: id) { fraction in
                Task { @MainActor in
                    if fraction < 1 { self.runtimeStatus.cleanupModel = .downloading(fraction) }
                }
            }
            // Pay MLX's one-time compile now (a throwaway generation) so the first real cleanup is
            // fast. Only mark ready afterwards, so "ready" means "warm, no first-press penalty".
            await cleaner.warmUp()
            cleanupState = .ready
            runtimeStatus.cleanupModel = .ready
        } catch {
            cleanupState = .failed
            runtimeStatus.cleanupModel = .unavailable
        }
    }

    /// Release the cleanup model when the feature is turned off, freeing its ~4–5 GB. It reloads
    /// (and re-warms) the next time cleanup is enabled.
    private func unloadCleanupModel() async {
        await cleaner.unload()
        cleanupState = .idle
        runtimeStatus.cleanupModel = .idle
    }

    /// Build a push-to-talk monitor wired to the dictation loop. Extracted so startup and live
    /// reconfiguration share the same callbacks.
    ///
    /// `triggers` and `toggleMode` are passed in rather than read back from `settingsStore`: when a
    /// live change arrives, `applySettings` runs inside the `@Published` publisher's `willSet`, so
    /// `settingsStore.settings` still holds the *old* value at that instant. Reading it here would
    /// rebuild the monitor with the stale toggle mode — the change would only "take" after a relaunch
    /// (which reads the persisted value at startup). Threading the fresh values through avoids that.
    private func makeHotkeyMonitor(_ triggers: [PushToTalkTrigger], toggleMode: Bool) -> HotkeyMonitor {
        HotkeyMonitor(
            triggers: triggers,
            toggleMode: toggleMode,
            onPress: { MainActor.assumeIsolated { self.dictation.press() } },
            onRelease: { MainActor.assumeIsolated { self.dictation.release() } }
        )
    }

    /// Build the dictation pipeline and wire its callbacks back to the app's status line, HUD and
    /// diagnostics. The pipeline shares the already-created mic/transcriber/cleaner/stores.
    private func makeDictationController() -> DictationController {
        let controller = DictationController(
            capture: capture,
            transcriber: transcriber,
            cleaner: cleaner,
            vocabulary: vocabulary,
            history: history,
            settings: settingsStore
        )
        controller.isCleanupReady = { [weak self] in self?.cleanupState == .ready }
        controller.onStatus = { [weak self] in self?.setStatus($0) }
        controller.onDelivered = { [weak self] in self?.flash($0) }
        controller.onWarning = { [weak self] text in
            chacharLog("dictation warning: \(text)")
            self?.flash(text)
        }
        return controller
    }

    // MARK: Settings application

    /// Apply a settings change live. Diffs against `appliedSettings` so each effect runs only when
    /// the relevant field actually changed (this fires on every keystroke in the settings UI).
    private func applySettings(_ settings: AppSettings) {
        let previous = appliedSettings
        appliedSettings = settings

        if previous.asrLanguage != settings.asrLanguage {
            Task { await transcriber.update(language: settings.asrLanguage) }
        }
        // Cleanup: keep the model resident + warm only while the feature is enabled. React to the
        // on/off toggle and to a model change — but ignore model changes while disabled (they take
        // effect when the user turns cleanup back on).
        let cleanupToggled = previous.cleanupEnabled != settings.cleanupEnabled
        let cleanupModelChanged = previous.cleanupModelId != settings.cleanupModelId
        if settings.cleanupEnabled {
            if cleanupToggled || cleanupModelChanged {
                Task { await loadCleanupModel(settings.cleanupModelId) }
            }
        } else if cleanupToggled {
            Task { await unloadCleanupModel() }
        }
        if previous.pttTriggers != settings.pttTriggers || previous.pttToggleMode != settings.pttToggleMode {
            rebuildHotkey(Array(settings.pttTriggers), toggleMode: settings.pttToggleMode)
        }
        if previous.micOnlyWhileDictating != settings.micOnlyWhileDictating {
            // Apply immediately: release the warm mic now, or re-warm it.
            if settings.micOnlyWhileDictating { capture.stop() } else { try? capture.start() }
        }
        if previous.historyRetentionLimit != settings.historyRetentionLimit,
           settings.historyRetentionLimit > 0 {
            let limit = settings.historyRetentionLimit
            let store = history
            Task.detached { store.trim(keepingLast: limit) }
        }
    }

    private func rebuildHotkey(_ triggers: [PushToTalkTrigger], toggleMode: Bool) {
        hotkey?.stop()
        let monitor = makeHotkeyMonitor(triggers, toggleMode: toggleMode)
        if monitor.start() {
            hotkey = monitor
            chacharLog("hotkey rebuilt with \(triggers)")
        } else {
            chacharLog("hotkey rebuild FAILED — Accessibility?")
            startAccessibilityPolling() // self-heal once Accessibility is granted
        }
    }

    /// After Accessibility is requested, watch for the grant and arm the hotkey the instant it lands
    /// — a `CGEventTap` can be created live once the process is trusted, so the user never has to
    /// relaunch. Polls lightly (1 s), stops as soon as it succeeds, and is guarded against duplicates.
    private func startAccessibilityPolling() {
        guard !accessibilityPolling else { return }
        accessibilityPolling = true
        Task { @MainActor [weak self] in
            defer { self?.accessibilityPolling = false }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard AXIsProcessTrusted() else { continue }
                self.rebuildHotkey(Array(self.settingsStore.settings.pttTriggers),
                                   toggleMode: self.settingsStore.settings.pttToggleMode)
                if self.hotkey != nil { self.setStatus("Ready — hold your push-to-talk key") }
                return
            }
        }
    }

    /// Refuse to run straight from the mounted `.dmg` (or a Gatekeeper-translocated copy of it).
    /// Granting TCC permissions to the disk-image copy binds them to the `/Volumes/...` path: they
    /// turn into orphaned "ChacharApp.app" rows with a generic icon once the image is ejected, and
    /// the installed copy has to be re-granted anyway. Standard drag-to-install hygiene: ask the
    /// user to install first, then quit. Returns true when quitting.
    private func quitIfRunningFromDiskImage() -> Bool {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return false }
        let alert = NSAlert()
        alert.messageText = "Move ChacharApp to Applications first"
        alert.informativeText = """
        You're running ChacharApp directly from the downloaded disk image. Drag ChacharApp \
        into the Applications folder, eject the disk image, and launch it from Applications — \
        otherwise macOS ties the permissions to the disk image and they break when it's ejected.
        """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
        return true
    }

    /// Open the setup guide when anything the app needs is missing — first run, a revoked
    /// permission, a deleted model — or when the user never finished it. No-op when everything is
    /// already in place: regular launches stay silent.
    private func showOnboardingIfNeeded() {
        let settings = settingsStore.settings
        let micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let modelOnDisk = Self.existingDefaultModelFolder(
            downloadedPath: settings.defaultASRModelPath) != nil
            || (!settings.asrModelPath.isEmpty
                && ASRModelManager.isValidModelFolder(URL(fileURLWithPath: settings.asrModelPath)))
        if !settings.onboardingCompleted || !micGranted || !AXIsProcessTrusted() || !modelOnDisk {
            onboarding.show()
        }
    }

    // MARK: UI

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let url = Bundle.main.resourceURL?.appending(path: "MenuBarIcon.png"),
               let image = NSImage(contentsOf: url) {
                let height: CGFloat = 18
                let aspect = image.size.width / max(image.size.height, 1)
                image.size = NSSize(width: height * aspect, height: height)
                image.isTemplate = false // colored logo (experiment); set true for a mono template
                button.image = image
            } else {
                button.title = "🎙" // fallback if the icon resource is missing
            }
        }

        let menu = NSMenu()
        let header = NSMenuItem(title: "ChacharApp", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let status = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status

        menu.addItem(.separator())

        // Deliberately NOT in this menu: the Layer 2 cleanup toggle (it loads a ~4–5 GB model —
        // too heavy a side effect for a one-click menu item pressed by accident) and vocabulary
        // editing. Both live in Settings, where the choice is explicit.
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let guide = NSMenuItem(title: "Setup Guide…", action: #selector(openOnboarding), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)

        // Only distribution builds carry an update feed (see `updater`); Sparkle's controller
        // validates the item itself (disabled while a check is already running).
        if let updater {
            let checkForUpdates = NSMenuItem(
                title: "Check for Updates…",
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            checkForUpdates.target = updater
            menu.addItem(checkForUpdates)
        }

        // About: version at a glance + the same project links as the Settings About tab.
        let about = NSMenuItem(title: "About ChacharApp", action: nil, keyEquivalent: "")
        let aboutMenu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        aboutMenu.addItem(NSMenuItem(title: "Version \(version) (\(build))", action: nil, keyEquivalent: ""))
        let website = NSMenuItem(title: "Website: juanpablocastro.com", action: #selector(openWebsite), keyEquivalent: "")
        website.target = self
        aboutMenu.addItem(website)
        about.submenu = aboutMenu
        menu.addItem(about)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ChacharApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    /// Show the HUD only when enabled (see `showHUD`). Centralises the gate so the pop-up stays
    /// off everywhere while the HUDController code remains intact.
    private func flash(_ text: String) {
        guard showHUD else { return }
        hud.show(text)
    }

    private func setStatus(_ text: String) {
        statusMenuItem?.title = text
    }

    @objc private func openSettings() {
        settingsWindow.show(store: settingsStore, status: runtimeStatus, history: history,
                            vocabulary: vocabulary, asr: asrController)
    }

    @objc private func openOnboarding() {
        onboarding.show()
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(URL(string: "https://juanpablocastro.com/en/projects/chacharapp/")!)
    }

    private func promptAccessibility() {
        // The setup guide already explains Accessibility (with a live checkmark and a button), so
        // don't stack a redundant alert on top of it.
        guard !onboarding.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = "Enable Accessibility for ChacharApp"
        alert.informativeText = """
        To capture the global push-to-talk key, enable ChacharApp under
        System Settings → Privacy & Security → Accessibility. It starts working within
        a second of granting — no need to relaunch.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Model location

    /// Locate the default turbo model already on disk: an env override, the copy bundled in the
    /// app's Resources (dev / full-offline builds), a previously auto-downloaded copy, or a dev
    /// checkout's `Models/`. Returns nil when none exists yet (a fresh download-on-first-run
    /// install), in which case the caller downloads it. Each candidate is validated as a real
    /// WhisperKit folder so a stale/partial path is skipped rather than loaded and failed.
    private static func existingDefaultModelFolder(downloadedPath: String) -> String? {
        func valid(_ path: String) -> Bool {
            !path.isEmpty && ASRModelManager.isValidModelFolder(URL(fileURLWithPath: path))
        }
        if let env = ProcessInfo.processInfo.environment["CHACHARAPP_MODEL_FOLDER"], valid(env) {
            return env
        }
        if let bundled = Bundle.main.resourceURL?.appending(path: "Models/\(modelVariant)").path,
           valid(bundled) {
            return bundled
        }
        if valid(downloadedPath) { return downloadedPath }
        let cwd = FileManager.default.currentDirectoryPath + "/Models/\(modelVariant)"
        return valid(cwd) ? cwd : nil
    }
}
