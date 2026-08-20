import Foundation
import CoreGraphics

/// Synthesizes keystrokes into whatever application currently has focus.
///
/// Text goes in as Unicode payloads on a keycode-0 event rather than as
/// synthesized key presses: it sidesteps keyboard-layout translation entirely,
/// so the output is the same on QWERTY, Dvorak or AZERTY.
final class TextInjector {
    /// Stamped on every event we post so our own event tap can recognise and
    /// ignore them instead of reprocessing its own output.
    static let signature: Int64 = 0x54_50_54_59   // "TPTY"

    private let source = CGEventSource(stateID: .combinedSessionState)

    /// Some applications truncate long Unicode payloads on a single event, so
    /// text is delivered in small chunks.
    private let chunkSize = 16

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.signature)
        event.post(tap: .cgAnnotatedSessionEventTap)
    }

    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            var end = min(i + chunkSize, units.count)
            // Never split a surrogate pair across chunks: a high surrogate at
            // the boundary would corrupt any non-BMP character (emoji).
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                end += 1
            }
            var chunk = Array(units[i..<end])
            for isDown in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: isDown)
                e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                post(e)
            }
            i = end
        }
    }

    /// Virtual keycode 51 is Delete (backspace).
    func backspace(_ count: Int) {
        guard count > 0 else { return }
        for _ in 0..<count {
            post(CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: true))
            post(CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: false))
        }
    }

    /// Option-Delete: the system-wide "delete previous word", so the focused
    /// app's own notion of a word boundary applies.
    func deleteWord() {
        for isDown in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 51, keyDown: isDown)
            e?.flags = .maskAlternate
            post(e)
        }
    }
}
