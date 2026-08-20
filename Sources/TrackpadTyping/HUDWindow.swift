import AppKit

/// Draws the keyboard, the live trace and the current candidates.
///
/// Layout-local coordinates map 1:1 onto view points, so a key pitch is
/// literally a number of pixels and nothing has to be rescaled between what is
/// drawn and what is decoded.
final class HUDView: NSView {
    var layout: KeyboardLayout!
    var livePath: [Pt] = []
    var hoverPoint: Pt?
    var candidates: [String] = []
    var selectedIndex: Int = 0
    /// Horizontal scroll position of the candidate strip, in points.
    var candidateOffset: CGFloat = 0
    var statusText: String = ""
    var bankWords: [String] = []
    /// Click-free (dwell) input mode indicator + toggle.
    var hoverModeOn = false
    /// True while a hover-mode trace is being recorded — tints the grid.
    var hoverTracingActive = false
    /// Dwell feedback ring: view-space point and fill fraction (0 hides it).
    var dwellPoint: NSPoint? = nil
    var dwellProgress: Double = 0
    static let hoverToggleWidth: CGFloat = 58

    var hoverToggleRect: NSRect {
        let top = bounds.height - bounds.height   // silence unused warnings pattern
        _ = top
        return NSRect(x: Self.margin, y: 4 + 2,
                      width: Self.hoverToggleWidth, height: Self.bankHeight - 12)
    }
    /// Chip frames from the last candidate-strip draw, for click hit-testing.
    private(set) var candidateRects: [NSRect] = []

    /// Everything typed this session, shown in the top bar.
    var typedText: String = ""
    /// Character range (into `typedText`) of the word marked for replacement.
    var replaceRange: Range<Int>? = nil
    /// Word frames from the last text-bar draw, with their character ranges.
    private(set) var typedWordRects: [(NSRect, Range<Int>)] = []

    override var isFlipped: Bool { false }   // y up, matching the layout

    static let margin: CGFloat = 10
    static let stripHeight: CGFloat = 46
    static let bankHeight: CGFloat = 34
    /// Slim strip across the very top; click-holding it moves the panel.
    static let grabberHeight: CGFloat = 16
    /// Bar under the grabber showing the text entered this session.
    static let textBarHeight: CGFloat = 32
    /// Row between the letters and the word bank holding the space bar.
    static let spaceRowHeight: CGFloat = 34

    var padRect: NSRect {
        NSRect(x: Self.margin, y: Self.margin + Self.bankHeight + Self.spaceRowHeight,
               width: CGFloat(layout.width), height: CGFloat(layout.height))
    }

    /// iPhone-style: a wide centred bar in its own row below the letters,
    /// with punctuation keys in the side gaps: ⇧ ' , [space] . ?
    var spaceBarRect: NSRect {
        let w = CGFloat(layout.keyPitch) * 5
        return NSRect(x: bounds.midX - w / 2,
                      y: Self.margin + Self.bankHeight + 3,
                      width: w, height: Self.spaceRowHeight - 6)
    }

    static let punctuationKeys: [String] = ["⇧", "'", ",", ".", "?", "!"]

    func punctuationRect(_ i: Int) -> NSRect {
        let space = spaceBarRect
        let y = space.minY
        let h = space.height
        let leftWidth = space.minX - padRect.minX
        let rightWidth = padRect.maxX - space.maxX
        switch i {
        case 0, 1, 2:   // ⇧ ' , share the left gap
            let w = (leftWidth - 8) / 3
            return NSRect(x: padRect.minX + CGFloat(i) * (w + 3), y: y, width: w, height: h)
        default:        // . ? ! share the right gap
            let w = (rightWidth - 10) / 3
            return NSRect(x: space.maxX + 4 + CGFloat(i - 3) * (w + 3), y: y, width: w, height: h)
        }
    }

    /// Highlights the ⇧ key while the next letter will be capitalized.
    var shiftArmed = false

