import Foundation
import Observation
import TideKit

/// Loads the San Francisco Bay analysis once and keeps it for the session
/// (it changes slowly: harmonics, plus two weeks of observations).
@MainActor
@Observable
final class BayModel {
    enum Phase: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var analysis: BayAnalysis?
    /// The animated tidal day, precomputed for every station.
    private(set) var day: BayDay?

    static let staleAfter: TimeInterval = 30 * 60

    func loadIfNeeded(service: ForecastService) async {
        if let a = analysis, Date().timeIntervalSince(a.generated) < Self.staleAfter { return }
        await load(service: service)
    }

    func load(service: ForecastService) async {
        if phase == .loading { return }
        phase = .loading
        do {
            let a = try await BayService(coops: service.coops).analyze()
            analysis = a
            day = BayDay(analysis: a)
            phase = .loaded
        } catch is CancellationError {
            phase = analysis == nil ? .idle : .loaded
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Mean high-water lag vs San Francisco, for the station screen's entry card.
    func highLag(code: String) -> TimeInterval? { analysis?.station(code: code)?.offsets?.high?.mean }
}

/// One tidal day (24 h 50 min, so the day's last high returns to where it
/// started) of predicted water level at every bay station on a 5-minute grid.
/// The animation and the propagation strip read from this, never the
/// harmonic engine, so a frame costs a few array lookups.
struct BayDay: Sendable {
    struct Row: Sendable, Identifiable {
        var id: String { station.code }
        let station: BayStation
        /// Heights above MLLW (or MSL), metres, one per `step`.
        let values: [Double]
        let low: Double
        let high: Double
        /// Predicted highs and lows within the day (plus a step either side).
        let extremes: [TideExtreme]
    }

    static let length: TimeInterval = 24 * 3_600 + 50 * 60
    static let step: TimeInterval = 300

    let start: Date
    let end: Date
    let rows: [Row]

    init(analysis: BayAnalysis, length: TimeInterval = BayDay.length) {
        // Start on the station clock's last 10-minute mark before now.
        let now = analysis.generated
        let s = Date(timeIntervalSince1970: (now.timeIntervalSince1970 / 600).rounded(.down) * 600)
        start = s
        end = s + length
        rows = analysis.stations.map { a in
            let curve = a.predictor.heights(from: s, to: s + length, interval: Self.step).values
            let ex = a.extremes.filter { $0.date >= s - Self.step && $0.date <= s + length + Self.step }
            return Row(station: a.station, values: curve, low: curve.min() ?? 0, high: curve.max() ?? 1, extremes: ex)
        }
    }

    func row(_ code: String) -> Row? { rows.first { $0.station.code == code } }

    func clamp(_ date: Date) -> Date { min(max(date, start), end) }
}

extension BayDay.Row {
    func value(at date: Date, start: Date) -> Double {
        guard !values.isEmpty else { return 0 }
        let x = date.timeIntervalSince(start) / BayDay.step
        let i = Int(x.rounded(.down))
        if i < 0 { return values[0] }
        if i >= values.count - 1 { return values[values.count - 1] }
        let w = x - Double(i)
        return values[i] + w * (values[i + 1] - values[i])
    }

    /// 0 at the day's lowest water, 1 at its highest.
    func fraction(at date: Date, start: Date) -> Double {
        let span = high - low
        guard span > 1e-6 else { return 0.5 }
        return min(1, max(0, (value(at: date, start: start) - low) / span))
    }

    func rising(at date: Date, start: Date) -> Bool {
        value(at: date + 120, start: start) >= value(at: date - 120, start: start)
    }

    /// The high or low within `tolerance` of `date`, if any: "high water now".
    func extreme(near date: Date, tolerance: TimeInterval = 12 * 60) -> TideExtreme? {
        extremes.first { abs($0.date.timeIntervalSince(date)) <= tolerance }
    }

    /// The next high or low after `date`.
    func nextExtreme(after date: Date) -> TideExtreme? { extremes.first { $0.date > date } }
}

/// The animation's clock, observed only by the views that draw the moment
/// (markers, the strip's cursor, the readout), so playing doesn't re-run the
/// whole screen's body each frame.
@MainActor
@Observable
final class BayClock {
    var time: Date
    var playing = false

    init(time: Date) { self.time = time }
}
