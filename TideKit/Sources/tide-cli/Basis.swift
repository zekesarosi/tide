import Foundation
import TideKit

/// `tide-cli basis <start ISO8601> <hours> <step seconds> <M2,S2,...> <out.csv>`
///
/// Writes the harmonic basis (f·cos(V+u), f·sin(V+u) per constituent) on a
/// regular time grid, one row per instant: `unix_seconds, c1, s1, c2, s2, ...`.
/// Offline tidal analysis (scripts/sfbay) fits constants against this so they
/// predict in exactly TideKit's convention.
func runBasis(_ args: [String]) {
    guard args.count == 5,
          let start = ISO8601DateFormatter().date(from: args[0]),
          let hours = Double(args[1]), let step = Double(args[2]), step > 0 else {
        print("usage: tide-cli basis <start ISO8601> <hours> <step seconds> <M2,S2,...> <out.csv>")
        exit(2)
    }
    let names = args[3].split(separator: ",").map(String.init)
    let defs = names.map { name -> ConstituentDefinition in
        guard let d = ConstituentCatalog.definition(named: name) else { print("unknown constituent \(name)"); exit(2) }
        return d
    }
    var out = "unix," + names.map { "\($0)_c,\($0)_s" }.joined(separator: ",") + "\n"
    var t = start
    let end = start + hours * 3_600
    while t < end {
        let p = HarmonicBasis.phasors(defs, at: t)
        out += String(format: "%.0f", t.timeIntervalSince1970) + "," + p.map { String(format: "%.9f,%.9f", $0.cos, $0.sin) }.joined(separator: ",") + "\n"
        t += step
    }
    do { try out.write(toFile: args[4], atomically: true, encoding: .utf8) } catch { print(error); exit(1) }
    print("wrote \(names.count) constituents × \(Int(hours * 3_600 / step)) steps to \(args[4])")
}
