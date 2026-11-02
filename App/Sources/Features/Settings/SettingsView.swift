import SwiftUI
import TideKit

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Display") {
                Picker("Units", selection: $settings.unit) {
                    Text("Feet").tag(LengthUnit.feet)
                    Text("Meters").tag(LengthUnit.meters)
                }
                Picker("Datum (US stations)", selection: $settings.datum) {
                    ForEach(AppSettings.selectableDatums, id: \.self) { d in
                        Text("\(d.rawValue) — \(d.displayName)").tag(d)
                    }
                }
            }
            Section {
                Picker("Forecast horizon", selection: $settings.horizonHours) {
                    ForEach(AppSettings.horizons, id: \.self) { Text("\($0 / 24) days").tag($0) }
                }
                Toggle("Blend official NWS guidance", isOn: $settings.blendOfficialGuidance)
            } header: {
                Text("Forecast")
            } footer: {
                Text("When available, the station-calibrated surge model is blended with the National Weather Service's official coastal water level forecast, weighted by each one's recent accuracy.")
            }
            Section {
                NavigationLink("API keys") { APIKeysView() }
                NavigationLink("Data sources & attribution") { DataSourcesView() }
            } header: {
                Text("Data")
            } footer: {
                if !env.isContactConfigured {
                    Text("⚠︎ Developer contact is not configured (TIDE_CONTACT in Config/App.xcconfig). The National Weather Service requires an identifying User-Agent and may reject requests.")
                        .foregroundStyle(Theme.warning)
                }
            }
            Section("About") {
                LabeledContent("Version", value: env.identity.version)
                Text("Tide predictions are computed on-device from NOAA harmonic constants. Storm surge forecasts are statistical guidance calibrated to each station's recent observations. Not for navigation; always follow official warnings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.mist)
        .navigationTitle("Settings")
    }
}

struct APIKeysView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Form {
            Section {
                Text("NOAA, NWS and Fisheries and Oceans Canada data need no key. Keys are optional and stored only in this device's Keychain.")
                    .font(.footnote)
            }
            ForEach(CredentialKey.allCases, id: \.self) { key in
                KeyEditor(key: key)
            }
        }
        .navigationTitle("API keys")
    }
}

private struct KeyEditor: View {
    @Environment(AppEnvironment.self) private var env
    let key: CredentialKey
    @State private var draft = ""
    @State private var isSet = false
    @State private var status: String?

    var body: some View {
        Section {
            SecureField(isSet ? "•••••••• (saved)" : "Paste key", text: $draft)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            HStack {
                Button("Save") { save(draft) }.buttonStyle(.borderless).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if isSet { Button("Remove", role: .destructive) { save(nil) }.buttonStyle(.borderless) }
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        } header: {
            Text(key.displayName)
        } footer: {
            Text(footer)
        }
        .onAppear { isSet = env.credentials.hasSecret(for: key) }
    }

    private var footer: String {
        switch key {
        case .openMeteoAPIKey:
            return "Only needed for commercial use of Open-Meteo. With a key, requests go to customer-api.open-meteo.com."
        case .ukAdmiraltySubscriptionKey:
            return "Enables UK Hydrographic Office tidal predictions for ~600 UK ports. Get a Discovery subscription at admiraltyapi.portal.azure-api.net."
        }
    }

    private func save(_ value: String?) {
        Task {
            do {
                try await env.updateSecret(value, for: key)
                draft = ""
                isSet = env.credentials.hasSecret(for: key)
                status = value == nil ? "Removed." : "Saved to Keychain."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}

struct DataSourcesView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        List {
            ForEach(DataSourceInfo.all) { info in
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name).font(.headline)
                    Text(info.agency).font(.subheadline).foregroundStyle(.secondary)
                    Text(authDescription(info)).font(.caption)
                    Text(info.notes).font(.caption).foregroundStyle(.secondary)
                    Text(info.attribution).font(.caption2).foregroundStyle(.secondary)
                    HStack {
                        Link("Website", destination: info.homepage)
                        Link("Terms", destination: info.termsURL)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.vertical, 4)
            }
            Section("Request identity") {
                LabeledContent("User-Agent", value: env.identity.userAgent).font(.caption)
                LabeledContent("NOAA application", value: env.identity.coopsApplication).font(.caption)
            }
        }
        .navigationTitle("Data sources")
    }

    private func authDescription(_ info: DataSourceInfo) -> String {
        switch info.auth {
        case .none: return "Authentication: none"
        case .identifyingUserAgent: return "Authentication: identifying User-Agent (no key)"
        case .apiKeyHeader(let name, let required):
            let set = keyFor(info.id).map { env.credentials.hasSecret(for: $0) } ?? false
            return "Authentication: \(name) header (\(required ? "required" : "optional")) — \(set ? "configured" : "not configured")"
        case .apiKeyQuery(let name, let required):
            let set = keyFor(info.id).map { env.credentials.hasSecret(for: $0) } ?? false
            return "Authentication: `\(name)` parameter (\(required ? "required" : "optional")) — \(set ? "configured" : "not configured")"
        }
    }

    private func keyFor(_ id: DataSourceID) -> CredentialKey? { CredentialKey.allCases.first { $0.source == id } }
}
