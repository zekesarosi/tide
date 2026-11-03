import Charts
import SwiftUI
import TideKit

/// The signature "tide line": full-bleed water level with the observed past,
/// the forecast and its 80 % range, the tide table, high/low labels and a
/// "now" dot. Swipe to move through time; touch and hold to read any moment.
struct TideLineChart: View {
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone

    enum Window: String, CaseIterable, Identifiable {
        case day = "Day", twoDays = "2 days", week = "Week", month = "Month"
        var id: String { rawValue }
    }

    @State private var window: Window = .day
    /// The moment being scrubbed. Not plain `@State` for the same reason as
    /// `scroll`: only the cursor overlay and the readout row observe it.
    @State private var selection = SelectionState()
    /// Leading edge of the visible range while scrolling. Not plain `@State`:
    /// the chart writes it on every scroll frame, and a state change would
    /// re-run this body and rebuild every mark each frame.
    @State private var scroll: ScrollState
    @State private var cache = SeriesCache()

    init(forecast: WaterLevelForecast, unit: LengthUnit, tz: TimeZone) {
        self.forecast = forecast
        self.unit = unit
        self.tz = tz
        _scroll = State(initialValue: ScrollState(Self.homeStart(.day, forecast: forecast, tz: tz),
                                                  home: ScrollState.Home(window: .day, issued: forecast.issued)))
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
    }

    struct Band: Identifiable {
        var id: Date { date }
        let date: Date
        let low: Double
        let high: Double
    }

    /// A high or low in view: the tide-table extreme paired with the
    /// forecast (or, in the past, observed) extreme it became.
    struct ExtremeLabel: Identifiable {
        var id: Date { table.date }
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

    enum Layer: String, CaseIterable {
        case water = "Water", band = "Range"
        case predicted = "Tide table", forecast = "Forecast", observed = "Observed"
    }

    private var calendar: Calendar {
        var c = Calendar.current
        c.timeZone = tz
        return c
    }

    /// Everything there is to scroll through: the observed past to the
    /// forecast horizon (months, with the long-range outlook).
    private var domain: ClosedRange<Date> {
        let now = forecast.issued
        let start = [forecast.observed.first?.date, forecast.astronomical.first?.date].compactMap { $0 }.min() ?? now - 12 * 3_600
        return Swift.min(start, now)...forecast.horizon
    }

    /// How much time is on screen at once (never more than there is).
    private func visibleLength(_ d: ClosedRange<Date>) -> TimeInterval {
        let span = d.upperBound.timeIntervalSince(d.lowerBound)
        switch window {
        case .day: return Swift.min(86_400, span)
        case .twoDays: return Swift.min(48 * 3_600, span)
        case .week: return Swift.min(7 * 86_400, span)
        case .month: return Swift.min(30 * 86_400, span)
        }
    }

    private func scrollable(_ d: ClosedRange<Date>) -> Bool {
        visibleLength(d) < d.upperBound.timeIntervalSince(d.lowerBound) - 60
    }

