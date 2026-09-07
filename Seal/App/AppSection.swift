import Foundation

enum AppSection: String, CaseIterable, Hashable {
    case home
    case apps
    case history
    case settings

    var title: String {
        switch self {
        case .home: "首页"
        case .apps: "应用"
        case .history: "历史"
        case .settings: "我的"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .apps: "square.grid.2x2"
        case .history: "clock.arrow.circlepath"
        case .settings: "person.crop.circle"
        }
    }

    var selectedSystemImage: String {
        switch self {
        case .home: "house.fill"
        case .apps: "square.grid.2x2.fill"
        case .history: "clock.arrow.circlepath"
        case .settings: "person.crop.circle.fill"
        }
    }
}
