import Foundation

/// Tunables, persisted as JSON so the geometry and decoder can be tuned
/// without a rebuild. Distances are expressed in *key pitches* rather than
/// millimetres so a setting keeps its meaning across trackpad sizes.
struct Config: Codable {
    // Layout ---------------------------------------------------------------
    /// Size of one key on screen, in points. This sets the size of the whole
    /// keyboard panel: ten keys across, three rows down.
    var screenKeyPitch: Double = 44
    /// Row spacing as a multiple of key width. Taller rows measurably cut
    /// row-confusion errors (the decoder's dominant failure mode); 1.6 is the
    /// sweep's sweet spot between accuracy and screen space.
    var rowPitchRatio: Double = 1.6
    /// Distance from the bottom of the screen to the keyboard panel, in points.
    /// Used until the user drags the panel somewhere; then the saved origin wins.
    var panelBottomMargin: Double = 40
    /// Where the user last dropped the panel (screen coordinates, bottom-left
    /// origin). Nil means "never moved": bottom-centre.
    var panelOriginX: Double? = nil
    var panelOriginY: Double? = nil
    /// Slots in the frequently-used word bank beneath the keys. The bank is a
    /// top-N-by-usage view, so a newly frequent word displaces the least used
    /// occupant automatically.
    var wordBankCount: Int = 5

    // Decoder --------------------------------------------------------------
    var resampleCount: Int = 64
    var shapeWeight: Double = 1.0
    var locationWeight: Double = 1.0
    /// Penalty per nat of negative log-prior, in key pitches. Expressed
    /// relative to key size so it keeps its meaning if the keyboard is resized.
    var priorWeightKeys: Double = 0.07
    /// How far from a key centre a glide may start/end and still be considered
    /// to have begun/ended on that key, in key pitches. Generous on purpose:
    /// sloppy swipes overshoot their first and last keys, and a word pruned
    /// here can never be recovered by scoring.
    var endpointRadiusKeys: Double = 1.6
    /// How many first-pass finalists get the expensive elastic (DTW) rescore.
    var rescoreCount: Int = 100
    /// Fraction of the final channel scores taken from elastic (DTW) matching
    /// versus rigid arc-length correspondence. Rigid encodes where along the
    /// path each turn happens — the main signal separating similar words —
    /// while elastic forgives local slop; pure elastic (1.0) measurably
    /// destroys clean-trace accuracy.
    var dtwBlend: Double = 0.75
    /// DTW warp band as a fraction of the resample count. Small on purpose:
    /// it should absorb local wobble, not whole-path reparameterization.
    var dtwBandFraction: Double = 0.08
    /// Emphasize endpoints over mid-path in the distance costs.
    var endWeighting: Bool = true
    /// Low-pass passes applied to the raw trace before scoring.
    var smoothingPasses: Int = 2
    /// Template/path arc-length ratio bounds for a word to stay in the running.
    var lengthRatioMin: Double = 0.35
    var lengthRatioMax: Double = 2.80
    var candidateCount: Int = 8
    /// A glide whose best score exceeds this (in key pitches) commits nothing.
    /// Real hits score 1-2.5 pitches; a stranded or accidental trace scores an
    /// order of magnitude worse, and typing its "nearest" word would be noise.
    var maxScoreKeys: Double = 3.5

    // Segmentation ---------------------------------------------------------
    /// Below this much travel a contact is a tap (single letter), not a glide.
    var tapMaxTravelKeys: Double = 0.55
    /// A contact shorter than this is ignored as an accidental brush.
    var minStrokeDurationMS: Double = 40
    var minStrokePoints: Int = 4
    /// Minimum mean finger travel, in normalized trackpad units, for a
    /// multi-finger gesture to count as a swipe rather than a tap.
    var multiSwipeMinTravel: Double = 0.06

    // Lexicon --------------------------------------------------------------
    /// Include /usr/share/dict/words as a low-prior fallback tier. It adds
    /// coverage but also ~198k archaic words that compete with real ones.
    var useSystemDictionary: Bool = true
    /// Nominal rank for fallback-tier words (sets their relative prior).
    var fallbackRank: Double = 60_000
    /// Flat extra penalty, in key pitches, for words outside the
    /// frequency-ranked core. Synthetic accuracy is flat from 0.8 to 2.2, but
    /// real traces are messier than synthetic ones and pull archaic dictionary
    /// entries into the candidate list; the higher value pushes them back out.
    var fallbackPenaltyKeys: Double = 1.6

    // Behaviour ------------------------------------------------------------
    var autoSpace: Bool = true
    var showHUD: Bool = true
    /// Swallow clicks and scrolling while glide mode is on and a finger is
    /// down, so tracing over the keyboard cannot activate whatever is beneath
    /// it. Pointer *movement* is never suppressed — it is the input.
    var suppressClicksWhileTyping: Bool = true
    /// Move the pointer onto the keyboard when glide mode turns on, and put it
    /// back where it was when it turns off.
    var warpPointerOnActivate: Bool = true
    /// Keep the pointer confined to the keyboard panel while glide mode is on.
    /// Without this the cursor drifts off the panel word by word until every
    /// trace decodes as garbage from a screen corner.
    var confinePointer: Bool = true

    // ----------------------------------------------------------------------
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TrackpadTyping", isDirectory: true)
    }
    static var fileURL: URL { supportDirectory.appendingPathComponent("config.json") }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.supportDirectory,
                                                 withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(self).write(to: Self.fileURL)
    }
}
