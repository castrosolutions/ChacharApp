import AppKit
import ChacharCore
import Combine
import Foundation

/// Drives ASR-model management from the Models tab: select the active model, import a local model
/// folder (validated), and remove installed ones. Selection persists via `SettingsStore` and asks
/// `AppDelegate` to (re)load the model through the `activate` closure (which falls back to the
/// bundled model if loading fails).
@MainActor
final class ASRModelController: ObservableObject {
    /// Display name for the always-available default model (bundled in dev builds; downloaded on
    /// first run in distributed builds).
    static let bundledName = "Whisper large-v3-turbo (default)"

    private let store: SettingsStore
    let status: RuntimeStatus
    private let activate: (String) async -> Void

    @Published var errorMessage: String?
    /// Catalog id currently downloading (drives the per-row progress), or nil.
    @Published var downloadingVariant: String?
    /// Download progress 0...1 for `downloadingVariant`.
    @Published var downloadProgress: Double = 0

    init(store: SettingsStore, status: RuntimeStatus, activate: @escaping (String) async -> Void) {
        self.store = store
        self.status = status
        self.activate = activate
    }

    var activePath: String { store.settings.asrModelPath }
    var installed: [InstalledASRModel] { store.settings.installedASRModels }
    var isBundledActive: Bool { store.settings.asrModelPath.isEmpty }

    /// Activate a model: "" = bundled, otherwise an absolute folder path.
    func select(path: String) {
        errorMessage = nil
        store.settings.asrModelPath = path
        Task { await activate(path) }
    }

    /// Remove an installed model from the list (does not delete imported files on disk). If it was
    /// active, fall back to the bundled model.
    func remove(_ model: InstalledASRModel) {
        store.settings.installedASRModels.removeAll { $0.path == model.path }
        if store.settings.asrModelPath == model.path { select(path: "") }
    }

    /// Download a known Whisper variant into ChacharApp's managed models folder, then register and
    /// activate it. `variant` is the catalog id (a repo folder name, e.g. "openai_whisper-large-v3").
    /// The active model stays loaded and usable throughout the download.
    func download(variant: String, displayName: String) {
        guard downloadingVariant == nil else { return }
        // Already downloaded? Just activate it.
        if let existing = store.settings.installedASRModels.first(where: { $0.name == variant }) {
            select(path: existing.path)
            return
        }
        errorMessage = nil
        downloadingVariant = variant
        downloadProgress = 0
        Task {
            do {
                let url = try await ASRModelManager.download(variant: variant) { fraction in
                    Task { @MainActor in self.downloadProgress = fraction }
                }
                let model = InstalledASRModel(name: variant, path: url.path, imported: false)
                if !store.settings.installedASRModels.contains(where: { $0.path == model.path }) {
                    store.settings.installedASRModels.append(model)
                }
                downloadingVariant = nil
                select(path: model.path) // activates + reloads (falls back if the folder is bad)
            } catch {
                downloadingVariant = nil
                errorMessage = "Couldn't download \(displayName): \(error.localizedDescription)"
            }
        }
    }

    /// Pick a local model folder, validate it has the required CoreML sub-models, register it and
    /// activate it.
    func importModel() {
        errorMessage = nil
        let panel = NSOpenPanel()
        panel.title = "Import a Whisper model folder"
        panel.message = "Choose a folder containing MelSpectrogram / AudioEncoder / TextDecoder."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard ASRModelManager.isValidModelFolder(url) else {
            errorMessage = "“\(url.lastPathComponent)” isn’t a valid WhisperKit model folder "
                + "(missing MelSpectrogram / AudioEncoder / TextDecoder)."
            return
        }
        if !ASRModelManager.hasOfflineTokenizer(url) {
            errorMessage = "Imported “\(url.lastPathComponent)”. Note: no tokenizer.json in the "
                + "folder, so the first load may fetch the tokenizer online."
        }
        let model = InstalledASRModel(name: url.lastPathComponent, path: url.path, imported: true)
        if !store.settings.installedASRModels.contains(where: { $0.path == model.path }) {
            store.settings.installedASRModels.append(model)
        }
        select(path: model.path)
    }
}
