import Charts
import SwiftUI
import TideKit

/// Total water level chart: predicted tide, observations, probabilistic
/// forecast, official NWS guidance and flood thresholds.
struct TideChartView: View {
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone

    enum Window: String, CaseIterable, Identifiable {
        case day = "24h", threeDays = "3d", all = "All"
        var id: String { rawValue }
    }

    @State private var window: Window = .threeDays
    @State private var selection: Date?

    struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let value: Double
        let series: Series
    }

    struct BandPoint: Identifiable {
        var id: Date { date }
        let date: Date
        let lo: Double
        let hi: Double
    }

    struct Threshold: Identifiable {
        var id: FloodCategory { category }
        let category: FloodCategory
        let value: Double
    }

    enum Series: String {
        case predicted = "Predicted tide"
        case observed = "Observed"
        case forecast = "Forecast"
        case official = "NWS official"
    }

    private var domain: ClosedRange<Date> {
        let start = forecast.issued - (window == .all ? 48 : 12) * 3_600
        let end: Date
        switch window {
        case .day: end = forecast.issued + 24 * 3_600
        case .threeDays: end = forecast.issued + 72 * 3_600
        case .all: end = forecast.horizon
        }
        return start...min(end, forecast.horizon)
    }

    private var points: [Point] {
        let d = domain
        func pts(_ s: TimeSeries, _ series: Series, stride: Int = 1) -> [Point] {
            s.points.enumerated()
                .filter { $0.offset % stride == 0 && d.contains($0.element.date) }
                .map { Point(date: $0.element.date, value: unit.fromMeters($0.element.value), series: series) }
        }
        let obsStride = max(1, forecast.observed.count / 400)
        return pts(forecast.astronomical, .predicted, stride: 2)
            + pts(forecast.observed, .observed, stride: obsStride)
            + pts(forecast.total, .forecast)
            + (forecast.officialTotal.map { pts($0, .official) } ?? [])
    }

    private var band: [BandPoint] {
        zip(forecast.totalLower.points, forecast.totalUpper.points)
            .filter { domain.contains($0.0.date) }
            .map { BandPoint(date: $0.0.date, lo: unit.fromMeters($0.0.value), hi: unit.fromMeters($0.1.value)) }
    }

    private var thresholds: [Threshold] {
        guard let t = forecast.thresholds else { return [] }
        return [FloodCategory.minor, .moderate, .major].compactMap { c in
            t.threshold(for: c).map { Threshold(category: c, value: unit.fromMeters($0)) }
        }
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value) + band.flatMap { [$0.lo, $0.hi] }
        guard var lo = values.min(), var hi = values.max() else { return 0...1 }
        // Show the minor threshold when it is reasonably close to the data.
        if let minor = thresholds.first?.value, minor - hi < (hi - lo) * 0.6 { hi = max(hi, minor) }
        let pad = (hi - lo) * 0.08
        lo -= pad
        hi += pad
        return lo...hi
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: $window) {
                ForEach(Window.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            Chart {
                ForEach(band) { b in
                    AreaMark(x: .value("Time", b.date), yStart: .value("Low", b.lo), yEnd: .value("High", b.hi))
                        .foregroundStyle(Color.orange.opacity(0.18))
                }
                ForEach(points) { p in
                    LineMark(x: .value("Time", p.date), y: .value("Level", p.value))
                        .foregroundStyle(by: .value("Series", p.series.rawValue))
                        .lineStyle(style(for: p.series))
                        .interpolationMethod(.monotone)
                }
                ForEach(thresholds) { t in
                    RuleMark(y: .value("Threshold", t.value))
                        .foregroundStyle(t.category.color)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("\(t.category.shortLabel) flood").font(.caption2).foregroundStyle(t.category.color)
                        }
                }
                RuleMark(x: .value("Now", forecast.issued))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                if let selection {
                    RuleMark(x: .value("Selected", selection))
                        .foregroundStyle(Color.primary.opacity(0.4))
                        .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            ChartTooltip(forecast: forecast, date: selection, unit: unit, tz: tz)
                        }
                }
            }
            .chartForegroundStyleScale([
                Series.predicted.rawValue: Color.gray,
                Series.observed.rawValue: Color.blue,
                Series.forecast.rawValue: Color.orange,
                Series.official.rawValue: Color.purple,
            ])
            .chartXScale(domain: domain)
            .chartYScale(domain: yDomain)
            .chartYAxisLabel(unit.symbol)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = value.as(Date.self) {
                            Text(d.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated).hour()))
                        }
                    }
                }
            }
            .chartXSelection(value: $selection)
            .chartLegend(position: .bottom, spacing: 8)
            .frame(height: 260)
        }
    }

    private func style(for s: Series) -> StrokeStyle {
        switch s {
        case .predicted: return StrokeStyle(lineWidth: 1.5, dash: [4, 3])
        case .observed: return StrokeStyle(lineWidth: 2)
        case .forecast: return StrokeStyle(lineWidth: 2.5)
        case .official: return StrokeStyle(lineWidth: 1.5, dash: [1, 3])
        }
    }

}

struct ChartTooltip: View {
    let forecast: WaterLevelForecast
    let date: Date
    let unit: LengthUnit
    let tz: TimeZone

    var body: some View {
        let astro = forecast.astronomical.value(at: date)
        let total = forecast.total.value(at: date, maxGap: 1_200)
        let obs = forecast.observed.value(at: date, maxGap: 1_200)
        VStack(alignment: .leading, spacing: 2) {
            Text(Fmt.dayTime(date, in: tz)).font(.caption.bold())
            if let obs { Text("Observed \(Fmt.length(obs, unit))").font(.caption2) }
            if let total { Text("Forecast \(Fmt.length(total, unit))").font(.caption2) }
            if let astro { Text("Tide \(Fmt.length(astro, unit))").font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Non-tidal residual: observed history and forecast with uncertainty.
struct SurgeChartView: View {
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone

    var body: some View {
        Chart {
            ForEach(forecast.surge) { s in
                AreaMark(x: .value("Time", s.date),
                         yStart: .value("Low", unit.fromMeters(s.surge - 1.2816 * s.sigma)),
                         yEnd: .value("High", unit.fromMeters(s.surge + 1.2816 * s.sigma)))
                    .foregroundStyle(Color.orange.opacity(0.18))
            }
            ForEach(forecast.observedResidual.points, id: \.date) { p in
                LineMark(x: .value("Time", p.date), y: .value("Surge", unit.fromMeters(p.value)))
                    .foregroundStyle(by: .value("Series", "Observed"))
            }
            ForEach(forecast.surge) { s in
                LineMark(x: .value("Time", s.date), y: .value("Surge", unit.fromMeters(s.surge)))
                    .foregroundStyle(by: .value("Series", "Forecast"))
            }
            ForEach(forecast.surge.filter { $0.officialSurge != nil }) { s in
                LineMark(x: .value("Time", s.date), y: .value("Surge", unit.fromMeters(s.officialSurge ?? 0)))
                    .foregroundStyle(by: .value("Series", "NWS official"))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [1, 3]))
            }
            RuleMark(y: .value("Zero", 0.0)).foregroundStyle(Color.secondary.opacity(0.5))
            RuleMark(x: .value("Now", forecast.issued)).foregroundStyle(.secondary)
        }
        .chartForegroundStyleScale(["Observed": Color.blue, "Forecast": Color.orange, "NWS official": Color.purple])
        .chartYAxisLabel(unit.symbol)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let d = value.as(Date.self) { Text(d.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated))) }
                }
            }
        }
        .chartLegend(position: .bottom)
        .frame(height: 180)
    }
}
