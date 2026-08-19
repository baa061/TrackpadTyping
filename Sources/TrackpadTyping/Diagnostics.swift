import Foundation
import ApplicationServices

/// Startup state written to a file.
///
/// The two things most likely to be wrong — no multitouch device, or
/// Accessibility not granted — both fail silently from the user's point of
/// view: the menu bar icon appears and simply nothing happens. Recording the
/// answer somewhere readable turns that into a five-second diagnosis.
enum Diagnostics {
    static var logURL: URL { Config.supportDirectory.appendingPathComponent("status.log") }

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    static func write(multitouch: Bool, eventTap: Bool, lexiconWords: Int, keyPitch: Double) {
        let fmt = ISO8601DateFormatter()
        let text = """
            TrackpadTyping status — \(fmt.string(from: Date()))
              bundle            \(Bundle.main.bundleIdentifier ?? "none")
              multitouch device \(multitouch ? "OK" : "FAILED")
              key pitch         \(String(format: "%.0f pt", keyPitch))
              lexicon           \(lexiconWords) words
              accessibility     \(isAccessibilityTrusted ? "granted" : "NOT GRANTED")
              event tap         \(eventTap ? "active" : "FAILED (typing will not work)")

            """
        try? FileManager.default.createDirectory(at: Config.supportDirectory,
                                                 withIntermediateDirectories: true)
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data(text.utf8))
    }
}
