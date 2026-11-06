import Foundation
import QuartzCore

/// Scripted performance run for the 3D bay, for tuning on a device. Off
/// unless the app is launched with `-BayBenchmark YES`, which opens the
/// scene, plays the phases below, prints a table to stdout and quits:
///
///     xcrun devicectl device process launch --console --terminate-existing \
///       --device <udid> <bundle id> -BayBenchmark YES [-BayMSAA 1] [-BayFPS 30]
///
/// GPU time comes from the command buffers' own timestamps; CPU is the whole
/// process (getrusage), so it includes SwiftUI and the main thread.
@MainActor
final class BaySceneBenchmark {
    static let isEnabled = UserDefaults.standard.bool(forKey: "BayBenchmark")

    struct Phase {
        let name: String
        let apply: (BaySceneModel, inout BayCamera, BaySceneGeometry) -> Void
        /// Heading change per second (radians), to stand in for a rotate gesture.
        var spin: Double = 0
    }

    static let phases: [Phase] = [
        Phase(name: "idle: paused, no flow") { m, _, _ in m.playing = false; m.showsFlow = false },
        Phase(name: "flow, paused") { m, _, _ in m.showsFlow = true },
        Phase(name: "flow + play 1 h/s") { m, _, _ in m.playing = true; m.rate = 3_600 },
        Phase(name: "flow + play + rotate", apply: { _, _, _ in }, spin: 0.4),
        Phase(name: "close (900 m) + play") { _, c, g in
            c.target = g.projection.point(latitude: 37.8199, longitude: -122.4783); c.distance = 900
        },
        Phase(name: "whole bay, speed colour") { m, c, _ in m.colourMode = .speed; c.distance = 70_000; c.pitch = 0.3 },
        Phase(name: "probe card + play") { m, c, g in
            m.colourMode = .level
            c.distance = 30_000; c.pitch = 0.6
            m.makeProbe(at: g.projection.point(latitude: 37.8199, longitude: -122.4783))
        },
    ]

    static let phaseLength: CFTimeInterval = 8
    static let warmup: CFTimeInterval = 2

    private var start: CFTimeInterval?
    private var index = -1
    private var phaseStart: CFTimeInterval = 0
    private var frames = 0
    private var cpuEncode: [Double] = []
    private var gpu: [Double] = []
    private var rusageStart: Double = 0
    private var rusageTaken = false
    private var measureFrom: CFTimeInterval = 0
    private var rows: [String] = []
    private var finished = false
    let config: String

    init(config: String) { self.config = config }

    func step(model: BaySceneModel, camera: inout BayCamera, now: CFTimeInterval, dt: Double, geometry: BaySceneGeometry) {
        guard !finished else { return }
        if start == nil { start = now }
        let i = Int((now - start!) / Self.phaseLength)
        if i != index {
            if index >= 0 { finishPhase(now: now) }
            guard i < Self.phases.count else { finish(); return }
            index = i
            phaseStart = now
            Self.phases[i].apply(model, &camera, geometry)
            frames = 0; cpuEncode = []; gpu = []
            rusageTaken = false
            measureFrom = now + Self.warmup
        }
        if !rusageTaken, now >= measureFrom {
            rusageStart = GlobeBenchmark.processCPUSeconds()
            rusageTaken = true
        }
        camera.heading += Self.phases[i].spin * dt
    }

    func recordFrame(encodeSeconds: Double, waitSeconds: Double) {
        guard CACurrentMediaTime() >= measureFrom else { return }
        frames += 1
        cpuEncode.append(encodeSeconds * 1_000)
    }

    func recordGPU(seconds: Double) {
        guard CACurrentMediaTime() >= measureFrom, seconds > 0 else { return }
        gpu.append(seconds * 1_000)
    }

    private func finishPhase(now: CFTimeInterval) {
        let span = now - measureFrom
        let cpu = (GlobeBenchmark.processCPUSeconds() - rusageStart) / max(span, 0.001) * 100
        func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        func p95(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[min(a.count - 1, Int(Double(a.count) * 0.95))] }
        let fps = Double(frames) / max(span, 0.001)
        rows.append(Self.phases[index].name.padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: " %5.1f  %6.2f %6.2f  %6.2f  %5.0f%%",
                           fps, avg(gpu), p95(gpu), avg(cpuEncode), cpu))
    }

    private func finish() {
        finished = true
        var out = "\n=== Bay scene benchmark · \(config) ===\n"
        out += "phase".padding(toLength: 28, withPad: " ", startingAt: 0) + String(format: " %5@  %6@ %6@  %6@  %6@\n", "fps" as NSString, "gpu ms" as NSString,
                      "p95" as NSString, "enc ms" as NSString, "cpu %" as NSString)
        out += rows.joined(separator: "\n") + "\n=== end ===\n"
        print(out)
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
}
