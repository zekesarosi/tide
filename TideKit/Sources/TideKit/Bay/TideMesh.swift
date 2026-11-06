import Foundation

/// An unstructured-mesh tide and current model of San Francisco Bay, packed by
/// `scripts/sfbay` from NOAA SFBOFS (see docs/SFBAY.md for the format).
///
/// Every node stores a mean (Z0, mean flow) and, per constituent, the complex
/// constants (H cos G, H sin G) of water level and of the east/north current,
/// fitted against `HarmonicBasis`. A value anywhere is the barycentric blend
/// of its triangle's three nodes; since the harmonic sum is linear, blending
/// the constants is the same as blending the predictions.
public struct TideMesh: Sendable {
    public enum LoadError: Error, Equatable {
        case badMagic
        case unsupportedVersion(Int)
        case badHeader
        case unknownConstituent(String)
        case truncated
        case meshIDMismatch(stored: UInt32, computed: UInt32)
        case constantsIDMismatch(stored: UInt32, computed: UInt32)
        case badTriangle(Int)
    }

    public enum Block: Sendable, CaseIterable {
        case mean, zeta, depthMeanCurrent, surfaceCurrent
    }

    public let constituents: [ConstituentDefinition]
    public let constituentNames: [String]
    public let nodeCount: Int, triangleCount: Int
    public let meshID: UInt32
    /// CRC-32 of everything after the triangle block (the mean and constant
    /// blocks), so a live residual can prove it was computed against these
    /// exact constants. 0 in files written before it was recorded.
    public let constantsID: UInt32
    public let longitudes: [Float], latitudes: [Float], depths: [Float]
    /// SFBOFS node index of each node (0-based).
    public let sourceNodeIndices: [UInt32]
    /// Node indices, 3 per triangle, counter-clockwise in lon/lat.
    public let triangles: [UInt32]
    /// Mesh edges used by one triangle only (coast and open boundary), in the
    /// triangle's winding order.
    public let boundaryEdges: [(UInt32, UInt32)]

    static let headerSize = 32
    static let maxConstituents = 24

    /// The whole file; the f16 blocks are read from it on demand.
    private let storage: Data
    private let offsets: [Block: Int]
    private let grid: LocateGrid

