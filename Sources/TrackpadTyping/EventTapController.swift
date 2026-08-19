import Foundation
import CoreGraphics
import AppKit

/// A single event tap serving two jobs.
///
/// 1. While glide mode is on *and a finger is down*, it swallows clicks and
///    scrolling, so tracing a word over the keyboard cannot press whatever sits
///    beneath it. Pointer *movement* is deliberately never suppressed: the
///    cursor is the input now, and the user is steering it by eye. Gating on
///    live contact count rather than on the mode alone keeps an external mouse
///    fully usable, since its events arrive when no finger is on the pad.
///
/// 2. It watches for the escape-hatch hotkey. This is on the same tap because
///    the hotkey must be consumed, not merely observed — otherwise toggling
///    would also type into the focused app. It stays armed even when glide mode
///    is off, so there is always a way back regardless of pointer state.
final class EventTapController {
    var glideModeActive = false
    /// Suppress clicks and scrolling while tracing.
    var suppressClicks = true
    var onHotkey: (() -> Void)?
    /// Physical click pressed / released while glide mode is on. The click
    /// itself is consumed: while the keyboard is up, clicking is how a trace
    /// is delimited, and must not also press whatever sits behind the panel.
    var onTraceDown: (() -> Void)?
    var onTraceUp: (() -> Void)?
    /// True while a just-committed word's candidates are on screen; the arrow
    /// keys then belong to candidate selection instead of the focused app.
    var candidatesActive = false
    /// +1 for right, -1 for left.
    var onArrow: ((Int) -> Void)?

    /// While glide mode is on, the pointer is confined to this rect (screen
    /// coordinates, bottom-left origin — the AppKit convention). Nil disables
    /// confinement.
    var confineRect: NSRect? = nil

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Control-Option-Space. Space is virtual keycode 49.
    private let hotkeyKeyCode: Int64 = 49
    private let hotkeyFlags: CGEventFlags = [.maskControl, .maskAlternate]

    static let shared = EventTapController()
    private init() {}

    @discardableResult
    func start() -> Bool {
        // Movement passes through (the cursor is the input), but is observed
        // so the pointer can be herded back onto the keyboard when it escapes.
        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: eventTapCallback,
                                          userInfo: nil) else { return false }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    /// Clamp an escaped pointer back inside the confinement rect.
    /// CGEvent locations use display space (top-left origin of the primary
    /// screen), so the rect is flipped here rather than converting every event.
    fileprivate func confine(_ event: CGEvent) {
        guard glideModeActive, let rect = confineRect,
              let screenH = NSScreen.screens.first?.frame.height else { return }
        let loc = event.location
        let minY = screenH - rect.maxY
        let maxY = screenH - rect.minY
        let cx = min(max(loc.x, rect.minX), rect.maxX)
        let cy = min(max(loc.y, minY), maxY)
        if cx != loc.x || cy != loc.y {
            CGWarpMouseCursorPosition(CGPoint(x: cx, y: cy))
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    fileprivate func shouldSuppressClicks() -> Bool {
        guard glideModeActive, suppressClicks else { return false }
        return TrackpadMonitor.shared.contactCount > 0
    }

    fileprivate func matchesHotkey(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.keyboardEventKeycode) == hotkeyKeyCode else { return false }
        let relevant: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        return event.flags.intersection(relevant) == hotkeyFlags
    }
}

private func eventTapCallback(proxy: CGEventTapProxy,
                              type: CGEventType,
                              event: CGEvent,
                              userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    let controller = EventTapController.shared

    // The system disables a tap that takes too long or that the user revokes;
    // it must be turned back on explicitly or input silently stops being seen.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        controller.reenable()
        return Unmanaged.passUnretained(event)
    }

    // Never reprocess our own synthesized keystrokes.
    if event.getIntegerValueField(.eventSourceUserData) == TextInjector.signature {
        return Unmanaged.passUnretained(event)
    }

    if type == .keyDown {
        if controller.matchesHotkey(event) {
            DispatchQueue.main.async { controller.onHotkey?() }
            return nil
        }
        // 123 = left arrow, 124 = right arrow. Only unmodified presses are
        // taken, and only while a candidate strip is showing — shift/option
        // arrows keep doing selection/word-jumps in the focused app.
        if controller.glideModeActive && controller.candidatesActive {
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let mods: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
            if (code == 123 || code == 124), event.flags.intersection(mods).isEmpty {
                let dir = (code == 124) ? 1 : -1
                DispatchQueue.main.async { controller.onArrow?(dir) }
                return nil
            }
        }
        return Unmanaged.passUnretained(event)
    }

    if type == .mouseMoved || type == .leftMouseDragged {
        controller.confine(event)
        return Unmanaged.passUnretained(event)
    }

    // While the keyboard is up, the primary button belongs to tracing:
    // press starts a word, release commits it.
    if controller.glideModeActive && (type == .leftMouseDown || type == .leftMouseUp) {
        let down = (type == .leftMouseDown)
        DispatchQueue.main.async { (down ? controller.onTraceDown : controller.onTraceUp)?() }
        return nil
    }

    if controller.shouldSuppressClicks() { return nil }
    return Unmanaged.passUnretained(event)
}
