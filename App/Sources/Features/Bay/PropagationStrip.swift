import SwiftUI
import TideKit

/// Time runs left to right, stations top to bottom in the order the tide
/// reaches them; each cell is shaded from low water (pale) to high water
/// (deep harbor) for that station. The amber dots mark each high water, so
/// the diagonal they draw is the tide moving through the bay. The cursor
/// follows the animation clock; drag anywhere to scrub.
struct PropagationStrip: View {
    let day: BayDay
    let clock: BayClock
    @Binding var selected: String
    let onScrub: (Date) -> Void

    static let rowHeight: CGFloat = 13
    static let groupGap: CGFloat = 7
    static let labelWidth: CGFloat = 86
    static let axisHeight: CGFloat = 18

    private var tz: TimeZone { SFBay.timeZone }

    /// Row tops, with a gap between bay arms.
    private var layout: [(row: BayDay.Row, y: CGFloat)] {
        var y: CGFloat = 0
        var out: [(BayDay.Row, CGFloat)] = []
        var last: BayRegion?
        for r in day.rows {
            if let l = last, l != r.station.region { y += Self.groupGap }
            out.append((r, y))
            y += Self.rowHeight
            last = r.station.region
        }
        return out
    }

    var body: some View {
        let layout = layout
        let height = (layout.last?.y ?? 0) + Self.rowHeight
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                ForEach(layout, id: \.row.id) { item in
                    Text(item.row.station.shortName)
                        .font(.system(size: 10, weight: item.row.station.code == selected ? .bold : .regular))
                        .foregroundStyle(item.row.station.code == selected ? Theme.ink : Theme.inkSecondary)
                        .lineLimit(1)
                        .frame(height: Self.rowHeight)
                        .offset(y: item.y)
                }
            }
            .frame(width: Self.labelWidth, height: height, alignment: .topTrailing)
            .accessibilityHidden(true)

            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    HeatCanvas(day: day, layout: layout, selected: selected)
                        .frame(width: w, height: height)
                    Cursor(day: day, clock: clock, width: w, height: height)
                    Axis(day: day, width: w, tz: tz).offset(y: height + 4)
                }
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    scrub(p.x, width: w)
                    if let hit = layout.last(where: { $0.y <= p.y }), p.y <= hit.y + Self.rowHeight {
                        selected = hit.row.station.code
                    }
                }
                // Horizontal drags scrub; vertical ones keep scrolling the page.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 6).onChanged { g in
                        guard abs(g.translation.width) > abs(g.translation.height) else { return }
                        scrub(g.location.x, width: w)
                    }
                )
            }
            .frame(height: height + Self.axisHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("High water through the bay")
        .accessibilityValue(summary)
        .accessibilityAdjustableAction { direction in
            let step: TimeInterval = direction == .increment ? 1_800 : -1_800
            onScrub(day.clamp(clock.time + step))
        }
    }

    private func scrub(_ x: CGFloat, width: CGFloat) {
        let f = Double(min(max(0, x), width) / max(width, 1))
        onScrub(day.start + f * day.end.timeIntervalSince(day.start))
    }

    /// "High water reaches Sausalito 14 minutes after San Francisco, …"
    private var summary: String {
        guard let ref = day.row(SFBay.referenceCode), let refHigh = ref.extremes.first(where: { $0.kind == .high }) else { return "" }
        let pieces = day.rows.compactMap { r -> String? in
            guard r.station.code != SFBay.referenceCode,
                  let h = r.extremes.filter({ $0.kind == .high }).min(by: { abs($0.date.timeIntervalSince(refHigh.date)) < abs($1.date.timeIntervalSince(refHigh.date)) })
            else { return nil }
            return "\(r.station.shortName) \(Fmt.lagSpoken(h.date.timeIntervalSince(refHigh.date)))"
        }
        return "After high water at San Francisco at \(Fmt.time(refHigh.date, in: tz)): " + pieces.joined(separator: "; ")
    }
}

