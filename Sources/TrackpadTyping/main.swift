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
