import SwiftUI
import UIKit

public enum ChatUIDesign {
    public enum Color {
        public static let offBlack = UIColor(hex: "#111111")
        public static let pureWhite = UIColor(hex: "#ffffff")
        public static let warmCream = UIColor(hex: "#faf9f6")
        public static let brandOrange = UIColor(hex: "#ff5600")
        public static let reportOrange = UIColor(hex: "#fe4c02")

        public static let black80 = UIColor(hex: "#313130")
        public static let black60 = UIColor(hex: "#626260")
        public static let black50 = UIColor(hex: "#7b7b78")
        public static let contentTertiary = UIColor(hex: "#9c9fa5")
        public static let oatBorder = UIColor(hex: "#dedbd6")
        public static let warmSand = UIColor(hex: "#d3cec6")
    }

    public enum Radius {
        public static let button: CGFloat = 4.0
        public static let navItem: CGFloat = 6.0
        public static let card: CGFloat = 8.0
    }

    public enum Typography {
        public static let agentTitle = UIFont.systemFont(ofSize: 16, weight: .regular)
        public static let agentSubtitle = UIFont.systemFont(ofSize: 12, weight: .regular)
    }
}

extension UIColor {
    convenience init(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let red = CGFloat((rgb & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgb & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgb & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue, alpha: 1.0)
    }
}