    private func drawPunctuation() {
        for (i, label) in Self.punctuationKeys.enumerated() {
            let rect = punctuationRect(i)
            let isShift = (i == 0)
            if isShift && shiftArmed {
                NSColor(calibratedRed: 0.24, green: 0.5, blue: 0.95, alpha: 0.9).setFill()
            } else {
                NSColor(calibratedWhite: 0.26, alpha: 0.95).setFill()
            }
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: (isShift && shiftArmed) ? NSColor.white
                                : NSColor(calibratedWhite: 0.72, alpha: 1),
            ]
            let str = NSString(string: label)
            let size = str.size(withAttributes: attrs)
            str.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                     withAttributes: attrs)
        }
    }

    /// Equal-width slots along the bottom edge, right of the hover toggle.
    func bankSlotRect(_ i: Int) -> NSRect {
        let left = Self.margin + Self.hoverToggleWidth + 6
        let count = max(bankWords.count, 1)
        let w = (bounds.width - left - Self.margin) / CGFloat(count)
        return NSRect(x: left + CGFloat(i) * w, y: 4,
                      width: w, height: Self.bankHeight - 6)
    }

    func bankIndex(at viewPoint: NSPoint) -> Int? {
        for i in bankWords.indices where bankSlotRect(i).contains(viewPoint) { return i }
        return nil
    }

    private func toView(_ p: Pt) -> NSPoint {
        NSPoint(x: padRect.minX + CGFloat(p.x), y: padRect.minY + CGFloat(p.y))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.09, alpha: 0.92).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 16, yRadius: 16).fill()

        drawGrabber()
        drawTypedBar()
        drawCandidateStrip()
        if hoverTracingActive {
            let r = padRect.insetBy(dx: -3, dy: -3)
            NSColor(calibratedRed: 0.3, green: 0.6, blue: 1.0, alpha: 0.5).setStroke()
            let b = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            b.lineWidth = 2.5
            b.stroke()
        }
        drawKeys()
        drawDeleteKey(active: deleteActive)
        drawSpaceBar()
        drawPunctuation()
        drawHoverToggle()
        drawBank()
        drawTrace()
        drawDwellRing()
    }

    private func drawGrabber() {
        // A sheet-style pill, the shared idiom for "this edge moves the thing".
        let pill = NSRect(x: bounds.midX - 18, y: bounds.height - Self.grabberHeight / 2 - 5,
                          width: 36, height: 5)
        NSColor(calibratedWhite: 0.45, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 2.5, yRadius: 2.5).fill()
    }

    var grabberRect: NSRect {
        NSRect(x: 0, y: bounds.height - Self.grabberHeight,
               width: bounds.width, height: Self.grabberHeight)
    }

    private func drawTypedBar() {
        let barY = bounds.height - Self.grabberHeight - Self.textBarHeight
        let bar = NSRect(x: Self.margin, y: barY + 2,
                         width: bounds.width - Self.margin * 2, height: Self.textBarHeight - 4)
        NSColor(calibratedWhite: 0.14, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: bar, xRadius: 6, yRadius: 6).fill()
        typedWordRects = []

        guard !typedText.isEmpty else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1),
            ]
            NSString(string: "typed text appears here — click a word to replace it").draw(
                at: NSPoint(x: bar.minX + 8, y: bar.midY - 7), withAttributes: attrs)
            return
        }

        // Segment into clickable letter-runs and inert connective text.
        // Punctuation is deliberately NOT part of a word's range: replacing
        // "hello" in "hello." must leave the period standing, so the mark can
        // only ever cover letters.
        enum Seg { case word(String, Range<Int>); case glue(String) }
        var segs: [Seg] = []
        let chars = Array(typedText)
        var i = 0
        while i < chars.count {
            let isWordChar = { (c: Character) in c.isLetter || c == "'" }
            let start = i
            if isWordChar(chars[i]) {
                while i < chars.count && isWordChar(chars[i]) { i += 1 }
                segs.append(.word(String(chars[start..<i]), start..<i))
            } else {
                while i < chars.count && !isWordChar(chars[i]) { i += 1 }
                segs.append(.glue(String(chars[start..<i])))
            }
        }

        // Newest text matters most: lay out right-to-left from the bar's end
        // and stop when full, so the tail is always the visible part.
        let font = NSFont.systemFont(ofSize: 13)
        let glueAttrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1),
        ]
        var x = bar.maxX - 6
        var drawn: [(NSString, NSRect, Range<Int>?, Bool)] = []
        for seg in segs.reversed() {
            switch seg {
            case .glue(let text):
                let str = NSString(string: text)
                let w = str.size(withAttributes: glueAttrs).width
                if x - w < bar.minX + 4 { x = bar.minX + 3 } // clipped; stop below
                else {
                    drawn.append((str, NSRect(x: x - w, y: bar.minY, width: w, height: bar.height), nil, false))
                    x -= w
                }
            case .word(let word, let range):
                let marked = (range == replaceRange)
                let str = NSString(string: word)
                let size = str.size(withAttributes: [.font: font])
                let chip = NSRect(x: x - size.width - 12, y: bar.minY + 3,
                                  width: size.width + 12, height: bar.height - 6)
                if chip.minX < bar.minX + 4 { x = bar.minX + 3 }
                else {
                    drawn.append((str, chip, range, marked))
                    x = chip.minX - 3
                }
            }
            if x <= bar.minX + 3 { break }
        }

        for (str, rect, range, marked) in drawn {
            if let range {
                // Every word is a chip, so every word looks pressable.
                if marked {
                    NSColor(calibratedRed: 0.85, green: 0.45, blue: 0.20, alpha: 0.9).setFill()
                } else {
                    NSColor(calibratedWhite: 0.24, alpha: 0.95).setFill()
                }
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: marked ? NSColor.white : NSColor(calibratedWhite: 0.80, alpha: 1),
                ]
                str.draw(at: NSPoint(x: rect.minX + 6, y: rect.midY - 8), withAttributes: attrs)
                typedWordRects.append((rect, range))
            } else {
                str.draw(at: NSPoint(x: rect.minX, y: rect.midY - 8), withAttributes: glueAttrs)
            }
        }
    }

    private func drawSpaceBar() {
        let rect = spaceBarRect
        NSColor(calibratedWhite: 0.30, alpha: 0.95).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.62, alpha: 1),
        ]
        let s = NSString(string: "space")
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
               withAttributes: attrs)
    }

    private func drawHoverToggle() {
        let r = hoverToggleRect
        if hoverModeOn {
            NSColor(calibratedRed: 0.24, green: 0.62, blue: 0.42, alpha: 0.95).setFill()
        } else {
            NSColor(calibratedWhite: 0.24, alpha: 0.95).setFill()
        }
        NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: hoverModeOn ? NSColor.white : NSColor(calibratedWhite: 0.62, alpha: 1),
        ]
        let s = NSString(string: "hover")
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2),
               withAttributes: attrs)
    }

    private func drawBank() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 1),
        ]
        for (i, word) in bankWords.enumerated() {
            let slot = bankSlotRect(i).insetBy(dx: 3, dy: 0)
            NSColor(calibratedWhite: 0.19, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: slot, xRadius: 7, yRadius: 7).fill()

            var str = NSString(string: word)
            var size = str.size(withAttributes: attrs)
            if size.width > slot.width - 8 {          // never overflow a slot
                str = NSString(string: word.prefix(8) + "…")
                size = str.size(withAttributes: attrs)
            }
            str.draw(at: NSPoint(x: slot.midX - size.width / 2,
                                 y: slot.midY - size.height / 2),
                     withAttributes: attrs)
        }
    }

    private var stripRect: NSRect {
        NSRect(x: Self.margin,
               y: bounds.height - Self.grabberHeight - Self.textBarHeight - Self.stripHeight + 3,
               width: bounds.width - Self.margin * 2,
               height: Self.stripHeight - 6)
    }

    /// Width of the full chip row at the current sizes, for offset clamping.
    func candidateContentWidth() -> CGFloat {
        let font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        var w: CGFloat = 4
        for word in candidates {
            w += NSString(string: word).size(withAttributes: [.font: font]).width + 24 + 10
        }
        return w
    }

    private func drawCandidateStrip() {
        let strip = stripRect
        candidateRects = []

        guard !candidates.isEmpty else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor(calibratedWhite: 0.55, alpha: 1),
            ]
            NSString(string: statusText).draw(
                at: NSPoint(x: strip.minX + 4, y: strip.midY - 8), withAttributes: attrs)
            return
        }

        // Chips render shifted by the scroll offset and clipped to the strip;
        // hit-test rects are recorded at their on-screen positions, so clicks
        // keep working wherever the strip is scrolled to.
        let maxOffset = max(0, candidateContentWidth() - strip.width)
        candidateOffset = min(max(candidateOffset, 0), maxOffset)

        NSGraphicsContext.current?.saveGraphicsState()
        NSBezierPath(rect: strip).addClip()

        var x = strip.minX + 4 - candidateOffset
        for (i, word) in candidates.enumerated() {
            let selected = (i == selectedIndex)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: selected ? .semibold : .medium),
                .foregroundColor: selected ? NSColor.white : NSColor(calibratedWhite: 0.62, alpha: 1),
            ]
            let str = NSString(string: word)
            let size = str.size(withAttributes: attrs)
            let chip = NSRect(x: x, y: strip.minY + 4,
                              width: size.width + 24, height: strip.height - 8)

            if chip.maxX > strip.minX && chip.minX < strip.maxX {   // visible
                if selected {
                    NSColor(calibratedRed: 0.24, green: 0.5, blue: 0.95, alpha: 0.95).setFill()
                } else {
                    NSColor(calibratedWhite: 0.20, alpha: 0.9).setFill()
                }
                NSBezierPath(roundedRect: chip, xRadius: 9, yRadius: 9).fill()
                str.draw(at: NSPoint(x: chip.minX + 12, y: chip.midY - size.height / 2),
                         withAttributes: attrs)
                candidateRects.append(chip)
            } else {
                candidateRects.append(.zero)   // keep indices aligned for hit tests
            }
            x = chip.maxX + 10
        }

        NSGraphicsContext.current?.restoreGraphicsState()

        // Edge fades hint that there is more to scroll to.
        if candidateOffset > 1 {
            NSColor(calibratedWhite: 0.09, alpha: 0.8).setFill()
            NSRect(x: strip.minX, y: strip.minY, width: 10, height: strip.height).fill()
        }
        if candidateOffset < maxOffset - 1 {
            NSColor(calibratedWhite: 0.09, alpha: 0.8).setFill()
            NSRect(x: strip.maxX - 10, y: strip.minY, width: 10, height: strip.height).fill()
        }
    }

    /// Backspace key: right end of the bottom row, phone-keyboard style.
    var deleteKeyRect: NSRect {
        let pitch = CGFloat(layout.keyPitch)
        let rowPitch = CGFloat(layout.rowPitch)
        let r = padRect
        return NSRect(x: r.minX + pitch * 8.55, y: r.minY + 2,
                      width: r.width - pitch * 8.55 - 2, height: rowPitch - 4)
    }

    private func drawDeleteKey(active: Bool) {
        let rect = deleteKeyRect
        (active ? NSColor(calibratedRed: 0.85, green: 0.30, blue: 0.30, alpha: 0.85)
                : NSColor(calibratedWhite: 0.30, alpha: 0.95)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.85, alpha: 1),
        ]
        let s = NSString(string: "⌫")
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
               withAttributes: attrs)
    }

    var deleteActive = false

    private func drawKeys() {
        let pitch = CGFloat(layout.keyPitch)
        let rowPitch = CGFloat(layout.rowPitch)
        let hovered = hoverPoint.flatMap { layout.nearestLetter(to: $0) }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: pitch * 0.38, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.82, alpha: 1),
        ]

        for key in layout.keys.values.sorted(by: { $0.letter < $1.letter }) {
            let c = toView(key.center)
            let rect = NSRect(x: c.x - pitch / 2 + 2, y: c.y - rowPitch / 2 + 2,
                              width: pitch - 4, height: rowPitch - 4)
            let isHovered = (key.letter == hovered)
            if isHovered {
                NSColor(calibratedRed: 0.24, green: 0.5, blue: 0.95, alpha: 0.55).setFill()
            } else {
                NSColor(calibratedWhite: 0.22, alpha: 0.95).setFill()
            }
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()

            let s = NSString(string: String(key.letter).uppercased())
            let size = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
        }
    }

    private func drawDwellRing() {
        guard dwellProgress > 0.03, let c = dwellPoint else { return }
        let r: CGFloat = 14
        let bg = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        NSColor(calibratedWhite: 0.2, alpha: 0.55).setStroke()
        bg.lineWidth = 4
        bg.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: c, radius: r, startAngle: 90,
                      endAngle: 90 - CGFloat(dwellProgress) * 360, clockwise: true)
        NSColor(calibratedRed: 0.35, green: 0.8, blue: 0.5, alpha: 0.95).setStroke()
        arc.lineWidth = 4
        arc.lineCapStyle = .round
        arc.stroke()
    }

    private func drawTrace() {
        guard livePath.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: toView(livePath[0]))
        for p in livePath.dropFirst() { path.line(to: toView(p)) }
        path.lineWidth = 4
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor(calibratedRed: 0.40, green: 0.80, blue: 1.0, alpha: 0.95).setStroke()
        path.stroke()

        // Mark the start so the direction of the trace stays readable.
        let start = toView(livePath[0])
        NSColor(calibratedRed: 0.40, green: 0.80, blue: 1.0, alpha: 0.95).setFill()
        NSBezierPath(ovalIn: NSRect(x: start.x - 5, y: start.y - 5, width: 10, height: 10)).fill()
    }
}

