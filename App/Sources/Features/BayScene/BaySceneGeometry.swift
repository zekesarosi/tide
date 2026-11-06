import CoreGraphics
import Foundation
import simd
import TideKit

/// Local metres around the bay: an equirectangular projection about a
/// centre, good to a few metres over the model's 45 km.
struct BayProjection: Sendable, Equatable {
    let longitude0: Double
    let latitude0: Double
    let metresPerDegreeLongitude: Double
    let metresPerDegreeLatitude: Double

    init(longitude0: Double, latitude0: Double) {
        self.longitude0 = longitude0
        self.latitude0 = latitude0
        let p = latitude0 * .pi / 180
        metresPerDegreeLatitude = 111_132.954 - 559.822 * cos(2 * p) + 1.175 * cos(4 * p)
        metresPerDegreeLongitude = 111_412.84 * cos(p) - 93.5 * cos(3 * p)
    }

    func point(latitude: Double, longitude: Double) -> SIMD2<Double> {
        SIMD2((longitude - longitude0) * metresPerDegreeLongitude, (latitude - latitude0) * metresPerDegreeLatitude)
    }

    func coordinate(_ p: SIMD2<Double>) -> (latitude: Double, longitude: Double) {
        (latitude0 + p.y / metresPerDegreeLatitude, longitude0 + p.x / metresPerDegreeLongitude)
    }
}

/// Everything about the mesh the GPU needs that doesn't change with time,
/// built once off the main thread.
struct BaySceneGeometry: Sendable {
    /// One vertex of a wall along the mesh boundary. Mirrors `WallVertex`.
    struct WallVertex: Sendable {
        /// x, y (m), node index, level (0 seafloor, 1 land top, 2 water surface, 3 base).
        var a: SIMD4<Float>
        /// Normal xy (towards the water), kind (0 earth, 1 water), unused.
        var n: SIMD4<Float>
    }

    let projection: BayProjection
    /// Per node: x, y (m), depth (m, positive down), 0.
    let nodes: [SIMD4<Float>]
    /// Per node: gradient of depth (m/m), for seafloor shading.
    let gradients: [SIMD2<Float>]
    let triangles: [UInt32]
    /// Banks: seafloor up to the land.
    let solidWalls: [WallVertex]
    /// Where the model's box cuts open water: the water in cross-section.
    let waterWalls: [WallVertex]
    /// Node bounding box (m).
    let bounds: CGRect
    let maxDepth: Float

