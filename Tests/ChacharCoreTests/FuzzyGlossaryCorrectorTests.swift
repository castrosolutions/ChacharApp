import XCTest
@testable import ChacharCore

final class FuzzyGlossaryCorrectorTests: XCTestCase {
    // MARK: Phonetic key

    func testPhoneticKeyCollapsesGicoCamMishearings() {
        let target = PhoneticFold.key(for: "GicoCam")
        XCTAssertEqual(PhoneticFold.key(for: "hikokam"), target)
        XCTAssertEqual(PhoneticFold.key(for: "jicokam"), target)
        XCTAssertEqual(PhoneticFold.key(for: "hiko cam"), target) // spaces dropped
    }

    func testPhoneticKeyChacharApp() {
        let target = PhoneticFold.key(for: "ChacharApp")
        XCTAssertEqual(PhoneticFold.key(for: "chacharap"), target)            // exact phonetic
        XCTAssertEqual(PhoneticFold.key(for: "cha-cha-rap"), target)          // hyphens dropped
    }

    // MARK: Fuzzy replacement

    private func corrector(_ glossary: [String]) -> FuzzyGlossaryCorrector {
        FuzzyGlossaryCorrector(glossary: glossary)
    }

    func testReplacesSingleWordMishearing() {
        let c = corrector(["GicoCam"])
        XCTAssertEqual(c.correct("Abre hikokam ahora"), "Abre GicoCam ahora")
        XCTAssertEqual(c.correct("instalé jicokam"), "instalé GicoCam")
    }

    func testReplacesMultiWordWindow() {
        let c = corrector(["GicoCam"])
        // "hiko cam" (two words) → one term, without swallowing the trailing "a".
        XCTAssertEqual(c.correct("uso hiko cam a diario"), "uso GicoCam a diario")
    }

    func testReplacesNearMissChacharApp() {
        let c = corrector(["ChacharApp"])
        XCTAssertEqual(c.correct("chacharapo es genial"), "ChacharApp es genial") // edit distance 1
    }

    func testPreservesPunctuationAndCasing() {
        let c = corrector(["GicoCam"])
        XCTAssertEqual(c.correct("¿Funciona hikokam?"), "¿Funciona GicoCam?")
    }

    func testDoesNotChurnExactTerm() {
        let c = corrector(["GicoCam"])
        XCTAssertEqual(c.correct("uso GicoCam a diario"), "uso GicoCam a diario")
    }

    func testLeavesOrdinarySpanishWordsAlone() {
        let c = corrector(["GicoCam", "ChacharApp"])
        let sentence = "vamos a comer algo y luego volvemos a casa"
        XCTAssertEqual(c.correct(sentence), sentence)
    }

    func testSkipsShortGlossaryTerms() {
        // "S3"/"AWS"/"i3" phonetic keys are too short to fuzzy-match → no entries, text untouched.
        let c = corrector(["S3", "AWS", "i3"])
        XCTAssertEqual(c.correct("esto es asi y va de la a a la i"), "esto es asi y va de la a a la i")
    }

    func testEmptyGlossaryIsNoOp() {
        XCTAssertEqual(corrector([]).correct("texto cualquiera"), "texto cualquiera")
    }
}
