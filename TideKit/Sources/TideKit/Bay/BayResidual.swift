import Foundation

/// The live, non-tidal part of the San Francisco Bay model: surge, wind and
/// river flow, as SFBOFS's latest forecast minus the `TideMesh` harmonic
/// prediction, hourly per mesh node (docs/SFBAY.md, `sfbay.residual`).
///
/// Built by `scripts/sfbay/live_residual.py` and published by
/// `.github/workflows/sfbay-live.yml`. Total water and flow are the harmonic
/// prediction plus this residual, linearly interpolated in time; outside the
/// frames the harmonic prediction stands alone.
public struct BayResidual: Sendable {
    public enum LoadError: Error, Equatable {
        case badHeader
        case unsupportedVersion(Int)
        case truncated
        case badTiming
        /// The file was made for a different mesh than the one in the app.
        case nodeCountMismatch(expected: Int, found: Int)
        case meshMismatch(expected: UInt32, found: UInt32)
        /// The file was computed against different harmonic constants than
        /// the app's (e.g. an app update shipped a refitted model), so
        /// adding it to the app's tide would be wrong.
        case constantsMismatch(expected: UInt32, found: UInt32)
    }

    /// One node's (or point's) residual at an instant.
    public struct Sample: Sendable, Equatable {
        /// Water level residual, m.
        public var zeta: Double
        /// Depth-mean current residual, m/s (east, north).
        public var depthMean: (east: Double, north: Double)
        /// Surface current residual, m/s (east, north).
        public var surface: (east: Double, north: Double)

        public init(zeta: Double, depthMean: (east: Double, north: Double), surface: (east: Double, north: Double)) {
            self.zeta = zeta
            self.depthMean = depthMean
            self.surface = surface
        }

        public static let zero = Sample(zeta: 0, depthMean: (0, 0), surface: (0, 0))

        public static func == (a: Sample, b: Sample) -> Bool {
            a.zeta == b.zeta && a.depthMean == b.depthMean && a.surface == b.surface
        }
    }

    static let magic: [UInt8] = [0x54, 0x52, 0x45, 0x53] // "TRES"
    static let headerSize = 48
    /// Bytes per node per frame: 8 × f16.
    public static let bytesPerNode = 16

    public let start: Date
    public let step: TimeInterval
    public let frameCount: Int
    /// The SFBOFS cycle the forecast came from.
    public let cycle: Date
    public let nodeCount: Int
    public let meshID: UInt32
    /// The `TideMesh.constantsID` it was computed against (0 if not recorded).
    public let constantsID: UInt32
    /// F × N × 16 bytes, exactly as stored.
    private let frames: Data

    /// Valid time of the last frame.
    public var end: Date { start + step * Double(frameCount - 1) }

    /// Parses decompressed `sfbay.residual` bytes and checks they belong to `mesh`.
    public init(data: Data, mesh: TideMesh) throws {
        try self.init(data: data, nodeCount: mesh.nodeCount, meshID: mesh.meshID, constantsID: mesh.constantsID)
    }

    /// Parses decompressed bytes against an expected node count, mesh ID and,
    /// when the mesh records one (non-zero), constants ID: then the residual
    /// must carry the same ID, so one without it is rejected too.
    public init(data: Data, nodeCount expectedNodes: Int, meshID expectedID: UInt32, constantsID expectedConstants: UInt32 = 0) throws {
        let header = Data(data.prefix(Self.headerSize))
        guard header.count == Self.headerSize else { throw LoadError.truncated }
        let h = try header.withUnsafeBytes { raw -> (f: Int, n: Int, id: UInt32, start: Double, step: Double, cycle: Double, constants: UInt32) in
            guard Array(raw[0..<4]) == Self.magic else { throw LoadError.badHeader }
            let version = Int(raw.leU16(4))
            guard version == 1 else { throw LoadError.unsupportedVersion(version) }
            func f64(_ o: Int) -> Double { Double(bitPattern: UInt64(raw.leU32(o)) | UInt64(raw.leU32(o + 4)) << 32) }
            return (Int(raw.leU16(6)), Int(raw.leU32(8)), raw.leU32(12), f64(16), f64(24), f64(32), raw.leU32(40))
        }
        let (f, n, id) = (h.f, h.n, h.id)
        guard n == expectedNodes else { throw LoadError.nodeCountMismatch(expected: expectedNodes, found: n) }
        guard id == expectedID else { throw LoadError.meshMismatch(expected: expectedID, found: id) }
        if expectedConstants != 0, h.constants != expectedConstants {
            throw LoadError.constantsMismatch(expected: expectedConstants, found: h.constants)
        }
        let (start, step, cycle) = (h.start, h.step, h.cycle)
        guard f > 0, start.isFinite, cycle.isFinite, step.isFinite, step > 0 else { throw LoadError.badTiming }
        let size = f * n * Self.bytesPerNode
        guard data.count >= Self.headerSize + size else { throw LoadError.truncated }
        let from = data.startIndex + Self.headerSize
        frames = data.subdata(in: from..<from + size)
        frameCount = f
        nodeCount = n
        meshID = id
        constantsID = h.constants
        self.start = Date(timeIntervalSince1970: start)
        self.step = step
        self.cycle = Date(timeIntervalSince1970: cycle)
    }

