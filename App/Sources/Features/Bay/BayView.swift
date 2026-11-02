import SwiftUI
import TideKit

/// San Francisco Bay: watch the tide travel from the Golden Gate into the
/// South Bay and up through Carquinez Strait, and read each station's timing
/// against the San Francisco gauge.
@MainActor
struct BayView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(StationStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The station highlighted on the map and strip.
    @State private var selected: String
    @State private var clock = BayClock(time: Date())

    init(initialCode: String? = nil) {
        let code = initialCode.flatMap { SFBay.station(code: $0)?.code }
        _selected = State(initialValue: code == nil || code == SFBay.referenceCode ? SFBay.defaultComparisonCode : code!)
    }

    private var model: BayModel { env.bay }
    private var unit: LengthUnit { settings.unit }
    private var tz: TimeZone { SFBay.timeZone }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    if let a = model.analysis, let day = model.day {
                        content(a, day, proxy: proxy)
                    } else if case .failed(let message) = model.phase {
                        ContentUnavailableView {
                            Label("Bay tides unavailable", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("Try again") { Task { await model.load(service: env.service) } }
                                .buttonStyle(.bordered)
                        }
                        .padding(.top, 40)
                    } else {
                        loading
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .background(Theme.surface)
        .navigationTitle("San Francisco Bay")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("San Francisco Bay").font(.subheadline.weight(.semibold)).opacity(0).accessibilityHidden(true)
            }
            if model.phase == .loading && model.analysis != nil {
                ToolbarItem(placement: .topBarTrailing) { ProgressView().controlSize(.small) }
            }
        }
        .refreshable { await model.load(service: env.service) }
        .task {
            await model.loadIfNeeded(service: env.service)
            if let day = model.day { clock.time = day.clamp(Date()) }
        }
        .task(id: clock.playing) { await play() }
        .onDisappear { clock.playing = false }
    }

    // MARK: Playback

    /// One hour of tide per second, so a tidal day plays in about 25 s.
    /// With Reduce Motion it steps a quarter hour at a time instead.
    private func play() async {
        guard clock.playing, let day = model.day else { return }
        if clock.time >= day.end - 60 { clock.time = day.start }
        var last = Date()
        while clock.playing, !Task.isCancelled {
            if reduceMotion {
                try? await Task.sleep(for: .milliseconds(700))
                clock.time += 15 * 60
            } else {
                try? await Task.sleep(for: .milliseconds(33))
                let now = Date()
                clock.time += now.timeIntervalSince(last) * 3_600
                last = now
            }
            if clock.time >= day.end { clock.time = day.start }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SAN FRANCISCO BAY")
                .font(.caption.weight(.semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.inkSecondary)
            Text("\(SFBay.stations.count) NOAA stations · tide table · Pacific time")
                .font(.footnote)
                .foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private var loading: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 6).fill(Theme.neutralWash).frame(height: 44)
            RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.neutralWash).frame(height: 400)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading the tide at \(SFBay.stations.count) stations around the bay…")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
            }
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading bay tides")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ a: BayAnalysis, _ day: BayDay, proxy: ScrollViewProxy) -> some View {
        if let sentence = headline(a) {
            Text(sentence)
                .font(.title3)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.margin)
                .padding(.top, 14)
        }

        VStack(spacing: 12) {
            BayMapView(day: day, clock: clock, unit: unit, selected: $selected)
                .frame(height: 420)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).strokeBorder(Theme.hairline))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Map of the bay's tide stations")
            ScrubberBar(day: day, clock: clock, selected: day.row(selected), unit: unit, reduceMotion: reduceMotion)
            MarkerLegend()
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 16)

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
            Text("Each row is shaded from that station's low water to its high water; the amber dots step later down each arm of the bay. Drag across the strip to scrub.")
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, Theme.sectionGap)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Timing vs San Francisco")
                Spacer()
                stationMenu(a)
            }
            BayComparisonView(analysis: a, code: selected, unit: unit, now: a.generated)
            if let s = store.station(id: "\(DataSourceID.noaaCoops.rawValue):\(selected)") {
                NavigationLink {
                    StationDetailView(station: s).id(s.id)
                } label: {
                    Text("\(s.name) forecast").frame(minHeight: 44)
                }
            }
        }
        .id("comparison")
        .padding(.horizontal, Theme.margin)
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
        .padding(.horizontal, Theme.margin)
        .padding(.top, Theme.sectionGap)

        methodNote(a)
            .padding(.horizontal, Theme.margin)
            .padding(.top, 20)
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
private struct ScrubberBar: View {
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
private struct MarkerLegend: View {
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
