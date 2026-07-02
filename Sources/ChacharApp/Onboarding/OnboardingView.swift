import AppKit
import SwiftUI

/// The first-run setup guide: a live checklist of the two permissions and the one-time
/// speech-model download. Each row updates the moment its requirement is met (permissions are
/// polled by ``OnboardingController``; the model row observes ``RuntimeStatus``), and the final
/// "Start Dictating" button unlocks when all three are green.
struct OnboardingView: View {
    @ObservedObject var controller: OnboardingController
    @ObservedObject var status: RuntimeStatus

    private var allReady: Bool {
        controller.micPermission == .granted && controller.axTrusted && status.asr == .ready
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()
            microphoneStep
            accessibilityStep
            modelStep
            Divider()
            footer
        }
        .padding(22)
        .frame(width: 540)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to ChacharApp").font(.title2).fontWeight(.semibold)
                Text("Local, private voice dictation. Three things and you're ready — "
                     + "this window updates by itself as each one completes.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Steps

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

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(allReady ? "You're all set!" : "Finishing setup…")
                    .fontWeight(.semibold)
                Text("Hold \(controller.pttKeyName), speak, release — the text lands wherever "
                     + "your cursor is. Reopen this guide any time from the menu-bar icon.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Start Dictating") { controller.finish() }
                .buttonStyle(.borderedProminent)
                .disabled(!allReady)
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
