import SwiftUI

struct RootTabView: View {
    @Binding var selection: AppSection
    let appsViewModel: AppsViewModel
    let settingsViewModel: SettingsViewModel
    let homeViewModel: HomeViewModel
    let historyViewModel: HistoryViewModel

    @State private var previousSelection: AppSection = .home

    init(
        selection: Binding<AppSection>,
        appsViewModel: AppsViewModel,
        settingsViewModel: SettingsViewModel,
        homeViewModel: HomeViewModel,
        historyViewModel: HistoryViewModel
    ) {
        self._selection = selection
        self.appsViewModel = appsViewModel
        self.settingsViewModel = settingsViewModel
        self.homeViewModel = homeViewModel
        self.historyViewModel = historyViewModel
    }

    var body: some View {
        TabView(selection: tabSelection) {
            HomeRootView(viewModel: homeViewModel, settingsViewModel: settingsViewModel)
                .tabItem {
                    Label(AppSection.home.title, systemImage: AppSection.home.systemImage)
                }
                .tag(AppSection.home)

            AppsRootView(viewModel: appsViewModel, settingsViewModel: settingsViewModel)
                .tabItem {
                    Label(AppSection.apps.title, systemImage: AppSection.apps.systemImage)
                }
                .tag(AppSection.apps)

            HistoryRootView(viewModel: historyViewModel)
                .tabItem {
                    Label(AppSection.history.title, systemImage: AppSection.history.systemImage)
                }
                .tag(AppSection.history)

            SettingsRootView(
                viewModel: settingsViewModel,
                relatedApps: appsViewModel.installedApps,
                certificateExportHandler: CertificateExportHandler(
                    keychain: KeychainVault(),
                    signingPreferenceStore: SigningPreferenceStore()
                )
            )
                .tabItem {
                    Label(AppSection.settings.title, systemImage: AppSection.settings.systemImage)
                }
                .tag(AppSection.settings)
        }
        .tint(Color.sealAccent)
    }

    private var tabSelection: Binding<AppSection> {
        Binding(
            get: { selection },
            set: { newValue in
                if newValue == previousSelection {
                    handleReselection(newValue)
                }
                previousSelection = newValue
                selection = newValue
            }
        )
    }

    private func handleReselection(_ section: AppSection) {
        switch section {
        case .home:
            NotificationCenter.default.post(name: .homeTabReselected, object: nil)
        case .apps:
            NotificationCenter.default.post(name: .appsTabReselected, object: nil)
        case .history:
            NotificationCenter.default.post(name: .historyTabReselected, object: nil)
        case .settings:
            NotificationCenter.default.post(name: .settingsTabReselected, object: nil)
        }
    }
}

extension Notification.Name {
    static let homeTabReselected = Notification.Name("seal.homeTabReselected")
    static let appsTabReselected = Notification.Name("seal.appsTabReselected")
    static let historyTabReselected = Notification.Name("seal.historyTabReselected")
    static let settingsTabReselected = Notification.Name("seal.settingsTabReselected")
}
