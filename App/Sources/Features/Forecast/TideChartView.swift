import Charts
import SwiftUI
import TideKit

/// The signature "tide line": full-bleed water level with the observed past,
/// the forecast and its 80 % range, the tide table, the flood level and a
/// "now" dot. Scrub to read any moment.
struct TideLineChart: View {
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone

    enum Window: String, CaseIterable, Identifiable {
        case day = "Today", twoDays = "2 days", week = "All"
        var id: String { rawValue }
    }

    @State private var window: Window = .day
    @State private var selection: Date?
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

    enum Layer: String, CaseIterable {
        case water = "Water", band = "Range", flooding = "Above flood level"
        case predicted = "Tide table", forecast = "Forecast", observed = "Observed"
    }

    private var calendar: Calendar {
        var c = Calendar.current
        c.timeZone = tz
        return c
    }

    private var domain: ClosedRange<Date> {
        let now = forecast.issued
        switch window {
        case .day:
            let start = calendar.startOfDay(for: now)
            // Late in the day, keep the next few hours in view.
            let end = max(start + 86_400, now + 6 * 3_600)
            return start...min(end, forecast.horizon)
        case .twoDays:
            return (now - 6 * 3_600)...min(now + 42 * 3_600, forecast.horizon)
        case .week:
            return (now - 12 * 3_600)...forecast.horizon
        }
    }

    // MARK: Data

    /// Everything the chart draws, built once per body pass (scrubbing
    /// re-runs the body on every move).
    struct Series {
        let domain: ClosedRange<Date>
        let observed: [Point]
        let forecast: [Point]
        let predicted: [Point]
        let band: [Band]
        let waterline: [Point]
        let yDomain: ClosedRange<Double>
        let minor: Double?
        let ticks: [Date]
    }

    private func makeSeries() -> Series {
        let d = domain
        func pts(_ s: TimeSeries, _ layer: Layer, maxPoints: Int = 400) -> [Point] {
            let inside = s.points.filter { d.contains($0.date) }
            let stride = Swift.max(1, inside.count / maxPoints)
            return inside.enumerated().compactMap { i, p in
                i % stride == 0
                    ? Point(id: "\(layer.rawValue)\(p.date.timeIntervalSince1970)", date: p.date, value: unit.fromMeters(p.value))
                    : nil
            }
        }
        let obs = pts(forecast.observed, .observed)
        let fc = pts(forecast.total, .forecast)
        let pred = pts(forecast.astronomical, .predicted, maxPoints: 300)
        let band = zip(forecast.totalLower.points, forecast.totalUpper.points)
            .filter { d.contains($0.0.date) }
            .map { Band(date: $0.0.date, low: unit.fromMeters($0.0.value), high: unit.fromMeters($0.1.value)) }
        let cut = fc.first?.date ?? forecast.issued
        let water = obs.filter { $0.date < cut } + fc
        let minor = forecast.thresholds?.minor.map(unit.fromMeters)

        var yd: ClosedRange<Double> = 0...1
        let values = (water + pred).map(\.value) + band.flatMap { [$0.low, $0.high] }
        if var lo = values.min(), var hi = values.max(), lo < hi {
            if let minor, minor - hi < (hi - lo) * 0.6 { hi = Swift.max(hi, minor) }
            let pad = (hi - lo) * 0.1
            lo -= pad
            hi += pad
            yd = lo...hi
        }

        let step = window == .week ? 24 : (window == .twoDays ? 12 : 6)
        var ticks: [Date] = []
        var t = calendar.startOfDay(for: d.lowerBound)
        while t <= d.upperBound {
            if t >= d.lowerBound { ticks.append(t) }
            t = calendar.date(byAdding: .hour, value: step, to: t) ?? t + Double(step) * 3_600
        }
        // Only draw the flood rule when it falls inside the plot.
        let visibleMinor = minor.flatMap { yd.contains($0) ? $0 : nil }
        return Series(domain: d, observed: obs, forecast: fc, predicted: pred, band: band, waterline: water,
                      yDomain: yd, minor: visibleMinor, ticks: ticks)
    }

    private func tickLabel(_ d: Date) -> String {
        if window == .week {
            return d.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated))
        }
        return d.formatted(Date.FormatStyle(timeZone: tz).hour())
    }

    private static let layerColors: [Color] = [
        Theme.harbor.opacity(0.08), Theme.swellBand.opacity(0.24), Theme.floodLine.opacity(0.3),
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
        let series = makeSeries()
        VStack(alignment: .leading, spacing: 10) {
            chart(series)
                .frame(height: 210)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: window)
                .accessibilityLabel("Water level chart")
                .accessibilityValue(accessibilitySummary(series.domain))

            Group {
                if let selection {
                    SelectionReadout(forecast: forecast, date: selection, unit: unit, tz: tz)
                } else {
                    legend
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
            if let minor = s.minor {
                ForEach(s.forecast) { p in
                    AreaMark(x: .value("Time", p.date), yStart: .value("Flood", minor), yEnd: .value("Level", Swift.max(p.value, minor)))
                        .foregroundStyle(by: .value("Layer", Layer.flooding.rawValue))
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("Minor flood", minor))
                    .foregroundStyle(Theme.floodLine.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("Minor flood \(Fmt.length(unit.toMeters(minor), unit))")
                            .font(.caption2)
                            .foregroundStyle(Theme.floodText)
                            .padding(.trailing, Theme.margin)
                    }
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
            if let selection {
                RuleMark(x: .value("Selected", selection))
                    .foregroundStyle(Theme.ink.opacity(0.35))
            }
        }
        .chartForegroundStyleScale(domain: Layer.allCases.map(\.rawValue), range: Self.layerColors)
        .chartLegend(.hidden)
        .chartXScale(domain: s.domain)
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
        .chartXSelection(value: $selection)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            LegendSwatch(color: Theme.harbor, label: "Observed")
            LegendSwatch(color: Theme.swell, label: "Forecast · 80% range")
            LegendSwatch(color: Theme.tideTable, label: "Tide table", dashed: true)
        }
    }

    private func accessibilitySummary(_ domain: ClosedRange<Date>) -> String {
        guard let peak = forecast.total.sliced(from: domain.lowerBound, to: domain.upperBound).maximum else { return "" }
        return "Highest forecast \(Fmt.length(peak.value, unit)) at \(Fmt.smartTime(peak.date, in: tz))."
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

    var body: some View {
        Chart {
            ForEach(forecast.surge) { s in
                AreaMark(x: .value("Time", s.date),
                         yStart: .value("Low", unit.fromMeters(s.surge - 1.2816 * s.sigma)),
                         yEnd: .value("High", unit.fromMeters(s.surge + 1.2816 * s.sigma)))
                    .foregroundStyle(by: .value("Layer", "Range"))
            }
            ForEach(forecast.observedResidual.points, id: \.date) { p in
                LineMark(x: .value("Time", p.date), y: .value("Surge", unit.fromMeters(p.value)), series: .value("Series", "Observed"))
                    .foregroundStyle(by: .value("Layer", "Observed"))
            }
            ForEach(forecast.surge) { s in
                LineMark(x: .value("Time", s.date), y: .value("Surge", unit.fromMeters(s.surge)), series: .value("Series", "Forecast"))
                    .foregroundStyle(by: .value("Layer", "Forecast"))
            }
            ForEach(forecast.surge.filter { $0.officialSurge != nil }) { s in
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
