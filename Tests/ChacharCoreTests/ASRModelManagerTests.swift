import XCTest
@testable import ChacharCore

final class ASRModelManagerTests: XCTestCase {
    private let fm = FileManager.default

    private func makeFolder(_ entries: [String]) throws -> URL {
        let dir = fm.temporaryDirectory.appending(path: "chachar-model-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for entry in entries {
            // .mlmodelc / .mlpackage are directories on disk; an empty dir is enough for the check.
            try fm.createDirectory(at: dir.appending(path: entry), withIntermediateDirectories: true)
        }
        return dir
    }

    func testValidCompiledModelFolder() throws {
        let dir = try makeFolder(["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"])
        defer { try? fm.removeItem(at: dir) }
        XCTAssertTrue(ASRModelManager.isValidModelFolder(dir))
    }

    func testValidPackageModelFolder() throws {
        let dir = try makeFolder(["MelSpectrogram.mlpackage", "AudioEncoder.mlpackage", "TextDecoder.mlpackage"])
        defer { try? fm.removeItem(at: dir) }
        XCTAssertTrue(ASRModelManager.isValidModelFolder(dir))
    }

    func testMissingSubmodelIsInvalid() throws {
        let dir = try makeFolder(["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc"]) // no TextDecoder
        defer { try? fm.removeItem(at: dir) }
        XCTAssertFalse(ASRModelManager.isValidModelFolder(dir))
    }

    func testOfflineTokenizerDetection() throws {
        let dir = try makeFolder(["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"])
        defer { try? fm.removeItem(at: dir) }
        XCTAssertFalse(ASRModelManager.hasOfflineTokenizer(dir))
        try Data("{}".utf8).write(to: dir.appending(path: "tokenizer.json"))
        XCTAssertTrue(ASRModelManager.hasOfflineTokenizer(dir))
    }
}
