import SwiftUI
import TideKit

// MARK: - Next tides

/// Four columns of upcoming highs and lows between hairlines.
struct NextTidesGrid: View {
    let events: [ForecastEvent]
    let unit: LengthUnit
    let tz: TimeZone
    let now: Date

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(events.prefix(4).enumerated()), id: \.element.id) { index, e in
                    HStack(spacing: 0) {
                        if index > 0 { Rectangle().fill(Theme.hairline).frame(width: 1) }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(label(e)).font(.caption).foregroundStyle(Theme.inkSecondary)
                            Text(Fmt.time(e.date, in: tz)).font(.subheadline.weight(.semibold))
                            Text(Fmt.length(e.total, unit)).font(.rowValue).monospacedDigit()
                        }
                        .padding(.leading, index > 0 ? 10 : 0)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Hairline()
        }
    }

    private func label(_ e: ForecastEvent) -> String {
        var cal = Calendar.current
        cal.timeZone = tz
        let name = Phrase.eventName(e.kind)
        return cal.isDate(e.date, inSameDayAs: now) ? name : "\(name) · \(e.date.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated)))"
    }
}

// MARK: - Flood outlook

/// "Highest water X, Y below minor flooding" with a ruler from 0 to past the
/// flood level.
struct FloodOutlookSection: View {
    let forecast: WaterLevelForecast
    let peak: ForecastEvent?
    let unit: LengthUnit
    let tz: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let peak, let minor = forecast.thresholds?.minor {
                let margin = minor - peak.total
                (Text("Highest water ") + Text(Fmt.length(peak.total, unit)).fontWeight(.semibold)
                    + Text(" \(Fmt.dayName(peak.date, in: tz, relativeTo: forecast.issued).lowercasedIfToday) at \(Fmt.time(peak.date, in: tz)), ")
                    + Text("\(Fmt.length(abs(margin), unit)) \(margin >= 0 ? "below" : "above")").fontWeight(.semibold)
                    + Text(" minor flooding."))
                    .font(.body)
                FloodRuler(peak: peak.total, minor: minor, moderate: forecast.thresholds?.moderate,
                           floor: min(0, forecast.total.minimum?.value ?? 0), unit: unit)
                let p = peak.exceedance[.minor] ?? 0
                Text("\(Fmt.percent(p)) chance of minor flooding at that high tide. \(forecast.thresholds?.authority ?? "NWS") minor flood level \(Fmt.length(minor, unit)).")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            } else {
                if let peak {
                    (Text("Highest water ") + Text(Fmt.length(peak.total, unit)).fontWeight(.semibold)
                        + Text(" \(Fmt.dayName(peak.date, in: tz, relativeTo: forecast.issued).lowercasedIfToday) at \(Fmt.time(peak.date, in: tz))."))
                        .font(.body)
                }
                Text("No flood levels are published for this station.")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }
}

private extension String {
    /// "Today" reads better lower-cased mid-sentence.
    var lowercasedIfToday: String { self == "Today" || self == "Tomorrow" ? lowercased() : "on \(self)" }
}

struct FloodRuler: View {
    let peak: Double
    let minor: Double
    let moderate: Double?
    let floor: Double
    let unit: LengthUnit

    var body: some View {
        let top = max(peak, moderate ?? minor) + max((minor - floor) * 0.12, 0.1)
        let span = max(top - floor, 0.01)
        let peakFrac = min(max((peak - floor) / span, 0), 1)
        let minorFrac = min(max((minor - floor) / span, 0), 1)
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Capsule().fill(Theme.neutralWash).frame(height: 8).offset(y: 18)
                Capsule().fill(FloodCategory.minor.wash)
                    .frame(width: w * (1 - minorFrac), height: 8)
                    .offset(x: w * minorFrac, y: 18)
                Capsule().fill(peak >= minor ? Theme.swell : Theme.harbor)
                    .frame(width: max(w * peakFrac, 8), height: 8)
                    .offset(y: 18)
                RoundedRectangle(cornerRadius: 1).fill(Theme.ink)
                    .frame(width: 2, height: 20)
                    .offset(x: w * peakFrac - 1, y: 12)
                Text(Fmt.length(floor, unit)).font(.caption2).foregroundStyle(Theme.inkSecondary).offset(y: 32)
                Text("Minor").font(.caption2).foregroundStyle(Theme.floodText)
                    .fixedSize()
                    .offset(x: min(w * minorFrac - 14, w - 36), y: 32)
            }
        }
        .frame(height: 48)
        .accessibilityElement()
        .accessibilityLabel("Highest water \(Fmt.length(peak, unit)), minor flood level \(Fmt.length(minor, unit))")
    }
}

