import Foundation

/// A QWERTY letter block, laid out in whatever unit the caller works in.
///
/// The layout is now anchored to an on-screen panel, so the unit is screen
/// points and the geometry is a plain 10x3 grid of square keys. That makes the
/// space naturally isotropic — a step sideways and a step upward are the same
/// real distance — which is what the shape matching in `Decoder` assumes.
struct KeyboardLayout {
    struct Key {
        let letter: Character
        /// Centre, in layout-local coordinates: origin bottom-left, y up.
        let center: Pt
    }

    let keys: [Character: Key]
    let keyPitch: Double
    /// Vertical distance between row centres.
    let rowPitch: Double
    let width: Double
    let height: Double

    private static let rows: [String] = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    /// - Parameter rowPitchRatio: row spacing as a multiple of key width.
    ///   Vertical mix-ups dominate the decoder's errors — a trace drifts a row
    ///   more easily than it drifts a column, because rows are what the hand
    ///   crosses on the way between letters. Spreading the rows buys accuracy
    ///   at the cost of a slightly tall keyboard.
    init(keyPitch: Double, rowPitchRatio: Double = 1.0) {
        self.keyPitch = keyPitch
        self.rowPitch = keyPitch * rowPitchRatio
        self.width = keyPitch * 10
        self.height = keyPitch * rowPitchRatio * 3

        var built: [Character: Key] = [:]
        for (rowIdx, row) in Self.rows.enumerated() {
            // Staggered like a real keyboard: home row by a quarter key,
            // bottom row by three quarters.
            let stagger: Double = [0.0, 0.25, 0.75][rowIdx]
            // Row 0 is the top row, so it takes the highest y.
            let y = height - rowPitch * (Double(rowIdx) + 0.5)
            for (colIdx, ch) in row.enumerated() {
                let x = keyPitch * (Double(colIdx) + 0.5 + stagger)
                built[ch] = Key(letter: ch, center: Pt(x: x, y: y))
            }
        }
        self.keys = built
    }

    func center(of letter: Character) -> Pt? { keys[letter]?.center }

    /// Letters whose centre lies within `radius` of a point, nearest first.
    func lettersNear(_ p: Pt, radius: Double) -> [Character] {
        keys.values
            .compactMap { k -> (Character, Double)? in
                let d = k.center.distance(to: p)
                return d <= radius ? (k.letter, d) : nil
            }
            .sorted { $0.1 < $1.1 }
            .map { $0.0 }
    }

    func nearestLetter(to p: Pt) -> Character? {
        keys.values.min { $0.center.distance(to: p) < $1.center.distance(to: p) }?.letter
    }

    /// The ideal traced path for a word: a polyline through its key centres.
    /// Consecutive repeats collapse — a glide across "ll" is physically
    /// indistinguishable from one across a single "l", so the template must not
    /// claim otherwise. Apostrophes (and any other non-key character) are
    /// skipped: "weren't" glides as w-e-r-e-n-t but types with its apostrophe.
    func template(for word: String) -> [Pt]? {
        var pts: [Pt] = []
        var last: Character? = nil
        for ch in word {
            guard let c = center(of: ch) else {
                if ch == "'" { continue }          // silent in the glide
                return nil                          // anything else: not glideable
            }
            if ch != last { pts.append(c) }
            last = ch
        }
        return pts.isEmpty ? nil : pts
    }
}
