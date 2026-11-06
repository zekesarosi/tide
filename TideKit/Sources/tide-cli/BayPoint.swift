import Foundation
import TideKit

/// `tide-cli bay-point <lat> <lon> [hours]`
///
/// Predicts the tide and depth-mean current at a point in San Francisco Bay
/// from the on-device mesh model. Reads `$TIDEMESH`, or
/// `App/Resources/Bay/sfbay.tidemesh` relative to the working directory.
func runBayPoint(_ args: [String]) {
    guard args.count == 2 || args.count == 3,
          let lat = Double(args[0]), let lon = Double(args[1]) else {
        print("usage: tide-cli bay-point <lat> <lon> [hours]")
        exit(2)
    }
    let hours = args.count == 3 ? max(1, Int(args[2]) ?? 24) : 24
    let path = ProcessInfo.processInfo.environment["TIDEMESH"] ?? "App/Resources/Bay/sfbay.tidemesh"
    let mesh: TideMesh
    do {
        mesh = try TideMesh(data: Data(contentsOf: URL(fileURLWithPath: path)))
    } catch {
        print("can't load \(path): \(error)"); exit(1)
    }
    print("\(path): " + String(format: "%d nodes, %d triangles, %d constituents, meshID %08x",
                                mesh.nodeCount, mesh.triangleCount, mesh.constituents.count, mesh.meshID))
    guard let (triangle, w) = mesh.locate(latitude: lat, longitude: lon),
          let predictor = mesh.waterLevelPredictor(latitude: lat, longitude: lon) else {
        print(String(format: "%.5f, %.5f is outside the mesh", lat, lon)); exit(1)
    }
    let (a, b, c) = mesh.nodes(ofTriangle: triangle)
    let depth = w.x * Double(mesh.depths[a]) + w.y * Double(mesh.depths[b]) + w.z * Double(mesh.depths[c])
    print(String(format: "Point %.5f, %.5f: triangle %d, depth %.1f m. Water level relative to model mean; current depth-mean.",
                 lat, lon, triangle, depth))

    let zone = TimeZone(identifier: "America/Los_Angeles")!
    let fmt = DateFormatter()
    fmt.timeZone = zone
    fmt.dateFormat = "EEE MMM d HH:mm zzz"

    func pad(_ s: String) -> String { s.padding(toLength: 26, withPad: " ", startingAt: 0) }
    let now = Date()
    let start = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 3_600).rounded(.down) * 3_600)
    print("\nTime                        Level m   Speed kn   Speed m/s   Dir °T")
    for h in 0...hours {
        let t = start + Double(h) * 3_600
        let level = mesh.waterLevel(triangle: triangle, weights: w, at: t)
        let flow = mesh.current(triangle: triangle, weights: w, at: t, surface: false)
        let speed = hypot(flow.east, flow.north)
        var dir = atan2(flow.east, flow.north) * 180 / .pi
        if dir < 0 { dir += 360 }
        print(pad(fmt.string(from: t)) + String(format: " %8.2f   %8.2f   %9.2f   %6.0f",
                                                level, speed / 0.514_444, speed, dir))
    }

    print("\nHighs and lows")
    for e in predictor.extrema(from: now, to: now + Double(max(hours, 24)) * 3_600) {
        print(pad(fmt.string(from: e.date)) + (e.kind == .high ? " High " : " Low  ") + String(format: "%6.2f m", e.height))
    }
}
