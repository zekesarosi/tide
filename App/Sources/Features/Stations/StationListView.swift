import SwiftUI
import TideKit

@MainActor
struct StationListView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(StationStore.self) private var store
    @Environment(LocationProvider.self) private var location
    @State private var query = ""

    var body: some View {
        List {
            if query.isEmpty {
                favoritesSection
                nearbySection
                ForEach(store.grouped, id: \.region) { group in
                    Section(group.region) {
                        ForEach(group.stations) { StationRow(station: $0) }
                    }
                }
            } else {
                let results = store.search(query)
                if results.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ForEach(results) { StationRow(station: $0) }
                }
            }
        }
        .navigationTitle("Tide & Surge")
        .navigationDestination(for: Station.self) { StationDetailView(station: $0) }
        .searchable(text: $query, prompt: "Station name, ID or state")
        .refreshable { await store.load(service: env.service, force: true) }
        .overlay {
            if store.stations.isEmpty {
                if store.isLoading {
                    ProgressView("Loading stations…")
                } else {
                    ContentUnavailableView {
                        Label("No stations", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(store.sourceProblems.first?.message ?? "Pull to retry.")
                    }
                }
            }
        }
    }

    @ViewBuilder private var favoritesSection: some View {
        let favorites = settings.favoriteIDs.compactMap(store.station(id:))
        if !favorites.isEmpty {
            Section("Favorites") {
                ForEach(favorites) { StationRow(station: $0) }
                    .onDelete { offsets in
                        for i in offsets { settings.toggleFavorite(favorites[i]) }
                    }
            }
        }
    }

    @ViewBuilder private var nearbySection: some View {
        Section("Nearby") {
            if let loc = location.location {
                ForEach(store.nearest(latitude: loc.coordinate.latitude, longitude: loc.coordinate.longitude), id: \.0.id) { station, distance in
                    StationRow(station: station, distance: distance)
                }
            } else if location.isDenied {
                Label("Location access is off. Enable it in Settings to see nearby stations.", systemImage: "location.slash")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Button {
                    location.request()
                } label: {
                    Label("Find stations near me", systemImage: "location")
                }
            }
        }
    }
}

struct StationRow: View {
    @Environment(AppSettings.self) private var settings
    let station: Station
    var distance: Double?

    var body: some View {
        NavigationLink(value: station) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name).font(.body)
                    HStack(spacing: 6) {
                        Text(station.code.count > 12 ? DataSourceInfo.info(station.source).agency : station.code)
                        if !station.isTidal { Text("· Great Lakes") }
                        if station.capabilities.contains(.officialForecast) { Image(systemName: "checkmark.seal").help("Official NWS forecast available") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let distance { Text(Fmt.distance(distance)).font(.caption).foregroundStyle(.secondary) }
                if settings.isFavorite(station) { Image(systemName: "star.fill").foregroundStyle(.yellow).font(.caption) }
            }
        }
    }
}
