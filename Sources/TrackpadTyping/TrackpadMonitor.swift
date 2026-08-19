import Foundation
import MTBridge

struct Touch {
    let id: Int
    let state: Int
    /// Normalized surface coordinates, y up.
    let pos: Pt
    let size: Double

    var isDown: Bool { state == 3 || state == 4 }
}

/// Owns the multitouch stream and republishes it on the main queue.
final class TrackpadMonitor {
    static let shared = TrackpadMonitor()

    /// Delivered on the main queue.
    var onFrame: (([Touch], Double) -> Void)?

    private let lock = NSLock()
    private var _contactCount = 0

    /// Number of fingers currently on the pad. Read from the event-tap thread,
    /// which is why it is updated synchronously in the HID callback rather than
    /// derived from the main-queue republish (that lags by a hop, and a lagging
    /// answer here means stray cursor jumps at the start of every glide).
    var contactCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _contactCount
    }

    private(set) var surfaceWidthMM: Double = 124.8
    private(set) var surfaceHeightMM: Double = 76.8

    private init() {}

    @discardableResult
    func start() -> Bool {
        var w = 0.0, h = 0.0
        if mtb_surface_size_mm(&w, &h) == 0, w > 1, h > 1 {
            surfaceWidthMM = w
            surfaceHeightMM = h
        }
        return mtb_start(mtbFrameCallback) == 0
    }

    func stop() { mtb_stop() }

    fileprivate func ingest(_ touches: [Touch], _ timestamp: Double) {
        let down = touches.filter { $0.isDown }
        lock.lock(); _contactCount = down.count; lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onFrame?(down, timestamp)
        }
    }
}

/// C callbacks cannot capture context, so the trampoline goes through the
/// singleton. It runs on the multitouch HID thread.
private func mtbFrameCallback(_ ptr: UnsafePointer<MTBTouch>?, _ count: Int32, _ timestamp: Double) {
    guard let ptr, count > 0 else {
        TrackpadMonitor.shared.ingest([], timestamp)
        return
    }
    var touches: [Touch] = []
    touches.reserveCapacity(Int(count))
    for i in 0..<Int(count) {
        let t = ptr[i]
        touches.append(Touch(id: Int(t.identifier),
                             state: Int(t.state),
                             pos: Pt(x: Double(t.x), y: Double(t.y)),
                             size: Double(t.size)))
    }
    TrackpadMonitor.shared.ingest(touches, timestamp)
}
