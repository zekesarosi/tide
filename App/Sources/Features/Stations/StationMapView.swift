import MapKit
import SwiftUI
import TideKit

/// Every station on a quiet basemap. Zoomed in on San Francisco Bay, the bay
/// stations come alive: each marker fills and drains with the tide, a panel
/// plays the tidal day, and the bay's timing is a tap away.
struct StationMapView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(StationStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var position: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.5, longitude: -96), span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 50))))
    @State private var selectedID: String?
    @State private var region: MKCoordinateRegion?

    // Bay mode
    @State private var baySelected = SFBay.defaultComparisonCode
    @State private var clock = BayClock(time: Date())
    @State private var showingBayDetails = false

    private var bay: BayModel { env.bay }

    /// The whole bay, Point Reyes to Carquinez and the South Bay.
    static let bayRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.66, longitude: -122.50),
        span: MKCoordinateSpan(latitudeDelta: 1.05, longitudeDelta: 1.15))

    /// Bay mode is on when the map is looking at the bay, closely enough for
    /// its stations to read as separate markers.
    private var inBay: Bool {
        guard let r = region else { return false }
        let b = Self.bayRegion
        let overlaps = abs(r.center.latitude - b.center.latitude) < (r.span.latitudeDelta + b.span.latitudeDelta) / 2
            && abs(r.center.longitude - b.center.longitude) < (r.span.longitudeDelta + b.span.longitudeDelta) / 2
        return overlaps && r.span.latitudeDelta < 1.6
    }

    /// Names on every marker once zoomed in past the whole-bay view.
    private var zoomedIn: Bool { (region?.span.latitudeDelta ?? 1) < 0.35 }

    private var bayDay: BayDay? { inBay ? bay.day : nil }

    var body: some View {
        let day = bayDay
        let bayCodes = day == nil ? Set<String>() : Set(day!.rows.map(\.station.code))
        Map(position: $position, selection: $selectedID) {
            ForEach(store.stations.filter { !($0.source == .noaaCoops && bayCodes.contains($0.code)) }) { s in
                Marker(s.name, systemImage: s.isTidal ? "water.waves" : "drop.fill",
                       coordinate: CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude))
                    .tint(tint(for: s))
                    .tag(s.id)
            }
            if let day {
                ForEach(day.rows) { row in
                    Annotation(row.station.shortName,
                               coordinate: CLLocationCoordinate2D(latitude: row.station.latitude, longitude: row.station.longitude),
                               anchor: .center) {
                        BayPin(row: row, start: day.start, clock: clock, unit: settings.unit,
                               label: label(for: row.station.code),
                               isSelected: baySelected == row.station.code)
                            .onTapGesture {
                                selectedID = nil
                                withAnimation(.snappy) { baySelected = row.station.code }
                            }
                    }
                    .annotationTitles(.hidden)
                }
            }
            UserAnnotation()
        }
        // A quiet basemap so the stations read first; quieter still over the bay.
        .mapStyle(.standard(elevation: .flat, emphasis: inBay ? .muted : .automatic,
                            pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            region = context.region
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    env.router.showingGlobe = true
                } label: {
                    Label("Globe", systemImage: "globe.americas")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel("Show the Tide Globe")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !inBay {
                    Button {
                        flyToBay()
                    } label: {
                        Label("SF Bay", systemImage: "water.waves")
                            .labelStyle(.titleAndIcon)
                            .font(.subheadline.weight(.semibold))
                    }
                    .accessibilityLabel("Show San Francisco Bay tides")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let id = selectedID, let s = store.station(id: id) {
                    stationCard(s)
                }
                if inBay { bayPanel }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .animation(reduceMotion ? nil : .snappy, value: inBay)
        }
        .sheet(isPresented: $showingBayDetails) {
            if let a = bay.analysis, let day = bay.day {
                BayDetailsSheet(analysis: a, day: day, clock: clock, selected: $baySelected, unit: settings.unit)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationDragIndicator(.visible)
            }
        }
        .task(id: inBay) {
            if inBay {
                await bay.loadIfNeeded(service: env.service)
                if let d = bay.day, !clock.playing { clock.time = d.clamp(Date()) }
            } else {
                clock.playing = false
            }
        }
        .task(id: clock.playing) {
            if let d = bay.day { await clock.run(day: d) }
        }
        .onAppear { consumeBayFocus() }
        .onChange(of: env.router.bayFocus) { consumeBayFocus() }
        .onDisappear { clock.playing = false }
        .navigationDestination(for: Station.self) { StationDetailView(station: $0).id($0.id) }
    }

    // MARK: Bay

    @ViewBuilder
    private var bayPanel: some View {
        if let a = bay.analysis, let d = bay.day {
            BayPanel(analysis: a, day: d, clock: clock, selected: $baySelected, unit: settings.unit) {
                showingBayDetails = true
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if case .failed(let message) = bay.phase {
            HStack(spacing: 10) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Theme.warning)
                Text(message).font(.footnote).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                Spacer(minLength: 4)
                Button("Retry") { Task { await bay.load(service: env.service) } }
                    .font(.footnote.weight(.semibold))
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        } else {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Reading the tide at \(SFBay.stations.count) stations around the bay…")
                    .font(.footnote).foregroundStyle(Theme.inkSecondary)
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func label(for code: String) -> Alignment? {
        if let a = BayMarkers.labels[code] { return a }
        return zoomedIn || baySelected == code ? .bottom : nil
    }

    private func flyToBay() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.8)) {
            position = .region(Self.bayRegion)
        }
        // `onMapCameraChange` reports the move when it ends; set it now so the
        // panel and markers don't wait for the animation.
        region = Self.bayRegion
    }

    /// A station screen or `tideforecast://bay` asked for the bay.
    private func consumeBayFocus() {
        guard let focus = env.router.bayFocus else { return }
        env.router.bayFocus = nil
        selectedID = nil
        if let code = focus.code, SFBay.station(code: code) != nil {
            baySelected = code
        }
        flyToBay()
    }

    // MARK: Pieces

    private func stationCard(_ s: Station) -> some View {
        NavigationLink(value: s) {
            HStack {
                VStack(alignment: .leading) {
                    Text(s.name).font(.headline)
                    Text("\(s.region ?? "") · \(DataSourceInfo.info(s.source).agency)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func tint(for s: Station) -> Color {
        switch s.source {
        case .noaaCoops: return s.isTidal ? Theme.harbor : Theme.tideTable
        case .dfoIWLS, .ukAdmiralty: return Theme.ink.opacity(0.7)
        default: return Theme.tideTable
        }
    }
}
