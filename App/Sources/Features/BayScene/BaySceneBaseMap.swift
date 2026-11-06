import CoreGraphics
import Foundation

/// Land around the bay for the base map, beyond the model's box: Natural
/// Earth 1:50m (the Globe's `land50m.rings`, see `LandMask`), rasterised
/// over a regional window instead of the whole Earth. Row 0 is the north edge.
struct BaySceneBaseMap: Sendable {
    static let longitudes = -124.2 ... -120.8
    static let latitudes = 36.6 ... 39.1

    let width: Int
    let height: Int
    /// Land coverage, 0...255.
    let pixels: [UInt8]

    init?(rings data: Data, width: Int = 2048) {
        let lonSpan = Self.longitudes.upperBound - Self.longitudes.lowerBound
        let latSpan = Self.latitudes.upperBound - Self.latitudes.lowerBound
        let midLat = (Self.latitudes.lowerBound + Self.latitudes.upperBound) / 2 * .pi / 180
        let height = Int(Double(width) * latSpan / (lonSpan * cos(midLat)))
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0..<4] == [0x4C, 0x52, 0x4E, 0x47] else { return nil } // "LRNG"
        func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        func i16(_ o: Int) -> Double { Double(Int16(bitPattern: UInt16(bytes[o]) | UInt16(bytes[o + 1]) << 8)) * 180 / 32_767 }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext user space has y up and memory row 0 at the top, so north stays on row 0.
        let W = Double(width), H = Double(height)
        func pt(_ lon: Double, _ lat: Double) -> CGPoint {
            CGPoint(x: (lon - Self.longitudes.lowerBound) / lonSpan * W, y: (lat - Self.latitudes.lowerBound) / latSpan * H)
        }
        let path = CGMutablePath()
        var o = 8
        for _ in 0..<u32(4) {
            guard o + 4 <= bytes.count else { return nil }
            let n = u32(o); o += 4
            guard o + n * 4 <= bytes.count else { return nil }
            defer { o += n * 4 }
            guard n > 2 else { continue }
            var minLon = 999.0, maxLon = -999.0, minLat = 999.0, maxLat = -999.0
            for k in 0..<n {
                let lon = i16(o + 4 * k), lat = i16(o + 4 * k + 2)
                minLon = min(minLon, lon); maxLon = max(maxLon, lon); minLat = min(minLat, lat); maxLat = max(maxLat, lat)
            }
            // Only rings that reach the window (and none that wrap the antimeridian).
            guard maxLon >= Self.longitudes.lowerBound, minLon <= Self.longitudes.upperBound,
                  maxLat >= Self.latitudes.lowerBound, minLat <= Self.latitudes.upperBound, maxLon - minLon < 180 else { continue }
            path.move(to: pt(i16(o), i16(o + 2)))
            for k in 1..<n { path.addLine(to: pt(i16(o + 4 * k), i16(o + 4 * k + 2))) }
            path.closeSubpath()
        }
        ctx.setShouldAntialias(true)
        ctx.addPath(path)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillPath(using: .evenOdd)
        guard let base = ctx.data else { return nil }
        pixels = Array(UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: width * height))
        self.width = width
        self.height = height
    }

    static func load() -> BaySceneBaseMap? {
        guard let url = Bundle.main.url(forResource: "land50m", withExtension: "rings")
                ?? Bundle.main.url(forResource: "land50m", withExtension: "rings", subdirectory: "Globe"),
              let data = try? Data(contentsOf: url) else { return nil }
        return BaySceneBaseMap(rings: data)
    }
}
