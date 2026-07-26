import SwiftUI
#if canImport(CoreLocation)
@preconcurrency import CoreLocation
#endif
#if canImport(MapKit)
import MapKit
#endif

struct CPSLLocationMapView: View {
    let location: CLLocation
    var markerSize: CGFloat = 11
    var span: CLLocationDegrees = 0.01
    /// Defer MKMapView construction until after the first frame so opening Location
    /// does not hitch the main thread on MapKit setup.
    @State private var isMapReady = false

    var body: some View {
        Group {
            if isMapReady {
                mapContent
            } else {
                CPSLTheme.elevated
            }
        }
        .overlay {
            Circle()
                .fill(.blue)
                .frame(width: markerSize, height: markerSize)
                .overlay(
                    Circle()
                        .stroke(.white, lineWidth: max(2, markerSize * 0.18))
                )
                .shadow(color: .black.opacity(0.24), radius: 2, y: 1)
        }
        .task {
            // Yield twice so the overlay panel can finish its open animation first.
            await Task.yield()
            await Task.yield()
            isMapReady = true
        }
    }

    @ViewBuilder
    private var mapContent: some View {
#if canImport(MapKit)
        CPSLLocationMapRepresentable(
            coordinate: location.coordinate,
            span: span
        )
#else
        CPSLTheme.success.opacity(0.35)
#endif
    }
}

#if canImport(MapKit)
private final class CPSLLocationMapCoordinator {
    private var coordinate: CLLocationCoordinate2D?
    private var span: CLLocationDegrees?

    func update(
        _ mapView: MKMapView,
        coordinate: CLLocationCoordinate2D,
        span: CLLocationDegrees
    ) {
        guard self.coordinate?.latitude != coordinate.latitude
                || self.coordinate?.longitude != coordinate.longitude
                || self.span != span
        else {
            return
        }

        self.coordinate = coordinate
        self.span = span
        mapView.setRegion(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
            ),
            animated: false
        )
    }
}
#endif

#if canImport(MapKit) && canImport(UIKit)
private struct CPSLLocationMapRepresentable: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let span: CLLocationDegrees

    func makeCoordinator() -> CPSLLocationMapCoordinator {
        CPSLLocationMapCoordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        configure(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.update(mapView, coordinate: coordinate, span: span)
    }

    private func configure(_ mapView: MKMapView) {
        mapView.isUserInteractionEnabled = false
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsUserLocation = false
    }
}
#elseif canImport(MapKit) && os(macOS)
private struct CPSLLocationMapRepresentable: NSViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let span: CLLocationDegrees

    func makeCoordinator() -> CPSLLocationMapCoordinator {
        CPSLLocationMapCoordinator()
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        configure(mapView)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.update(mapView, coordinate: coordinate, span: span)
    }

    private func configure(_ mapView: MKMapView) {
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsUserLocation = false
    }
}
#endif
