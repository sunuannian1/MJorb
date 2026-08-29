import Foundation
import ZIPFoundation

actor SelfAppRegistrar {
    private let metadata: SelfAppMetadata
    private let appStore: any AppStore
    private let accountRepository: any AccountRepository
    private let fileStore: AppFileStore

    // 固定 ID，确保 Seal 记录和文件夹路径始终一致，不会出现多个文件夹
    private let fixedSealID = UUID(uuidString: "SEAL0000-0000-0000-0000-000000000001")!

    // 防重入：确保同时只有一个注册流程在执行
    private var isRegistering = false

    init(
        metadata: SelfAppMetadata,
        appStore: any AppStore,
        accountRepository: any AccountRepository,
        fileStore: AppFileStore
    ) {
        self.metadata = metadata
        self.appStore = appStore
        self.accountRepository = accountRepository
        self.fileStore = fileStore
    }

    func ensureRegistered() async throws {
        guard isRegistering == false else { return }
        isRegistering = true
        defer { isRegistering = false }

        let records = try await appStore.fetchAll()
        let accounts = try await accountRepository.fetchAll()
        let existing = SelfAppRecordSelection.preferredExistingSealRecord(
            in: records,
            currentBundleIdentifier: metadata.bundleIdentifier
        )

        // 版本一致且文件存在 → 直接跳过，只清理重复记录
        if let existing,
           existing.version == metadata.version,
           existing.buildNumber == metadata.buildNumber,
           try await fileStore.exists(relativePath: existing.ipaRelativePath) {
            try await cleanupDuplicateSealRecords(records: records, keepID: existing.id)
            return
        }

        // 版本变更或文件缺失 → 原子更新
        let id = existing?.id ?? fixedSealID
        try await atomicallyUpdateSealRecord(id: id, existing: existing, accounts: accounts)

        // 清理历史残留的重复记录
        try await cleanupDuplicateSealRecords(records: records, keepID: id)
    }

    // MARK: - 原子更新：先暂存，再提交覆盖，失败回滚

    private func atomicallyUpdateSealRecord(
        id: UUID,
        existing: AppRecord?,
        accounts: [AppleAccountRecord]
    ) async throws {
        // 1. 打包新 IPA 到临时工作区（不碰旧文件）
        let workspace = try await fileStore.signingWorkspace(appID: UUID())
        defer { try? FileManager.default.removeItem(at: workspace) }

        let payload = workspace.appending(path: "Payload", directoryHint: .isDirectory)
        let appURL = payload.appending(
            path: "\(metadata.name).app",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: payload,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: metadata.bundleURL, to: appURL)
        let ipaURL = workspace.appending(path: "Seal.ipa")
        try FileManager.default.zipItem(
            at: payload,
            to: ipaURL,
            shouldKeepParent: true,
            compressionMethod: .deflate
        )

        // 2. 暂存新文件
        let staged = try await fileStore.stage(sourceURL: ipaURL)

        do {
            // 3. 图标：优先用新提取的，失败则复用旧图标
            var iconData = metadata.iconData
            if iconData == nil, let oldIconPath = existing?.iconRelativePath {
                iconData = try? await fileStore.read(relativePath: oldIconPath)
            }

            // 4. 提交新文件（用同一个 ID，覆盖旧文件，不是先删后建）
            let files = try await fileStore.commit(
                staged: staged,
                appID: id,
                iconData: iconData
            )

            // 5. 取消暂存
            do {
                try await fileStore.cancel(staged)
            } catch {
                throw ImportFailure(
                    title: "Seal 临时文件清理失败",
                    reason: "Seal 自身注册已写入文件，但暂存文件未能清理。",
                    recovery: "重新打开 Seal 后在存储维护中重试",
                    code: "SEAL-STORAGE-SELF-001"
                )
            }

            // 6. 计算文件大小
            let attributes = try FileManager.default.attributesOfItem(atPath: ipaURL.path)
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0

            // 7. 解析账户绑定
            let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: metadata.signingTeamIdentifier,
                accounts: accounts,
                fallbackAccountID: existing?.accountID
            )

            // 8. 更新记录（复用 ID，不删除重建）
            let record = AppRecord(
                id: id,
                originalBundleIdentifier: SelfAppBundleIdentity.originalBundleIdentifier(
                    currentBundleIdentifier: metadata.bundleIdentifier,
                    declaredOriginalBundleIdentifier: metadata.originalBundleIdentifier,
                    existingOriginalBundleIdentifier: existing?.originalBundleIdentifier
                ),
                mappedBundleIdentifier: metadata.bundleIdentifier,
                name: metadata.name,
                version: metadata.version,
                buildNumber: metadata.buildNumber,
                size: size,
                iconRelativePath: files.iconRelativePath ?? existing?.iconRelativePath,
                state: .installed,
                expiryDate: metadata.expirationDate,
                accountID: resolvedAccountID,
                signingTeamID: metadata.signingTeamIdentifier ?? existing?.signingTeamID,
                certificateSerialNumber: existing?.certificateSerialNumber,
                provisioningProfileExpirationDate: metadata.expirationDate,
                ipaRelativePath: files.ipaRelativePath,
                signedIPARelativePath: nil,
                preferredBundleIdentifier: metadata.bundleIdentifier,
                isSeal: true,
                isPinned: true,
                importedAt: existing?.importedAt ?? Date(),
                extensions: existing?.extensions ?? []
            )
            try await appStore.save(record)

        } catch {
            // 9. 失败回滚：取消暂存，旧文件不受影响
            try? await fileStore.cancel(staged)
            throw error
        }
    }

    // MARK: - 清理重复的 Seal 记录

    private func cleanupDuplicateSealRecords(
        records: [AppRecord],
        keepID: UUID
    ) async throws {
        for record in records where record.isSeal && record.id != keepID {
            // 先删除文件，再删除数据库记录，避免产生孤儿文件
            try? await fileStore.removeApp(appID: record.id)
            try? await appStore.delete(id: record.id)
        }
    }
}
