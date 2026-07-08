import ChacharCore
import Combine
import Foundation
import SwiftUI

/// Backs the Vocabulary tab: edits the glossary (terms biased toward in recognition) and the
/// deterministic replacement rules (Layer 1), then persists them via the shared `VocabularyStore`
/// so the next dictation picks them up. Rows carry a stable `id` for SwiftUI editing; the saved
/// `Vocabulary` is sanitised (trimmed, empties dropped, defaults normalised).
@MainActor
final class VocabularyViewModel: ObservableObject {
    struct TermItem: Identifiable, Equatable { let id = UUID(); var term: String }
    struct RuleItem: Identifiable, Equatable {
        let id = UUID()
        var from: String
        var to: String
        var caseSensitive: Bool
        var wholeWord: Bool
    }

    private let store: VocabularyStore
    @Published var terms: [TermItem] = []
    @Published var rules: [RuleItem] = []
    @Published private(set) var statusMessage: String?

    init(store: VocabularyStore) {
        self.store = store
        reload()
    }

    /// (Re)load from the store, discarding unsaved edits.
    func reload() {
        let vocab = store.current
        terms = vocab.glossary.map { TermItem(term: $0) }
        rules = vocab.replacements.map {
            RuleItem(from: $0.from, to: $0.to,
                     caseSensitive: $0.caseSensitive ?? false,
                     wholeWord: $0.wholeWord ?? true)
        }
        statusMessage = nil
    }

    func addTerm() { terms.append(TermItem(term: "")); statusMessage = nil }
    func removeTerm(_ item: TermItem) { terms.removeAll { $0.id == item.id }; statusMessage = nil }
    func addRule() { rules.append(RuleItem(from: "", to: "", caseSensitive: false, wholeWord: true)); statusMessage = nil }
    func removeRule(_ item: RuleItem) { rules.removeAll { $0.id == item.id }; statusMessage = nil }

    // Row bindings resolve their element by `id` at call time (with a guard), never by a
    // stored array index. `ForEach($terms)` would instead hand each row an index-based binding;
    // when the array is replaced/shrunk underneath a `TextField` that is still committing —
    // e.g. `save()` → `reload()` drops empty rows during the same layout pass — that stale index
    // trips `Array._checkSubscript` and traps ("Index out of range", crash in 1.3.0). Resolving by
    // id makes a vanished element read back as the fallback instead of crashing.
    func binding(forTerm id: TermItem.ID) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.terms.first { $0.id == id }?.term ?? "" },
            set: { [weak self] value in
                guard let self, let i = self.terms.firstIndex(where: { $0.id == id }) else { return }
                self.terms[i].term = value
            }
        )
    }

    func binding<V>(forRule id: RuleItem.ID, _ keyPath: WritableKeyPath<RuleItem, V>, default fallback: V) -> Binding<V> {
        Binding(
            get: { [weak self] in self?.rules.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
            set: { [weak self] value in
                guard let self, let i = self.rules.firstIndex(where: { $0.id == id }) else { return }
                self.rules[i][keyPath: keyPath] = value
            }
        )
    }

    /// The sanitised vocabulary that would be saved: trimmed terms, empty terms/rules dropped, and
    /// default flags normalised back to `nil` to keep the JSON clean.
    var sanitized: Vocabulary {
        let glossary = terms
            .map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let replacements: [Vocabulary.Replacement] = rules.compactMap { rule in
            let from = rule.from.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !from.isEmpty else { return nil }       // a rule with no "from" is a no-op
            return Vocabulary.Replacement(
                from: from,
                to: rule.to,
                caseSensitive: rule.caseSensitive ? true : nil,
                wholeWord: rule.wholeWord ? nil : false
            )
        }
        return Vocabulary(glossary: glossary, replacements: replacements)
    }

    /// Whether there are unsaved changes versus what's on disk.
    var isDirty: Bool { sanitized != store.current }

    /// Count of rows that will be dropped on save (empty terms / rules without a "from").
    var droppedCount: Int {
        let emptyTerms = terms.filter { $0.term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let emptyRules = rules.filter { $0.from.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        return emptyTerms + emptyRules
    }

    func save() {
        if store.save(sanitized) {
            reload()
            statusMessage = "Saved."
        } else {
            statusMessage = "Could not save."
        }
    }
}
