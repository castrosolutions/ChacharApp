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
    @ObservedObject var updates: UpdatesController

    @State private var selection: Tab = .general

    private enum Tab: String, CaseIterable, Identifiable {
        // Ordered by how often they're used: History and Vocabulary are day-to-day, Models and
        // Cleanup are set-once, Updates/Feedback/About are rare.
        case general = "General", history = "History", vocabulary = "Vocabulary"
        case models = "Models", cleanup = "Cleanup"
        case updates = "Updates", feedback = "Feedback", about = "About"
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
        case .history: HistorySettingsView(store: store, history: history)
        case .vocabulary: VocabularySettingsView(model: vocabulary)
        case .models: ModelsSettingsView(store: store, status: status, asr: asr)
        case .cleanup: CleanupSettingsView(store: store, status: status)
        case .updates: UpdatesSettingsView(updates: updates)
        case .feedback: FeedbackSettingsView(store: store, asr: asr)
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
                Text("Cleanup is an optional second pass that runs a local language model over the "
                     + "recognized text — it removes fillers (\"um\", \"eh\") and applies the spoken "
                     + "self-corrections you say out loud (\"no, I mean…\") for a cleaner result.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("It's off by default because it's demanding: it downloads and keeps its own "
                     + "multi-gigabyte model in memory, adds a few seconds to every dictation, and "
                     + "uses noticeable CPU and RAM while active. Turn it on for the extra polish "
                     + "when your Mac can spare the resources — it still runs 100% on-device.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("About cleanup")
            }

            Section {
                Toggle("Clean up speech with a local LLM", isOn: $store.settings.cleanupEnabled)
                LabeledContent("Model status") { statusLabel }
            } footer: {
                Text("While on, every dictation is sent through the cleanup model before it's "
                     + "inserted. “Model status” shows whether that model is loaded and ready.")
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
                    Text("A searchable log of your past dictations — both the raw recognition and "
                         + "the final inserted text — so you can revisit or re-copy anything you've said.")
                        .font(.callout).foregroundStyle(.secondary)
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
            .frame(height: 190)

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

// MARK: - Updates

/// Software-update pane: manual check, auto-check toggle and last-checked date, so updating never
/// depends on the menu-bar icon (which macOS can hide when the bar is full or under the notch). In
/// dev builds (no Sparkle feed) it explains that updates come from a reinstall instead.
private struct UpdatesSettingsView: View {
    @ObservedObject var updates: UpdatesController

    var body: some View {
        Form {
            if updates.isEnabled {
                Section {
                    LabeledContent("Current version", value: updates.currentVersion)
                    LabeledContent("Last checked", value: lastCheckedText)
                    Button("Check for Updates…") { updates.checkForUpdates() }
                        .disabled(!updates.canCheckForUpdates)
                } footer: {
                    Text("Checks the maintainer's signed update feed and walks you through "
                         + "installing a newer version. Also available from the menu-bar icon.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Automatically check for updates",
                           isOn: $updates.automaticallyChecksForUpdates)
                } footer: {
                    Text("When on, ChacharApp checks for a new version in the background and tells "
                         + "you — no need to open this window or reach the menu-bar icon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    LabeledContent("Current version", value: updates.currentVersion)
                } footer: {
                    Text("This is a development build (built from source), so it doesn't receive "
                         + "automatic updates — update by pulling the latest code and reinstalling. "
                         + "Notarized release builds show the update controls here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { updates.refresh() }
    }

    private var lastCheckedText: String {
        guard let date = updates.lastCheckDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Feedback

/// Feedback pane: pick what the feedback is about, review the (non-private) diagnostics that will be
/// attached, then open a pre-filled form to send it — no account and no configured mail client
/// required. The message itself is written in the destination (a hosted Tally form, or a GitHub issue
/// for those who prefer it); the app only pre-fills the category and diagnostics. Living here (not
/// only in the menu-bar menu) means reaching the maintainer never depends on the status-bar icon,
/// which macOS can hide when the bar is full or under the notch.
///
/// Privacy: the app never sends anything on its own. Dictation stays 100% local; the only thing that
/// leaves the machine is what the user types into the form and submits there.
private struct FeedbackSettingsView: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var asr: ASRModelController

    @State private var category: FeedbackCategory = .bug
    @State private var includeDiagnostics = true

    var body: some View {
        Form {
            Section {
                Text("Found a bug, want a feature, or just have a thought? This is how you reach the "
                     + "maintainer. ChacharApp is a free, open-source project, and feedback is what "
                     + "shapes it.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("You write your message in a short form that opens in your browser — no account "
                     + "needed. Dictation always stays on your Mac; the only thing sent is what you "
                     + "type into that form and submit.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("About feedback")
            }

            Section {
                Picker("What's this about?", selection: $category) {
                    ForEach(FeedbackCategory.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                Toggle("Attach app & system info", isOn: $includeDiagnostics)
                if includeDiagnostics {
                    Text(diagnostics)
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Helps pin down bugs. No transcriptions, no audio, no personal data — only the "
                     + "app version, your macOS version, hardware and which models are active. It's "
                     + "pre-filled into the form for you.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button { open(report.formURL) } label: {
                    Label("Send feedback", systemImage: "paperplane")
                }
                .buttonStyle(.borderedProminent)

                Button { open(report.githubURL) } label: {
                    Label("Open a GitHub issue instead", systemImage: "ladybug")
                }
                .buttonStyle(.link)
            } footer: {
                Text("“Send feedback” opens a short form in your browser (no account needed); you "
                     + "write your message there and submit. Prefer GitHub? It's public and "
                     + "searchable, and needs a GitHub account.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var report: FeedbackReport {
        FeedbackReport(category: category, diagnostics: includeDiagnostics ? diagnostics : nil)
    }

    /// Non-private context that helps triage a report: never any transcription, audio or personal data.
    private var diagnostics: String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "—") "
            + "(\(info?["CFBundleVersion"] as? String ?? "—"))"
        let asrModel = asr.isBundledActive
            ? "\(ASRModelController.bundledName) (bundled)"
            : (asr.installed.first { $0.path == asr.activePath }?.name ?? "custom")
        let cleanup = store.settings.cleanupEnabled
            ? "on · \(ModelCatalog.cleanupModel(id: store.settings.cleanupModelId)?.name ?? store.settings.cleanupModelId)"
            : "off"
        return """
        ChacharApp: \(version)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Hardware: \(FeedbackReport.hardwareModel())
        ASR model: \(asrModel)
        Cleanup: \(cleanup)
        """
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

private enum FeedbackCategory: String, CaseIterable, Identifiable {
    case bug, feature, general
    var id: Self { self }

    var label: String {
        switch self {
        case .bug: return "Bug report"
        case .feature: return "Feature request"
        case .general: return "General feedback"
        }
    }

    /// Prefix in the GitHub issue title so reports are grouped even when the sender can't set labels.
    var titlePrefix: String {
        switch self {
        case .bug: return "[Bug]"
        case .feature: return "[Feature]"
        case .general: return "[Feedback]"
        }
    }
}

/// Builds the pre-filled URLs the Feedback tab opens: a hosted Tally form (the default — no account
/// needed) and a GitHub issue (for those who prefer it). Pure value type — no side effects, no
/// network. Opening the URL hands the draft to the browser; the user writes the message and submits
/// it there.
private struct FeedbackReport {
    let category: FeedbackCategory
    /// The diagnostics block to attach, or nil when the user opted out.
    let diagnostics: String?

    /// Change here if the repository moves; keeps GitHub and any docs pointing at one place.
    static let repository = "castrosolutions/ChacharApp"
    /// Tally form id (the part after tally.so/r/). The form must expose two pre-fill keys: `type`
    /// (a dropdown whose option labels match FeedbackCategory.label) and `diagnostics` (a hidden
    /// field that receives the block below).
    static let tallyFormID = "rjW2DR"

    /// Hosted form, pre-filled with the category and diagnostics. The user writes the message and
    /// (optionally) their email in the form, then submits.
    var formURL: URL? {
        var components = URLComponents(string: "https://tally.so/r/\(Self.tallyFormID)")
        var items = [URLQueryItem(name: "type", value: category.label)]
        if let diagnostics {
            items.append(URLQueryItem(name: "diagnostics", value: diagnostics))
        }
        components?.queryItems = items
        return components?.url
    }

    var githubURL: URL? {
        var components = URLComponents(string: "https://github.com/\(Self.repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: "\(category.titlePrefix) "),
            URLQueryItem(name: "body", value: githubBody),
        ]
        return components?.url
    }

    /// The user types their description above the fold; the HTML comment renders invisibly on GitHub,
    /// and the diagnostics (when attached) are fenced as a code block.
    private var githubBody: String {
        let prompt = "<!-- Describe your feedback here. -->"
        guard let diagnostics else { return prompt }
        return "\(prompt)\n\n---\n**App & system info**\n\n```\n\(diagnostics)\n```"
    }

    /// Board identifier (e.g. "Mac15,3") plus architecture — enough to reproduce hardware-specific
    /// issues without any marketing-name lookup.
    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let model = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        #if arch(arm64)
        return "\(model) (arm64)"
        #else
        return "\(model) (x86_64)"
        #endif
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
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ChacharApp").font(.title3.bold())
                        Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("A local, free, configurable voice-dictation assistant for macOS.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Created by") {
                    Link("Juan Pablo Castro — juanpablocastro.com",
                         destination: URL(string: "https://juanpablocastro.com")!)
                }
                LabeledContent("Source code") {
                    Link("github.com/castrosolutions/ChacharApp",
                         destination: URL(string: "https://github.com/castrosolutions/ChacharApp")!)
                }
                LabeledContent("License", value: "MIT")
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
                Text("Models are the on-device engines ChacharApp runs. The speech-recognition "
                     + "(ASR) model turns your voice into text and is always used — the default "
                     + "downloads on first run.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("The cleanup model powers the optional Cleanup pass and is only loaded when "
                     + "you enable that feature. Download curated alternatives or import your own; "
                     + "everything stays local.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("About models")
            }

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
                    Text("Vocabulary teaches ChacharApp your personal terms so it writes them "
                         + "correctly. Recognition leans toward the canonical spellings in your "
                         + "glossary, and phonetic matching catches their mishearings "
                         + "(e.g. \"cubernetes\" → \"Kubernetes\").")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Replacements are exact find-and-replace rules applied to every "
                         + "transcription. It all runs instantly and on-device (Layer 1).")
                        .font(.callout).foregroundStyle(.secondary)
                } header: {
                    Text("About vocabulary")
                }

                Section {
                    ForEach(model.terms) { item in
                        HStack {
                            TextField("Term or proper noun", text: model.binding(forTerm: item.id))
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
                    ForEach(model.rules) { rule in
                        VStack(spacing: 4) {
                            HStack {
                                TextField("heard as", text: model.binding(forRule: rule.id, \.from, default: ""))
                                    .textFieldStyle(.roundedBorder)
                                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                TextField("replace with", text: model.binding(forRule: rule.id, \.to, default: ""))
                                    .textFieldStyle(.roundedBorder)
                                Button { model.removeRule(rule) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 14) {
                                Toggle("Case-sensitive", isOn: model.binding(forRule: rule.id, \.caseSensitive, default: false))
                                Toggle("Whole word", isOn: model.binding(forRule: rule.id, \.wholeWord, default: false))
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