/// A panel that shows the keyboard without ever becoming key.
///
/// Anything that took focus would defeat the point — the keystrokes have to
/// land in the app the user was already typing into. `ignoresMouseEvents` also
/// matters here: the pointer has to travel *over* this panel to trace, and must
/// not be intercepted by it on the way.
final class HUDWindow: NSPanel {
    let hudView = HUDView()
    private let layout: KeyboardLayout
    private let bottomMargin: CGFloat

    init(layout: KeyboardLayout, bottomMargin: CGFloat) {
        self.layout = layout
        self.bottomMargin = bottomMargin

        let width = CGFloat(layout.width) + HUDView.margin * 2
        let height = CGFloat(layout.height) + HUDView.margin * 2
                   + HUDView.stripHeight + HUDView.bankHeight + HUDView.grabberHeight
                   + HUDView.textBarHeight + HUDView.spaceRowHeight

        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        hudView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hudView.layout = layout
        contentView = hudView

        positionBottomCenter()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        setFrameOrigin(NSPoint(x: vf.midX - frame.width / 2, y: vf.minY + bottomMargin))
    }

    /// Restore a saved position, clamped on-screen in case the display
    /// arrangement changed since it was saved.
    func position(savedOrigin: NSPoint?) {
        guard let o = savedOrigin else { positionBottomCenter(); return }
        setFrameOrigin(clampedOnScreen(o))
    }

