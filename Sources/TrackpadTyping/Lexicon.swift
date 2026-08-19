import Foundation

/// The vocabulary the decoder searches, with a prior over words.
///
/// Three tiers, in descending confidence:
///   1. `CommonWords.ordered` — frequency-ranked, carries the real language model.
///   2. /usr/share/dict/words — broad coverage, uniformly low prior.
///   3. words the user has accepted — promoted so personal vocabulary sticks.
final class Lexicon {
    private(set) var words: [String] = []
    /// -log(rank), so 0 is the most likely word and values fall as words rarify.
    private(set) var logPrior: [Double] = []
    /// True for the frequency-ranked core vocabulary. The fallback tier is a
    /// coverage net, not a peer: it is scored with a flat extra penalty so an
    /// archaic word cannot win on shape against a word people actually use.
    private(set) var isCore: [Bool] = []

    /// words[] indices bucketed by (first letter, last letter). Endpoint
    /// pruning is what makes the search cheap: a glide's start and end are its
    /// most reliably observed features, so they cut the candidate set by orders
    /// of magnitude before any shape maths runs.
    private var buckets: [[Int]] = Array(repeating: [], count: 26 * 26)

    private var indexOfWord: [String: Int] = [:]
    private var learned: [String: Int] = [:]

    private let config: Config

    init(config: Config) {
        self.config = config
        loadCore()
        if config.useSystemDictionary { loadSystemDictionary() }
        loadLearned()
    }

    // MARK: - Loading

    private static func bucketKey(_ w: String) -> Int? {
        guard let f = w.first?.asciiValue, let l = w.last?.asciiValue,
              f >= 97, f <= 122, l >= 97, l <= 122 else { return nil }
        return Int(f - 97) * 26 + Int(l - 97)
    }

    private func add(_ word: String, rank: Double, core: Bool) {
        guard indexOfWord[word] == nil, let key = Self.bucketKey(word) else { return }
        let idx = words.count
        words.append(word)
        logPrior.append(-Foundation.log(rank + 1.0))
        isCore.append(core)
        buckets[key].append(idx)
        indexOfWord[word] = idx
    }

    private func loadCore() {
        var rank = 0.0
        for w in CommonWords.ordered {
            guard indexOfWord[w] == nil else { continue }   // list has intentional repeats
            add(w, rank: rank, core: true)
            rank += 1
        }
    }

    private func loadSystemDictionary() {
        let path = "/usr/share/dict/words"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let w = String(line)
            guard w.count >= 2, w.count <= 14 else { continue }
            guard w.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else { continue }
            add(w, rank: config.fallbackRank, core: false)
        }
    }

    // MARK: - Learning

    private var learnedURL: URL { Config.supportDirectory.appendingPathComponent("learned.json") }

    private func loadLearned() {
        guard let data = try? Data(contentsOf: learnedURL),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        learned = dict
        for (w, _) in dict { applyLearnedPrior(w) }
    }

    /// Accepting a word pulls it up the ranking. The effect saturates: repeated
    /// use should make a word competitive, not make it beat everything.
    private func applyLearnedPrior(_ word: String) {
        guard let idx = indexOfWord[word] else { return }
        let count = Double(learned[word] ?? 0)
        guard count > 0 else { return }
        let boost = Foundation.log(1.0 + count) * 1.2
        // Two accepts are enough to treat a word as part of the user's real
        // vocabulary; without this, a name or jargon term stays permanently
        // buried under the fallback penalty no matter how often it is used.
        if count >= 2 { isCore[idx] = true }
        logPrior[idx] = min(0, logPrior[idx] + boost)
    }

    func reinforce(_ word: String) {
        guard indexOfWord[word] != nil else { return }
        learned[word, default: 0] += 1
        applyLearnedPrior(word)
        try? FileManager.default.createDirectory(at: Config.supportDirectory,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(learned) { try? data.write(to: learnedURL) }
    }

    /// The user's most-used words, most-used first, padded out to `n` with the
    /// most common English words. Ties and the padding both defer to overall
    /// frequency, so the bank is useful from first launch and each slot is
    /// surrendered exactly when some other word overtakes its count.
    func topUsed(_ n: Int) -> [String] {
        var out = learned
            .sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                return (indexOfWord[a.key] ?? .max) < (indexOfWord[b.key] ?? .max)
            }
            .map { $0.key }
        if out.count < n {
            var seen = Set(out)
            for w in CommonWords.ordered where !seen.contains(w) {
                out.append(w)
                seen.insert(w)
                if out.count == n { break }
            }
        }
        return Array(out.prefix(n))
    }

    /// Completions for a typed prefix, best first: core vocabulary by
    /// frequency, then fallback words. The prefix itself is excluded — the
    /// caller shows the raw letters as the already-chosen first option.
    func complete(prefix: String, count: Int) -> [String] {
        guard !prefix.isEmpty else { return [] }
        var core: [(Int, Double)] = []
        var fallback: [(Int, Double)] = []
        for (idx, w) in words.enumerated() {
            guard w.count > prefix.count, w.hasPrefix(prefix) else { continue }
            if isCore[idx] { core.append((idx, logPrior[idx])) }
            else { fallback.append((idx, logPrior[idx])) }
        }
        core.sort { $0.1 > $1.1 }
        fallback.sort { $0.1 > $1.1 }
        return (core + fallback).prefix(count).map { words[$0.0] }
    }

    // MARK: - Query

    func candidateIndices(startLetters: [Character], endLetters: [Character]) -> [Int] {
        var out: [Int] = []
        for s in startLetters {
            guard let sv = s.asciiValue, sv >= 97, sv <= 122 else { continue }
            for e in endLetters {
                guard let ev = e.asciiValue, ev >= 97, ev <= 122 else { continue }
                out.append(contentsOf: buckets[Int(sv - 97) * 26 + Int(ev - 97)])
            }
        }
        return out
    }

    var count: Int { words.count }
}