/// The heat map itself, drawn once per day/selection; the cursor is separate.
private struct HeatCanvas: View {
    let day: BayDay
    let layout: [(row: BayDay.Row, y: CGFloat)]
    let selected: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            let span = day.end.timeIntervalSince(day.start)
            let cellStep = 2  // 10-minute cells
            let ramp = scheme == .dark ? Ramp.dark : Ramp.light
            for item in layout {
                let r = item.row
                let n = r.values.count
                guard n > 1 else { continue }
                var i = 0
                while i < n - 1 {
                    let x0 = CGFloat(Double(i) * BayDay.step / span) * size.width
                    let x1 = CGFloat(Double(min(i + cellStep, n - 1)) * BayDay.step / span) * size.width
                    let v = r.values[i]
                    let f = r.high - r.low > 1e-6 ? (v - r.low) / (r.high - r.low) : 0.5
                    let rect = CGRect(x: x0, y: item.y, width: x1 - x0 + 0.6, height: PropagationStrip.rowHeight - 1)
                    ctx.fill(Path(rect), with: .color(ramp.color(f)))
                    i += cellStep
                }
                if r.station.code == selected {
                    let rect = CGRect(x: 0, y: item.y - 0.5, width: size.width, height: PropagationStrip.rowHeight)
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(scheme == .dark ? .white.opacity(0.8) : .black.opacity(0.6)), lineWidth: 1)
                }
                for e in r.extremes where e.kind == .high && e.date >= day.start && e.date <= day.end {
                    let x = CGFloat(e.date.timeIntervalSince(day.start) / span) * size.width
                    let c = CGPoint(x: x, y: item.y + (PropagationStrip.rowHeight - 1) / 2)
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)), with: .color(ramp.dotRing))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)), with: .color(ramp.dot))
                }
            }
        }
    }
}

/// Harbor ramp for the strip, matched to the calendar's heat scale but
/// continuous. Light: pale to deep; dark: dim to bright.
private struct Ramp {
    let stops: [(Double, Double, Double)]
    let dot: Color
    let dotRing: Color

    static func rgb(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    static let light = Ramp(stops: [0xEEF4F8, 0xAECDE4, 0x74A8D1, 0x3A7DB5, 0x1A5486].map(rgb),
                            dot: Color(hex: 0xE08A3C), dotRing: .white)
    static let dark = Ramp(stops: [0x0F2230, 0x1D4B69, 0x2A6893, 0x4890C4, 0x86C0EA].map(rgb),
                           dot: Color(hex: 0xF0A266), dotRing: Color(hex: 0x0B1820))

    func color(_ f: Double) -> Color {
        let x = min(1, max(0, f)) * Double(stops.count - 1)
        let i = min(stops.count - 2, Int(x))
        let w = x - Double(i)
        let a = stops[i], b = stops[i + 1]
        return Color(red: a.0 + (b.0 - a.0) * w, green: a.1 + (b.1 - a.1) * w, blue: a.2 + (b.2 - a.2) * w)
    }
}

private extension Color {
    init(hex: UInt32) {
        let c = Ramp.rgb(hex)
        self.init(red: c.0, green: c.1, blue: c.2)
    }
}

/// The animation cursor: a hairline across all rows with a knob on top.
private struct Cursor: View {
    let day: BayDay
    let clock: BayClock
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        let span = day.end.timeIntervalSince(day.start)
        let x = CGFloat(day.clamp(clock.time).timeIntervalSince(day.start) / span) * width
        ZStack(alignment: .top) {
            Rectangle().fill(Theme.ink).frame(width: 1.5, height: height + 6)
            Circle().fill(Theme.ink).frame(width: 7, height: 7).offset(y: -5)
        }
        .offset(x: x - 3.5, y: -3)
        .frame(width: 7, alignment: .center)
        .allowsHitTesting(false)
    }
}

/// Hour ticks on the station clock.
private struct Axis: View {
    let day: BayDay
    let width: CGFloat
    let tz: TimeZone

    private var ticks: [Date] {
        var cal = Calendar.current
        cal.timeZone = tz
        var out: [Date] = []
        var t = cal.nextDate(after: day.start, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? day.start
        while t <= day.end {
            if cal.component(.hour, from: t) % 6 == 0 { out.append(t) }
            t += 3_600
        }
        return out
    }

    var body: some View {
        let span = day.end.timeIntervalSince(day.start)
        ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.self) { t in
                let x = CGFloat(t.timeIntervalSince(day.start) / span) * width
                Text(label(t))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize()
                    .frame(width: 60)
                    .offset(x: min(max(x - 30, -14), width - 46))
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityHidden(true)
    }

    private func label(_ d: Date) -> String {
        var cal = Calendar.current
        cal.timeZone = tz
        if cal.component(.hour, from: d) == 0 { return d.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated)) }
        return d.formatted(Date.FormatStyle(timeZone: tz).hour())
    }
}
