import Foundation
import SwiftUI
import TideKit

enum Fmt {
    static func length(_ meters: Double, _ unit: LengthUnit, signed: Bool = false, digits: Int? = nil) -> String {
        let v = unit.fromMeters(meters)
        let d = digits ?? (unit == .feet ? 1 : 2)
        let s = String(format: "%\(signed ? "+" : "").\(d)f", v)
        return "\(s) \(unit.symbol)"
    }

    static func time(_ date: Date, in tz: TimeZone) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: tz))
    }

    static func dayTime(_ date: Date, in tz: TimeZone) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: tz)
        style = style.weekday(.abbreviated)
        return date.formatted(style)
    }

    static func percent(_ p: Double) -> String {
        if p < 0.01 { return "<1%" }
        if p > 0.99 { return ">99%" }
        return p.formatted(.percent.precision(.fractionLength(0)))
    }

    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func compass(_ degrees: Double) -> String {
        let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE", "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]
        return points[Int((degrees / 22.5).rounded()) % 16]
    }
}

extension FloodCategory {
    var color: Color {
        switch self {
        case .none: return .green
        case .action: return .yellow
        case .minor: return .orange
        case .moderate: return .red
        case .major: return .purple
        }
    }

    var shortLabel: String {
        switch self {
        case .none: return "Normal"
        case .action: return "Action"
        case .minor: return "Minor"
        case .moderate: return "Moderate"
        case .major: return "Major"
        }
    }
}
