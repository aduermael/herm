import SwiftUI

enum CPSLGlassTuning {
    static let tintOpacityScale: Double = 1.12
    static let nativeGlassTintOpacity: Double = 0.30

    static func tint(_ color: Color, opacity: Double) -> Color {
        color.opacity(min(opacity * tintOpacityScale, 1))
    }
}

struct CPSLGlassSurface<S: Shape>: View {
    let shape: S
    let tint: Color
    let strokeOpacity: Double

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) {
            nativeGlass
        } else {
            materialGlass
        }
    }

    private var nativeGlass: some View {
        shape
            .fill(CPSLTheme.background.opacity(0.001))
            .glassEffect(
                .clear.tint(CPSLTheme.background.opacity(CPSLGlassTuning.nativeGlassTintOpacity)),
                in: shape
            )
            .overlay(shape.fill(tint))
            .overlay(stroke)
    }

    private var materialGlass: some View {
        shape
            .fill(.thinMaterial)
            .overlay(shape.fill(tint))
            .overlay(stroke)
    }

    private var stroke: some View {
        shape.stroke(CPSLTheme.text.opacity(strokeOpacity), lineWidth: 1)
    }
}

struct CPSLGlassBackgroundModifier<S: Shape>: ViewModifier {
    let shape: S
    let tint: Color
    let strokeOpacity: Double

    func body(content: Content) -> some View {
        content
            .background {
                CPSLGlassSurface(
                    shape: shape,
                    tint: tint,
                    strokeOpacity: strokeOpacity
                )
            }
            .clipShape(shape)
    }
}

extension View {
    func cpslGlassBackground<S: Shape>(
        in shape: S,
        tint: Color = CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.40),
        strokeOpacity: Double = 0.045
    ) -> some View {
        modifier(
            CPSLGlassBackgroundModifier(
                shape: shape,
                tint: tint,
                strokeOpacity: strokeOpacity
            )
        )
    }
}
