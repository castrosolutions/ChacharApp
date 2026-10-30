import AppKit
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
///
/// The probe refuses (``Verdict/none``) only when it has *seen* the focused element and recognised
/// it as untypeable. "Couldn't find a focused element" is never a refusal on its own: Chromium and
/// Electron apps (Chrome, Slack, VS Code, Claude, Notion…) keep their Accessibility tree dormant
/// until an assistive client wakes it, and until then the system-wide focus query answers
/// `kAXErrorNoValue` even with the caret sitting in a text field. Treating that as "nowhere to
/// insert" blocked every dictation in those apps on machines where no other assistive tool had
/// already woken the tree (1.5.0–1.7.0).
public enum FocusedTextTarget {

    public enum Verdict: Sendable, Equatable {
        /// Something with a text caret has focus — paste away.
        case editable
        /// The focused element was found and can't take text (a button, a file list, a web page).
        case none
        /// Couldn't tell: Accessibility is unavailable, the app didn't answer, it published no
        /// focused element, or it describes itself in a way this probe doesn't recognise.
        case unknown
    }

    /// What the probe could read about the focused element — the input of the pure decision.
    struct ElementTraits: Equatable {
        var hasSelectedTextRange = false
        var role: String?
        var valueSettable = false
    }

    /// The outcome of one "which element has keyboard focus?" query.
    enum Lookup: Equatable {
        /// An element was returned.
        case element(ElementTraits)
        /// The query worked but named no element (`kAXErrorNoValue` / `…AttributeUnsupported`):
        /// either nothing is focused, or the app hasn't built its Accessibility tree yet.
        case missing
        /// The query itself failed (no Accessibility grant, app busy or wedged…).
        case failed
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

    /// Chromium/Electron's switch for building its Accessibility tree on demand, without the
    /// side effects of `AXEnhancedUserInterface` (which makes some apps animate window moves
    /// oddly). Apps that don't know it just answer "unsupported".
    private static let manualAccessibilityAttribute = "AXManualAccessibility"

    // MARK: Decision (pure)

    /// The verdict for one element that was found.
    static func classify(_ traits: ElementTraits) -> Verdict {
        // A selected-text range is the strongest signal there is: native fields, web
        // contenteditable areas and terminal emulators all expose one, and non-text elements
        // don't. Check it before roles, which vary far more between toolkits.
        if traits.hasSelectedTextRange { return .editable }
        guard let role = traits.role else { return .unknown }
        if textRoles.contains(role) { return .editable }
        // Some custom controls advertise editability only through a settable value.
        if traits.valueSettable { return .editable }
        // Refuse only for roles known to be untypeable; anything else is a toolkit this doesn't
        // recognise, and a paste is far cheaper to get wrong than a refusal.
        return nonTextRoles.contains(role) ? .none : .unknown
    }

    /// The whole decision: the system-wide answer first, then — only when it named no element —
    /// the frontmost app asked directly (`frontmostApp` is lazy, so the common path never pays for
    /// it). No element from either is ``Verdict/unknown``, never ``Verdict/none``.
    static func decide(systemWide: Lookup, frontmostApp: () -> Lookup) -> Verdict {
        switch systemWide {
        case .element(let traits):
            return classify(traits)
        case .failed:
            return .unknown
        case .missing:
            if case .element(let traits) = frontmostApp() { return classify(traits) }
            return .unknown
        }
    }

    // MARK: Accessibility reads

    @MainActor
    public static func probe() -> Verdict {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        let systemWide = focusedElement(of: system)

        var appDetail = "-"
        let verdict = decide(systemWide: systemWide.lookup) {
            let (lookup, detail) = frontmostAppLookup()
            appDetail = detail
            return lookup
        }
        // Only with CHACHARAPP_DEBUG. Says *why*, not just what: when a paste misbehaves in some
        // app, the raw AX errors are what tell a dormant tree from a wedged app from no focus.
        chacharLog("focus probe: \(verdict) — system-wide: \(systemWide.detail); frontmost app: \(appDetail)")
        return verdict
    }

    /// Ask the frontmost app itself for its focused element. If it published none, nudge a
    /// Chromium/Electron app into building its Accessibility tree and ask once more — that both
    /// rescues this verdict when the tree comes up fast and makes every later probe in that app
    /// answer on the first, system-wide query.
    @MainActor
    private static func frontmostAppLookup() -> (Lookup, String) {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return (.failed, "none")
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let name = app.bundleIdentifier ?? "pid \(app.processIdentifier)"

        let first = focusedElement(of: element)
        guard first.lookup == .missing else { return (first.lookup, "\(name) \(first.detail)") }

        let woke = AXUIElementSetAttributeValue(element, manualAccessibilityAttribute as CFString,
                                                kCFBooleanTrue)
        guard woke == .success else {
            return (first.lookup, "\(name) \(first.detail), manual AX: \(woke.rawValue)")
        }
        let retry = focusedElement(of: element)
        return (retry.lookup, "\(name) \(first.detail), manual AX on, retry: \(retry.detail)")
    }

    /// Query `kAXFocusedUIElementAttribute` on `element` (system-wide or one app) and read the
    /// traits ``classify(_:)`` needs. `detail` is a short description for the diagnostics log.
    private static func focusedElement(of element: AXUIElement) -> (lookup: Lookup, detail: String) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString,
                                                  &value)
        switch error {
        case .success:
            break
        case .noValue, .attributeUnsupported:
            return (.missing, "no element (\(error.rawValue))")
        default:
            // .apiDisabled (no Accessibility grant), .cannotComplete (app busy), and friends.
            return (.failed, "error \(error.rawValue)")
        }
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return (.failed, "not an element")
        }
        let focused = value as! AXUIElement // checked by the type-id guard above

        var traits = ElementTraits()
        traits.hasSelectedTextRange = hasAttribute(focused, kAXSelectedTextRangeAttribute)
        traits.role = copyString(focused, kAXRoleAttribute)
        var settable = DarwinBoolean(false)
        traits.valueSettable =
            AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue
        return (.element(traits), "role \(traits.role ?? "?")\(traits.hasSelectedTextRange ? " +caret" : "")")
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
