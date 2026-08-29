import SwiftUI
import UIKit

enum SealAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "浅色"
        case .dark: "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum SealAccentTheme: String, CaseIterable, Identifiable {
    case system
    case green
    case blue
    case purple
    case amber
    case pink

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "默认"
        case .green: "绿色"
        case .blue: "青色"
        case .purple: "紫色"
        case .amber: "琥珀色"
        case .pink: "玫红色"
        }
    }

    var uiColor: UIColor {
        switch self {
        case .system: .systemBlue
        case .green: .systemGreen
        case .blue: .systemCyan
        case .purple: .systemPurple
        case .amber: .systemOrange
        case .pink: .systemPink
        }
    }

    var color: Color { Color(uiColor: uiColor) }

    static var current: SealAccentTheme {
        SealAccentTheme(rawValue: UserDefaults.standard.string(forKey: "appearance.accent") ?? "") ?? .system
    }
}
