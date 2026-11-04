import Charts
import QuartzCore
import SwiftUI
import TideKit
import UIKit

/// The signature "tide line": full-bleed water level with the observed past,
/// the forecast and its 80 % range, the tide table, high/low labels and a
/// "now" dot. Drawn with `Canvas` so pinching, panning and scrubbing redraw
/// the exact curve every frame at any zoom, rather than stretching an image.
/// Swipe to move through time, pinch to zoom (6 h to 45 days), touch and hold
/// to read any moment.
struct TideLineChart: View {
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone

    enum Window: String, CaseIterable, Identifiable {
        case day = "Day", twoDays = "2 days", week = "Week", month = "Month"
        var id: String { rawValue }
    }

    /// What's on screen. Only the canvas, the row under it and the picker
    /// observe it, so a pan or pinch frame never re-runs this body.
    @State private var viewport: ChartViewport
    @State private var store = ChartDataStore()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(forecast: WaterLevelForecast, unit: LengthUnit, tz: TimeZone) {
        self.forecast = forecast
        self.unit = unit
        self.tz = tz
        _viewport = State(initialValue: ChartViewport(
            bounds: Self.domain(forecast), window: .day,
            start: Self.homeStart(.day, forecast: forecast, tz: tz).timeIntervalSince1970,
            length: Self.presetLength(.day)))
    }

    /// A high or low: the tide-table extreme paired with the forecast (or, in
    /// the past, observed) extreme it became.
    struct ExtremeLabel {
        let kind: TideExtremeKind
        let table: TideExtreme
        let actual: TideExtreme?
        let observed: Bool
        /// Where the marker sits: the actual extreme when there is one.
        var anchor: TideExtreme { actual ?? table }
        /// Below this surge (0.2 ft) the tide-table line would just repeat the forecast.
        static let minimumSurge = 0.2 * 0.3048
        /// Whether the tide-table line adds anything over the actual one.
        var showsTable: Bool {
            guard let actual else { return true }
            return abs(actual.height - table.height) >= Self.minimumSurge
        }
    }

    // MARK: Ranges

    /// Everything there is to move through: the observed past to the
    /// forecast horizon (months, with the long-range outlook), in seconds.
    static func domain(_ f: WaterLevelForecast) -> ClosedRange<Double> {
        let now = f.issued
        let start = [f.observed.first?.date, f.astronomical.first?.date].compactMap { $0 }.min() ?? now - 12 * 3_600
        let lo = Swift.min(start, now).timeIntervalSince1970
        return lo...Swift.max(f.horizon.timeIntervalSince1970, lo + 3_600)
    }

    static func presetLength(_ w: Window) -> TimeInterval {
        switch w {
        case .day: return 86_400
        case .twoDays: return 48 * 3_600
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }

    /// Zoom limits: a quarter day to about six weeks on screen.
    static let zoomRange: ClosedRange<TimeInterval> = (6 * 3_600)...(45 * 86_400)

    /// The preset closest to what's on screen: it sets tick spacing and
    /// whether high/low labels fit, and is what the picker highlights.
    static func tier(for length: TimeInterval) -> Window {
        switch length {
        case ..<(1.5 * 86_400): return .day
        case ..<(4 * 86_400): return .twoDays
        case ..<(14 * 86_400): return .week
        default: return .month
        }
    }

    /// Where each preset starts: today from midnight (late in the day,
    /// keeping the next few hours in view), longer ones from a little before now.
    static func homeStart(_ w: Window, forecast: WaterLevelForecast, tz: TimeZone) -> Date {
        let now = forecast.issued
        switch w {
        case .day:
            var c = Calendar.current
            c.timeZone = tz
            return Swift.max(c.startOfDay(for: now), now - 18 * 3_600)
        case .twoDays: return now - 6 * 3_600
        case .week: return now - 12 * 3_600
        case .month: return now - 24 * 3_600
        }
    }

    private func home(_ w: Window) -> Double { Self.homeStart(w, forecast: forecast, tz: tz).timeIntervalSince1970 }

    // MARK: Body

    var body: some View {
        let data = store.data(forecast: forecast, unit: unit, tz: tz)
        VStack(alignment: .leading, spacing: 10) {
            TideCanvas(data: data, viewport: viewport, forecast: forecast, unit: unit, tz: tz, reduceMotion: reduceMotion)
                .frame(height: 210)

            ChartFooter(data: data, viewport: viewport, forecast: forecast, unit: unit, tz: tz,
                        home: home, reduceMotion: reduceMotion)
                .padding(.horizontal, Theme.margin)
                .frame(minHeight: 18, alignment: .leading)

            RangePicker(viewport: viewport, home: home, reduceMotion: reduceMotion)
                .padding(.horizontal, Theme.margin)
        }
        .onChange(of: forecast.issued) {
            viewport.updateBounds(Self.domain(forecast), home: home(viewport.window))
        }
    }
}

// MARK: - Viewport

/// The visible time range (seconds since 1970) and the scrubbed moment.
/// Gestures and animations write it every frame; the views that draw it
/// observe it.
@MainActor
@Observable
final class ChartViewport {
    private(set) var start: Double
    private(set) var length: Double
    var selection: Double?

