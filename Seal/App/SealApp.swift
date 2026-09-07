import SwiftUI

@main
@MainActor
struct SealApp: App {
    private let container: AppContainer
    private let notificationPresenter: SealNotificationPresenter
    @State private var selectedTab: AppSection = .home

    init() {
        let notificationPresenter = SealNotificationPresenter()
        notificationPresenter.install()
        self.notificationPresenter = notificationPresenter
        container = AppContainer.live()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(
                selection: $selectedTab,
                appsViewModel: container.appsViewModel,
                settingsViewModel: container.settingsViewModel,
                homeViewModel: container.homeViewModel,
                historyViewModel: container.historyViewModel
            )
        }
    }
}
