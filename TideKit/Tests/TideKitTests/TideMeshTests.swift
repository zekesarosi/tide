import XCTest
@testable import TideKit

/// The San Francisco Bay mesh model (`sfbay.tidemesh`, docs/SFBAY.md).
final class TideMeshTests: XCTestCase {
    // MARK: Synthetic mesh

    /// Float → IEEE half for the exactly representable values used here.
    static func half(_ f: Float) -> UInt16 {
        if f == 0 { return f.sign == .minus ? 0x8000 : 0 }
        let bits = f.bitPattern
        let sign = UInt16((bits >> 16) & 0x8000)
        let exp = Int((bits >> 23) & 0xFF) - 127 + 15
        precondition(exp > 0 && exp < 31, "not a normal half")
        return sign | UInt16(exp) << 10 | UInt16((bits >> 13) & 0x3FF)
    }

    static let names = ["M2", "K1"]
    // Exact in Float32, so node coordinates round-trip without error.
    static let lon0 = -122.5, lat0 = 37.75, size = 0.125
    /// Unit-square coordinates of the nodes: four corners and the centre.
    static let unit: [(x: Double, y: Double)] = [(0, 0), (1, 0), (1, 1), (0, 1), (0.5, 0.5)]
    static let tris: [[UInt32]] = [[0, 1, 4], [1, 2, 4], [2, 3, 4], [3, 0, 4]]

    /// Values linear in (x, y), so barycentric interpolation is exact.
    static func zeta(_ k: Int, _ x: Double, _ y: Double) -> (re: Double, im: Double) {
        k == 0 ? (0.5 + 0.25 * x, 0.25 * y) : (0.125, -0.125 + 0.25 * x)
    }
    static func cur(_ k: Int, _ x: Double, _ y: Double, surface: Bool) -> SIMD4<Double> {
        let s = surface ? 2.0 : 1.0
        return k == 0 ? SIMD4(0.5 * s, 0.25 * y, 0.25 * x, 0.5 * s) : SIMD4(0.125, 0, 0, 0.125 * x)
    }
    static func mean(_ x: Double, _ y: Double) -> [Double] { [0.25 + 0.5 * x, 0.125, -0.25 * y, 0.5, 0.25 * x] }

    static func syntheticData() -> Data {
        var d = Data("TMSH".utf8)
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func f32(_ v: Float) { u32(v.bitPattern) }
        func f16(_ v: Double) { u16(half(Float(v))) }
        let n = unit.count, k = names.count
        var mesh = Data()
        for (i, p) in unit.enumerated() {
            for v in [Float(lon0 + size * p.x), Float(lat0 + size * p.y), Float(5 + i)] {
                withUnsafeBytes(of: v.bitPattern.littleEndian) { mesh.append(contentsOf: $0) }
            }
            withUnsafeBytes(of: UInt32(100 + i).littleEndian) { mesh.append(contentsOf: $0) }
        }
        for (j, t) in tris.enumerated() {
            for v in t + [UInt32(200 + j)] { withUnsafeBytes(of: v.littleEndian) { mesh.append(contentsOf: $0) } }
        }
        u16(1); u16(UInt16(k)); u32(UInt32(n)); u32(UInt32(tris.count))
        u32(CRC32.checksum(mesh))
        d.append(Data(count: 12))
        for name in names { d.append(contentsOf: Array(name.padding(toLength: 8, withPad: " ", startingAt: 0).utf8)) }
        d.append(mesh)
        for p in unit { mean(p.x, p.y).forEach(f16); f16(0); f16(0); f16(0) }
        for c in 0..<k { for p in unit { let z = zeta(c, p.x, p.y); f16(z.re); f16(z.im) } }
        for surface in [false, true] {
            for c in 0..<k { for p in unit { let v = cur(c, p.x, p.y, surface: surface); f16(v.x); f16(v.y); f16(v.z); f16(v.w) } }
        }
        return d
    }

    func point(_ x: Double, _ y: Double) -> (lat: Double, lon: Double) {
        (Self.lat0 + Self.size * y, Self.lon0 + Self.size * x)
    }

