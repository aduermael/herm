import SwiftUI

enum CPSLTagPalette {
    static let defaultKey = "mauve"
    static let keys = [
        "mauve", "blue", "cyan", "teal", "green",
        "lime", "yellow", "orange", "red", "pink",
        "magenta", "gray",
    ]

    static func color(for key: String) -> Color {
        switch key {
        case "mauve": return CPSLTheme.mauve
        case "blue": return CPSLTheme.IconPalette.folder
        case "cyan": return Color(red: 0.28, green: 0.72, blue: 0.82)
        case "teal": return Color(red: 0.20, green: 0.66, blue: 0.60)
        case "green": return CPSLTheme.success
        case "lime": return Color(red: 0.56, green: 0.72, blue: 0.30)
        case "yellow": return Color(red: 0.87, green: 0.71, blue: 0.29)
        case "orange": return Color(red: 0.89, green: 0.54, blue: 0.28)
        case "red": return CPSLTheme.danger
        case "pink": return Color(red: 0.87, green: 0.44, blue: 0.63)
        case "magenta": return Color(red: 0.72, green: 0.38, blue: 0.74)
        case "gray": return CPSLTheme.secondaryText
        default: return CPSLTheme.mauve
        }
    }
}
