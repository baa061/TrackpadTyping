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
    /// Corpus words admitted past the core cutoff: real vocabulary with real
    /// frequencies, unlike the archaic dictionary tail — they pay a reduced
    /// penalty rather than the full junk rate.
    private(set) var isMidTier: [Bool] = []

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

    /// Test hook: build the lexicon as if the bundled corpus were absent,
    /// reproducing the pre-corpus vocabulary for A/B comparisons.
    static var resourceDisabled = false
    private var learned: [String: LearnedWord] = [:]

    /// Priors and tiers as loaded, before any learning boost — what `forget`
    /// restores. Per-word, because the corpus load mixes tiers.
    private var basePrior: [Double] = []
    private var baseCore: [Bool] = []

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

    private func add(_ word: String, rank: Double, core: Bool, midTier: Bool = false) {
        guard indexOfWord[word] == nil, let key = Self.bucketKey(word) else { return }
        let idx = words.count
        let prior = -Foundation.log(rank + 1.0)
        words.append(word)
        logPrior.append(prior)
        // basePrior must stay index-aligned with the arrays above — words can
        // now be added after load (user-taught vocabulary), and a mismatch is
        // an out-of-bounds crash in applyLearnedPrior.
        basePrior.append(prior)
        baseCore.append(core)
        isCore.append(core)
        isMidTier.append(midTier)
        buckets[key].append(idx)
        indexOfWord[word] = idx
    }

    private func loadCore() {
        var rank = 0.0

        // Primary vocabulary: a modern frequency-ranked word list (derived
        // from OpenSubtitles via hermitdave/FrequencyWords, CC-BY-SA), bundled
        // as a resource. Line order carries the frequency rank.
        //
        // Subtitles are dialogue, so the corpus is thick with character names
        // ("jana", "webber", "airbender"). Admitting those as core vocabulary
        // measurably costs accuracy — they outscore real words on shape. So a
        // corpus word enters the core tier only if it is frequent enough that
        // tier membership is beyond doubt, or a dictionary vouches for it;
        // everything else stays reachable but carries the fallback penalty.
        let dictionary = Self.systemDictionaryWords()
        let curated = Set(CommonWords.ordered)

        if !Self.resourceDisabled,
           let url = Bundle.module.url(forResource: "lexicon-en", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let w = String(line)
                guard !w.isEmpty, indexOfWord[w] == nil else { continue }
                // Core stays deliberately small: it is the set the decoder
                // lets win easily, and every admission dilutes accuracy on
                // the words that dominate real typing. Beyond it, words keep
                // their frequency-informed prior but pay the fallback penalty.
                let core = rank < 3_000
                        || (rank < 9_000 && dictionary.contains(w))
                        || curated.contains(w)
                add(w, rank: rank, core: core, midTier: !core)
                rank += 1
            }
        }

        // Contractions: the corpus tokenizer split them ("weren" + "t"), so
        // none survived cleaning. They are among the most common words in
        // conversational English; glide templates skip their apostrophes.
        for (w, r) in Self.contractions where indexOfWord[w] == nil {
            add(w, rank: r, core: true)
        }

        // The embedded list backstops a missing resource, and tops up any
        // hand-curated words the corpus lacks.
        for w in CommonWords.ordered {
            guard indexOfWord[w] == nil else { continue }   // list has intentional repeats
            add(w, rank: rank, core: true)
            rank += 1
        }
    }

    static let contractions: [(String, Double)] = [
        ("i'm", 40), ("it's", 45), ("don't", 55), ("that's", 80), ("you're", 90),
        ("can't", 110), ("i'll", 120), ("i've", 140), ("he's", 150), ("she's", 160),
        ("we're", 170), ("what's", 180), ("didn't", 190), ("there's", 210),
        ("let's", 230), ("i'd", 250), ("they're", 270), ("doesn't", 290),
        ("isn't", 320), ("won't", 340), ("you'll", 360), ("we'll", 380),
        ("wasn't", 400), ("you've", 420), ("he'll", 480), ("wouldn't", 500),
        ("couldn't", 520), ("aren't", 560), ("we've", 580), ("haven't", 600),
        ("shouldn't", 650), ("weren't", 670), ("hasn't", 720), ("they'll", 760),
        ("you'd", 800), ("they've", 840), ("she'll", 880), ("hadn't", 920),
        ("who's", 960), ("ain't", 1000), ("that'll", 1200), ("would've", 1300),
        ("could've", 1400), ("should've", 1500), ("here's", 1100), ("it'll", 1150),
    ]

    private static func systemDictionaryWords() -> Set<String> {
        guard let text = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8)
        else { return [] }
        var out = Set<String>()
        out.reserveCapacity(200_000)
        for line in text.split(separator: "\n") {
            let w = String(line)
            guard w.count >= 2, w.count <= 14 else { continue }
            guard w.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else { continue }
            out.insert(w)
        }
        return out
    }

    private func loadSystemDictionary() {
        for w in Self.systemDictionaryWords().sorted() {
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
            isCore[idx] = baseCore[idx]
        }
        persistLearned()
    }

    func isLearned(_ word: String) -> Bool { learned[word.lowercased()] != nil }

    func contains(_ word: String) -> Bool { indexOfWord[word.lowercased()] != nil }

    /// Add a word the lexicon has never seen. The only path here is the user
    /// spelling something out letter by letter and moving on — the strongest
    /// signal there is that it's a real word to them ("haha", names, jargon).
    /// It enters the fallback tier and earns promotion through the same
    /// session-gated rules as everything else.
    func learn(_ word: String, session: Int) {
        let word = word.lowercased()
        guard word.count >= 2, word.count <= 20 else { return }
        guard word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return }
        guard indexOfWord[word] == nil else { return }
        add(word, rank: config.fallbackRank, core: false)
        reinforce(word, session: session)
    }

    /// The user's most-used words, padded out to `n` with the most common
    /// English words. Ranking is recency-decayed rather than raw count: a raw
    /// tally lets the first busy week entrench five words forever, and the
    /// bank stops reflecting what the user types *now*. With a ten-day
    /// half-life a word keeps its slot exactly as long as it keeps earning it.
    func topUsed(_ n: Int) -> [String] {
        let now = Date().timeIntervalSince1970
        // Distinctiveness weighting: every sentence contains "the" and "is",
        // so raw counts hand the bank permanently to function words — the
        // least useful shortcuts there are (short, easy to glide, never
        // misrecognized). Scaling by global rarity makes the bank surface
        // vocabulary that is frequent *for this user*: names, jargon,
        // project words — the ones worth one-click access.
        func score(_ w: String, _ e: LearnedWord) -> Double {
            let ageDays = max(0, now - e.lastUsed) / 86_400
            let recencyScore = Double(e.count) * pow(0.5, ageDays / 10.0)
            let rank = indexOfWord[w].map { exp(-basePrior[$0]) - 1 } ?? config.fallbackRank
            return recencyScore * min(1.0, rank / 800.0)
        }
        var out = learned
            .sorted { a, b in
                let sa = score(a.key, a.value), sb = score(b.key, b.value)
                if sa != sb { return sa > sb }
                return (indexOfWord[a.key] ?? .max) < (indexOfWord[b.key] ?? .max)
            }
            .map { $0.key }
        if out.count < n {
            var seen = Set(out)
            for (i, w) in words.enumerated() where i >= 800 && isCore[i] && !seen.contains(w) {
                out.append(w)
                seen.insert(w)
                if out.count == n { break }
            }
            for w in CommonWords.ordered where !seen.contains(w) && out.count < n {
                out.append(w)
                seen.insert(w)
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
