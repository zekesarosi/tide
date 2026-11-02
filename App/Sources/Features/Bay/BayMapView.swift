import MapKit
import SwiftUI
import TideKit

/// Live bay station markers for the Map tab: a disc that fills with water
/// from low (empty) to high (full) over the tidal day, a rising/falling
/// tick, and an amber ring while it is high water there.
enum BayMarkers {
    /// Where each station's name goes, chosen so neighbours don't collide at
    /// whole-bay zoom. Stations without an entry show a name only when
    /// selected or when zoomed in.
    static let labels: [String: Alignment] = [
        "9414290": .bottom, "9414806": .leading, "9414863": .trailing, "9414750": .trailing,
        "9414523": .leading, "9414575": .leading, "9415056": .trailing, "9415102": .bottom, "9415144": .top,
        "9414458": .trailing, "9415020": .trailing,
    ]
}

/// A station marker. Reads the clock, so only markers redraw while playing.
struct BayPin: View {
    let row: BayDay.Row
    let start: Date
    let clock: BayClock
    let unit: LengthUnit
    let label: Alignment?
    let isSelected: Bool

    var body: some View {
        let t = clock.time
        let f = row.fraction(at: t, start: start)
        let rising = row.rising(at: t, start: start)
        let atHigh = row.extreme(near: t).map { $0.kind == .high } ?? false
        let disc = WaterDisc(fraction: f, rising: rising, atHigh: atHigh, size: isSelected ? 24 : 20, emphasized: isSelected)
            .frame(width: 30, height: 30)
        // The label sits on one side and an invisible copy on the other, so
        // the disc stays at the centre the annotation is anchored on.
        Group {
            if let label {
                let tag = tag(t)
                switch label {
                case .leading, .trailing:
                    HStack(spacing: 1) {
                        tag.opacity(label == .leading ? 1 : 0)
                        disc
                        tag.opacity(label == .trailing ? 1 : 0)
                    }
                default:
                    VStack(spacing: 0) {
                        tag.opacity(label == .top ? 1 : 0)
                        disc
                        tag.opacity(label == .top ? 0 : 1)
                    }
                }
            } else {
                disc
            }
        }
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(CenterSquare(side: 44))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.station.name)
            .accessibilityValue(BayText.state(row: row, at: t, start: start, unit: unit))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func tag(_ t: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(row.station.shortName)
                .font(.caption2.weight(isSelected ? .bold : .semibold))
                .foregroundStyle(Theme.ink)
            if isSelected {
                Text(Fmt.length(row.value(at: t, start: start), unit))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Theme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .fixedSize()
        .allowsHitTesting(false)
    }
}

/// A square hit area around the middle of a view (the disc, not its label).
private struct CenterSquare: Shape {
    let side: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side))
    }
}

/// A disc that fills with harbor blue from low water (empty) to high water
/// (full), with a small tick on top (rising) or bottom (falling), ringed in
/// swell amber at high water.
struct WaterDisc: View {
    let fraction: Double
    let rising: Bool
    let atHigh: Bool
    var size: CGFloat = 20
    var emphasized = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.surface)
            Rectangle()
                .fill(Theme.harbor.opacity(0.85))
                .frame(height: size * CGFloat(0.12 + 0.88 * fraction))
                .frame(maxHeight: .infinity, alignment: .bottom)
                .clipShape(Circle())
            Circle().strokeBorder(atHigh ? Theme.swell : Theme.harbor, lineWidth: atHigh ? 2.5 : (emphasized ? 2 : 1.2))
        }
        .frame(width: size, height: size)
        .overlay(alignment: rising ? .top : .bottom) {
            Image(systemName: rising ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(.system(size: 6))
                .foregroundStyle(Theme.ink.opacity(0.75))
                .offset(y: rising ? -6 : 6)
        }
        .background {
            if atHigh { Circle().fill(Theme.swell.opacity(0.22)).frame(width: size + 12, height: size + 12) }
        }
        .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
    }
}

/// Spoken and readout phrasing for the bay screen.
enum BayText {
    static func state(row: BayDay.Row, at t: Date, start: Date, unit: LengthUnit) -> String {
        let tz = SFBay.timeZone
        var parts = [Fmt.length(row.value(at: t, start: start), unit), row.rising(at: t, start: start) ? "rising" : "falling"]
        if let e = row.extreme(near: t) {
            parts.append("\(Phrase.eventName(e.kind).lowercased()) water now")
        } else if let n = row.nextExtreme(after: t) {
            parts.append("\(Phrase.eventName(n.kind).lowercased()) at \(Fmt.time(n.date, in: tz))")
        }
        return parts.joined(separator: ", ")
    }
}