    @ObservationIgnored private(set) var bounds: ClosedRange<Double>
    /// The preset last picked (homes the Now button and new forecasts).
    @ObservationIgnored var window: TideLineChart.Window
    /// Set once the reader has moved the chart, so a refreshed forecast
    /// doesn't yank it back home.
    @ObservationIgnored private(set) var interacted = false
    @ObservationIgnored private let driver = FrameDriver()

    init(bounds: ClosedRange<Double>, window: TideLineChart.Window, start: Double, length: Double) {
        self.bounds = bounds
        self.window = window
        self.start = start
        self.length = length
        set(start: start, length: length)
    }

    var span: Double { bounds.upperBound - bounds.lowerBound }
    var lengthRange: ClosedRange<Double> {
        let lo = Swift.min(TideLineChart.zoomRange.lowerBound, span)
        return lo...Swift.max(lo, Swift.min(TideLineChart.zoomRange.upperBound, span))
    }
    var canPan: Bool { length < span - 60 }

    func clamped(start s: Double, length l: Double) -> (start: Double, length: Double) {
        let r = lengthRange
        let len = Swift.min(Swift.max(l, r.lowerBound), r.upperBound)
        let st = Swift.min(Swift.max(s, bounds.lowerBound), bounds.upperBound - len)
        return (st, len)
    }

    func set(start s: Double, length l: Double) {
        let c = clamped(start: s, length: l)
        if c.length != length { length = c.length }
        if c.start != start { start = c.start }
    }

    func beginInteraction() {
        driver.stop()
        interacted = true
    }

    /// Pinch: `scale` > 1 zooms in, keeping `anchorTime` under `fraction` of the width.
    func zoom(scale: Double, from baseLength: Double, anchorTime: Double, fraction: Double) {
        guard scale.isFinite, scale > 0 else { return }
        let r = lengthRange
        let len = Swift.min(Swift.max(baseLength / scale, r.lowerBound), r.upperBound)
        set(start: anchorTime - len * fraction, length: len)
    }

    /// Momentum after a pan: `velocity` in seconds of time per second,
    /// decaying like a scroll view.
    func fling(velocity: Double) {
        var v = velocity
        guard abs(v) > length * 0.05 else { return }
        driver.run { [weak self] dt in
            guard let self else { return false }
            let before = self.start
            self.set(start: self.start + v * dt, length: self.length)
            v *= pow(0.998, dt * 1_000)
            return self.start != before && abs(v) > self.length * 0.02
        }
    }

    /// Ease to a range (presets, Now, VoiceOver). Length moves in log space
    /// so zooming feels even.
    func animate(toStart s: Double, length l: Double, duration: Double) {
        driver.stop()
        let target = clamped(start: s, length: l)
        guard duration > 0 else { set(start: target.start, length: target.length); return }
        let s0 = start, l0 = length
        var t = 0.0
        driver.run { [weak self] dt in
            guard let self else { return false }
            t = Swift.min(t + dt, duration)
            let p = t / duration
            let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
            self.set(start: s0 + (target.start - s0) * e, length: l0 * pow(target.length / l0, e))
            return t < duration
        }
    }

    func updateBounds(_ b: ClosedRange<Double>, home: Double) {
        bounds = b
        set(start: interacted ? start : home, length: length)
    }
}

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

// MARK: - Data

/// One series in display units, sorted by time (seconds since 1970).
struct ChartLine {
    var t: [Double] = []
    var v: [Double] = []

    init() {}
    init(_ s: TimeSeries, _ unit: LengthUnit) {
        t = s.points.map { $0.date.timeIntervalSince1970 }
        v = s.points.map { unit.fromMeters($0.value) }
    }

    var isEmpty: Bool { t.isEmpty }

