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

    /// - Parameter path: the traced path in layout-local coordinates.
    func decode(path rawPath: [Pt]) -> [Candidate] {
        guard rawPath.count >= 2 else { return [] }

        let userLoc = Geometry.resample(rawPath, to: config.resampleCount)
        let userShape = Geometry.normalizeShape(userLoc, size: shapeNormSize)
        let userLength = Geometry.pathLength(rawPath)

        let radius = config.endpointRadiusKeys * layout.keyPitch
        var startLetters = layout.lettersNear(rawPath.first!, radius: radius)
        var endLetters = layout.lettersNear(rawPath.last!, radius: radius)
        // A trace that begins or ends outside the letter block still has to
        // resolve to something — fall back to the single nearest key.
        if startLetters.isEmpty, let n = layout.nearestLetter(to: rawPath.first!) { startLetters = [n] }
        if endLetters.isEmpty, let n = layout.nearestLetter(to: rawPath.last!) { endLetters = [n] }

        let indices = lexicon.candidateIndices(startLetters: startLetters, endLetters: endLetters)

        var results: [Candidate] = []
        results.reserveCapacity(min(indices.count, 512))

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

            let shape = Geometry.meanPointDistance(userShape, tShape)
            let location = Geometry.meanPointDistance(userLoc, tLoc)
            let priorPenalty = -lexicon.logPrior[idx] * priorScale
                             + (lexicon.isCore[idx] ? 0 : fallbackPenalty)

            let score = shape * config.shapeWeight
                      + location * config.locationWeight
                      + priorPenalty

            results.append(Candidate(word: lexicon.words[idx], score: score,
                                     shape: shape, location: location))
        }

        results.sort { $0.score < $1.score }
        return Array(results.prefix(config.candidateCount))
    }

    /// A contact that barely moved is a single key press, not a word.
    func decodeTap(at p: Pt) -> Character? { layout.nearestLetter(to: p) }
}