    public init(data: Data) throws {
        let storage = Data(data) // rebased to index 0
        let total = storage.count
        guard total >= Self.headerSize else { throw LoadError.truncated }
        let header = try storage.withUnsafeBytes { raw -> (k: Int, n: Int, t: Int, id: UInt32, constants: UInt32) in
            guard raw[0] == 0x54, raw[1] == 0x4D, raw[2] == 0x53, raw[3] == 0x48 else { throw LoadError.badMagic } // "TMSH"
            let version = Int(raw.leU16(4))
            guard version == 1 else { throw LoadError.unsupportedVersion(version) }
            return (Int(raw.leU16(6)), Int(raw.leU32(8)), Int(raw.leU32(12)), raw.leU32(16), raw.leU32(20))
        }
        let (k, n, t) = (header.k, header.n, header.t)
        guard k <= Self.maxConstituents, n >= 3, t >= 1 else { throw LoadError.badHeader }

        let namesOffset = Self.headerSize
        let nodeOffset = namesOffset + 8 * k
        let triOffset = nodeOffset + 16 * n
        let meanOffset = triOffset + 16 * t
        let zetaOffset = meanOffset + 16 * n
        let depthOffset = zetaOffset + 4 * k * n
        let surfaceOffset = depthOffset + 8 * k * n
        let end = surfaceOffset + 8 * k * n
        guard total >= end else { throw LoadError.truncated }

        var names: [String] = [], defs: [ConstituentDefinition] = []
        for i in 0..<k {
            let start = namesOffset + 8 * i
            let name = storage.withUnsafeBytes { String(decoding: UnsafeRawBufferPointer(rebasing: $0[start..<start + 8]), as: UTF8.self) }
                .trimmingCharacters(in: .whitespaces.union(.controlCharacters))
            guard let def = ConstituentCatalog.definition(named: name) else { throw LoadError.unknownConstituent(name) }
            names.append(name)
            defs.append(def)
        }

        let computed = storage.withUnsafeBytes { CRC32.checksum(UnsafeRawBufferPointer(rebasing: $0[nodeOffset..<meanOffset])) }
        guard computed == header.id else { throw LoadError.meshIDMismatch(stored: header.id, computed: computed) }
        if header.constants != 0 {
            let c = storage.withUnsafeBytes { CRC32.checksum(UnsafeRawBufferPointer(rebasing: $0[meanOffset..<end])) }
            guard c == header.constants else { throw LoadError.constantsIDMismatch(stored: header.constants, computed: c) }
        }

        var lons = [Float](repeating: 0, count: n), lats = lons, deps = lons
        var src = [UInt32](repeating: 0, count: n)
        var tris = [UInt32](repeating: 0, count: 3 * t)
        try storage.withUnsafeBytes { raw in
            for i in 0..<n {
                let o = nodeOffset + 16 * i
                lons[i] = raw.leF32(o); lats[i] = raw.leF32(o + 4); deps[i] = raw.leF32(o + 8); src[i] = raw.leU32(o + 12)
            }
            for j in 0..<t {
                let o = triOffset + 16 * j
                for v in 0..<3 {
                    let index = raw.leU32(o + 4 * v)
                    guard index < n else { throw LoadError.badTriangle(j) }
                    tris[3 * j + v] = index
                }
            }
        }

        self.storage = storage
        constituents = defs
        constituentNames = names
        nodeCount = n
        triangleCount = t
        meshID = header.id
        constantsID = header.constants
        longitudes = lons; latitudes = lats; depths = deps
        sourceNodeIndices = src
        triangles = tris
        offsets = [.mean: meanOffset, .zeta: zetaOffset, .depthMeanCurrent: depthOffset, .surfaceCurrent: surfaceOffset]
        boundaryEdges = Self.boundaryEdges(tris)
        grid = LocateGrid(longitudes: lons, latitudes: lats, triangles: tris)
    }

    /// Bytes of one block of the file, exactly as stored (f16, little endian).
    public func rawBlock(_ block: Block) -> Data {
        let start = offsets[block]!
        return storage.subdata(in: start..<start + byteCount(block))
    }

    private func byteCount(_ block: Block) -> Int {
        switch block {
        case .mean: return 16 * nodeCount
        case .zeta: return 4 * constituents.count * nodeCount
        case .depthMeanCurrent, .surfaceCurrent: return 8 * constituents.count * nodeCount
        }
    }

    /// Bounding box of the mesh nodes, degrees.
    public var bounds: (minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
        (grid.minLat, grid.maxLat, grid.minLon, grid.maxLon)
    }

    // MARK: Point location

    /// The triangle containing a point and the point's barycentric weights
    /// on its nodes (`triangles[3·t ..< 3·t+3]`), or nil outside the mesh.
    /// Points on a shared edge resolve to one of the two triangles.
    public func locate(latitude: Double, longitude: Double) -> (triangle: Int, weights: SIMD3<Double>)? {
        grid.locate(latitude: latitude, longitude: longitude, longitudes: longitudes, latitudes: latitudes, triangles: triangles)
    }

    /// The three node indices of a triangle.
    public func nodes(ofTriangle t: Int) -> (Int, Int, Int) {
        (Int(triangles[3 * t]), Int(triangles[3 * t + 1]), Int(triangles[3 * t + 2]))
    }

    // MARK: Prediction

    /// Tidal water level (m) relative to the model mean Z0: η − Z0.
    public func waterLevel(latitude: Double, longitude: Double, at date: Date) -> Double? {
        guard let (t, w) = locate(latitude: latitude, longitude: longitude) else { return nil }
        return waterLevel(triangle: t, weights: w, at: date)
    }

