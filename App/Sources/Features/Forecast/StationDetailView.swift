import SwiftUI
import TideKit

struct StationDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @State private var model: ForecastViewModel

    init(station: Station) {
        _model = State(initialValue: ForecastViewModel(station: station))
    }

    private var station: Station { model.station }
    private var tz: TimeZone { station.timeZone }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let f = model.forecast {
                    content(f)
                } else if case .failed(let message) = model.phase {
                    ContentUnavailableView {
                        Label("Forecast unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") { Task { await reload() } }
                    }
                    .padding(.top, 60)
                } else {
                    ProgressView("Building forecast…\nTide · observations · weather · official guidance")
                        .multilineTextAlignment(.center)
                        .padding(.top, 80)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    settings.toggleFavorite(station)
                } label: {
                    Image(systemName: settings.isFavorite(station) ? "star.fill" : "star")
                }
                .accessibilityLabel(settings.isFavorite(station) ? "Remove favorite" : "Add favorite")
            }
            ToolbarItem(placement: .status) {
                if model.phase == .loading && model.forecast != nil { ProgressView().controlSize(.small) }
            }
        }
        .refreshable { await reload() }
        .task(id: settings.forecastOptions) {
            await model.loadIfNeeded(service: env.service, options: settings.forecastOptions)
        }
    }

    private func reload() async {
        await env.service.api.clearCache()
        await model.load(service: env.service, options: settings.forecastOptions)
    }

    @ViewBuilder
    private func content(_ f: WaterLevelForecast) -> some View {
        if !f.alerts.isEmpty || !f.nearbyStorms.isEmpty {
            AlertsCard(alerts: f.alerts, storms: f.nearbyStorms, tz: tz)
        }
        NowCard(model: model, forecast: f, unit: settings.unit, tz: tz)
        FloodOutlookCard(forecast: f, peak: model.peakEvent, riskiest: model.riskiestEvent, unit: settings.unit, tz: tz)
        Card(title: "Water level", subtitle: "\(f.datum.displayName) (\(f.datum.rawValue))") {
            TideChartView(forecast: f, unit: settings.unit, tz: tz)
        }
        Card(title: "Storm surge", subtitle: "Non-tidal water level: observed and forecast") {
            SurgeChartView(forecast: f, unit: settings.unit, tz: tz)
            SurgeBreakdownView(forecast: f, unit: settings.unit, tz: tz)
        }
        Card(title: "Upcoming tides", subtitle: "Total = predicted tide + forecast surge, with 80% range") {
            EventsListView(events: f.events, unit: settings.unit, tz: tz, hasThresholds: f.thresholds != nil)
        }
        Card(title: "Model & skill") {
            ModelDiagnosticsView(forecast: f, unit: settings.unit)
        }
        Card(title: "Data sources") {
            SourcesView(result: model.result, notes: f.notes)
        }
        Text("Forecasts are guidance only and not for navigation. Always follow official NWS / national agency warnings.")
            .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }
}

// MARK: - Cards

struct Card<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct NowCard: View {
    let model: ForecastViewModel
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone

    var body: some View {
        Card(title: "Now") {
            HStack(alignment: .firstTextBaseline) {
                if let obs = forecast.latestObservation, forecast.issued.timeIntervalSince(obs.date) < 3 * 3_600 {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.length(obs.value, unit)).font(.system(size: 40, weight: .semibold, design: .rounded))
                        Text("Observed \(Fmt.time(obs.date, in: tz))").font(.caption).foregroundStyle(.secondary)
                    }
                } else if let a = forecast.astronomical.value(at: forecast.issued) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Fmt.length(a, unit)).font(.system(size: 40, weight: .semibold, design: .rounded))
                        Text("Predicted (no live observations)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let rising = model.trendRising {
                    Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
                        .font(.title2).foregroundStyle(rising ? .blue : .teal)
                        .accessibilityLabel(rising ? "Rising" : "Falling")
                }
                Spacer()
                if let r = forecast.currentResidual {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.length(r.value, unit, signed: true)).font(.title3.weight(.semibold))
                            .foregroundStyle(abs(r.value) > 0.3 ? .orange : .primary)
                        Text("vs. predicted").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                ForEach(model.nextEvents) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.kind == .high ? "Next high" : "Next low").font(.caption).foregroundStyle(.secondary)
                        Text(Fmt.time(e.date, in: tz)).font(.subheadline.weight(.semibold))
                        Text(Fmt.length(e.total, unit)).font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct FloodOutlookCard: View {
    let forecast: WaterLevelForecast
    let peak: ForecastEvent?
    let riskiest: ForecastEvent?
    let unit: LengthUnit
    let tz: TimeZone

    var body: some View {
        Card(title: "Flood outlook", subtitle: "Next \(Int(forecast.horizon.timeIntervalSince(forecast.issued) / 3_600)) hours") {
            if let th = forecast.thresholds, let minor = th.minor {
                let p = forecast.maxMinorFloodProbability
                let category = forecast.peakCategory
                HStack(spacing: 12) {
                    Circle().fill(category.color).frame(width: 14, height: 14)
                    VStack(alignment: .leading) {
                        Text(category == .none ? (p >= 0.1 ? "Possible minor flooding" : "No flooding expected") : category.label)
                            .font(.title3.weight(.semibold))
                        if let r = riskiest, p >= 0.01 {
                            Text("\(Fmt.percent(p)) chance of minor flooding at the \(Fmt.dayTime(r.date, in: tz)) high tide")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                if let peak {
                    let margin = minor - peak.total
                    Text("Highest water: \(Fmt.length(peak.total, unit)) \(Fmt.dayTime(peak.date, in: tz)) — \(Fmt.length(abs(margin), unit)) \(margin >= 0 ? "below" : "above") minor flood stage (\(th.authority)).")
                        .font(.footnote)
                }
            } else {
                if let peak {
                    Text("Highest water: \(Fmt.length(peak.total, unit)) \(Fmt.dayTime(peak.date, in: tz))").font(.subheadline)
                }
                Text("No official flood thresholds are published for this station.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct AlertsCard: View {
    let alerts: [WeatherAlert]
    let storms: [TropicalCyclone]
    let tz: TimeZone
    @State private var expanded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(storms) { s in
                HStack(alignment: .top) {
                    Image(systemName: "hurricane").foregroundStyle(.white)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(s.classification) \(s.name) nearby").font(.headline).foregroundStyle(.white)
                        Text("Statistical surge guidance is unreliable in tropical cyclones. Follow NHC and local NWS products.")
                            .font(.footnote).foregroundStyle(.white.opacity(0.9))
                        if let url = s.advisoryURL { Link("NHC advisory", destination: url).font(.footnote.bold()).foregroundStyle(.white) }
                    }
                }
            }
            ForEach(alerts) { a in
                VStack(alignment: .leading, spacing: 4) {
                    Label(a.event, systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.white)
                    if let h = a.headline { Text(h).font(.footnote).foregroundStyle(.white.opacity(0.9)) }
                    if expanded == a.id {
                        if let d = a.description { Text(d).font(.footnote).foregroundStyle(.white) }
                        if let i = a.instruction { Text(i).font(.footnote.bold()).foregroundStyle(.white) }
                    }
                    Button(expanded == a.id ? "Less" : "Details") { expanded = expanded == a.id ? nil : a.id }
                        .font(.footnote.bold()).foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 16))
    }
}