    /// Where each window starts before any scrolling: today from midnight
    /// (late in the day, keeping the next few hours in view), longer windows
    /// from a little before now.
    private static func homeStart(_ w: Window, forecast: WaterLevelForecast, tz: TimeZone) -> Date {
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

    private var homeStart: Date { Self.homeStart(window, forecast: forecast, tz: tz) }

    // MARK: Data

    /// Everything the chart draws across the whole scrollable range. Built
    /// once per forecast, window and unit (see `SeriesCache`): scrubbing
    /// re-runs the body on every move. Scrolling does not re-run it at all,
    /// since only `ScrollHome` observes the scroll position.
    struct Series {
        let domain: ClosedRange<Date>
        let observed: [Point]
        let forecast: [Point]
        let predicted: [Point]
        let band: [Band]
        let waterline: [Point]
        let yDomain: ClosedRange<Double>
        let ticks: [Date]
        let extremes: [ExtremeLabel]
    }

    /// The chart draws the full curve from the observed past to a week ahead;
    /// further out it joins the forecast highs and lows. Months of 10-minute
    /// points would be tens of thousands of marks.
    private static let denseHorizon: TimeInterval = 7 * 86_400

    /// What a `Series` depends on, cheap to compare (the forecast itself is
    /// tens of thousands of points).
    fileprivate struct SeriesKey: Equatable {
        let issued: Date
        let horizon: Date
        let observedCount: Int
        let totalCount: Int
        let window: Window
        let unit: LengthUnit
        let tz: TimeZone
    }

    private var seriesKey: SeriesKey {
        SeriesKey(issued: forecast.issued, horizon: forecast.horizon, observedCount: forecast.observed.points.count,
                  totalCount: forecast.total.points.count, window: window, unit: unit, tz: tz)
    }

    private func cachedSeries() -> Series {
        let key = seriesKey
        if let hit = cache.series(for: key) { return hit }
        let s = makeSeries()
        cache.store(s, for: key)
        return s
    }

    private func makeSeries() -> Series {
        let d = domain
        let denseEnd = Swift.min(d.upperBound, forecast.issued + Self.denseHorizon)
        let dense = d.lowerBound...denseEnd
        // ~20-minute spacing over the dense range: smooth at any zoom.
        func pts(_ s: TimeSeries, _ layer: Layer, spacing: TimeInterval = 1_200) -> [Point] {
            let inside = s.points.filter { dense.contains($0.date) }
            let maxPoints = Swift.max(1, Int(dense.upperBound.timeIntervalSince(dense.lowerBound) / spacing))
            let stride = Swift.max(1, inside.count / maxPoints)
            return inside.enumerated().compactMap { i, p in
                i % stride == 0 ? point(layer, p.date, p.value) : nil
            }
        }
        func point(_ layer: Layer, _ date: Date, _ meters: Double) -> Point {
            Point(id: "\(layer.rawValue)\(date.timeIntervalSince1970)", date: date, value: unit.fromMeters(meters))
        }
        let outlook = forecast.events.filter { $0.date > denseEnd && d.contains($0.date) }
        let obs = pts(forecast.observed, .observed, spacing: 600)
        let fc = pts(forecast.total, .forecast) + outlook.map { point(.forecast, $0.date, $0.total) }
        let pred = pts(forecast.astronomical, .predicted) + outlook.map { point(.predicted, $0.date, $0.astronomical) }
        let bandStride = Swift.max(1, forecast.totalLower.points.filter { dense.contains($0.date) }.count
            / Swift.max(1, Int(dense.upperBound.timeIntervalSince(dense.lowerBound) / 1_200)))
        let band = zip(forecast.totalLower.points, forecast.totalUpper.points)
            .enumerated()
            .filter { $0.offset % bandStride == 0 && dense.contains($0.element.0.date) }
            .map { Band(date: $0.element.0.date, low: unit.fromMeters($0.element.0.value), high: unit.fromMeters($0.element.1.value)) }
            + outlook.map { Band(date: $0.date, low: unit.fromMeters($0.lower80), high: unit.fromMeters($0.upper80)) }
        let cut = fc.first?.date ?? forecast.issued
        let water = obs.filter { $0.date < cut } + fc
        let extremes = (window == .day || window == .twoDays) ? extremeLabels(dense: dense, outlook: outlook) : []

        var yd: ClosedRange<Double> = 0...1
        let values = (water + pred).map(\.value) + band.flatMap { [$0.low, $0.high] }
        if var lo = values.min(), var hi = values.max(), lo < hi {
            // Leave room for the high/low labels above and below the curve.
            let pad = (hi - lo) * (extremes.isEmpty ? 0.1 : 0.3)
            lo -= pad
            hi += pad
            yd = lo...hi
        }

        // Ticks on the station's clock, day by day, so they stay put across DST
        // changes: every 6 or 12 h, each midnight (week) or each Monday (month).
        let hours: [Int] = switch window {
        case .day: [0, 6, 12, 18]
        case .twoDays: [0, 12]
        case .week, .month: [0]
        }
        var ticks: [Date] = []
        var day = calendar.startOfDay(for: d.lowerBound)
        while day <= d.upperBound {
            if window != .month || calendar.component(.weekday, from: day) == 2 {
                for h in hours {
                    if let t = calendar.date(bySettingHour: h, minute: 0, second: 0, of: day), d.contains(t) { ticks.append(t) }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return Series(domain: d, observed: obs, forecast: fc, predicted: pred, band: band, waterline: water,
                      yDomain: yd, ticks: ticks, extremes: extremes)
    }

    /// Tide-table highs and lows, each matched with the forecast extreme (or
    /// the observed one, before now) within ±3 h over the dense range; past
    /// it, the forecast events themselves (the outlook surge varies slowly,
    /// so the forecast turns when the tide does).
    private func extremeLabels(dense d: ClosedRange<Date>, outlook: [ForecastEvent]) -> [ExtremeLabel] {
        let far = outlook.map { e in
            ExtremeLabel(kind: e.kind, table: TideExtreme(date: e.date, height: e.astronomical, kind: e.kind),
                         actual: TideExtreme(date: e.date, height: e.total, kind: e.kind), observed: false)
        }
        return nearExtremeLabels(in: d) + far
    }

    private func nearExtremeLabels(in d: ClosedRange<Date>) -> [ExtremeLabel] {
        let window: TimeInterval = 3 * 3_600
        return forecast.astronomical.sliced(from: d.lowerBound - window, to: d.upperBound + window)
            .extrema()
            .filter { d.contains($0.date) }
            .map { t in
                let range = (t.date - window)...(t.date + window)
                func pick(_ s: TimeSeries) -> TideExtreme? {
                    let inside = s.points.filter { range.contains($0.date) }
                    let best = t.kind == .high ? inside.max { $0.value < $1.value } : inside.min { $0.value < $1.value }
                    // An extreme on the edge of the search window is just a slope, not a turn.
                    guard let best, let first = inside.first, let last = inside.last,
                          best.date != first.date, best.date != last.date else { return nil }
                    return TideExtreme(date: best.date, height: best.value, kind: t.kind)
                }
                if let fc = pick(forecast.total) {
                    return ExtremeLabel(kind: t.kind, table: t, actual: fc, observed: false)
                }
                let obs = t.date <= forecast.issued ? pick(forecast.observed) : nil
                return ExtremeLabel(kind: t.kind, table: t, actual: obs, observed: obs != nil)
            }
    }

    private func tickLabel(_ d: Date) -> String {
        switch window {
        case .month: return d.formatted(Date.FormatStyle(timeZone: tz).month(.abbreviated).day())
        case .week: return d.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated).day())
        case .day, .twoDays:
            // Midnight names the day, so a scrolled chart says which day it shows.
            if calendar.component(.hour, from: d) == 0 {
                return d.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated))
            }
        }
        return d.formatted(Date.FormatStyle(timeZone: tz).hour())
    }

