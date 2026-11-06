import MetalKit
import SwiftUI
import TideKit

/// San Francisco Bay in 3D: the seafloor, the water at its level, and the
/// currents drifting through the Golden Gate, from a harmonic model of NOAA's
/// SFBOFS (plus its live forecast, when loaded). Zoom from the whole bay to a
/// few hundred metres, and scrub a week either side of now.
struct BaySceneView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var model = BaySceneModel()
    @State private var live = BayLiveStore()
    @State private var showingInfo = false
    @State private var headerBottom: CGFloat = 0
    @State private var controlsTop: CGFloat = .infinity

    static let background = Color(red: 0.016, green: 0.031, blue: 0.043)

    var body: some View {
        ZStack {
            Self.background.ignoresSafeArea()
            switch model.phase {
            case .ready:
                if let mesh = model.mesh, let geometry = model.geometry {
                    BaySceneMetalView(model: model, mesh: mesh, geometry: geometry) { p in
                        withAnimation(reduceMotion ? nil : .snappy) { model.makeProbe(at: p) }
                    }
                    .ignoresSafeArea()
                    .accessibilityLabel("3D map of San Francisco Bay tides and currents")
                    .accessibilityHint("Drag to move, pinch to zoom, twist to turn, two-finger drag to tilt. Tap the water to read the tide and current there.")
                    BaySceneLabels(overlay: model.overlay)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
            case .loading:
                ProgressView().tint(.white)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                header
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { headerBottom = $0; updateLabelBand() }
                Spacer(minLength: 0)
                controls
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { controlsTop = $0; updateLabelBand() }
            }
        }
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showingInfo) { BaySceneInfoSheet().presentationDetents([.medium, .large]) }
        .task {
            model.calmFlow = reduceMotion
            await model.load()
            // Testing aids: -BaySceneHours <h> starts h hours from now, paused; -BaySceneMode level|speed|depth.
            let d = UserDefaults.standard
            if let m = d.string(forKey: "BaySceneMode").flatMap(BaySceneModel.ColourMode.init(rawValue:)) { model.colourMode = m }
            if d.object(forKey: "BaySceneHours") != nil {
                model.setTime(model.anchor + d.double(forKey: "BaySceneHours") * 3_600)
            } else if !reduceMotion && !BaySceneBenchmark.isEnabled {
                model.playing = true
            }
            if let mesh = model.mesh, !BaySceneBenchmark.isEnabled { await live.refresh(mesh: mesh) }
        }
        .onChange(of: live.residual?.cycle, initial: true) {
            model.residual = live.residual
        }
        .onChange(of: reduceMotion) { model.calmFlow = reduceMotion }
    }

    /// Labels keep clear of the header and the bottom panel.
    private func updateLabelBand() {
        let lo = headerBottom + 10, hi = controlsTop - 10
        model.overlay.labelBand = lo < hi ? lo...hi : nil
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
            BaySceneClock(model: model, liveStatus: live.statusText)
            Spacer(minLength: 0)
            Menu {
                Picker("Colour", selection: $model.colourMode) {
                    ForEach(BaySceneModel.ColourMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Currents", selection: $model.surfaceCurrents) {
                    Text("Surface currents").tag(true)
                    Text("Depth-averaged currents").tag(false)
                }
                Toggle("Moving water", systemImage: "wind", isOn: $model.showsFlow)
                Picker("Relief", selection: $model.relief) {
                    ForEach(BaySceneModel.Relief.allCases) { Text($0.title).tag($0) }
                }
                Button("Whole bay", systemImage: "arrow.up.left.and.arrow.down.right") {
                    if let g = model.geometry {
                        model.flyRequest = (g.projection.point(latitude: 37.835, longitude: -122.452), 30_000)
                    }
                }
                Button("About this model", systemImage: "info.circle") { showingInfo = true }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Scene options")
        }
        .padding(.horizontal, Theme.margin)
        .padding(.top, 8)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            if let p = model.probe {
                BayProbeCard(model: model, probe: p, unit: settings.unit) {
                    withAnimation(reduceMotion ? nil : .snappy) { model.probe = nil }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            VStack(spacing: 12) {
                legend
                transport
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private var legend: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("Colour", selection: $model.colourMode) {
                    Text("Speed").tag(BaySceneModel.ColourMode.speed)
                    Text("Level").tag(BaySceneModel.ColourMode.level)
                    Text("Depth").tag(BaySceneModel.ColourMode.depth)
                }
                .pickerStyle(.segmented)
                .frame(width: 168)
                VStack(spacing: 3) {
                    LinearGradient(colors: model.colourMode == .level ? Self.levelColours : model.colourMode == .speed ? Self.speedColours : Self.depthColours,
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(height: 6)
                        .clipShape(Capsule())
                    HStack {
                        if model.colourMode == .level {
                            Text(Fmt.length(-Double(BaySceneRenderer.levelScale), settings.unit, signed: true))
                            Spacer()
                            Text("mean")
                            Spacer()
                            Text(Fmt.length(Double(BaySceneRenderer.levelScale), settings.unit, signed: true))
                        } else if model.colourMode == .depth {
                            Text(Fmt.length(0, settings.unit, digits: 0))
                            Spacer()
                            Text(Fmt.length(20, settings.unit, digits: 0))
                            Spacer()
                            Text(Fmt.length(100, settings.unit, digits: 0) + " deep")
                        } else {
                            Text("0 kn")
                            Spacer()
                            Text(String(format: "%.1f kn", Double(BaySceneRenderer.speedScale) * Self.knots / 2))
                            Spacer()
                            Text(String(format: "%.0f+ kn", Double(BaySceneRenderer.speedScale) * Self.knots))
                        }
                    }
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
            if model.showsFlow {
                BayFlowLegend(overlay: model.overlay)
            }
        }
    }

    static let knots = 1.943_844
    static let levelColours = [Color(red: 0.42, green: 0.70, blue: 0.95), Color(red: 0.16, green: 0.42, blue: 0.72),
                               Color(red: 0.05, green: 0.16, blue: 0.24),
                               Color(red: 0.92, green: 0.56, blue: 0.30), Color(red: 1, green: 0.86, blue: 0.66)]
    /// Matches `bathyColour` at 0, 8, 20, 50 and 110 m, spaced by depth up to ~100 m.
    static let depthColours = [Color(red: 0.58, green: 0.55, blue: 0.42), Color(red: 0.30, green: 0.50, blue: 0.47),
                               Color(red: 0.13, green: 0.36, blue: 0.50), Color(red: 0.06, green: 0.17, blue: 0.36),
                               Color(red: 0.05, green: 0.06, blue: 0.20)]
    static let speedColours = [Color(red: 0.04, green: 0.12, blue: 0.17), Color(red: 0.12, green: 0.42, blue: 0.62),
                               Color(red: 0.44, green: 0.75, blue: 0.86), Color(red: 1, green: 0.86, blue: 0.55)]

    private var transport: some View {
        HStack(spacing: 10) {
            Button {
                model.playing.toggle()
            } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(model.playing ? "Pause" : "Play")
            BaySceneScrubber(model: model)
            Menu {
                Picker("Speed", selection: $model.rate) {
                    ForEach(BaySceneModel.rates, id: \.0) { r in
                        Text(r.1).tag(r.0)
                    }
                }
            } label: {
                Text(model.rateLabel)
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            .accessibilityLabel("Playback speed, \(model.rateLabel)")
            Button("Now") { model.jumpToNow() }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10).frame(height: 32)
                .background(Color.white.opacity(0.08), in: Capsule())
                .buttonStyle(.plain)
                .accessibilityLabel("Jump to now")
        }
    }
}

// MARK: - Views that follow the clock or the camera
//
// The renderer moves the clock every frame and publishes `model.time` about
// 15 times a second, and the overlay ~10 times a second. Only these small
// views read them, so the rest of the screen (and its menus) stays put.

extension BaySceneModel {
    static let zone = TimeZone(identifier: "America/Los_Angeles") ?? .current

    var timeTitle: String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        style.timeZone = Self.zone
        return time.formatted(style)
    }
}

private struct BaySceneClock: View {
    let model: BaySceneModel
    let liveStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SAN FRANCISCO BAY")
                .font(.caption.weight(.semibold)).tracking(1.2)
                .foregroundStyle(.secondary)
            Text(model.timeTitle)
                .font(.title3.weight(.light)).monospacedDigit()
            HStack(spacing: 5) {
                Circle()
                    .fill(model.isLive(at: model.time) ? Theme.swell : Color.white.opacity(0.4))
                    .frame(width: 6, height: 6)
                Text(sourceLine)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var sourceLine: String {
        if let r = model.residual {
            if model.isLive(at: model.time) {
                // Cycles are named by their UTC hour (03/09/15/21Z). Format it
                // directly: locale date styles would give a 12-hour "09" for 21Z.
                var utc = Calendar(identifier: .gregorian)
                utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
                let hour = utc.component(.hour, from: r.cycle)
                return "Live forecast (SFBOFS \(String(format: "%02d", hour))Z run)"
            }
            return "Tide only · live forecast ends \(r.end.formatted(.relative(presentation: .named)))"
        }
        return "Tide only (harmonic model)"
    }
}

private struct BaySceneScrubber: View {
    @Bindable var model: BaySceneModel

    var body: some View {
        Slider(value: $model.offset, in: -BaySceneModel.window / 3_600...BaySceneModel.window / 3_600) { editing in
            if editing { model.playing = false }
        }
        .tint(Theme.swell)
        .accessibilityLabel("Time")
        .accessibilityValue(model.timeTitle)
    }
}

private struct BayFlowLegend: View {
    let overlay: BaySceneOverlay

    var body: some View {
        HStack(spacing: 6) {
            LinearGradient(colors: [Color(red: 0.55, green: 0.78, blue: 0.92).opacity(0.5), .white, Color(red: 1, green: 0.84, blue: 0.5)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 34, height: 3)
                .clipShape(Capsule())
            Text("Drift trails: 0 → \(String(format: "%.0f", Double(BaySceneRenderer.speedScale) * BaySceneView.knots)) kn · 1 s shows \(driftText) of flow")
                .lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
        .font(.caption2).monospacedDigit()
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Moving trails follow the current, brighter and warmer where it's faster; slack water has fewer. Each second shows \(driftText) of drift.")
    }

    private var driftText: String {
        let s = overlay.driftFactor
        if s < 90 { return "\(Int(s.rounded())) s" }
        if s < 5_400 { return "\(Int((s / 60).rounded())) min" }
        return String(format: "%.1f h", s / 3_600)
    }
}

private struct BaySceneLabels: View {
    let overlay: BaySceneOverlay

    var body: some View {
        ZStack {
            ForEach(overlay.labels) { l in
                Text(l.id)
                    .font(l.isWater ? .caption.italic() : .caption.weight(.semibold))
                    .foregroundStyle(l.isWater ? Color(red: 0.72, green: 0.86, blue: 0.96) : Color.white.opacity(0.88))
                    .shadow(color: .black.opacity(0.8), radius: 2)
                    .fixedSize()
                    .position(l.point)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
}

// MARK: - Probe

private struct BayProbeCard: View {
    let model: BaySceneModel
    let probe: BayProbe
    let unit: LengthUnit
    let close: () -> Void

    var body: some View {
        let t = model.time
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(coordinate).font(.subheadline.weight(.semibold)).monospacedDigit()
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Close reading")
            }
            switch probe.place {
            case .water:
                if let h = model.waterLevel(probe, at: t) {
                    let rising = (model.waterLevel(probe, at: t + 300) ?? h) > h
                    HStack(alignment: .lastTextBaseline, spacing: 10) {
                        Text(Fmt.length(h, unit, signed: true))
                            .font(Font.cardValue).monospacedDigit()
                        Label(rising ? "Rising" : "Falling", systemImage: rising ? "arrow.up.right" : "arrow.down.right")
                            .font(.subheadline).foregroundStyle(rising ? Theme.swell : Theme.harbor)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(probe.nextEvents(after: t), id: \.date) { e in
                                Text("\(e.kind == .high ? "High" : "Low") \(Self.clock(e.date))")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let c = model.current(probe, at: t) {
                    currentLine(c)
                }
                if let p = probe.predictor {
                    BayProbeCurve(predictor: p, time: t)
                        .frame(height: 50)
                }
                Text(model.isLive(at: t) ? "Level relative to the model's mean sea level, with the live forecast. Curve: tide only." :
                        "Level relative to the model's mean sea level. Tide only; weather and river flow not included.")
                    .font(.caption2).foregroundStyle(.secondary)
            case .land:
                Text("That's land. Tap the water to read the tide and current there.")
                    .font(.subheadline).foregroundStyle(.secondary)
            case .outside:
                Text("That's the open Pacific, past the edge of this bay model.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    @ViewBuilder
    private func currentLine(_ c: (east: Double, north: Double)) -> some View {
        let speed = (c.east * c.east + c.north * c.north).squareRoot()
        let kn = speed * BaySceneView.knots
        let toward = (atan2(c.east, c.north) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        HStack(spacing: 8) {
            Image(systemName: "location.north.fill")
                .rotationEffect(.degrees(toward))
                .foregroundStyle(Theme.harbor)
                .opacity(kn < 0.1 ? 0.3 : 1)
            if kn < 0.1 {
                Text("Slack water").font(.subheadline.weight(.semibold))
            } else {
                Text(String(format: "%.1f kn", kn)).font(.subheadline.weight(.semibold)).monospacedDigit()
                Text("toward \(Fmt.compass(toward)) (\(String(format: "%03.0f", toward))°)")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.surfaceCurrents ? "surface" : "depth-averaged")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    static func clock(_ d: Date) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = BaySceneModel.zone
        return d.formatted(style)
    }

    private var coordinate: String {
        String(format: "%.4f° N  %.4f° W", probe.latitude, abs(probe.longitude))
    }
}

/// ±12 hours of the tide at the probe, with the scene's instant in the middle.
private struct BayProbeCurve: View {
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

private struct BaySceneInfoSheet: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Twice a day the Pacific pours in through the Golden Gate and drains out again. The channel under the bridge is over 100 m deep and only 1.6 km wide, so the current there runs at 3 to 5 knots: the flood fans out across the Central Bay and through Raccoon Strait; the ebb shoots out past Point Bonita as a jet.")
                    Text("Colour is the water level (or the current's speed). The drifting trails follow the current: brighter and warmer where it's faster. They are sped up so you can see them move; the legend says by how much. Depth and water level are exaggerated vertically so you can see them.")
                    SectionLabel("Method")
                    Text("NOAA's San Francisco Bay Operational Forecast System (SFBOFS, an FVCOM model) was run back over months of hourly output; at every one of its mesh nodes the tide and the currents were fitted as harmonic constituents. Your phone evaluates those constants for any instant, on the GPU, at every node. When the live forecast is available, the model's latest run (minus the tide) is added for the next two days, so wind, river flow and surge show too.")
                    SectionLabel("Sources")
                    Text("NOAA CO-OPS SFBOFS (FVCOM), via NOAA NCEI and CO-OPS THREDDS. Harmonic analysis and the 3D scene: this app.")
                        .foregroundStyle(.secondary)
                    Text("A model, not a measurement. Levels are relative to the model's own mean sea level, not chart datum. Not for navigation.")
                        .foregroundStyle(.secondary)
                }
                .font(.body)
                .padding(Theme.margin)
            }
            .navigationTitle("Bay in 3D")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Metal view

struct BaySceneMetalView: UIViewRepresentable {
    let model: BaySceneModel
    let mesh: TideMesh
    let geometry: BaySceneGeometry
    let onPick: (SIMD2<Double>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isOpaque = true
        view.backgroundColor = .black
        guard let renderer = BaySceneRenderer(view: view, model: model, mesh: mesh, geometry: geometry) else { return view }
        let c = context.coordinator
        c.renderer = renderer
        c.view = view
        view.delegate = renderer

        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let tilt = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.tilt(_:)))
        tilt.minimumNumberOfTouches = 2
        tilt.maximumNumberOfTouches = 2
        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: c, action: #selector(Coordinator.rotate(_:)))
        let doubleTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let twoFingerTap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.zoomOut(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        // A short pinch also looks like a two-finger tap; only zoom out when
        // no pinch, twist or tilt happened.
        twoFingerTap.require(toFail: pinch)
        twoFingerTap.require(toFail: rotate)
        twoFingerTap.require(toFail: tilt)
        let tap = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap(_:)))
        tap.require(toFail: doubleTap)
        for g in [pan, tilt, pinch, rotate, doubleTap, twoFingerTap, tap] as [UIGestureRecognizer] {
            g.delegate = c
            view.addGestureRecognizer(g)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.onPick = onPick
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var renderer: BaySceneRenderer?
        weak var view: MTKView?
        var onPick: ((SIMD2<Double>) -> Void)?
        private var last: CGPoint = .zero
        private var tiltLast: CGPoint = .zero
        /// Finger spread when the two-finger gesture began, and what it turned out to be.
        private var tiltSpread: CGFloat = 0
        private var twoFinger: TwoFinger = .undecided
        private enum TwoFinger { case undecided, tilt, pinch }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let r = renderer, let v = view else { return }
            let p = g.location(in: v)
            switch g.state {
            case .began:
                r.camera.velocity = .zero
                last = p
            case .changed:
                r.camera.drag(from: last, to: p, in: v.bounds.size)
                last = p
            case .ended:
                r.camera.fling(velocity: g.velocity(in: v), at: p, in: v.bounds.size)
            default: break
            }
        }

        @objc func tilt(_ g: UIPanGestureRecognizer) {
            guard let r = renderer, let v = view else { return }
            let t = g.translation(in: v)
            guard g.numberOfTouches == 2 else { return }
            let a = g.location(ofTouch: 0, in: v), b = g.location(ofTouch: 1, in: v)
            let spread = hypot(a.x - b.x, a.y - b.y)
            if g.state == .began {
                tiltLast = .zero
                tiltSpread = spread
                twoFinger = .undecided
            }
            let dy = t.y - tiltLast.y
            tiltLast = t
            // Decide once per gesture: fingers sliding up or down together
            // tilt; fingers spreading or closing pinch (and never tilt).
            if twoFinger == .undecided {
                let spreadChange = abs(spread - tiltSpread)
                if spreadChange > 18 { twoFinger = .pinch }
                else if abs(t.y) > 22, abs(t.y) > abs(t.x) * 1.5 { twoFinger = .tilt }
                else { return }
            }
            guard twoFinger == .tilt else { return }
            r.camera.tilt(by: -Double(dy) * 0.006)
        }

        @objc func pinch(_ g: UIPinchGestureRecognizer) {
            guard let r = renderer, let v = view, g.numberOfTouches >= 2 || g.state == .changed else { return }
            // While tilting, the spread wobbles a little: don't zoom on it.
            if twoFinger == .tilt { g.scale = 1; return }
            r.camera.velocity = .zero
            r.camera.zoom(by: Double(g.scale), about: g.location(in: v), in: v.bounds.size)
            g.scale = 1
        }

        @objc func rotate(_ g: UIRotationGestureRecognizer) {
            guard let r = renderer, let v = view else { return }
            r.camera.rotate(by: Double(g.rotation), about: g.location(in: v), in: v.bounds.size)
            g.rotation = 0
        }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let r = renderer, let v = view, let p = r.pick(g.location(in: v), in: v.bounds.size) else { return }
            onPick?(p)
        }

        @objc func doubleTap(_ g: UITapGestureRecognizer) {
            guard let r = renderer, let v = view, let p = r.pick(g.location(in: v), in: v.bounds.size) else { return }
            r.camera.fly(to: p, distance: r.camera.distance * 0.45)
        }

        @objc func zoomOut(_ g: UITapGestureRecognizer) {
            guard let r = renderer else { return }
            r.camera.fly(to: r.camera.target, distance: r.camera.distance * 2.2)
        }

        func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool { true }
    }
}
