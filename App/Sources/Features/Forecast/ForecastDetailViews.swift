import SwiftUI
import TideKit

struct EventsListView: View {
    let events: [ForecastEvent]
    let unit: LengthUnit
    let tz: TimeZone
    let hasThresholds: Bool
    @State private var showAll = false

    var body: some View {
        let shown = showAll ? events : Array(events.prefix(8))
        VStack(spacing: 0) {
            ForEach(shown) { e in
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: e.kind == .high ? "arrow.up.to.line" : "arrow.down.to.line")
                        .foregroundStyle(e.kind == .high ? .blue : .teal)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Fmt.dayTime(e.date, in: tz)).font(.subheadline.weight(.medium))
                        Text("tide \(Fmt.length(e.astronomical, unit)) · surge \(Fmt.length(e.surge, unit, signed: true))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Fmt.length(e.total, unit)).font(.subheadline.weight(.semibold)).monospacedDigit()
                        Text("\(Fmt.length(e.lower80, unit, signed: false))–\(Fmt.length(e.upper80, unit))")
                            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if hasThresholds && e.kind == .high {
                        RiskBadge(event: e).frame(width: 64, alignment: .trailing)
                    }
                }
                .padding(.vertical, 6)
                .accessibilityElement(children: .combine)
                Divider()
            }
            if events.count > 8 {
                Button(showAll ? "Show fewer" : "Show all \(events.count)") { withAnimation { showAll.toggle() } }
                    .font(.footnote).padding(.top, 8)
            }
        }
    }
}

struct RiskBadge: View {
    let event: ForecastEvent

    var body: some View {
        let p = event.exceedance[.minor] ?? 0
        let category = event.category
        if category > .none || p >= 0.05 {
            Text(category > .none ? category.shortLabel : Fmt.percent(p))
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background((category > .none ? category.color : FloodCategory.minor.color).opacity(0.2), in: Capsule())
                .foregroundStyle(category > .none ? category.color : .orange)
                .accessibilityLabel(category > .none ? category.label : "\(Fmt.percent(p)) chance of minor flooding")
        }
    }
}

/// What drives the surge: pressure, wind, tide interaction, persistence.
struct SurgeBreakdownView: View {
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone

    var body: some View {
        // Show the hour with the largest weather-driven surge.
        if let p = forecast.surge.max(by: { abs($0.pressureComponent + $0.windComponent) < abs($1.pressureComponent + $1.windComponent) }) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Peak weather-driven surge \(Fmt.dayTime(p.date, in: tz))").font(.subheadline.weight(.semibold))
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    row("Pressure (inverse barometer)", p.pressureComponent)
                    row("Wind set-up / set-down", p.windComponent)
                    row("Tide–surge interaction", p.tideInteractionComponent)
                    row("Mean sea level anomaly", p.offsetComponent)
                    row("Persistence of current anomaly", p.persistenceComponent)
                    if let o = p.officialSurge {
                        row("NWS official guidance (weight \(Fmt.percent(p.officialWeight)))", o)
                    }
                    Divider()
                    GridRow {
                        Text("Forecast surge").font(.footnote.bold())
                        Text("\(Fmt.length(p.surge, unit, signed: true)) ± \(Fmt.length(1.2816 * p.sigma, unit))")
                            .font(.footnote.bold()).monospacedDigit()
                    }
                }
            }
        }
    }

    private func row(_ label: String, _ value: Double) -> some View {
        GridRow {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Text(Fmt.length(value, unit, signed: true)).font(.footnote).monospacedDigit()
        }
    }
}

struct ModelDiagnosticsView: View {
    let forecast: WaterLevelForecast
    let unit: LengthUnit

    var body: some View {
        let d = forecast.model
        VStack(alignment: .leading, spacing: 8) {
            Label(methodDescription, systemImage: d.calibrated ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(d.calibrated ? Color.primary : Color.orange)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                if let m = d.hindcast24hRMS, let p = d.persistence24hRMS {
                    item("24 h error (out of sample)", "\(Fmt.length(m, unit)) vs \(Fmt.length(p, unit)) persistence")
                }
                if let s = d.skillVsPersistence { item("Skill vs persistence", Fmt.percent(max(s, 0))) }
                if let r2 = d.rSquared { item("Variance explained (R²)", Fmt.percent(r2)) }
                if let ib = d.inverseBarometerCmPerHPa { item("Pressure response", String(format: "%.2f cm/hPa (theory −0.99)", ib)) }
                if let dir = d.dominantWindDirection { item("Wind raising water most", "from \(Fmt.compass(dir)) (\(Int(dir))°)") }
                if d.persistenceEFoldingHours.isFinite && d.persistenceEFoldingHours > 0 {
                    item("Anomaly memory", String(format: "%.0f h e-folding", d.persistenceEFoldingHours))
                }
                if d.modelWeight < 1 { item("Regression weight", Fmt.percent(d.modelWeight)) }
                if let s = d.trainingStart, let e = d.trainingEnd {
                    item("Calibrated on", "\(d.trainingHours) h, \(s.formatted(date: .abbreviated, time: .omitted))–\(e.formatted(date: .abbreviated, time: .omitted))")
                }
            }
        }
    }

    private var methodDescription: String {
        switch forecast.method {
        case .calibrated: return "Station-calibrated surge model" + (forecast.model.usesTideInteraction ? " with tide interaction" : "")
        case .uncalibrated: return "Uncalibrated (no recent observations)"
        case .persistenceOnly: return "Persistence only (no weather data)"
        }
    }

    private func item(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.footnote)
        }
    }
}

struct SourcesView: View {
    let result: ForecastResult?
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(notes, id: \.self) { n in
                Label(n, systemImage: "info.circle").font(.footnote)
            }
            if let result {
                ForEach(result.sources) { s in
                    HStack(alignment: .top) {
                        Image(systemName: s.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(s.ok ? .green : .red)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(DataSourceInfo.info(s.source).name) — \(s.component)").font(.footnote)
                            if let m = s.message { Text(m).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                let used = Set(result.sources.filter(\.ok).map(\.source))
                ForEach(DataSourceInfo.all.filter { used.contains($0.id) }) { info in
                    Text(info.attribution).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
