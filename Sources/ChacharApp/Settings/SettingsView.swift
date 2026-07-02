import AppKit
import ChacharCore
import SwiftUI

/// The ChacharApp settings window content: a classic macOS preferences-style `TabView`.
struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var status: RuntimeStatus
    @ObservedObject var history: HistoryViewModel
    @ObservedObject var vocabulary: VocabularyViewModel
    @ObservedObject var asr: ASRModelController

    @State private var selection: Tab = .general

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General", cleanup = "Cleanup", models = "Models"
        case vocabulary = "Vocabulary", history = "History", about = "About"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            // A self-contained segmented control instead of TabView's system tab bar, so the chip
            // strip has intentional margins and its rounded background isn't clipped at the edges.
            Picker("Section", selection: $selection) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 580, height: 520)
    }

    @ViewBuilder private var content: some View {
        switch selection {
        case .general: GeneralSettingsView(store: store)
        case .cleanup: CleanupSettingsView(store: store, status: status)
        case .models: ModelsSettingsView(store: store, status: status, asr: asr)
        case .vocabulary: VocabularySettingsView(model: vocabulary)
        case .history: HistorySettingsView(store: store, history: history)
        case .about: AboutSettingsView()
        }
    }
}

// MARK: - General

private struct GeneralSettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        Form {
            Section {
                ForEach(PTTOption.catalog) { option in
                    Toggle(option.label, isOn: triggerBinding(option))
                        .disabled(isOnlyEnabled(option.trigger))
                }
                Toggle("Hands-free (press to start, press again to stop)",
                       isOn: $store.settings.pttToggleMode)
            } header: {
                Text("Push-to-talk")
            } footer: {
                Text("By default, hold a key to dictate and release to insert. Hands-free mode "
                     + "instead toggles recording with a press, then a second press to stop. "
                     + "At least one key must stay enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open microphone only while dictating", isOn: $store.settings.micOnlyWhileDictating)
            } header: {
                Text("Microphone")
            } footer: {
                Text("On: the mic opens while you hold the key and closes on release, so macOS shows "
                     + "its orange “mic in use” indicator only while you dictate — but the first press "
                     + "pays a small warm-up. Off: the mic stays warm for the fastest response (the "
                     + "indicator stays on).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Recognition") {
                Picker("Spoken language", selection: languageSelection) {
                    ForEach(ASRLanguageOption.catalog) { Text($0.label).tag($0.id) }
                }
                Text("Forcing a language keeps inline English tech terms (code-switching) instead of "
                     + "switching language mid-sentence.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Match glossary terms phonetically", isOn: $store.settings.fuzzyGlossaryEnabled)
                Text("Catches misheard jargon (e.g. “cubernetes” → “Kubernetes”) using your "
                     + "vocabulary glossary, without needing the exact misspelling. Turn off if it "
                     + "over-corrects.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Remove trailing “thank you”/“gracias”", isOn: $store.settings.trailingHallucinationFilter)
                Text("Whisper sometimes invents a stray “gracias”/“thank you” at the end of quiet "
                     + "audio. This drops it when it stands alone at the end. Turn off if you often "
                     + "finish a dictation with a real standalone “gracias”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func triggerBinding(_ option: PTTOption) -> Binding<Bool> {
        Binding(
            get: { store.settings.pttTriggers.contains(option.trigger) },
            set: { isOn in
                var set = store.settings.pttTriggers
                if isOn {
                    set.insert(option.trigger)
                } else if set.count > 1 {
                    set.remove(option.trigger)
                }
                store.settings.pttTriggers = set
            }
        )
    }

    /// True when this trigger is the only one enabled (so its toggle is locked on).
    private func isOnlyEnabled(_ trigger: PushToTalkTrigger) -> Bool {
        store.settings.pttTriggers == [trigger]
    }

    private var languageSelection: Binding<String> {
        Binding(
            get: { ASRLanguageOption.catalog.first { $0.code == store.settings.asrLanguage }?.id ?? "auto" },
            set: { id in store.settings.asrLanguage = ASRLanguageOption.catalog.first { $0.id == id }?.code }
        )
    }
}

// MARK: - Cleanup

private struct CleanupSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var status: RuntimeStatus

    var body: some View {
        Form {
            Section {
                Toggle("Clean up speech with a local LLM", isOn: $store.settings.cleanupEnabled)
                LabeledContent("Model status") { statusLabel }
            } footer: {
                Text("When on, a local model removes fillers and applies your spoken self-corrections "
                     + "(\"no, I mean…\"). Costs a few seconds per phrase; off is the fastest path.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Active model") {
                    Text(ModelCatalog.cleanupModel(id: store.settings.cleanupModelId)?.name
                         ?? store.settings.cleanupModelId)
                        .foregroundStyle(.secondary)
                }
                Text("Choose, download or change the cleanup model in the Models tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var statusLabel: some View {
        CleanupStatusLabel(status: status.cleanupModel)
    }
}

/// Shared cleanup-model status indicator (loading / downloading% / ready / unavailable).
struct CleanupStatusLabel: View {
    let status: RuntimeStatus.CleanupModel
    var body: some View {
        switch status {
        case .idle:
            Label("Off", systemImage: "moon.zzz").foregroundStyle(.secondary)
        case .loading:
            Label("Loading…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .downloading(let p):
            Label("Downloading \(Int(p * 100))%", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unavailable:
            Label("Unavailable", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

// MARK: - History

private struct HistorySettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var history: HistoryViewModel
    @State private var confirmingClear = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Record dictation history", isOn: $store.settings.historyEnabled)
                    LabeledContent("Keep most recent") {
                        HStack {
                            TextField("", value: $store.settings.historyRetentionLimit, format: .number)
                                .frame(width: 80).multilineTextAlignment(.trailing)
                            Text("entries (0 = unlimited)").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Stored locally only — nothing leaves your Mac. Records both the raw "
                         + "recognition and the final inserted text.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 150)

            Divider()

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $history.query)
                    .textFieldStyle(.plain)
                Spacer()
                Text("\(history.filtered.count) of \(history.items.count)")
                    .font(.caption).foregroundStyle(.secondary)
                Button { history.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload")
                Button(role: .destructive) { confirmingClear = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).help("Clear all history")
                .disabled(history.items.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            if history.filtered.isEmpty {
                ContentUnavailablePlaceholder(query: history.query)
            } else {
                List(history.filtered) { item in
                    HistoryRow(item: item) { history.delete(item) }
                }
                .listStyle(.inset)
            }
        }
        .confirmationDialog("Clear all dictation history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { history.clearAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes every recorded dictation. This can't be undone.")
        }
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let onDelete: () -> Void
    @State private var justCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.record.date.formatted(date: .abbreviated, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
                if let app = item.record.app {
                    Text("· \(app)").font(.caption).foregroundStyle(.secondary)
                }
                if item.record.cleanupApplied {
                    Text("cleaned").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule()).foregroundStyle(.tint)
                }
                Spacer()
                // One-click copy of the final text to the system clipboard (the common case). The
                // "···" menu still offers copying the raw recognition or deleting.
                Button {
                    copyToClipboard(item.record.inserted)
                    justCopied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); justCopied = false }
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(justCopied ? Color.green : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Copy text to clipboard")
                Menu {
                    Button("Copy final text") { copyToClipboard(item.record.inserted) }
                    Button("Copy raw recognition") { copyToClipboard(item.record.raw) }
                    Divider()
                    Button("Delete", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Text(item.record.inserted).font(.body).textSelection(.enabled)
            if item.record.raw != item.record.inserted {
                Text(item.record.raw).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ContentUnavailablePlaceholder: View {
    let query: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: query.isEmpty ? "tray" : "magnifyingglass")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text(query.isEmpty ? "No dictations recorded yet." : "No matches for “\(query)”.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - About

private struct AboutSettingsView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("ChacharApp", value: version)
                Text("A local, free, configurable voice-dictation assistant for macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data locations") {
                PathRow(label: "Vocabulary", url: VocabularyStore.defaultURL())
                PathRow(label: "History", url: HistoryStore.defaultURL())
            }
        }
        .formStyle(.grouped)
    }
}

private struct PathRow: View {
    let label: String
    let url: URL
    var body: some View {
        LabeledContent(label) {
            HStack {
                Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - Models

private struct ModelsSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var status: RuntimeStatus
    @ObservedObject var asr: ASRModelController

    /// Free-form Hugging Face id for a cleanup model outside the curated list.
    @State private var customCleanupId = ""

    /// Known downloadable ASR models that aren't installed yet.
    private var downloadableModels: [ModelDescriptor] {
        ModelCatalog.asr.filter { model in
            !model.bundled && !asr.installed.contains(where: { $0.name == model.id })
        }
    }

    var body: some View {
        Form {
            Section {
                Button { asr.select(path: "") } label: {
                    ASRModelRow(name: ASRModelController.bundledName,
                                subtitle: "626 MB · RTF 0.10–0.15× · downloaded on first run",
                                selected: asr.isBundledActive,
                                status: asr.isBundledActive ? status.asr : nil)
                }
                .buttonStyle(.plain)

                ForEach(asr.installed) { model in
                    Button { asr.select(path: model.path) } label: {
                        ASRModelRow(name: model.name,
                                    subtitle: (model.imported ? "imported · " : "downloaded · ") + model.path,
                                    selected: asr.activePath == model.path,
                                    status: asr.activePath == model.path ? status.asr : nil)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove from list", role: .destructive) { asr.remove(model) }
                    }
                }

                Button { asr.importModel() } label: {
                    Label("Import model folder…", systemImage: "square.and.arrow.down")
                }
                if let error = asr.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                HStack { Text("Speech recognition (ASR)"); Spacer(); ASRStatusLabel(status: status.asr) }
            } footer: {
                Text("Pick the default model, download another Whisper variant below, or import a "
                     + "WhisperKit CoreML folder (must contain MelSpectrogram / AudioEncoder / "
                     + "TextDecoder). A bad model falls back to the default one.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !downloadableModels.isEmpty {
                Section {
                    ForEach(downloadableModels) { model in
                        VStack(alignment: .leading, spacing: 6) {
                            ModelCapabilityRow(model: model, selected: false)
                            if asr.downloadingVariant == model.id {
                                ProgressView(value: asr.downloadProgress) {
                                    Text("Downloading… \(Int(asr.downloadProgress * 100))%").font(.caption)
                                }
                            } else {
                                Button {
                                    asr.download(variant: model.id, displayName: model.name)
                                } label: {
                                    Label("Download", systemImage: "arrow.down.circle")
                                }
                                .disabled(asr.downloadingVariant != nil)
                            }
                        }
                    }
                } header: {
                    Text("Download a Whisper model")
                } footer: {
                    Text("Downloads from the WhisperKit model repo into ChacharApp's models folder "
                         + "(a few GB; needs network). large-v3 conditions on prompts reliably, which "
                         + "would re-enable glossary biasing (Layer 0).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(ModelCatalog.cleanup) { model in
                    Button {
                        if store.settings.cleanupModelId != model.id {
                            store.settings.cleanupModelId = model.id
                        }
                    } label: {
                        ModelCapabilityRow(
                            model: model,
                            selected: store.settings.cleanupModelId == model.id,
                            activeStatus: store.settings.cleanupModelId == model.id ? status.cleanupModel : nil
                        )
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Cleanup model (Layer 2)")
            } footer: {
                Text("Selecting a model loads it (downloading on first use — a few GB). Cleanup must "
                     + "also be enabled in the Cleanup tab.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("mlx-community/…", text: $customCleanupId)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Button("Use") { useCustomCleanupId() }
                        .disabled(trimmedCustomCleanupId.isEmpty
                                  || trimmedCustomCleanupId == store.settings.cleanupModelId)
                }
            } header: {
                Text("Custom cleanup model")
            } footer: {
                Text("Any MLX-format instruct model id from Hugging Face (e.g. mlx-community/…). "
                     + "It downloads on first use; an unknown or non-MLX id shows as unavailable.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var trimmedCustomCleanupId: String {
        customCleanupId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Point cleanup at a hand-entered model id. The app reacts (loads/warms it) if cleanup is on.
    private func useCustomCleanupId() {
        let id = trimmedCustomCleanupId
        guard !id.isEmpty else { return }
        store.settings.cleanupModelId = id
        customCleanupId = ""
    }
}

private struct ModelCapabilityRow: View {
    let model: ModelDescriptor
    let selected: Bool
    var activeStatus: RuntimeStatus.CleanupModel?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(model.name).fontWeight(.medium)
                    if let activeStatus { CleanupStatusLabel(status: activeStatus).font(.caption2) }
                }
                Text(model.id).font(.caption2).monospaced().foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("\(model.sizeText) · \(model.ramText) · \(model.speedText) · \(model.quality) · \(model.languages)")
                    .font(.caption).foregroundStyle(.secondary)
                if let note = model.note {
                    Text(note).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

struct ASRStatusLabel: View {
    let status: RuntimeStatus.ASRModel
    var body: some View {
        switch status {
        case .loading:
            Label("Loading…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .downloading(let p):
            Label("Downloading \(Int(p * 100))%", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unavailable:
            Label("Unavailable", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}

private struct ASRModelRow: View {
    let name: String
    let subtitle: String
    let selected: Bool
    var status: RuntimeStatus.ASRModel?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(name).fontWeight(.medium)
                    if let status { ASRStatusLabel(status: status).font(.caption2) }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Vocabulary

private struct VocabularySettingsView: View {
    @ObservedObject var model: VocabularyViewModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach($model.terms) { $item in
                        HStack {
                            TextField("Term or proper noun", text: $item.term)
                                .textFieldStyle(.roundedBorder)
                            Button { model.removeTerm(item) } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).foregroundStyle(.secondary)
                        }
                    }
                    Button { model.addTerm() } label: { Label("Add term", systemImage: "plus") }
                } header: {
                    Text("Glossary")
                } footer: {
                    Text("Canonical spellings biased toward in recognition (phonetic matching catches "
                         + "their mishearings). One proper noun / term per row.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach($model.rules) { $rule in
                        VStack(spacing: 4) {
                            HStack {
                                TextField("heard as", text: $rule.from).textFieldStyle(.roundedBorder)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                TextField("replace with", text: $rule.to).textFieldStyle(.roundedBorder)
                                Button { model.removeRule(rule) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 14) {
                                Toggle("Case-sensitive", isOn: $rule.caseSensitive)
                                Toggle("Whole word", isOn: $rule.wholeWord)
                                Spacer()
                            }
                            .toggleStyle(.checkbox).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                    Button { model.addRule() } label: { Label("Add rule", systemImage: "plus") }
                } header: {
                    Text("Replacements")
                } footer: {
                    Text("Exact find/replace applied to every transcription (Layer 1), in order.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack(spacing: 10) {
                if let message = model.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                } else if model.droppedCount > 0 {
                    Text("\(model.droppedCount) empty row(s) will be dropped on save.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Revert") { model.reload() }.disabled(!model.isDirty)
                Button("Save") { model.save() }
                    .keyboardShortcut("s").buttonStyle(.borderedProminent).disabled(!model.isDirty)
            }
            .padding(12)
        }
    }
}

// MARK: - Helpers

private func copyToClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
