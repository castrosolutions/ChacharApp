import SwiftUI

/// What the floating pill is showing. Owned by ``StatusOverlayController``, rendered by
/// ``StatusOverlayView``.
enum OverlayContent: Equatable {
    /// Recording: live level meter + "Listening…".
    case listening
    /// Indeterminate work with a label ("Transcribing…", "Cleaning up…").
    case working(String)
    /// Determinate progress (0…1) with a label — the first-run model download.
    case progress(String, Double)
    /// A short-lived message that dismisses itself.
    case notice(String, OverlayNotice)
    /// Words that couldn't be inserted anywhere, held on screen with a way to rescue them.
    /// The only content that is interactive, and the only one that never dismisses itself.
    case recovery(String)

    /// Whether this content has buttons — which decides whether the panel takes clicks at all.
    var isInteractive: Bool {
        if case .recovery = self { return true }
        return false
    }
}

enum OverlayNotice: Equatable { case success, info, failure }

/// The floating pill: one shape per wait the app makes you sit through — a live level meter while
/// recording, a spinner while the pipeline runs, a progress bar while the speech model loads, and
/// a short-lived message for outcomes.
///
/// A pure function of `(content, levels)` on purpose: it holds no state and observes nothing, so
/// every appearance can be rendered in isolation (see `Scripts/preview-overlay.sh`). The live
/// wiring is one thin `@ObservedObject` wrapper in ``StatusOverlayController``.
///
/// Drawn inside a transparent, click-through panel, so everything here is decoration: nothing is
/// interactive, and nothing may grow past `contentWidth`.
struct StatusOverlayView: View {
    let content: OverlayContent?
    let levels: [CGFloat]
    /// Put the rescued text on the clipboard. Only reachable from ``OverlayContent/recovery(_:)``.
    var onCopy: () -> Void = {}
    /// Throw the rescued text away and close the card.
    var onDiscard: () -> Void = {}

    /// Width proposed to the pill. It caps where long messages wrap while leaving short ones free
    /// to hug their content — the pill is *centred* in this box, not stretched to fill it.
    static let contentWidth: CGFloat = 420
    /// How far the pill floats above the bottom of the screen's usable area (the panel's own
    /// bottom edge sits on it).
    static let bottomInset: CGFloat = 56

    /// The recovery card's exact size. Fixed, unlike the pill's: its panel has to take clicks, so
    /// the window is sized to the card rather than being a big transparent sheet that would
    /// swallow clicks meant for the app underneath.
    static let cardSize = CGSize(width: 520, height: 132)
    /// Breathing room around the card inside its panel, so the drop shadow isn't clipped. Clicks
    /// in this thin ring are absorbed too — a few points around a floating card nobody aims at.
    static let cardMargin: CGFloat = 12
    static var cardPanelSize: CGSize {
        CGSize(width: cardSize.width + cardMargin * 2, height: cardSize.height + cardMargin * 2)
    }

    private static let cornerRadius: CGFloat = 16
    /// Mic-live green. Deliberately not the orange of macOS's own recording dot: this is app UI
    /// and shouldn't read as a system indicator.
    private static let liveTint = Color(red: 0.36, green: 0.87, blue: 0.60)
    private static let warningTint = Color(red: 1.00, green: 0.64, blue: 0.32)

    var body: some View {
        // Two layouts, because the two panels differ: the passive pill floats inside a large
        // transparent window, while the recovery card *is* its window (see `cardSize`).
        if case .recovery(let text) = content {
            recoveryCard(text)
                .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                .padding(Self.cardMargin)
        } else {
            Group {
                if let content { pill(content) }
            }
            .frame(width: Self.contentWidth)
            .padding(.bottom, Self.bottomInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.easeOut(duration: 0.16), value: content)
        }
    }

    private func pill(_ content: OverlayContent) -> some View {
        body(for: content)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(minWidth: 160)
            .background(pillBackground)
            .shadow(color: .black.opacity(0.32), radius: 14, y: 5)
    }

