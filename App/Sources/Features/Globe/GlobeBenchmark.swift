import Foundation
import QuartzCore

/// Scripted performance run for the Tide Globe, for tuning on a device.
/// Off unless the app is launched with `-GlobeBenchmark YES`, which opens the
/// globe, plays the phases below, prints a table to stdout and quits:
///
///     xcrun devicectl device process launch --console --terminate-existing \
///       --device <udid> <bundle id> -GlobeBenchmark YES [-GlobeMSAA 1] [-GlobeScale 2] [-GlobeFPS 30]
///
/// GPU time comes from the command buffers' own timestamps. CPU is the whole
/// process (getrusage), so it includes SwiftUI and the main thread.
@MainActor
final class GlobeBenchmark {
    static let isEnabled = UserDefaults.standard.bool(forKey: "GlobeBenchmark")

    struct Phase {
        let name: String
        let apply: (GlobeModel, inout OrbitCamera) -> Void
        /// Per-frame camera motion (degrees of longitude per second), to stand in for a drag.
        var spin: Double = 0
    }

    static let phases: [Phase] = [
        Phase(name: "idle: paused, still") { m, c in m.playing = false; m.selection = nil; c.distance = 3.4 },
        Phase(name: "play 3 h/s") { m, _ in m.playing = true; m.rate = 10_800 },
        Phase(name: "play + spin", apply: { _, _ in }, spin: 30),
        Phase(name: "M2 + play + spin", apply: { m, _ in m.selection = "M2" }, spin: 30),
        Phase(name: "zoomed in (1.6) + play") { m, c in m.selection = nil; c.distance = 1.6 },
        Phase(name: "relief off + play") { m, c in m.relief = false; c.distance = 3.4 },
        Phase(name: "probe card + play") { m, _ in
            m.relief = true
            m.makeProbe(latitude: 35, longitude: -137, stations: [])
        },
    ]

    static let phaseLength: CFTimeInterval = 9
    static let warmup: CFTimeInterval = 2

    private var start: CFTimeInterval?
    private var index = -1
    private var phaseStart: CFTimeInterval = 0
    private var frames = 0
    private var cpuEncode: [Double] = []
    private var gpu: [Double] = []
    private var wait: [Double] = []
    private var rusageStart: Double = 0
    private var rows: [String] = []
    private var finished = false
    let config: String

    init(config: String) { self.config = config }

    /// Call at the top of every draw; applies the current phase.
    func step(model: GlobeModel, camera: inout OrbitCamera, now: CFTimeInterval, dt: Double) {
        guard !finished else { return }
        if start == nil { start = now }
        let elapsed = now - start!
        let i = Int(elapsed / Self.phaseLength)
        if i != index {
            if index >= 0 { finishPhase(now: now) }
            guard i < Self.phases.count else { finish(); return }
            index = i
            phaseStart = now
            Self.phases[i].apply(model, &camera)
            resetCounters()
        }
        if !rusageTaken, now >= measureFrom {
            rusageStart = Self.processCPUSeconds()
            rusageTaken = true
        }
        camera.longitude += Self.phases[i].spin * dt
        if camera.longitude > 180 { camera.longitude -= 360 }
    }

    private func resetCounters() {
        frames = 0; cpuEncode = []; gpu = []; wait = []
        rusageTaken = false
        measureFrom = phaseStart + Self.warmup
    }

    private var measureFrom: CFTimeInterval = 0
    private var rusageTaken = false

    /// A frame was encoded and committed.
    func recordFrame(encodeSeconds: Double, waitSeconds: Double) {
        guard CACurrentMediaTime() >= measureFrom else { return }
        frames += 1
        cpuEncode.append(encodeSeconds * 1_000)
        wait.append(waitSeconds * 1_000)
    }

    func recordGPU(seconds: Double) {
        guard CACurrentMediaTime() >= measureFrom, seconds > 0 else { return }
        gpu.append(seconds * 1_000)
    }

    private func finishPhase(now: CFTimeInterval) {
        let span = now - measureFrom
        let cpu = (Self.processCPUSeconds() - rusageStart) / max(span, 0.001) * 100
        func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        func p95(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.sorted()[min(a.count - 1, Int(Double(a.count) * 0.95))] }
        let fps = Double(frames) / max(span, 0.001)
        let gpuBusy = avg(gpu) * fps / 10 // % of each second the GPU spends on us
        let thermal = ["nominal", "fair", "serious", "critical"][ProcessInfo.processInfo.thermalState.rawValue]
        rows.append(String(format: "%-26@ %5.1f  %6.2f %6.2f  %6.2f %6.2f  %5.1f%%  %5.0f%%  %@",
                           Self.phases[index].name as NSString, fps, avg(gpu), p95(gpu), avg(cpuEncode), avg(wait), gpuBusy, cpu, thermal as NSString))
    }

    private func finish() {
        finished = true
        var out = "\n=== Tide Globe benchmark · \(config) ===\n"
        out += String(format: "%-26@ %5@  %6@ %6@  %6@ %6@  %6@  %6@  %@\n", "phase" as NSString, "fps" as NSString, "gpu ms" as NSString, "p95" as NSString,
                      "enc ms" as NSString, "wait" as NSString, "gpu %" as NSString, "cpu %" as NSString, "thermal" as NSString)
        out += rows.joined(separator: "\n") + "\n=== end ===\n"
        print(out)
        fflush(stdout)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    static func processCPUSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return s(u.ru_utime) + s(u.ru_stime)
    }
}
