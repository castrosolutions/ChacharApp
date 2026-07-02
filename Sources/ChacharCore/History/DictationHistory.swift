import Foundation

/// One dictation, as stored in the local history log.
///
/// Captures both texts: the `raw` recognition (straight from Whisper) and the `inserted` text that
/// actually reached the focused app (after Layer 1, and after Layer 2 cleanup when it was on). The
/// point is recovery — finding a prompt/transcription that was lost (e.g. an injection that failed).
public struct DictationRecord: Codable, Sendable, Equatable {
    public let date: Date
    /// Raw recognition from the ASR model.
    public let raw: String
    /// Text actually inserted (Layer 1 always; Layer 2 cleanup when the toggle was on).
    public let inserted: String
    /// Whether the Layer 2 LLM cleanup was applied to produce `inserted`.
    public let cleanupApplied: Bool
    /// Frontmost app the text was delivered to, if known.
    public let app: String?
    /// Transcription time in seconds.
    public let durationSeconds: Double

    public init(date: Date, raw: String, inserted: String, cleanupApplied: Bool,
                app: String?, durationSeconds: Double) {
        self.date = date
        self.raw = raw
        self.inserted = inserted
        self.cleanupApplied = cleanupApplied
        self.app = app
        self.durationSeconds = durationSeconds
    }
}

/// Append-only, **local** history of dictations, stored as JSON Lines (one record per line) so it
/// is crash-safe and easy to recover or tail. 100% on-disk in Application Support; nothing leaves
/// the machine.
///
/// `@unchecked Sendable`: file access is serialised by a lock so it can be called from any context.
public final class HistoryStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes] // compact: one line per record
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// `~/Library/Application Support/ChacharApp/history.jsonl`
    public static func defaultURL() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ChacharApp", directoryHint: .isDirectory)
        return base.appending(path: "history.jsonl")
    }

    /// Append one record as a single JSON line. Best-effort: never throws into the caller, so a
    /// logging failure can't break dictation.
    public func append(_ record: DictationRecord) {
        lock.lock(); defer { lock.unlock() }
        guard var data = try? encoder.encode(record) else { return }
        data.append(0x0A) // '\n' — JSON string values escape newlines, so each record stays one line
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// All records, oldest first. Tolerates malformed lines (skips them) so a partial write can't
    /// poison the whole log.
    public func load() -> [DictationRecord] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// Replace the whole log with `records` (oldest first). Used to delete individual entries or to
    /// apply a retention cap — the file is append-only in the hot path, so editing means a rewrite.
    public func overwrite(_ records: [DictationRecord]) {
        lock.lock(); defer { lock.unlock() }
        overwriteLocked(records)
    }

    /// Keep only the most recent `n` records (retention cap). No-op when `n <= 0` (unlimited) or the
    /// log already fits. Read + rewrite happen under one lock hold, so a dictation appended
    /// concurrently can't be lost between the two.
    public func trim(keepingLast n: Int) {
        guard n > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let all = loadLocked()
        guard all.count > n else { return }
        overwriteLocked(Array(all.suffix(n)))
    }

    /// Erase the whole history.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? Data().write(to: url)
    }

    // The lock is not reentrant, so the locking public API delegates to these unlocked bodies.

    private func loadLocked() -> [DictationRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(DictationRecord.self, from: data)
        }
    }

    private func overwriteLocked(_ records: [DictationRecord]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var blob = Data()
        for record in records {
            guard var data = try? encoder.encode(record) else { continue }
            data.append(0x0A)
            blob.append(data)
        }
        try? blob.write(to: url)
    }
}
