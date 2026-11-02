import AppIntents
import Charts
import SwiftUI
import TideKit
import WidgetKit

@main
struct TideWidgetBundle: WidgetBundle {
    var body: some Widget {
        TideWidget()
    }
}

struct TideWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: AppGroup.widgetKind, intent: SelectStationIntent.self, provider: TideProvider()) { entry in
            TideWidgetView(entry: entry)
        }
        .configurationDisplayName("Tide & Surge")
        .description("Water level now, the next tides and flood risk for one station.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

// MARK: - Root

struct TideWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TideEntry

    var body: some View {
        content
            .containerBackground(for: .widget) {
                if family == .accessoryCircular { AccessoryWidgetBackground() } else { Color(.systemBackground) }
            }
    }

    @ViewBuilder private var content: some View {
        switch entry.state {
        case .ready(let snap):
            ready(snap)
                .widgetURL(AppGroup.deepLink(stationID: snap.stationID))
        case .needsStation:
            MessageView(title: "Tide & Surge", message: "Touch and hold, then Edit Widget to choose a station. Favorites are used by default.")
        case .unavailable(let name, let message):
            MessageView(title: name, message: message)
        }
    }

    @ViewBuilder private func ready(_ snap: ForecastSnapshot) -> some View {
        let m = WidgetModel(snap: snap, date: entry.date, unit: entry.unit)
        switch family {
        case .systemSmall: SmallTideView(m: m)
        case .systemMedium: MediumTideView(m: m)
        case .systemLarge: LargeTideView(m: m)
        case .accessoryRectangular: RectangularTideView(m: m)
        case .accessoryCircular: CircularTideView(m: m)
        case .accessoryInline: InlineTideView(m: m)
        default: SmallTideView(m: m)
        }
    }
}

/// Everything a view needs, computed once per entry.
struct WidgetModel {
    let snap: ForecastSnapshot
    let date: Date
    let unit: LengthUnit

    var tz: TimeZone { snap.timeZone }
    var level: Double? { snap.level(at: date) }
    var rising: Bool? { snap.isRising(at: date) }
    var next: [ForecastSnapshot.Event] { snap.nextEvents(after: date, limit: 6) }
    var outlook: (category: FloodCategory, minorProbability: Double) { snap.floodOutlook(after: date) }
    var stale: Bool { snap.isStale(at: date) }

    func len(_ v: Double?, signed: Bool = false) -> String { v.map { Fmt.length($0, unit, signed: signed) } ?? "–" }
    var arrow: String { rising == true ? "arrow.up.right" : "arrow.down.right" }
    func eventTitle(_ e: ForecastSnapshot.Event) -> String { e.kind == .high ? "High" : "Low" }

    /// Show the risk line only when there is something to say.
    var riskText: String? {
        let o = outlook
        if o.category > .none { return o.category.label }
        if o.minorProbability >= 0.1 { return "\(Fmt.percent(o.minorProbability)) chance of flooding" }
        return nil
    }
}

// MARK: - Shared pieces

struct MessageView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: "water.waves").font(.caption.weight(.semibold)).lineLimit(1)
            Text(message).font(.caption2).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LevelHeader: View {
    let m: WidgetModel
    var size: CGFloat = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(m.snap.stationName).font(.caption.weight(.semibold)).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(m.len(m.level))
                    .font(.system(size: size, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.6).lineLimit(1)
                if m.rising != nil {
                    Image(systemName: m.arrow).font(.caption.weight(.bold)).foregroundStyle(.blue)
                        .accessibilityLabel(m.rising == true ? "Rising" : "Falling")
                }
            }
            if let a = m.snap.currentAnomaly {
                Text("\(m.len(a, signed: true)) vs tide table")
                    .font(.caption2)
                    .foregroundStyle(abs(a) >= 0.3 ? Color.orange : Color.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct EventRow: View {
    let m: WidgetModel
    let e: ForecastSnapshot.Event
    var showRisk = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: e.kind == .high ? "arrow.up.to.line" : "arrow.down.to.line")
                .font(.caption2).foregroundStyle(e.kind == .high ? .blue : .teal)
            Text("\(m.eventTitle(e)) \(Fmt.time(e.date, in: m.tz))").font(.caption).lineLimit(1)
            Spacer(minLength: 4)
            Text(m.len(e.total)).font(.caption.weight(.semibold)).monospacedDigit()
            if showRisk, e.kind == .high, e.category > .none || (e.minorFloodProbability ?? 0) >= 0.05 {
                Text(e.category > .none ? e.category.shortLabel : Fmt.percent(e.minorFloodProbability ?? 0))
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background((e.category > .none ? e.category.color : Color.orange).opacity(0.2), in: Capsule())
                    .foregroundStyle(e.category > .none ? e.category.color : Color.orange)
            }
        }
    }
}

