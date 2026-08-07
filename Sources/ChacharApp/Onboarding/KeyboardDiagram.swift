import ChacharCore
import SwiftUI

/// A stylised keyboard fragment that points at the push-to-talk key (or keys).
///
/// The setup guide can say "hold Right ⌘" in words, but Right ⌘ is a key most people have never
/// deliberately pressed and can't locate by name — the whole reason it makes a good push-to-talk
/// trigger is that nothing else uses it. So the guide shows *where* it is: the row it lives on,
/// its neighbours for orientation, and a caret underneath.
///
/// The rows shown follow the configured trigger, because the guide must not point at a key that
/// wouldn't do anything: right-hand modifiers get the bottom row, Right ⇧ its own row, the
/// function keys the function row, and a combo gets both rows its keys live on.
struct KeyboardDiagram: View {
    /// The trigger to point at — the first enabled one, chosen by the caller.
    let trigger: PushToTalkTrigger
    /// Mirror the real key: caps sink while the user is actually holding them down.
    var isPressed = false

    /// Draw attention to the target caps until the user has pressed them at least once.
    @State private var pulsing = false

    private static let liveTint = Color(red: 0.20, green: 0.68, blue: 0.44)

    var body: some View {
        let rows = Self.rows(for: trigger)
        VStack(spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .top, spacing: 5) {
                    // The caret belongs under the last row only: on a two-row combo one under the
                    // upper row would collide with the row beneath it.
                    ForEach(row) { cap in capView(cap, showCaret: index == rows.count - 1) }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }

    private func capView(_ cap: Cap, showCaret: Bool) -> some View {
        VStack(spacing: 4) {
            Keycap(cap.legend,
                   style: .window,
                   width: cap.width,
                   height: 30,
                   fontSize: cap.legend.count > 2 ? 10 : 13,
                   highlighted: cap.isTarget,
                   accent: Self.liveTint)
                .scaleEffect(cap.isTarget && isPressed ? 0.94 : 1)
                .shadow(color: Self.liveTint.opacity(shadowOpacity(cap.isTarget)), radius: 6)
                .animation(.easeOut(duration: 0.12), value: isPressed)
            // Non-target caps reserve the same height so the row doesn't shift when it appears.
            Image(systemName: "arrowtriangle.up.fill")
                .font(.system(size: 8))
                .foregroundStyle(Self.liveTint)
                .opacity(cap.isTarget && showCaret ? 1 : 0)
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

    /// The keyboard rows the trigger lives on, with its keys marked.
    ///
    /// Sized in the proportions of a real Mac keyboard rather than to fit the window — a row is
    /// recognisable only if the space bar dwarfs the modifiers the way it does on the desk.
    private static func rows(for trigger: PushToTalkTrigger) -> [[Cap]] {
        switch trigger {
        case .combo(let codes):
            // Both rows the chord spans, so the diagonal reach between them is visible.
            var result: [[Cap]] = []
            if codes.contains(KeyCode.leftShift) || codes.contains(KeyCode.rightShift) {
                result.append(shiftRow(leftIsTarget: codes.contains(KeyCode.leftShift),
                                       rightIsTarget: codes.contains(KeyCode.rightShift)))
            }
            result.append(bottomRow(targets: codes))
            return result

        case .modifier(KeyCode.rightShift):
            return [shiftRow(leftIsTarget: false, rightIsTarget: true)]

        case .key(let code):
            // Function row: show the neighbours so an unlabelled key can still be counted to.
            let keys = [KeyCode.f6: "F6", KeyCode.f7: "F7", KeyCode.f8: "F8"]
            let target = keys[code] ?? "F7"
            return [["F4", "F5", "F6", "F7", "F8", "F9", "F10"].enumerated().map {
                Cap(id: $0.offset, legend: $0.element, width: 38, isTarget: $0.element == target)
            }]

        case .modifier(let code):
            return [bottomRow(targets: [code])]
        }
    }

    /// The bottom row. Both halves are drawn because "Right ⌘" only means something next to a
    /// left ⌘ — the side is the whole instruction.
    private static func bottomRow(targets: Set<CGKeyCode>) -> [Cap] {
        [
            Cap(id: 0, legend: "control", width: 50, isTarget: targets.contains(59)),
            Cap(id: 1, legend: "option", width: 44, isTarget: targets.contains(58)),
            Cap(id: 2, legend: "⌘", width: 54, isTarget: targets.contains(KeyCode.leftCommand)),
            Cap(id: 3, legend: "space", width: 150),
            Cap(id: 4, legend: "⌘", width: 54, isTarget: targets.contains(KeyCode.rightCommand)),
            Cap(id: 5, legend: "option", width: 44, isTarget: targets.contains(KeyCode.rightOption)),
            Cap(id: 6, legend: "control", width: 50, isTarget: targets.contains(KeyCode.rightControl)),
        ]
    }

    private static func shiftRow(leftIsTarget: Bool, rightIsTarget: Bool) -> [Cap] {
        let letters = ["Z", "X", "C", "V", "B", "N", "M"]
        return [Cap(id: 0, legend: "⇧", width: 62, isTarget: leftIsTarget)]
            + letters.enumerated().map { Cap(id: $0.offset + 1, legend: $0.element, width: 30) }
            + [Cap(id: 8, legend: "⇧", width: 62, isTarget: rightIsTarget)]
    }
}
