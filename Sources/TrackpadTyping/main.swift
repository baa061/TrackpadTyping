import Foundation

let args = Array(CommandLine.arguments.dropFirst())
var config = Config.load()

if args.contains("--trace") {
    var seconds = 45.0
    if let i = args.firstIndex(of: "--trace"), i + 1 < args.count, let v = Double(args[i + 1]) {
        seconds = v
    }
    TraceMode.run(config: config, seconds: seconds)
}

if args.contains("--ablate") {
    _ = TrackpadMonitor.shared.start()
    TrackpadMonitor.shared.stop()
    SelfTest.ablate(baseConfig: config)
    exit(0)
}

if let i = args.firstIndex(of: "--probe"), i + 1 < args.count {
    _ = TrackpadMonitor.shared.start()
    TrackpadMonitor.shared.stop()
    let layout = KeyboardLayout(keyPitch: config.screenKeyPitch, rowPitchRatio: config.rowPitchRatio)
    let lexicon = Lexicon(config: config)
    let decoder = Decoder(layout: layout, lexicon: lexicon, config: config)
    for word in args[(i + 1)...] {
        print("\n=== \(word)  (in lexicon: \(lexicon.contains(word)))")
        var rng = SeededRNG(seed: 99)
        for trial in 0..<3 {
            guard let path = SelfTest.synthesize(word: word, layout: layout,
                                                 noiseKeys: 0.30, sloppy: trial == 2, rng: &rng) else { continue }
            let cands = decoder.decode(path: path)
            let list = cands.prefix(5).map { String(format: "%@ %.0f", $0.word, $0.score) }.joined(separator: "  ")
            print("  trial \(trial)\(trial == 2 ? " (sloppy)" : ""): \(list)")
        }
    }
    exit(0)
}

if args.contains("--emphasis-test") {
    _ = TrackpadMonitor.shared.start()
    TrackpadMonitor.shared.stop()
    let layout = KeyboardLayout(keyPitch: config.screenKeyPitch, rowPitchRatio: config.rowPitchRatio)
    let lexicon = Lexicon(config: config)
    let decoder = Decoder(layout: layout, lexicon: lexicon, config: config)

    // The canonical ambiguity: p→t sweeps straight through o, i and u, so
    // pot/put/pit trace identically and only the prior breaks the tie.
    let pC = layout.center(of: "p")!, tC = layout.center(of: "t")!
    func line(_ n: Int) -> ([Pt], [Double]) {
        var pts: [Pt] = []
        for i in 0..<n {
            let f = Double(i) / Double(n - 1)
            pts.append(Pt(x: pC.x + (tC.x - pC.x) * f, y: pC.y + (tC.y - pC.y) * f))
        }
        return (pts, [Double](repeating: 0, count: n))
    }
    func report(_ name: String, _ pts: [Pt], _ dw: [Double]) {
        let (cleaned, emph) = EmphasisDetector.detect(path: pts, dwell: dw, layout: layout, config: config)
        let cands = decoder.decode(path: cleaned, emphases: emph)
        let e = emph.map { "\($0.letter)@\(String(format: "%.2f", $0.t))" }.joined(separator: ",")
        print("\(name): emphases=[\(e)]  ->  \(cands.prefix(4).map { $0.word }.joined(separator: ", "))")
    }

    var (pts, dw) = line(60)
    report("plain line     ", pts, dw)

    // pause on 'i'
    (pts, dw) = line(60)
    var bestI = 0; var bd = 1e9
    let iC = layout.center(of: "i")!
    for (k, p) in pts.enumerated() { let d = p.distance(to: iC); if d < bd { bd = d; bestI = k } }
    dw[bestI] = 0.30
    report("pause on i     ", pts, dw)

    // pause on 'u'
    (pts, dw) = line(60)
    let uC = layout.center(of: "u")!
    bd = 1e9
    for (k, p) in pts.enumerated() { let d = p.distance(to: uC); if d < bd { bd = d; bestI = k } }
    dw[bestI] = 0.30
    report("pause on u     ", pts, dw)

    // loop over 'i': insert a small circle at i's position
    (pts, dw) = line(60)
    bd = 1e9
    for (k, p) in pts.enumerated() { let d = p.distance(to: iC); if d < bd { bd = d; bestI = k } }
    var looped: [Pt] = Array(pts[0...bestI])
    let r = layout.keyPitch * 0.45
    for step in 1...22 {
        let a = Double(step) / 22.0 * 2 * Double.pi
        looped.append(Pt(x: pts[bestI].x + r * Foundation.sin(a),
                         y: pts[bestI].y + r * (1 - Foundation.cos(a)) - r))
    }
    looped.append(contentsOf: pts[(bestI + 1)...])
    report("loop over i    ", looped, [Double](repeating: 0, count: looped.count))

    exit(0)
}

if args.contains("--sweep") {
    _ = TrackpadMonitor.shared.start()
    TrackpadMonitor.shared.stop()
    SelfTest.sweep(baseConfig: config)
    exit(0)
}

if args.contains("--selftest") {
    // Surface dimensions come from the real device when present.
    _ = TrackpadMonitor.shared.start()
    TrackpadMonitor.shared.stop()

    let verbose = args.contains("--verbose")
    for noise in [0.20, 0.30, 0.40] {
        SelfTest.run(config: config, sampleSize: 300, noiseKeys: noise, verbose: verbose && noise == 0.30)
    }
    for noise in [0.30, 0.45] {
        SelfTest.run(config: config, sampleSize: 300, noiseKeys: noise, sloppy: true,
                     verbose: verbose && noise == 0.45)
    }
    exit(0)
}

import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
