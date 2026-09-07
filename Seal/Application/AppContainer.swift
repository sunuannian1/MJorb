import Foundation

@MainActor
struct AppContainer {
    let appsViewModel: AppsViewModel
    let settingsViewModel: SettingsViewModel
    let homeViewModel: HomeViewModel
    let historyViewModel: HistoryViewModel
    let certificateExportHandler: CertificateExportHandler

    static func live(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> AppContainer {
        if let testModel = AppsViewModel.uiTestModel(arguments: arguments) {
            return AppContainer(
                appsViewModel: testModel,
                settingsViewModel: .preview(),
                homeViewModel: HomeViewModel(
                    appStore: try! CoreDataAppStore(storeURL: URL(fileURLWithPath: "/dev/null")),
                    accountRepository: ProtectedAccountRepository(
                        fileURL: URL(fileURLWithPath: "/dev/null")
                    ),
                    notificationScheduler: ExpiryNotificationScheduler(),
                    notificationPreferences: NotificationPreferences(),
                    signingPreferenceStore: SigningPreferenceStore()
                ),
                historyViewModel: HistoryViewModel(
                    signingHistoryStore: SigningHistoryStore(
                        fileURL: URL(fileURLWithPath: "/dev/null")
                    ),
                    appStore: try! CoreDataAppStore(storeURL: URL(fileURLWithPath: "/dev/null"))
                ),
                certificateExportHandler: CertificateExportHandler(
                    keychain: KeychainVault(),
                    signingPreferenceStore: SigningPreferenceStore()
                )
            )
        }

        do {
            let fileManager = FileManager.default
            guard let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw AppStoreError.invalidConfiguration
            }
            let sealDirectory = applicationSupport.appending(
                path: AppConfiguration.Paths.applicationSupportSubdirectory,
                directoryHint: .isDirectory
            )
            try fileManager.createDirectory(
                at: sealDirectory,
                withIntermediateDirectories: true
            )
            try CompleteFileProtector().protect(sealDirectory)

            let appStore = try Self.makeAppStore(in: sealDirectory)
            let fileStore = try AppFileStore.live()
            let accountRepository = ProtectedAccountRepository(
                fileURL: sealDirectory.appending(path: AppConfiguration.Paths.accountsFile)
            )
            let keychain = KeychainVault()
            let signingPreferenceStore = SigningPreferenceStore()
            let certificateExportHandler = CertificateExportHandler(
                keychain: keychain,
                signingPreferenceStore: signingPreferenceStore
            )
            let pairingStore = PairingStore(
                fileURL: sealDirectory.appending(path: AppConfiguration.Paths.pairingFile)
            )
            let anisetteProvider = AnisetteV3Client()
            let installChannel = MinimuxerInstallChannel(
                pairingStore: pairingStore,
                logDirectory: sealDirectory.appending(
                    path: AppConfiguration.Paths.minimuxerLogsSubdirectory,
                    directoryHint: .isDirectory
                )
            )
            let operationCoordinator = OperationCoordinator()
            let signingVerificationBroker = VerificationCodeBroker()
            let workflow = ImportWorkflow(
                parser: IPAParserService(),
                fileStore: fileStore,
                appStore: appStore
            )
            let signingCoordinator = SigningCoordinator(
                appStore: appStore,
                accountRepository: accountRepository,
                keychain: keychain,
                fileStore: fileStore,
                installChannel: installChannel,
                portal: ApplePortalSigningService(
                    anisetteProvider: anisetteProvider,
                    verificationCodeProvider: { [signingVerificationBroker] in
                        await signingVerificationBroker.request()
                    }
                )
            )
            let refreshQueueStore = RefreshQueueStore(
                fileURL: sealDirectory.appending(path: AppConfiguration.Paths.refreshQueueFile)
            )
            let logStore = SealLogStore(
                fileURL: sealDirectory.appending(path: AppConfiguration.Paths.sealLogFile)
            )
            let signingHistoryStore = SigningHistoryStore(
                fileURL: sealDirectory.appending(path: AppConfiguration.Paths.signingHistoryFile)
            )
            let notificationScheduler = ExpiryNotificationScheduler()
            let notificationPreferences = NotificationPreferences()
            let renewalCoordinator = RenewalCoordinator(
                appStore: appStore,
                signingCoordinator: signingCoordinator,
                queueStore: refreshQueueStore,
                defaultAccountIDProvider: {
                    let activeID = await signingPreferenceStore.activeAccountID()
                    if let activeID,
                       let accounts = try? await accountRepository.fetchAll(),
                       accounts.contains(where: { $0.id == activeID && AccountAvailabilityPolicy.isSelectable($0) }) {
                        return activeID
                    }
                    if let accounts = try? await accountRepository.fetchAll(),
                       let firstSelectable = accounts.first(where: { AccountAvailabilityPolicy.isSelectable($0) }) {
                        return firstSelectable.id
                    }
                    return nil
                },
                accountsProvider: {
                    (try? await accountRepository.fetchAll()) ?? []
                }
            )
            let appRecordRecovery = AppRecordRecovery(
                appStore: appStore,
                fileStore: fileStore
            )
            let selfAppRegistrar = SelfAppMetadata.current().map {
                SelfAppRegistrar(
                    metadata: $0,
                    appStore: appStore,
                    accountRepository: accountRepository,
                    fileStore: fileStore
                )
            }

            return AppContainer(
                appsViewModel: AppsViewModel(
                    workflow: workflow,
                    appStore: appStore,
                    fileStore: fileStore,
                    accountRepository: accountRepository,
                    keychain: keychain,
                    signingCoordinator: signingCoordinator,
                    installChannel: installChannel,
                    renewalCoordinator: renewalCoordinator,
                    appRecordRecovery: appRecordRecovery,
                    selfAppRegistrar: selfAppRegistrar,
                    logStore: logStore,
                    signingHistoryStore: signingHistoryStore,
                    notificationScheduler: notificationScheduler,
                    notificationPreferences: notificationPreferences,
                    signingPreferenceStore: signingPreferenceStore,
                    operationCoordinator: operationCoordinator,
                    signingVerificationBroker: signingVerificationBroker,
                ),
                settingsViewModel: SettingsViewModel(
                    accountRepository: accountRepository,
                    keychain: keychain,
                    accountClient: AppleAccountClient(
                        anisetteProvider: anisetteProvider
                    ),
                    pairingStore: pairingStore,
                    installChannel: installChannel,
                    appStore: appStore,
                    fileStore: fileStore,
                    logStore: logStore,
                    signingHistoryStore: signingHistoryStore,
                    notificationScheduler: notificationScheduler,
                    notificationPreferences: notificationPreferences,
                    anisetteEnvironment: anisetteProvider,
                    signingPreferenceStore: signingPreferenceStore,
                    operationCoordinator: operationCoordinator
                ),
                homeViewModel: HomeViewModel(
                    appStore: appStore,
                    accountRepository: accountRepository,
                    notificationScheduler: notificationScheduler,
                    notificationPreferences: notificationPreferences,
                    signingPreferenceStore: signingPreferenceStore
                ),
                historyViewModel: HistoryViewModel(
                    signingHistoryStore: signingHistoryStore,
                    appStore: appStore
                ),
                certificateExportHandler: certificateExportHandler
            )
        } catch {
            let failure = ImportFailure(
                title: "无法打开数据",
                reason: "本地存储初始化失败：\(Self.readableStartupError(error))",
                recovery: "知道了",
                code: "SEAL-APP-001"
            )

            let fallbackStore: (any AppStore)?
            let tempDir = FileManager.default.temporaryDirectory.appending(path: "SealFallback-\(UUID().uuidString)")
            if let store = try? Self.makeAppStore(in: tempDir) {
                fallbackStore = store
            } else {
                fallbackStore = try? CoreDataAppStore(inMemory: true)
            }

            return AppContainer(
                appsViewModel: AppsViewModel(startupFailure: failure),
                settingsViewModel: SettingsViewModel(startupFailure: failure),
                homeViewModel: HomeViewModel(
                    appStore: fallbackStore ?? FallbackAppStore(),
                    accountRepository: ProtectedAccountRepository(
                        fileURL: FileManager.default.temporaryDirectory.appending(path: "seal-accounts-\(UUID().uuidString).json")
                    ),
                    notificationScheduler: ExpiryNotificationScheduler(),
                    notificationPreferences: NotificationPreferences(),
                    signingPreferenceStore: SigningPreferenceStore()
                ),
                historyViewModel: HistoryViewModel(
                    signingHistoryStore: SigningHistoryStore(
                        fileURL: FileManager.default.temporaryDirectory.appending(path: "seal-history-\(UUID().uuidString).json")
                    ),
                    appStore: fallbackStore ?? FallbackAppStore()
                ),
                certificateExportHandler: CertificateExportHandler(
                    keychain: KeychainVault(),
                    signingPreferenceStore: SigningPreferenceStore()
                )
            )
        }
    }
    private static func makeAppStore(in sealDirectory: URL) throws -> CoreDataAppStore {
        let storeURL = sealDirectory.appending(path: "Seal.sqlite")
        do {
            return try CoreDataAppStore(storeURL: storeURL)
        } catch {
            try backupUnreadableSQLiteStore(
                at: storeURL,
                in: sealDirectory,
                originalError: error
            )
            return try CoreDataAppStore(storeURL: storeURL)
        }
    }

    private static func backupUnreadableSQLiteStore(
        at storeURL: URL,
        in sealDirectory: URL,
        originalError: Error
    ) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: storeURL.path) else {
            throw originalError
        }

        let recoveryDirectory = sealDirectory.appending(
            path: "StorageRecovery-\(compactTimestamp())",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )

        var didMoveAnyFile = false
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: storeURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let destination = recoveryDirectory.appending(path: source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: source, to: destination)
            didMoveAnyFile = true
        }

        guard didMoveAnyFile else { throw originalError }
    }

    private static func compactTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func readableStartupError(_ error: Error) -> String {
        if let failure = error as? ImportFailure {
            return failure.userMessage
        }
        return (error as NSError).localizedDescription
    }
}
