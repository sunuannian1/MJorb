import Combine
import Foundation
import UserNotifications

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var installedApps: [AppRecord] = []
    @Published private(set) var accounts: [AppleAccountRecord] = []
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var isLoading = false
    @Published var pushAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published private(set) var expiringSoonCount = 0
    @Published private(set) var notificationConfig: NotificationConfigurationSummary = .empty

    private let appStore: any AppStore
    private let accountRepository: any AccountRepository
    private let notificationScheduler: ExpiryNotificationScheduler
    private let notificationPreferences: NotificationPreferences
    private let signingPreferenceStore: SigningPreferenceStore

    struct NotificationConfigurationSummary: Equatable {
        let isEnabled: Bool
        let hasAuthorizedPush: Bool

        static let empty = NotificationConfigurationSummary(
            isEnabled: false,
            hasAuthorizedPush: false
        )
    }

    init(
        appStore: any AppStore,
        accountRepository: any AccountRepository,
        notificationScheduler: ExpiryNotificationScheduler,
        notificationPreferences: NotificationPreferences,
        signingPreferenceStore: SigningPreferenceStore
    ) {
        self.appStore = appStore
        self.accountRepository = accountRepository
        self.notificationScheduler = notificationScheduler
        self.notificationPreferences = notificationPreferences
        self.signingPreferenceStore = signingPreferenceStore
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }

        await reloadData()
        await refreshPushAuthorizationStatus()
    }

    func reloadData() async {
        if let allApps = try? await appStore.fetchAll() {
            installedApps = allApps.filter { $0.belongsInInstalledList && $0.isSeal == false }
        }
        if let allAccounts = try? await accountRepository.fetchAll() {
            accounts = allAccounts
        }
        activeAccountID = signingPreferenceStore.activeAccountID()
        expiringSoonCount = calculateExpiringSoonCount()
        await updateNotificationConfig()
    }

    private func calculateExpiringSoonCount() -> Int {
        let calendar = Calendar.current
        let threshold = calendar.date(byAdding: .day, value: 3, to: Date()) ?? Date()
        return installedApps.filter { app in
            guard let expiry = app.expiryDate else { return false }
            return expiry <= threshold
        }.count
    }

    private func updateNotificationConfig() async {
        pushAuthorizationStatus = await notificationScheduler.authorizationStatus()
        notificationConfig = NotificationConfigurationSummary(
            isEnabled: notificationPreferences.isEnabled,
            hasAuthorizedPush: pushAuthorizationStatus == .authorized || pushAuthorizationStatus == .provisional
        )
    }

    func refreshPushAuthorizationStatus() async {
        pushAuthorizationStatus = await notificationScheduler.authorizationStatus()
    }

    var activeAccountEmail: String? {
        guard let id = activeAccountID else { return nil }
        return accounts.first(where: { $0.id == id })?.maskedEmail ?? accounts.first?.maskedEmail
    }

    var hasSignedApps: Bool {
        installedApps.isEmpty == false
    }

    var totalSignedCount: Int {
        installedApps.count
    }

    func navigateToSettings() {
        // 由 View 层处理导航
    }
}
