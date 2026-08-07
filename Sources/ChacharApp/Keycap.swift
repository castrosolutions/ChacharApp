import SwiftUI

/// A single key drawn as a key: a rounded, outlined cap with its legend inside.
///
/// Shared by the two places the app has to name a physical key — the floating pill's "esc to
/// cancel" hint and the setup guide's keyboard diagram — because a key spelled as prose ("press
/// escape") reads as a sentence, while a key drawn as a cap reads as the thing on the desk.
///
/// Two surfaces, since the two callers sit on opposite backgrounds: ``Style/hud`` for the dark
/// translucent pill, ``Style/window`` for a normal light-or-dark window.
struct Keycap: View {
    enum Style {
        /// On the floating pill: always dark underneath, so the cap is a white wash.
        case hud
        /// In a window: follows the system light/dark appearance.
        case window
    }

    let legend: String
    var style: Style = .hud
    /// Fixed width for diagram rows where caps must line up; nil hugs the legend.
    var width: CGFloat?
    var height: CGFloat = 20
    var fontSize: CGFloat = 11
    /// Draw as the key being asked for: tinted fill, stronger border, brighter legend.
    var highlighted = false
    /// The tint used when `highlighted` — the caller's accent (mic-live green in the HUD).
    var accent: Color = .accentColor

    /// Positional legend, so call sites read as the key they draw: `Keycap("esc")`.
    init(_ legend: String, style: Style = .hud, width: CGFloat? = nil, height: CGFloat = 20,
         fontSize: CGFloat = 11, highlighted: Bool = false, accent: Color = .accentColor) {
        self.legend = legend
        self.style = style
        self.width = width
        self.height = height
        self.fontSize = fontSize
        self.highlighted = highlighted
        self.accent = accent
    }

    var body: some View {
        Text(legend)
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(legendColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, width == nil ? 7 : 4)
            .frame(width: width, height: height)
            .background {
                let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                ZStack {
                    shape.fill(fillColor)
                    shape.strokeBorder(borderColor, lineWidth: 1)
                }
            }
    }

    private var legendColor: Color {
        switch (style, highlighted) {
        case (.hud, true): accent
        case (.hud, false): .white.opacity(0.85)
        case (.window, true): accent
        case (.window, false): .primary.opacity(0.75)
        }
    }

    private var fillColor: Color {
        switch (style, highlighted) {
        case (.hud, true): accent.opacity(0.18)
        case (.hud, false): .white.opacity(0.12)
        case (.window, true): accent.opacity(0.15)
        case (.window, false): .primary.opacity(0.06)
        }
    }

    private var borderColor: Color {
        switch (style, highlighted) {
        case (.hud, true): accent.opacity(0.55)
        case (.hud, false): .white.opacity(0.22)
        case (.window, true): accent.opacity(0.65)
        case (.window, false): .primary.opacity(0.18)
        }
    }
}
