import CoreGraphics
import QuartzCore
import Foundation
import Observation
import TideKit

/// Land as an equirectangular coverage mask, rasterised once from Natural
/// Earth 1:50m polygons (`land50m.rings`, see scripts/pack_globe_data.py).
/// Row 0 is the south pole, column 0 is 180°W, like the tide atlas.
struct LandMask: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    enum LoadError: Error { case badFile }

    init(rings data: Data, width: Int = 4096, height: Int = 2048) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4] == [0x4C, 0x52, 0x4E, 0x47] else { throw LoadError.badFile } // "LRNG"
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        func i16(_ o: Int) -> Double { Double(Int16(bitPattern: UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8)) * 180 / 32_767 }

        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { throw LoadError.badFile }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Memory row 0 is the top of a CGContext (user-space y = height), so
        // map latitude −90° to the top to put the south pole in row 0.
        let W = Double(width), H = Double(height)
        func pt(_ lon: Double, _ lat: Double) -> CGPoint { CGPoint(x: (lon + 180) / 360 * W, y: (90 - lat) / 180 * H) }

        let path = CGMutablePath()
        var o = 8
        let count = u32(4)
        for _ in 0..<count {
            guard o + 4 <= bytes.count else { throw LoadError.badFile }
            let n = u32(o); o += 4
            guard o + n * 4 <= bytes.count, n > 2 else { o += n * 4; continue }
            // Unwrap longitudes so rings that cross the antimeridian stay whole.
            var ring: [(Double, Double)] = []
            ring.reserveCapacity(n + 2)
            var prev: Double?
            for k in 0..<n {
                var lon = i16(o + 4 * k)
                let lat = i16(o + 4 * k + 2)
                if let p = prev {
                    while lon - p > 180 { lon -= 360 }
                    while lon - p < -180 { lon += 360 }
                }
                ring.append((lon, lat)); prev = lon
            }
            o += n * 4
            // A ring that circles a pole (Antarctica) closes through the pole.
            if abs(ring[ring.count - 1].0 - ring[0].0) > 180 {
                let pole: Double = ring[0].1 < 0 ? -90 : 90
                ring.append((ring[ring.count - 1].0, pole))
                ring.append((ring[0].0, pole))
            }
            for shift in [-360.0, 0, 360] {
                path.move(to: pt(ring[0].0 + shift, ring[0].1))
                for (lon, lat) in ring.dropFirst() { path.addLine(to: pt(lon + shift, lat)) }
                path.closeSubpath()
            }
        }
        ctx.setShouldAntialias(true)
        ctx.addPath(path)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillPath(using: .evenOdd)
        guard let base = ctx.data else { throw LoadError.badFile }
        pixels = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: width * height))
        self.width = width
        self.height = height
    }

    /// Land coverage 0...1 at a point (nearest pixel).
    func coverage(latitude: Double, longitude: Double) -> Double {
        var lon = longitude.truncatingRemainder(dividingBy: 360)
        if lon < -180 { lon += 360 } else if lon >= 180 { lon -= 360 }
        let x = min(Int((lon + 180) / 360 * Double(width)), width - 1)
        let y = min(max(Int((latitude + 90) / 180 * Double(height)), 0), height - 1)
        return Double(pixels[y * width + x]) / 255
    }
}

/// What the tide is doing at a point the reader tapped.
struct GlobeProbe: Identifiable {
    let id = UUID()
    let latitude: Double
    let longitude: Double
    let predictor: HarmonicPredictor?
    /// Largest constituent here, for the "mostly twice-daily" line.
    let dominant: HarmonicConstituent?
    let range: Double
    let nearest: (station: Station, meters: Double)?
    /// High and low waters over the scrubber's window, worked out once.
    let events: [TideExtreme]

    var isLand: Bool { predictor == nil }

    /// The next `count` events after `t`.
    func nextEvents(after t: Date, count: Int = 2) -> [TideExtreme] {
        if let first = events.firstIndex(where: { $0.date > t }), events.count - first >= count {
            return Array(events[first..<first + count])
        }
        // Outside the cached window: work it out.
        return Array((predictor?.extrema(from: t, to: t + 26 * 3_600) ?? []).prefix(count))
    }
}

/// State behind the Tide Globe screen.
@MainActor
@Observable
final class GlobeModel {
    enum Phase: Equatable { case loading, ready, failed(String) }

    /// One constituent to isolate, with a plain-language gloss.
    struct Choice: Identifiable, Hashable {
        let name: String?
        let title: String
        let gloss: String
        var id: String { name ?? "all" }
    }

