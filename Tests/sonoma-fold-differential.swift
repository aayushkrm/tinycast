import Foundation

/// Sonoma-branch-only differential: every launcher corpus case ranked through the raw and the
/// pre-folded path must come out in identical order, and the folded path must be no slower.
/// Wired only in sonoma-perf.yml, never in run-tests.sh.
@main
struct FoldDifferential {
    struct Entry: Codable {
        let key: String
        let kind: String
        let name: String
        let strongNames: [String]
        let translations: [String]
        var ownerName: String?
        var bundleID: String?
        var executableName: String?

        var fields: SearchFields {
            var sources = EntryNaming.Sources(name: name)
            sources.strongNames = strongNames
            sources.translations = translations
            sources.ownerName = ownerName
            sources.bundleID = bundleID
            sources.executableName = executableName
            return SearchFields(EntryNaming.aliases(for: sources))
        }
    }

    struct Case: Codable {
        let query: String
        let expect: String
        let criterion: String
    }

    struct Corpus: Codable {
        let entries: [Entry]
        let cases: [Case]
    }

    static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }

    static func main() {
        let url = URL(fileURLWithPath: "Tests/launcher-corpus/corpus.json")
        guard let data = try? Data(contentsOf: url),
            let corpus = try? JSONDecoder().decode(Corpus.self, from: data)
        else {
            print("FAIL corpus.json is unreadable — run from the repo root")
            exit(1)
        }
        let fields = corpus.entries.map(\.fields)
        let folded = fields.map(FoldedFields.init)
        let byKey = Dictionary(
            uniqueKeysWithValues: zip(corpus.entries.map(\.key), fields))
        let pairs = zip(corpus.entries, folded).map { $0 }
        let limit = corpus.entries.count
        var mismatches = 0
        for test in corpus.cases {
            let query = FuzzyMatch.Query(test.query)
            let old = LauncherOrder.ranked(
                corpus.entries, query: query, limit: limit,
                fields: { byKey[$0.key]! },
                usage: { _ in 0 }, name: \.name
            ).map(\.key)
            let new = LauncherOrder.rankedFolded(
                pairs, query: query, limit: limit, folded: { $0.1 },
                usage: { _ in 0 }, name: { $0.0.name }
            ).map { $0.0.key }
            if old != new {
                mismatches += 1
                let at = zip(old, new).firstIndex { $0 != $1 } ?? -1
                print("MISMATCH '\(test.query)' first divergence at \(at)")
            }
        }
        print("cases: \(corpus.cases.count), mismatches: \(mismatches)")
        guard mismatches == 0 else { exit(1) }

        let iterations = 30
        var oldTotal = 0.0
        var newTotal = 0.0
        for _ in 0..<iterations {
            for test in corpus.cases {
                let query = FuzzyMatch.Query(test.query)
                var start = ContinuousClock.now
                _ = LauncherOrder.ranked(
                    corpus.entries, query: query, limit: limit,
                    fields: { byKey[$0.key]! },
                    usage: { _ in 0 }, name: \.name)
                oldTotal += milliseconds(start)
                start = ContinuousClock.now
                _ = LauncherOrder.rankedFolded(
                    pairs, query: query, limit: limit, folded: { $0.1 },
                    usage: { _ in 0 }, name: { $0.0.name })
                newTotal += milliseconds(start)
            }
        }
        let queries = Double(iterations * corpus.cases.count)
        print(String(format: "raw mean_ms: %.3f folded mean_ms: %.3f",
            oldTotal / queries, newTotal / queries))
    }
}
