import Foundation
import Sparkle

/// Observable façade over Sparkle's updater for the settings **Updates** tab, so updating the app
/// never depends on the menu-bar icon (which macOS can hide when the bar is full or under the
/// notch). Wraps the optional `SPUStandardUpdaterController`: in dev builds there's no update feed,
/// so `updater` is nil and `isEnabled` is false — the tab then shows a "built from source" note
/// instead of the controls.
@MainActor
final class UpdatesController: ObservableObject {
    private let updater: SPUUpdater?
    private var observations: [NSKeyValueObservation] = []

    /// False while a check is already running (or offline machinery isn't ready) — mirrors what
    /// Sparkle uses to enable/disable its own menu item, so the button greys out live.
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastCheckDate: Date?
    /// Two-way bound by the toggle; writes straight through to Sparkle's stored preference.
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    /// True only in distribution builds (a real Sparkle feed is present).
    var isEnabled: Bool { updater != nil }

    var currentVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    init(controller: SPUStandardUpdaterController?) {
        let updater = controller?.updater
        self.updater = updater
        self.automaticallyChecksForUpdates = updater?.automaticallyChecksForUpdates ?? false
        guard let updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
        // KVO so the button state and last-checked date track Sparkle live (a check flips
        // canCheckForUpdates and updates the date asynchronously). Change values are Sendable, so we
        // hop back to the main actor to publish them.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? false
                Task { @MainActor in self?.canCheckForUpdates = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, change in
                let value = change.newValue ?? nil
                Task { @MainActor in self?.lastCheckDate = value }
            },
        ]
    }

    /// Re-read the current state from Sparkle. Called on tab appearance as a belt-and-suspenders
    /// refresh in case a KVO notification was missed.
    func refresh() {
        guard let updater else { return }
        canCheckForUpdates = updater.canCheckForUpdates
        lastCheckDate = updater.lastUpdateCheckDate
    }

    /// Start a user-initiated update check (the same action the menu-bar item triggers).
    func checkForUpdates() {
        updater?.checkForUpdates()
    }
}