    /// First index with t ≥ x.
    func lowerIndex(_ x: Double) -> Int {
        var lo = 0, hi = t.count
        while lo < hi { let m = (lo + hi) / 2; if t[m] < x { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// First index with t > x.
    func upperIndex(_ x: Double) -> Int {
        var lo = 0, hi = t.count
        while lo < hi { let m = (lo + hi) / 2; if t[m] <= x { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// Indices covering [a, b] plus one point either side, so lines run off the edges.
    func covering(_ a: Double, _ b: Double) -> Range<Int> {
        Swift.max(lowerIndex(a) - 1, 0)..<Swift.min(upperIndex(b) + 1, t.count)
    }

    func value(at x: Double, maxGap: Double = 1_200) -> Double? {
        let i = lowerIndex(x)
        if i < t.count, t[i] == x { return v[i] }
        guard i > 0, i < t.count, t[i] - t[i - 1] <= maxGap else { return nil }
        let w = (x - t[i - 1]) / (t[i] - t[i - 1])
        return v[i - 1] + w * (v[i] - v[i - 1])
    }

    func prefix(before x: Double) -> ChartLine {
        var out = ChartLine()
        let n = lowerIndex(x)
        out.t = Array(t[..<n])
        out.v = Array(v[..<n])
        return out
    }

    static func + (a: ChartLine, b: ChartLine) -> ChartLine {
        var out = a
        out.t += b.t
        out.v += b.v
        return out
    }
}

/// The last `ChartData` built, so body passes reuse it. Plain class: storing
/// into it mustn't invalidate the view.
final class ChartDataStore {
    private struct Key: Equatable {
        let issued: Date, horizon: Date, observed: Int, total: Int, unit: LengthUnit, tz: TimeZone
    }
    private var key: Key?
    private var value: ChartData?

    func data(forecast f: WaterLevelForecast, unit: LengthUnit, tz: TimeZone) -> ChartData {
        let k = Key(issued: f.issued, horizon: f.horizon, observed: f.observed.points.count,
                    total: f.total.points.count, unit: unit, tz: tz)
        if k == key, let value { return value }
        let d = ChartData(forecast: f, unit: unit, tz: tz)
        key = k
        value = d
        return d
    }
}

/// Everything the canvas draws, prepared once per forecast and unit. Each
/// frame draws only the visible slice, thinned to about two points a pixel.
final class ChartData {
    struct Tag {
        struct Line { let text: String; let color: Color; let bold: Bool }
        let t: Double
        let high: Bool
        let v: Double
        let lines: [Line]
        let dot: Color
    }

    let unit: LengthUnit
    let tz: TimeZone
    let calendar: Calendar
    let bounds: ClosedRange<Double>
    let observed: ChartLine
    let forecast: ChartLine
    let lower: ChartLine
    let upper: ChartLine
    let table: ChartLine
    /// Observed until the forecast starts, then the forecast: the water fill.
    let water: ChartLine
    /// Where the drawn line switches from observed to forecast.
    let cut: Double
    let yLo: Double
    let yHi: Double
    let tags: [Tag]
    let now: Double
    let nowLevel: Double?
    let outlook: Double?
    private var tickLabels: [Double: String] = [:]

    static let axisHeight: CGFloat = 22

    init(forecast f: WaterLevelForecast, unit: LengthUnit, tz: TimeZone) {
        self.unit = unit
        self.tz = tz
        var c = Calendar.current
        c.timeZone = tz
        calendar = c
        bounds = TideLineChart.domain(f)
        observed = ChartLine(f.observed, unit)
        forecast = ChartLine(f.total, unit)
        lower = ChartLine(f.totalLower, unit)
        upper = ChartLine(f.totalUpper, unit)
        table = ChartLine(f.astronomical, unit)
        cut = f.total.first?.date.timeIntervalSince1970 ?? f.issued.timeIntervalSince1970
        water = observed.prefix(before: cut) + forecast
        now = f.issued.timeIntervalSince1970
        if let v = f.total.value(at: f.issued, maxGap: 3_600) {
            nowLevel = unit.fromMeters(v)
        } else if let o = f.observed.last, f.issued.timeIntervalSince(o.date) < 3_600 {
            nowLevel = unit.fromMeters(o.value)
        } else {
            nowLevel = nil
        }
        outlook = f.weatherHorizon.flatMap { $0 < f.horizon - 3_600 ? $0.timeIntervalSince1970 : nil }
        let all = water.v + table.v + lower.v + upper.v
        let lo = all.min() ?? 0, hi = all.max() ?? 1
        yLo = lo
        yHi = hi > lo ? hi : lo + 1
        tags = Self.makeTags(f, unit: unit, tz: tz)
    }

    // MARK: Tags

    /// Every tide-table high and low, matched with the forecast extreme (or
    /// the observed one, before now) within ±3 h.
    private static func makeTags(_ f: WaterLevelForecast, unit: LengthUnit, tz: TimeZone) -> [Tag] {
        let total = ChartLine(f.total, .meters), obs = ChartLine(f.observed, .meters)
        let window: Double = 3 * 3_600
        func pick(_ l: ChartLine, _ t: TideExtreme) -> TideExtreme? {
            let x = t.date.timeIntervalSince1970
            let i0 = l.lowerIndex(x - window), i1 = l.upperIndex(x + window)
            guard i1 - i0 >= 3 else { return nil }
            var best = i0
            for i in i0..<i1 where t.kind == .high ? l.v[i] > l.v[best] : l.v[i] < l.v[best] { best = i }
            // An extreme on the edge of the search window is just a slope, not a turn.
            guard best != i0, best != i1 - 1 else { return nil }
            return TideExtreme(date: Date(timeIntervalSince1970: l.t[best]), height: l.v[best], kind: t.kind)
        }
        func line(_ e: TideExtreme) -> String {
            let t = e.date.formatted(Date.FormatStyle(timeZone: tz).hour(.defaultDigits(amPM: .narrow)).minute())
            return "\(t) \(Fmt.length(e.height, unit))"
        }
        return f.astronomical.extrema().map { t in
            let label: TideLineChart.ExtremeLabel
            if let fc = pick(total, t) {
                label = .init(kind: t.kind, table: t, actual: fc, observed: false)
            } else {
                let o = t.date <= f.issued ? pick(obs, t) : nil
                label = .init(kind: t.kind, table: t, actual: o, observed: o != nil)
            }
            var lines: [Tag.Line] = []
            if let a = label.actual {
                lines.append(.init(text: line(a), color: label.observed ? Theme.harbor : Theme.swellText, bold: true))
            }
            if label.showsTable { lines.append(.init(text: line(label.table), color: Theme.inkSecondary, bold: false)) }
            let dot = label.actual == nil ? Theme.tideTable : (label.observed ? Theme.harbor : Theme.swell)
            return Tag(t: label.anchor.date.timeIntervalSince1970, high: t.kind == .high,
                       v: unit.fromMeters(label.anchor.height), lines: lines, dot: dot)
        }
    }

    // MARK: Ticks

    /// Ticks on the station's clock, day by day so they stay put across DST:
    /// every 2 h (≤ 12 h on screen), 6 h, 12 h, each midnight, or each Monday.
    func ticks(start: Double, end: Double, length: Double) -> [(t: Double, label: String)] {
        let tier = TideLineChart.tier(for: length)
        let hours: [Int] = switch tier {
        case .day: length <= 12 * 3_600 ? Array(stride(from: 0, to: 24, by: 2)) : [0, 6, 12, 18]
        case .twoDays: [0, 12]
        case .week, .month: [0]
        }
        var out: [(Double, String)] = []
        var day = calendar.startOfDay(for: Date(timeIntervalSince1970: start - 86_400))
        let last = Date(timeIntervalSince1970: end)
        while day <= last {
            if tier != .month || calendar.component(.weekday, from: day) == 2 {
                for h in hours {
                    guard let d = calendar.date(bySettingHour: h, minute: 0, second: 0, of: day) else { continue }
                    let t = d.timeIntervalSince1970
                    if t >= start - length * 0.15, t <= end { out.append((t, tickLabel(t, tier: tier))) }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return out
    }

    private func tickLabel(_ t: Double, tier: TideLineChart.Window) -> String {
        let key = t * 8 + Double(TideLineChart.Window.allCases.firstIndex(of: tier) ?? 0)
        if let hit = tickLabels[key] { return hit }
        let d = Date(timeIntervalSince1970: t)
        let s: String
        switch tier {
        case .month: s = d.formatted(Date.FormatStyle(timeZone: tz).month(.abbreviated).day())
        case .week: s = d.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated).day())
        case .day, .twoDays:
            // Midnight names the day, so a moved chart says which day it shows.
            s = calendar.component(.hour, from: d) == 0
                ? d.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated))
                : d.formatted(Date.FormatStyle(timeZone: tz).hour())
        }
        if tickLabels.count > 4_000 { tickLabels.removeAll() }
        tickLabels[key] = s
        return s
    }

    /// Height of the drawn line at `t`: observed before the forecast starts.
    func level(at t: Double) -> Double? {
        t < cut ? observed.value(at: t) : forecast.value(at: t)
    }

    /// Room for the high/low tags above and below the curve while they show
    /// (≤ 4 days on screen), easing to a tighter fit further out.
    func yRange(length: Double) -> (lo: Double, hi: Double) {
        let a = 4 * 86_400.0, b = 5.5 * 86_400.0
        let f = length <= a ? 0.3 : (length >= b ? 0.1 : 0.3 - 0.2 * (length - a) / (b - a))
        let pad = (yHi - yLo) * f
        return (yLo - pad, yHi + pad)
    }

    /// High/low tags fade out between 3.5 and 4 days on screen.
    static func tagOpacity(length: Double) -> Double {
        Swift.min(Swift.max((4 * 86_400 - length) / (0.5 * 86_400), 0), 1)
    }
}

// MARK: - Drawing

extension ChartData {
    private enum Thin { case envelope, max, min }

    func draw(_ ctx: inout GraphicsContext, size: CGSize, start: Double, length: Double, selection: Double?) {
        let w = size.width
        let plotH = size.height - Self.axisHeight
        guard w > 1, plotH > 1, length > 0 else { return }
        let end = start + length
        let (lo, hi) = yRange(length: length)
        // Lines thin out past four days on screen, where each tide is only a
        // few pixels wide, so the month reads as tides rather than a block.
        let thin = CGFloat(Swift.min(Swift.max(log2(length / (4 * 86_400)), 0), 3) / 3)
        func weight(_ w: CGFloat) -> CGFloat { w - (w - 0.9) * thin }
        let xs = Double(w) / length
        func X(_ t: Double) -> CGFloat { CGFloat((t - start) * xs) }
        func Y(_ v: Double) -> CGFloat { plotH - CGFloat((v - lo) / (hi - lo)) * plotH }

        // Gridlines and tick labels.
        for tick in ticks(start: start, end: end, length: length) {
            let x = X(tick.t)
            var grid = Path()
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: plotH))
            ctx.stroke(grid, with: .color(Theme.hairline), lineWidth: 0.75)
            let label = ctx.resolve(Text(tick.label).font(.caption2).foregroundStyle(Theme.inkSecondary))
            ctx.draw(label, at: CGPoint(x: x + 3, y: plotH + 5), anchor: .topLeading)
        }

        var plot = ctx
        plot.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: plotH)))

        // Water fill under the line.
        let waterPts = points(water, start: start, end: end, w: w, X: X, Y: Y, thin: .envelope)
        if waterPts.count > 1 {
            var area = Path()
            area.move(to: CGPoint(x: waterPts[0].x, y: plotH))
            area.addLine(to: waterPts[0])
            Self.appendCurve(&area, waterPts)
            area.addLine(to: CGPoint(x: waterPts[waterPts.count - 1].x, y: plotH))
            area.closeSubpath()
            plot.fill(area, with: .color(Theme.harbor.opacity(0.08)))
        }

        // 80 % range.
        let up = points(upper, start: start, end: end, w: w, X: X, Y: Y, thin: .max)
        let dn = points(lower, start: start, end: end, w: w, X: X, Y: Y, thin: .min)
        if up.count > 1, dn.count > 1 {
            var band = Path()
            band.move(to: up[0])
            Self.appendCurve(&band, up)
            band.addLine(to: dn[dn.count - 1])
            Self.appendCurve(&band, dn, reversed: true)
            band.closeSubpath()
            plot.fill(band, with: .color(Theme.swellBand.opacity(0.24)))
        }

        // Tide table, dashed; the dashes stay put on the data as it moves.
        let tablePts = points(table, start: start, end: end, w: w, X: X, Y: Y, thin: .envelope)
        if tablePts.count > 1 {
            var p = Path()
            p.move(to: tablePts[0])
            Self.appendCurve(&p, tablePts)
            let phase = (Double(tablePts[0].x) - Double(X(bounds.lowerBound))).truncatingRemainder(dividingBy: 6)
            plot.stroke(p, with: .color(Theme.tideTable.opacity(1 - 0.4 * thin)),
                        style: StrokeStyle(lineWidth: weight(1.2) * (1 - 0.3 * thin), dash: [3, 3], dashPhase: CGFloat(-phase)))
        }

        func stroke(_ line: ChartLine, _ color: Color, _ width: CGFloat) {
            let pts = points(line, start: start, end: end, w: w, X: X, Y: Y, thin: .envelope)
            guard pts.count > 1 else { return }
            var p = Path()
            p.move(to: pts[0])
            Self.appendCurve(&p, pts)
            plot.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: weight(width), lineCap: .round, lineJoin: .round))
        }
        stroke(forecast, Theme.swell, 2.2)
        stroke(observed.prefix(before: cut + 1), Theme.harbor, 2.4)

