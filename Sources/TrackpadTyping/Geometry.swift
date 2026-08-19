import Foundation

struct Pt: Equatable {
    var x: Double
    var y: Double

    static func - (a: Pt, b: Pt) -> Pt { Pt(x: a.x - b.x, y: a.y - b.y) }
    static func + (a: Pt, b: Pt) -> Pt { Pt(x: a.x + b.x, y: a.y + b.y) }
    static func * (a: Pt, s: Double) -> Pt { Pt(x: a.x * s, y: a.y * s) }

    var length: Double { (x * x + y * y).squareRoot() }
    func distance(to o: Pt) -> Double { (self - o).length }
}

enum Geometry {
    /// Total arc length of a polyline.
    static func pathLength(_ pts: [Pt]) -> Double {
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count { total += pts[i].distance(to: pts[i - 1]) }
        return total
    }

    /// Resample a polyline into `n` points spaced equally along its arc length.
    /// A degenerate (zero-length) path collapses to `n` copies of its first point,
    /// which is what a tap should look like to the decoder.
    static func resample(_ pts: [Pt], to n: Int) -> [Pt] {
        guard n > 1 else { return pts.isEmpty ? [] : [pts[0]] }
        guard pts.count > 1 else { return Array(repeating: pts.first ?? Pt(x: 0, y: 0), count: n) }

        let total = pathLength(pts)
        guard total > 1e-9 else { return Array(repeating: pts[0], count: n) }

        let step = total / Double(n - 1)
        var out: [Pt] = [pts[0]]
        out.reserveCapacity(n)

        var srcIdx = 1
        var current = pts[0]
        var remaining = step

        while out.count < n && srcIdx < pts.count {
            let segLen = current.distance(to: pts[srcIdx])
            if segLen < remaining {
                remaining -= segLen
                current = pts[srcIdx]
                srcIdx += 1
            } else {
                let t = segLen > 1e-12 ? remaining / segLen : 0
                current = current + (pts[srcIdx] - current) * t
                out.append(current)
                remaining = step
            }
        }
        while out.count < n { out.append(pts[pts.count - 1]) }
        return out
    }

    static func centroid(_ pts: [Pt]) -> Pt {
        guard !pts.isEmpty else { return Pt(x: 0, y: 0) }
        var sx = 0.0, sy = 0.0
        for p in pts { sx += p.x; sy += p.y }
        return Pt(x: sx / Double(pts.count), y: sy / Double(pts.count))
    }

    /// Translate to the origin and scale so the longer bounding-box side is `size`.
    /// This is the SHARK2 "shape channel" normalization: it throws away where the
    /// gesture happened and how big it was, keeping only its form.
    static func normalizeShape(_ pts: [Pt], size: Double) -> [Pt] {
        guard !pts.isEmpty else { return [] }
        var minX = Double.infinity, maxX = -Double.infinity
        var minY = Double.infinity, maxY = -Double.infinity
        for p in pts {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        let span = max(maxX - minX, maxY - minY)
        // A near-zero span means a tap or a straight-line-of-no-extent; scaling
        // that up would amplify sensor noise into a meaningless shape.
        let scale = span > 1e-6 ? size / span : 0
        let c = centroid(pts)
        return pts.map { Pt(x: ($0.x - c.x) * scale, y: ($0.y - c.y) * scale) }
    }

    /// Mean pointwise distance between two equal-length point sequences.
    static func meanPointDistance(_ a: [Pt], _ b: [Pt]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var total = 0.0
        for i in 0..<a.count { total += a[i].distance(to: b[i]) }
        return total / Double(a.count)
    }
}
