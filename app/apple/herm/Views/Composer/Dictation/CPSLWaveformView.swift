import SwiftUI

/// Scrolling level meter: the most recent samples appear on the right and drift
/// left, fading down to dots as they age. Drawn in a single `Canvas` — no
/// per-bar subviews to lay out — so it stays cheap under high-frequency updates.
/// Pure presentation: pass normalized levels (0...1, newest last) from any source.
struct CPSLWaveformView: View {
    var levels: [Float]
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 3
    var minHeight: CGFloat = 3
    var color: Color = CPSLTheme.text

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let step = barWidth + barSpacing
            let count = max(1, Int((size.width + barSpacing) / step))
            for index in 0..<count {
                let level = CGFloat(level(at: index, count: count))
                let barHeight = max(minHeight, level * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * step,
                    y: (size.height - barHeight) / 2,
                    width: barWidth,
                    height: barHeight
                )
                let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                context.fill(path, with: .color(color.opacity(level > 0.03 ? 0.9 : 0.28)))
            }
        }
    }

    private func level(at index: Int, count: Int) -> Float {
        let missing = count - levels.count
        let levelIndex = index - missing
        guard levelIndex >= 0, levelIndex < levels.count else {
            return 0
        }
        return levels[levelIndex]
    }
}
