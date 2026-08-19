import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()

    private var layout: KeyboardLayout!
    private var lexicon: Lexicon!
    private var decoder: Decoder!
    private var recognizer: GestureRecognizer!
    private let injector = TextInjector()

    private var statusItem: NSStatusItem!
    private var hud: HUDWindow!
    private var hoverTimer: Timer?

    private var glideMode = false
    private var savedPointer: NSPoint?

    /// The trace being drawn while the physical click is held. Sampled on its
    /// own timer rather than from multitouch frames so the path keeps recording
    /// even through momentary sensor dropouts mid-click.
    private var tracePath: [Pt] = []
    private var traceTimer: Timer?
    private var tracing = false

    /// Non-nil while the panel is being dragged by its grabber: the offset from
    /// the cursor to the panel origin, so the panel doesn't jump on grab.
    private var dragOffset: NSPoint? = nil

    /// Hold-to-delete state: when the ⌫ key was pressed and how many repeats
    /// have fired, which together drive the escalation schedule.
    private var deleteHeldSince: Date? = nil
    private var deleteRepeats = 0

    /// Best-effort mirror of what this session has typed into the focused app,
    /// shown in the panel's top bar. It is only a mirror: it goes stale if the
    /// user edits with the real keyboard or moves focus, which is why every
    /// operation built on it (word replacement) is expressed as backspaces
    /// from the end rather than caret movement.
    private var typed = ""
    /// Character range of the typed-bar word marked for replacement; the next
    /// glide fills it.
    private var replaceRange: Range<Int>? = nil
    private var lastSpaceTap: Date? = nil

    /// Letters tapped in unbroken succession — the prefix that completion
    /// predictions are offered for. Any other action ends the run.
    private var letterRun = ""

    /// When the last click-held interaction (trace, delete-hold, panel drag)
    /// ended. Physically clicking the trackpad usually means a thumb pressing
    /// while a finger steers — two contacts — so the finger-lift at the end of
    /// every glide *looks like* a two-finger tap to the recognizer. Any
    /// multi-finger command overlapping or immediately trailing a click is
    /// therefore part of the click, not a command.
    private var lastClickActivityEnd = Date.distantPast

    /// Debug instrumentation: when a file named "debug-ui" exists in the
    /// support directory, every UI update also writes the panel's live state
    /// and hit-rects (screen coordinates) to ui.json, so an external harness
    /// can drive the keyboard and assert on what it believes.
    private lazy var debugUI: Bool = FileManager.default.fileExists(
        atPath: Config.supportDirectory.appendingPathComponent("debug-ui").path)

    private var clickInteractionActive: Bool {
        tracing || dragOffset != nil || deleteHeldSince != nil
    }

    /// What the last glide committed, so it can be cycled or taken back.
    private struct Commit {
        var candidates: [String]
        var index: Int
        /// Length of the committed word text itself (with any auto-space).
        var insertedLength: Int
        /// Text sitting after the word in the field — non-empty when the word
        /// replaced one in the middle of the transcript. Cycling and deleting
        /// must erase and restore it too.
        var tail: String = ""
    }
    private var lastCommit: Commit?

    /// A word is only reinforced once the user has moved on without correcting
    /// it. Reinforcing at commit time would teach the lexicon from its own
    /// mistakes — every wrong first guess would become more likely.
    private var pendingReinforce: String?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard TrackpadMonitor.shared.start() else {
            fatalAlert("Could not open the trackpad",
                       "The MultitouchSupport framework did not return a device. "
                       + "TrackpadTyping needs a built-in or Magic Trackpad to tell "
                       + "when a glide starts and ends.")
            return
        }

        layout = KeyboardLayout(keyPitch: config.screenKeyPitch, rowPitchRatio: config.rowPitchRatio)
        lexicon = Lexicon(config: config)
        decoder = Decoder(layout: layout, lexicon: lexicon, config: config)
        recognizer = GestureRecognizer(config: config, keyPitch: layout.keyPitch)
        hud = HUDWindow(layout: layout, bottomMargin: CGFloat(config.panelBottomMargin))

        recognizer.onEvent = { [weak self] in self?.handle($0) }

        TrackpadMonitor.shared.onFrame = { [weak self] touches, ts in
            self?.recognizer.handle(frame: touches, timestamp: ts)
        }

        setUpStatusItem()

        EventTapController.shared.suppressClicks = config.suppressClicksWhileTyping
        EventTapController.shared.onHotkey = { [weak self] in self?.toggleGlideMode() }
        EventTapController.shared.onTraceDown = { [weak self] in self?.beginTrace() }
        EventTapController.shared.onTraceUp = { [weak self] in self?.endTrace() }
        EventTapController.shared.onArrow = { [weak self] dir in self?.arrowCandidate(dir) }
        let tapOK = EventTapController.shared.start()

        Diagnostics.write(multitouch: true,
                          eventTap: tapOK,
                          lexiconWords: lexicon.count,
                          keyPitch: layout.keyPitch)

        if !tapOK || !Diagnostics.isAccessibilityTrusted {
            requestAccessibilityPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TrackpadMonitor.shared.stop()
    }

    // MARK: - Permissions

    private func requestAccessibilityPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)

        let alert = NSAlert()
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = """
            TrackpadTyping types into other apps, which requires Accessibility access.

            Enable TrackpadTyping in System Settings → Privacy & Security → \
            Accessibility, then relaunch it.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func fatalAlert(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusTitle()

        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Glide Typing  (⌃⌥Space)",
                     action: #selector(menuToggle), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let clickItem = NSMenuItem(title: "Block Clicks While Tracing",
                                   action: #selector(menuToggleClicks), keyEquivalent: "")
        clickItem.target = self
        clickItem.state = config.suppressClicksWhileTyping ? .on : .off
        menu.addItem(clickItem)

        let warpItem = NSMenuItem(title: "Move Pointer to Keyboard on Activate",
                                  action: #selector(menuToggleWarp), keyEquivalent: "")
        warpItem.target = self
        warpItem.state = config.warpPointerOnActivate ? .on : .off
        menu.addItem(warpItem)

        menu.addItem(withTitle: "Reset Keyboard Position",
                     action: #selector(menuResetPosition), keyEquivalent: "").target = self

        menu.addItem(.separator())
        menu.addItem(withTitle: "Reveal Settings File…",
                     action: #selector(menuRevealConfig), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Gesture Reference…",
                     action: #selector(menuShowHelp), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TrackpadTyping",
                     action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
    }

    private func updateStatusTitle() {
        statusItem.button?.title = glideMode ? "⌨︎ ●" : "⌨︎"
        statusItem.button?.toolTip = glideMode ? "Glide typing is ON" : "Glide typing is off"
    }

    @objc private func menuToggle() { toggleGlideMode() }

    @objc private func menuToggleClicks(_ sender: NSMenuItem) {
        config.suppressClicksWhileTyping.toggle()
        config.save()
        sender.state = config.suppressClicksWhileTyping ? .on : .off
        EventTapController.shared.suppressClicks = config.suppressClicksWhileTyping
    }

    @objc private func menuToggleWarp(_ sender: NSMenuItem) {
        config.warpPointerOnActivate.toggle()
        config.save()
        sender.state = config.warpPointerOnActivate ? .on : .off
    }

    @objc private func menuResetPosition() {
        config.panelOriginX = nil
        config.panelOriginY = nil
        config.save()
        hud.positionBottomCenter()
        if glideMode, config.confinePointer {
            EventTapController.shared.confineRect = hud.frame.insetBy(dx: 2, dy: 2)
            warpPointer(to: hud.centerOnScreen)
        }
    }

    @objc private func menuRevealConfig() {
        try? FileManager.default.createDirectory(at: Config.supportDirectory,
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: Config.fileURL.path) { config.save() }
        NSWorkspace.shared.activateFileViewerSelecting([Config.fileURL])
    }

    @objc private func menuShowHelp() {
        let alert = NSAlert()
        alert.messageText = "Gestures"
        alert.informativeText = """
            Four-finger tap, or ⌃⌥Space — turn glide typing on and off. The \
            keyboard appears at the bottom of the screen and the pointer jumps \
            onto it.

            While it is on, move the pointer freely — nothing is decoded until \
            you press. Then:
              Click and HOLD, sweep, release — trace a word
              Quick click                    — type the letter under the pointer
              Quick click on a bank word     — type that word
              Space bar                      — space; double-tap for “. ”
              Click a word in the top bar    — mark it, then glide to replace it
              Click a suggested word, or ←/→ — pick a candidate / completion
              ⌫ key                          — backspace; hold to delete more
              Hold the top grab bar          — move the keyboard
              Two fingers, tap               — cycle to the next candidate
              Two fingers, swipe left        — backspace
              Two fingers, swipe down        — delete the last word
              Three fingers, tap             — space

            The pointer stays confined to the keyboard while the mode is on; \
            leave with another four-finger tap or ⌃⌥Space.
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Mode

    private func toggleGlideMode() {
        glideMode.toggle()
        EventTapController.shared.glideModeActive = glideMode
        updateStatusTitle()

        if glideMode {
            lastCommit = nil
            typed = ""
            letterRun = ""
            clearReplaceTarget()
            lastSpaceTap = nil
            refreshTypedBar()
            hud.hudView.livePath = []
            hud.hudView.candidates = []
            hud.hudView.statusText = "Trace a word"
            let saved: NSPoint? = (config.panelOriginX != nil && config.panelOriginY != nil)
                ? NSPoint(x: config.panelOriginX!, y: config.panelOriginY!) : nil
            hud.position(savedOrigin: saved)
            hud.orderFrontRegardless()

            if config.warpPointerOnActivate {
                savedPointer = NSEvent.mouseLocation
                warpPointer(to: hud.centerOnScreen)
            }
            if config.confinePointer {
                // The whole panel, not just the keys: the word bank at the
                // bottom edge has to stay reachable.
                EventTapController.shared.confineRect = hud.frame.insetBy(dx: 2, dy: 2)
            }
            refreshBank()
            startHoverTracking()
            hud.refresh()
            dumpUIState()
        } else {
            flushReinforcement()
            tracing = false
            dragOffset = nil
            deleteHeldSince = nil
            hud.hudView.deleteActive = false
            setCandidates(active: false)
            traceTimer?.invalidate()
            traceTimer = nil
            tracePath = []
            stopHoverTracking()
            EventTapController.shared.confineRect = nil
            hud.orderOut(nil)
            if let p = savedPointer, config.warpPointerOnActivate { warpPointer(to: p) }
            savedPointer = nil
        }
        NSSound(named: glideMode ? "Tink" : "Pop")?.play()
    }

    /// `CGWarpMouseCursorPosition` works in display space, whose origin is the
    /// top-left of the primary screen — the opposite vertical convention to
    /// `NSEvent.mouseLocation`.
    private func warpPointer(to screenPoint: NSPoint) {
        guard let primary = NSScreen.screens.first else { return }
        CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x,
                                          y: primary.frame.height - screenPoint.y))
        // Warping briefly decouples the cursor from the input device; without
        // this the pointer can stick for a moment afterwards.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Multitouch frames only arrive while fingers are down, so the hovered key
    /// would otherwise freeze the moment the user lifts off.
    private func startHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, self.glideMode else { return }
            let p = self.hud.toLayout(screenPoint: NSEvent.mouseLocation)
            let previous = self.hud.hudView.hoverPoint
            self.hud.hudView.hoverPoint = p
            if previous.flatMap({ self.layout.nearestLetter(to: $0) }) != self.layout.nearestLetter(to: p) {
                self.hud.refresh()
            }
        }
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hud.hudView.hoverPoint = nil
    }

    // MARK: - Tracing (physical click held = drawing a word)

    private func beginTrace() {
        guard glideMode, !tracing else { return }

        // Grabbing the top bar moves the panel; everything else is a trace.
        let mouse = NSEvent.mouseLocation
        if dragOffset == nil, hud.isInGrabber(screenPoint: mouse) {
            dragOffset = NSPoint(x: mouse.x - hud.frame.minX, y: mouse.y - hud.frame.minY)
            // The pointer has to be free to travel while it carries the panel.
            EventTapController.shared.confineRect = nil
            traceTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                guard let self, let off = self.dragOffset else { return }
                let m = NSEvent.mouseLocation
                self.hud.setFrameOrigin(self.hud.clampedOnScreen(
                    NSPoint(x: m.x - off.x, y: m.y - off.y)))
            }
            return
        }

        // Pressing the ⌫ key deletes immediately and then escalates while
        // held: single characters, faster characters, then whole words.
        if hud.isInDeleteKey(screenPoint: mouse) {
            deleteHeldSince = Date()
            deleteRepeats = 0
            letterRun = ""
            setCandidates(active: false)
            pendingReinforce = nil
            lastCommit = nil          // arbitrary deletion invalidates word-undo
            erase(1)
            hud.hudView.deleteActive = true
            updateHUD(candidates: [], status: "⌫")

            traceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let since = self.deleteHeldSince else { return }
                let held = Date().timeIntervalSince(since)
                guard held > 0.40 else { return }   // grace period before repeat
                let active = held - 0.40
                // Escalation: 8 chars/s for two seconds, then whole words.
                let due: Int
                if active < 2.0 {
                    due = Int(active / 0.125)
                } else {
                    due = 16 + Int((active - 2.0) / 0.30)
                }
                while self.deleteRepeats < due {
                    self.deleteRepeats += 1
                    if self.deleteRepeats <= 16 {
                        self.erase(1)
                    } else {
                        self.eraseWord()
                    }
                }
            }
            return
        }

        setCandidates(active: false)
        tracing = true
        tracePath = [hud.toLayout(screenPoint: NSEvent.mouseLocation)]

        traceTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self, self.tracing else { return }
            let p = self.hud.toLayout(screenPoint: NSEvent.mouseLocation)
            // Skip near-duplicates: a paused cursor would otherwise pack the
            // path with points and bias resampling toward the hesitation.
            if self.tracePath.last.map({ $0.distance(to: p) > 0.5 }) ?? true {
                self.tracePath.append(p)
                self.hud.hudView.livePath = self.tracePath
                self.hud.refresh()
            }
        }
    }

    private func endTrace() {
        lastClickActivityEnd = Date()

        if deleteHeldSince != nil {
            deleteHeldSince = nil
            deleteRepeats = 0
            traceTimer?.invalidate()
            traceTimer = nil
            hud.hudView.deleteActive = false
            hud.refresh()
            return
        }

        if dragOffset != nil {
            // Drop the panel: persist the spot and restore confinement there.
            dragOffset = nil
            traceTimer?.invalidate()
            traceTimer = nil
            config.panelOriginX = Double(hud.frame.minX)
            config.panelOriginY = Double(hud.frame.minY)
            config.save()
            if config.confinePointer {
                EventTapController.shared.confineRect = hud.frame.insetBy(dx: 2, dy: 2)
            }
            return
        }

        guard glideMode, tracing else { return }
        tracing = false
        traceTimer?.invalidate()
        traceTimer = nil

        let path = tracePath
        tracePath = []
        flushReinforcement()

        if Geometry.pathLength(path) < config.tapMaxTravelKeys * layout.keyPitch {
            // A click that barely moved: whichever control it landed on, or
            // failing all of those, the letter key under the pointer.
            let mouseUp = NSEvent.mouseLocation
            if hud.isInSpaceBar(screenPoint: mouseUp) {
                spaceBarTapped()
            } else if let range = hud.typedWordRange(screenPoint: mouseUp) {
                toggleReplaceTarget(range)
            } else if let idx = hud.candidateIndex(screenPoint: mouseUp),
               lastCommit != nil {
                selectCandidate(idx)
            } else if let slot = hud.bankIndex(screenPoint: NSEvent.mouseLocation),
               slot < hud.hudView.bankWords.count {
                let word = hud.hudView.bankWords[slot]
                letterRun = ""
                if let target = replaceRange {
                    _ = performReplace(target: target, with: word)
                } else {
                    injectWordSeparatorIfNeeded()
                    inject(word + (config.autoSpace ? " " : ""))
                }
                lexicon.reinforce(word)   // an explicit pick counts as usage
                lastCommit = nil
                updateHUD(candidates: [], status: word)
                refreshBank()
            } else if let p = path.last, let ch = decoder.decodeTap(at: p) {
                if let target = replaceRange {
                    _ = performReplace(target: target, with: String(ch))
                    lastCommit = nil
                    updateHUD(candidates: [], status: String(ch))
                } else {
                    inject(String(ch))
                    letterRun.append(ch)
                    offerCompletions()
                }
            }
        } else {
            commitGlide(path: path)
        }
    }

    // MARK: - Multi-finger gestures

    private func handle(_ event: GestureRecognizer.Event) {
        // The four-finger tap has to work in both states: it is what turns the
        // mode on in the first place.
        if case .multiTap(let fingers) = event, fingers >= 4 {
            toggleGlideMode()
            return
        }
        guard glideMode else { return }

        // See lastClickActivityEnd: contacts that belong to a physical click
        // must not double as commands. The window covers the thumb lifting a
        // beat after the button releases.
        if clickInteractionActive || Date().timeIntervalSince(lastClickActivityEnd) < 0.4 {
            return
        }

        switch event {
        case .multiTap(let fingers):
            switch fingers {
            case 2: cycleCandidate()
            case 3:
                flushReinforcement()
                insertSpace()
            default: break
            }

        case .multiSwipe(let fingers, let direction):
            guard fingers == 2 else { return }
            switch direction {
            case .left: backspace()
            case .down: deleteLastWord()
            default: break
            }
        }
    }

    private func commitGlide(path: [Pt]) {
        letterRun = ""
        let candidates = decoder.decode(path: path)
        guard let best = candidates.first,
              best.score <= config.maxScoreKeys * layout.keyPitch else {
            // Typing the least-bad word from an unrecognizable trace would be
            // worse than typing nothing: the user knows what they traced, and
            // silence tells them it did not land.
            updateHUD(candidates: [], status: "no match — try again")
            return
        }

        if let target = replaceRange {
            let tail = performReplace(target: target, with: best.word)
            lastCommit = Commit(candidates: candidates.map { $0.word },
                                index: 0,
                                insertedLength: best.word.count,
                                tail: tail)
        } else {
            injectWordSeparatorIfNeeded()
            let text = best.word + (config.autoSpace ? " " : "")
            inject(text)
            lastCommit = Commit(candidates: candidates.map { $0.word },
                                index: 0,
                                insertedLength: text.count)
        }
        pendingReinforce = best.word
        setCandidates(active: true)
        updateHUD(candidates: lastCommit!.candidates, selected: 0, status: best.word)
    }

    private func cycleCandidate() {
        guard let commit = lastCommit, commit.candidates.count > 1 else { return }
        selectCandidate((commit.index + 1) % commit.candidates.count)
    }

    private func arrowCandidate(_ direction: Int) {
        guard let commit = lastCommit, commit.candidates.count > 1 else { return }
        let n = commit.candidates.count
        selectCandidate(((commit.index + direction) % n + n) % n)
    }

    /// Replace the committed word with a specific candidate. The replacement is
    /// live in the target app, so whatever is highlighted when the user simply
    /// keeps typing *is* the chosen word — no separate confirm step.
    private func selectCandidate(_ idx: Int) {
        guard var commit = lastCommit, commit.candidates.indices.contains(idx) else { return }
        commit.index = idx
        let word = commit.candidates[idx]
        let text = commit.tail.isEmpty ? word + (config.autoSpace ? " " : "") : word

        erase(commit.insertedLength + commit.tail.count)
        inject(text + commit.tail)

        commit.insertedLength = text.count
        lastCommit = commit
        letterRun = ""
        pendingReinforce = word
        updateHUD(candidates: commit.candidates, selected: commit.index, status: word)
    }

    /// The arrow keys are only diverted from the focused app while this is on.
    private func setCandidates(active: Bool) {
        EventTapController.shared.candidatesActive = active
    }

    private func backspace() {
        // A single-character correction invalidates the word-level undo state:
        // the commit's recorded length no longer matches what is on screen.
        letterRun = ""
        pendingReinforce = nil
        lastCommit = nil
        setCandidates(active: false)
        erase(1)
        updateHUD(candidates: [], status: "⌫")
    }

    private func deleteLastWord() {
        // Taking a word back is an explicit rejection, so it must not be
        // learned from.
        letterRun = ""
        pendingReinforce = nil
        setCandidates(active: false)
        if let commit = lastCommit {
            erase(commit.insertedLength + commit.tail.count)
            if !commit.tail.isEmpty { inject(commit.tail) }
            lastCommit = nil
            updateHUD(candidates: [], status: "deleted")
        } else {
            erase(1)
        }
    }

    /// Show completions of the current letter run as candidates. The run
    /// itself is slot 0 and stays "selected": predictions are offers, never
    /// impositions — the letters stand unless the user picks one. A lone
    /// "a" or "i" gets no offers at all; they are words in their own right,
    /// and a stray cycle gesture must not be able to inflate them.
    private func offerCompletions() {
        if letterRun == "a" || letterRun == "i" {
            lastCommit = nil
            setCandidates(active: false)
            updateHUD(candidates: [], status: letterRun)
            return
        }
        let completions = lexicon.complete(prefix: letterRun, count: config.candidateCount)
        guard !completions.isEmpty else {
            lastCommit = nil
            setCandidates(active: false)
            updateHUD(candidates: [], status: letterRun)
            return
        }
        lastCommit = Commit(candidates: [letterRun] + completions,
                            index: 0,
                            insertedLength: letterRun.count)
        pendingReinforce = nil          // raw letters are not a decoder win
        setCandidates(active: true)
        updateHUD(candidates: lastCommit!.candidates, selected: 0, status: letterRun)
    }

    private func insertSpace() {
        letterRun = ""
        lastCommit = nil
        setCandidates(active: false)
        inject(" ")
        updateHUD(candidates: [], status: "space")
    }

    /// Space, with the double-tap-for-period convention: a second tap in quick
    /// succession converts the just-typed space into ". ".
    private func spaceBarTapped() {
        flushReinforcement()
        let now = Date()
        if let last = lastSpaceTap, now.timeIntervalSince(last) < 0.45, typed.hasSuffix(" ") {
            lastSpaceTap = nil
            lastCommit = nil
            setCandidates(active: false)
            // The word may carry an auto-space plus the first tap's space;
            // the period belongs directly against the word, so consume every
            // trailing space before placing it.
            var trailing = 0
            for c in typed.reversed() { if c == " " { trailing += 1 } else { break } }
            erase(trailing)
            inject(". ")
            updateHUD(candidates: [], status: ". ")
            return
        }
        lastSpaceTap = now
        insertSpace()
    }

    /// Mark (or unmark) a word in the typed bar; the next glide replaces it.
    private func toggleReplaceTarget(_ range: Range<Int>) {
        flushReinforcement()
        letterRun = ""
        lastCommit = nil
        setCandidates(active: false)
        if replaceRange == range {
            replaceRange = nil
            hud.hudView.replaceRange = nil
            updateHUD(candidates: [], status: "")
        } else {
            replaceRange = range
            hud.hudView.replaceRange = range
            let chars = Array(typed)
            let word = String(chars[range])
            updateHUD(candidates: [], status: "glide to replace “\(word)”")
        }
        hud.refresh()
    }

    /// A whole word about to be appended needs a space before it unless the
    /// text already ends in one — covers gliding right after a tapped letter
    /// ("a" + "test" must not fuse into "atest") and after punctuation whose
    /// trailing space the user deleted. Injected separately from the word so
    /// candidate cycling never erases it.
    private func injectWordSeparatorIfNeeded() {
        if let last = typed.last, !last.isWhitespace { inject(" ") }
    }

    /// Swap the marked typed-bar word for `word`, preserving everything after
    /// it. Expressed entirely as end-of-field edits, so no caret movement.
    /// Returns the preserved tail for the caller's Commit bookkeeping.
    private func performReplace(target: Range<Int>, with word: String) -> String {
        let chars = Array(typed)
        let tail = String(chars[target.upperBound...])
        erase(chars.count - target.lowerBound)
        inject(word + tail)
        return tail
    }

    // MARK: - Transcript-aware output

    private func inject(_ text: String) {
        injector.insert(text)
        typed += text
        clearReplaceTarget()
        refreshTypedBar()
    }

    private func erase(_ n: Int) {
        guard n > 0 else { return }
        injector.backspace(n)
        typed = String(typed.dropLast(n))
        clearReplaceTarget()
        refreshTypedBar()
    }

    /// Mirrors Option-Delete: trailing whitespace, then the word before it.
    private func eraseWord() {
        injector.deleteWord()
        var chars = Array(typed)
        while let c = chars.last, c == " " { chars.removeLast() }
        while let c = chars.last, c != " " { chars.removeLast() }
        typed = String(chars)
        clearReplaceTarget()
        refreshTypedBar()
    }

    private func clearReplaceTarget() {
        // Any text mutation shifts character offsets, so a pending target
        // could point at the wrong word; drop it rather than guess.
        replaceRange = nil
        hud.hudView.replaceRange = nil
    }

    private func refreshTypedBar() {
        hud.hudView.typedText = typed
        hud.refresh()
        dumpUIState()
    }

    private func dumpUIState() {
        guard debugUI else { return }
        // The typed-bar rects are computed during draw; force one now so the
        // dump never describes a stale frame.
        hud.hudView.displayIfNeeded()

        let f = hud.frame
        func screen(_ r: NSRect) -> [Double] {
            [Double(f.minX + r.minX), Double(f.minY + r.minY), Double(r.width), Double(r.height)]
        }
        let keyArea = hud.keyAreaOnScreen
        var keys: [String: [Double]] = [:]
        for k in layout.keys.values {
            keys[String(k.letter)] = [Double(keyArea.minX) + k.center.x,
                                      Double(keyArea.minY) + k.center.y]
        }
        let dict: [String: Any] = [
            "glideMode": glideMode,
            "panel": [Double(f.minX), Double(f.minY), Double(f.width), Double(f.height)],
            "typed": typed,
            "replaceRange": replaceRange.map { [$0.lowerBound, $0.upperBound] } as Any,
            "status": hud.hudView.statusText,
            "candidates": hud.hudView.candidates,
            "candidateRects": hud.hudView.candidateRects.map(screen),
            "typedWords": hud.hudView.typedWordRects.map { ["rect": screen($0.0),
                                                            "range": [$0.1.lowerBound, $0.1.upperBound]] },
            "spaceBar": screen(hud.hudView.spaceBarRect),
            "deleteKey": screen(hud.hudView.deleteKeyRect),
            "keys": keys,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            try? data.write(to: Config.supportDirectory.appendingPathComponent("ui.json"))
        }
    }

    private func flushReinforcement() {
        if let w = pendingReinforce {
            lexicon.reinforce(w)
            refreshBank()
        }
        pendingReinforce = nil
    }

    /// Re-rank the bank. Cheap, and called only when a usage count changed.
    private func refreshBank() {
        hud.hudView.bankWords = lexicon.topUsed(config.wordBankCount)
        hud.refresh()
    }

    private func updateHUD(candidates: [String], selected: Int = 0, status: String) {
        guard glideMode else { return }
        hud.hudView.candidates = candidates
        hud.hudView.selectedIndex = selected
        hud.hudView.statusText = status
        hud.hudView.livePath = []
        hud.refresh()
        dumpUIState()
    }
}