struct RefreshButton: View {
    let stationID: String

    var body: some View {
        Button(intent: RefreshTideIntent(stationID: stationID)) {
            Image(systemName: "arrow.clockwise").font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Refresh forecast")
    }
}

struct UpdatedLine: View {
    let m: WidgetModel

    var body: some View {
        HStack(spacing: 4) {
            if m.stale { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            Text("Updated \(Fmt.time(m.snap.issued, in: m.tz))")
            if !m.snap.alertTitles.isEmpty {
                Text("· \(m.snap.alertTitles[0])").foregroundStyle(.red).lineLimit(1)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

/// Forecast total with 80 % band, predicted tide, minor flood line and "now".
struct TideMiniChart: View {
    let m: WidgetModel
    let hoursBack: Double
    let hoursAhead: Double

    var body: some View {
        let from = m.date - hoursBack * 3_600, to = m.date + hoursAhead * 3_600
        let pts = m.snap.chartPoints(from: from, to: to)
        let u = m.unit
        let minor = m.snap.minorFlood.map(u.fromMeters)
        let values = pts.flatMap { [$0.lower, $0.upper, $0.predicted, $0.total].compactMap { $0 } }.map(u.fromMeters)
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        // Show the flood line only when it is near the data.
        let showMinor = minor.map { $0 - hi < (hi - lo) * 0.5 } ?? false
        let top = showMinor ? max(hi, minor ?? hi) : hi
        let pad = max((top - lo) * 0.08, 0.05)

        Chart {
            ForEach(pts) { p in
                if let l = p.lower, let h = p.upper {
                    AreaMark(x: .value("Time", p.date), yStart: .value("Low", u.fromMeters(l)), yEnd: .value("High", u.fromMeters(h)))
                        .foregroundStyle(Color.orange.opacity(0.18))
                }
                if let pr = p.predicted {
                    LineMark(x: .value("Time", p.date), y: .value("Level", u.fromMeters(pr)), series: .value("Series", "Tide table"))
                        .foregroundStyle(Color.secondary)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                }
                if let t = p.total {
                    LineMark(x: .value("Time", p.date), y: .value("Level", u.fromMeters(t)), series: .value("Series", "Forecast"))
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                }
            }
            if showMinor, let minor {
                RuleMark(y: .value("Minor flood", minor))
                    .foregroundStyle(Color.red.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            RuleMark(x: .value("Now", m.date))
                .foregroundStyle(Color.primary.opacity(0.35))
            if let now = m.level {
                PointMark(x: .value("Now", m.date), y: .value("Level", u.fromMeters(now)))
                    .foregroundStyle(Color.orange)
                    .symbolSize(28)
            }
        }
        .chartXScale(domain: from...to)
        .chartYScale(domain: (lo - pad)...(top + pad))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: hoursAhead > 30 ? 12 : 6)) { value in
                AxisGridLine().foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d.formatted(Date.FormatStyle(timeZone: m.tz).hour())).font(.system(size: 9))
                    }
                }
            }
        }
        .chartLegend(.hidden)
    }
}

// MARK: - Home screen

struct SmallTideView: View {
    let m: WidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LevelHeader(m: m)
            Spacer(minLength: 0)
            ForEach(m.next.prefix(2)) { e in EventRow(m: m, e: e) }
            if let risk = m.riskText {
                Label(risk, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(m.outlook.category > .none ? m.outlook.category.color : Color.orange)
                    .lineLimit(1)
            }
        }
    }
}

struct MediumTideView: View {
    let m: WidgetModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                LevelHeader(m: m, size: 28)
                Spacer(minLength: 0)
                ForEach(m.next.prefix(2)) { e in EventRow(m: m, e: e) }
            }
            .frame(maxWidth: 150)
            VStack(alignment: .trailing, spacing: 2) {
                HStack {
                    if let risk = m.riskText {
                        Text(risk).font(.caption2.weight(.semibold)).foregroundStyle(Color.orange).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    RefreshButton(stationID: m.snap.stationID)
                }
                TideMiniChart(m: m, hoursBack: 3, hoursAhead: 21)
            }
        }
    }
}