    private static let layerColors: [Color] = [
        Theme.harbor.opacity(0.08), Theme.swellBand.opacity(0.24),
        Theme.tideTable, Theme.swell, Theme.harbor,
    ]

    /// The level at the "now" dot: the forecast, or a fresh observation.
    private var nowLevel: Double? {
        if let v = forecast.total.value(at: forecast.issued, maxGap: 3_600) { return v }
        if let o = forecast.observed.last, forecast.issued.timeIntervalSince(o.date) < 3_600 { return o.value }
        return nil
    }

    // MARK: Body

    var body: some View {
        let series = cachedSeries()
        // Re-run (once) when the position is set from here rather than by a
        // scroll, so the chart picks it up.
        let _ = scroll.jumps
        // A new window or forecast starts from its home, in this same pass.
        let _ = scroll.rehome(ScrollState.Home(window: window, issued: forecast.issued), to: homeStart)
        VStack(alignment: .leading, spacing: 10) {
            chart(series)
                .frame(height: 210)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: window)
                .accessibilityLabel("Water level chart")
                .accessibilityValue(accessibilitySummary(series.domain))

            ScrollHome(scroll: scroll, home: homeStart, now: forecast.issued,
                       length: visibleLength(series.domain), enabled: scrollable(series.domain), reduceMotion: reduceMotion) { away in
                if let date = selection.date {
                    SelectionReadout(forecast: forecast, date: date, unit: unit, tz: tz)
                } else {
                    legend(compact: away)
                }
            }
            .padding(.horizontal, Theme.margin)
            .frame(minHeight: 18, alignment: .leading)

            Picker("Chart range", selection: $window) {
                ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.margin)
        }
        .onChange(of: window) { scroll.show(homeStart) }
        .onChange(of: forecast.issued) { scroll.show(homeStart) }
    }

