import SwiftUI
#if canImport(CoreLocation)
@preconcurrency import CoreLocation
#endif

struct CPSLLocationOverlay: View {
    @ObservedObject private var model: CPSLChatModel
    @ObservedObject private var location: CPSLLocationService
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(
        model: CPSLChatModel,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) {
        _model = ObservedObject(wrappedValue: model)
        _location = ObservedObject(wrappedValue: model.location)
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    var body: some View {
        CPSLFileOverlayStage(
            metrics: CPSLFileOverlayStageMetrics(
                topInset: topInset,
                bottomInset: bottomInset,
                dimOpacity: 0.001
            )
        ) {
            CPSLLocationPanel(model: model, location: location)
        }
    }
}

private struct CPSLLocationPanel: View {
    @ObservedObject var model: CPSLChatModel
    @ObservedObject var location: CPSLLocationService

    var body: some View {
        CPSLFileOverlayPanel {
            CPSLLocationHeader(model: model, location: location)
        } content: {
            CPSLLocationContent(location: location)
        }
    }
}

private struct CPSLLocationHeader: View {
    @ObservedObject var model: CPSLChatModel
    @ObservedObject var location: CPSLLocationService

    private var subtitle: LocalizedStringKey {
        if location.isLoadingCurrentLocation {
            return "Updating current location"
        }
        switch location.access {
        case .granted:
            return location.currentLocation == nil ? "No location loaded" : "Current device location"
        case .denied:
            return "Access denied"
        case .undefined:
            return "Access not requested"
        }
    }

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            Image(systemName: "location.fill")
                .symbolRenderingMode(.hierarchical)
                .font(CPSLTheme.iconMediumFont)
                .foregroundStyle(CPSLTheme.success)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)

            VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
                Text("Location")
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: CPSLTheme.medium)

            CPSLFileOverlayIconButton(systemName: "arrow.clockwise", accessibilityLabel: "Refresh location") {
                Task {
                    await location.loadCurrentLocation()
                }
            }
            .disabled(location.isLoadingCurrentLocation || location.isRequestingAccess)
            .opacity(location.isLoadingCurrentLocation || location.isRequestingAccess ? 0.45 : 1)

            CPSLFileOverlayIconButton(systemName: "xmark", accessibilityLabel: "Close location") {
                model.closeLocation()
            }
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.vertical, CPSLTheme.small)
        .frame(minHeight: CPSLTheme.controlSize + CPSLTheme.medium)
    }
}

private struct CPSLLocationContent: View {
    @ObservedObject var location: CPSLLocationService

    var body: some View {
        ScrollView {
            LazyVStack(spacing: CPSLTheme.medium) {
                if location.isLoadingCurrentLocation || location.isRequestingAccess {
                    CPSLLocationStatusRow(systemName: "location.viewfinder", title: "Updating location")
                }

                if let locationError = location.locationError {
                    CPSLLocationStatusRow(systemName: "exclamationmark.triangle.fill", title: locationError)
                }

                if let currentLocation = location.currentLocation {
                    CPSLLocationMapSection(location: currentLocation)
                    CPSLLocationDetailsSection(location: currentLocation)
                } else if !location.isLoadingCurrentLocation && !location.isRequestingAccess && location.locationError == nil {
                    CPSLLocationStatusRow(systemName: "location.slash.fill", title: "No location loaded")
                }
            }
            .padding(CPSLTheme.medium)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct CPSLLocationMapSection: View {
    let location: CLLocation

    var body: some View {
        CPSLLocationMapView(location: location, markerSize: 14, span: 0.012)
            .frame(maxWidth: .infinity)
            .frame(height: 280)
            .background(CPSLTheme.background.opacity(0.22))
            .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous)
                    .stroke(CPSLTheme.text.opacity(0.07), lineWidth: 1)
            )
    }
}

private struct CPSLLocationDetailsSection: View {
    let location: CLLocation

    var body: some View {
        VStack(spacing: CPSLTheme.small) {
            CPSLLocationDetailRow(
                title: "Coordinates",
                value: coordinateText,
                systemName: "scope"
            )
            CPSLLocationDetailRow(
                title: "Accuracy",
                value: accuracyText,
                systemName: "dot.scope"
            )
            if let altitudeText {
                CPSLLocationDetailRow(
                    title: "Altitude",
                    value: altitudeText,
                    systemName: "mountain.2.fill"
                )
            }
            if let speedText {
                CPSLLocationDetailRow(
                    title: "Speed",
                    value: speedText,
                    systemName: "speedometer"
                )
            }
            CPSLLocationDetailRow(
                title: "Updated",
                value: location.timestamp.formatted(.dateTime.hour().minute().second()),
                systemName: "clock.fill"
            )
        }
    }

    private var coordinateText: String {
        let latitude = location.coordinate.latitude.formatted(.number.precision(.fractionLength(5)))
        let longitude = location.coordinate.longitude.formatted(.number.precision(.fractionLength(5)))
        return "\(latitude), \(longitude)"
    }

    private var accuracyText: String {
        guard location.horizontalAccuracy >= 0 else {
            return "Unavailable"
        }
        return "\(Int(location.horizontalAccuracy.rounded())) m"
    }

    private var altitudeText: String? {
        guard location.verticalAccuracy >= 0 else {
            return nil
        }
        return "\(Int(location.altitude.rounded())) m"
    }

    private var speedText: String? {
        guard location.speed >= 0 else {
            return nil
        }
        let speed = location.speed.formatted(.number.precision(.fractionLength(1)))
        return "\(speed) m/s"
    }
}

private struct CPSLLocationStatusRow: View {
    let systemName: String
    let title: String

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .font(CPSLTheme.iconMediumFont)
                .foregroundStyle(CPSLTheme.success)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)

            Text(title)
                .font(CPSLTheme.bodyFont)
                .foregroundStyle(CPSLTheme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CPSLTheme.medium)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.30),
            strokeOpacity: 0.045
        )
    }
}

private struct CPSLLocationDetailRow: View {
    let title: LocalizedStringKey
    let value: String
    let systemName: String

    var body: some View {
        HStack(alignment: .top, spacing: CPSLTheme.medium) {
            Image(systemName: systemName)
                .symbolRenderingMode(.hierarchical)
                .font(CPSLTheme.iconSmallFont)
                .foregroundStyle(CPSLTheme.success)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CPSLTheme.captionMediumFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
                Text(value)
                    .font(CPSLTheme.bodyFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(CPSLTheme.medium)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.30),
            strokeOpacity: 0.045
        )
    }
}
