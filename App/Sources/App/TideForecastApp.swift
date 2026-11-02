import SwiftUI
import TideKit

@main
struct TideForecastApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .environment(environment.settings)
                .environment(environment.stations)
                .environment(environment.location)
                .task { await environment.stations.load(service: environment.service) }
        }
    }
}

struct RootView: View {
    enum Tab: Hashable { case stations, map, settings }

    @Environment(StationStore.self) private var store
    @State private var tab: Tab = .stations
    @State private var stationPath: [Station] = []
    @State private var pendingStationID: String?

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $stationPath) { StationListView() }
                .tabItem { Label("Stations", systemImage: "list.bullet") }
                .tag(Tab.stations)
            NavigationStack { StationMapView() }
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Tab.map)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        // Widgets open `tideforecast://station/<id>`.
        .onOpenURL { url in
            guard let id = AppGroup.stationID(from: url) else { return }
            pendingStationID = id
            openPendingStation()
        }
        .onChange(of: store.stations.count) { _, _ in openPendingStation() }
    }

    private func openPendingStation() {
        guard let id = pendingStationID, let station = store.station(id: id) else { return }
        pendingStationID = nil
        tab = .stations
        stationPath = [station]
    }
}
