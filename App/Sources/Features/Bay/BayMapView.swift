import MapKit
import SwiftUI
import TideKit

/// The bay on a quiet basemap with one live marker per station: a disc that
/// fills with water from low (empty) to high (full) over the tidal day, a
/// rising/falling tick, and an amber ring while it is high water there.
/// Point Reyes, out on the open coast, sits in an inset.
struct BayMapView: View {
    let day: BayDay
    let clock: BayClock
    let unit: LengthUnit
    @Binding var selected: String

    @State private var position: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.765, longitude: -122.27),
        span: MKCoordinateSpan(latitudeDelta: 0.68, longitudeDelta: 0.5)))

    /// Where each station's name goes, chosen so neighbours don't collide.
    /// Stations without an entry show a name only when selected.
    static let labels: [String: Alignment] = [
        "9414290": .bottom, "9414806": .leading, "9414863": .trailing, "9414750": .trailing,
        "9414523": .leading, "9414575": .leading, "9415056": .trailing, "9415102": .bottom, "9415144": .top,
        "9414458": .trailing,
    ]

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(day.rows.filter { $0.station.region != .coast }) { row in
                Annotation(row.station.shortName,
                           coordinate: CLLocationCoordinate2D(latitude: row.station.latitude, longitude: row.station.longitude),
                           anchor: .center) {
                    StationPin(row: row, start: day.start, clock: clock, unit: unit,
                               label: Self.labels[row.station.code] ?? (selected == row.station.code ? .bottom : nil),
                               isSelected: selected == row.station.code)
                        .onTapGesture { selected = row.station.code }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls { MapScaleView() }
        .overlay(alignment: .topLeading) {
            if let coast = day.rows.first(where: { $0.station.region == .coast }) {
                CoastInset(row: coast, start: day.start, clock: clock, unit: unit,
                           isSelected: selected == coast.station.code)
                    .onTapGesture { selected = coast.station.code }
                    .padding(8)
            }
        }
    }
}

/// A station marker. Reads the clock, so only markers redraw while playing.
private struct StationPin: View {
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

/// The open-coast reference, off the edge of the bay map.
private struct CoastInset: View {
    let row: BayDay.Row
    let start: Date
    let clock: BayClock
    let unit: LengthUnit
    let isSelected: Bool

    var body: some View {
        let t = clock.time
        HStack(spacing: 7) {
            WaterDisc(fraction: row.fraction(at: t, start: start), rising: row.rising(at: t, start: start),
                      atHigh: row.extreme(near: t).map { $0.kind == .high } ?? false, size: 18, emphasized: isSelected)
            VStack(alignment: .leading, spacing: 0) {
                Text("‹ OPEN COAST").font(.system(size: 8, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.inkSecondary)
                Text(row.station.shortName).font(.caption2.weight(.semibold)).foregroundStyle(Theme.ink)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay { if isSelected { Capsule().strokeBorder(Theme.ink.opacity(0.5), lineWidth: 1) } }
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.station.name), open coast")
        .accessibilityValue(BayText.state(row: row, at: t, start: start, unit: unit))
        .accessibilityAddTraits(.isButton)
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
