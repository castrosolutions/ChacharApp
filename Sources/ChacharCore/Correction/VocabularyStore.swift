import Foundation

/// Loads (and seeds) the user vocabulary from a JSON file, reloading when the file changes so
/// hand-edits take effect on the next utterance.
///
/// `@unchecked Sendable`: shared state is guarded by a lock so it can be read from any context.
public final class VocabularyStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var cached: Vocabulary
    private var lastModified: Date?
    private var _lastParseError: String?

    /// Human-readable reason the file on disk couldn't be parsed on the last reload, or `nil` if the
    /// current vocabulary loaded cleanly. Set when a hand-edit leaves `vocabulary.json` malformed:
    /// the store keeps the previous vocabulary (dictation never breaks) but records *why* here so the
    /// UI can tell the user instead of failing silently.
    public var lastParseError: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastParseError
    }

    public init(url: URL, seed: Vocabulary = .seed) {
        self.url = url
        self.cached = seed
        createIfMissing(seed: seed)
        _ = reloadIfChanged()
    }

    /// `~/Library/Application Support/ChacharApp/vocabulary.json`
    public static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ChacharApp", directoryHint: .isDirectory)
        return base.appending(path: "vocabulary.json")
    }

    public var current: Vocabulary {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// Reload from disk if the file changed since the last read; returns the current vocabulary.
    ///
    /// A malformed file does not throw and does not clobber the in-memory vocabulary — the previous
    /// one is kept so dictation keeps working — but the parse error is recorded in `lastParseError`
    /// (rather than swallowed), and `lastModified` is advanced so the same broken file isn't
    /// re-parsed on every utterance.
    @discardableResult
    public func reloadIfChanged() -> Vocabulary {
        lock.lock(); defer { lock.unlock() }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let modified, modified == lastModified { return cached }
        guard let data = try? Data(contentsOf: url) else { return cached }
        do {
            cached = try JSONDecoder().decode(Vocabulary.self, from: data)
            lastModified = modified
            _lastParseError = nil
        } catch {
            _lastParseError = "vocabulary.json couldn't be parsed (\(error.localizedDescription)). "
                + "Keeping the previously loaded vocabulary."
            lastModified = modified // don't retry the same broken file every dictation
        }
        return cached
    }

    /// Persist `vocabulary` to disk (pretty JSON) and update the in-memory cache so the next
    /// `reloadIfChanged()` is a no-op rather than re-reading. Returns `false` if writing failed.
    @discardableResult
    public func save(_ vocabulary: Vocabulary) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(vocabulary) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        } catch {
            return false
        }
        cached = vocabulary
        lastModified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        _lastParseError = nil // we just wrote valid JSON, so any earlier parse error is resolved
        return true
    }

    private func createIfMissing(seed: Vocabulary) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(seed) {
            try? data.write(to: url)
        }
    }
}
