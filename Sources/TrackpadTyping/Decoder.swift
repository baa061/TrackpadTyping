import Foundation

struct Candidate {
    let word: String
    let score: Double        // lower is better
    let shape: Double
    let location: Double
}

/// SHARK2-style gesture decoder.
///
/// A traced path is compared against each candidate word's ideal path (the
/// polyline through its key centres) on two channels:
///
///   * shape    — both paths translated to the origin and scaled to a common
///                size. Answers "did they draw this word's form?" while
///                forgiving drift and an overall too-small or too-large trace.
///   * location — the same comparison with no normalization at all. Answers
///                "did they draw it *over the right keys*?"
///
/// Shape alone confuses words with the same form in different places ("dog" and
/// "sit" are both short right-leaning zigzags); location alone punishes the
/// sloppy, drifting traces that gesture typing actually produces. Summing them
/// with a language prior is what makes the result usable.
final class Decoder {
    private let layout: KeyboardLayout
    private let lexicon: Lexicon
    private let config: Config

    /// Per-word resampled templates. Building one is cheap, but a single decode
    /// touches thousands of words and consecutive decodes overlap heavily.
    private var locationCache: [Int: [Pt]] = [:]
    private var shapeCache: [Int: [Pt]] = [:]
    private var templateLength: [Int: Double] = [:]
    private let cacheLimit = 60_000

    /// Size that shape-normalized paths are scaled to. Arbitrary, but it sets
    /// the units of the shape score, so the weights are tuned against it.
    private let shapeNormSize: Double

    /// Prior penalties precomputed into distance units, so the scoring loop
    /// stays a pure sum of comparable quantities.
    private let priorScale: Double
    private let fallbackPenalty: Double

    init(layout: KeyboardLayout, lexicon: Lexicon, config: Config) {
        self.layout = layout
        self.lexicon = lexicon
        self.config = config
        self.shapeNormSize = layout.keyPitch * 4.0
        self.priorScale = config.priorWeightKeys * layout.keyPitch
        self.fallbackPenalty = config.fallbackPenaltyKeys * layout.keyPitch
    }

    // MARK: - Templates

    private func ensureTemplate(_ idx: Int) -> Bool {
        if locationCache[idx] != nil { return true }
        if locationCache.count > cacheLimit {
            locationCache.removeAll(keepingCapacity: true)
            shapeCache.removeAll(keepingCapacity: true)
            templateLength.removeAll(keepingCapacity: true)
        }
        guard let poly = layout.template(for: lexicon.words[idx]) else { return false }
        let resampled = Geometry.resample(poly, to: config.resampleCount)
        locationCache[idx] = resampled
        shapeCache[idx] = Geometry.normalizeShape(resampled, size: shapeNormSize)
        templateLength[idx] = Geometry.pathLength(poly)
        return true
    }

    // MARK: - Decoding

    /// Light low-pass on the raw trace: cursor jitter is high-frequency and
    /// carries no intent, but it inflates every distance the scorer computes.
    private static func smooth(_ pts: [Pt], passes: Int) -> [Pt] {
        guard pts.count > 4 else { return pts }
        var cur = pts
        for _ in 0..<passes {
            var out = cur
            for i in 1..<(cur.count - 1) {
                out[i] = Pt(x: (cur[i-1].x + cur[i].x * 2 + cur[i+1].x) / 4,
                            y: (cur[i-1].y + cur[i].y * 2 + cur[i+1].y) / 4)
            }
            cur = out
        }
        return cur
    }

    /// Position weights over the resampled path: endpoints are aimed
    /// deliberately and should count; the middle is where sloppiness lives
    /// and is forgiven. 1.3 at the ends tapering to 0.7 mid-path.
    private lazy var positionWeights: [Double] = {
        let n = config.resampleCount
        guard config.endWeighting else { return [Double](repeating: 1, count: n) }
        return (0..<n).map { i in
            let t = Double(i) / Double(max(n - 1, 1))
            return 0.7 + 0.6 * pow(abs(2 * t - 1), 1.5)
        }
    }()

    /// Weighted mean pointwise distance — the cheap first-pass score.
    private func weightedPointDistance(_ a: [Pt], _ b: [Pt]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total = 0.0, wsum = 0.0
        for i in 0..<a.count {
            let w = positionWeights[i]
            total += w * a[i].distance(to: b[i])
            wsum += w
        }
        return total / wsum
    }

    /// Banded dynamic time warping. Rigid index-to-index comparison punishes a
    /// single mid-word overshoot twice: once where it happens, and again at
    /// every later point whose correspondence it shifted. DTW re-aligns
    /// locally, so slop costs only where it occurs. The band caps how far the
    /// alignment may wander, keeping "helpfully" degenerate alignments (and
    /// the runtime) in check.
    /// Rolling DP rows, reused across calls: a decode runs a few hundred DTWs
    /// and per-row allocation dominated its cost.
    private var dtwPrev: [Double] = []
    private var dtwCur: [Double] = []

