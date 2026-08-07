import AppKit
import SwiftUI

/// The first-run setup guide, as a four-step wizard: the permissions and model download, the two
/// choices the app must not make for you (spoken language, push-to-talk mode), and a hands-on
/// practice dictation into a scratchpad.
///
/// The practice step exists because everything before it is invisible plumbing. Someone who has
/// granted two permissions and waited for a 626 MB download still has no idea what the gesture
/// feels like, and the first real attempt normally happens in a document that matters. Here it
/// happens in a notepad that doesn't, with the keyboard diagram pointing at the key.
struct OnboardingView: View {
    @ObservedObject var controller: OnboardingController
    @ObservedObject var status: RuntimeStatus
    @ObservedObject var store: SettingsStore

    /// Keyboard focus for the practice scratchpad. Dictation pastes into whatever has focus, so
    /// the step only works if the caret is already sitting in the notepad when the user presses
    /// the key — asking them to click there first would be one instruction too many.
    @FocusState private var scratchpadFocused: Bool

    private var allReady: Bool {
        controller.micPermission == .granted && controller.axTrusted && status.asr == .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            stepContent
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(22)
        .frame(width: 560, height: 470)
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(controller.step == .permissions
                     ? "Welcome to ChacharApp" : controller.step.title)
                    .font(.title2).fontWeight(.semibold)
                Text(subtitle)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            stepDots
        }
    }

    private var subtitle: String {
        switch controller.step {
        case .permissions:
            "Local, private voice dictation. Three things and you're ready — this window "
                + "updates by itself as each one completes."
        case .language:
            "Pick the language you'll be speaking. You can change it later in Settings."
        case .mode:
            "Choose how you'd rather start a dictation."
        case .practice:
            "Last step — let's make sure it actually works."
        }
    }

    private var stepDots: some View {
        HStack(spacing: 5) {
            ForEach(SetupStep.allCases, id: \.rawValue) { candidate in
                Circle()
                    .fill(candidate.rawValue <= controller.step.rawValue
                          ? Color.accentColor : Color.secondary.opacity(0.28))
                    .frame(width: 6, height: 6)
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch controller.step {
        case .permissions:
            VStack(alignment: .leading, spacing: 16) {
                microphoneStep
                accessibilityStep
                modelStep
            }
        case .language:
            languageStep
        case .mode:
            modeStep
        case .practice:
            practiceStep
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(footerTitle).fontWeight(.semibold)
                Text(footerDetail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if controller.step != .permissions {
                Button("Back") { controller.goBack() }
            }
            if controller.step == .practice {
                Button("Start Dictating") { controller.finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.practice != .done && !controller.canSkipPractice)
            } else {
                Button("Continue") { controller.advance() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canAdvance)
            }
        }
    }

    private var footerTitle: String {
        switch controller.step {
        case .permissions: allReady ? "All three are ready" : "Finishing setup…"
        case .language: "Spoken language"
        case .mode: "Dictation mode"
        case .practice: controller.practice == .done ? "You're all set!" : "Give it a try"
        }
    }

    private var footerDetail: String {
        switch controller.step {
        case .permissions:
            allReady ? "Two quick choices left, then you can try it out."
                : "This window updates by itself as each requirement is met."
        case .language:
            "Forcing a language is more accurate than auto-detect on short phrases."
        case .mode:
            "You can switch modes any time from Settings."
        case .practice:
            controller.practice == .done
                ? "Hold \(controller.pttKeyName), speak, release — the text lands wherever your "
                    + "cursor is. Reopen this guide any time from the menu-bar icon."
                : "Dictate one line into the notepad above to finish setup."
        }
    }

    // MARK: Step 1 — permissions

    private var microphoneStep: some View {
        StepRow(
            number: 1,
            done: controller.micPermission == .granted,
            title: "Allow the microphone",
            detail: "ChacharApp listens only while you hold the push-to-talk key. Audio is "
                + "transcribed on this Mac and never uploaded anywhere."
        ) {
            switch controller.micPermission {
            case .granted:
                StepStatus(text: "Granted", color: .green, symbol: "checkmark.circle.fill")
            case .undetermined:
                StepStatus(text: "Waiting", color: .secondary, symbol: "circle.dashed")
            case .denied:
                StepStatus(text: "Denied", color: .orange, symbol: "exclamationmark.triangle.fill")
            }
        } action: {
            switch controller.micPermission {
            case .granted:
                EmptyView()
            case .undetermined:
                Button("Allow Microphone…") { controller.requestMicrophone() }
            case .denied:
                // After a denial macOS never re-prompts — the grant must be flipped manually. And
                // unlike Accessibility, a Microphone change made in System Settings only reaches a
                // running app after a relaunch, so tell the user instead of promising a live update.
                VStack(alignment: .leading, spacing: 4) {
                    Text("Turn ChacharApp on under Privacy & Security → Microphone, then quit and "
                         + "reopen the app — macOS applies microphone changes only on relaunch.")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open System Settings…") { controller.requestMicrophone() }
                }
            }
        }
    }

    private var accessibilityStep: some View {
        StepRow(
            number: 2,
            done: controller.axTrusted,
            title: "Enable Accessibility",
            detail: "Needed to detect the push-to-talk key system-wide and to paste the text into "
                + "the app you're dictating into. Turn ChacharApp on under Privacy & Security → "
                + "Accessibility — it takes effect within a second, no relaunch needed."
        ) {
            if controller.axTrusted {
                StepStatus(text: "Granted", color: .green, symbol: "checkmark.circle.fill")
            } else {
                StepStatus(text: "Waiting", color: .secondary, symbol: "circle.dashed")
            }
        } action: {
            if !controller.axTrusted {
                Button("Open System Settings…") { controller.openAccessibilitySettings() }
            }
        }
    }

    private var modelStep: some View {
        StepRow(
            number: 3,
            done: status.asr == .ready,
            title: "Get the speech model",
            detail: "Whisper large-v3-turbo (~626 MB) downloads automatically the first time and "
                + "is stored on this Mac — after that, dictation works fully offline."
        ) {
            switch status.asr {
            case .ready:
                StepStatus(text: "Ready", color: .green, symbol: "checkmark.circle.fill")
            case .loading:
                StepStatus(text: "Preparing…", color: .secondary, symbol: "hourglass")
            case .downloading(let fraction):
                StepStatus(text: "Downloading \(Int(fraction * 100))%", color: .secondary,
                           symbol: "arrow.down.circle")
            case .unavailable:
                StepStatus(text: "Failed", color: .orange, symbol: "exclamationmark.triangle.fill")
            }
        } action: {
            switch status.asr {
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(maxWidth: 260)
            case .unavailable:
                VStack(alignment: .leading, spacing: 4) {
                    Text("The download needs a network connection. Check you're online, then retry.")
                        .font(.caption).foregroundStyle(.orange)
                    Button("Retry Download") { controller.retryModel() }
                }
            default:
                EmptyView()
            }
        }
    }

    // MARK: Step 2 — language

    /// The app ships tuned for Spanish, which is a default, not a decision — asking once here is
    /// the difference between "works out of the box" and "transcribes my English as Spanish".
    private var languageStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which language will you speak?")
                .font(.headline)
            Picker("", selection: Binding(
                get: { store.settings.asrLanguage },
                set: { store.settings.asrLanguage = $0 }
            )) {
                ForEach(ASRLanguageOption.catalog) { option in
                    Text(option.label).tag(option.code)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            InfoNote("Technical English words inside a sentence are kept as they are — you don't "
                     + "need to switch languages to say \"pull request\" or \"deploy\". Pick "
                     + "Auto-detect only if you routinely dictate in more than one language.")
        }
    }

    // MARK: Step 3 — mode

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModeOption(
                title: "Hold to talk",
                detail: "Hold \(controller.pttKeyName) while you speak, let go when you're done. "
                    + "Nothing is recorded unless the key is down.",
                symbol: "hand.point.up.left.fill",
                selected: !store.settings.pttToggleMode
            ) { store.settings.pttToggleMode = false }

            ModeOption(
                title: "Hands-free",
                detail: "Press \(controller.pttKeyName) once to start, press again to stop. Better "
                    + "for long dictations, where holding a key for a minute gets tiring.",
                symbol: "hands.clap.fill",
                selected: store.settings.pttToggleMode
            ) { store.settings.pttToggleMode = true }

            InfoNote("Either way, ESC cancels a recording in progress and throws the audio away.")
        }
    }

    // MARK: Step 4 — practice

    private var practiceStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            scratchpad
            KeyboardDiagram(trigger: controller.primaryTrigger, isPressed: controller.isKeyDown)
                .frame(maxWidth: .infinity)
            CoachCard(state: controller.practice,
                      keyName: controller.pttKeyName,
                      toggleMode: store.settings.pttToggleMode)
        }
        // Put the caret in the notepad the moment the step appears, so the words have somewhere to
        // land without the user being told to click first.
        .onAppear { scratchpadFocused = true }
        .onChange(of: controller.step) { _, step in
            if step == .practice { scratchpadFocused = true }
        }
    }

    private var scratchpad: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $controller.practiceText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .focused($scratchpadFocused)
            if controller.practiceText.isEmpty {
                Text("Your words will appear here…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 16)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 92)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            ZStack {
                shape.fill(Color.primary.opacity(0.04))
                shape.strokeBorder(
                    controller.practice == .listening
                        ? Color.green.opacity(0.55) : Color.primary.opacity(0.12),
                    lineWidth: 1)
            }
        }
        .animation(.easeOut(duration: 0.15), value: controller.practice)
    }
}