    func clampedOnScreen(_ origin: NSPoint) -> NSPoint {
        guard let screen = NSScreen.main else { return origin }
        let vf = screen.visibleFrame
        return NSPoint(x: min(max(origin.x, vf.minX), max(vf.minX, vf.maxX - frame.width)),
                       y: min(max(origin.y, vf.minY), max(vf.minY, vf.maxY - frame.height)))
    }

    func isInGrabber(screenPoint p: NSPoint) -> Bool {
        hudView.grabberRect.contains(viewPoint(p))
    }

    func isInDeleteKey(screenPoint p: NSPoint) -> Bool {
        hudView.deleteKeyRect.contains(viewPoint(p))
    }

    func candidateIndex(screenPoint p: NSPoint) -> Int? {
        let v = viewPoint(p)
        return hudView.candidateRects.firstIndex { !$0.isEmpty && $0.contains(v) }
    }

    func isInHoverToggle(screenPoint p: NSPoint) -> Bool {
        hudView.hoverToggleRect.contains(viewPoint(p))
    }

    func isInSpaceBar(screenPoint p: NSPoint) -> Bool {
        hudView.spaceBarRect.contains(viewPoint(p))
    }

    /// True when the point is on the letter-key grid (with a small grace
    /// margin), so stray taps in gutters don't decode into far-away letters.
    func isInKeyArea(screenPoint p: NSPoint) -> Bool {
        keyAreaOnScreen.insetBy(dx: -6, dy: -6).contains(p)
    }

