import SwiftUI
import TideKit

/// A month of daily highest water as heat-mapped circles. The scale spans the
/// month on screen, so the colors always answer "which days in this month run
/// highest?"; the month's top day wears an amber ring. Swipe or use the
/// chevrons to change month; tap a day for its hourly forecast.
struct TideCalendarView: View {
    let forecast: WaterLevelForecast
    let unit: LengthUnit
    let tz: TimeZone

    @State private var monthIndex = 0
    @State private var forward = true
    @State private var selected: Date?
    @State private var hourly: HourlyDay?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.forecastNow) private var forecastNow
    private var now: Date { forecastNow ?? Date() }

    /// Highest water on one station day.
    struct HourlyDay: Identifiable {
        var id: Date { day }
        let day: Date
    }

    struct DayPeak: Hashable {
        enum Source { case observed, forecast, outlook }
        let day: Date
        let date: Date
        let height: Double
        let source: Source
    }

    private var calendar: Calendar {
        var c = Calendar.current
        c.timeZone = tz
        return c
    }

    // MARK: Data

    /// Highest water per station day: the forecast highs, and the observed
    /// maximum for days (or the part of today) already measured.
    private var peaks: [Date: DayPeak] {
        let cal = calendar
        var out: [Date: DayPeak] = [:]
        func offer(_ p: DayPeak) {
            if let cur = out[p.day], cur.height >= p.height { return }
            out[p.day] = p
        }
        for e in forecast.events where e.kind == .high {
            let outlook = forecast.weatherHorizon.map { e.date > $0 } ?? false
            offer(DayPeak(day: cal.startOfDay(for: e.date), date: e.date, height: e.total, source: outlook ? .outlook : .forecast))
        }
        let byDay = Dictionary(grouping: forecast.observed.points) { cal.startOfDay(for: $0.date) }
        for (day, pts) in byDay {
            if let m = pts.max(by: { $0.value < $1.value }) {
                offer(DayPeak(day: day, date: m.date, height: m.value, source: .observed))
            }
        }
        return out
    }

    /// First day of each month from now to the forecast horizon.
    private var months: [Date] {
        let cal = calendar
        guard var m = cal.dateInterval(of: .month, for: now)?.start else { return [] }
        var out: [Date] = []
        while m <= forecast.horizon {
            out.append(m)
            guard let next = cal.date(byAdding: .month, value: 1, to: m) else { break }
            m = next
        }
        return out
    }

    // MARK: Body

    var body: some View {
        let months = months
        let index = min(monthIndex, max(months.count - 1, 0))
        if let month = months.indices.contains(index) ? months[index] : nil {
            let all = peaks
            let days = daysIn(month)
            let monthPeaks = days.compactMap { all[$0] }
            let top = monthPeaks.max { $0.height < $1.height }
            let lo = monthPeaks.map(\.height).min() ?? 0, hi = monthPeaks.map(\.height).max() ?? 1
            let focus = selected.flatMap { all[$0] } ?? top

            VStack(alignment: .leading, spacing: 14) {
                header(month: month, index: index, count: months.count, top: top)

                MonthGrid(month: month, days: days, peaks: all, range: lo...hi, top: top?.day,
                          selected: focus?.day, today: calendar.startOfDay(for: now),
                          calendar: calendar, unit: unit, tz: tz, reduceMotion: reduceMotion) { day in
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75)) {
                        selected = day
                    }
                    hourly = HourlyDay(day: day)
                }
                .id(month)
                .transition(reduceMotion ? .opacity : .push(from: forward ? .trailing : .leading))
                .simultaneousGesture(
                    DragGesture(minimumDistance: 24).onEnded { g in
                        guard abs(g.translation.width) > abs(g.translation.height) * 1.5, abs(g.translation.width) > 50 else { return }
                        go(g.translation.width < 0 ? 1 : -1, count: months.count)
                    }
                )

                if !monthPeaks.isEmpty { legend(lo: lo, hi: hi) }
                if let focus {
                    DayDetail(peak: focus, isTop: focus.day == top?.day, events: events(on: focus.day),
                              unit: unit, tz: tz, now: now) { hourly = HourlyDay(day: focus.day) }
                }
            }
            .clipped()
            .sheet(item: $hourly) { h in
                DayForecastView(forecast: forecast, day: h.day, unit: unit, tz: tz)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func go(_ step: Int, count: Int) {
        let next = monthIndex + step
        guard (0..<count).contains(next) else { return }
        forward = step > 0
        selected = nil
        withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86)) { monthIndex = next }
    }

    private func daysIn(_ month: Date) -> [Date] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    private func events(on day: Date) -> [ForecastEvent] {
        forecast.events.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }

    // MARK: Pieces

    private func header(month: Date, index: Int, count: Int, top: DayPeak?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(month.formatted(Date.FormatStyle(timeZone: tz).month(.wide)))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.opacity)
                if let top {
                    (Text("Highest ") + Text(top.day.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated).day()))
                        + Text(" · ") + Text(Fmt.length(top.height, unit)).foregroundStyle(Theme.swellText).fontWeight(.semibold))
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                chevron("chevron.left", label: "Previous month", enabled: index > 0) { go(-1, count: count) }
                chevron("chevron.right", label: "Next month", enabled: index < count - 1) { go(1, count: count) }
            }
        }
    }

    private func chevron(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(Theme.neutralWash, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.harbor : Theme.inkSecondary.opacity(0.35))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func legend(lo: Double, hi: Double) -> some View {
        HStack(spacing: 8) {
            Text(Fmt.length(lo, unit))
            HStack(spacing: 4) {
                ForEach(0..<HeatScale.steps, id: \.self) { i in
                    Circle().fill(HeatScale.fill[i]).frame(width: 10, height: 10)
                }
            }
            Text(Fmt.length(hi, unit))
            Spacer()
            HStack(spacing: 5) {
                Circle().strokeBorder(Theme.swell, lineWidth: 1.5).frame(width: 11, height: 11)
                Text("Highest this month")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(Theme.inkSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Color scale from \(Fmt.length(lo, unit)) to \(Fmt.length(hi, unit)); ringed day is the month's highest")
    }
}

/// Five steps of harbor blue, light → dark in light mode and dim → bright in
/// dark mode, each with the ink that reads on it (checked with APCA).
enum HeatScale {
    static let steps = 5
    static let fill: [Color] = [
        Color(light: 0xDCEAF4, dark: 0x163447),
        Color(light: 0xAECDE4, dark: 0x1D4B69),
        Color(light: 0x74A8D1, dark: 0x2A6893),
        Color(light: 0x3A7DB5, dark: 0x4890C4),
        Color(light: 0x1A5486, dark: 0x86C0EA),
    ]
    static let text: [Color] = [
        Color(light: 0x0D2230, dark: 0xE8F0F4),
        Color(light: 0x0D2230, dark: 0xE8F0F4),
        Color(light: 0xFFFFFF, dark: 0xE8F0F4),
        Color(light: 0xFFFFFF, dark: 0xE8F0F4),
        Color(light: 0xFFFFFF, dark: 0x0B1820),
    ]

    static func step(_ v: Double, in range: ClosedRange<Double>) -> Int {
        let span = range.upperBound - range.lowerBound
        guard span > 1e-6 else { return 2 }
        return min(steps - 1, max(0, Int(((v - range.lowerBound) / span) * Double(steps))))
    }
}

/// The 7-column grid for one month. Its own view so each month's circles can
/// ripple in when it appears.
private struct MonthGrid: View {
    let month: Date
    let days: [Date]
    let peaks: [Date: TideCalendarView.DayPeak]
    let range: ClosedRange<Double>
    let top: Date?
    let selected: Date?
    let today: Date
    let calendar: Calendar
    let unit: LengthUnit
    let tz: TimeZone
    let reduceMotion: Bool
    let onSelect: (Date) -> Void

    @State private var appeared = false

    private var leading: Int {
        guard let first = days.first else { return 0 }
        return (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
    }

    private var weekdaySymbols: [String] {
        let s = calendar.veryShortStandaloneWeekdaySymbols
        let f = calendar.firstWeekday - 1
        return Array(s[f...] + s[..<f])
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(Theme.inkSecondary)
                }
            }
            .accessibilityHidden(true)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<leading, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                ForEach(Array(days.enumerated()), id: \.element) { i, day in
                    cell(day)
                        .scaleEffect(appeared ? 1 : 0.4)
                        .opacity(appeared ? 1 : 0)
                        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.7).delay(Double(i) * 0.012),
                                   value: appeared)
                }
            }
        }
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private func cell(_ day: Date) -> some View {
        let peak = peaks[day]
        let step = peak.map { HeatScale.step($0.height, in: range) }
        let isTop = day == top, isSelected = day == selected, isToday = day == today
        Button { if peak != nil { onSelect(day) } } label: {
            ZStack {
                if let step {
                    Circle().fill(HeatScale.fill[step])
                } else {
                    Circle().strokeBorder(Theme.hairline, lineWidth: 1)
                }
                Text("\(calendar.component(.day, from: day))")
                    .font(.footnote.monospacedDigit().weight(isToday ? .bold : .medium))
                    .foregroundStyle(step.map { HeatScale.text[$0] } ?? Theme.inkSecondary.opacity(0.6))
                if isToday {
                    Circle().fill(step.map { HeatScale.text[$0] } ?? Theme.harbor)
                        .frame(width: 4, height: 4)
                        .offset(y: 11)
                }
            }
            // A 2 pt surface gap, then the ring: amber for the month's top day,
            // ink for the day being read.
            .padding(4)
            .overlay {
                if isTop || isSelected {
                    Circle().strokeBorder(isTop ? Theme.swell : Theme.ink.opacity(0.7), lineWidth: 2)
                }
            }
            .scaleEffect(isSelected ? 1.08 : 1)
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(peak == nil)
        .accessibilityLabel(accessibilityText(day, peak, isTop: isTop))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func accessibilityText(_ day: Date, _ peak: TideCalendarView.DayPeak?, isTop: Bool) -> String {
        let name = day.formatted(Date.FormatStyle(timeZone: tz).weekday(.wide).month(.wide).day())
        guard let peak else { return "\(name), no data" }
        let src = peak.source == .observed ? "observed" : (peak.source == .outlook ? "outlook" : "forecast")
        return "\(name), highest water \(Fmt.length(peak.height, unit)) \(src) at \(Fmt.time(peak.date, in: tz))\(isTop ? ", highest this month" : "")"
    }
}

/// The focused day: its highest water and every high and low.
private struct DayDetail: View {
    let peak: TideCalendarView.DayPeak
    let isTop: Bool
    let events: [ForecastEvent]
    let unit: LengthUnit
    let tz: TimeZone
    let now: Date
    let onHourly: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.dayName(peak.day, in: tz, relativeTo: now) + ", " + peak.day.formatted(Date.FormatStyle(timeZone: tz).month(.abbreviated).day()))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(sourceLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(peak.source == .observed ? Theme.harbor : Theme.swellText)
                    .background(peak.source == .observed ? Theme.neutralWash : Theme.swellWash, in: Capsule())
            }
            if events.isEmpty {
                row(kind: "High", time: peak.date, height: peak.height, emphasized: true)
            } else {
                ForEach(events) { e in
                    row(kind: e.kind == .high ? "High" : "Low", time: e.date, height: e.total,
                        emphasized: e.kind == .high && abs(e.total - peak.height) < 1e-9, range: (e.lower80, e.upper80))
                }
            }
            Button(action: onHourly) {
                HStack(spacing: 4) {
                    Text("Hourly forecast")
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                }
                .font(.subheadline.weight(.semibold))
                .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.harbor)
        }
        .padding(14)
        .background(Theme.neutralWash.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            if isTop { Capsule().fill(Theme.swell).frame(width: 3).padding(.vertical, 12) }
        }
        .accessibilityElement(children: .contain)
    }

    private var sourceLabel: String {
        switch peak.source {
        case .observed: return "Observed"
        case .forecast: return "Forecast"
        case .outlook: return "Outlook"
        }
    }

    private func row(kind: String, time: Date, height: Double, emphasized: Bool, range: (Double, Double)? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: kind == "High" ? "arrow.up.to.line" : "arrow.down.to.line")
                .font(.caption)
                .foregroundStyle(kind == "High" ? Theme.harbor : Theme.inkSecondary)
                .frame(width: 16)
            Text("\(kind) \(Fmt.time(time, in: tz))")
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
            Spacer()
            if let range {
                Text("\(Fmt.length(range.0, unit))–\(Fmt.length(range.1, unit))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            }
            Text(Fmt.length(height, unit))
                .font(.subheadline.monospacedDigit().weight(emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? Theme.swellText : Theme.ink)
        }
    }
}
