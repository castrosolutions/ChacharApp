import XCTest
@testable import ChacharCore

final class DictionaryCorrectorTests: XCTestCase {
    func testWholeWordCaseInsensitiveReplace() {
        let corrector = DictionaryCorrector([.init(from: "cubernetes", to: "Kubernetes")])
        XCTAssertEqual(corrector.correct("desplegando en Cubernetes hoy"),
                       "desplegando en Kubernetes hoy")
    }

    func testDoesNotReplaceInsideWords() {
        let corrector = DictionaryCorrector([.init(from: "s3", to: "S3")])
        XCTAssertEqual(corrector.correct("sube a s3"), "sube a S3")
        XCTAssertEqual(corrector.correct("express3"), "express3") // no word boundary → untouched
    }

    func testOrderedMultiWordReplacements() {
        let corrector = DictionaryCorrector([
            .init(from: "ese tres", to: "S3"),
            .init(from: "a w s", to: "AWS"),
        ])
        XCTAssertEqual(corrector.correct("sube a ese tres en a w s"), "sube a S3 en AWS")
    }

    func testEmptyReplacementsAreNoOp() {
        let corrector = DictionaryCorrector([])
        XCTAssertEqual(corrector.correct("nada cambia"), "nada cambia")
    }

    func testGlossaryPromptJoinsTerms() {
        let vocab = Vocabulary(glossary: ["AWS", "S3", "Kubernetes"])
        XCTAssertEqual(vocab.glossaryPrompt, "AWS, S3, Kubernetes")
        XCTAssertNil(Vocabulary(glossary: []).glossaryPrompt)
    }
}
