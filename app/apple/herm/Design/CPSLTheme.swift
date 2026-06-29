import SwiftUI

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
    static let command = Color(red: 0.16, green: 0.24, blue: 0.22)
    static let error = Color(red: 0.36, green: 0.16, blue: 0.20)

    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let large: CGFloat = 20

    static let composerRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8
    static let rowRadius: CGFloat = 6

    static let controlSize: CGFloat = 38
    static let contentHorizontalInset = Self.large + Self.small
    static let chromeHorizontalInset = Self.large
    static let topChromeInset: CGFloat = 148
    static let bottomChromeInset: CGFloat = 132
    static let topBlendHeight: CGFloat = 100
    static let bottomBlendHeight: CGFloat = 200
    static let commandBlockMaxHeight: CGFloat = 320

    static let normalTextSize: CGFloat = 16
    static let largeTextSize: CGFloat = 22

    static let headerFont = Font.system(size: Self.largeTextSize, weight: .semibold)
    static let bodyFont = Font.system(size: Self.normalTextSize, weight: .regular)
    static let monospacedBodyFont = Font.system(size: Self.normalTextSize, weight: .regular, design: .monospaced)
    static let controlFont = Font.system(size: 14, weight: .medium)
    static let rowTitleFont = Font.system(size: 13, weight: .regular)
}
