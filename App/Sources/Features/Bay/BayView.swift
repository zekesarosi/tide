import SwiftUI
import TideKit

/// The bay on the Map tab: a compact panel over the map with the animation
/// controls and the selected station's timing, and a way into the details.
@MainActor
struct BayPanel: View {
    let analysis: BayAnalysis
    let day: BayDay
    let clock: BayClock
    @Binding var selected: String
    let unit: LengthUnit
    let onDetails: () -> Void

    @Environment(StationStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("San Francisco Bay")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button(action: onDetails) {
                    HStack(spacing: 3) {
                        Text("Timing")
                        Image(systemName: "chevron.up").font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(minHeight: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.harbor)
                .accessibilityLabel("Bay timing details")
            }
            ScrubberBar(day: day, clock: clock, selected: day.row(selected), unit: unit, reduceMotion: reduceMotion)
            stationLine
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    /// "Sausalito · high water 14 min after San Francisco · Forecast ›"
    @ViewBuilder
    private var stationLine: some View {
        if let s = analysis.station(code: selected) {
            HStack(spacing: 6) {
                Group {
                    if s.station.code == analysis.referenceCode {
                        Text("\(s.station.shortName) · the reference gauge")
                    } else if let lag = s.offsets?.high?.mean {
                        Text("\(s.station.shortName) · high water ") + Text(Fmt.lag(lag)).fontWeight(.semibold).foregroundStyle(Theme.harbor)
                            + Text(" vs SF")
                    } else {
                        Text(s.station.shortName)
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                if let st = store.station(id: "\(DataSourceID.noaaCoops.rawValue):\(selected)") {
                    NavigationLink(value: st) {
                        HStack(spacing: 3) {
                            Text("Forecast")
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                        }
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 30)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.harbor)
                }
            }
        }
    }
}

/// Everything about the bay's timing, in a sheet over the map: the headline,
/// the propagation strip, the selected station against San Francisco, and
/// the all-stations table. Shares the map's clock and selection.
@MainActor
struct BayDetailsSheet: View {
    let analysis: BayAnalysis
    let day: BayDay
    let clock: BayClock
    @Binding var selected: String
    let unit: LengthUnit

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let a = analysis
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let sentence = headline(a) {
                            Text(sentence)
                                .font(.title3)
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 6)
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("High water through the bay")
                            PropagationStrip(day: day, clock: clock, selected: $selected) { t in
                                clock.playing = false
                                clock.time = day.clamp(t)
                            }
                            HStack(spacing: 6) {
                                Text("Low")
                                LinearGradient(colors: HeatScale.fill, startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 56, height: 8)
                                    .clipShape(Capsule())
                                Text("High")
                                Circle().fill(Theme.swellDot).frame(width: 6, height: 6).padding(.leading, 10)
                                Text("Time of high water")
                            }
                            .font(.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .accessibilityHidden(true)
                            Text("Each row is shaded from that station's low water to its high water; the amber dots step later down each arm of the bay. Drag across the strip to move the map's time.")
                                .font(.caption)
                                .foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, Theme.sectionGap)

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                SectionLabel("Timing vs San Francisco")
                                Spacer()
                                stationMenu(a)
                            }
                            BayComparisonView(analysis: a, code: selected, unit: unit, now: a.generated)
                        }
                        .id("comparison")
                        .padding(.top, Theme.sectionGap)

                        VStack(alignment: .leading, spacing: 12) {
                            SectionLabel("All stations")
                            BayOffsetsTable(analysis: a, selected: selected) { code in
                                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.3)) {
                                    selected = code
                                    proxy.scrollTo("comparison", anchor: .top)
                                }
                            }
                            HStack(spacing: 6) {
                                Circle().fill(Theme.harbor).frame(width: 5, height: 5)
                                Text("Live gauge").font(.caption).foregroundStyle(Theme.inkSecondary)
                            }
                            .accessibilityHidden(true)
                        }
                        .padding(.top, Theme.sectionGap)

                        methodNote(a)
                            .padding(.top, 20)
                    }
                    .padding(.horizontal, Theme.margin)
                    .padding(.bottom, 32)
                }
            }
            .background(Theme.surface)
            .navigationTitle("Bay timing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func stationMenu(_ a: BayAnalysis) -> some View {
        Menu {
            Picker("Station", selection: $selected) {
                ForEach(a.stations.filter { $0.station.code != a.referenceCode }) { s in
                    Text(s.station.name).tag(s.station.code)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(SFBay.station(code: selected)?.shortName ?? "Station")
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.harbor)
            .frame(minHeight: 32)
        }
        .accessibilityLabel("Compare station")
        .accessibilityValue(SFBay.station(code: selected)?.name ?? "")
    }

    /// The answer first: how long the tide takes to reach each arm.
    private func headline(_ a: BayAnalysis) -> AttributedString? {
        let south = a.station(code: "9414575") ?? a.stations.last { $0.station.region == .south }
        let north = a.stations.last { $0.station.region == .north }
        guard let sh = south?.offsets?.high?.mean, let nh = north?.offsets?.high?.mean,
              let s = south?.station, let n = north?.station else { return nil }
        var out = AttributedString("High water reaches \(s.shortName) ")
        var lagS = AttributedString(Fmt.lag(sh).replacingOccurrences(of: "+", with: ""))
        lagS.foregroundColor = Theme.harbor
        out += lagS
        out += AttributedString(" after the Golden Gate, and \(n.shortName) ")
        var lagN = AttributedString(Fmt.lag(nh).replacingOccurrences(of: "+", with: ""))
        lagN.foregroundColor = Theme.harbor
        out += lagN
        out += AttributedString(".")
        return out
    }

    private func methodNote(_ a: BayAnalysis) -> some View {
        let days = Int((a.window.duration / 86_400).rounded())
        let obs = Int((a.observationWindow.duration / 86_400).rounded())
        return VStack(alignment: .leading, spacing: 6) {
            Text("High and low lags pair every San Francisco high and low with the one it becomes at each station over \(days) days of on-device tide predictions (two spring–neap cycles). ± is one standard deviation: lags run longer at neaps and on the smaller of each day's two tides. Observed: the lag that best lines up the last \(obs) days of measured water levels, with the tide table's lag over the same days beneath it.")
            Text("Reference: San Francisco 9414290, NOAA's radar gauge at the Golden Gate. Heights above MLLW. Tide table only; storm surge and river flow are not included.")
            if !a.problems.isEmpty {
                Text("Not loaded: \(a.problems.map(\.component).joined(separator: ", ")).")
                    .foregroundStyle(Theme.warning)
            }
            Text("NOAA · Guidance only. Not for navigation.")
        }
        .font(.caption)
        .foregroundStyle(Theme.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Play/pause, the moment being shown, and a slider across the tidal day.
/// Its own view: it reads the clock, the screen doesn't.
struct ScrubberBar: View {
    let day: BayDay
    let clock: BayClock
    let selected: BayDay.Row?
    let unit: LengthUnit
    let reduceMotion: Bool

    private var tz: TimeZone { SFBay.timeZone }

    var body: some View {
        let t = clock.time
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button {
                    clock.playing.toggle()
                } label: {
                    Image(systemName: clock.playing ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.surface)
                        .frame(width: 46, height: 46)
                        .background(Theme.harbor, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clock.playing ? "Pause" : "Play the tidal day")

                VStack(alignment: .leading, spacing: 1) {
                    Text(Fmt.time(t, in: tz))
                        .font(.system(size: 28, weight: .light, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                    Text(relative(t))
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                if let selected {
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: selected.rising(at: t, start: day.start) ? "arrow.up.right" : "arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.harbor)
                            Text(Fmt.length(selected.value(at: t, start: day.start), unit))
                                .font(.rowValue)
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink)
                        }
                        Text(selected.station.shortName)
                            .font(.caption)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(selected.station.name)
                    .accessibilityValue(BayText.state(row: selected, at: t, start: day.start, unit: unit))
                }
            }
            Slider(value: Binding(get: { clock.time.timeIntervalSince(day.start) },
                                  set: { clock.playing = false; clock.time = day.start + $0 }),
                   in: 0...day.end.timeIntervalSince(day.start))
                .tint(Theme.harbor)
                .accessibilityLabel("Time")
                .accessibilityValue("\(Fmt.dayTime(t, in: tz)), \(relative(t))")
        }
    }

    private func relative(_ t: Date) -> String {
        let d = t.timeIntervalSince(Date())
        if abs(d) < 5 * 60 { return "Now · \(Fmt.dayName(t, in: tz))" }
        let m = Int((abs(d) / 60 / 5).rounded()) * 5
        let span = m >= 60 ? "\(m / 60) h \(m % 60 == 0 ? "" : "\(m % 60) min")" : "\(m) min"
        return "\(Fmt.dayName(t, in: tz)) · \(span.trimmingCharacters(in: .whitespaces)) \(d > 0 ? "from now" : "ago")"
    }
}

/// What the map markers mean.
struct MarkerLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                WaterDisc(fraction: 0, rising: true, atHigh: false, size: 12)
                Text("Low")
                WaterDisc(fraction: 1, rising: false, atHigh: false, size: 12)
                Text("High")
            }
            HStack(spacing: 5) {
                WaterDisc(fraction: 1, rising: true, atHigh: true, size: 12)
                Text("High water now")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(Theme.inkSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Markers fill from empty at low water to full at high water, with an arrow for rising or falling; an amber ring marks high water now.")
    }
}
