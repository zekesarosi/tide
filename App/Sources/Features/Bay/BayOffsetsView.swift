import Charts
import SwiftUI
import TideKit

/// One station against San Francisco: its average lags, the next highs and
/// lows at both, and both tide curves on one axis.
struct BayComparisonView: View {
    let analysis: BayAnalysis
    let code: String
    let unit: LengthUnit
    let now: Date

    private var tz: TimeZone { SFBay.timeZone }

    var body: some View {
        if let ref = analysis.reference, let st = analysis.station(code: code) {
            VStack(alignment: .leading, spacing: 16) {
                summary(st)
                NextPairsTable(ref: ref, station: st, unit: unit, now: now)
                OverlayChart(ref: ref, station: st, unit: unit, now: now)
                observedNote(st)
            }
        }
    }

    private func summary(_ st: BayStationAnalysis) -> some View {
        HStack(alignment: .top, spacing: 0) {
            stat("High water", st.offsets?.high)
            Rectangle().fill(Theme.hairline).frame(width: 1).padding(.horizontal, 12)
            stat("Low water", st.offsets?.low)
            Rectangle().fill(Theme.hairline).frame(width: 1).padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 3) {
                Text("Range").font(.caption).foregroundStyle(Theme.inkSecondary)
                Text(st.offsets?.rangeRatio.map { String(format: "%.2f×", $0) } ?? "–")
                    .font(.rowValue).monospacedDigit().foregroundStyle(Theme.ink)
                Text(st.offsets?.meanRange.map { "mean \(Fmt.length($0, unit))" } ?? " ")
                    .font(.caption2).foregroundStyle(Theme.inkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func stat(_ title: String, _ s: LagStatistics?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(Theme.inkSecondary)
            Text(s.map { Fmt.lag($0.mean) } ?? "–")
                .font(.rowValue).monospacedDigit().foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(s.map { "±\(Int(($0.standardDeviation / 60).rounded())) min · \(Fmt.lagClock($0.minimum))…\(Fmt.lagClock($0.maximum))" } ?? " ")
                .font(.caption2.monospacedDigit()).foregroundStyle(Theme.inkSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(s.map { "on average \(Fmt.lagSpoken($0.mean)) than San Francisco, give or take \(Int(($0.standardDeviation / 60).rounded())) minutes" } ?? "not available")
    }

    @ViewBuilder
    private func observedNote(_ st: BayStationAnalysis) -> some View {
        let days = Int((analysis.observationWindow.duration / 86_400).rounded())
        Group {
            if st.station.code == analysis.referenceCode {
                Text("San Francisco is the reference gauge.")
            } else if let o = st.observedCurveLag, let p = st.predictedCurveLag {
                (Text("Measured over the last \(days) days, the whole curve runs ")
                    + Text(Fmt.lag(o.lag)).fontWeight(.semibold).foregroundStyle(Theme.harbor)
                    + Text(" behind San Francisco; the tide table says \(Fmt.lag(p.lag))."))
            } else if !st.station.hasObservations {
                Text("No live gauge at \(st.station.shortName): timing from NOAA's harmonic constants for the site.")
            } else {
                Text("Recent observations are unavailable, so only the tide table is compared.")
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The next highs and lows at the station, each beside the San Francisco
/// event it follows.
private struct NextPairsTable: View {
    let ref: BayStationAnalysis
    let station: BayStationAnalysis
    let unit: LengthUnit
    let now: Date

    private var tz: TimeZone { SFBay.timeZone }

    private var pairs: [ExtremaPair] {
        let refEx = ref.extremes.filter { $0.date > now - 6 * 3_600 && $0.date < now + 3 * 86_400 }
        let st = station.extremes.filter { $0.date > now - 12 * 3_600 && $0.date < now + 4 * 86_400 }
        return (OffsetAnalysis.pairs(reference: refEx, station: st, kind: .high)
            + OffsetAnalysis.pairs(reference: refEx, station: st, kind: .low))
            .filter { $0.station.date > now }
            .sorted { $0.station.date < $1.station.date }
            .prefix(4)
            .map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("").frame(width: 44, alignment: .leading)
                Text("San Francisco").frame(maxWidth: .infinity, alignment: .leading)
                Text(station.station.shortName).frame(maxWidth: .infinity, alignment: .leading)
                Text("Lag").frame(width: 84, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(Theme.inkSecondary)
            .padding(.bottom, 6)
            .accessibilityHidden(true)
            Hairline()
            ForEach(pairs, id: \.station.date) { p in
                HStack(alignment: .firstTextBaseline) {
                    Text(Phrase.eventName(p.station.kind))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(p.station.kind == .high ? Theme.harbor : Theme.inkSecondary)
                        .frame(width: 44, alignment: .leading)
                    cell(p.reference)
                    cell(p.station)
                    Text(Fmt.lag(p.lag))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(width: 84, alignment: .trailing)
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(Phrase.eventName(p.station.kind)) at \(station.station.shortName) \(Fmt.smartTime(p.station.date, in: tz, relativeTo: now)), \(Fmt.length(p.station.height, unit)); San Francisco \(Fmt.smartTime(p.reference.date, in: tz, relativeTo: now)); \(Fmt.lagSpoken(p.lag))")
                Hairline()
            }
        }
    }

    private func cell(_ e: TideExtreme) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Fmt.smartTime(e.date, in: tz, relativeTo: now))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.ink)
            Text(Fmt.length(e.height, unit))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Both tide curves over the next day on one height axis, with the lag to
/// the next high drawn as a bracket.
private struct OverlayChart: View {
    let ref: BayStationAnalysis
    let station: BayStationAnalysis
    let unit: LengthUnit
    let now: Date

    private var tz: TimeZone { SFBay.timeZone }

    struct Point: Identifiable {
        var id: String { "\(series)\(date.timeIntervalSince1970)" }
        let series: String
        let date: Date
        let value: Double
    }

    private var range: ClosedRange<Date> { (now - 2 * 3_600)...(now + 26 * 3_600) }

    private var points: [Point] {
        let r = range
        func curve(_ a: BayStationAnalysis, _ name: String) -> [Point] {
            a.predictor.heights(from: r.lowerBound, to: r.upperBound, interval: 600).points
                .map { Point(series: name, date: $0.date, value: unit.fromMeters($0.value)) }
        }
        let same = ref.station.code == station.station.code
        return curve(ref, "San Francisco") + (same ? [] : curve(station, station.station.shortName))
    }

    /// The next high at the station and the San Francisco high it follows.
    private var nextHigh: ExtremaPair? {
        let refEx = ref.extremes.filter { range.contains($0.date) || $0.date > now - 6 * 3_600 && $0.date < now }
        return OffsetAnalysis.pairs(reference: refEx, station: station.extremes, kind: .high)
            .first { $0.station.date > now && range.contains($0.station.date) }
    }

    var body: some View {
        let pts = points
        let names = ["San Francisco", station.station.shortName]
        let lo = pts.map(\.value).min() ?? 0, hi = pts.map(\.value).max() ?? 1
        let pad = (hi - lo) * 0.18
        let bracket = nextHigh
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(pts) { p in
                    LineMark(x: .value("Time", p.date), y: .value("Height", p.value), series: .value("Station", p.series))
                        .foregroundStyle(by: .value("Station", p.series))
                        .lineStyle(p.series == "San Francisco"
                                   ? StrokeStyle(lineWidth: 1.6, dash: [4, 3])
                                   : StrokeStyle(lineWidth: 2.4, lineCap: .round))
                        .interpolationMethod(.monotone)
                }
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(Theme.ink.opacity(0.18))
                if let b = bracket, ref.station.code != station.station.code {
                    let y = unit.fromMeters(max(b.reference.height, b.station.height)) + pad * 0.55
                    RuleMark(xStart: .value("From", b.reference.date), xEnd: .value("To", b.station.date), y: .value("Bracket", y))
                        .foregroundStyle(Theme.swell)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .annotation(position: .top, spacing: 2) {
                            Text(Fmt.lag(b.lag))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Theme.swellText)
                                .fixedSize()
                        }
                    PointMark(x: .value("Time", b.reference.date), y: .value("Height", unit.fromMeters(b.reference.height)))
                        .symbolSize(22).foregroundStyle(Theme.tideTable)
                    PointMark(x: .value("Time", b.station.date), y: .value("Height", unit.fromMeters(b.station.height)))
                        .symbolSize(28).foregroundStyle(Theme.harbor)
                }
            }
            .chartForegroundStyleScale(domain: names, range: [Theme.tideTable, Theme.harbor])
            .chartLegend(.hidden)
            .chartXScale(domain: range)
            .chartYScale(domain: (lo - pad * 0.3)...(hi + pad))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let d = v.as(Double.self) {
                            Text(String(format: unit == .feet ? "%.0f" : "%.1f", d)).font(.caption2).foregroundStyle(Theme.inkSecondary)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: ticks) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel {
                        if let d = v.as(Date.self) { Text(tick(d)).font(.caption2).foregroundStyle(Theme.inkSecondary) }
                    }
                }
            }
            .frame(height: 190)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Tide at \(station.station.shortName) and San Francisco over the next day")
            .accessibilityValue(bracket.map { "Next high at \(station.station.shortName) \(Fmt.time($0.station.date, in: tz)), \(Fmt.lagSpoken($0.lag)) than San Francisco" } ?? "")

            HStack(spacing: 14) {
                swatch(Theme.harbor, station.station.shortName, dashed: false)
                swatch(Theme.tideTable, "San Francisco", dashed: true)
                Spacer()
                Text("\(unit.symbol) above MLLW").font(.caption2).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private var ticks: [Date] {
        var cal = Calendar.current
        cal.timeZone = tz
        var out: [Date] = []
        var day = cal.startOfDay(for: range.lowerBound)
        while day <= range.upperBound {
            for h in [0, 6, 12, 18] {
                if let t = cal.date(bySettingHour: h, minute: 0, second: 0, of: day), range.contains(t) { out.append(t) }
            }
            day = cal.date(byAdding: .day, value: 1, to: day) ?? range.upperBound + 1
        }
        return out
    }

    private func tick(_ d: Date) -> String {
        var cal = Calendar.current
        cal.timeZone = tz
        if cal.component(.hour, from: d) == 0 { return d.formatted(Date.FormatStyle(timeZone: tz).weekday(.abbreviated)) }
        return d.formatted(Date.FormatStyle(timeZone: tz).hour())
    }

    private func swatch(_ c: Color, _ label: String, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 14, y: 1)) }
                .stroke(c, style: StrokeStyle(lineWidth: dashed ? 1.5 : 2.4, lineCap: .round, dash: dashed ? [3, 2] : []))
                .frame(width: 14, height: 2)
            Text(label)
        }
        .font(.caption)
        .foregroundStyle(Theme.inkSecondary)
    }
}

/// Every bay station against San Francisco, in the order the tide reaches
/// them. Tap a row to compare it above.
struct BayOffsetsTable: View {
    let analysis: BayAnalysis
    let selected: String
    let onSelect: (String) -> Void

    static let lagWidth: CGFloat = 58
    static let rangeWidth: CGFloat = 40
    static let obsWidth: CGFloat = 58

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 6) {
                Text("Station").frame(maxWidth: .infinity, alignment: .leading)
                Text("High").frame(width: Self.lagWidth, alignment: .trailing)
                Text("Low").frame(width: Self.lagWidth, alignment: .trailing)
                Text("Range").frame(width: Self.rangeWidth, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Observed")
                    Text("vs table").font(.caption2)
                }
                .frame(width: Self.obsWidth, alignment: .trailing)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.inkSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.bottom, 6)
            .accessibilityHidden(true)

            ForEach(BayRegion.allCases, id: \.self) { region in
                let rows = analysis.stations.filter { $0.station.region == region }
                if !rows.isEmpty {
                    Hairline()
                    Text(region.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.inkSecondary)
                        .padding(.top, 10)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(rows) { a in row(a) }
                }
            }
            Hairline()
        }
    }

    private func row(_ a: BayStationAnalysis) -> some View {
        let isRef = a.station.code == analysis.referenceCode
        let isSel = a.station.code == selected
        return Button { onSelect(a.station.code) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                HStack(spacing: 5) {
                    Text(a.station.shortName)
                        .font(.subheadline.weight(isSel ? .semibold : .regular))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    if a.station.hasObservations {
                        Circle().fill(Theme.harbor).frame(width: 5, height: 5)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isRef {
                    Text("reference").font(.caption).foregroundStyle(Theme.inkSecondary)
                        .frame(width: Self.lagWidth * 2 + 6, alignment: .trailing)
                } else {
                    lagCell(a.offsets?.high)
                    lagCell(a.offsets?.low)
                }
                Text(a.offsets?.rangeRatio.map { String(format: "%.2f", $0) } ?? "–")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .frame(width: Self.rangeWidth, alignment: .trailing)
                observedCell(a, isRef: isRef)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 6)
            .background(isSel ? Theme.neutralWash : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, -6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a.station.name)
        .accessibilityValue(spoken(a, isRef: isRef))
        .accessibilityAddTraits(isSel ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Compares this station with San Francisco above")
    }

    private func lagCell(_ s: LagStatistics?) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(s.map { Fmt.lagClock($0.mean) } ?? "–")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.ink)
            Text(s.map { "±\(Int(($0.standardDeviation / 60).rounded()))" } ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.inkSecondary)
        }
        .frame(width: Self.lagWidth, alignment: .trailing)
    }

    @ViewBuilder
    private func observedCell(_ a: BayStationAnalysis, isRef: Bool) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            if !isRef, let o = a.observedCurveLag {
                Text(Fmt.lagClock(o.lag))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.harbor)
                Text(a.predictedCurveLag.map { Fmt.lagClock($0.lag) } ?? "")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            } else {
                Text("–").font(.subheadline).foregroundStyle(Theme.inkSecondary.opacity(0.6))
                Text(isRef || a.predictedCurveLag == nil ? "" : Fmt.lagClock(a.predictedCurveLag!.lag))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
        .frame(width: Self.obsWidth, alignment: .trailing)
    }

    private func spoken(_ a: BayStationAnalysis, isRef: Bool) -> String {
        if isRef { return "Reference gauge" }
        var parts: [String] = []
        if let h = a.offsets?.high { parts.append("high water \(Fmt.lagSpoken(h.mean)), give or take \(Int((h.standardDeviation / 60).rounded())) minutes") }
        if let l = a.offsets?.low { parts.append("low water \(Fmt.lagSpoken(l.mean))") }
        if let r = a.offsets?.rangeRatio { parts.append(String(format: "range %.2f times San Francisco's", r)) }
        if let o = a.observedCurveLag { parts.append("observed curve \(Fmt.lagSpoken(o.lag))") }
        if let p = a.predictedCurveLag { parts.append("tide table curve \(Fmt.lagSpoken(p.lag))") }
        return parts.joined(separator: "; ")
    }
}