    /// Material for the native blur, then a black wash so white text stays legible over a bright
    /// app underneath — this floats over arbitrary content and can't assume anything about it.
    private var pillBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        return ZStack {
            shape.fill(.regularMaterial)
            shape.fill(Color.black.opacity(0.30))
            shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func body(for content: OverlayContent) -> some View {
        switch content {
        case .listening:
            HStack(spacing: 14) {
                LevelMeter(levels: levels, tint: Self.liveTint)
                label("Listening…")
            }
        case .working(let text):
            HStack(spacing: 12) {
                Spinner(tint: .white)
                label(text)
            }
        case .progress(let text, let fraction):
            VStack(alignment: .leading, spacing: 9) {
                label(text)
                ProgressBar(fraction: fraction, tint: Self.liveTint)
                    .frame(width: 250)
            }
        case .notice(let text, let kind):
            HStack(spacing: 10) {
                Image(systemName: symbol(kind))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint(kind))
                label(text)
            }
        case .recovery:
            EmptyView() // never reaches the pill layout — `body` routes it to `recoveryCard`
        }
    }

    // MARK: Recovery card

    /// Shown when the words had nowhere to go. It stays until the user acts, because the only
    /// other copy of this text is the history log — and someone who just watched a dictation
    /// vanish shouldn't have to go looking for it.
    private func recoveryCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Self.warningTint)
                Text("Nowhere to insert this — copy it or discard it")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            HStack(spacing: 10) {
                Button(action: onCopy) { transcriptBox(text) }
                Button(action: onDiscard) {
                    Text("Discard")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 96, height: 62)
                }
            }
            .buttonStyle(CardButtonStyle())
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(pillBackground)
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }

    /// The transcription itself, as the copy affordance: the whole box is the button, with a glyph
    /// saying so. Truncated rather than scrollable — this is a rescue hatch, not a text editor.
    private func transcriptBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(3)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Image(systemName: "doc.on.doc")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Self.liveTint)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(height: 62)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }

    private func symbol(_ kind: OverlayNotice) -> String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ kind: OverlayNotice) -> Color {
        switch kind {
        case .success: Self.liveTint
        case .info: .white.opacity(0.7)
        case .failure: Self.warningTint
        }
    }
}

/// The recovery card's buttons: an outlined well that lights up under the pointer and sinks when
/// pressed. The system button styles bring the light-mode chrome the rest of this HUD avoids.
private struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return configuration.label
            .background {
                ZStack {
                    shape.fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.07))
                    shape.strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
            }
            .contentShape(shape) // the whole well is the target, gaps in the text included
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// An indeterminate spinner, drawn rather than borrowed from AppKit.
///
/// `ProgressView`'s circular style brings the system's grey indicator, which reads as a sheet
/// that's stuck rather than as part of this pill — and being an AppKit control, it can't be
/// rendered offscreen for review (`Scripts/preview-overlay.sh`). An arc costs four lines.
struct Spinner: View {
    let tint: Color
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(tint.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 15, height: 15)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}

/// A determinate progress bar in the pill's own palette (the system one is accent-blue, which
/// looks borrowed here). Same offscreen-rendering argument as ``Spinner``.
struct ProgressBar: View {
    let fraction: Double
    let tint: Color

    private static let height: CGFloat = 5

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: Self.height)
    }
}

/// A scrolling level meter: one capsule per reading, oldest on the left, mirrored about the centre
/// line so it reads as a waveform rather than as a bar chart.
struct LevelMeter: View {
    let levels: [CGFloat]
    let tint: Color

    private static let barWidth: CGFloat = 2.5
    private static let spacing: CGFloat = 2.5
    private static let height: CGFloat = 22
    /// Bars never collapse fully: a flat line still has to say "listening", not "broken".
    private static let minBarHeight: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: Self.spacing) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: Self.barWidth,
                           height: Self.minBarHeight + level * (Self.height - Self.minBarHeight))
                    // Fade the older readings so the meter reads as scrolling out to the left.
                    .opacity(0.35 + 0.65 * (Double(index) / Double(max(levels.count - 1, 1))))
            }
        }
        .frame(height: Self.height)
    }
}