        // Weather-forecast horizon.
        if let o = outlook, o >= start - length * 0.2, o <= end {
            let x = X(o)
            var rule = Path()
            rule.move(to: CGPoint(x: x, y: 0))
            rule.addLine(to: CGPoint(x: x, y: plotH))
            plot.stroke(rule, with: .color(Theme.inkSecondary.opacity(0.35)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let text = plot.resolve(Text("Outlook ›").font(.caption2.weight(.medium)).foregroundStyle(Theme.inkSecondary))
            let tw = text.measure(in: size).width
            plot.draw(text, at: CGPoint(x: Swift.min(Swift.max(x + 4, 0), w - tw), y: 0), anchor: .topLeading)
        }

        // Now.
        if now >= start - length * 0.05, now <= end + length * 0.05 {
            let x = X(now)
            var rule = Path()
            rule.move(to: CGPoint(x: x, y: 0))
            rule.addLine(to: CGPoint(x: x, y: plotH))
            plot.stroke(rule, with: .color(Theme.ink.opacity(0.18)), lineWidth: 1)
            if let v = nowLevel {
                let c = CGPoint(x: x, y: Y(v))
                plot.fill(Self.circle(c, 9), with: .color(Theme.harbor.opacity(0.15)))
                plot.fill(Self.circle(c, 5), with: .color(Theme.surface))
                plot.stroke(Self.circle(c, 4.3), with: .color(Theme.harbor), lineWidth: 2.4)
            }
        }

        // High/low tags.
        let alpha = Self.tagOpacity(length: length)
        if alpha > 0 {
            var tagCtx = ctx
            tagCtx.opacity = alpha
            drawTags(&tagCtx, start: start, end: end, length: length, w: w, plotH: plotH, X: X, Y: Y)
        }

        // Scrub cursor.
        if let s = selection, s >= start, s <= end {
            let x = X(s)
            var rule = Path()
            rule.move(to: CGPoint(x: x, y: 0))
            rule.addLine(to: CGPoint(x: x, y: plotH))
            plot.stroke(rule, with: .color(Theme.ink.opacity(0.35)), lineWidth: 1)
            if let v = level(at: s) {
                let c = CGPoint(x: x, y: Y(v))
                plot.fill(Self.circle(c, 5), with: .color(Theme.surface))
                plot.stroke(Self.circle(c, 4), with: .color(Theme.ink.opacity(0.7)), lineWidth: 2)
            }
        }
    }

    private func drawTags(_ ctx: inout GraphicsContext, start: Double, end: Double, length: Double, w: CGFloat,
                          plotH: CGFloat, X: (Double) -> CGFloat, Y: (Double) -> CGFloat) {
        let margin = length * 0.15
        var i = lowerTagIndex(start - margin)
        while i < tags.count, tags[i].t <= end + margin {
            let tag = tags[i]
            i += 1
            let p = CGPoint(x: X(tag.t), y: Y(tag.v))
            let texts = tag.lines.map { l in
                ctx.resolve(Text(l.text).font(.caption2.monospacedDigit()).fontWeight(l.bold ? .semibold : .regular)
                    .foregroundStyle(l.color))
            }
            let sizes = texts.map { $0.measure(in: CGSize(width: 300, height: 40)) }
            let blockW = sizes.map(\.width).max() ?? 0
            let blockH = sizes.reduce(0) { $0 + $1.height }
            var top = tag.high ? p.y - 3 - 2.5 - blockH : p.y + 3 + 2.5
            top = Swift.min(Swift.max(top, 0), plotH - blockH)
            // Kept inside the chart while its point is, then sliding off with it.
            let left = Swift.min(Swift.max(p.x - blockW / 2, Swift.min(0, p.x)), Swift.max(w - blockW, p.x - blockW))
            var y = top
            for (text, size) in zip(texts, sizes) {
                ctx.draw(text, at: CGPoint(x: left + (blockW - size.width) / 2, y: y), anchor: .topLeading)
                y += size.height
            }
            ctx.fill(Self.circle(p, 2.4), with: .color(tag.dot))
        }
    }

    private func lowerTagIndex(_ x: Double) -> Int {
        var lo = 0, hi = tags.count
        while lo < hi { let m = (lo + hi) / 2; if tags[m].t < x { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// The visible slice in screen points; more than ~1.5 points a pixel is
    /// thinned per pixel column (keeping each column's extremes, so peaks
    /// survive any zoom).
    private func points(_ line: ChartLine, start: Double, end: Double, w: CGFloat,
                        X: (Double) -> CGFloat, Y: (Double) -> CGFloat, thin: Thin) -> [CGPoint] {
        let r = line.covering(start, end)
        guard !r.isEmpty else { return [] }
        if Double(r.count) <= Double(w) * 1.5 {
            return r.map { CGPoint(x: X(line.t[$0]), y: Y(line.v[$0])) }
        }
        var out: [CGPoint] = []
        out.reserveCapacity(Int(w) * 2 + 4)
        var column = Int.min
        var minI = r.lowerBound, maxI = r.lowerBound
        func flush() {
            guard column != Int.min else { return }
            switch thin {
            case .envelope:
                let a = Swift.min(minI, maxI), b = Swift.max(minI, maxI)
                out.append(CGPoint(x: X(line.t[a]), y: Y(line.v[a])))
                if b != a { out.append(CGPoint(x: X(line.t[b]), y: Y(line.v[b]))) }
            case .max: out.append(CGPoint(x: X(line.t[maxI]), y: Y(line.v[maxI])))
            case .min: out.append(CGPoint(x: X(line.t[minI]), y: Y(line.v[minI])))
            }
        }
        for i in r {
            let c = Int(X(line.t[i]).rounded(.down))
            if c != column {
                flush()
                column = c
                minI = i
                maxI = i
            } else {
                if line.v[i] < line.v[minI] { minI = i }
                if line.v[i] > line.v[maxI] { maxI = i }
            }
        }
        flush()
        return out
    }

    static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }

    /// Continues `path` (already at the first point, or the last when
    /// `reversed`) through `pts`: a monotone cubic where points are sparse
    /// enough to show corners, straight segments where they're dense.
    static func appendCurve(_ path: inout Path, _ pts: [CGPoint], reversed: Bool = false) {
        let n = pts.count
        guard n > 1 else { return }
        let sparse = n >= 3 && (pts[n - 1].x - pts[0].x) / CGFloat(n - 1) > 3
        guard sparse else {
            if reversed { for i in stride(from: n - 2, through: 0, by: -1) { path.addLine(to: pts[i]) } }
            else { for i in 1..<n { path.addLine(to: pts[i]) } }
            return
        }
        // Fritsch–Carlson tangents: no overshoot past the data's highs and lows.
        var d = [CGFloat](repeating: 0, count: n - 1), m = [CGFloat](repeating: 0, count: n)
        for i in 0..<(n - 1) {
            let dx = pts[i + 1].x - pts[i].x
            d[i] = dx > 0 ? (pts[i + 1].y - pts[i].y) / dx : 0
        }
        m[0] = d[0]
        m[n - 1] = d[n - 2]
        for i in 1..<(n - 1) {
            if d[i - 1] * d[i] <= 0 { m[i] = 0; continue }
            let h0 = pts[i].x - pts[i - 1].x, h1 = pts[i + 1].x - pts[i].x
            m[i] = 3 * (h0 + h1) / ((2 * h1 + h0) / d[i - 1] + (h1 + 2 * h0) / d[i])
        }
        func controls(_ i: Int) -> (CGPoint, CGPoint) {
            let h = (pts[i + 1].x - pts[i].x) / 3
            return (CGPoint(x: pts[i].x + h, y: pts[i].y + m[i] * h),
                    CGPoint(x: pts[i + 1].x - h, y: pts[i + 1].y - m[i + 1] * h))
        }
        if reversed {
            for i in stride(from: n - 2, through: 0, by: -1) {
                let (c1, c2) = controls(i)
                path.addCurve(to: pts[i], control1: c2, control2: c1)
            }
        } else {
            for i in 0..<(n - 1) {
                let (c1, c2) = controls(i)
                path.addCurve(to: pts[i + 1], control1: c1, control2: c2)
            }
        }
    }
}

// MARK: - Views

/// The drawn chart plus its gestures. Reads the viewport, so it (alone)
/// redraws on every pan, pinch, scrub or animation frame.
private struct TideCanvas: View {
    let data: ChartData
    let viewport: ChartViewport
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone
    let reduceMotion: Bool

    var body: some View {
        let start = viewport.start, length = viewport.length, selection = viewport.selection
        Canvas { ctx, size in
            data.draw(&ctx, size: size, start: start, length: length, selection: selection)
        }
        .overlay(ChartGestureLayer(viewport: viewport))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Water level chart")
        .accessibilityValue(summary(start: start, length: length))
        .accessibilityHint("Pinch to zoom. Swipe up or down to move through time.")
        .accessibilityZoomAction { action in
            let c = start + length / 2, l = action.direction == .zoomIn ? length / 2 : length * 2
            viewport.animate(toStart: c - l / 2, length: l, duration: reduceMotion ? 0 : 0.3)
        }
        .accessibilityAdjustableAction { dir in
            let step = length / 2 * (dir == .increment ? 1 : -1)
            viewport.animate(toStart: start + step, length: length, duration: reduceMotion ? 0 : 0.3)
        }
    }

    private func summary(start: Double, length: Double) -> String {
        let a = Date(timeIntervalSince1970: start), b = Date(timeIntervalSince1970: start + length)
        var out = "Showing \(Fmt.smartTime(a, in: tz)) to \(Fmt.smartTime(b, in: tz))."
        let r = data.forecast.covering(start, start + length)
        if let i = r.max(by: { data.forecast.v[$0] < data.forecast.v[$1] }) {
            let t = Date(timeIntervalSince1970: data.forecast.t[i])
            out += " Highest forecast \(Fmt.length(unit.toMeters(data.forecast.v[i]), unit)) at \(Fmt.smartTime(t, in: tz))."
        }
        return out
    }
}

/// Legend (or the scrub readout) and the Now button once now is off screen.
private struct ChartFooter: View {
    let data: ChartData
    let viewport: ChartViewport
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone
    let home: (TideLineChart.Window) -> Double
    let reduceMotion: Bool

    var body: some View {
        let start = viewport.start, length = viewport.length
        let away = viewport.canPan && !(start...(start + length)).contains(data.now)
        HStack(spacing: 8) {
            if let s = viewport.selection {
                SelectionReadout(forecast: forecast, date: Date(timeIntervalSince1970: s), unit: unit, tz: tz)
            } else {
                HStack(spacing: 14) {
                    LegendSwatch(color: Theme.harbor, label: "Observed")
                    LegendSwatch(color: Theme.swell, label: away ? "Forecast" : "Forecast · 80% range")
                    LegendSwatch(color: Theme.tideTable, label: "Tide table", dashed: true)
                }
            }
            Spacer(minLength: 0)
            if away {
                Button {
                    let w = viewport.window
                    let target = abs(length - TideLineChart.presetLength(w)) < 60 ? home(w) : data.now - length * 0.25
                    viewport.animate(toStart: target, length: length, duration: reduceMotion ? 0 : 0.45)
                } label: {
                    Label("Now", systemImage: data.now < start ? "chevron.left" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.neutralWash, in: Capsule())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.harbor)
                .accessibilityLabel("Scroll back to now")
            }
        }
    }
}

/// Day / 2 days / Week / Month: highlights the preset nearest the zoom, and
/// eases to a preset's length and starting point when tapped.
private struct RangePicker: View {
    let viewport: ChartViewport
    let home: (TideLineChart.Window) -> Double
    let reduceMotion: Bool

    var body: some View {
        Picker("Chart range", selection: Binding(get: { TideLineChart.tier(for: viewport.length) }, set: { w in
            viewport.window = w
            viewport.animate(toStart: home(w), length: TideLineChart.presetLength(w), duration: reduceMotion ? 0 : 0.45)
        })) {
            ForEach(TideLineChart.Window.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}

// MARK: - Gestures

/// UIKit recognizers over the canvas: they report velocity for momentum and
/// can defer to the page's vertical scroll properly. One-finger horizontal
/// pan (with momentum), two-finger pinch (zoom about the fingers, and pan
/// while pinching), touch-and-hold then drag to scrub.
private struct ChartGestureLayer: UIViewRepresentable {
    let viewport: ChartViewport

    func makeCoordinator() -> Coordinator { Coordinator(viewport: viewport) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let c = context.coordinator
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = c
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        pinch.delegate = c
        let press = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.25
        press.allowableMovement = 10
        press.delegate = c
        [pan, pinch, press].forEach(view.addGestureRecognizer)
        c.panRecognizer = pan
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.viewport = viewport
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var viewport: ChartViewport
        weak var panRecognizer: UIPanGestureRecognizer?
        private var panBase = 0.0
        private var pinchBase = 0.0
        private var pinchAnchor = 0.0
        private let haptics = UISelectionFeedbackGenerator()

        init(viewport: ChartViewport) { self.viewport = viewport }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let v = g.view, v.bounds.width > 0 else { return }
            let perPoint = viewport.length / Double(v.bounds.width)
            switch g.state {
            case .began:
                viewport.beginInteraction()
                panBase = viewport.start
            case .changed:
                viewport.set(start: panBase - Double(g.translation(in: v).x) * perPoint, length: viewport.length)
            case .ended:
                viewport.fling(velocity: -Double(g.velocity(in: v).x) * perPoint)
            default: break
            }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let v = g.view, v.bounds.width > 0, g.numberOfTouches >= 2 || g.state != .changed else { return }
            let fx = Swift.min(Swift.max(Double(g.location(in: v).x / v.bounds.width), 0), 1)
            switch g.state {
            case .began:
                viewport.beginInteraction()
                pinchBase = viewport.length
                pinchAnchor = viewport.start + viewport.length * fx
            case .changed:
                // The moment first under the fingers follows them: zoom and pan at once.
                viewport.zoom(scale: Double(g.scale), from: pinchBase, anchorTime: pinchAnchor, fraction: fx)
            default: break
            }
        }

        @objc func press(_ g: UILongPressGestureRecognizer) {
            guard let v = g.view, v.bounds.width > 0 else { return }
            let x = Swift.min(Swift.max(g.location(in: v).x, 0), v.bounds.width)
            let t = viewport.start + viewport.length * Double(x / v.bounds.width)
            switch g.state {
            case .began:
                viewport.beginInteraction()
                haptics.selectionChanged()
                scrollView(of: v)?.isScrollEnabled = false
                viewport.selection = t
            case .changed:
                viewport.selection = t
            default:
                viewport.selection = nil
                scrollView(of: v)?.isScrollEnabled = true
            }
        }

        private func scrollView(of v: UIView) -> UIScrollView? {
            var s = v.superview
            while let view = s, !(view is UIScrollView) { s = view.superview }
            return s as? UIScrollView
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === panRecognizer, let p = panRecognizer, let v = p.view else { return true }
            let vel = p.velocity(in: v)
            return viewport.selection == nil && viewport.canPan && abs(vel.x) > abs(vel.y)
        }

        /// The page's vertical scroll waits for a horizontal pan to fail.
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            g === panRecognizer && other is UIPanGestureRecognizer && other.view is UIScrollView
        }
    }
}

private struct LegendSwatch: View {
    let color: Color
    let label: String
    var dashed = false

    var body: some View {
        HStack(spacing: 6) {
            if dashed {
                HLine().stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 14, height: 2)
            } else {
                Capsule().fill(color).frame(width: 14, height: 2)
            }
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(Theme.inkSecondary)
    }
}

private struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

/// Replaces the legend while the reader scrubs the chart.
private struct SelectionReadout: View {
    let forecast: WaterLevelForecast
    let date: Date
    let unit: LengthUnit
    let tz: TimeZone

    var body: some View {
        let obs = date <= forecast.issued ? forecast.observed.value(at: date, maxGap: 1_200) : nil
        let fc = forecast.total.value(at: date, maxGap: 1_200)
        let table = forecast.astronomical.value(at: date)
        HStack(spacing: 10) {
            Text(Fmt.smartTime(date, in: tz)).fontWeight(.semibold)
            if let obs {
                Text("Observed \(Fmt.length(obs, unit))").foregroundStyle(Theme.harbor)
            } else if let fc {
                Text("Forecast \(Fmt.length(fc, unit))").foregroundStyle(Theme.swellText)
            }
            if let table { Text("Table \(Fmt.length(table, unit))").foregroundStyle(Theme.inkSecondary) }
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .combine)
    }
}

/// Non-tidal water: observed history and forecast with its range.
struct SurgeChartView: View {
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone

    private static let colors: [Color] = [Theme.swellBand.opacity(0.24), Theme.harbor, Theme.swell, Theme.inkSecondary]

    /// The weather-driven part only; the outlook beyond is flat by design.
    private var surge: [SurgeForecastPoint] {
        guard let w = forecast.weatherHorizon else { return forecast.surge }
        return forecast.surge.filter { $0.date <= w }
    }

    var body: some View {
        let surge = surge
        return Chart {
            ForEach(surge) { s in
                AreaMark(x: .value("Time", s.date),
                         yStart: .value("Low", unit.fromMeters(s.surge - 1.2816 * s.sigma)),
                         yEnd: .value("High", unit.fromMeters(s.surge + 1.2816 * s.sigma)))
                    .foregroundStyle(by: .value("Layer", "Range"))
            }
            ForEach(forecast.observedResidual.points, id: \.date) { p in
                LineMark(x: .value("Time", p.date), y: .value("Surge", unit.fromMeters(p.value)), series: .value("Series", "Observed"))
                    .foregroundStyle(by: .value("Layer", "Observed"))
            }
            ForEach(surge) { s in
                LineMark(x: .value("Time", s.date), y: .value("Surge", unit.fromMeters(s.surge)), series: .value("Series", "Forecast"))
                    .foregroundStyle(by: .value("Layer", "Forecast"))
            }
            ForEach(surge.filter { $0.officialSurge != nil }) { s in
                LineMark(x: .value("Time", s.date), y: .value("Surge", unit.fromMeters(s.officialSurge ?? 0)), series: .value("Series", "NWS"))
                    .foregroundStyle(by: .value("Layer", "NWS official"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [1, 3]))
            }
            RuleMark(y: .value("Tide table", 0.0)).foregroundStyle(Theme.tideTable.opacity(0.6))
            RuleMark(x: .value("Now", forecast.issued)).foregroundStyle(Theme.ink.opacity(0.18))
        }
        .chartForegroundStyleScale(domain: ["Range", "Observed", "Forecast", "NWS official"], range: Self.colors)
        .chartYAxisLabel(unit.symbol)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let d = value.as(Date.self) { Text(d.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated))) }
                }
            }
        }
        .chartLegend(position: .bottom)
        .frame(height: 180)
    }
}

