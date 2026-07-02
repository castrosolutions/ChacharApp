import CoreGraphics

/// Named macOS virtual key codes (`kVK_*`), so key handling reads as `.key(KeyCode.f7)`
/// instead of the magic number `.key(98)`.
///
/// Grouping every keycode the app cares about here makes them searchable and self-describing,
/// and gives the push-to-talk catalog and the paste injector a single source of truth.
public enum KeyCode {
    // Function row (built-in keyboard).
    public static let f6: CGKeyCode = 97
    public static let f7: CGKeyCode = 98
    public static let f8: CGKeyCode = 100

    // Right-hand modifiers — the ones that work reliably as global push-to-talk on external
    // keyboards whose function row is intercepted by their own software.
    public static let rightCommand: CGKeyCode = 54
    public static let rightShift: CGKeyCode = 60
    public static let rightOption: CGKeyCode = 61
    public static let rightControl: CGKeyCode = 62

    // Letters.
    public static let ansiV: CGKeyCode = 9 // kVK_ANSI_V — synthesized for the paste (⌘V) injector
}