    /// Tidal current (m/s, east and north), including the mean flow.
    /// `surface` selects sigma layer 0; otherwise the depth mean.
    public func current(latitude: Double, longitude: Double, at date: Date, surface: Bool) -> (east: Double, north: Double)? {
        guard let (t, w) = locate(latitude: latitude, longitude: longitude) else { return nil }
        return current(triangle: t, weights: w, at: date, surface: surface)
    }

    /// A predictor for the water level at a point (relative to Z0), so the
    /// usual curve and high/low code applies.
    public func waterLevelPredictor(latitude: Double, longitude: Double) -> HarmonicPredictor? {
        guard let (t, w) = locate(latitude: latitude, longitude: longitude) else { return nil }
        let z = zetaConstants(triangle: t, weights: w)
        let cons = constituents.indices.map { i -> HarmonicConstituent in
            let (re, im) = z[i]
            return HarmonicConstituent(name: constituents[i].name, amplitude: (re * re + im * im).squareRoot(),
                                       phaseGMT: Angle.normalize(atan2(im, re).degrees), speed: constituents[i].speed)
        }
        return HarmonicPredictor(constituents: cons, meanLevel: 0)
    }

    /// Interpolated water-level constants (H cos G, H sin G), metres, in file order.
    public func zetaConstants(triangle t: Int, weights w: SIMD3<Double>) -> [(re: Double, im: Double)] {
        let base = offsets[.zeta]!
        let n = nodeCount
        let (a, b, c) = nodes(ofTriangle: t)
        return storage.withUnsafeBytes { raw in
            constituents.indices.map { i in
                func at(_ node: Int, _ j: Int) -> Double { Double(raw.leF16(base + 4 * (i * n + node) + 2 * j)) }
                return (w.x * at(a, 0) + w.y * at(b, 0) + w.z * at(c, 0),
                        w.x * at(a, 1) + w.y * at(b, 1) + w.z * at(c, 1))
            }
        }
    }

    /// Interpolated current constants (u re, u im, v re, v im), m/s, in file order.
    public func currentConstants(triangle t: Int, weights w: SIMD3<Double>, surface: Bool) -> [SIMD4<Double>] {
        let base = offsets[surface ? .surfaceCurrent : .depthMeanCurrent]!
        let n = nodeCount
        let (a, b, c) = nodes(ofTriangle: t)
        return storage.withUnsafeBytes { raw in
            constituents.indices.map { i in
                func at(_ node: Int) -> SIMD4<Double> {
                    let o = base + 8 * (i * n + node)
                    return SIMD4(Double(raw.leF16(o)), Double(raw.leF16(o + 2)), Double(raw.leF16(o + 4)), Double(raw.leF16(o + 6)))
                }
                return w.x * at(a) + w.y * at(b) + w.z * at(c)
            }
        }
    }

    /// Interpolated mean values: (Z0, depth-mean u0, v0, surface u0, v0).
    public func meanValues(triangle t: Int, weights w: SIMD3<Double>) -> (z0: Double, depthMean: (east: Double, north: Double), surface: (east: Double, north: Double)) {
        let base = offsets[.mean]!
        let (a, b, c) = nodes(ofTriangle: t)
        let v: [Double] = storage.withUnsafeBytes { raw in
            (0..<5).map { j in
                w.x * Double(raw.leF16(base + 16 * a + 2 * j)) + w.y * Double(raw.leF16(base + 16 * b + 2 * j))
                    + w.z * Double(raw.leF16(base + 16 * c + 2 * j))
            }
        }
        return (v[0], (v[1], v[2]), (v[3], v[4]))
    }

    public func waterLevel(triangle t: Int, weights w: SIMD3<Double>, at date: Date) -> Double {
        let p = HarmonicBasis.phasors(constituents, at: date)
        return zip(zetaConstants(triangle: t, weights: w), p).reduce(0) { $0 + $1.0.re * $1.1.cos + $1.0.im * $1.1.sin }
    }

