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
