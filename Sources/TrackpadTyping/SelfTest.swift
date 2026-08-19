import Foundation
import AppKit

/// Deterministic RNG so accuracy numbers are comparable across tuning runs.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func gaussian(sigma: Double) -> Double {
        let u1 = Double.random(in: 1e-9...1, using: &self)
        let u2 = Double.random(in: 0...1, using: &self)
        return sigma * (-2 * Foundation.log(u1)).squareRoot() * Foundation.cos(2 * .pi * u2)
    }
}

enum SelfTest {

    /// Synthesize a plausible human trace for a word.
    ///
    /// Two distortions matter and neither is optional if the numbers are to
    /// mean anything: fingers land *near* key centres rather than on them, and
    /// a moving finger rounds off corners instead of hitting vertices. A test
    /// built from exact templates would report near-perfect accuracy and tell
    /// us nothing.
    static func synthesize(word: String,
                           layout: KeyboardLayout,
                           noiseKeys: Double,
                           rng: inout SeededRNG) -> [Pt]? {
        guard let template = layout.template(for: word) else { return nil }
        let sigma = noiseKeys * layout.keyPitch

        let jittered = template.map { p in
            Pt(x: p.x + rng.gaussian(sigma: sigma), y: p.y + rng.gaussian(sigma: sigma))
        }

        // Dense sampling, then repeated smoothing to round the corners the way
        // a finger in motion does.
        var dense = Geometry.resample(jittered, to: max(60, jittered.count * 20))
        if dense.count > 4 {
            for _ in 0..<6 {
                var out = dense
                for i in 1..<(dense.count - 1) {
                    out[i] = Pt(x: (dense[i-1].x + dense[i].x * 2 + dense[i+1].x) / 4,
                                y: (dense[i-1].y + dense[i].y * 2 + dense[i+1].y) / 4)
                }
                dense = out
            }
        }
        // Sensor-level jitter on top.
        return dense.map { p in
            Pt(x: p.x + rng.gaussian(sigma: sigma * 0.12),
               y: p.y + rng.gaussian(sigma: sigma * 0.12))
        }
    }

    static func run(config: Config, sampleSize: Int = 300, noiseKeys: Double = 0.30, verbose: Bool = false) {
        let layout = KeyboardLayout(keyPitch: config.screenKeyPitch, rowPitchRatio: config.rowPitchRatio)
        let t0 = Date()
        let lexicon = Lexicon(config: config)
        let loadMS = Date().timeIntervalSince(t0) * 1000
        let decoder = Decoder(layout: layout, lexicon: lexicon, config: config)

        print(String(format: "lexicon: %d words (%.0f ms)  key pitch: %.0f pt  keyboard: %.0f x %.0f pt",
                     lexicon.count, loadMS, layout.keyPitch, layout.width, layout.height))

        // Test on frequent words: those are what a user actually types, and
        // accuracy on them is what determines whether this feels usable.
        var rng = SeededRNG(seed: 42)
        let pool = CommonWords.ordered.filter { $0.count >= 2 }
        var seen = Set<String>()
        let words = pool.filter { seen.insert($0).inserted }.prefix(sampleSize)

        var top1 = 0, top3 = 0, total = 0
        var totalMS = 0.0
        var failures: [(String, [String])] = []

        for w in words {
            guard let path = synthesize(word: w, layout: layout, noiseKeys: noiseKeys, rng: &rng) else { continue }
            let start = Date()
            let cands = decoder.decode(path: path)
            totalMS += Date().timeIntervalSince(start) * 1000
            total += 1

            let names = cands.map { $0.word }
            if names.first == w { top1 += 1 }
            if names.prefix(3).contains(w) { top3 += 1 }
            else if failures.count < 25 { failures.append((w, Array(names.prefix(3)))) }
        }

        guard total > 0 else { print("no test words"); return }
        print(String(format: "noise %.2f keys | top-1 %.1f%%  top-3 %.1f%%  (n=%d)  mean decode %.1f ms",
                     noiseKeys,
                     100.0 * Double(top1) / Double(total),
                     100.0 * Double(top3) / Double(total),
                     total, totalMS / Double(total)))
        if verbose && !failures.isEmpty {
            print("misses (want -> got):")
            for (w, got) in failures.prefix(20) { print("  \(w) -> \(got.joined(separator: ", "))") }
        }
    }
}