    public func current(triangle t: Int, weights w: SIMD3<Double>, at date: Date, surface: Bool) -> (east: Double, north: Double) {
        let p = HarmonicBasis.phasors(constituents, at: date)
        let mean = meanValues(triangle: t, weights: w)
        var (u, v) = surface ? mean.surface : mean.depthMean
        for (k, ph) in zip(currentConstants(triangle: t, weights: w, surface: surface), p) {
            u += k.x * ph.cos + k.y * ph.sin
            v += k.z * ph.cos + k.w * ph.sin
        }
        return (u, v)
    }

    // MARK: Topology

    static func boundaryEdges(_ tris: [UInt32]) -> [(UInt32, UInt32)] {
        // Count undirected edges; keep each single-use edge in its triangle's winding.
        var count: [UInt64: Int] = [:]
        count.reserveCapacity(tris.count)
        func key(_ a: UInt32, _ b: UInt32) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
        for j in stride(from: 0, to: tris.count, by: 3) {
            for e in 0..<3 { count[key(tris[j + e], tris[j + (e + 1) % 3]), default: 0] += 1 }
        }
        var out: [(UInt32, UInt32)] = []
        for j in stride(from: 0, to: tris.count, by: 3) {
            for e in 0..<3 {
                let a = tris[j + e], b = tris[j + (e + 1) % 3]
                if count[key(a, b)] == 1 { out.append((a, b)) }
            }
        }
        return out
    }
}

// MARK: - Locate grid

/// A uniform grid of triangle buckets over the mesh's bounding box, with cells
/// roughly square on the ground (longitude scaled by cos latitude).
struct LocateGrid: Sendable {
    let minLon: Double, minLat: Double, maxLon: Double, maxLat: Double
    let columns: Int, rows: Int
    let cellLon: Double, cellLat: Double
    /// CSR buckets: triangles of cell c are `items[starts[c] ..< starts[c+1]]`.
    let starts: [Int32]
    let items: [Int32]

    init(longitudes: [Float], latitudes: [Float], triangles: [UInt32]) {
        let lonMin = Double(longitudes.min() ?? 0), lonMax = Double(longitudes.max() ?? 0)
        let latMin = Double(latitudes.min() ?? 0), latMax = Double(latitudes.max() ?? 0)
        minLon = lonMin; maxLon = lonMax; minLat = latMin; maxLat = latMax
        let t = triangles.count / 3
        let scale = cos(((latMin + latMax) / 2) * .pi / 180)
        let width = max((lonMax - lonMin) * scale, 1e-9), height = max(latMax - latMin, 1e-9)
        // About one triangle per cell on average.
        let side = (width * height / Double(max(t, 1))).squareRoot()
        columns = max(1, min(4_096, Int((width / side).rounded(.up))))
        rows = max(1, min(4_096, Int((height / side).rounded(.up))))
        cellLon = max(lonMax - lonMin, 1e-9) / Double(columns)
        cellLat = max(latMax - latMin, 1e-9) / Double(rows)

        let (columns, rows, cellLon, cellLat) = (self.columns, self.rows, self.cellLon, self.cellLat)
        func cellRange(_ j: Int) -> (ClosedRange<Int>, ClosedRange<Int>) {
            var x0 = Double.infinity, x1 = -Double.infinity, y0 = Double.infinity, y1 = -Double.infinity
            for v in 0..<3 {
                let n = Int(triangles[3 * j + v])
                x0 = min(x0, Double(longitudes[n])); x1 = max(x1, Double(longitudes[n]))
                y0 = min(y0, Double(latitudes[n])); y1 = max(y1, Double(latitudes[n]))
            }
            let c0 = Self.clamp(Int(((x0 - lonMin) / cellLon).rounded(.down)), columns)
            let c1 = Self.clamp(Int(((x1 - lonMin) / cellLon).rounded(.down)), columns)
            let r0 = Self.clamp(Int(((y0 - latMin) / cellLat).rounded(.down)), rows)
            let r1 = Self.clamp(Int(((y1 - latMin) / cellLat).rounded(.down)), rows)
            return (c0...c1, r0...r1)
        }
        let cells = columns * rows
        var counts = [Int32](repeating: 0, count: cells + 1)
        for j in 0..<t {
            let (cs, rs) = cellRange(j)
            for r in rs { for c in cs { counts[r * columns + c + 1] += 1 } }
        }
        for i in 0..<cells { counts[i + 1] += counts[i] }
        var fill = counts
        var items = [Int32](repeating: 0, count: Int(counts[cells]))
        for j in 0..<t {
            let (cs, rs) = cellRange(j)
            for r in rs {
                for c in cs {
                    let cell = r * columns + c
                    items[Int(fill[cell])] = Int32(j)
                    fill[cell] += 1
                }
            }
        }
        starts = counts
        self.items = items
    }

