import XCTest
@testable import ChacharCore

final class HallucinationFilterTests: XCTestCase {
    private let filter = HallucinationFilter()

    func testStripsTrailingGraciasAsOwnSentence() {
        XCTAssertEqual(filter.correct("Vamos a desplegar el servicio. Gracias."),
                       "Vamos a desplegar el servicio.")
    }

    func testStripsWholeOutputWhenItIsOnlyTheHallucination() {
        XCTAssertEqual(filter.correct("Gracias."), "")
        XCTAssertEqual(filter.correct("¡Gracias!"), "")
        XCTAssertEqual(filter.correct("Thank you"), "")
    }

    func testKeepsGraciasWhenItIsPartOfARealSentence() {
        // Mid-sentence: not an isolated trailing clause, so it must be preserved.
        XCTAssertEqual(filter.correct("Muchas gracias por tu ayuda"),
                       "Muchas gracias por tu ayuda")
        XCTAssertEqual(filter.correct("Te lo agradezco, gracias a ti todo salió bien"),
                       "Te lo agradezco, gracias a ti todo salió bien")
    }

    func testStripsSubtitleStyleCredit() {
        XCTAssertEqual(filter.correct("Revisamos el informe mañana. Gracias por ver el vídeo."),
                       "Revisamos el informe mañana.")
    }

    func testLeavesNormalTextUntouched() {
        XCTAssertEqual(filter.correct("El pipeline ya está en producción."),
                       "El pipeline ya está en producción.")
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(filter.correct(""), "")
        XCTAssertEqual(filter.correct("   "), "   ")
    }
}
