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
    typealias Tab = AppRouter.Tab

    @Environment(AppEnvironment.self) private var env
    @Environment(StationStore.self) private var store
    /// Holds `Station`s and `RegionRoute`s: every push in the Tides tab goes
    /// through the path, so pushing a station never drops the screens below.
    @State private var stationPath = NavigationPath()
    @State private var pendingStationID: String?

    var body: some View {
        @Bindable var router = env.router
        TabView(selection: $router.tab) {
            NavigationStack(path: $stationPath) { StationListView() }
                .tabItem { Label("Tides", systemImage: "water.waves") }
                .tag(Tab.stations)
            NavigationStack { StationMapView() }
                .tabItem { Label("Map", systemImage: "map") }
                .tag(Tab.map)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .tint(Theme.harbor)
        // Widgets open `tideforecast://station/<id>`.
        .onOpenURL { url in
            if let code = AppGroup.bayStationCode(from: url) {
                env.router.showBay(code: code.isEmpty ? nil : code)
                return
            }
            guard let id = AppGroup.stationID(from: url) else { return }
            pendingStationID = id
            openPendingStation()
        }
        .onChange(of: store.stations.count) { _, _ in openPendingStation() }
    }

    private func openPendingStation() {
        guard let id = pendingStationID, let station = store.station(id: id) else { return }
        pendingStationID = nil
        env.router.tab = .stations
        var path = NavigationPath()
        path.append(station)
        stationPath = path
    }
}
