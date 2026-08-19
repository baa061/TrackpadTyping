import Foundation

/// Turns frames of contacts into discrete gestures.
///
/// Only multi-finger gestures are recognised here. Single-finger contact says
/// nothing by itself any more: moving the pointer and tracing a word are the
/// same physical act on a trackpad, so the *physical click* — handled in
/// `EventTapController` — is what delimits a trace. This class watches the
/// finger count for the command gestures layered on top.
///
/// Everything is scoped to a *contact session*: first finger down to last
/// finger up. Classifying only at the end of a session is what lets a
/// two-finger tap be told apart from a passing brush of a second finger.
final class GestureRecognizer {
    enum Direction { case left, right, up, down }

    enum Event {
        case multiTap(fingers: Int)
        case multiSwipe(fingers: Int, direction: Direction)
    }

    var onEvent: ((Event) -> Void)?

    private let config: Config
    private let keyPitch: Double

    private var sessionActive = false
    private var sessionStartTime: Double = 0
    private var maxConcurrent = 0
    /// Finger positions stay in normalized trackpad units.
    private var fingerStart: [Int: Pt] = [:]
    private var fingerLast: [Int: Pt] = [:]

    init(config: Config, keyPitch: Double) {
        self.config = config
        self.keyPitch = keyPitch
    }

    func handle(frame touches: [Touch], timestamp: Double) {
        if touches.isEmpty {
            if sessionActive { endSession(at: timestamp) }
            return
        }

        if !sessionActive {
            sessionActive = true
            sessionStartTime = timestamp
            maxConcurrent = 0
            fingerStart.removeAll(keepingCapacity: true)
            fingerLast.removeAll(keepingCapacity: true)
        }

        maxConcurrent = max(maxConcurrent, touches.count)

        for t in touches {
            if fingerStart[t.id] == nil { fingerStart[t.id] = t.pos }
            fingerLast[t.id] = t.pos
        }
    }

    private func endSession(at timestamp: Double) {
        defer { sessionActive = false }

        let duration = (timestamp - sessionStartTime) * 1000.0
        guard duration >= config.minStrokeDurationMS else { return }
        guard maxConcurrent >= 2 else { return }

        // Multi-finger: mean finger displacement decides tap versus swipe.
        var dx = 0.0, dy = 0.0, n = 0.0
        for (id, start) in fingerStart {
            guard let last = fingerLast[id] else { continue }
            dx += last.x - start.x
            dy += last.y - start.y
            n += 1
        }
        guard n > 0 else { return }
        dx /= n; dy /= n

        if Pt(x: dx, y: dy).length < config.multiSwipeMinTravel {
            onEvent?(.multiTap(fingers: maxConcurrent))
        } else {
            let dir: Direction
            if abs(dx) >= abs(dy) {
                dir = dx < 0 ? .left : .right
            } else {
                dir = dy < 0 ? .down : .up   // normalized trackpad y is up
            }
            onEvent?(.multiSwipe(fingers: maxConcurrent, direction: dir))
        }
    }
}