    static let choices: [Choice] = [
        Choice(name: nil, title: "All", gloss: "The full tide"),
        Choice(name: "M2", title: "M2", gloss: "Moon, twice a day"),
        Choice(name: "S2", title: "S2", gloss: "Sun, twice a day"),
        Choice(name: "N2", title: "N2", gloss: "Moon's distance"),
        Choice(name: "K1", title: "K1", gloss: "Moon + Sun, daily"),
        Choice(name: "O1", title: "O1", gloss: "Moon, daily"),
    ]

    private(set) var phase: Phase = .loading
    private(set) var atlas: TideAtlas?
    private(set) var land: LandMask?

    /// The instant on the globe as SwiftUI sees it, refreshed ~15 times a
    /// second during playback. The renderer reads `liveTime`, which moves
    /// every frame; views that read `time` would otherwise redraw at frame rate.
    private(set) var time = Date()
    @ObservationIgnored private(set) var liveTime = Date()
    @ObservationIgnored private var lastPublish: CFTimeInterval = 0
    private(set) var anchor = Date()
    var playing = false
    /// Tide time per second of playback.
    var rate: TimeInterval = 3 * 3_600
    var selection: String?
    var relief = true
    var showsStations = true
    var probe: GlobeProbe?
    /// A request for the camera to fly somewhere; the renderer consumes it.
    struct FlyRequest: Equatable {
        let latitude: Double
        let longitude: Double
        let id = UUID()
    }
    var flyRequest: FlyRequest?
    /// Where the camera starts.
    var initialFocus: (latitude: Double, longitude: Double) = (30, -45)

    /// The scrubber spans a spring–neap fortnight either side of now; playback loops over it.
    static let window: TimeInterval = 7 * 86_400

    var offset: Double {
        get { time.timeIntervalSince(anchor) / 3_600 }
        set { setTime(anchor + newValue * 3_600) }
    }

    func setTime(_ t: Date) {
        liveTime = t
        time = t
    }

    func load() async {
        guard atlas == nil else { return }
        phase = .loading
        do {
            let (a, l) = try await Task.detached(priority: .userInitiated) {
                guard let au = Self.resource("got410c", "tideatlas"), let lu = Self.resource("land50m", "rings") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return (try TideAtlas(data: Data(contentsOf: au, options: .mappedIfSafe)),
                        try LandMask(rings: Data(contentsOf: lu)))
            }.value
            atlas = a
            land = l
            phase = .ready
        } catch {
            phase = .failed("The tide atlas couldn't be read.")
        }
    }

    nonisolated private static func resource(_ name: String, _ ext: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: ext) ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Globe")
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

    func jumpToNow() {
        anchor = Date()
        setTime(anchor)
    }

    func makeProbe(latitude: Double, longitude: Double, stations: [Station]) {
        guard let atlas else { return }
        let onLand = (land?.coverage(latitude: latitude, longitude: longitude) ?? 0) > 0.5
        let cons = onLand ? [] : atlas.harmonicConstituents(latitude: latitude, longitude: longitude)
        let here = CLLocationLike(latitude: latitude, longitude: longitude)
        let nearest = stations.lazy.filter(\.isTidal)
            .map { ($0, here.distance(to: CLLocationLike(latitude: $0.latitude, longitude: $0.longitude))) }
            .min { $0.1 < $1.1 }
        let semi = cons.filter { $0.name.hasSuffix("2") }.reduce(0) { $0 + $1.amplitude }
        let diurnal = cons.filter { $0.name.hasSuffix("1") }.reduce(0) { $0 + $1.amplitude }
        let predictor = cons.isEmpty ? nil : HarmonicPredictor(constituents: cons)
        probe = GlobeProbe(
            latitude: latitude, longitude: longitude,
            predictor: predictor,
            dominant: cons.max { $0.amplitude < $1.amplitude },
            range: 2 * (semi + diurnal),
            nearest: nearest.map { (station: $0.0, meters: $0.1) },
            events: predictor?.extrema(from: anchor - Self.window - 86_400, to: anchor + Self.window + 2 * 86_400) ?? [])
    }
}

/// Great-circle distance without pulling CoreLocation into the model.
struct CLLocationLike {
    let latitude: Double, longitude: Double
    func distance(to o: CLLocationLike) -> Double {
        let r = 6_371_000.0
        let p1 = latitude * .pi / 180, p2 = o.latitude * .pi / 180
        let dp = p2 - p1, dl = (o.longitude - longitude) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * asin(min(1, a.squareRoot()))
    }
}
