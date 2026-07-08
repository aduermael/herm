import SwiftUI
#if canImport(CoreLocation)
@preconcurrency import CoreLocation
#endif
#if canImport(MapKit)
import MapKit
#endif

struct CPSLToolStripView: View {
    @ObservedObject var model: CPSLChatModel
    @ObservedObject private var calendar: CPSLCalendarService
    @ObservedObject private var location: CPSLLocationService

    init(model: CPSLChatModel) {
        self.model = model
        _calendar = ObservedObject(wrappedValue: model.calendar)
        _location = ObservedObject(wrappedValue: model.location)
    }

    private func controlTint(isActive: Bool) -> Color {
        isActive ? CPSLGlassTuning.tint(CPSLTheme.card, opacity: 0.52) : CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.40)
    }

    private func controlStrokeOpacity(isActive: Bool) -> Double {
        isActive ? 0.10 : 0.045
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CPSLTheme.medium) {
                CPSLToolStripButton(
                    title: "Files",
                    systemName: "folder.fill",
                    color: CPSLTheme.IconPalette.folder,
                    tint: controlTint(isActive: model.isFileBrowserOpen),
                    strokeOpacity: controlStrokeOpacity(isActive: model.isFileBrowserOpen),
                    isGlowing: model.isFileActivityActive
                ) {
                    model.toggleFileBrowser()
                }

                CPSLToolStripButton(
                    title: "Browser",
                    systemName: "globe",
                    color: CPSLTheme.success,
                    tint: controlTint(isActive: model.isWebBrowserOpen),
                    strokeOpacity: controlStrokeOpacity(isActive: model.isWebBrowserOpen),
                    isGlowing: model.webBrowser.isActivityActive
                ) {
                    model.toggleWebBrowser()
                }

                CPSLToolStripButton(
                    title: "Calendar",
                    systemName: "calendar",
                    color: CPSLTheme.IconPalette.calendar,
                    tint: controlTint(isActive: calendar.access.isGranted),
                    strokeOpacity: controlStrokeOpacity(isActive: calendar.access.isGranted),
                    isGlowing: calendar.isRequestingAccess
                ) {
                    model.toggleCalendarAccess()
                }

                CPSLLocationToolStripButton(
                    access: location.access,
                    location: location.currentLocation,
                    isUpdating: location.isUpdatingLocation || location.isRequestingAccess
                ) {
                    model.toggleLocationAccess()
                }

                CPSLDisabledToolIcon(systemName: "envelope.fill", color: CPSLTheme.IconPalette.mail)
            }
            .padding(.horizontal, CPSLTheme.chromeHorizontalInset)
        }
        .frame(height: CPSLTheme.controlSize)
        .padding(.bottom, CPSLTheme.medium)
    }
}

private struct CPSLLocationToolStripButton: View {
    let access: CPSLFeatureAccessState
    let location: CLLocation?
    let isUpdating: Bool
    let action: () -> Void

    private var hasMapBackground: Bool {
        access.isGranted && location != nil
    }

    var body: some View {
        Button(action: action) {
            if hasMapBackground, let location {
                CPSLLocationToolStripMapLabel(location: location, isGlowing: isUpdating)
            } else {
                CPSLToolStripButtonLabel(
                    title: "Location",
                    systemName: "location.fill",
                    color: CPSLTheme.success,
                    tint: access.isGranted
                        ? CPSLGlassTuning.tint(CPSLTheme.card, opacity: 0.52)
                        : CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.40),
                    strokeOpacity: access.isGranted ? 0.10 : 0.045,
                    isGlowing: isUpdating
                )
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.text)
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLLocationToolStripMapLabel: View {
    let location: CLLocation
    let isGlowing: Bool

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            Image(systemName: "location.fill")
                .symbolRenderingMode(.hierarchical)
                .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
            Text("Location")
                .font(CPSLTheme.controlFont)
        }
        .padding(.horizontal, CPSLTheme.medium)
        .frame(height: CPSLTheme.controlSize)
        .background {
            ZStack {
                CPSLLocationMapThumbnail(location: location)
                CPSLTheme.background.opacity(0.34)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous)
                .stroke(CPSLTheme.text.opacity(isGlowing ? 0.18 : 0.10), lineWidth: 1)
        )
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .cpslActivityGlow(
            when: isGlowing,
            color: CPSLTheme.success,
            in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLLocationMapThumbnail: View {
    let location: CLLocation

    var body: some View {
#if canImport(MapKit)
        CPSLLocationMapRepresentable(coordinate: location.coordinate)
#else
        CPSLTheme.success.opacity(0.35)
#endif
    }
}

private struct CPSLToolStripButton: View {
    let title: LocalizedStringKey
    let systemName: String
    let color: Color
    let tint: Color
    let strokeOpacity: Double
    var isGlowing = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CPSLToolStripButtonLabel(
                title: title,
                systemName: systemName,
                color: color,
                tint: tint,
                strokeOpacity: strokeOpacity,
                isGlowing: isGlowing
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.text)
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

#if canImport(MapKit) && canImport(UIKit)
private struct CPSLLocationMapRepresentable: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D

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
        mapView.showsUserLocation = true
        update(mapView)
    }

    private func update(_ mapView: MKMapView) {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        mapView.setRegion(region, animated: false)
    }
}
#elseif canImport(MapKit) && os(macOS)
private struct CPSLLocationMapRepresentable: NSViewRepresentable {
    let coordinate: CLLocationCoordinate2D

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
        mapView.showsUserLocation = true
        update(mapView)
    }

    private func update(_ mapView: MKMapView) {
        let region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        mapView.setRegion(region, animated: false)
    }
}
#endif

private struct CPSLToolStripButtonLabel: View {
    let title: LocalizedStringKey
    let systemName: String
    let color: Color
    let tint: Color
    let strokeOpacity: Double
    let isGlowing: Bool

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(CPSLTheme.controlFont)
        }
        .padding(.horizontal, CPSLTheme.medium)
        .frame(height: CPSLTheme.controlSize)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
            tint: tint,
            strokeOpacity: isGlowing ? 0.18 : strokeOpacity
        )
        .cpslActivityGlow(
            when: isGlowing,
            color: color,
            in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
    }
}

private struct CPSLDisabledToolIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.hierarchical)
            .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
            .cpslGlassBackground(
                in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
                tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.34),
                strokeOpacity: 0.035
            )
            .opacity(0.62)
    }
}
