import SwiftUI

extension View {
    func cpslMeasureHeight(_ height: Binding<CGFloat>) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height.wrappedValue = $0 }
    }
}

struct CPSLFlowLayout: Layout {
    var spacing: CGFloat = CPSLTheme.small
    var lineSpacing: CGFloat = CPSLTheme.small

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = maxWidth.isFinite ? maxWidth : (rows.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projected = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty, projected > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append(index)
        }
        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

struct CPSLSelfSizingSheet<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    @State private var headerHeight: CGFloat = 70
    @State private var contentHeight: CGFloat = 120
    @State private var bottomInset: CGFloat = 34

    private var sheetHeight: CGFloat { headerHeight + contentHeight + bottomInset }

    var body: some View {
        VStack(spacing: 0) {
            CPSLSheetHeader(title: title) { trailing }
                .cpslMeasureHeight($headerHeight)

            ScrollView {
                content
                    .padding(.horizontal, CPSLTheme.large)
                    .padding(.bottom, CPSLTheme.large)
                    .cpslMeasureHeight($contentHeight)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CPSLTheme.background.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomInset = $0 }
        .presentationDetents([.height(sheetHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(CPSLTheme.background)
        .preferredColorScheme(.dark)
    }
}

struct CPSLSheetHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            Text(title)
                .font(CPSLTheme.headerFont)
                .foregroundStyle(CPSLTheme.text)
            Spacer(minLength: CPSLTheme.medium)
            trailing
        }
        .padding(.horizontal, CPSLTheme.large)
        .padding(.top, CPSLTheme.large)
        .padding(.bottom, CPSLTheme.medium)
    }
}

struct CPSLSheetChromeButton: View {
    let title: String
    var isProminent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(CPSLTheme.controlFont)
                .foregroundStyle(isProminent ? CPSLTheme.text : CPSLTheme.secondaryText)
                .padding(.horizontal, CPSLTheme.medium)
                .frame(height: CPSLTheme.controlSize)
                .background {
                    if isProminent {
                        CPSLGlassSurface(
                            shape: Capsule(),
                            tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.34),
                            strokeOpacity: 0.045
                        )
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct CPSLTagChip: View {
    let name: String
    let colorKey: String
    let isSelected: Bool

    var body: some View {
        let color = CPSLTagPalette.color(for: colorKey)
        HStack(spacing: CPSLTheme.small) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: CPSLTheme.FontSize.caption, weight: .bold))
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            Text(name)
                .font(CPSLTheme.supportingMediumFont)
                .lineLimit(1)
        }
        .foregroundStyle(CPSLTheme.text)
        .padding(.horizontal, CPSLTheme.medium)
        .frame(height: 34)
        .background(Capsule().fill(color.opacity(isSelected ? 0.30 : 0.12)))
        .overlay(Capsule().strokeBorder(color.opacity(isSelected ? 0.9 : 0.32), lineWidth: isSelected ? 1.5 : 1))
        .contentShape(Capsule())
    }
}

struct CPSLTagCreateRow: View {
    @Binding var name: String
    @Binding var colorKey: String
    let onCreate: () -> Void

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            Button(action: randomizeColor) {
                Circle()
                    .fill(CPSLTagPalette.color(for: colorKey))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(CPSLTheme.text.opacity(0.15), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Random color")
            TextField("New tag", text: $name)
                .textFieldStyle(.plain)
                .font(CPSLTheme.supportingFont)
                .foregroundStyle(CPSLTheme.text)
                .submitLabel(.done)
                .onSubmit(create)
            Button(action: create) {
                Text("Create")
                    .font(CPSLTheme.controlFont)
                    .foregroundStyle(canCreate ? CPSLTheme.text : CPSLTheme.mutedText)
                    .padding(.horizontal, CPSLTheme.medium)
                    .frame(height: 30)
                    .background(Capsule().fill(CPSLTheme.mauve.opacity(canCreate ? 1 : 0.15)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canCreate)
        }
        .padding(.leading, CPSLTheme.medium)
        .padding(.trailing, CPSLTheme.small / 2)
        .frame(height: CPSLTheme.controlSize)
        .cpslGlassBackground(
            in: Capsule(),
            tint: CPSLGlassTuning.tint(CPSLTheme.elevated, opacity: 0.5),
            strokeOpacity: 0.06
        )
    }

    private func randomizeColor() {
        colorKey = CPSLTagPalette.keys.filter { $0 != colorKey }.randomElement() ?? colorKey
    }

    private func create() {
        guard canCreate else { return }
        onCreate()
    }
}
