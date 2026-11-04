import QuartzCore
import UIKit

/// Calls `tick(dt)` every display frame until it returns false.
@MainActor
final class FrameDriver: NSObject {
    private var link: CADisplayLink?
    private var tick: ((Double) -> Bool)?
    private var last: CFTimeInterval?

    func run(_ tick: @escaping (Double) -> Bool) {
        stop()
        self.tick = tick
        let l = CADisplayLink(target: self, selector: #selector(step(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
        tick = nil
        last = nil
    }

    @objc private func step(_ l: CADisplayLink) {
        let dt = last.map { l.timestamp - $0 } ?? 1.0 / 60
        last = l.timestamp
        if tick?(Swift.min(Swift.max(dt, 1.0 / 240), 1.0 / 20)) != true { stop() }
    }
}
