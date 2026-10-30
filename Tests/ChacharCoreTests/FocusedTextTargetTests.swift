import XCTest
@testable import ChacharCore

/// The probe's decision logic, fed canned Accessibility answers (tests have no AX tree). The rule
/// under test: refuse to paste only after *seeing* an untypeable element — never because no
/// element could be found, which is how Chromium/Electron apps answer while their tree is dormant.
final class FocusedTextTargetTests: XCTestCase {

    private typealias Traits = FocusedTextTarget.ElementTraits

    private func decide(_ systemWide: FocusedTextTarget.Lookup,
                        app: FocusedTextTarget.Lookup = .failed,
                        appAsked: UnsafeMutablePointer<Bool>? = nil) -> FocusedTextTarget.Verdict {
        FocusedTextTarget.decide(systemWide: systemWide) {
            appAsked?.pointee = true
            return app
        }
    }

    // MARK: Regression — the 1.5.0–1.7.0 "Nowhere to insert this" in every Electron app

    func testNoElementAnywhereIsUnknownNotNone() {
        XCTAssertEqual(decide(.missing, app: .missing), .unknown)
    }

    func testNoElementAndFrontmostAppUnreadableIsUnknown() {
        XCTAssertEqual(decide(.missing, app: .failed), .unknown)
    }

    func testFrontmostAppAnswersWhenSystemWideHasNoElement() {
        let field = Traits(hasSelectedTextRange: true, role: "AXTextArea")
        XCTAssertEqual(decide(.missing, app: .element(field)), .editable)
    }

    func testFrontmostAppCanStillRefuseWithAKnownUntypeableRole() {
        XCTAssertEqual(decide(.missing, app: .element(Traits(role: "AXWebArea"))), .none)
    }

    // MARK: System-wide answers

    func testFrontmostAppNotAskedWhenSystemWideFoundAnElement() {
        var asked = false
        _ = decide(.element(Traits(role: "AXTextField")), app: .missing, appAsked: &asked)
        XCTAssertFalse(asked)
    }

    func testFailedSystemWideQueryIsUnknown() {
        XCTAssertEqual(decide(.failed, app: .element(Traits(role: "AXButton"))), .unknown)
    }

    // MARK: classify

    func testCaretMeansEditableWhateverTheRole() {
        XCTAssertEqual(FocusedTextTarget.classify(Traits(hasSelectedTextRange: true, role: "AXGroup")),
                       .editable)
    }

    func testTextRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertEqual(FocusedTextTarget.classify(Traits(role: role)), .editable, role)
        }
    }

    func testSettableValueIsEditable() {
        XCTAssertEqual(FocusedTextTarget.classify(Traits(role: "AXCustomThing", valueSettable: true)),
                       .editable)
    }

    func testKnownUntypeableRolesRefuse() {
        for role in ["AXButton", "AXList", "AXOutline", "AXWebArea", "AXWindow"] {
            XCTAssertEqual(FocusedTextTarget.classify(Traits(role: role)), .none, role)
        }
    }

    func testUnrecognisedOrMissingRoleIsUnknown() {
        XCTAssertEqual(FocusedTextTarget.classify(Traits(role: "AXSomethingNew")), .unknown)
        XCTAssertEqual(FocusedTextTarget.classify(Traits()), .unknown)
    }
}
