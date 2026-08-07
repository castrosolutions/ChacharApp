import ChacharCore
import SwiftUI

/// A one-row stylised keyboard that points at the push-to-talk key.
///
/// The setup guide can say "hold Right ⌘" in words, but Right ⌘ is a key most people have never
/// deliberately pressed and can't locate by name — the whole reason it makes a good push-to-talk
/// trigger is that nothing else uses it. So the guide shows *where* it is: the row it lives on,
/// its neighbours for orientation, and a caret underneath.
///
/// The row shown follows the configured trigger, because the guide must not point at a key that
/// wouldn't do anything: right-hand modifiers get the bottom row, Right ⇧ its own row, and the
/// function keys the function row.
struct KeyboardDiagram: View {
    /// The trigger to point at — the first enabled one, chosen by the caller.
    let trigger: PushToTalkTrigger
    /// Mirror the real key: the cap sinks while the user is actually holding it down.
    var isPressed = false

    /// Draw attention to the target cap until the user has pressed it at least once.
    @State private var pulsing = false

    private static let liveTint = Color(red: 0.20, green: 0.68, blue: 0.44)

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            ForEach(Self.row(for: trigger)) { cap in
                VStack(spacing: 4) {
                    Keycap(cap.legend,
                           style: .window,
                           width: cap.width,
                           height: 30,
                           fontSize: cap.legend.count > 2 ? 10 : 13,
                           highlighted: cap.isTarget,
                           accent: Self.liveTint)
                        .scaleEffect(cap.isTarget && isPressed ? 0.94 : 1)
                        .shadow(color: Self.liveTint.opacity(shadowOpacity(cap.isTarget)),
                                radius: 6)
                        .animation(.easeOut(duration: 0.12), value: isPressed)
                    // The caret sits under the target only; the other caps reserve the same height
                    // so the row doesn't shift when the diagram appears.
                    Image(systemName: "arrowtriangle.up.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Self.liveTint)
                        .opacity(cap.isTarget ? 1 : 0)
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }

    /// The target's glow: steady while held, breathing while waiting to be pressed.
    private func shadowOpacity(_ isTarget: Bool) -> Double {
        guard isTarget else { return 0 }
        if isPressed { return 0.55 }
        return pulsing ? 0.45 : 0.05
    }

    // MARK: Rows

    private struct Cap: Identifiable {
        let id: Int
        let legend: String
        let width: CGFloat
        var isTarget = false
    }

    /// The keyboard row the trigger lives on, with the trigger marked.
    ///
    /// Sized in the proportions of a real Mac keyboard rather than to fit the window — the row is
    /// recognisable only if the space bar dwarfs the modifiers the way it does on the desk.
    private static func row(for trigger: PushToTalkTrigger) -> [Cap] {
        switch trigger {
        case .modifier(KeyCode.rightShift):
            let letters = ["Z", "X", "C", "V", "B", "N", "M"]
            return [Cap(id: 0, legend: "⇧", width: 62)]
                + letters.enumerated().map { Cap(id: $0.offset + 1, legend: $0.element, width: 30) }
                + [Cap(id: 8, legend: "⇧", width: 62, isTarget: true)]

        case .key(let code):
            // Function row: show the neighbours so an unlabelled key can still be counted to.
            let keys = [KeyCode.f6: "F6", KeyCode.f7: "F7", KeyCode.f8: "F8"]
            let target = keys[code] ?? "F7"
            return ["F4", "F5", "F6", "F7", "F8", "F9", "F10"].enumerated().map {
                Cap(id: $0.offset, legend: $0.element, width: 38, isTarget: $0.element == target)
            }

        case .modifier(let code):
            // Bottom row. Both halves are drawn because "Right ⌘" only means something next to a
            // left ⌘ — the side is the whole instruction.
            return [
                Cap(id: 0, legend: "control", width: 50),
                Cap(id: 1, legend: "option", width: 44),
                Cap(id: 2, legend: "⌘", width: 54),
                Cap(id: 3, legend: "space", width: 150),
                Cap(id: 4, legend: "⌘", width: 54, isTarget: code == KeyCode.rightCommand),
                Cap(id: 5, legend: "option", width: 44, isTarget: code == KeyCode.rightOption),
                Cap(id: 6, legend: "control", width: 50, isTarget: code == KeyCode.rightControl),
            ]
        }
    }
}