    static func clamp(_ v: Int, _ n: Int) -> Int { min(max(v, 0), n - 1) }

    func locate(latitude: Double, longitude: Double, longitudes: [Float], latitudes: [Float],
                triangles: [UInt32]) -> (triangle: Int, weights: SIMD3<Double>)? {
        let tolerance = 1e-9
        let marginLon = cellLon * 1e-6, marginLat = cellLat * 1e-6
        guard latitude.isFinite, longitude.isFinite,
              longitude >= minLon - marginLon, longitude <= maxLon + marginLon,
              latitude >= minLat - marginLat, latitude <= maxLat + marginLat else { return nil }
        let c = Self.clamp(Int(((longitude - minLon) / cellLon).rounded(.down)), columns)
        let r = Self.clamp(Int(((latitude - minLat) / cellLat).rounded(.down)), rows)
        let cell = r * columns + c
        var best: (triangle: Int, weights: SIMD3<Double>, score: Double)?
        for i in Int(starts[cell])..<Int(starts[cell + 1]) {
            let j = Int(items[i])
            let a = Int(triangles[3 * j]), b = Int(triangles[3 * j + 1]), d = Int(triangles[3 * j + 2])
            // Barycentric weights are affine-invariant, so plain degrees will do.
            let ax = Double(longitudes[a]), ay = Double(latitudes[a])
            let bx = Double(longitudes[b]) - ax, by = Double(latitudes[b]) - ay
            let cx = Double(longitudes[d]) - ax, cy = Double(latitudes[d]) - ay
            let px = longitude - ax, py = latitude - ay
            let det = bx * cy - by * cx
            guard det != 0 else { continue }
            let wb = (px * cy - py * cx) / det
            let wc = (bx * py - by * px) / det
            let wa = 1 - wb - wc
            let score = min(wa, wb, wc)
            if score >= 0 { return (j, SIMD3(wa, wb, wc)) }
            if score >= -tolerance, score > (best?.score ?? -.infinity) { best = (j, SIMD3(wa, wb, wc), score) }
        }
        guard let b = best else { return nil }
        // Snap a point a hair outside onto the triangle.
        let w = simd_max0(b.weights)
        return (b.triangle, w / (w.x + w.y + w.z))
    }

    private func simd_max0(_ w: SIMD3<Double>) -> SIMD3<Double> { SIMD3(max(w.x, 0), max(w.y, 0), max(w.z, 0)) }
}

// MARK: - CRC-32

/// CRC-32 (IEEE 802.3, reflected polynomial 0xEDB88320), as zlib's `crc32`.
enum CRC32 {
    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// Continues a running CRC (start with 0) over more bytes.
    static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = ~crc
        table.withUnsafeBufferPointer { t in
            for byte in bytes { c = t[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }

    static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 { update(0, bytes) }

    static func checksum(_ data: Data) -> UInt32 { data.withUnsafeBytes { checksum($0) } }
}

// MARK: - Little-endian reads

extension UnsafeRawBufferPointer {
    func leU16(_ o: Int) -> UInt16 { UInt16(self[o]) | UInt16(self[o + 1]) << 8 }
    func leU32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | UInt32(self[o + 1]) << 8 | UInt32(self[o + 2]) << 16 | UInt32(self[o + 3]) << 24
    }
    func leF32(_ o: Int) -> Float { Float(bitPattern: leU32(o)) }
    func leF16(_ o: Int) -> Float { TideAtlas.halfToFloat(leU16(o)) }
}
