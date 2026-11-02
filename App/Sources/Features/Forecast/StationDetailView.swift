import SwiftUI
import TideKit

/// A station: the reading now and what the water will do next, with method
/// and sources one tap away.
@MainActor
struct StationDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @State private var model: ForecastViewModel

    init(station: Station) {
        _model = State(initialValue: ForecastViewModel(station: station))
    }

    private var station: Station { model.station }
    private var tz: TimeZone { station.timeZone }
    private var unit: LengthUnit { settings.unit }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                if let f = model.forecast {
                    content(f)
                } else if case .failed(let message) = model.phase {
                    ContentUnavailableView {
                        Label("Forecast unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await reload() } }
                            .buttonStyle(.bordered)
                    }
                    .padding(.top, 40)
                } else {
                    LoadingHero()
                }
            }
            .padding(.bottom, 32)
        }
        .background(Theme.surface)
        .navigationTitle(station.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // The caps header below names the station; keep the bar quiet.
                Text(station.name).font(.subheadline.weight(.semibold)).opacity(0)
                    .accessibilityHidden(true)
            }
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 4) {
                    if model.phase == .loading && model.forecast != nil {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        settings.toggleFavorite(station)
                    } label: {
                        Image(systemName: settings.isFavorite(station) ? "star.fill" : "star")
                    }
                    .accessibilityLabel(settings.isFavorite(station) ? "Remove from favorites" : "Add to favorites")
                }
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

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(station.name.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.inkSecondary)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let r = station.region, !r.isEmpty { parts.append(r) }
        if station.source == .noaaCoops { parts.append("NOAA \(station.code)") } else { parts.append(DataSourceInfo.info(station.source).agency) }
        if let f = model.forecast { parts.append("Updated \(Fmt.time(f.issued, in: tz))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ f: WaterLevelForecast) -> some View {
        if !f.nearbyStorms.isEmpty || !f.alerts.isEmpty {
            callouts(f)
                .padding(.horizontal, Theme.margin)
                .padding(.top, 14)
        }

        hero(f)
            .padding(.horizontal, Theme.margin)
            .padding(.top, 18)

        TideLineChart(forecast: f, unit: unit, tz: tz)
            .padding(.top, 14)

        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Next tides")
            NextTidesGrid(events: f.events, unit: unit, tz: tz, now: f.issued)
            NavigationLink {
                AllTidesView(forecast: f, unit: unit, tz: tz)
            } label: {
                Text("All tides").frame(minHeight: 44)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, Theme.sectionGap)

        if SFBay.contains(station) {
            BayEntryCard(station: station, highLag: env.bay.highLag(code: station.code))
                .padding(.horizontal, Theme.margin)
                .padding(.top, Theme.sectionGap)
        }

        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Tide calendar")
            TideCalendarView(forecast: f, unit: unit, tz: tz)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, Theme.sectionGap)

        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Highest water · \(Int((f.horizon.timeIntervalSince(f.issued) / 86_400).rounded())) days")
            HighestWaterSection(forecast: f, peak: model.peakEvent, unit: unit, tz: tz)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 18)

        if let point = model.componentsNow {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel((model.anomalyNow ?? point.surge) >= 0 ? "Why the water is high" : "Why the water is low")
                if let sentence = model.driverSentence {
                    Text(sentence).font(.subheadline).foregroundStyle(Theme.ink)
                }
                DriverBars(point: point, unit: unit)
            }
            .padding(.horizontal, Theme.margin)
            .padding(.top, Theme.sectionGap)
        }

        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Confidence")
            Text(confidenceText(f)).font(.subheadline)
            if let result = model.result {
                NavigationLink {
                    ForecastDetailsView(result: result, unit: unit, tz: tz)
                } label: {
                    Text("How this forecast works").frame(minHeight: 44)
                }
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, Theme.sectionGap)

        VStack(alignment: .leading, spacing: 4) {
            Text(sourceLine)
            Text("Guidance only. Not for navigation.")
        }
        .font(.caption)
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, Theme.margin)
        .padding(.top, 24)
    }

    // MARK: Pieces

    @ViewBuilder
    private func callouts(_ f: WaterLevelForecast) -> some View {
        VStack(spacing: 10) {
            ForEach(f.nearbyStorms) { s in
                RiskCallout(title: "\(s.classification) \(s.name) nearby",
                            message: "Statistical surge forecasts are unreliable in tropical cyclones. Follow NHC and local NWS forecasts.",
                            systemImage: "hurricane",
                            tint: Theme.alert, wash: Theme.alertWash)
            }
            ForEach(f.alerts) { a in
                RiskCallout(title: a.event, message: a.headline, systemImage: "exclamationmark.triangle.fill",
                            tint: Theme.alert, wash: Theme.alertWash)
            }
        }
    }

    @ViewBuilder
    private func hero(_ f: WaterLevelForecast) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = model.reading {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(number(r.value))
                        .font(.reading(76))
                        .tracking(-1)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.6)
                    Text(unit.symbol).font(.title2.weight(.light)).foregroundStyle(Theme.inkSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(Fmt.length(r.value, unit)) \(r.observed ? "observed" : "predicted")")

                if let next = f.events.first {
                    HStack(spacing: 8) {
                        if let rising = model.trendRising { TrendArrow(rising: rising) }
                        (Text("\(model.trendRising.map { $0 ? "Rising · " : "Falling · " } ?? "Next ")\(Phrase.eventName(next.kind).lowercased()) ")
                            + Text(Fmt.length(next.total, unit)).fontWeight(.semibold)
                            + Text(" at \(Fmt.smartTime(next.date, in: tz, relativeTo: f.issued))"))
                            .font(.callout)
                    }
                }
                if !r.observed {
                    Text("Predicted: no live observations at this station.")
                        .font(.footnote).foregroundStyle(Theme.inkSecondary)
                }
            }
            if let a = model.anomalyNow {
                Chip(text: Phrase.anomaly(a, unit), style: a >= 0.03 ? .swell : (a <= -0.03 ? .harbor : .neutral))
            }
        }
    }

    private func number(_ meters: Double) -> String {
        String(format: unit == .feet ? "%.1f" : "%.2f", unit.fromMeters(meters))
    }

    private func confidenceText(_ f: WaterLevelForecast) -> String {
        if let rms = f.model.hindcast24hRMS {
            return "In recent tests this station's forecast was within ±\(Fmt.length(rms * 1.2816, unit)) a day ahead, 8 times in 10."
        }
        switch f.method {
        case .calibrated: return "Not enough recent data to measure this station's accuracy yet."
        case .uncalibrated: return "No recent observations here, so this forecast is less certain than usual."
        case .persistenceOnly: return "Weather data is unavailable, so the forecast carries today's level forward."
        }
    }

    private var sourceLine: String {
        guard let r = model.result else { return DataSourceInfo.info(station.source).agency }
        let names = Set(r.sources.filter(\.ok).map(\.source)).map { id -> String in
            switch id {
            case .noaaCoops: return "NOAA"
            case .nwsAlerts, .nwps, .nhc: return "NWS"
            case .openMeteo: return "Open-Meteo"
            case .dfoIWLS: return "Fisheries and Oceans Canada"
            case .ukAdmiralty: return "UK Hydrographic Office"
            }
        }
        return Array(Set(names)).sorted().joined(separator: " · ")
    }
}

