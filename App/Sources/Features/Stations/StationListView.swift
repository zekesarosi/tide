import Observation
import SwiftUI
import TideKit

/// Home: favorites as live cards, then nearby stations and browse by region.
@MainActor
struct StationListView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(StationStore.self) private var store
    @Environment(LocationProvider.self) private var location
    @State private var query = ""
    @State private var favorites = FavoritesModel()
    @State private var nearby: [(station: Station, meters: Double)] = []

    private var favoriteStations: [Station] { settings.favoriteIDs.compactMap { store.station(id: $0) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if query.isEmpty {
                    Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.horizontal, 4)
                    favoritesSection
                    nearbySection
                    browseSection
                } else {
                    searchResults
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.mist)
        .navigationTitle("Tides")
        .navigationDestination(for: Station.self) { StationDetailView(station: $0).id($0.id) }
        .navigationDestination(for: RegionRoute.self) { r in
            RegionStationsView(region: r.region, stations: store.grouped.first { $0.region == r.region }?.stations ?? [])
        }
        .searchable(text: $query, prompt: "Search stations")
        .refreshable {
            await store.load(service: env.service, force: true)
            await favorites.refresh(favoriteStations, service: env.service, options: settings.forecastOptions, force: true)
        }
        .task(id: location.location.map { "\(Int($0.coordinate.latitude * 100)),\(Int($0.coordinate.longitude * 100)),\(store.stations.count)" }) {
            guard let loc = location.location else { return }
            nearby = store.nearest(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude, limit: 3)
                .map { (station: $0.0, meters: $0.1) }
        }
        .task(id: settings.favoriteIDs) {
            favorites.loadSaved(favoriteStations)
            await favorites.refresh(favoriteStations, service: env.service, options: settings.forecastOptions)
        }
        .overlay {
            if store.stations.isEmpty {
                if store.isLoading {
                    ProgressView("Loading stations")
                } else {
                    ContentUnavailableView {
                        Label("No stations", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(store.sourceProblems.first?.message ?? "Check your connection and pull to try again.")
                    }
                }
            }
        }
    }

    // MARK: Sections

    @ViewBuilder private var favoritesSection: some View {
        SectionLabel("Favorites").padding(.horizontal, 4).padding(.top, 4)
        if favoriteStations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Keep your tides here").font(.headline)
                Text("Star a station to see its water level, the next tide and the surge at a glance. Your first favorite also fills the widget.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        } else {
            ForEach(favoriteStations) { station in
                NavigationLink(value: station) {
                    FavoriteCard(station: station, snapshot: favorites.snapshots[station.id],
                                 updating: favorites.refreshing.contains(station.id), unit: settings.unit)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(role: .destructive) { settings.toggleFavorite(station) } label: {
                        Label("Remove from favorites", systemImage: "star.slash")
                    }
                }
            }
        }
    }

    @ViewBuilder private var nearbySection: some View {
        SectionLabel("Nearby").padding(.horizontal, 4).padding(.top, 10)
        GroupCard {
            if location.location != nil, !nearby.isEmpty {
                ForEach(Array(nearby.enumerated()), id: \.element.station.id) { i, pair in
                    if i > 0 { Divider().overlay(Theme.hairline).padding(.leading, 16) }
                    StationRow(station: pair.station, trailing: Fmt.distance(pair.meters))
                }
            } else if location.isDenied {
                Text("Location is off. Turn it on in Settings to see stations near you.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(16)
            } else {
                Button {
                    location.request()
                } label: {
                    Label("Find stations near me", systemImage: "location")
                        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                        .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder private var browseSection: some View {
        SectionLabel("Browse").padding(.horizontal, 4).padding(.top, 10)
        GroupCard {
            ForEach(Array(store.grouped.enumerated()), id: \.element.region) { i, group in
                if i > 0 { Divider().overlay(Theme.hairline).padding(.leading, 16) }
                NavigationLink(value: RegionRoute(region: group.region)) {
                    HStack {
                        Text(group.region).foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(group.stations.count)").foregroundStyle(Theme.inkSecondary).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.inkSecondary.opacity(0.6))
                    }
                    .frame(minHeight: 48)
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var searchResults: some View {
        let results = store.search(query)
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            GroupCard {
                ForEach(Array(results.prefix(100).enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Divider().overlay(Theme.hairline).padding(.leading, 16) }
                    StationRow(station: s, trailing: s.region)
                }
            }
            .padding(.top, 8)
        }
    }
}

// MARK: - Favorites

/// Keeps the latest snapshot per favorite and refreshes stale ones in the
/// background (also feeding the widgets).
@MainActor
@Observable
final class FavoritesModel {
    private(set) var snapshots: [String: ForecastSnapshot] = [:]
    private(set) var refreshing: Set<String> = []

    static let maxAge: TimeInterval = 30 * 60

    func loadSaved(_ stations: [Station]) {
        for s in stations where snapshots[s.id] == nil {
            if let snap = AppGroup.snapshots.load(stationID: s.id) { snapshots[s.id] = snap }
        }
    }

    func refresh(_ stations: [Station], service: ForecastService, options: ForecastOptions, force: Bool = false) async {
        let shared = SharedSettings.load()
        let due = stations.filter { s in
            guard !refreshing.contains(s.id) else { return false }
            guard let snap = snapshots[s.id], !force else { return true }
            return Date().timeIntervalSince(snap.issued) > Self.maxAge || snap.datum != shared.datum(for: s)
        }
        .prefix(4)
        guard !due.isEmpty else { return }
        for s in due { refreshing.insert(s.id) }
        await withTaskGroup(of: (String, ForecastSnapshot?).self) { group in
            for s in due {
                group.addTask {
                    let result = try? await service.forecast(for: s, options: options)
                    if let result { await ForecastCache.shared.store(result, for: s) }
                    return (s.id, result.map { ForecastSnapshot(forecast: $0.forecast) })
                }
            }
            for await (id, snap) in group {
                refreshing.remove(id)
                if let snap {
                    snapshots[id] = snap
                    try? AppGroup.snapshots.save(snap)
                }
            }
        }
        WidgetBridge.settingsChanged()
    }
}

/// A favorite: reading, trend, next tide, today's tide line and the anomaly.
struct FavoriteCard: View {
    let station: Station
    let snapshot: ForecastSnapshot?
    let updating: Bool
    let unit: LengthUnit

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(station.name).font(.headline).foregroundStyle(Theme.ink)
                        Text(nextLine(now)).font(.footnote).foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer(minLength: 8)
                    if let v = snapshot?.level(at: now) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(String(format: unit == .feet ? "%.1f" : "%.2f", unit.fromMeters(v)))
                                .font(.cardValue)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Text(unit.symbol).font(.subheadline).foregroundStyle(Theme.inkSecondary)
                            if let rising = snapshot?.isRising(at: now) { TrendArrow(rising: rising).font(.caption) }
                        }
                        .foregroundStyle(Theme.ink)
                    } else if updating {
                        ProgressView().controlSize(.small)
                    }
                }
                if let snapshot {
                    DayTideLine(snapshot: snapshot, now: now)
                        .frame(height: 40)
                    HStack(spacing: 6) {
                        if let a = snapshot.currentAnomaly {
                            Circle().fill(abs(a) < 0.03 ? Theme.inkSecondary : (a > 0 ? Theme.swellDot : Theme.harbor))
                                .frame(width: 6, height: 6)
                            Text(Phrase.anomaly(a, unit))
                                .foregroundStyle(a > 0.03 ? Theme.swellText : Theme.inkSecondary)
                        }
                        Spacer()
                    }
                    .font(.caption)
                } else if !updating {
                    Text("Open for the forecast").font(.footnote).foregroundStyle(Theme.inkSecondary)
                }
            }
            .padding(16)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: Theme.ink.opacity(0.05), radius: 1, y: 1)
            .accessibilityElement(children: .combine)
        }
    }

    private func nextLine(_ now: Date) -> String {
        guard let e = snapshot?.nextEvents(after: now, limit: 1).first, let tz = snapshot?.timeZone else {
            return station.region ?? ""
        }
        return "\(Phrase.eventName(e.kind)) \(Fmt.length(e.total, unit)) · \(Fmt.smartTime(e.date, in: tz, relativeTo: now))"
    }
}

/// Today's water line at the station, with a "now" mark.
struct DayTideLine: View {
    let snapshot: ForecastSnapshot
    let now: Date

    var body: some View {
        var cal = Calendar.current
        cal.timeZone = snapshot.timeZone
        let start = cal.startOfDay(for: now)
        let end = start + 86_400
        let pts = snapshot.chartPoints(from: start, to: end).compactMap { p -> (Date, Double)? in
            guard let v = p.total ?? p.predicted.map({ $0 + (snapshot.currentAnomaly ?? 0) }) else { return nil }
            return (p.date, v)
        }
        let lo = pts.map(\.1).min() ?? 0, hi = pts.map(\.1).max() ?? 1
        return Canvas { ctx, size in
            guard pts.count > 1, hi > lo else { return }
            func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(start) / 86_400) * size.width }
            func y(_ v: Double) -> CGFloat { size.height - 2 - CGFloat((v - lo) / (hi - lo)) * (size.height - 4) }
            var path = Path()
            for (i, p) in pts.enumerated() {
                let pt = CGPoint(x: x(p.0), y: y(p.1))
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            ctx.stroke(path, with: .color(Theme.harbor), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            let nx = x(now)
            var rule = Path()
            rule.move(to: CGPoint(x: nx, y: 2))
            rule.addLine(to: CGPoint(x: nx, y: size.height - 2))
            ctx.stroke(rule, with: .color(Theme.ink.opacity(0.15)), lineWidth: 1)
            if let v = snapshot.level(at: now) {
                let r: CGFloat = 3
                ctx.fill(Path(ellipseIn: CGRect(x: nx - r, y: y(v) - r, width: 2 * r, height: 2 * r)), with: .color(Theme.harbor))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Shared rows

/// White rounded group on the mist ground.
struct GroupCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }
}

struct StationRow: View {
    @Environment(AppSettings.self) private var settings
    let station: Station
    var trailing: String?

    var body: some View {
        NavigationLink(value: station) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name).foregroundStyle(Theme.ink)
                    if !station.isTidal {
                        Text("Great Lakes").font(.caption).foregroundStyle(Theme.inkSecondary)
                    }
                }
                Spacer()
                if settings.isFavorite(station) {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(Theme.harbor)
                        .accessibilityLabel("Favorite")
                }
                if let trailing { Text(trailing).font(.subheadline).foregroundStyle(Theme.inkSecondary) }
            }
            .frame(minHeight: 52)
            .padding(.horizontal, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A state/province in the Browse list, pushed by value so it lives in the
/// Tides tab's navigation path alongside the stations it leads to.
struct RegionRoute: Hashable {
    let region: String
}

struct RegionStationsView: View {
    let region: String
    let stations: [Station]

    var body: some View {
        ScrollView {
            GroupCard {
                ForEach(Array(stations.enumerated()), id: \.element.id) { i, s in
                    if i > 0 { Divider().overlay(Theme.hairline).padding(.leading, 16) }
                    StationRow(station: s, trailing: s.source == .noaaCoops ? s.code : nil)
                }
            }
            .padding(16)
        }
        .background(Theme.mist)
        .navigationTitle(region)
    }
}