    private func chart(_ s: Series) -> some View {
        let base: Double = s.yDomain.lowerBound
        let now: Date = forecast.issued
        let level: Double? = nowLevel

        return Chart {
            ForEach(s.waterline) { p in
                AreaMark(x: .value("Time", p.date), yStart: .value("Base", base), yEnd: .value("Level", p.value))
                    .foregroundStyle(by: .value("Layer", Layer.water.rawValue))
                    .interpolationMethod(.monotone)
            }
            ForEach(s.band) { r in
                AreaMark(x: .value("Time", r.date), yStart: .value("Low", r.low), yEnd: .value("High", r.high))
                    .foregroundStyle(by: .value("Layer", Layer.band.rawValue))
                    .interpolationMethod(.monotone)
            }
            ForEach(s.predicted) { p in
                LineMark(x: .value("Time", p.date), y: .value("Level", p.value), series: .value("Series", Layer.predicted.rawValue))
                    .foregroundStyle(by: .value("Layer", Layer.predicted.rawValue))
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .interpolationMethod(.monotone)
            }
            ForEach(s.forecast) { p in
                LineMark(x: .value("Time", p.date), y: .value("Level", p.value), series: .value("Series", Layer.forecast.rawValue))
                    .foregroundStyle(by: .value("Layer", Layer.forecast.rawValue))
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(s.observed) { p in
                LineMark(x: .value("Time", p.date), y: .value("Level", p.value), series: .value("Series", Layer.observed.rawValue))
                    .foregroundStyle(by: .value("Layer", Layer.observed.rawValue))
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(s.extremes) { e in
                PointMark(x: .value("Time", e.anchor.date), y: .value("Level", unit.fromMeters(e.anchor.height)))
                    .symbolSize(18)
                    .foregroundStyle(e.actual == nil ? Theme.tideTable : (e.observed ? Theme.harbor : Theme.swell))
                    .annotation(position: e.kind == .high ? .top : .bottom, spacing: 3,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        ExtremeTag(label: e, unit: unit, tz: tz)
                    }
            }
            if let w = forecast.weatherHorizon, w < s.domain.upperBound - 3_600 {
                RuleMark(x: .value("Outlook", w))
                    .foregroundStyle(Theme.inkSecondary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    .annotation(position: .top, alignment: .leading, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        Text("Outlook ›")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.inkSecondary)
                            .padding(.leading, 4)
                            .accessibilityLabel("Beyond here the weather forecast ends; tide table plus typical surge")
                    }
            }
            if s.domain.contains(now) {
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(Theme.ink.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                if let level {
                    PointMark(x: .value("Now", now), y: .value("Level", unit.fromMeters(level)))
                        .symbol {
                            NowDot()
                        }
                }
            }
        }
        .chartForegroundStyleScale(domain: Layer.allCases.map(\.rawValue), range: Self.layerColors)
        .chartLegend(.hidden)
        .chartXScale(domain: s.domain)
        .chartScrollableAxes(scrollable(s.domain) ? .horizontal : [])
        .chartXVisibleDomain(length: visibleLength(s.domain))
        .chartScrollPosition(x: scroll.chartBinding)
        .chartYScale(domain: s.yDomain)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: s.ticks) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(tickLabel(d)).font(.caption2).foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
        }
        .chartXSelection(value: selection.chartBinding)
        .chartOverlay { proxy in
            SelectionCursor(selection: selection, proxy: proxy, level: cursorLevel)
        }
    }

    /// Height of the drawn line at `date`, in display units: observed before
    /// the forecast starts, then the forecast.
    private func cursorLevel(_ date: Date) -> Double? {
        let cut = forecast.total.first?.date ?? forecast.issued
        let m = date < cut ? forecast.observed.value(at: date, maxGap: 1_200) : forecast.total.value(at: date, maxGap: 1_200)
        return m.map(unit.fromMeters)
    }

    private func legend(compact: Bool) -> some View {
        HStack(spacing: 14) {
            LegendSwatch(color: Theme.harbor, label: "Observed")
            LegendSwatch(color: Theme.swell, label: compact ? "Forecast" : "Forecast · 80% range")
            LegendSwatch(color: Theme.tideTable, label: "Tide table", dashed: true)
        }
    }

    private func accessibilitySummary(_ domain: ClosedRange<Date>) -> String {
        guard let peak = forecast.total.sliced(from: domain.lowerBound, to: domain.upperBound).maximum else { return "" }
        return "Highest forecast \(Fmt.length(peak.value, unit)) at \(Fmt.smartTime(peak.date, in: tz))."
    }
}

/// Two-line high/low tag: forecast (or observed) time and height over the
/// tide-table time and height.
private struct ExtremeTag: View {
    let label: TideLineChart.ExtremeLabel
    let unit: LengthUnit
    let tz: TimeZone

