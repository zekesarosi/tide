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
    /// San Francisco Bay analysis, loaded when the Bay screen first opens.
    let bay = BayModel()

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
