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

    var body: some View {
        mapContent
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

#if canImport(MapKit) && canImport(UIKit)
private struct CPSLLocationMapRepresentable: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let span: CLLocationDegrees

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        configure(mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        update(mapView)
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
        update(mapView)
    }

    private func update(_ mapView: MKMapView) {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        )
        mapView.setRegion(region, animated: false)
    }
}
#elseif canImport(MapKit) && os(macOS)
private struct CPSLLocationMapRepresentable: NSViewRepresentable {
    let coordinate: CLLocationCoordinate2D
    let span: CLLocationDegrees

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        configure(mapView)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        update(mapView)
    }

    private func configure(_ mapView: MKMapView) {
        mapView.isScrollEnabled = false
        mapView.isZoomEnabled = false
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsUserLocation = false
        update(mapView)
    }

    private func update(_ mapView: MKMapView) {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        )
        mapView.setRegion(region, animated: false)
    }
}
#endif