    func testCRC32() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
        let a = Data("hello ".utf8), b = Data("world".utf8)
        let running = b.withUnsafeBytes { CRC32.update(CRC32.checksum(a), $0) }
        XCTAssertEqual(running, CRC32.checksum(a + b))
    }

    func testParsesSyntheticMesh() throws {
        let data = Self.syntheticData()
        let mesh = try TideMesh(data: data)
        XCTAssertEqual(mesh.constituentNames, ["M2", "K1"])
        XCTAssertEqual(mesh.constituents.map(\.name), ["M2", "K1"])
        XCTAssertEqual(mesh.nodeCount, 5)
        XCTAssertEqual(mesh.triangleCount, 4)
        XCTAssertEqual(mesh.triangles, Self.tris.flatMap { $0 })
        XCTAssertEqual(mesh.depths, [5, 6, 7, 8, 9])
        XCTAssertEqual(mesh.sourceNodeIndices, [100, 101, 102, 103, 104])
        XCTAssertEqual(mesh.longitudes[2], -122.375)
        XCTAssertEqual(mesh.latitudes[2], 37.875)
        // meshID is the CRC of the node and triangle blocks.
        let k = 2, n = 5, t = 4
        let nodeStart = 32 + 8 * k
        XCTAssertEqual(mesh.meshID, CRC32.checksum(data.subdata(in: nodeStart..<nodeStart + 16 * (n + t))))
        // Raw blocks are the stored bytes.
        var o = nodeStart + 16 * (n + t)
        for (block, size) in [(TideMesh.Block.mean, 16 * n), (.zeta, 4 * k * n), (.depthMeanCurrent, 8 * k * n), (.surfaceCurrent, 8 * k * n)] {
            XCTAssertEqual(mesh.rawBlock(block), data.subdata(in: o..<o + size), "\(block)")
            o += size
        }
        XCTAssertEqual(o, data.count)
        // Also from a slice that doesn't start at index 0.
        let sliced = (Data([1, 2, 3]) + data).dropFirst(3)
        XCTAssertEqual(try TideMesh(data: sliced).rawBlock(.zeta), mesh.rawBlock(.zeta))
    }

    func testBoundaryEdges() throws {
        let mesh = try TideMesh(data: Self.syntheticData())
        let edges = Set(mesh.boundaryEdges.map { [$0.0, $0.1] })
        XCTAssertEqual(edges, [[0, 1], [1, 2], [2, 3], [3, 0]])
    }

    func testLocate() throws {
        let mesh = try TideMesh(data: Self.syntheticData())
        // Inside the bottom triangle (0, 1, 4).
        let p = point(0.5, 0.2)
        let hit = try XCTUnwrap(mesh.locate(latitude: p.lat, longitude: p.lon))
        XCTAssertEqual(hit.triangle, 0)
        // (0.5, 0.2) = 0.3·n0 + 0.3·n1 + 0.4·n4
        XCTAssertEqual(hit.weights.x, 0.3, accuracy: 1e-5)
        XCTAssertEqual(hit.weights.y, 0.3, accuracy: 1e-5)
        XCTAssertEqual(hit.weights.z, 0.4, accuracy: 1e-5)
        // Every triangle is found from its centroid.
        for (j, t) in Self.tris.enumerated() {
            let c = t.reduce((0.0, 0.0)) { ($0.0 + Self.unit[Int($1)].x / 3, $0.1 + Self.unit[Int($1)].y / 3) }
            let q = point(c.0, c.1)
            XCTAssertEqual(mesh.locate(latitude: q.lat, longitude: q.lon)?.triangle, j)
        }
        // Nodes, interior edges and the outer boundary all resolve.
        for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.5, 0.5), (0.25, 0.25), (0.5, 0.0), (1.0, 0.3), (0.0, 0.999)] {
            let q = point(x, y)
            let r = try XCTUnwrap(mesh.locate(latitude: q.lat, longitude: q.lon), "\(x), \(y)")
            XCTAssertEqual(r.weights.x + r.weights.y + r.weights.z, 1, accuracy: 1e-9)
            XCTAssertGreaterThanOrEqual(min(r.weights.x, r.weights.y, r.weights.z), 0)
        }
        // Outside.
        for (x, y) in [(-0.01, 0.5), (1.01, 0.5), (0.5, -0.01), (0.5, 1.5), (5.0, 5.0)] {
            let q = point(x, y)
            XCTAssertNil(mesh.locate(latitude: q.lat, longitude: q.lon), "\(x), \(y)")
        }
        XCTAssertNil(mesh.locate(latitude: .nan, longitude: Self.lon0))
    }

    func testInterpolationAndPrediction() throws {
        let mesh = try TideMesh(data: Self.syntheticData())
        let date = ISO8601DateFormatter().date(from: "2026-11-05T13:20:00Z")!
        let p = HarmonicBasis.phasors(mesh.constituents, at: date)
        for (x, y) in [(0.3, 0.7), (0.9, 0.1), (0.5, 0.5), (0.05, 0.6)] {
            let q = point(x, y)
            // Water level = Σ re·c + im·s of the linear field, without Z0.
            let expected = (0..<2).reduce(0.0) { s, k in let z = Self.zeta(k, x, y); return s + z.re * p[k].cos + z.im * p[k].sin }
            let level = try XCTUnwrap(mesh.waterLevel(latitude: q.lat, longitude: q.lon, at: date))
            XCTAssertEqual(level, expected, accuracy: 1e-5)

            // The predictor carries the same constants.
            let constants = (0..<2).map { k -> HarmonicConstituent in
                let z = Self.zeta(k, x, y)
                return HarmonicConstituent(name: Self.names[k], amplitude: hypot(z.re, z.im),
                                           phaseGMT: atan2(z.im, z.re) * 180 / .pi, speed: mesh.constituents[k].speed)
            }
            let reference = HarmonicPredictor(constituents: constants)
            let predictor = try XCTUnwrap(mesh.waterLevelPredictor(latitude: q.lat, longitude: q.lon))
            XCTAssertEqual(predictor.meanLevel, 0)
            for h in stride(from: 0.0, through: 48, by: 7) {
                let t = date + h * 3_600
                XCTAssertEqual(predictor.height(at: t), reference.height(at: t), accuracy: 1e-5)
                XCTAssertEqual(predictor.height(at: t), mesh.waterLevel(latitude: q.lat, longitude: q.lon, at: t)!, accuracy: 1e-3)
            }

            for surface in [false, true] {
                let m = Self.mean(x, y)
                var u = surface ? m[3] : m[1], v = surface ? m[4] : m[2]
                for k in 0..<2 {
                    let c = Self.cur(k, x, y, surface: surface)
                    u += c.x * p[k].cos + c.y * p[k].sin
                    v += c.z * p[k].cos + c.w * p[k].sin
                }
                let flow = try XCTUnwrap(mesh.current(latitude: q.lat, longitude: q.lon, at: date, surface: surface))
                XCTAssertEqual(flow.east, u, accuracy: 1e-5)
                XCTAssertEqual(flow.north, v, accuracy: 1e-5)
            }
        }
        XCTAssertNil(mesh.waterLevel(latitude: 0, longitude: 0, at: date))
        XCTAssertNil(mesh.current(latitude: 0, longitude: 0, at: date, surface: false))
        XCTAssertNil(mesh.waterLevelPredictor(latitude: 0, longitude: 0))
    }

    func testRejectsBadFiles() {
        let good = Self.syntheticData()
        func error(_ d: Data) -> TideMesh.LoadError? {
            do { _ = try TideMesh(data: d); return nil } catch { return error as? TideMesh.LoadError }
        }
        var magic = good; magic[0] = 0x58
        XCTAssertEqual(error(magic), .badMagic)
        var version = good; version[4] = 2
        XCTAssertEqual(error(version), .unsupportedVersion(2))
        XCTAssertEqual(error(good.prefix(good.count - 1)), .truncated)
        XCTAssertEqual(error(good.prefix(20)), .truncated)
        XCTAssertEqual(error(Data()), .truncated)
        var crc = good; crc[32 + 16 + 9] ^= 0x01 // a node depth byte
        if case .meshIDMismatch = error(crc) {} else { XCTFail("expected meshIDMismatch, got \(String(describing: error(crc)))") }
        var name = good; name[32] = 0x5A; name[33] = 0x5A // "ZZ"
        XCTAssertEqual(error(name), .unknownConstituent("ZZ"))
    }

    // MARK: Shipped model

    static var shippedURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/Bay/sfbay.tidemesh")
    }

    func shippedMesh() throws -> TideMesh {
        guard let data = try? Data(contentsOf: Self.shippedURL) else { throw XCTSkip("sfbay.tidemesh not present") }
        return try TideMesh(data: data)
    }

    /// The triangle at a point, or at the nearest wet point within ~300 m (stations sit on piers).
    func locateNear(_ mesh: TideMesh, _ lat: Double, _ lon: Double) -> (triangle: Int, weights: SIMD3<Double>)? {
        if let hit = mesh.locate(latitude: lat, longitude: lon) { return hit }
        for r in stride(from: 0.0005, through: 0.003, by: 0.0005) {
            for a in stride(from: 0.0, to: 360, by: 15) {
                let la = lat + r * cos(a * .pi / 180), lo = lon + r * sin(a * .pi / 180) / cos(lat * .pi / 180)
                if let hit = mesh.locate(latitude: la, longitude: lo) { return hit }
            }
        }
        return nil
    }

    func angleDiff(_ a: Double, _ b: Double) -> Double { abs(Angle.normalize(a - b + 180) - 180) }

    func testShippedMeshLoadsAndLocates() throws {
        let mesh = try shippedMesh()
        XCTAssertGreaterThan(mesh.nodeCount, 1_000)
        XCTAssertTrue(mesh.constituentNames.contains("M2"))
        XCTAssertFalse(mesh.boundaryEdges.isEmpty)
        // Every centroid locates to its own triangle (or a neighbour sharing the point).
        var misses = 0
        for t in stride(from: 0, to: mesh.triangleCount, by: 7) {
            let (a, b, c) = mesh.nodes(ofTriangle: t)
            let lat = (Double(mesh.latitudes[a]) + Double(mesh.latitudes[b]) + Double(mesh.latitudes[c])) / 3
            let lon = (Double(mesh.longitudes[a]) + Double(mesh.longitudes[b]) + Double(mesh.longitudes[c])) / 3
            if mesh.locate(latitude: lat, longitude: lon)?.triangle != t { misses += 1 }
        }
        XCTAssertEqual(misses, 0)

        // Locate speed: random points over the bounding box.
        let box = mesh.bounds
        var rng = SystemRandomNumberGenerator()
        let points = (0..<100_000).map { _ in
            (Double.random(in: box.minLatitude...box.maxLatitude, using: &rng), Double.random(in: box.minLongitude...box.maxLongitude, using: &rng))
        }
        let start = Date()
        var found = 0
        for p in points where mesh.locate(latitude: p.0, longitude: p.1) != nil { found += 1 }
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "TideMesh.locate: %d nodes, %d triangles; 100k random points in %.3f s (%.2f µs each), %d inside",
                     mesh.nodeCount, mesh.triangleCount, elapsed, elapsed * 10, found))
        XCTAssertLessThan(elapsed, 5)
    }

    func testShippedWaterLevelAtSanFrancisco() throws {
        let mesh = try shippedMesh()
        let noaa = try JSONDecoder().decode(HarconFile.self, from: Fixtures.data("harcon_9414290"))
        let m2 = try XCTUnwrap(noaa.HarmonicConstituents.first { $0.name == "M2" })
        let hit = try XCTUnwrap(locateNear(mesh, 37.8063, -122.4659), "San Francisco is outside the mesh")
        let k = try XCTUnwrap(mesh.constituentNames.firstIndex(of: "M2"))
        let z = mesh.zetaConstants(triangle: hit.triangle, weights: hit.weights)[k]
        let amp = hypot(z.re, z.im), phase = Angle.normalize(atan2(z.im, z.re) * 180 / .pi)
        print(String(format: "9414290 M2: model %.3f m %.1f°, NOAA %.3f m %.1f°", amp, phase, m2.amplitude, m2.phase_GMT))
        XCTAssertEqual(amp, m2.amplitude, accuracy: 0.15 * m2.amplitude)
        XCTAssertLessThan(angleDiff(phase, m2.phase_GMT), 10)
    }

    func testShippedCurrentsAtGoldenGateAndRaccoonStrait() throws {
        let mesh = try shippedMesh()
        let k = try XCTUnwrap(mesh.constituentNames.firstIndex(of: "M2"))
        for (id, lat, lon) in [("SFB1203", 37.8201, -122.473), ("SFB1212", 37.8719, -122.442)] {
            let noaa = try JSONDecoder().decode(CurrentHarconFile.self, from: Fixtures.data("harcon_current_\(id)"))
            let bins = noaa.HarmonicConstituents.filter { $0.constituentName == "M2" }.sorted { $0.binNbr < $1.binNbr }
            let ref = try XCTUnwrap(bins.isEmpty ? nil : bins[bins.count / 2]) // mid-depth bin
            let hit = try XCTUnwrap(locateNear(mesh, lat, lon), "\(id) is outside the mesh")
            let c = mesh.currentConstants(triangle: hit.triangle, weights: hit.weights, surface: false)[k]
            // Project (u, v) onto NOAA's flood azimuth: east = sin, north = cos.
            let az = ref.azi * .pi / 180
            let re = c.x * sin(az) + c.z * cos(az), im = c.y * sin(az) + c.w * cos(az)
            let amp = hypot(re, im) * 100, phase = Angle.normalize(atan2(im, re) * 180 / .pi)
            print(String(format: "%@ M2 along %.1f°: model %.1f cm/s %.1f°, NOAA bin %d (%.0f m) %.1f cm/s %.1f°",
                         id, ref.azi, amp, phase, ref.binNbr, ref.binDepth, ref.majorAmplitude, ref.majorPhaseGMT))
            XCTAssertEqual(amp, ref.majorAmplitude, accuracy: 0.15 * ref.majorAmplitude, id)
            XCTAssertLessThan(angleDiff(phase, ref.majorPhaseGMT), 10, id)
        }
    }

    struct HarconFile: Decodable {
        struct C: Decodable { let name: String; let amplitude: Double; let phase_GMT: Double }
        let HarmonicConstituents: [C]
    }

    struct CurrentHarconFile: Decodable {
        struct C: Decodable {
            let binNbr: Int; let binDepth: Double; let constituentName: String
            let majorAmplitude: Double; let majorPhaseGMT: Double; let azi: Double
        }
        let HarmonicConstituents: [C]
    }
}
