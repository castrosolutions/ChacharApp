import XCTest
@testable import ChacharCore

final class VocabularyStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "chachar-vocab-\(UUID().uuidString).json")
    }

    func testSaveRoundTripsAndUpdatesCache() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VocabularyStore(url: url)

        let vocab = Vocabulary(
            glossary: ["GicoCam", "ChacharApp"],
            replacements: [Vocabulary.Replacement(from: "ese tres", to: "S3")]
        )
        XCTAssertTrue(store.save(vocab))

        // In-memory cache reflects the save without a reload from disk.
        XCTAssertEqual(store.current, vocab)
        // A fresh store reading the same file decodes the same content.
        let reopened = VocabularyStore(url: url)
        XCTAssertEqual(reopened.current.glossary, ["GicoCam", "ChacharApp"])
        XCTAssertEqual(reopened.current.replacements.first?.to, "S3")
    }

    func testSaveThenReloadIfChangedIsNoOp() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VocabularyStore(url: url)
        let vocab = Vocabulary(glossary: ["MLX"], replacements: [])
        store.save(vocab)
        // Saving updates lastModified, so reloadIfChanged should return the cached value as-is.
        XCTAssertEqual(store.reloadIfChanged(), vocab)
    }

    func testMalformedReloadKeepsPreviousVocabularyAndRecordsError() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = VocabularyStore(url: url)

        // Start from a known-good vocabulary loaded cleanly (no parse error).
        let good = Vocabulary(glossary: ["Kubernetes"], replacements: [])
        XCTAssertTrue(store.save(good))
        XCTAssertNil(store.lastParseError)

        // Simulate a hand-edit that leaves the file malformed. Bump the modification date so
        // reloadIfChanged() actually re-reads instead of short-circuiting on an unchanged mtime.
        try Data("{ not valid json".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: url.path)

        // The broken file must not clobber the in-memory vocabulary; the failure is recorded, not
        // swallowed, so the UI can surface it.
        let after = store.reloadIfChanged()
        XCTAssertEqual(after, good, "a malformed file must not clobber the loaded vocabulary")
        XCTAssertEqual(store.current, good)
        XCTAssertNotNil(store.lastParseError)

        // Writing valid JSON again resolves the recorded error.
        XCTAssertTrue(store.save(Vocabulary(glossary: ["MLX"], replacements: [])))
        XCTAssertNil(store.lastParseError)
    }
}
