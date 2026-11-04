import Charts
import SwiftUI
import TideKit

/// One station day, hour by hour: a compact tide line for the day and an
/// hourly table of the water level, its 80 % range and the difference from
/// the tide table. Observed hours come first when the day has begun.
struct DayForecastView: View {
    let forecast: WaterLevelForecast
    let day: Date
    let unit: LengthUnit
    let tz: TimeZone

    @Environment(\.dismiss) private var dismiss
    @Environment(\.forecastNow) private var forecastNow
    private var now: Date { forecastNow ?? Date() }

    struct Hour: Identifiable {
        var id: Date { date }
        let date: Date
        let level: Double
        let table: Double?
        let low: Double?
        let high: Double?
        let observed: Bool
        let rising: Bool?
    }

    struct Sample: Identifiable {
        var id: String { "\(series)\(date.timeIntervalSince1970)" }
        let series: String
        let date: Date
        let value: Double
    }

    private var calendar: Calendar {
        var c = Calendar.current
        c.timeZone = tz
        return c
    }

    private var interval: DateInterval {
        calendar.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86_400)
    }

    private var isOutlook: Bool {
        forecast.weatherHorizon.map { interval.start > $0 } ?? false
    }

    // MARK: Data

    private func level(at t: Date) -> (value: Double, observed: Bool)? {
        if t <= forecast.issued, let o = forecast.observed.value(at: t, maxGap: 1_200) { return (o, true) }
        if let f = forecast.total.value(at: t, maxGap: 1_200) { return (f, false) }
        return nil
    }

    private var hours: [Hour] {
        (0..<25).compactMap { h -> Hour? in
            guard let t = calendar.date(byAdding: .hour, value: h, to: interval.start), t <= interval.end,
                  let l = level(at: t) else { return nil }
            let next = level(at: t + 600)?.value
            return Hour(date: t, level: l.value, table: forecast.astronomical.value(at: t),
                        low: l.observed ? nil : forecast.totalLower.value(at: t, maxGap: 1_200),
                        high: l.observed ? nil : forecast.totalUpper.value(at: t, maxGap: 1_200),
                        observed: l.observed, rising: next.map { $0 > l.value })
        }
        .filter { $0.date < interval.end }
    }

    private var events: [ForecastEvent] {
        forecast.events.filter { interval.contains($0.date) }
    }

    private var samples: (observed: [Sample], forecast: [Sample], table: [Sample], band: [(Date, Double, Double)]) {
        let r = interval.start...interval.end
        let u = unit
        func pts(_ s: TimeSeries, _ name: String, every n: Int = 1) -> [Sample] {
            s.points.filter { r.contains($0.date) }.enumerated().compactMap { i, p in
                i % n == 0 ? Sample(series: name, date: p.date, value: u.fromMeters(p.value)) : nil
            }
        }
        let band = zip(forecast.totalLower.points, forecast.totalUpper.points)
            .filter { r.contains($0.0.date) }
            .map { ($0.0.date, u.fromMeters($0.0.value), u.fromMeters($0.1.value)) }
        return (pts(forecast.observed, "Observed", every: 2), pts(forecast.total, "Forecast"), pts(forecast.astronomical, "Tide table"), band)
    }

    // MARK: Body

    var body: some View {
        let hours = hours
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summary(hours)
                    dayChart
                        .frame(height: 170)
                    VStack(spacing: 0) {
                        header
                        ForEach(hours) { h in
                            row(h)
                            if h.id != hours.last?.id { Divider().overlay(Theme.hairline) }
                        }
                    }
                    if isOutlook {
                        Text("Beyond the weather forecast: tide table plus this station's typical surge, with its usual range.")
                            .font(.footnote)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
                .padding(Theme.margin)
            }
            .background(Theme.surface)
            .navigationTitle(day.formatted(Date.FormatStyle(timeZone: tz).weekday(.wide).month(.abbreviated).day()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func summary(_ hours: [Hour]) -> some View {
        HStack(spacing: 8) {
            ForEach(events) { e in
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.kind == .high ? "High" : "Low").font(.caption).foregroundStyle(Theme.inkSecondary)
                    Text(Fmt.time(e.date, in: tz)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(Fmt.length(e.total, unit)).font(.subheadline.monospacedDigit())
                        .foregroundStyle(e.kind == .high ? Theme.swellText : Theme.ink)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.neutralWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var dayChart: some View {
        let s = samples
        return Chart {
            ForEach(Array(s.band.enumerated()), id: \.offset) { _, b in
                AreaMark(x: .value("Time", b.0), yStart: .value("Low", b.1), yEnd: .value("High", b.2))
                    .foregroundStyle(Theme.swellBand.opacity(0.24))
                    .interpolationMethod(.monotone)
            }
            ForEach(s.table) { p in
                LineMark(x: .value("Time", p.date), y: .value("Level", p.value), series: .value("Series", p.series))
                    .foregroundStyle(Theme.tideTable)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [3, 3]))
                    .interpolationMethod(.monotone)
            }
            ForEach(s.forecast) { p in
                LineMark(x: .value("Time", p.date), y: .value("Level", p.value), series: .value("Series", p.series))
                    .foregroundStyle(Theme.swell)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            ForEach(s.observed) { p in
                LineMark(x: .value("Time", p.date), y: .value("Level", p.value), series: .value("Series", p.series))
                    .foregroundStyle(Theme.harbor)
                    .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if interval.contains(now) {
                RuleMark(x: .value("Now", now)).foregroundStyle(Theme.ink.opacity(0.2))
            }
            ForEach(events) { e in
                PointMark(x: .value("Time", e.date), y: .value("Level", unit.fromMeters(e.total)))
                    .symbolSize(22)
                    .foregroundStyle(Theme.swell)
            }
        }
        .chartXScale(domain: interval.start...interval.end)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(.caption2)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 6, calendar: calendar)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d.formatted(Date.FormatStyle(timeZone: tz).hour())).font(.caption2)
                    }
                }
            }
        }
        .accessibilityLabel("Water level through the day")
    }

    private var header: some View {
        HStack {
            Text("Time").frame(width: 76, alignment: .leading)
            Spacer()
            Text("vs table").frame(width: 64, alignment: .trailing)
            Text("Range").frame(width: 92, alignment: .trailing)
            Text("Level").frame(width: 62, alignment: .trailing)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Theme.inkSecondary)
        .textCase(.uppercase)
        .padding(.bottom, 6)
    }

    private func row(_ h: Hour) -> some View {
        let isNow = abs(h.date.timeIntervalSince(now)) < 1_800
        return HStack {
            HStack(spacing: 6) {
                if let rising = h.rising {
                    Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(h.observed ? Theme.harbor : Theme.inkSecondary)
                }
                Text(h.date.formatted(Date.FormatStyle(timeZone: tz).hour()))
                    .fontWeight(isNow ? .semibold : .regular)
            }
            .frame(width: 76, alignment: .leading)
            Spacer()
            Text(h.table.map { Fmt.length(h.level - $0, unit, signed: true) } ?? "–")
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 64, alignment: .trailing)
            Text(h.low.flatMap { lo in h.high.map { "\(Fmt.length(lo, unit, digits: 1))–\(Fmt.length($0, unit, digits: 1))" } } ?? (h.observed ? "observed" : "–"))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: 92, alignment: .trailing)
            Text(Fmt.length(h.level, unit))
                .fontWeight(.semibold)
                .foregroundStyle(h.observed ? Theme.harbor : Theme.ink)
                .frame(width: 62, alignment: .trailing)
        }
        .font(.subheadline.monospacedDigit())
        .padding(.vertical, 8)
        .background(isNow ? Theme.neutralWash.opacity(0.7) : .clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Fmt.time(h.date, in: tz)), \(h.observed ? "observed" : "forecast") \(Fmt.length(h.level, unit))"
            + (h.table.map { ", \(Fmt.length(h.level - $0, unit, signed: true)) versus tide table" } ?? ""))
    }
}