    private func dtwDistance(_ a: [Pt], _ b: [Pt], band: Int) -> Double {
        let n = a.count, m = b.count
        guard n > 0 && m > 0 else { return .infinity }
        let inf = Double.greatestFiniteMagnitude
        if dtwPrev.count != m + 1 {
            dtwPrev = [Double](repeating: inf, count: m + 1)
            dtwCur = dtwPrev
        }
        for j in 0...m { dtwPrev[j] = inf; dtwCur[j] = inf }
        dtwPrev[0] = 0
        for i in 1...n {
            let lo = max(1, i - band), hi = min(m, i + band)
            // Clear the strip the band can touch, one cell wider on each
            // side: the next row's band shifts right by one and reads this
            // row at hi+1 — without the extra clear it would see a stale
            // finite value from two rows back.
            for j in max(0, lo - 1)...min(m, hi + 1) { dtwCur[j] = inf }
            for j in lo...hi {
                let w = positionWeights[min(j - 1, positionWeights.count - 1)]
                let d = w * a[i - 1].distance(to: b[j - 1])
                dtwCur[j] = d + min(dtwPrev[j], dtwCur[j - 1], dtwPrev[j - 1])
            }
            swap(&dtwPrev, &dtwCur)
        }
        return dtwPrev[m] / Double(n)
    }

    /// - Parameter path: the traced path in layout-local coordinates.
    func decode(path rawPath: [Pt]) -> [Candidate] {
        guard rawPath.count >= 2 else { return [] }

        let smoothed = Self.smooth(rawPath, passes: config.smoothingPasses)
        let userLoc = Geometry.resample(smoothed, to: config.resampleCount)
        let userShape = Geometry.normalizeShape(userLoc, size: shapeNormSize)
        let userLength = Geometry.pathLength(smoothed)

        let radius = config.endpointRadiusKeys * layout.keyPitch
        var startLetters = layout.lettersNear(rawPath.first!, radius: radius)
        var endLetters = layout.lettersNear(rawPath.last!, radius: radius)
        // A trace that begins or ends outside the letter block still has to
        // resolve to something — fall back to the single nearest key.
        if startLetters.isEmpty, let n = layout.nearestLetter(to: rawPath.first!) { startLetters = [n] }
        if endLetters.isEmpty, let n = layout.nearestLetter(to: rawPath.last!) { endLetters = [n] }

        let indices = lexicon.candidateIndices(startLetters: startLetters, endLetters: endLetters)

        // Stage 1: cheap rigid scoring over every candidate the buckets and
        // the length prune allow. Its job is only to nominate finalists.
        var firstPass: [(idx: Int, prior: Double, shape: Double, location: Double, score: Double)] = []
        firstPass.reserveCapacity(min(indices.count, 512))

        for idx in indices {
            guard ensureTemplate(idx), let tLen = templateLength[idx] else { continue }

            // Arc-length prune. Cheap, and it removes the bulk of the bucket:
            // a three-key word cannot explain a trace that crossed the pad twice.
            if userLength > 1e-6 {
                let ratio = tLen / userLength
                if ratio < config.lengthRatioMin || ratio > config.lengthRatioMax { continue }
            } else if tLen > layout.keyPitch {
                continue
            }

            guard let tLoc = locationCache[idx], let tShape = shapeCache[idx] else { continue }

            let shape = weightedPointDistance(userShape, tShape)
            let location = weightedPointDistance(userLoc, tLoc)
            let priorPenalty = -lexicon.logPrior[idx] * priorScale
                             + (lexicon.isCore[idx] ? 0 : fallbackPenalty)

            firstPass.append((idx, priorPenalty, shape, location,
                              shape * config.shapeWeight
                              + location * config.locationWeight
                              + priorPenalty))
        }

        firstPass.sort { $0.score < $1.score }

        // Stage 2: blended rescoring of the finalists. The rigid distances
        // stay in the score as the discriminator; the elastic (DTW) term is
        // mixed in to forgive local slop. DTW is ~20x the cost of the rigid
        // pass, so it runs on the short list where it matters.
        let band = max(2, Int(Double(config.resampleCount) * config.dtwBandFraction))
        let blend = min(max(config.dtwBlend, 0), 1)
        var results: [Candidate] = []
        results.reserveCapacity(config.rescoreCount)

        for entry in firstPass.prefix(config.rescoreCount) {
            guard let tLoc = locationCache[entry.idx],
                  let tShape = shapeCache[entry.idx] else { continue }
            let shape = (1 - blend) * entry.shape
                      + blend * dtwDistance(userShape, tShape, band: band)
            let location = (1 - blend) * entry.location
                         + blend * dtwDistance(userLoc, tLoc, band: band)
            let score = shape * config.shapeWeight
                      + location * config.locationWeight
                      + entry.prior
            results.append(Candidate(word: lexicon.words[entry.idx], score: score,
                                     shape: shape, location: location))
        }

        results.sort { $0.score < $1.score }
        return Array(results.prefix(config.candidateCount))
    }

    /// A contact that barely moved is a single key press, not a word.
    func decodeTap(at p: Pt) -> Character? { layout.nearestLetter(to: p) }
}
