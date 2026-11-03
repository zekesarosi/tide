import Foundation
import Observation
import TideKit

/// Composition root: identity, credentials, networking and app-wide stores.
@MainActor
@Observable
final class AppEnvironment {
    let identity: AppIdentity
    let credentials: CredentialStore
    let service: ForecastService
    let settings: AppSettings
    let stations: StationStore
    let location: LocationProvider
    /// San Francisco Bay analysis, loaded when the map first shows the bay.
    let bay = BayModel()
    let router = AppRouter()
    /// Morning summary notifications.
    let morning: MorningNotifier

    init() {
        identity = AppIdentity.fromBundle()
        // Keychain first (user-entered keys), then optional build-time
        // defaults injected via Config/Secrets.xcconfig → Info.plist.
        // The Keychain access group is shared with the widget extension.
        credentials = AppGroup.credentials()
        service = ForecastService(api: APIClient(identity: identity, credentials: credentials))
        settings = AppSettings()
        stations = StationStore()
        location = LocationProvider()
        morning = MorningNotifier(service: service, settings: settings, stations: stations, router: router)
    }

    /// True when the NWS-required contact has not been set in Config/App.xcconfig.
    var isContactConfigured: Bool { identity.contact != "contact-not-configured" && !identity.contact.contains("example.com") }

    func updateSecret(_ value: String?, for key: CredentialKey) async throws {
        try credentials.setSecret(value?.trimmingCharacters(in: .whitespacesAndNewlines), for: key)
        await service.api.clearCache()
        WidgetBridge.settingsChanged()
        if key == .ukAdmiraltySubscriptionKey {
            await stations.load(service: service, force: true)
        }
    }
}

/// Cross-tab navigation: the tab on screen, and a request for the map to show
/// San Francisco Bay (from a bay station's screen or `tideforecast://bay`).
@MainActor
@Observable
final class AppRouter {
    enum Tab: Hashable { case stations, map, settings }

    struct BayFocus: Equatable {
        /// Station to select, or nil for the default comparison.
        let code: String?
        let id = UUID()
    }

    var tab: Tab = .stations
    /// Consumed by the map once it has moved there.
    var bayFocus: BayFocus?
    /// A station to open in the Tides tab (e.g. from a notification).
    var openStationID: String?

    func showBay(code: String? = nil) {
        bayFocus = BayFocus(code: code)
        tab = .map
    }
}
