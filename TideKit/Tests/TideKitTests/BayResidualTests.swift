import XCTest
@testable import TideKit

/// The live non-tidal layer of the Bay model (`sfbay.residual`, docs/SFBAY.md).
final class BayResidualTests: XCTestCase {
    typealias M = TideMeshTests

    static let start = Date(timeIntervalSince1970: 1_793_000_000)
    static let step: TimeInterval = 3_600
    static let frames = 3

    /// Residual values, linear in node position (x, y) so barycentric
    /// interpolation is exact, and exactly representable as f16.
    static func values(_ f: Int, _ x: Double, _ y: Double) -> [Double] {
        [0.125 * Double(f) + 0.25 * x, 0.5 * y, -0.25 * Double(f), 0.25 * x + 0.125, 0.0625 * y]
    }

    static func syntheticData(frames: Int = frames, nodeCount: Int = M.unit.count, meshID: UInt32, version: UInt16 = 1, constantsID: UInt32 = 0) -> Data {
        var d = Data("TRES".utf8)
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        u16(version); u16(UInt16(frames)); u32(UInt32(nodeCount)); u32(meshID)
        f64(start.timeIntervalSince1970); f64(step); f64(start.timeIntervalSince1970 + 6 * 3_600)
        u32(constantsID); d.append(Data(count: 4))
        for f in 0..<frames {
            for p in M.unit {
                for v in values(f, p.x, p.y) + [0, 0, 0] { u16(M.half(Float(v))) }
            }
        }
        return d
    }

    func mesh() throws -> TideMesh { try TideMesh(data: M.syntheticData()) }

    func testParsesHeaderAndFrames() throws {
        let mesh = try mesh()
        let r = try BayResidual(data: Self.syntheticData(meshID: mesh.meshID), mesh: mesh)
        XCTAssertEqual(r.frameCount, 3)
        XCTAssertEqual(r.nodeCount, 5)
        XCTAssertEqual(r.meshID, mesh.meshID)
        XCTAssertEqual(r.start, Self.start)
        XCTAssertEqual(r.step, 3_600)
        XCTAssertEqual(r.end, Self.start + 2 * 3_600)
        XCTAssertEqual(r.cycle, Self.start + 6 * 3_600)
        XCTAssertEqual(r.rawFrames().count, 3 * 5 * 16)
        XCTAssertEqual(r.rawFrames(), Self.syntheticData(meshID: mesh.meshID).dropFirst(48))
        let s = r.sample(node: 1, frame: 2) // x = 1, y = 0
        XCTAssertEqual(s, BayResidual.Sample(zeta: 0.5, depthMean: (0, -0.5), surface: (0.375, 0)))
    }

    func testRejectsMismatchedAndBrokenFiles() throws {
        let mesh = try mesh()
        func error(_ d: Data) -> BayResidual.LoadError? {
            do { _ = try BayResidual(data: d, mesh: mesh); return nil } catch { return error as? BayResidual.LoadError }
        }
        XCTAssertEqual(error(Self.syntheticData(meshID: mesh.meshID &+ 1)),
                       .meshMismatch(expected: mesh.meshID, found: mesh.meshID &+ 1))
        XCTAssertEqual(error(Self.syntheticData(nodeCount: 6, meshID: mesh.meshID)),
                       .nodeCountMismatch(expected: 5, found: 6))
        XCTAssertEqual(error(Self.syntheticData(meshID: mesh.meshID, version: 2)), .unsupportedVersion(2))
        XCTAssertEqual(error(Self.syntheticData(frames: 0, meshID: mesh.meshID)), .badTiming)
        XCTAssertEqual(error(Self.syntheticData(meshID: mesh.meshID).dropLast(1)), .truncated)
        XCTAssertEqual(error(Data(count: 10)), .truncated)
        var bad = Self.syntheticData(meshID: mesh.meshID)
        bad[0] = 0x58
        XCTAssertEqual(error(bad), .badHeader)
        // Works from a non-zero-based slice too.
        let padded = Data([1, 2, 3]) + Self.syntheticData(meshID: mesh.meshID)
        XCTAssertNoThrow(try BayResidual(data: padded.dropFirst(3), mesh: mesh))
    }

