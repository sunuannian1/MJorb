import SwiftUI

@main
@MainActor
struct SealApp: App {
    private let container: AppContainer
    private let notificationPresenter: SealNotificationPresenter

    init() {
        let notificationPresenter = SealNotificationPresenter()
        notificationPresenter.install()
        self.notificationPresenter = notificationPresenter
        container = AppContainer.live()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView(
                appsViewModel: container.appsViewModel,
                settingsViewModel: container.settingsViewModel,
                certificateExportHandler: container.certificateExportHandler
            )
        }
    }
}
