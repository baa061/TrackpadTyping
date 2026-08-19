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

    struct LearnedWord: Codable {
        var count: Int
        /// Number of distinct calendar days the word was used on. Days rather
        /// than app launches or mode toggles: they are monotonic across
        /// restarts (toggle counters reset and collide with persisted values),
        /// and "vocabulary" means used on separate occasions — one afternoon
        /// of toggling must not be able to promote a misrecognition.
        var sessions: Int
        var lastSession: Int
        /// Unix time of last use, for pruning stale one-offs.
        var lastUsed: TimeInterval
    }

    /// Session unit: the calendar day (UTC epoch days).
    static func currentSession() -> Int { Int(Date().timeIntervalSince1970) / 86_400 }
    private var learned: [String: LearnedWord] = [:]

    /// Priors as loaded, before any learning boost — what `forget` restores.
    private var basePrior: [Double] = []
    /// Words below this index came from the frequency-ranked core list.
    private var coreEnd = 0

    private let config: Config

    init(config: Config) {
        self.config = config
        loadCore()
        coreEnd = words.count
        if config.useSystemDictionary { loadSystemDictionary() }
        basePrior = logPrior
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
        guard let data = try? Data(contentsOf: learnedURL) else { return }
        let now = Date().timeIntervalSince1970

        if let dict = try? JSONDecoder().decode([String: LearnedWord].self, from: data) {
            learned = dict
        } else if let old = try? JSONDecoder().decode([String: Int].self, from: data) {
            // v1 format: bare counts. Nothing recorded which sessions they came
            // from, so credit a single session — words keep their boost but
            // must earn promotion again under the stricter rule.
            for (w, c) in old {
                learned[w] = LearnedWord(count: c, sessions: 1, lastSession: 0,
                                         lastUsed: c > 1 ? now : 0)
            }
        } else { return }

        // A word accepted once and never again is far more likely a
        // misrecognition than vocabulary; let those age out.
        let cutoff = now - 14 * 86_400
        learned = learned.filter { $0.value.count > 1 || $0.value.lastUsed >= cutoff }

        for (w, _) in learned { applyLearnedPrior(w) }
        persistLearned()
    }

    private func persistLearned() {
        try? FileManager.default.createDirectory(at: Config.supportDirectory,
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(learned) {
            try? data.write(to: learnedURL, options: .atomic)
        }
    }

    /// Accepting a word pulls it up the ranking. The effect saturates: repeated
    /// use should make a word competitive, not make it beat everything.
    private func applyLearnedPrior(_ word: String) {
        guard let idx = indexOfWord[word], let entry = learned[word] else { return }
        let boost = Foundation.log(1.0 + Double(entry.count)) * 1.2
        // Promotion out of the fallback tier requires use in more than one
        // session. A single session isn't vocabulary — it is one afternoon's
        // worth of accepted misrecognitions reinforcing themselves.
        if entry.sessions >= 2 && entry.count >= 3 { isCore[idx] = true }
        logPrior[idx] = min(0, basePrior[idx] + boost)
    }

    /// - Parameter session: monotonically increasing glide-session number, so
    ///   uses within one sitting count as one session.
    func reinforce(_ word: String, session: Int) {
        let word = word.lowercased()   // callers pass display forms ("There")
        guard indexOfWord[word] != nil else { return }
        var entry = learned[word] ?? LearnedWord(count: 0, sessions: 0,
                                                 lastSession: -1, lastUsed: 0)
        entry.count += 1
        if entry.lastSession != session {
            entry.sessions += 1
            entry.lastSession = session
        }
        entry.lastUsed = Date().timeIntervalSince1970
        learned[word] = entry
        applyLearnedPrior(word)
        persistLearned()
    }

    /// Erase everything learned about a word and restore its original prior —
    /// the escape hatch for junk that got itself reinforced.
    func forget(_ word: String) {
        let word = word.lowercased()
        learned.removeValue(forKey: word)
        if let idx = indexOfWord[word] {
            logPrior[idx] = basePrior[idx]
            isCore[idx] = idx < coreEnd
        }
        persistLearned()
    }

    func isLearned(_ word: String) -> Bool { learned[word.lowercased()] != nil }

    /// The user's most-used words, most-used first, padded out to `n` with the
    /// most common English words. Ties and the padding both defer to overall
    /// frequency, so the bank is useful from first launch and each slot is
    /// surrendered exactly when some other word overtakes its count.
    func topUsed(_ n: Int) -> [String] {
        var out = learned
            .sorted { a, b in
                if a.value.count != b.value.count { return a.value.count > b.value.count }
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