// MARK: - Why the water is high

/// Diverging bars: what pushes the water above or below the tide table.
struct DriverBars: View {
    let point: SurgeForecastPoint
    let unit: LengthUnit

    private struct Row: Identifiable {
        var id: String { label }
        let label: String
        let value: Double
    }

    private var rows: [Row] {
        var out = [
            Row(label: "Background sea level", value: point.offsetComponent),
            Row(label: "Recent trend", value: point.persistenceComponent),
            Row(label: "Tide–surge interaction", value: point.tideInteractionComponent),
            Row(label: "Wind", value: point.windComponent),
            Row(label: "Air pressure", value: point.pressureComponent),
        ]
        let modelSum = out.reduce(0) { $0 + $1.value }
        if point.officialWeight > 0.05 {
            out.append(Row(label: "NWS forecast adjustment", value: point.surge - modelSum))
        }
        return out.filter { abs($0.value) >= 0.005 }
    }

    var body: some View {
        let scale = max(rows.map { abs($0.value) }.max() ?? 0.1, 0.1)
        VStack(spacing: 10) {
            ForEach(rows) { r in
                HStack(spacing: 10) {
                    Text(r.label).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    DivergingBar(fraction: r.value / scale, color: r.value >= 0 ? Theme.swellDot : Theme.harbor)
                        .frame(width: 120, height: 14)
                    Text(Fmt.length(r.value, unit, signed: true))
                        .font(.subheadline.monospacedDigit())
                        .frame(width: 72, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
            Hairline()
            HStack {
                Text(point.surge >= 0 ? "Above the tide table" : "Below the tide table").font(.subheadline.weight(.semibold))
                Spacer()
                Text(Fmt.length(point.surge, unit, signed: true)).font(.subheadline.weight(.semibold).monospacedDigit())
            }
        }
    }
}

private struct DivergingBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let half = geo.size.width / 2
            let len = half * min(abs(fraction), 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.hairline).frame(width: 1, height: geo.size.height).offset(x: half)
                Capsule().fill(color)
                    .frame(width: max(len, 2), height: 6)
                    .offset(x: fraction >= 0 ? half : half - len)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - All tides

struct AllTidesView: View {
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone

    private var days: [(day: String, events: [ForecastEvent])] {
        var cal = Calendar.current
        cal.timeZone = tz
        let groups = Dictionary(grouping: forecast.events) { cal.startOfDay(for: $0.date) }
        return groups.keys.sorted().map { key in
            (Fmt.dayName(key, in: tz, relativeTo: forecast.issued), groups[key]!.sorted { $0.date < $1.date })
        }
    }

    var body: some View {
        List {
            ForEach(days, id: \.day) { group in
                Section(group.day) {
                    ForEach(group.events) { e in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(Phrase.eventName(e.kind)) \(Fmt.time(e.date, in: tz))").font(.body.weight(.semibold))
                                Text("Tide table \(Fmt.length(e.astronomical, unit)) · \(Fmt.length(e.surge, unit, signed: true))")
                                    .font(.caption).foregroundStyle(Theme.inkSecondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Fmt.length(e.total, unit)).font(.rowValue).monospacedDigit()
                                Text("\(Fmt.length(e.lower80, unit))–\(Fmt.length(e.upper80, unit))")
                                    .font(.caption2).foregroundStyle(Theme.inkSecondary).monospacedDigit()
                            }
                            if e.kind == .high, e.category > .none || (e.exceedance[.minor] ?? 0) >= 0.05 {
                                FloodBadge(category: e.category, probability: e.exceedance[.minor])
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.mist)
        .navigationTitle("Tides")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - How this forecast works

struct ForecastDetailsView: View {
    let result: ForecastResult
    let unit: LengthUnit
    let tz: TimeZone

    var body: some View {
        let f = result.forecast
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("The method")
                    Text("Tide predictions are computed on this phone from NOAA's harmonic constants for the station. They match NOAA's own tide tables to within a millimetre.")
                    Text("The difference between the measured water and the tide table is the surge. A model trained on this station's last 30 days links it to air pressure, wind and the tide itself, then carries today's anomaly forward.")
                    if f.surge.contains(where: { $0.officialWeight > 0 }) {
                        Text("Where the National Weather Service issues its own coastal forecast, the two are blended, each weighted by its recent accuracy.")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Theme.ink)

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Water above the tide table")
                    SurgeChartView(forecast: f, unit: unit, tz: tz)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Model")
                    ModelDiagnosticsView(forecast: f, unit: unit)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Data sources")
                    SourcesView(result: result, notes: f.notes)
                }

                Text("Forecasts are guidance only and not for navigation. Always follow official warnings.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(Theme.margin)
        }
        .background(Theme.surface)
        .navigationTitle("How this forecast works")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ModelDiagnosticsView: View {
    let forecast: WaterLevelForecast
    let unit: LengthUnit

    var body: some View {
        let d = forecast.model
        VStack(alignment: .leading, spacing: 10) {
            Label(methodDescription, systemImage: d.calibrated ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(d.calibrated ? Theme.ink : FloodCategory.minor.tint)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                if let m = d.hindcast24hRMS, let p = d.persistence24hRMS {
                    item("24 h error (out of sample)", "\(Fmt.length(m, unit)) vs \(Fmt.length(p, unit)) persistence")
                }
                if let r2 = d.rSquared { item("Variance explained", Fmt.percent(max(r2, 0))) }
                if let ib = d.inverseBarometerCmPerHPa { item("Pressure response", String(format: "%.2f cm per hPa (theory −0.99)", ib)) }
                if let dir = d.dominantWindDirection { item("Wind raising water most", "from \(Fmt.compass(dir)) (\(Int(dir))°)") }
                if d.persistenceEFoldingHours.isFinite && d.persistenceEFoldingHours > 0 {
                    item("Anomaly memory", String(format: "%.0f h", d.persistenceEFoldingHours))
                }
                if d.modelWeight < 1 { item("Weight on regression", Fmt.percent(d.modelWeight)) }
                if let s = d.trainingStart, let e = d.trainingEnd {
                    item("Calibrated on", "\(s.formatted(date: .abbreviated, time: .omitted)) – \(e.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        }
    }

    private var methodDescription: String {
        switch forecast.method {
        case .calibrated: return "Calibrated to this station" + (forecast.model.usesTideInteraction ? ", with tide interaction" : "")
        case .uncalibrated: return "Uncalibrated: no recent observations"
        case .persistenceOnly: return "Persistence only: no weather data"
        }
    }

    private func item(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.footnote).foregroundStyle(Theme.inkSecondary)
            Text(value).font(.footnote)
        }
    }
}

struct SourcesView: View {
    let result: ForecastResult?
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.footnote).foregroundStyle(Theme.ink)
            }
            if let result {
                ForEach(result.sources) { s in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: s.ok ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(s.ok ? Theme.harbor : FloodCategory.moderate.tint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(DataSourceInfo.info(s.source).name), \(s.component)").font(.footnote)
                            if let m = s.message { Text(m).font(.caption2).foregroundStyle(Theme.inkSecondary) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                let used = Set(result.sources.filter(\.ok).map(\.source))
                ForEach(DataSourceInfo.all.filter { used.contains($0.id) }) { info in
                    Text(info.attribution).font(.caption2).foregroundStyle(Theme.inkSecondary)
                }
            }
        }
    }
}
