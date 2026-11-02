import MapKit
import SwiftUI
import TideKit

struct StationMapView: View {
    @Environment(StationStore.self) private var store
    @State private var position: MapCameraPosition = .userLocation(fallback: .region(
        MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 37.5, longitude: -96), span: MKCoordinateSpan(latitudeDelta: 40, longitudeDelta: 50))))
    @State private var selectedID: String?

    var body: some View {
        Map(position: $position, selection: $selectedID) {
            ForEach(store.stations) { s in
                Marker(s.name, systemImage: s.isTidal ? "water.waves" : "drop.fill",
                       coordinate: CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude))
                    .tint(tint(for: s))
                    .tag(s.id)
            }
            UserAnnotation()
        }
        // A quiet basemap so the stations read first.
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
            MapScaleView()
        }
        .navigationTitle("Map")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let id = selectedID, let s = store.station(id: id) {
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
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationDestination(for: Station.self) { StationDetailView(station: $0) }
    }

    private func tint(for s: Station) -> Color {
        switch s.source {
        case .noaaCoops: return s.isTidal ? Theme.harbor : Theme.tideTable
        case .dfoIWLS, .ukAdmiralty: return Theme.ink.opacity(0.7)
        default: return Theme.tideTable
        }
    }
}
