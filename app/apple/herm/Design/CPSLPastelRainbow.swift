import SwiftUI

enum CPSLPastelRainbow {
    static let cycleDuration: TimeInterval = 4

    static let colors: [Color] = [
        Color(red: 0.923, green: 0.637, blue: 0.637),
        Color(red: 0.923, green: 0.780, blue: 0.637),
        Color(red: 0.923, green: 0.923, blue: 0.637),
        Color(red: 0.780, green: 0.923, blue: 0.637),
        Color(red: 0.637, green: 0.923, blue: 0.637),
        Color(red: 0.637, green: 0.923, blue: 0.780),
        Color(red: 0.637, green: 0.923, blue: 0.923),
        Color(red: 0.637, green: 0.780, blue: 0.923),
        Color(red: 0.637, green: 0.637, blue: 0.923),
        Color(red: 0.780, green: 0.637, blue: 0.923),
        Color(red: 0.923, green: 0.637, blue: 0.923),
        Color(red: 0.923, green: 0.637, blue: 0.780),
        Color(red: 0.923, green: 0.637, blue: 0.637)
    ]

    static func gradient(at angle: Angle) -> AngularGradient {
        AngularGradient(
            colors: colors,
            center: .center,
            startAngle: angle,
            endAngle: .degrees(angle.degrees + 360)
        )
    }

    static func angle(at date: Date) -> Angle {
        let elapsed = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration)
        return .degrees(elapsed / cycleDuration * 360)
    }

    static func textGradient(at progress: Double) -> LinearGradient {
        let offset = CGFloat(progress * 2)
        return LinearGradient(
            colors: colors,
            startPoint: UnitPoint(x: -offset, y: 0.5),
            endPoint: UnitPoint(x: 3 - offset, y: 0.5)
        )
    }

    static func textShift(at date: Date) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: cycleDuration)
        let phase = elapsed / cycleDuration
        return (1 - cos(phase * .pi * 2)) / 2
    }
}

private struct CPSLAnimatedPastelRainbowBorderModifier<S: InsettableShape>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let isActive: Bool
    let shape: S
    let lineWidth: CGFloat

    func body(content: Content) -> some View {
        content.overlay {
            if isActive {
                TimelineView(
                    .animation(
                        minimumInterval: 1.0 / 30.0,
                        paused: accessibilityReduceMotion
                    )
                ) { timeline in
                    shape.strokeBorder(
                        CPSLPastelRainbow.gradient(
                            at: accessibilityReduceMotion
                                ? .zero
                                : CPSLPastelRainbow.angle(at: timeline.date)
                        ),
                        lineWidth: lineWidth
                    )
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}

private struct CPSLAnimatedPastelRainbowForegroundModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func body(content: Content) -> some View {
        TimelineView(
            .animation(
                minimumInterval: 1.0 / 30.0,
                paused: accessibilityReduceMotion
            )
        ) { timeline in
            content.foregroundStyle(
                CPSLPastelRainbow.textGradient(
                    at: accessibilityReduceMotion
                        ? 0
                        : CPSLPastelRainbow.textShift(at: timeline.date)
                )
            )
        }
    }
}

extension View {
    func cpslAnimatedPastelRainbowBorder<S: InsettableShape>(
        when isActive: Bool = true,
        in shape: S,
        lineWidth: CGFloat = 1
    ) -> some View {
        modifier(
            CPSLAnimatedPastelRainbowBorderModifier(
                isActive: isActive,
                shape: shape,
                lineWidth: lineWidth
            )
        )
    }

    func cpslAnimatedPastelRainbowBorder<S: InsettableShape>(
        when isHighlighted: Bool,
        duringActivity isActivityActive: Bool,
        in shape: S,
        lineWidth: CGFloat = 1
    ) -> some View {
        modifier(
            CPSLAnimatedPastelRainbowBorderModifier(
                isActive: isHighlighted || isActivityActive,
                shape: shape,
                lineWidth: lineWidth
            )
        )
        .animation(
            .easeInOut(duration: 0.18),
            value: isActivityActive && !isHighlighted
        )
    }

    func cpslAnimatedPastelRainbowForeground() -> some View {
        modifier(CPSLAnimatedPastelRainbowForegroundModifier())
    }
}
