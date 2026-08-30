import Foundation

struct BatchRefreshResult: Equatable, Sendable {
    let total: Int
    let succeeded: Int
    let failed: Int
    let remaining: Int
}

enum BatchRefreshEvent: Sendable {
    case prepared(apps: [AppRecord])
    case started(total: Int)
    case appProgress(index: Int, total: Int, app: AppRecord, stage: SigningStage)
    case appSucceeded(index: Int, total: Int, app: AppRecord)
    case appFailed(index: Int, total: Int, app: AppRecord, failure: ImportFailure)
}

actor RenewalCoordinator {
    private let appStore: any AppStore
    private let signingCoordinator: SigningCoordinator
    private let queueStore: RefreshQueueStore
    private let planner: RefreshPlanner
    private let defaultAccountIDProvider: (@Sendable () async -> UUID?)?

    init(
        appStore: any AppStore,
        signingCoordinator: SigningCoordinator,
        queueStore: RefreshQueueStore,
        planner: RefreshPlanner = RefreshPlanner(),
        defaultAccountIDProvider: (@Sendable () async -> UUID?)? = nil
    ) {
        self.appStore = appStore
        self.signingCoordinator = signingCoordinator
        self.queueStore = queueStore
        self.planner = planner
        self.defaultAccountIDProvider = defaultAccountIDProvider
    }

    func refreshAll(
        progress: @Sendable (BatchRefreshEvent) async -> Void
    ) async throws -> BatchRefreshResult {
        let apps = try await appStore.fetchAll()
        let fallbackAccountID: UUID?
        if let provider = defaultAccountIDProvider {
            fallbackAccountID = await provider()
        } else {
            fallbackAccountID = nil
        }
        let queue = planner.makeQueue(apps: apps, fallbackAccountID: fallbackAccountID)
        let queuedApps = queue.compactMap { item in apps.first(where: { $0.id == item.appID }) }
        await progress(.prepared(apps: queuedApps))
        try await queueStore.replace(with: queue)
        return try await process(queue: queue, progress: progress)
    }


    private func process(
        queue: [RefreshQueueItem],
        progress: @Sendable (BatchRefreshEvent) async -> Void
    ) async throws -> BatchRefreshResult {
        await progress(.started(total: queue.count))
        var succeeded = 0
        var failed = 0

        for (offset, item) in queue.enumerated() {
            do {
                try Task.checkCancellation()
                let apps = try await appStore.fetchAll()
                guard let app = apps.first(where: { $0.id == item.appID }) else {
                    throw ImportFailure(
                        title: "无法续签应用",
            reason: "续签时未找到该应用的本地记录。",
            recovery: "重新导入 IPA 并签名安装",
                        code: "SEAL-RENEW-404"
                    )
                }
                try await queueStore.markRunning(appID: item.appID)
                let queueStore = self.queueStore
                let updated = try await signingCoordinator.signAndInstall(
                    appID: item.appID,
                    accountID: item.accountID,
                    requestedBundleIdentifier: app.mappedBundleIdentifier ?? app.preferredBundleIdentifier,
                    selectedCertificateSerialNumber: nil,
                    progress: { stage in
                        if app.isSeal, stage == .installing {
                            try? await queueStore.markCompleted(appID: item.appID)
                        }
                        await progress(
                            .appProgress(
                                index: offset + 1,
                                total: queue.count,
                                app: app,
                                stage: stage
                            )
                        )
                    }
                )
                try await queueStore.markCompleted(appID: item.appID)
                succeeded += 1
                await progress(
                    .appSucceeded(
                        index: offset + 1,
                        total: queue.count,
                        app: updated
                    )
                )
            } catch is CancellationError {
                do {
                    try await queueStore.markPending(appID: item.appID)
                } catch {
                    throw Self.queuePersistenceFailure(
                        reason: "取消续签后，队列状态未能保存。",
                        code: "SEAL-RENEW-QUEUE-002"
                    )
                }
                throw CancellationError()
            } catch let failure as ImportFailure {
                do {
                    try await queueStore.markFailed(
                        appID: item.appID,
                        errorCode: failure.code
                    )
                } catch {
                    throw Self.queuePersistenceFailure(
                        reason: "续签失败状态未能写入队列。",
                        code: "SEAL-RENEW-QUEUE-003"
                    )
                }
                failed += 1
                let currentApps: [AppRecord]
                do {
                    currentApps = try await appStore.fetchAll()
                } catch {
                    throw ImportFailure(
                        title: "续签状态读取失败",
                        reason: "续签失败后无法重新读取本地应用状态。",
                        recovery: "重新打开 Seal 后重试",
                        code: "SEAL-RENEW-STORE-001"
                    )
                }
                if let app = currentApps.first(where: { $0.id == item.appID }) {
                    await progress(
                        .appFailed(
                            index: offset + 1,
                            total: queue.count,
                            app: app,
                            failure: failure
                        )
                    )
                }
            } catch {
                let failure = ImportFailure(
                    title: "续签失败",
            reason: "续签过程中签名或安装步骤失败，具体原因请查看详情。",
            recovery: "根据错误提示处理后重试；如为账号问题请在「我的」中检查 Apple ID",
                    code: "SEAL-RENEW-500"
                )
                do {
                    try await queueStore.markFailed(
                        appID: item.appID,
                        errorCode: failure.code
                    )
                } catch {
                    throw Self.queuePersistenceFailure(
                        reason: "续签失败状态未能写入队列。",
                        code: "SEAL-RENEW-QUEUE-004"
                    )
                }
                failed += 1
                let currentApps: [AppRecord]
                do {
                    currentApps = try await appStore.fetchAll()
                } catch {
                    throw ImportFailure(
                        title: "续签状态读取失败",
                        reason: "续签失败后无法重新读取本地应用状态。",
                        recovery: "重新打开 Seal 后重试",
                        code: "SEAL-RENEW-STORE-002"
                    )
                }
                if let app = currentApps.first(where: { $0.id == item.appID }) {
                    await progress(
                        .appFailed(
                            index: offset + 1,
                            total: queue.count,
                            app: app,
                            failure: failure
                        )
                    )
                }
            }
        }

        do {
            try await queueStore.removeCompleted()
        } catch {
            throw Self.queuePersistenceFailure(
                reason: "已完成的续签任务未能从队列中清理。",
                code: "SEAL-RENEW-QUEUE-005"
            )
        }
        return BatchRefreshResult(
            total: queue.count,
            succeeded: succeeded,
            failed: failed,
            remaining: max(0, queue.count - succeeded)
        )
    }

    private static func queuePersistenceFailure(reason: String, code: String) -> ImportFailure {
        ImportFailure(
            title: "续签队列异常",
            reason: reason,
            recovery: "检查本机存储后重试",
            code: code
        )
    }

}