    private func line(_ e: TideExtreme) -> String {
        let t = e.date.formatted(Date.FormatStyle(timeZone: tz).hour(.defaultDigits(amPM: .narrow)).minute())
        return "\(t) \(Fmt.length(e.height, unit))"
    }

    var body: some View {
        VStack(spacing: 0) {
            if let actual = label.actual {
                Text(line(actual))
                    .fontWeight(.semibold)
                    .foregroundStyle(label.observed ? Theme.harbor : Theme.swellText)
            }
            if label.showsTable {
                Text(line(label.table))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let name = label.kind == .high ? "High" : "Low"
        let table = "tide table \(Fmt.time(label.table.date, in: tz)), \(Fmt.length(label.table.height, unit))"
        guard let a = label.actual else { return "\(name): \(table)" }
        let src = label.observed ? "observed" : "forecast"
        guard label.showsTable else { return "\(name): \(src) \(Fmt.time(a.date, in: tz)), \(Fmt.length(a.height, unit)), near the tide table" }
        return "\(name): \(src) \(Fmt.time(a.date, in: tz)), \(Fmt.length(a.height, unit)); \(table)"
    }
}

/// The row under the chart, with a "Now" button once the reader has scrolled
/// now out of view. Its own view so only this row, not the whole chart,
/// re-renders while scrolling; `content` learns whether the button shows.
private struct ScrollHome<Content: View>: View {
    let scroll: ScrollState
    let home: Date
    let now: Date
    let length: TimeInterval
    let enabled: Bool
    let reduceMotion: Bool
    @ViewBuilder let content: (_ away: Bool) -> Content

    var body: some View {
        let position = scroll.x
        let away = enabled && !(position...(position + length)).contains(now)
        HStack(spacing: 8) {
            content(away)
            Spacer(minLength: 0)
            if away { button }
        }
    }

    private var button: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.35)) { scroll.jump(to: home) }
        } label: {
            Label("Now", systemImage: now < scroll.x ? "chevron.left" : "chevron.right")
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

/// The chart's scroll position, observed only where it's shown. The chart
/// reads and writes `chartX`, which nothing observes, so scrolling doesn't
/// re-run `TideLineChart.body` (and rebuild thousands of marks) every frame;
/// `x` mirrors it for `ScrollHome`. The chart only re-reads its position when
/// its view updates, so moving it from code goes through `jump(to:)`, which
/// also bumps `jumps`, a value `TideLineChart.body` does observe, or, for a
/// new window or forecast, through `rehome` during that body pass.
@Observable
private final class ScrollState {
    struct Home: Equatable {
        let window: TideLineChart.Window
        let issued: Date
    }

    @ObservationIgnored private var chartX: Date
    /// The position the chart last read. It scrolls only when the binding's
    /// value differs from this, not from where it has since been scrolled.
    @ObservationIgnored private var lastRead: Date
    private(set) var x: Date
    private(set) var jumps = 0
    @ObservationIgnored private var home: Home

    init(_ x: Date, home: Home) {
        chartX = x
        lastRead = x
        self.x = x
        self.home = home
    }

    /// Moves the chart to `date` when `home` changes, from the body. It has
    /// to land in the same pass as the window change: one pass later the
    /// chart's own window animation wins and it stays put. `show(_:)` then
    /// updates the "Now" row, which can't change during the body.
    func rehome(_ home: Home, to date: Date) {
        guard home != self.home else { return }
        self.home = home
        chartX = date == lastRead ? date + 0.001 : date
    }

    func show(_ date: Date) {
        x = date
    }

    func jump(to date: Date) {
        // Jumping back to the value the chart last read would look like no
        // change to it; a millisecond off is the same place on screen.
        chartX = date == lastRead ? date + 0.001 : date
        x = date
        jumps += 1
    }

    var chartBinding: Binding<Date> {
        Binding(get: {
            self.lastRead = self.chartX
            return self.chartX
        }, set: {
            self.chartX = $0
            self.x = $0
        })
    }
}

/// The last `Series` built, so a body pass that doesn't change its inputs
/// (scrubbing, a jump) reuses it. Plain class: storing into it mustn't
/// invalidate the view.
private final class SeriesCache {
    private var key: TideLineChart.SeriesKey?
    private var value: TideLineChart.Series?

    func series(for key: TideLineChart.SeriesKey) -> TideLineChart.Series? {
        key == self.key ? value : nil
    }

    func store(_ series: TideLineChart.Series, for key: TideLineChart.SeriesKey) {
        self.key = key
        value = series
    }
}

/// The "now" marker riding the tide line.
private struct NowDot: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.harbor.opacity(0.15)).frame(width: 18, height: 18)
            Circle().fill(Theme.surface).frame(width: 10, height: 10)
            Circle().strokeBorder(Theme.harbor, lineWidth: 2.4).frame(width: 11, height: 11)
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

/// The scrubbed moment, written by the chart's selection gesture. The chart
/// reads and writes `chartValue`, which nothing observes, so a scrub doesn't
/// re-run `TideLineChart.body`; `date` mirrors it for the cursor and readout.
@Observable
private final class SelectionState {
    @ObservationIgnored private var chartValue: Date?
    private(set) var date: Date?

    var chartBinding: Binding<Date?> {
        Binding(get: { self.chartValue }, set: {
            self.chartValue = $0
            self.date = $0
        })
    }
}

/// The scrub line and a dot on the curve, drawn over the chart rather than
/// as chart marks, so moving them redraws two shapes instead of the chart.
private struct SelectionCursor: View {
    let selection: SelectionState
    let proxy: ChartProxy
    let level: (Date) -> Double?

    var body: some View {
        GeometryReader { geo in
            if let date = selection.date, let anchor = proxy.plotFrame,
               let x = proxy.position(forX: date) {
                let plot = geo[anchor]
                let px = plot.minX + x
                if px >= plot.minX - 1, px <= plot.maxX + 1 {
                    Rectangle()
                        .fill(Theme.ink.opacity(0.35))
                        .frame(width: 1, height: plot.height)
                        .position(x: px, y: plot.midY)
                    if let v = level(date), let y = proxy.position(forY: v) {
                        Circle()
                            .fill(Theme.surface)
                            .overlay(Circle().strokeBorder(Theme.ink.opacity(0.7), lineWidth: 2))
                            .frame(width: 10, height: 10)
                            .position(x: px, y: plot.minY + y)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
