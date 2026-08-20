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
                           sloppy: Bool = false,
                           rng: inout SeededRNG) -> [Pt]? {
        guard let template = layout.template(for: word) else { return nil }
        let sigma = noiseKeys * layout.keyPitch

        var jittered = template.map { p in
            Pt(x: p.x + rng.gaussian(sigma: sigma), y: p.y + rng.gaussian(sigma: sigma))
        }

        if sloppy {
            // Sloppiness is not just noise — it has structure. Three real
            // failure modes of a fast hand:
            // 1. corner overshoot: momentum carries past a turn, then corrects
            var overshot: [Pt] = [jittered[0]]
            for i in 1..<jittered.count {
                let prev = jittered[i - 1]
                let cur = jittered[i]
                overshot.append(cur)
                if i < jittered.count - 1 {
                    let dir = cur - prev
                    let len = dir.length
                    if len > 1e-6, Double.random(in: 0...1, using: &rng) < 0.5 {
                        let over = Double.random(in: 0.2...0.6, using: &rng) * layout.keyPitch
                        overshot.append(cur + dir * (over / len))
                        overshot.append(cur)
                    }
                }
            }
            jittered = overshot
            // 2. endpoint drift: the finger lands/lifts short of or past the key
            let eSigma = sigma * 1.6
            jittered[0] = Pt(x: jittered[0].x + rng.gaussian(sigma: eSigma),
                             y: jittered[0].y + rng.gaussian(sigma: eSigma))
            let last = jittered.count - 1
            jittered[last] = Pt(x: jittered[last].x + rng.gaussian(sigma: eSigma),
                                y: jittered[last].y + rng.gaussian(sigma: eSigma))
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
        // 3. mid-path wobble: a slow lateral oscillation, worst mid-glide and
        //    calm near the deliberately-aimed endpoints.
        if sloppy && dense.count > 4 {
            let phase = Double.random(in: 0...(2 * .pi), using: &rng)
            let amp = 0.35 * layout.keyPitch
            let cycles = Double.random(in: 1.5...3.0, using: &rng)
            for i in 0..<dense.count {
                let t = Double(i) / Double(dense.count - 1)
                let envelope = Foundation.sin(t * .pi)          // 0 at ends, 1 mid
                let off = amp * envelope * Foundation.sin(phase + t * cycles * 2 * .pi)
                dense[i] = Pt(x: dense[i].x, y: dense[i].y + off)
            }
        }

        // Sensor-level jitter on top.
        return dense.map { p in
            Pt(x: p.x + rng.gaussian(sigma: sigma * 0.12),
               y: p.y + rng.gaussian(sigma: sigma * 0.12))
        }
    }

    static func run(config: Config, sampleSize: Int = 300, noiseKeys: Double = 0.30,
                    sloppy: Bool = false, verbose: Bool = false) {
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
            guard let path = synthesize(word: w, layout: layout, noiseKeys: noiseKeys,
                                        sloppy: sloppy, rng: &rng) else { continue }
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
        print(String(format: "noise %.2f keys%@ | top-1 %.1f%%  top-3 %.1f%%  (n=%d)  mean decode %.1f ms",
                     noiseKeys, sloppy ? " SLOPPY" : "",
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
    /// The decisive lexicon comparison: words sampled in proportion to their
    /// real frequency from the modern corpus, decoded by both the corpus
    /// lexicon and the legacy one. A missing word decodes wrong — which is
    /// exactly what it does to the user.
    static func ablate(baseConfig: Config, sampleSize: Int = 500) {
        let layout = KeyboardLayout(keyPitch: baseConfig.screenKeyPitch,
                                    rowPitchRatio: baseConfig.rowPitchRatio)

        guard let url = Bundle.module.url(forResource: "lexicon-en", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("no corpus resource"); return
        }
        let corpus = text.split(separator: "\n").prefix(5000).map(String.init)
            .filter { $0.count >= 2 }

        // Zipf-weighted sampling: rank r drawn with probability ~ 1/(r+10).
        var rng = SeededRNG(seed: 21)
        let weights = corpus.indices.map { 1.0 / Double($0 + 10) }
        let totalW = weights.reduce(0, +)
        var words: [String] = []
        for _ in 0..<sampleSize {
            var t = Double.random(in: 0..<totalW, using: &rng)
            for (i, w) in weights.enumerated() {
                t -= w
                if t <= 0 { words.append(corpus[i]); break }
            }
        }

        func cases(sloppy: Bool, seed: UInt64) -> [(String, [Pt])] {
            var r = SeededRNG(seed: seed)
            return words.compactMap { w in
                synthesize(word: w, layout: layout, noiseKeys: 0.30, sloppy: sloppy, rng: &r)
                    .map { (w, $0) }
            }
        }
        let clean = cases(sloppy: false, seed: 31)
        let sloppyC = cases(sloppy: true, seed: 32)

        func score(_ dec: Decoder, _ cs: [(String, [Pt])]) -> (Double, Double) {
            var t1 = 0, t3 = 0
            for (want, path) in cs {
                let names = dec.decode(path: path).map { $0.word }
                if names.first == want { t1 += 1 }
                if names.prefix(3).contains(want) { t3 += 1 }
            }
            return (100.0 * Double(t1) / Double(cs.count), 100.0 * Double(t3) / Double(cs.count))
        }

        for anchor in [0.0, 0.3, 0.6] {
            for mid in [0.4, 0.7] {
                var cfg = baseConfig
                cfg.endpointAnchorWeight = anchor
                cfg.midFallbackPenaltyKeys = mid
                let lexicon = Lexicon(config: cfg)
                let dec = Decoder(layout: layout, lexicon: lexicon, config: cfg)
                let c = score(dec, clean), sl = score(dec, sloppyC)
                print(String(format: "anchor %.1f mid %.1f:  clean %.1f/%.1f   sloppy %.1f/%.1f",
                             anchor, mid, c.0, c.1, sl.0, sl.1))
            }
        }
    }

    static func sweep(baseConfig: Config, sampleSize: Int = 400) {
        let layout = KeyboardLayout(keyPitch: baseConfig.screenKeyPitch,
                                    rowPitchRatio: baseConfig.rowPitchRatio)
        let lexicon = Lexicon(config: baseConfig)

        var seen = Set<String>()
        let words = CommonWords.ordered.filter { $0.count >= 2 && seen.insert($0).inserted }
                                       .prefix(sampleSize)

        // Two test populations, scored separately: tuning must buy sloppy
        // accuracy without selling clean accuracy.
        func makeCases(noise: Double, sloppy: Bool, seed: UInt64) -> [(String, [Pt])] {
            var rng = SeededRNG(seed: seed)
            return words.compactMap { w in
                synthesize(word: w, layout: layout, noiseKeys: noise, sloppy: sloppy, rng: &rng)
                    .map { (w, $0) }
            }
        }
        let clean = makeCases(noise: 0.20, sloppy: false, seed: 7)
                  + makeCases(noise: 0.30, sloppy: false, seed: 8)
        let sloppy = makeCases(noise: 0.30, sloppy: true, seed: 9)
                   + makeCases(noise: 0.45, sloppy: true, seed: 10)
        print("sweep: \(clean.count) clean + \(sloppy.count) sloppy traces\n")

        func top1(_ dec: Decoder, _ cases: [(String, [Pt])]) -> Double {
            var hit = 0
            for (want, path) in cases where dec.decode(path: path).first?.word == want { hit += 1 }
            return 100.0 * Double(hit) / Double(cases.count)
        }

        struct Row { let blend, band, prior, clean, sloppy: Double }
        var grid: [(Double, Double, Double)] = []
        for blend in [0.0, 0.25, 0.5, 0.75, 1.0] {
            for band in [0.05, 0.08, 0.16] {
                for prior in [0.04, 0.07] {
                    grid.append((blend, band, prior))
                }
            }
        }
        // Each cell gets its own Decoder (they cache templates internally);
        // the lexicon and layout are shared read-only.
        var rows = [Row?](repeating: nil, count: grid.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: grid.count) { i in
            let (blend, band, prior) = grid[i]
            var cfg = baseConfig
            cfg.dtwBlend = blend
            cfg.dtwBandFraction = band
            cfg.priorWeightKeys = prior
            let dec = Decoder(layout: layout, lexicon: lexicon, config: cfg)
            let row = Row(blend: blend, band: band, prior: prior,
                          clean: top1(dec, clean), sloppy: top1(dec, sloppy))
            lock.lock(); rows[i] = row; lock.unlock()
        }
        var done = rows.compactMap { $0 }

        // Rank by sloppy accuracy among configs that keep clean accuracy high.
        let floor = done.map { $0.clean }.max()! - 2.0
        done.sort {
            let aOK = $0.clean >= floor, bOK = $1.clean >= floor
            if aOK != bOK { return aOK }
            return $0.sloppy != $1.sloppy ? $0.sloppy > $1.sloppy : $0.clean > $1.clean
        }
        print("\nall (blend / bandFrac / prior -> clean top1, sloppy top1):")
        for r in done {
            print(String(format: "  %.2f  %.2f  %.2f  ->  %.1f%%  %.1f%%",
                         r.blend, r.band, r.prior, r.clean, r.sloppy))
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
