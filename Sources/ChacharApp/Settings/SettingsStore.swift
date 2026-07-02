import Combine
import Foundation

/// Single source of truth for user settings: holds the `AppSettings`, persists every change to
/// `UserDefaults`, and publishes updates so both SwiftUI views and `AppDelegate` react to changes.
///
/// `@MainActor` because it backs the settings UI; `AppDelegate` (also main-actor) subscribes to
/// `$settings` to apply changes live (rebuild the hotkey, retune the cleaner, etc.).
@MainActor
final class SettingsStore: ObservableObject {
    private static let storageKey = "appSettings"
    /// Pre-window key that stored only the cleanup toggle as a bare Bool — migrated on first load.
    private static let legacyCleanupKey = "cleanupEnabled"

    @Published var settings: AppSettings {
        didSet { persist() }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = Self.loadInitial(from: defaults)
    }

    private static func loadInitial(from defaults: UserDefaults) -> AppSettings {
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return decoded
        }
        // First run with the new store: start from defaults, migrating the old standalone toggle.
        var settings = AppSettings()
        if defaults.object(forKey: legacyCleanupKey) != nil {
            settings.cleanupEnabled = defaults.bool(forKey: legacyCleanupKey)
        }
        return settings
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