extension SelfTest {
    /// Grid search over the score weights.
    ///
    /// The lexicon and the synthetic traces are built once and shared: they do
    /// not depend on the weights, and holding them fixed means every cell of
    /// the grid is scored against identical input.
    static func sweep(baseConfig: Config, sampleSize: Int = 400) {
        var seen = Set<String>()
        let words = CommonWords.ordered.filter { $0.count >= 2 && seen.insert($0).inserted }
                                       .prefix(sampleSize)
        let lexicon = Lexicon(config: baseConfig)
        let noiseLevels = [0.20, 0.30, 0.40]

        struct Row { let ratio: Double; let loc: Double; let fb: Double; let top1: Double; let top3: Double }
        var rows: [Row] = []

        // Row spacing changes the layout, so the synthetic traces have to be
        // rebuilt for each ratio — they are drawn against the keyboard itself.
        for ratio in [1.0, 1.2, 1.4, 1.6, 1.9] {
            let layout = KeyboardLayout(keyPitch: baseConfig.screenKeyPitch, rowPitchRatio: ratio)
            var cases: [(String, [Pt])] = []
            for noise in noiseLevels {
                var rng = SeededRNG(seed: 7)
                for w in words {
                    if let p = synthesize(word: w, layout: layout, noiseKeys: noise, rng: &rng) {
                        cases.append((w, p))
                    }
                }
            }

            for loc in [0.7, 1.0, 1.3] {
                for fb in [0.8, 1.4, 2.2] {
                    var cfg = baseConfig
                    cfg.rowPitchRatio = ratio
                    cfg.locationWeight = loc
                    cfg.fallbackPenaltyKeys = fb
                    let dec = Decoder(layout: layout, lexicon: lexicon, config: cfg)

                    var t1 = 0, t3 = 0
                    for (want, path) in cases {
                        let names = dec.decode(path: path).map { $0.word }
                        if names.first == want { t1 += 1 }
                        if names.prefix(3).contains(want) { t3 += 1 }
                    }
                    rows.append(Row(ratio: ratio, loc: loc, fb: fb,
                                    top1: 100.0 * Double(t1) / Double(cases.count),
                                    top3: 100.0 * Double(t3) / Double(cases.count)))
                }
            }
            print("  ...ratio \(ratio) done")
        }

        rows.sort { $0.top1 > $1.top1 }
        print("\nbest (rowRatio / locWeight / fallbackKeys -> top1, top3):")
        for r in rows.prefix(10) {
            print(String(format: "  %.1f  %.2f  %.1f  ->  %.1f%%  %.1f%%", r.ratio, r.loc, r.fb, r.top1, r.top3))
        }
        print("\nworst:")
        for r in rows.suffix(3) {
            print(String(format: "  %.1f  %.2f  %.1f  ->  %.1f%%  %.1f%%", r.ratio, r.loc, r.fb, r.top1, r.top3))
        }
    }
}

/// Live decoding with no text injection.
///
/// Same keyboard, same click-held-to-trace input, same decoder as the app —
/// but results print here instead of being typed, so the feel can be checked
/// before trusting it with real input. Uses passive NSEvent monitors instead
/// of the app's event tap, so clicks are NOT swallowed: whatever is behind the
/// panel will still be clicked. Rehearse over the desktop.
enum TraceMode {
    private static var hud: HUDWindow?
    private static var monitors: [Any] = []
    private static var traceTimer: Timer?
    private static var tracePath: [Pt] = []
    private static var tracing = false

    static func run(config: Config, seconds: Double) {
        let layout = KeyboardLayout(keyPitch: config.screenKeyPitch, rowPitchRatio: config.rowPitchRatio)
        let lexicon = Lexicon(config: config)
        let decoder = Decoder(layout: layout, lexicon: lexicon, config: config)

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = HUDWindow(layout: layout, bottomMargin: CGFloat(config.panelBottomMargin))
        panel.hudView.statusText = "Click-hold, sweep, release — nothing is typed"
        panel.orderFrontRegardless()
        hud = panel

        var glides = 0

        func begin() {
            guard !tracing else { return }
            tracing = true
            tracePath = [panel.toLayout(screenPoint: NSEvent.mouseLocation)]
            traceTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { _ in
                guard tracing else { return }
                let p = panel.toLayout(screenPoint: NSEvent.mouseLocation)
                if tracePath.last.map({ $0.distance(to: p) > 0.5 }) ?? true {
                    tracePath.append(p)
                    panel.hudView.livePath = tracePath
                    panel.refresh()
                }
            }
        }

        func end() {
            guard tracing else { return }
            tracing = false
            traceTimer?.invalidate()
            traceTimer = nil
            let path = tracePath
            tracePath = []

            if Geometry.pathLength(path) < config.tapMaxTravelKeys * layout.keyPitch {
                let ch = path.last.flatMap { layout.nearestLetter(to: $0) }.map(String.init) ?? "?"
                print("click -> \(ch)")
                panel.hudView.candidates = []
                panel.hudView.statusText = "letter: \(ch)"
            } else {
                glides += 1
                let cands = decoder.decode(path: path)
                let cutoff = config.maxScoreKeys * layout.keyPitch
                let accepted = cands.first.map { $0.score <= cutoff } ?? false
                print(String(format: "glide #%d  %.0fpt, %d pts%@", glides,
                             Geometry.pathLength(path), path.count,
                             accepted ? "" : "  [rejected: best score too high]"))
                let list = cands.map { String(format: "%@ (%.1f)", $0.word, $0.score) }
                                .joined(separator: "   ")
                print("   \(list.isEmpty ? "no candidates" : list)")
                panel.hudView.candidates = accepted ? cands.map { $0.word } : []
                panel.hudView.selectedIndex = 0
                panel.hudView.statusText = accepted ? (cands.first?.word ?? "") : "no match — try again"
            }
            panel.hudView.livePath = []
            panel.refresh()
            fflush(stdout)
        }

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in begin() } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in end() } as Any)

        // Hover highlight needs its own clock; there is no event stream for a
        // merely-moving cursor here.
        monitors.append(Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { _ in
            let p = panel.toLayout(screenPoint: NSEvent.mouseLocation)
            let previous = panel.hudView.hoverPoint
            panel.hudView.hoverPoint = p
            if previous.flatMap({ layout.nearestLetter(to: $0) }) != layout.nearestLetter(to: p) {
                panel.refresh()
            }
        })

        if let primary = NSScreen.screens.first {
            let c = panel.centerOnScreen
            CGWarpMouseCursorPosition(CGPoint(x: c.x, y: primary.frame.height - c.y))
            CGAssociateMouseAndMouseCursorPosition(1)
        }

        print("""

            REHEARSAL — nothing is typed, but clicks are NOT blocked either,
            so keep the pointer over the keyboard panel / desktop.

            Move the pointer freely: nothing is decoded until you press.
            CLICK AND HOLD on the first letter, sweep through the word,
            RELEASE on the last letter. A quick click = single letter.

            Listening for \(Int(seconds))s.

            """)
        fflush(stdout)

        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            print("\ndone — \(glides) glides decoded")
            exit(0)
        }
        app.run()
    }
}
