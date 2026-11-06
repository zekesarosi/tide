import CoreLocation
import MetalKit
import SwiftUI
import TideKit

/// The Tide Globe: the whole ocean's astronomical tide, live. Crests wheel
/// around amphidromic points under the real Sun and Moon; tap the sea to read
/// the tide there.
struct GlobeView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(StationStore.self) private var store
    @Environment(LocationProvider.self) private var location
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = GlobeModel()
    @State private var showingInfo = false

    var body: some View {
        ZStack {
            Color(red: 0.01, green: 0.022, blue: 0.032).ignoresSafeArea()
            switch model.phase {
            case .ready:
                if let atlas = model.atlas, let land = model.land {
                    GlobeMetalView(model: model, atlas: atlas, land: land, stations: store.stations) { lat, lon in
                        withAnimation(reduceMotion ? nil : .snappy) {
                            model.makeProbe(latitude: lat, longitude: lon, stations: store.stations)
                        }
                    }
                    .ignoresSafeArea()
                    .accessibilityLabel("Globe of ocean tides")
                    .accessibilityHint("Drag to turn the Earth. Tap the ocean to read the tide there.")
                }
            case .loading:
                ProgressView().tint(.white)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                header
                Spacer(minLength: 0)
                controls
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .sheet(isPresented: $showingInfo) { GlobeInfoSheet().presentationDetents([.medium, .large]) }
        .task {
            if let here = location.location {
                model.initialFocus = (here.coordinate.latitude, here.coordinate.longitude - 25)
            }
            await model.load()
            if !reduceMotion { model.playing = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Close")
            GlobeTimeHeader(model: model)
            Spacer(minLength: 0)
            Menu {
                Toggle("Ocean relief", systemImage: "mountain.2", isOn: $model.relief)
                Toggle("Tide stations", systemImage: "mappin.circle", isOn: $model.showsStations)
                Button("Go to the Moon's point", systemImage: "moon") { flyToMoon() }
                Button("About the globe", systemImage: "info.circle") { showingInfo = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Globe options")
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 8)
    }

    private func flyToMoon() {
        let p = Ephemeris.moon(model.time).subpoint(at: model.time)
        model.flyRequest = .init(latitude: p.latitude, longitude: p.longitude)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            if let p = model.probe {
                LiveProbeCard(model: model, probe: p, unit: settings.unit) {
                    withAnimation(reduceMotion ? nil : .snappy) { model.probe = nil }
                } openStation: { s in
                    env.router.openStationID = s.id
                    dismiss()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            VStack(spacing: 12) {
                legend
                choiceStrip
                transport
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var legend: some View {
        let s = Double(GlobeRenderer.colourScale)
        return VStack(spacing: 6) {
            LinearGradient(colors: [Color(red: 0.42, green: 0.70, blue: 0.95), Color(red: 0.20, green: 0.47, blue: 0.76),
                                    Color(red: 0.03, green: 0.105, blue: 0.15),
                                    Color(red: 0.92, green: 0.56, blue: 0.30), Color(red: 1, green: 0.88, blue: 0.72)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 6)
                .clipShape(Capsule())
            HStack {
                Text("Low " + Fmt.length(-s, settings.unit, signed: true))
                Spacer()
                Label("high water now", systemImage: "minus")
                    .labelStyle(LegendLineStyle())
                Spacer()
                Text("High " + Fmt.length(s, settings.unit, signed: true))
            }
            .font(.caption2).monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour shows the tide: blue below mean sea level, amber above, up to \(Fmt.length(s, settings.unit)). A bright line marks high water now.")
    }

    private var choiceStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GlobeModel.choices) { c in
                    let on = model.selection == c.name
                    Button {
                        withAnimation(.snappy) { model.selection = c.name }
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.title).font(.subheadline.weight(.semibold))
                            Text(c.gloss).font(.caption2).foregroundStyle(on ? Color.black.opacity(0.7) : .secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(on ? Color.black : Color.primary)
                        .background(on ? Theme.swell : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button {
                model.playing.toggle()
            } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(model.playing ? "Pause" : "Play")
            GlobeScrubber(model: model)
            Menu {
                Picker("Speed", selection: $model.rate) {
                    Text("1 hour per second").tag(3_600.0)
                    Text("3 hours per second").tag(10_800.0)
                    Text("12 hours per second").tag(43_200.0)
                    Text("1 day per second").tag(86_400.0)
                }
                Button("Now", systemImage: "clock.arrow.circlepath") { model.jumpToNow() }
            } label: {
                Text(speedLabel)
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .accessibilityLabel("Speed, \(speedLabel)")
        }
    }

    private var speedLabel: String {
        model.rate >= 86_400 ? "1 d/s" : "\(Int(model.rate / 3_600)) h/s"
    }
}

// MARK: - Views that follow the clock
//
// The renderer moves the clock every frame and publishes `model.time` about
// 15 times a second. Only these small views read it, so the rest of the
// screen (and its menus) stays put. A menu inside a view that redraws
// continuously is rebuilt under the finger and won't open.

extension GlobeModel {
    var timeTitle: String {
        time.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }
}

private struct GlobeTimeHeader: View {
    let model: GlobeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("TIDE GLOBE")
                .font(.caption.weight(.semibold)).tracking(1.2)
                .foregroundStyle(.secondary)
            Text(model.timeTitle)
                .font(.title3.weight(.light)).monospacedDigit()
            Text(moonLine)
                .font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var moonLine: String {
        let e = Ephemeris.lunarElongation(model.time)
        let names = ["New Moon", "Waxing crescent", "First quarter", "Waxing gibbous", "Full Moon", "Waning gibbous", "Last quarter", "Waning crescent"]
        let name = names[Int(((e + 22.5).truncatingRemainder(dividingBy: 360)) / 45)]
        // Spring tides follow new and full Moon; the Moon gains 12.19° a day on the Sun.
        let toSpring = (180 - e.truncatingRemainder(dividingBy: 180)).truncatingRemainder(dividingBy: 180) / 12.19
        let springs: String
        if toSpring < 1 || toSpring > 13.8 { springs = "spring tides" }
        else if abs(toSpring - 7.4) < 1.2 { springs = "neap tides" }
        else { springs = "springs in \(Int(toSpring.rounded())) d" }
        return "\(name) · \(springs)"
    }
}

private struct GlobeScrubber: View {
    @Bindable var model: GlobeModel

    var body: some View {
        Slider(value: $model.offset, in: -GlobeModel.window / 3_600...GlobeModel.window / 3_600) { editing in
            if editing { model.playing = false }
        }
        .tint(Theme.swell)
        .accessibilityLabel("Time")
        .accessibilityValue(model.timeTitle)
    }
}

private struct LiveProbeCard: View {
    let model: GlobeModel
    let probe: GlobeProbe
    let unit: LengthUnit
    let close: () -> Void
    let openStation: (Station) -> Void

    var body: some View {
        ProbeCard(probe: probe, time: model.time, unit: unit, close: close, openStation: openStation)
    }
}

private struct LegendLineStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(Color(red: 1, green: 0.95, blue: 0.88)).frame(width: 14, height: 2)
            configuration.title
        }
    }
}

// MARK: - Probe

private struct ProbeCard: View {
    let probe: GlobeProbe
    let time: Date
    let unit: LengthUnit
    let close: () -> Void
    let openStation: (Station) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(coordinate).font(.subheadline.weight(.semibold)).monospacedDigit()
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close reading")
            }
            if let p = probe.predictor {
                let h = p.height(at: time)
                let rising = p.height(at: time + 300) > h
                HStack(alignment: .lastTextBaseline, spacing: 10) {
                    Text(Fmt.length(h, unit, signed: true))
                        .font(Font.cardValue).monospacedDigit()
                        .contentTransition(.numericText())
                    Label(rising ? "Rising" : "Falling", systemImage: rising ? "arrow.up.right" : "arrow.down.right")
                        .font(.subheadline).foregroundStyle(rising ? Theme.swell : Theme.harbor)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        ForEach(probe.nextEvents(after: time), id: \.date) { e in
                            Text("\(e.kind == .high ? "High" : "Low") \(e.date.formatted(date: .omitted, time: .shortened))")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
                ProbeCurve(predictor: p, time: time)
                    .frame(height: 54)
                Text(character)
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("That's land. Tap the ocean to read the tide.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let n = probe.nearest, n.meters < 400_000 {
                Button { openStation(n.station) } label: {
                    HStack {
                        Image(systemName: "water.waves")
                        Text("\(n.station.name) · \(Fmt.distance(n.meters))").lineLimit(1)
                        Spacer()
                        Text("Forecast").fontWeight(.semibold)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.harbor)
                }
                .accessibilityLabel("Open the forecast for \(n.station.name)")
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var coordinate: String {
        let lat = String(format: "%.1f° %@", abs(probe.latitude), probe.latitude >= 0 ? "N" : "S")
        let lon = String(format: "%.1f° %@", abs(probe.longitude), probe.longitude >= 0 ? "E" : "W")
        return "\(lat)  \(lon)"
    }

    private var character: String {
        guard let d = probe.dominant else { return "" }
        let kind = d.name.hasSuffix("1") ? "once a day" : "twice a day"
        return "Mostly \(kind) (\(d.name)) · range up to \(Fmt.length(probe.range, unit)). Open-ocean model; harbours can differ."
    }
}

/// ±12 hours of the model tide at the probe, with "now" in the middle.
private struct ProbeCurve: View {
    let predictor: HarmonicPredictor
    let time: Date

    var body: some View {
        Canvas { ctx, size in
            let n = 96
            let values = (0...n).map { predictor.height(at: time + (Double($0) / Double(n) - 0.5) * 24 * 3_600) }
            let m = max(values.map(abs).max() ?? 1, 0.05)
            func y(_ v: Double) -> CGFloat { size.height / 2 - CGFloat(v / m) * (size.height / 2 - 3) }
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: size.height / 2)); zero.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(zero, with: .color(.white.opacity(0.15)), lineWidth: 1)
            var line = Path()
            for (i, v) in values.enumerated() {
                let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(n), y: y(v))
                i == 0 ? line.move(to: p) : line.addLine(to: p)
            }
            var fill = line
            fill.addLine(to: CGPoint(x: size.width, y: size.height)); fill.addLine(to: CGPoint(x: 0, y: size.height)); fill.closeSubpath()
            ctx.fill(fill, with: .color(Theme.harbor.opacity(0.18)))
            ctx.stroke(line, with: .color(Theme.harbor), lineWidth: 1.5)
            let now = CGPoint(x: size.width / 2, y: y(values[n / 2]))
            ctx.fill(Path(ellipseIn: CGRect(x: now.x - 4, y: now.y - 4, width: 8, height: 8)), with: .color(Theme.swell))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Info

private struct GlobeInfoSheet: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("The Moon and Sun pull the ocean into two bulges, but continents get in the way. So the tide becomes a set of huge waves, one per ocean basin, each wheeling around a point where the water barely moves. Those points are amphidromes.")
                    Text("Colour is the astronomical tide right now: amber above mean sea level, blue below. The bright line is high water, sweeping counter-clockwise around amphidromes in the north and clockwise in the south. The amber ring marks the point directly under the Moon. High water is rarely there.")
                    Text("Pick M2 to see the Moon's twice-daily tide alone. White lines join places that reach high water at the same time, an hour apart. Where they meet is an amphidrome.")
                    SectionLabel("Sources")
                    Text("Ocean tide: NASA Goddard GOT4.10c (R. Ray, 2013), 8 constituents on a 0.5° grid. Coastline: Natural Earth. Sun and Moon: Meeus.")
                        .foregroundStyle(.secondary)
                    Text("This is an open-ocean model. Tides in harbours and estuaries can be much larger and later; station forecasts use the local gauge. Not for navigation.")
                        .foregroundStyle(.secondary)
                }
                .font(.body)
                .padding(Theme.margin)
            }
            .navigationTitle("Tide Globe")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Metal view

struct GlobeMetalView: UIViewRepresentable {
    let model: GlobeModel
    let atlas: TideAtlas
    let land: LandMask
    let stations: [Station]
    let onPick: (Double, Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isOpaque = true
        view.backgroundColor = .black
        let scale = UserDefaults.standard.double(forKey: "GlobeScale")
        if scale > 0 { view.contentScaleFactor = scale }
        guard let renderer = GlobeRenderer(view: view, model: model, atlas: atlas, land: land) else { return view }
        context.coordinator.renderer = renderer
        context.coordinator.view = view
        view.delegate = renderer

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinch(_:)))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: doubleTap)
        [pan, pinch, doubleTap, tap].forEach(view.addGestureRecognizer)
        pinch.delegate = context.coordinator
        pan.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.onPick = onPick
        guard let r = context.coordinator.renderer else { return }
        if context.coordinator.stationCount != stations.count {
            context.coordinator.stationCount = stations.count
            r.setStations(stations.map { ($0.latitude, $0.longitude) })
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: GlobeRenderer?
        weak var view: MTKView?
        var onPick: ((Double, Double) -> Void)?
        var stationCount = -1
        private var pinchStart = 0.0

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let r = renderer, let v = view else { return }
            let t = g.translation(in: v)
            r.camera.drag(by: CGSize(width: t.x, height: t.y))
            g.setTranslation(.zero, in: v)
            if g.state == .began { r.camera.velocity = .zero }
            if g.state == .ended { r.camera.fling(g.velocity(in: v)) }
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let r = renderer else { return }
            if g.state == .began { pinchStart = r.camera.distance }
            // Zoom on the gap to the surface so it slows near the ground.
            let gap = (pinchStart - 1) / Double(max(g.scale, 0.05))
            r.camera.zoom(to: 1 + gap)
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let r = renderer, let v = view, let p = r.pick(g.location(in: v), in: v.bounds.size) else { return }
            onPick?(p.latitude, p.longitude)
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let r = renderer, let v = view else { return }
            if let p = r.pick(g.location(in: v), in: v.bounds.size) {
                r.camera.fly(to: p.latitude, p.longitude, distance: max(OrbitCamera.minDistance, 1 + (r.camera.distance - 1) * 0.55))
            } else {
                r.camera.fly(to: r.camera.latitude, r.camera.longitude, distance: 3.4)
            }
        }

        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }
    }
}
