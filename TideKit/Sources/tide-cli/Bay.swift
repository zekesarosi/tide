import Foundation
import TideKit

/// `tide-cli bay`: San Francisco Bay offsets vs 9414290, computed on device,
/// checked against the same computation on NOAA's official high/low
/// predictions and, where NOAA publishes them, its subordinate-station
/// differences.
func runBay(api: APIClient) async {
    let coops = NOAACoopsClient(api: api)
    let started = Date()
    let analysis: BayAnalysis
    do {
        analysis = try await BayService(coops: coops).analyze()
    } catch {
        print("Bay analysis failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"); exit(2)
    }
    print(String(format: "Bay analysis in %.1fs: %d of %d stations", Date().timeIntervalSince(started),
                 analysis.stations.count, SFBay.stations.count))
    for p in analysis.problems { print("  ! \(p.component): \(p.message ?? "")") }

    // NOAA official hi/lo over the same window, and published offsets.
    let w = analysis.window
    let official = await withTaskGroup(of: (String, [TideExtreme]?).self) { g in
        for s in SFBay.stations {
            g.addTask { (s.code, try? await coops.highLowPredictions(station: s.code, from: w.start - 6 * 3_600, to: w.end + 6 * 3_600, datum: .mllw)) }
        }
        var out: [String: [TideExtreme]] = [:]
        for await (c, e) in g { if let e { out[c] = e } }
        return out
    }
    struct Published: Decodable {
        let type: String?
        let refStationId: String?
        let timeOffsetHighTide: Double?
        let timeOffsetLowTide: Double?
        let heightOffsetHighTide: Double?
        let heightOffsetLowTide: Double?
    }
    var published: [String: Published] = [:]
    for s in SFBay.stations {
        if let ep = try? Endpoint.build(.noaaCoops, "\(NOAACoopsClient.metaBase)/stations/\(s.code)/tidepredoffsets.json"),
           let data = try? await api.data(for: ep), let p = try? JSONDecoder().decode(Published.self, from: data),
           p.type == "S" { published[s.code] = p }
    }

    func m(_ s: TimeInterval?) -> String { s.map { String(format: "%+5.0f", $0 / 60) } ?? "    -" }
    func sd(_ s: LagStatistics?) -> String { s.map { String(format: "±%-3.0f", $0.standardDeviation / 60) } ?? "    " }
    func r(_ v: Double?) -> String { v.map { String(format: "%4.2f", $0) } ?? "   -" }
    let refOfficial = official[SFBay.referenceCode].map { e in e.filter { w.contains($0.date) } }

    print("""

    Lags in minutes vs San Francisco 9414290 (+ = later). Window \(w.start.formatted(.iso8601.year().month().day())) – \(w.end.formatted(.iso8601.year().month().day())), \(Int(w.duration / 86_400)) days.
    Station          code     | on-device: high  ±sd   low  ±sd  [min..max high] range | NOAA hilo: high  low range | curve lag pred / obs (r)  | obs extrema high / low | published high low
    """)
    for a in analysis.stations {
        let o = a.offsets
        let noaa = refOfficial.flatMap { ref in official[a.station.code].map { OffsetAnalysis.offsets(reference: ref, station: $0) } }
        let pub = published[a.station.code].map { "\(m(($0.timeOffsetHighTide ?? 0) * 60)) \(m(($0.timeOffsetLowTide ?? 0) * 60))  ×\(r($0.heightOffsetHighTide))" } ?? ""
        let span = o?.high.map { String(format: "[%+4.0f..%+4.0f]", $0.minimum / 60, $0.maximum / 60) } ?? "               "
        let obs = a.observedCurveLag.map { String(format: "%@ (%.3f)", m($0.lag), $0.correlation) } ?? "             "
        print("\(a.station.shortName.padding(toLength: 16, withPad: " ", startingAt: 0)) \(a.station.code) | "
              + "\(m(o?.high?.mean)) \(sd(o?.high)) \(m(o?.low?.mean)) \(sd(o?.low)) \(span) \(r(o?.rangeRatio)) | "
              + "\(m(noaa?.high?.mean)) \(m(noaa?.low?.mean)) \(r(noaa?.rangeRatio)) | "
              + "\(m(a.predictedCurveLag?.lag)) / \(obs) | \(m(a.observedHigh?.mean)) / \(m(a.observedLow?.mean)) | \(pub)")
    }
}
