import ApplicationServices

/// Asks the Accessibility API a single question: *does typed text have anywhere to go right now?*
///
/// A synthetic ⌘V into an app with no focused text field does nothing at all, silently — no error,
/// no clue. That is how a dictation could be reported as inserted when the words went nowhere
/// (switching apps mid-dictation, a Finder window, a web page with nothing focused). Looking first
/// is the only way to tell the difference.
///
/// The verdict is deliberately three-valued. Accessibility trees are uneven — Electron apps,
/// terminals and custom controls all describe themselves differently — so anything this can't read
/// confidently comes back ``Verdict/unknown``, and callers treat that as "paste anyway". Being
/// wrong in that direction costs nothing (it is exactly the old behaviour); being wrong the other
/// way would break insertion in an app where it works today.
public enum FocusedTextTarget {

    public enum Verdict: Sendable, Equatable {
        /// Something with a text caret has focus — paste away.
        case editable
        /// Focus exists but can't take text (a button, a file list, a web page), or nothing at all
        /// has keyboard focus.
        case none
        /// Couldn't tell: Accessibility is unavailable, the app didn't answer, or it describes
        /// itself in a way this probe doesn't recognise.
        case unknown
    }

    /// Roles that are text entry by definition, for elements that don't expose a caret.
    private static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
    ]

    /// Roles that certainly cannot take dictated text. Insertion is blocked only for these — an
    /// *allowlist of refusals*, not "deny anything I don't recognise". A role this doesn't know
    /// falls through to ``Verdict/unknown`` and the paste goes ahead, so an unfamiliar toolkit can
    /// never cost the user their words; the list only has to cover where focus actually lands when
    /// there is nothing to type into (a file list, a web page, a button, the desktop).
    private static let nonTextRoles: Set<String> = [
        kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXPopUpButtonRole, kAXMenuButtonRole,
        kAXMenuItemRole, kAXMenuRole, kAXMenuBarRole, kAXMenuBarItemRole,
        kAXOutlineRole, kAXTableRole, kAXRowRole, kAXCellRole, kAXColumnRole, kAXListRole,
        kAXBrowserRole, kAXScrollAreaRole, kAXSplitGroupRole, kAXTabGroupRole, kAXToolbarRole,
        kAXGroupRole, kAXWindowRole, kAXSheetRole, kAXDrawerRole, kAXImageRole, kAXStaticTextRole,
        kAXSliderRole, kAXProgressIndicatorRole, kAXDisclosureTriangleRole,
        // Not all roles have constants in ApplicationServices; these come from the web/AXAPI
        // vocabulary that browsers use.
        "AXLink", "AXWebArea", "AXHeading", "AXApplication",
    ]

    /// How long to wait for the focused app to answer. Long enough for a healthy app (these
    /// normally return in about a millisecond), short enough that a wedged one can't stall the
    /// dictation it is holding up.
    private static let messagingTimeout: Float = 0.25

    public static func probe() -> Verdict {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)

        var value: CFTypeRef?
        switch AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) {
        case .success:
            break
        case .noValue, .attributeUnsupported:
            return .none // nothing anywhere holds keyboard focus
        default:
            // .apiDisabled (no Accessibility grant), .cannotComplete (app busy), and friends. We
            // know nothing, so don't stand between the user and their paste.
            return .unknown
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unknown }
        let element = value as! AXUIElement // checked by the type-id guard above

        // A selected-text range is the strongest signal there is: native fields, web
        // contenteditable areas and terminal emulators all expose one, and non-text elements
        // don't. Check it before roles, which vary far more between toolkits.
        if hasAttribute(element, kAXSelectedTextRangeAttribute) { return .editable }

        guard let role = copyString(element, kAXRoleAttribute) else { return .unknown }
        if textRoles.contains(role) { return .editable }

        // Some custom controls advertise editability only through a settable value.
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return .editable
        }

        // Refuse only for roles known to be untypeable; anything else is a toolkit this doesn't
        // recognise, and a paste is far cheaper to get wrong than a refusal.
        return nonTextRoles.contains(role) ? .none : .unknown
    }

    private static func hasAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
    }

    private static func copyString(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}
