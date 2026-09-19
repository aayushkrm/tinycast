import Foundation

/// One catalog entry's search text, folded once at load so keystrokes never re-fold it.
struct EmojiSearchText: Sendable {
    let name: String
    let nameLength: Int
    let keywordsWhole: String
    let keywords: [EmojiKeywordText]

    init(entry: EmojiEntry) {
        let name = FuzzyMatch.normalized(entry.name)
        let whole = FuzzyMatch.normalized(entry.keywords)
        self.name = name
        nameLength = name.count
        keywordsWhole = whole
        keywords = entry.keywords.split(separator: ",").map { raw in
            let folded = FuzzyMatch.normalized(String(raw))
            return EmojiKeywordText(keyword: folded, length: folded.count)
        }
    }
}

/// One pre-folded keyword plus the length the prefix tier scores against.
struct EmojiKeywordText: Sendable {
    let keyword: String
    let length: Int
}

/// The parsed catalog: sections precomputed at load, search memoized one query deep.
@MainActor
@Observable
final class EmojiIndex {
    private(set) var entries: [EmojiEntry] = []
    private(set) var categorySections: [(category: EmojiCategory, entries: [EmojiEntry])] = []

    /// `order` is the catalog index, the tie-break that keeps equal scores in catalog order.
    private struct ScoredEntry {
        let entry: EmojiEntry
        let score: Int
        let order: Int
    }

    private struct SearchKey: Equatable {
        let query: String
        let revision: Int
        let frequentID: ObjectIdentifier
        let frequentRevision: Int
        let limit: Int
    }

    private var byGlyph: [String: EmojiEntry] = [:]
    @ObservationIgnored private var searchMemo = Memo<SearchKey, [EmojiEntry]>()
    /// Folded once at load, so a keystroke never re-folds ~2.1k names and keyword lists.
    @ObservationIgnored private var normTexts: [EmojiSearchText] = []
    /// Bumped on each load, so the key above names the catalog it scored.
    private var revision = 0

    var isLoaded: Bool { !entries.isEmpty }

    func load(_ raw: String = EmojiData.raw) async {
        let parsed = await Task.detached(priority: .utility) { EmojiCatalog.parse(raw) }.value
        entries = parsed
        var grouped: [EmojiCategory: [EmojiEntry]] = [:]
        for entry in parsed { grouped[entry.category, default: []].append(entry) }
        categorySections = EmojiCategory.allCases.compactMap { category in
            grouped[category].map { (category, $0) }
        }
        byGlyph = Dictionary(parsed.map { ($0.glyph, $0) }, uniquingKeysWith: { first, _ in first })
        normTexts = parsed.map(EmojiSearchText.init(entry:))
        revision &+= 1
    }

    func entry(for glyph: String) -> EmojiEntry? { byGlyph[glyph] }

    /// Trimmed, unwrapped and word-split once, so `search` and `searchRequestKey` agree.
    private static func prepared(_ query: String) -> (q: String, words: [String]) {
        let trimmed = FuzzyMatch.normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        let unwrapped =
            trimmed.count > 2 && trimmed.first == ":" && trimmed.last == ":"
            ? String(trimmed.dropFirst().dropLast()) : trimmed
        let words = unwrapped.split(whereSeparator: \.isWhitespace).map(String.init)
        return (words.joined(separator: " "), words)
    }

    /// Ranked fuzzy matches over names and keywords; an empty query returns nothing.
    func search(_ query: String, frequent: FrequentEmojiStore, limit: Int = 320) -> [EmojiEntry] {
        let (q, words) = Self.prepared(query)
        guard !q.isEmpty, limit > 0 else { return [] }
        let key = SearchKey(
            query: q, revision: revision, frequentID: ObjectIdentifier(frequent),
            frequentRevision: frequent.revision, limit: limit)
        return searchMemo.value(for: key) {
            Self.runSearch(
                query: q, words: words, entries: entries, norms: normTexts,
                frequentGlyphs: frequent.top(Self.frecencyLimit), limit: limit)
        }
    }

    /// The scoring sweep, callable off the main thread: every input is a value snapshot.
    nonisolated static func runSearch(
        query q: String, words: [String], entries: [EmojiEntry], norms: [EmojiSearchText],
        frequentGlyphs: [String], limit: Int
    ) -> [EmojiEntry] {
        let query = FuzzyMatch.Query(q)
        let terms = words.count > 1 ? words : []
        let frecency = Dictionary(
            frequentGlyphs.enumerated().map {
                ($0.element, Self.frecencyLimit - $0.offset)
            }, uniquingKeysWith: max)
        var scored: [ScoredEntry] = []
        scored.reserveCapacity(entries.count)
        for (order, entry) in entries.enumerated() {
            guard
                let textScore = Self.textScore(
                    query, terms: terms, hasKeywords: !entry.keywords.isEmpty,
                    norm: norms[order])
            else { continue }
            let score = textScore + (frecency[entry.glyph] ?? 0)
            scored.append(ScoredEntry(entry: entry, score: score, order: order))
        }
        return
            scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .prefix(limit)
            .map(\.entry)
    }

