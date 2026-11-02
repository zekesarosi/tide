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
    var body: some View {
        TabView {
            NavigationStack { StationListView() }
                .tabItem { Label("Stations", systemImage: "list.bullet") }
            NavigationStack { StationMapView() }
                .tabItem { Label("Map", systemImage: "map") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
    }
}
