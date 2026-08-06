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

    /// Width proposed to the pill. It caps where long messages wrap while leaving short ones free
    /// to hug their content — the pill is *centred* in this box, not stretched to fill it.
    static let contentWidth: CGFloat = 420
    /// How far the pill floats above the bottom of the screen's usable area (the panel's own
    /// bottom edge sits on it).
    static let bottomInset: CGFloat = 56

    private static let cornerRadius: CGFloat = 16
    /// Mic-live green. Deliberately not the orange of macOS's own recording dot: this is app UI
    /// and shouldn't read as a system indicator.
    private static let liveTint = Color(red: 0.36, green: 0.87, blue: 0.60)
    private static let warningTint = Color(red: 1.00, green: 0.64, blue: 0.32)

    var body: some View {
        Group {
            if let content { pill(content) }
        }
        .frame(width: Self.contentWidth)
        .padding(.bottom, Self.bottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeOut(duration: 0.16), value: content)
    }

    private func pill(_ content: OverlayContent) -> some View {
        body(for: content)
            .padding(.horizontal, 18)
            .padding(.vertical, 13)
            .frame(minWidth: 160)
            .background {
                let shape = RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                ZStack {
                    // Material for the native blur, then a black wash so white text stays legible
                    // over a bright app underneath — the pill floats over arbitrary content.
                    shape.fill(.regularMaterial)
                    shape.fill(Color.black.opacity(0.30))
                    shape.strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
            }
            .shadow(color: .black.opacity(0.32), radius: 14, y: 5)
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
        }
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
