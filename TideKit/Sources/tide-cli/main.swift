import Foundation
import TideKit

// Usage: tide-cli <NOAA station id | search text> [datum] [hours]
//        tide-cli bay      (San Francisco Bay offsets vs 9414290)
// Env:   TIDE_CONTACT (required by api.weather.gov), OPEN_METEO_API_KEY, UK_ADMIRALTY_KEY

let args = CommandLine.arguments.dropFirst()
let query = args.first ?? "8518750"
let datum = args.dropFirst().first.flatMap { TidalDatum(rawValue: $0.uppercased()) } ?? .mllw
let hours = args.dropFirst(2).first.flatMap(Int.init) ?? 120

let env = ProcessInfo.processInfo.environment
let identity = AppIdentity(appName: "TideForecastCLI", version: "0.1", contact: env["TIDE_CONTACT"] ?? "contact-not-configured")
var secrets: [CredentialKey: String] = [:]
if let k = env["OPEN_METEO_API_KEY"] { secrets[.openMeteoAPIKey] = k }
if let k = env["UK_ADMIRALTY_KEY"] { secrets[.ukAdmiraltySubscriptionKey] = k }
let service = ForecastService(api: APIClient(identity: identity, credentials: InMemoryCredentialStore(secrets)))

if query.lowercased() == "bay" {
    await runBay(api: service.api)
    exit(0)
}

func fmt(_ v: Double) -> String { String(format: "%6.2f", v) }

let (stations, stationSources) = await service.allStations()
for s in stationSources where !s.ok { print("! \(s.source.rawValue) \(s.component): \(s.message ?? "")") }
guard let station = stations.first(where: { $0.code == query })
        ?? stations.first(where: { $0.name.localizedCaseInsensitiveContains(query) }) else {
    print("No station matching \(query) among \(stations.count) stations"); exit(1)
}
print("Station: \(station.name) [\(station.id)] \(station.region ?? "") lid=\(station.nwsLID ?? "-")")

do {
    let started = Date()
    let r = try await service.forecast(for: station, options: ForecastOptions(datum: datum, horizonHours: hours))
    let f = r.forecast
    print(String(format: "Forecast built in %.1fs, datum %@, method %@", Date().timeIntervalSince(started), r.datum.rawValue, f.method.rawValue))
    for s in r.sources { print("  \(s.ok ? "✓" : "✗") \(s.source.rawValue) \(s.component) \(String(format: "%.1fs", s.duration))\(s.message.map { " — \($0)" } ?? "")") }
    let d = f.model
    print("Model: hours=\(d.trainingHours) R²=\(d.rSquared.map { String(format: "%.2f", $0) } ?? "-") " +
          "errRMS=\(d.modelErrorRMS.map { String(format: "%.3f", $0) } ?? "-") " +
          "IB=\(d.inverseBarometerCmPerHPa.map { String(format: "%.2f cm/hPa", $0) } ?? "-") " +
          "setupWindFrom=\(d.dominantWindDirection.map { String(format: "%.0f°", $0) } ?? "-") " +
          "eFold=\(String(format: "%.0fh", d.persistenceEFoldingHours)) tideTerms=\(d.usesTideInteraction) " +
          "w=\(String(format: "%.1f", d.modelWeight)) regression24h=\(d.regression24hRMS.map { String(format: "%.3f", $0) } ?? "-") final24h=\(d.hindcast24hRMS.map { String(format: "%.3f", $0) } ?? "-") vs persistence \(d.persistence24hRMS.map { String(format: "%.3f", $0) } ?? "-")")
    if let o = f.latestObservation, let r0 = f.currentResidual {
        print("Latest obs \(o.date): \(fmt(o.value)) m, residual \(fmt(r0.value)) m")
    }
    if let t = f.thresholds { print("Flood thresholds (\(t.authority), \(t.datum.rawValue)): minor \(t.minor.map(fmt) ?? "-") moderate \(t.moderate.map(fmt) ?? "-") major \(t.major.map(fmt) ?? "-")") }
    for n in f.notes { print("Note: \(n)") }
    for a in f.alerts { print("ALERT: \(a.event) — \(a.headline ?? "")") }
    let df = DateFormatter(); df.dateFormat = "EEE MM-dd HH:mm zzz"; df.timeZone = station.timeZone
    print("\nEvent                 kind  astro  surge  total  ±80%   P(minor)")
    for e in f.events.prefix(14) {
        let p = e.exceedance[.minor].map { String(format: "%5.1f%%", $0 * 100) } ?? "    -"
        print("\(df.string(from: e.date))  \(e.kind == .high ? "HIGH" : "low ") \(fmt(e.astronomical)) \(fmt(e.surge)) \(fmt(e.total)) \(fmt(1.2816 * e.sigma))  \(p)  \(e.category == .none ? "" : e.category.label)")
    }
    print("\nSurge components (every 12h): date  total = offset + pressure + wind + tide + persistence  | official (weight)")
    for s in f.surge.enumerated().filter({ $0.offset % 12 == 0 }).map(\.element) {
        print("\(df.string(from: s.date)) \(fmt(s.surge)) = \(fmt(s.offsetComponent)) \(fmt(s.pressureComponent)) \(fmt(s.windComponent)) \(fmt(s.tideInteractionComponent)) \(fmt(s.persistenceComponent)) | \(s.officialSurge.map(fmt) ?? "   -  ") (\(String(format: "%.2f", s.officialWeight))) σ=\(fmt(s.sigma))")
    }
} catch {
    print("Forecast failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
    exit(2)
}
