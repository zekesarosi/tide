import CoreGraphics
import Foundation
import Observation
import QuartzCore
import TideKit

/// What the reader tapped in the bay scene.
struct BayProbe: Identifiable {
    enum Place {
        case water(triangle: Int, weights: SIMD3<Double>)
        case land
        /// Water, but beyond the model's box.
        case outside
    }

    let id = UUID()
    let latitude: Double
    let longitude: Double
    let point: SIMD2<Double>
    let place: Place
    let predictor: HarmonicPredictor?
    /// Tide-only highs and lows around the scrubber window, worked out once.
    let events: [TideExtreme]

    func nextEvents(after t: Date, count: Int = 2) -> [TideExtreme] {
        if let first = events.firstIndex(where: { $0.date > t }), events.count - first >= count {
            return Array(events[first..<first + count])
        }
        return Array((predictor?.extrema(from: t, to: t + 26 * 3_600) ?? []).prefix(count))
    }
}

/// A label placed on screen by the renderer.
struct BayPlacedLabel: Identifiable, Equatable {
    let id: String
    let point: CGPoint
    let isWater: Bool
}

/// Things the renderer measures for small SwiftUI views, published a few
/// times a second. Kept apart from `BaySceneModel` so reading them redraws
/// only the views that show them.
@MainActor
@Observable
final class BaySceneOverlay {
    var labels: [BayPlacedLabel] = []
    /// View-space band (points, from the top) where labels may sit: below
    /// the header and above the bottom panel. Set by the view.
    @ObservationIgnored var labelBand: ClosedRange<CGFloat>?
    var probePoint: CGPoint?
    /// Seconds of drift shown per second on screen.
    var driftFactor: Double = 0
}

/// State behind the 3D bay scene.
@MainActor
@Observable
final class BaySceneModel {
    enum Phase: Equatable { case loading, ready, failed(String) }
    enum ColourMode: String, CaseIterable, Identifiable {
        case level, speed, depth
        var id: String { rawValue }
        var title: String {
            switch self {
            case .level: "Water level"
            case .speed: "Current speed"
            case .depth: "Depth"
            }
        }
    }
    enum Relief: String, CaseIterable, Identifiable {
        case natural, auto, strong
        var id: String { rawValue }
        var title: String {
            switch self {
            case .natural: "True scale"
            case .auto: "Exaggerated"
            case .strong: "Very exaggerated"
            }
        }
    }

    private(set) var phase: Phase = .loading
    private(set) var mesh: TideMesh?
    private(set) var geometry: BaySceneGeometry?
    private(set) var baseMap: BaySceneBaseMap?

    /// See `GlobeModel.time`: `time` is published ~15 Hz for SwiftUI;
    /// the renderer reads `liveTime` every frame.
    private(set) var time = Date()
    @ObservationIgnored private(set) var liveTime = Date()
    @ObservationIgnored private var lastPublish: CFTimeInterval = 0
    private(set) var anchor = Date()
    var playing = false
    /// Tide time per second of playback.
    var rate: TimeInterval = 600
    var colourMode: ColourMode = .speed
    var surfaceCurrents = true
    var showsFlow = true
    var relief: Relief = .auto
    var probe: BayProbe?
    /// Live forecast residuals (SFBOFS minus the harmonic model), when loaded.
    var residual: BayResidual?
    var liveStatus: String?
    /// Lowers the particle animation's pace (Reduce Motion).
    var calmFlow = false

    @ObservationIgnored let overlay = BaySceneOverlay()
    /// A request for the camera to move; the renderer consumes it.
    @ObservationIgnored var flyRequest: (point: SIMD2<Double>, distance: Double?)?

    static let window: TimeInterval = 7 * 86_400
    static let rates: [(TimeInterval, String)] = [(600, "10 min/s"), (3_600, "1 h/s"), (10_800, "3 h/s")]

    var offset: Double {
        get { time.timeIntervalSince(anchor) / 3_600 }
        set { setTime(anchor + newValue * 3_600) }
    }

    var rateLabel: String { Self.rates.first { $0.0 == rate }?.1 ?? "\(Int(rate / 60)) min/s" }

    func setTime(_ t: Date) {
        liveTime = min(max(t, anchor - Self.window), anchor + Self.window)
        time = liveTime
    }

    func jumpToNow() {
        anchor = Date()
        setTime(anchor)
    }

    /// Whether the live forecast covers an instant.
    func isLive(at t: Date) -> Bool {
        guard let r = residual else { return false }
        return t >= r.start && t <= r.end
    }

    func load() async {
        guard mesh == nil else { return }
        phase = .loading
        do {
            let (m, g, b) = try await Task.detached(priority: .userInitiated) {
                guard let url = Self.resource("sfbay", "tidemesh") else { throw CocoaError(.fileNoSuchFile) }
                let mesh = try TideMesh(data: Data(contentsOf: url, options: .mappedIfSafe))
                return (mesh, BaySceneGeometry(mesh: mesh), BaySceneBaseMap.load())
            }.value
            mesh = m
            geometry = g
            baseMap = b
            phase = .ready
        } catch {
            phase = .failed("The bay model couldn't be read.")
        }
    }

    nonisolated private static func resource(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext) ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Bay")
    }

    /// Called every display frame by the renderer.
    func advance(_ dt: TimeInterval) {
        guard playing else {
            if time != liveTime { time = liveTime }
            return
        }
        liveTime += dt * rate
        if liveTime > anchor + Self.window { liveTime = anchor - Self.window }
        let now = CACurrentMediaTime()
        if now - lastPublish >= 1.0 / 15 {
            lastPublish = now
            time = liveTime
        }
    }

    // MARK: Values at a point (the probe)

    func waterLevel(_ p: BayProbe, at t: Date) -> Double? {
        guard let mesh, case .water(let tri, let w) = p.place else { return nil }
        var h = mesh.waterLevel(triangle: tri, weights: w, at: t)
        if let r = residual, let s = r.sample(in: mesh, latitude: p.latitude, longitude: p.longitude, at: t) { h += s.zeta }
        return h
    }

    func current(_ p: BayProbe, at t: Date) -> (east: Double, north: Double)? {
        guard let mesh, case .water(let tri, let w) = p.place else { return nil }
        var c = mesh.current(triangle: tri, weights: w, at: t, surface: surfaceCurrents)
        if let r = residual, let s = r.sample(in: mesh, latitude: p.latitude, longitude: p.longitude, at: t) {
            let d = surfaceCurrents ? s.surface : s.depthMean
            c.east += d.east; c.north += d.north
        }
        return c
    }

    func makeProbe(at point: SIMD2<Double>) {
        guard let mesh, let geometry else { return }
        let c = geometry.projection.coordinate(point)
        let place: BayProbe.Place
        var predictor: HarmonicPredictor?
        if let hit = mesh.locate(latitude: c.latitude, longitude: c.longitude) {
            place = .water(triangle: hit.triangle, weights: hit.weights)
            predictor = mesh.waterLevelPredictor(latitude: c.latitude, longitude: c.longitude)
        } else {
            let b = geometry.bounds.insetBy(dx: 300, dy: 300)
            let inside = b.contains(CGPoint(x: point.x, y: point.y))
            // West of the Golden Gate everything beyond the box is the Pacific.
            place = inside ? .land : (point.x < Double(geometry.bounds.minX) + 3_000 ? .outside : .land)
        }
        probe = BayProbe(latitude: c.latitude, longitude: c.longitude, point: point, place: place, predictor: predictor,
                         events: predictor?.extrema(from: anchor - Self.window - 86_400, to: anchor + Self.window + 2 * 86_400) ?? [])
    }
}
