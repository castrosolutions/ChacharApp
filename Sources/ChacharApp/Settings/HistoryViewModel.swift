import ChacharCore
import Combine
import Foundation

/// One history row for the viewer. `id` is the record's index in the on-disk (oldest-first) log, so
/// deletes map back to a precise position; it stays valid because we reload after every mutation.
struct HistoryItem: Identifiable, Equatable {
    let id: Int
    let record: DictationRecord
}

/// Backs the history viewer: loads records from the `HistoryStore`, exposes them newest-first,
/// filters by a search query, and supports per-row delete and clear-all.
@MainActor
final class HistoryViewModel: ObservableObject {
    private let store: HistoryStore
    /// Full log, oldest first — the source of truth for rewrites.
    private var records: [DictationRecord] = []

    /// Rows for display, newest first.
    @Published private(set) var items: [HistoryItem] = []
    @Published var query: String = ""

    init(store: HistoryStore) {
        self.store = store
        reload()
    }

    func reload() {
        records = store.load()
        items = records.enumerated()
            .map { HistoryItem(id: $0.offset, record: $0.element) }
            .reversed()
    }

    /// Rows matching the current query (case/diacritic-insensitive over raw, final and app).
    var filtered: [HistoryItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return items }
        return items.filter { item in
            let haystack = [item.record.raw, item.record.inserted, item.record.app ?? ""].joined(separator: "\n")
            return haystack.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    func delete(_ item: HistoryItem) {
        guard records.indices.contains(item.id) else { return }
        records.remove(at: item.id)
        store.overwrite(records)
        reload()
    }

    func clearAll() {
        store.clear()
        reload()
    }
}