    init(mesh: TideMesh) {
        let b = mesh.bounds
        let proj = BayProjection(longitude0: (b.minLongitude + b.maxLongitude) / 2, latitude0: (b.minLatitude + b.maxLatitude) / 2)
        projection = proj
        let n = mesh.nodeCount
        var nodes = [SIMD4<Float>](repeating: .zero, count: n)
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var deepest: Float = 0
        for i in 0..<n {
            let p = proj.point(latitude: Double(mesh.latitudes[i]), longitude: Double(mesh.longitudes[i]))
            nodes[i] = SIMD4(Float(p.x), Float(p.y), mesh.depths[i], 0)
            minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
            deepest = max(deepest, mesh.depths[i])
        }
        self.nodes = nodes
        maxDepth = deepest
        bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        triangles = mesh.triangles

        // Area-weighted gradient of the (linear) depth on each triangle.
        var grad = [SIMD2<Double>](repeating: .zero, count: n)
        var area = [Double](repeating: 0, count: n)
        let tri = mesh.triangles
        for t in 0..<mesh.triangleCount {
            let i0 = Int(tri[3 * t]), i1 = Int(tri[3 * t + 1]), i2 = Int(tri[3 * t + 2])
            let p0 = SIMD3<Double>(Double(nodes[i0].x), Double(nodes[i0].y), Double(nodes[i0].z))
            let p1 = SIMD3<Double>(Double(nodes[i1].x), Double(nodes[i1].y), Double(nodes[i1].z))
            let p2 = SIMD3<Double>(Double(nodes[i2].x), Double(nodes[i2].y), Double(nodes[i2].z))
            let e1 = p1 - p0, e2 = p2 - p0
            let det = e1.x * e2.y - e2.x * e1.y
            guard abs(det) > 1e-6 else { continue }
            let gx = (e1.z * e2.y - e2.z * e1.y) / det
            let gy = (e2.z * e1.x - e1.z * e2.x) / det
            let a = abs(det) / 2
            for i in [i0, i1, i2] { grad[i] += SIMD2(gx, gy) * a; area[i] += a }
        }
        gradients = (0..<n).map { area[$0] > 0 ? SIMD2<Float>(grad[$0] / area[$0]) : .zero }

        // Walls. Boundary edges run in their triangle's winding, so the water is on the left.
        var solid: [WallVertex] = [], water: [WallVertex] = []
        solid.reserveCapacity(mesh.boundaryEdges.count * 6)
        func nearBox(_ p: SIMD4<Float>, _ tol: Double) -> Bool {
            let x = Double(p.x), y = Double(p.y)
            return x - minX < tol || maxX - x < tol || y - minY < tol || maxY - y < tol
        }
        for (ua, ub) in mesh.boundaryEdges {
            let a = nodes[Int(ua)], b = nodes[Int(ub)]
            let d = SIMD2<Float>(b.x - a.x, b.y - a.y)
            let len = simd_length(d)
            guard len > 0 else { continue }
            let nrm = SIMD2<Float>(-d.y, d.x) / len
            let tol = max(Double(len) * 1.6, 250)
            let open = nearBox(a, tol) && nearBox(b, tol)
            func quad(_ lo: Float, _ hi: Float, kind: Float, into list: inout [WallVertex]) {
                func v(_ p: SIMD4<Float>, _ i: UInt32, _ level: Float) -> WallVertex {
                    WallVertex(a: SIMD4(p.x, p.y, Float(i), level), n: SIMD4(nrm.x, nrm.y, kind, 0))
                }
                list += [v(a, ua, lo), v(b, ub, lo), v(b, ub, hi), v(a, ua, lo), v(b, ub, hi), v(a, ua, hi)]
            }
            // Where the box cuts open water the model fades into the base map instead.
            if !open { quad(0, 1, kind: 0, into: &solid) }
        }
        solidWalls = solid
        waterWalls = water
    }
}

/// Named places, drawn as labels over the scene.
struct BayPlace: Sendable, Identifiable {
    enum Kind: Sendable { case water, land }
    let id: String
    let latitude: Double
    let longitude: Double
    let kind: Kind
    /// Shown from this far out (camera distance, m).
    let maxDistance: Double

    static let all: [BayPlace] = [
        BayPlace(id: "Golden Gate", latitude: 37.8199, longitude: -122.4783, kind: .water, maxDistance: 200_000),
        BayPlace(id: "Alcatraz", latitude: 37.8267, longitude: -122.4230, kind: .land, maxDistance: 60_000),
        BayPlace(id: "Angel Island", latitude: 37.8609, longitude: -122.4326, kind: .land, maxDistance: 80_000),
        BayPlace(id: "Sausalito", latitude: 37.8591, longitude: -122.4853, kind: .land, maxDistance: 80_000),
        BayPlace(id: "Richardson Bay", latitude: 37.8750, longitude: -122.4900, kind: .water, maxDistance: 60_000),
        BayPlace(id: "Raccoon Strait", latitude: 37.8690, longitude: -122.4470, kind: .water, maxDistance: 35_000),
        BayPlace(id: "Bay Bridge", latitude: 37.7983, longitude: -122.3778, kind: .water, maxDistance: 120_000),
        BayPlace(id: "Point Bonita", latitude: 37.8157, longitude: -122.5297, kind: .land, maxDistance: 80_000),
        BayPlace(id: "San Francisco", latitude: 37.7880, longitude: -122.4300, kind: .land, maxDistance: 200_000),
        BayPlace(id: "Pacific Ocean", latitude: 37.7800, longitude: -122.6400, kind: .water, maxDistance: 200_000),
    ]
}
