import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum CPSLTheme {
    static let background = Color(red: 0.047, green: 0.055, blue: 0.094)
    static let surface = Color(red: 0.067, green: 0.082, blue: 0.125)
    static let card = Color(red: 0.086, green: 0.102, blue: 0.165)
    static let elevated = Color(red: 0.106, green: 0.125, blue: 0.204)
    static let controlPressed = Color(red: 0.16, green: 0.15, blue: 0.25)
    static let text = Color(red: 0.941, green: 0.933, blue: 0.914)
    static let secondaryText = Color(red: 0.604, green: 0.616, blue: 0.698)
    static let mutedText = Color(red: 0.345, green: 0.369, blue: 0.447)
    static let mauve = Color(red: 0.49, green: 0.42, blue: 0.78)
    static let command = Color(red: 0.076, green: 0.091, blue: 0.145)
    static let error = Color(red: 0.36, green: 0.16, blue: 0.20)

    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 20

    static let compactRadius: CGFloat = 10
    static let controlRadius: CGFloat = 12
    static let largeRadius: CGFloat = 18
    static let composerRadius = Self.largeRadius
    static let messageRadius = Self.largeRadius
    static let paneRadius = Self.largeRadius
    static let rowRadius = Self.compactRadius

    static let controlSize: CGFloat = 38
    static let contentHorizontalInset = Self.medium
    static let chromeHorizontalInset = Self.medium
    static let messageVerticalSpacing = Self.large
    static let framedMessageSideIndent: CGFloat = 44
    static let framedMessageMaxWidth: CGFloat = 720
    static let bodyLineSpacing: CGFloat = 2
    static let composerSpacing = Self.small
    static let composerPadding = Self.small
    static let promptVerticalInset = Self.small
    static let topChromeInset: CGFloat = 148
    static let bottomChromeInset: CGFloat = 132
    static let topBlendHeight: CGFloat = 100
    static let bottomBlendHeight: CGFloat = 200
    static let commandBlockMaxHeight: CGFloat = 320

    enum FontSize {
        static let title: CGFloat = 22
        static let body: CGFloat = 16
        static let monospaceBody: CGFloat = 15
        static let control: CGFloat = 14
        static let supporting: CGFloat = 13
        static let caption: CGFloat = 12
        static let emptyStateIcon: CGFloat = 56
        static let iconLarge: CGFloat = 18
        static let iconMedium: CGFloat = 15
        static let iconSmall: CGFloat = 13
    }

    static func userFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: size, weight: weight, design: design)
    }

    static func iconFont(size: CGFloat, weight: Font.Weight = .medium) -> Font {
        userFont(size: size, weight: weight)
    }

    static let headerFont = userFont(size: FontSize.title, weight: .semibold)
    static let bodyFont = userFont(size: FontSize.body)
    static let monospacedBodyFont = userFont(size: FontSize.monospaceBody, design: .monospaced)
    static let controlFont = userFont(size: FontSize.control, weight: .medium)
    static let supportingFont = userFont(size: FontSize.supporting)
    static let supportingMediumFont = userFont(size: FontSize.supporting, weight: .medium)
    static let captionFont = userFont(size: FontSize.caption)
    static let captionMediumFont = userFont(size: FontSize.caption, weight: .medium)
    static let rowTitleFont = supportingFont
    static let emptyStateIconFont = iconFont(size: FontSize.emptyStateIcon, weight: .light)
    static let iconLargeFont = iconFont(size: FontSize.iconLarge)
    static let iconMediumFont = iconFont(size: FontSize.iconMedium)
    static let iconSmallFont = iconFont(size: FontSize.iconSmall, weight: .semibold)

#if canImport(UIKit)
    static let bodyUIFont = UIFont.systemFont(ofSize: FontSize.body, weight: .regular)
#endif
}