/// Quiet placeholder while the first forecast builds.
private struct LoadingHero: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 8).fill(Theme.neutralWash).frame(width: 120, height: 64)
            RoundedRectangle(cornerRadius: 6).fill(Theme.neutralWash).frame(width: 220, height: 16)
            RoundedRectangle(cornerRadius: 12).fill(Theme.neutralWash).frame(height: 200)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the tide, the weather and the latest observations…")
                    .font(.footnote)
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading forecast")
    }
}

/// The way into the San Francisco Bay screen from a bay station.
private struct BayEntryCard: View {
    let station: Station
    let highLag: TimeInterval?

    private var detail: String {
        if station.code == SFBay.referenceCode {
            return "Watch high water travel from the Golden Gate into the South Bay and up to Carquinez Strait."
        }
        if let lag = highLag {
            return "High water here comes \(Fmt.lagSpoken(lag)) than at San Francisco. See how the tide moves through the bay."
        }
        return "See how the tide moves through the bay, and this station's timing against San Francisco."
    }

    var body: some View {
        NavigationLink {
            BayView(initialCode: station.code)
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "water.waves")
                    .font(.title3)
                    .foregroundStyle(Theme.harbor)
                    .frame(width: 40, height: 40)
                    .background(Theme.surface, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("San Francisco Bay").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(detail).font(.footnote).foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.inkSecondary.opacity(0.6))
                    .accessibilityHidden(true)
            }
            .padding(14)
            .background(Theme.neutralWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the bay's tide propagation and timing")
    }
}