// MARK: - Components

/// The practice step's running commentary: one line that always says what to do next, whether
/// that's "press the key", "keep talking" or "that didn't work, here's why".
private struct CoachCard: View {
    let state: PracticeState
    let keyName: String
    let toggleMode: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 18)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(state == .done ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
            ZStack {
                shape.fill(tint.opacity(0.10))
                shape.strokeBorder(tint.opacity(0.30), lineWidth: 1)
            }
        }
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .waiting:
            Image(systemName: "keyboard").foregroundStyle(.secondary)
        case .listening:
            Image(systemName: "waveform").foregroundStyle(.green).symbolEffect(.variableColor)
        case .working:
            ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    private var message: String {
        switch state {
        case .waiting:
            toggleMode
                ? "Press \(keyName) once, say a sentence, then press it again to stop."
                : "Hold \(keyName) down, say a sentence out loud, then let go."
        case .listening:
            toggleMode
                ? "Listening — say something, then press \(keyName) again to stop."
                : "Listening — keep talking, and let go of \(keyName) when you're done."
        case .working:
            "Transcribing on this Mac…"
        case .failed(let reason):
            reason
        case .done:
            "That's it — those are your words, transcribed on this Mac. You're ready to dictate "
                + "into any app."
        }
    }

    private var tint: Color {
        switch state {
        case .waiting, .working: .secondary
        case .listening: .green
        case .failed: .orange
        case .done: .green
        }
    }
}

/// One of the two push-to-talk modes, as a selectable card.
private struct ModeOption: View {
    let title: String
    let detail: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.system(size: 15))
                VStack(alignment: .leading, spacing: 3) {
                    Label(title, systemImage: symbol)
                        .font(.system(size: 13, weight: .medium))
                    Text(detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
                ZStack {
                    shape.fill(selected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
                    shape.strokeBorder(
                        selected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.12),
                        lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A quiet aside — context that helps but shouldn't compete with the choice above it.
private struct InfoNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
            Text(text)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One checklist row: a numbered badge that becomes a green check when done, a title with a
/// trailing status label, an explanatory detail line, and an optional contextual action
/// (a button or a progress bar) underneath.
private struct StepRow<Status: View, Action: View>: View {
    let number: Int
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var status: () -> Status
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).fontWeight(.medium)
                    Spacer()
                    status()
                }
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
    }

    @ViewBuilder private var badge: some View {
        if done {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3).foregroundStyle(.green)
        } else {
            Image(systemName: "\(number).circle")
                .font(.title3).foregroundStyle(.secondary)
        }
    }
}

private struct StepStatus: View {
    let text: String
    let color: Color
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption).foregroundStyle(color)
    }
}