    /// Search results published per applied query; the grid keeps showing the previous set
    /// while a new search resolves, so the search field echoes without waiting for scoring.
    private(set) var publishedSearch: [EmojiEntry] = []

    /// What triggers a re-search: the query plus every revision the output depends on.
    struct SearchRequestKey: Hashable, Sendable {
        let query: String
        let revision: Int
        let frequentRevision: Int
        let limit: Int
    }

    func searchRequestKey(
        query: String, frequent: FrequentEmojiStore, limit: Int = 320
    ) -> SearchRequestKey {
        let (q, _) = Self.prepared(query)
        return SearchRequestKey(
            query: q, revision: revision, frequentRevision: frequent.revision, limit: limit)
    }

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var completedSearchKey: SearchRequestKey?

    /// Whether the published search already answers this query: fresh output renders without
    /// waiting, anything else resolves synchronously once (first flight) or async (re-search).
    func hasFreshSearch(query: String, frequent: FrequentEmojiStore, limit: Int = 320) -> Bool {
        searchRequestKey(query: query, frequent: frequent, limit: limit) == completedSearchKey
    }

    /// Resolves the search off the main thread; empty queries publish nothing (the view shows
    /// frequents plus categories synchronously). Superseded requests cancel; stale completions
    /// are discarded.
    func requestSearch(query: String, frequent: FrequentEmojiStore, limit: Int = 320) {
        let key = searchRequestKey(query: query, frequent: frequent, limit: limit)
        // Already published for these exact inputs: an in-flight twin lands the same.
        guard key != completedSearchKey else { return }
        searchTask?.cancel()
        guard !key.query.isEmpty else {
            completedSearchKey = key
            publishedSearch = []
            return
        }
        let (q, words) = Self.prepared(query)
        let entriesSnapshot = entries
        let normsSnapshot = normTexts
        let frequentSnapshot = frequent.top(Self.frecencyLimit)
        searchTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.runSearch(
                    query: key.query, words: words, entries: entriesSnapshot,
                    norms: normsSnapshot, frequentGlyphs: frequentSnapshot, limit: key.limit)
            }.value
            guard !Task.isCancelled else { return }
            guard key == self.searchRequestKey(query: query, frequent: frequent, limit: limit)
            else { return }
            self.completedSearchKey = key
            self.publishedSearch = found
        }
    }

    /// Just under half a tier, so an equal-quality name match always wins.
    private nonisolated static let keywordPenalty = 500
    private nonisolated static let frecencyLimit = 100
    /// A complete leading name word: above an exact keyword, below the exact name.
    private nonisolated static let leadingWordScore = 95_000
    /// Scattered query words rank below every literal phrase, name-only words first.
    private nonisolated static let nameWordsScore = 60_000
    private nonisolated static let mixedWordsScore = 50_000

    private nonisolated static func textScore(
        _ query: FuzzyMatch.Query, terms: [String], hasKeywords: Bool, norm: EmojiSearchText
    ) -> Int? {
        var nameOnly = true
        if !terms.isEmpty {
            for term in terms where !Self.containsWordStart(term, in: norm.name) {
                guard !term.contains(","), Self.containsWordStart(term, in: norm.keywordsWhole)
                else { return nil }
                nameOnly = false
            }
        }

        let nameMatch = FuzzyMatch.match(
            query, normalizedCandidate: norm.name, candidateLength: norm.nameLength)
        if nameMatch?.tier == .exact { return nameMatch?.score }
        var best = nameMatch?.score
        if let nameMatch, nameMatch.tier == .prefix,
            let next = norm.name.dropFirst(nameMatch.queryLength).first,
            !next.isLetter && !next.isNumber
        {
            best = Self.leadingWordScore - nameMatch.candidateLength
        }
        if !terms.isEmpty {
            let ordered = nameMatch?.tier == .subsequence ? nameMatch?.score ?? 0 : 0
            best = max(best ?? Int.min, (nameOnly ? Self.nameWordsScore : Self.mixedWordsScore) + ordered)
        }
        guard hasKeywords,
            FuzzyMatch.match(
                query, normalizedCandidate: norm.keywordsWhole,
                candidateLength: norm.keywordsWhole.count) != nil
        else { return best }
        for part in norm.keywords {
            guard
                let match = FuzzyMatch.match(
                    query, normalizedCandidate: part.keyword, candidateLength: part.length)
            else { continue }
            best = max(best ?? Int.min, min(match.score, Self.leadingWordScore) - Self.keywordPenalty)
            if match.tier == .exact { break }
        }
        return best
    }

    private nonisolated static func containsWordStart(
        _ term: String, in candidate: String
    ) -> Bool {
        var start = candidate.startIndex
        while let range = candidate.range(of: term, range: start..<candidate.endIndex) {
            if range.lowerBound == candidate.startIndex { return true }
            let previous = candidate[candidate.index(before: range.lowerBound)]
            if !previous.isLetter && !previous.isNumber { return true }
            start = candidate.index(after: range.lowerBound)
        }
        return false
    }
}