    /// Index into HUDView.punctuationKeys, or nil.
    func punctuationIndex(screenPoint p: NSPoint) -> Int? {
        let v = viewPoint(p)
        return HUDView.punctuationKeys.indices.first { hudView.punctuationRect($0).contains(v) }
    }

    func typedWordRange(screenPoint p: NSPoint) -> Range<Int>? {
        let v = viewPoint(p)
        return hudView.typedWordRects.first { $0.0.contains(v) }?.1
    }

    private func viewPoint(_ p: NSPoint) -> NSPoint {
        NSPoint(x: p.x - frame.minX, y: p.y - frame.minY)
    }

    /// Screen point -> view coordinates, for callers positioning overlays.
    func viewPointPublic(_ p: NSPoint) -> NSPoint { viewPoint(p) }

    /// The key area in screen coordinates (origin bottom-left, y up) — the same
    /// space `NSEvent.mouseLocation` reports in.
    var keyAreaOnScreen: NSRect {
        let r = hudView.padRect
        return NSRect(x: frame.minX + r.minX, y: frame.minY + r.minY,
                      width: r.width, height: r.height)
    }

    /// Screen point -> layout-local coordinates.
    func toLayout(screenPoint p: NSPoint) -> Pt {
        let area = keyAreaOnScreen
        return Pt(x: Double(p.x - area.minX), y: Double(p.y - area.minY))
    }

    /// Centre of the key area, in screen coordinates.
    var centerOnScreen: NSPoint {
        let a = keyAreaOnScreen
        return NSPoint(x: a.midX, y: a.midY)
    }

    /// Which bank slot a screen point falls in, if any.
    func bankIndex(screenPoint p: NSPoint) -> Int? {
        hudView.bankIndex(at: NSPoint(x: p.x - frame.minX, y: p.y - frame.minY))
    }

    func refresh() { hudView.needsDisplay = true }
}
