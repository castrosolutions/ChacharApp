import XCTest
@testable import ChacharCore

final class HistoryStoreTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "chachar-history-\(UUID().uuidString).jsonl")
    }

    func testAppendAndLoadRoundTrips() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        let a = DictationRecord(date: Date(timeIntervalSince1970: 1), raw: "ola k ase",
                                inserted: "Hola, ¿qué hace?", cleanupApplied: true,
                                app: "Safari", durationSeconds: 1.2)
        let b = DictationRecord(date: Date(timeIntervalSince1970: 2), raw: "subelo a ese tres",
                                inserted: "Súbelo a S3", cleanupApplied: false,
                                app: nil, durationSeconds: 0.8)
        store.append(a)
        store.append(b)

        let loaded = store.load()
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first, a) // oldest first
        XCTAssertEqual(loaded.last, b)
        XCTAssertNil(loaded.last?.app)
    }

    func testToleratesMalformedLines() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        store.append(DictationRecord(date: Date(timeIntervalSince1970: 1), raw: "x", inserted: "X",
                                     cleanupApplied: false, app: nil, durationSeconds: 0))
        // Inject a junk line between valid records.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not json\n".utf8))
        try handle.close()
        store.append(DictationRecord(date: Date(timeIntervalSince1970: 3), raw: "y", inserted: "Y",
                                     cleanupApplied: false, app: nil, durationSeconds: 0))

        XCTAssertEqual(store.load().map(\.inserted), ["X", "Y"]) // malformed line skipped
    }

    func testOverwriteReplacesWholeLog() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        for i in 1...3 {
            store.append(DictationRecord(date: Date(timeIntervalSince1970: Double(i)), raw: "r\(i)",
                                         inserted: "I\(i)", cleanupApplied: false, app: nil, durationSeconds: 0))
        }
        // Simulate deleting the middle entry: rewrite with the survivors.
        let survivors = store.load().filter { $0.inserted != "I2" }
        store.overwrite(survivors)
        XCTAssertEqual(store.load().map(\.inserted), ["I1", "I3"])
    }

    func testTrimKeepsMostRecent() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        for i in 1...5 {
            store.append(DictationRecord(date: Date(timeIntervalSince1970: Double(i)), raw: "r\(i)",
                                         inserted: "I\(i)", cleanupApplied: false, app: nil, durationSeconds: 0))
        }
        store.trim(keepingLast: 2)
        XCTAssertEqual(store.load().map(\.inserted), ["I4", "I5"]) // oldest first, newest kept

        store.trim(keepingLast: 0) // unlimited: no-op
        XCTAssertEqual(store.load().count, 2)
    }

    func testClearEmpties() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HistoryStore(url: url)
        store.append(DictationRecord(date: Date(), raw: "a", inserted: "A",
                                     cleanupApplied: false, app: nil, durationSeconds: 0))
        XCTAssertEqual(store.load().count, 1)
        store.clear()
        XCTAssertEqual(store.load().count, 0)
    }
}