    func testFrameIndex() throws {
        let mesh = try mesh()
        let r = try BayResidual(data: Self.syntheticData(meshID: mesh.meshID), mesh: mesh)
        XCTAssertNil(r.frameIndex(at: Self.start - 1))
        XCTAssertNil(r.frameIndex(at: r.end + 1))
        XCTAssertTrue(r.frameIndex(at: Self.start)! == (0, 1, 0))
        XCTAssertTrue(r.frameIndex(at: Self.start + 900)! == (0, 1, 0.25))
        XCTAssertTrue(r.frameIndex(at: Self.start + 5_400)! == (1, 2, 0.5))
        XCTAssertTrue(r.frameIndex(at: r.end)! == (2, 2, 0))
    }

    func testInterpolatesInTimeAndSpace() throws {
        let mesh = try mesh()
        let r = try BayResidual(data: Self.syntheticData(meshID: mesh.meshID), mesh: mesh)
        let t = Self.start + 5_400 // frame 1.5
        let n = try XCTUnwrap(r.sample(node: 2, at: t)) // x = 1, y = 1
        XCTAssertEqual(n.zeta, 0.125 * 1.5 + 0.25, accuracy: 1e-12)
        XCTAssertEqual(n.depthMean.north, -0.375, accuracy: 1e-12)
        XCTAssertNil(r.sample(node: 2, at: r.end + 60))

        for (x, y) in [(0.3, 0.6), (0.9, 0.2), (0.5, 0.5), (0.01, 0.99)] {
            let lat = M.lat0 + M.size * y, lon = M.lon0 + M.size * x
            let s = try XCTUnwrap(r.sample(in: mesh, latitude: lat, longitude: lon, at: t))
            let lo = Self.values(1, x, y), hi = Self.values(2, x, y)
            let want = zip(lo, hi).map { 0.5 * ($0 + $1) }
            let got = [s.zeta, s.depthMean.east, s.depthMean.north, s.surface.east, s.surface.north]
            for (g, w) in zip(got, want) { XCTAssertEqual(g, w, accuracy: 1e-6) }

            // Totals: harmonic prediction + residual inside the frames, harmonic alone outside.
            let tide = try XCTUnwrap(mesh.waterLevel(latitude: lat, longitude: lon, at: t))
            XCTAssertEqual(try XCTUnwrap(r.waterLevel(in: mesh, latitude: lat, longitude: lon, at: t)), tide + want[0], accuracy: 1e-6)
            let later = r.end + 3_600
            XCTAssertEqual(r.waterLevel(in: mesh, latitude: lat, longitude: lon, at: later),
                           mesh.waterLevel(latitude: lat, longitude: lon, at: later))
            let c = try XCTUnwrap(mesh.current(latitude: lat, longitude: lon, at: t, surface: true))
            let total = try XCTUnwrap(r.current(in: mesh, latitude: lat, longitude: lon, at: t, surface: true))
            XCTAssertEqual(total.east, c.east + want[3], accuracy: 1e-6)
            XCTAssertEqual(total.north, c.north + want[4], accuracy: 1e-6)
        }
        XCTAssertNil(r.sample(in: mesh, latitude: M.lat0 - 0.5, longitude: M.lon0, at: t))
        XCTAssertNil(r.waterLevel(in: mesh, latitude: M.lat0 - 0.5, longitude: M.lon0, at: t))
    }

    /// A mesh that records its constants ID only accepts residuals computed
    /// against those constants; older meshes (ID 0) accept any.
    func testConstantsIDGuardsAgainstRefittedModels() throws {
        let stamped = try TideMesh(data: TideMeshTests.stamped(M.syntheticData()))
        XCTAssertNotEqual(stamped.constantsID, 0)
        let id = stamped.constantsID
        XCTAssertNoThrow(try BayResidual(data: Self.syntheticData(meshID: stamped.meshID, constantsID: id), mesh: stamped))
        func error(_ d: Data) -> BayResidual.LoadError? {
            do { _ = try BayResidual(data: d, mesh: stamped); return nil } catch { return error as? BayResidual.LoadError }
        }
        XCTAssertEqual(error(Self.syntheticData(meshID: stamped.meshID, constantsID: id &+ 1)), .constantsMismatch(expected: id, found: id &+ 1))
        XCTAssertEqual(error(Self.syntheticData(meshID: stamped.meshID)), .constantsMismatch(expected: id, found: 0))
        // An unstamped (older) mesh takes residuals with or without the ID.
        let old = try mesh()
        XCTAssertEqual(old.constantsID, 0)
        XCTAssertNoThrow(try BayResidual(data: Self.syntheticData(meshID: old.meshID, constantsID: 1234), mesh: old))
    }
}
