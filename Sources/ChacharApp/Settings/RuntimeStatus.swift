import Combine
import Foundation

/// Live (non-persisted) app state surfaced in the settings UI — e.g. whether the cleanup model has
/// finished loading, and download progress while switching models. Owned by `AppDelegate`, observed
/// by the views. Kept separate from ``AppSettings`` because this is runtime status, not a user
/// choice.
@MainActor
final class RuntimeStatus: ObservableObject {
    enum CleanupModel: Equatable {
        case idle                // cleanup disabled → model not loaded / not held in memory
        case loading
        case downloading(Double) // 0...1 first-run download progress
        case ready
        case unavailable
    }

    @Published var cleanupModel: CleanupModel = .loading

    enum ASRModel: Equatable {
        case loading
        case downloading(Double) // 0...1 first-run download progress
        case ready
        case unavailable
    }

    @Published var asr: ASRModel = .loading
}