    /// F × N × 16 bytes ({zeta, depth-mean u, v, surface u, v, 0, 0, 0} as f16), for GPU upload.
    public func rawFrames() -> Data { frames }

    /// The two frames bracketing `date` and the blend weight of the upper one
    /// (value = lower·(1 − t) + upper·t). Nil outside [start, end].
    public func frameIndex(at date: Date) -> (lower: Int, upper: Int, t: Double)? {
        let x = date.timeIntervalSince(start) / step
        guard x >= 0, x <= Double(frameCount - 1) else { return nil }
        let lower = min(Int(x), frameCount - 1)
        let upper = min(lower + 1, frameCount - 1)
        return (lower, upper, upper == lower ? 0 : x - Double(lower))
    }

    /// The stored values of one node in one frame.
    public func sample(node: Int, frame: Int) -> Sample {
        precondition(node >= 0 && node < nodeCount && frame >= 0 && frame < frameCount)
        let base = (frame * nodeCount + node) * Self.bytesPerNode
        return frames.withUnsafeBytes { raw -> Sample in
            func h(_ k: Int) -> Double { Double(raw.leF16(base + 2 * k)) }
            return Sample(zeta: h(0), depthMean: (h(1), h(2)), surface: (h(3), h(4)))
        }
    }

    /// One node's residual at `date`, linearly interpolated; nil outside the frames.
    public func sample(node: Int, at date: Date) -> Sample? {
        guard let (lo, hi, t) = frameIndex(at: date) else { return nil }
        let a = sample(node: node, frame: lo)
        if t == 0 { return a }
        return Self.mix(a, sample(node: node, frame: hi), t)
    }

    /// The residual at a point: barycentric in space (via `mesh.locate`), linear in time.
    /// Nil outside the mesh or the frames.
    public func sample(in mesh: TideMesh, latitude: Double, longitude: Double, at date: Date) -> Sample? {
        guard mesh.nodeCount == nodeCount, mesh.meshID == meshID,
              let (lo, hi, t) = frameIndex(at: date),
              let (tri, w) = mesh.locate(latitude: latitude, longitude: longitude) else { return nil }
        let corners = mesh.nodes(ofTriangle: tri)
        let nodes = [corners.0, corners.1, corners.2]
        func at(_ frame: Int) -> Sample {
            var s = Sample.zero
            for (k, node) in nodes.enumerated() {
                s = Self.add(s, sample(node: node, frame: frame), w[k])
            }
            return s
        }
        let a = at(lo)
        return t == 0 ? a : Self.mix(a, at(hi), t)
    }

    /// Total water level (m, η − Z0): harmonic prediction plus the residual
    /// where the frames cover `date`. Nil outside the mesh.
    public func waterLevel(in mesh: TideMesh, latitude: Double, longitude: Double, at date: Date) -> Double? {
        guard let tide = mesh.waterLevel(latitude: latitude, longitude: longitude, at: date) else { return nil }
        return tide + (sample(in: mesh, latitude: latitude, longitude: longitude, at: date)?.zeta ?? 0)
    }

    /// Total current (m/s): harmonic prediction (incl. mean flow) plus the
    /// residual where the frames cover `date`. Nil outside the mesh.
    public func current(in mesh: TideMesh, latitude: Double, longitude: Double, at date: Date, surface: Bool) -> (east: Double, north: Double)? {
        guard let tide = mesh.current(latitude: latitude, longitude: longitude, at: date, surface: surface) else { return nil }
        guard let r = sample(in: mesh, latitude: latitude, longitude: longitude, at: date) else { return tide }
        let d = surface ? r.surface : r.depthMean
        return (tide.east + d.east, tide.north + d.north)
    }

    static func add(_ a: Sample, _ b: Sample, _ w: Double) -> Sample {
        Sample(zeta: a.zeta + w * b.zeta,
               depthMean: (a.depthMean.east + w * b.depthMean.east, a.depthMean.north + w * b.depthMean.north),
               surface: (a.surface.east + w * b.surface.east, a.surface.north + w * b.surface.north))
    }

    static func mix(_ a: Sample, _ b: Sample, _ t: Double) -> Sample {
        add(add(.zero, a, 1 - t), b, t)
    }
}
