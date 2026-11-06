import CoreGraphics
import Foundation
import simd

/// A map-like camera over the bay: it looks at a point on the water plane
/// from a distance, turned to a heading and tilted from straight down.
/// World space is local metres: +x east, +y north, +z up.
struct BayCamera: Equatable {
    /// The point on the water the camera looks at (m).
    var target = SIMD2<Double>(0, 0)
    /// Eye to target (m).
    var distance: Double = 40_000
    /// Compass direction of screen-up, radians (0 = north up).
    var heading: Double = 0
    /// Tilt from looking straight down, radians.
    var pitch: Double = 0.5
    /// Drift after a fling (m/s on the ground).
    var velocity = SIMD2<Double>(0, 0)
    /// An animated move.
    var flight: Flight?

    struct Flight: Equatable {
        var target: SIMD2<Double>
        var distance: Double
        var heading: Double
        var pitch: Double
    }

    static let minDistance = 70.0       // about 25 m across a phone screen
    static let maxDistance = 120_000.0
    static let maxPitch = 1.15          // ~66°
    static let fieldOfView = 40.0 * Double.pi / 180

    static func == (a: BayCamera, b: BayCamera) -> Bool {
        a.target == b.target && a.distance == b.distance && a.heading == b.heading && a.pitch == b.pitch
    }

    var isMoving: Bool { velocity != .zero || flight != nil }

    /// Screen-up on the ground.
    var forward: SIMD2<Double> { SIMD2(sin(heading), cos(heading)) }

    var eye: SIMD3<Double> {
        let back = -forward * distance * sin(pitch)
        return SIMD3(target.x + back.x, target.y + back.y, distance * cos(pitch))
    }

    func view() -> simd_float4x4 {
        let e = eye
        // Origin-relative floats are fine: the bay is ±30 km.
        return .lookAt(eye: SIMD3<Float>(e), center: SIMD3<Float>(Float(target.x), Float(target.y), 0),
                       up: SIMD3<Float>(Float(forward.x), Float(forward.y), 0))
    }

    func projection(aspect: Float) -> simd_float4x4 {
        .perspective(fovy: Float(Self.fieldOfView), aspect: aspect, near: Float(max(distance * 0.02, 5)), far: Float(distance * 12 + 20_000))
    }

    func viewProjection(size: CGSize) -> simd_float4x4 {
        projection(aspect: Float(max(size.width, 1) / max(size.height, 1))) * view()
    }

    /// The ground (z = `height`) under a view point, if the ray meets it in front of the camera.
    func ground(at point: CGPoint, in size: CGSize, height: Double = 0) -> SIMD2<Double>? {
        let inv = viewProjection(size: size).inverse
        let ndc = SIMD2<Float>(Float(point.x / size.width) * 2 - 1, 1 - Float(point.y / size.height) * 2)
        let a = inv * SIMD4(ndc.x, ndc.y, 0, 1), b = inv * SIMD4(ndc.x, ndc.y, 1, 1)
        let p0 = SIMD3<Double>(SIMD3(a.x, a.y, a.z) / a.w), p1 = SIMD3<Double>(SIMD3(b.x, b.y, b.z) / b.w)
        let d = p1 - p0
        guard abs(d.z) > 1e-9 else { return nil }
        let t = (height - p0.z) / d.z
        guard t > 0 else { return nil }
        let g = p0 + d * t
        // Reject points out near the horizon.
        guard simd_length(SIMD2(g.x, g.y) - target) < distance * 6 else { return nil }
        return SIMD2(g.x, g.y)
    }

    /// Ground width across the middle of the view (m).
    func viewWidth(aspect: Double) -> Double {
        2 * distance * tan(Self.fieldOfView / 2) * aspect
    }

    // MARK: Gestures

    /// Moves the camera so the ground under `from` ends up under `to`.
    mutating func drag(from: CGPoint, to: CGPoint, in size: CGSize) {
        flight = nil
        guard let a = ground(at: from, in: size), let b = ground(at: to, in: size) else { return }
        var d = a - b
        let cap = distance * 2
        if simd_length(d) > cap { d = simd_normalize(d) * cap }
        target += d
    }

    /// A fling at a screen velocity (points/s) near a point.
    mutating func fling(velocity v: CGPoint, at p: CGPoint, in size: CGSize) {
        let dt = 0.02
        guard let a = ground(at: p, in: size),
              let b = ground(at: CGPoint(x: p.x + v.x * dt, y: p.y + v.y * dt), in: size) else { return }
        var g = (a - b) / dt
        let cap = distance * 3
        if simd_length(g) > cap { g = simd_normalize(g) * cap }
        velocity = simd_length(g) * 0.02 > distance * 0.002 ? g : .zero
    }

    /// Zooms by a factor about a view point, keeping the ground under it still.
    mutating func zoom(by factor: Double, about p: CGPoint, in size: CGSize) {
        flight = nil
        let before = ground(at: p, in: size)
        distance = min(max(distance / factor, Self.minDistance), Self.maxDistance)
        if let before, let after = ground(at: p, in: size) { target += before - after }
    }

    /// Turns the view by an angle (radians, clockwise on screen) about a view point.
    mutating func rotate(by angle: Double, about p: CGPoint, in size: CGSize) {
        flight = nil
        let before = ground(at: p, in: size)
        heading -= angle
        heading = heading.truncatingRemainder(dividingBy: 2 * .pi)
        if let before, let after = ground(at: p, in: size) { target += before - after }
    }

    mutating func tilt(by d: Double) {
        flight = nil
        pitch = min(max(pitch + d, 0), Self.maxPitch)
    }

    mutating func fly(to t: SIMD2<Double>, distance: Double? = nil, heading: Double? = nil, pitch: Double? = nil) {
        velocity = .zero
        var h = heading ?? self.heading
        // Turn the short way round.
        while h - self.heading > .pi { h -= 2 * .pi }
        while h - self.heading < -.pi { h += 2 * .pi }
        flight = Flight(target: t, distance: min(max(distance ?? self.distance, Self.minDistance), Self.maxDistance),
                        heading: h, pitch: min(max(pitch ?? self.pitch, 0), Self.maxPitch))
    }

    mutating func clamp(to bounds: CGRect) {
        let pad = 2_000.0
        target.x = min(max(target.x, Double(bounds.minX) - pad), Double(bounds.maxX) + pad)
        target.y = min(max(target.y, Double(bounds.minY) - pad), Double(bounds.maxY) + pad)
    }

    mutating func step(_ dt: Double) {
        if let f = flight {
            let k = 1 - exp(-dt * 4.5)
            target += (f.target - target) * k
            // Zoom in log space so it feels even.
            distance = exp(log(distance) + (log(f.distance) - log(distance)) * k)
            heading += (f.heading - heading) * k
            pitch += (f.pitch - pitch) * k
            if simd_length(f.target - target) < distance * 0.001, abs(f.distance - distance) < distance * 0.002,
               abs(f.heading - heading) < 0.002, abs(f.pitch - pitch) < 0.002 {
                target = f.target; distance = f.distance; heading = f.heading; pitch = f.pitch
                flight = nil
            }
            return
        }
        guard velocity != .zero else { return }
        target += velocity * dt
        velocity *= exp(-dt * 3.2)
        if simd_length(velocity) < distance * 0.01 { velocity = .zero }
    }
}