struct LargeTideView: View {
    let m: WidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                LevelHeader(m: m, size: 34)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    RefreshButton(stationID: m.snap.stationID)
                    if let risk = m.riskText {
                        Text(risk).font(.caption.weight(.semibold))
                            .foregroundStyle(m.outlook.category > .none ? m.outlook.category.color : Color.orange)
                    } else if m.snap.minorFlood != nil {
                        Text("No flooding expected").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            TideMiniChart(m: m, hoursBack: 6, hoursAhead: 42)
                .frame(maxHeight: 150)
            VStack(spacing: 4) {
                ForEach(m.next.prefix(5)) { e in EventRow(m: m, e: e, showRisk: true) }
            }
            Spacer(minLength: 0)
            UpdatedLine(m: m)
        }
    }
}

// MARK: - Lock screen

struct RectangularTideView: View {
    let m: WidgetModel

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: m.arrow)
                Text(m.len(m.level)).font(.headline)
                if let a = m.snap.currentAnomaly, abs(a) >= 0.15 {
                    Text(m.len(a, signed: true)).font(.caption2)
                }
            }
            if let e = m.next.first {
                Text("\(m.eventTitle(e)) \(Fmt.time(e.date, in: m.tz)) · \(m.len(e.total))").font(.caption)
            }
            Text(m.riskText ?? m.snap.stationName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CircularTideView: View {
    let m: WidgetModel

    var body: some View {
        // Gauge spans the coming day's low to high water.
        let day = m.snap.chartPoints(from: m.date, to: m.date + 24 * 3_600).compactMap(\.total)
        let lo = day.min() ?? 0, hi = max(day.max() ?? 1, lo + 0.01)
        let v = min(max(m.level ?? lo, lo), hi)
        Gauge(value: v, in: lo...hi) {
            Image(systemName: "water.waves")
        } currentValueLabel: {
            Text(String(format: "%.1f", m.unit.fromMeters(v)))
        }
        .gaugeStyle(.accessoryCircular)
    }
}

struct InlineTideView: View {
    let m: WidgetModel

    var body: some View {
        if let e = m.next.first {
            Label("\(m.eventTitle(e)) \(Fmt.time(e.date, in: m.tz)) \(m.len(e.total))",
                  systemImage: e.kind == .high ? "arrow.up.to.line" : "arrow.down.to.line")
        } else {
            Label(m.len(m.level), systemImage: "water.waves")
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    TideWidget()
} timeline: {
    TideEntry(date: Date(), state: .ready(.sample()), unit: .feet)
}

#Preview("Medium", as: .systemMedium) {
    TideWidget()
} timeline: {
    TideEntry(date: Date(), state: .ready(.sample()), unit: .feet)
}

#Preview("Large", as: .systemLarge) {
    TideWidget()
} timeline: {
    TideEntry(date: Date(), state: .ready(.sample()), unit: .feet)
}

#Preview("Lock screen", as: .accessoryRectangular) {
    TideWidget()
} timeline: {
    TideEntry(date: Date(), state: .ready(.sample()), unit: .feet)
}
