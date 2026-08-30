import re

fpath = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Features\Apps\AppsViewModel.swift"
with open(fpath, 'r', encoding='utf-8') as f:
    content = f.read()

# 找到 load 方法中从 "if let selfAppRegistrar" 到 "restorePendingBatchResultIfNeeded()" 的部分
old_block_start = "            if let selfAppRegistrar {"
old_block_end = "            restorePendingBatchResultIfNeeded()"

start_idx = content.find(old_block_start)
end_idx = content.find(old_block_end, start_idx) + len(old_block_end)

if start_idx == -1 or end_idx == -1:
    print("ERROR: Could not find block")
    print(f"start_idx={start_idx}, end_idx={end_idx}")
    exit(1)

old_block = content[start_idx:end_idx]
print(f"Found block of length {len(old_block)}")

new_block = """            // 优化：先快速显示数据，自注册等耗时操作移到后台
            try await appRecordRecovery?.restoreMissingRecords()
            guard generation == loadGeneration else { return }

            let fetched = try await appStore.fetchAll()
            guard generation == loadGeneration else { return }

            var fetchedAccounts = try await accountRepository?.fetchAll() ?? []
            guard generation == loadGeneration else { return }
            fetchedAccounts = try await repairLegacyAccountStatuses(fetchedAccounts)
            guard generation == loadGeneration else { return }

            let preferredAccountID: UUID?
            if let signingPreferenceStore {
                preferredAccountID = await signingPreferenceStore.activeAccountID()
            } else {
                preferredAccountID = nil
            }
            guard generation == loadGeneration else { return }

            let selectableAccounts = fetchedAccounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
            let resolvedAccountID: UUID?
            if let preferredAccountID, fetchedAccounts.contains(where: { $0.id == preferredAccountID }) {
                resolvedAccountID = preferredAccountID
            } else if let current = activeAccountID, fetchedAccounts.contains(where: { $0.id == current }) {
                resolvedAccountID = current
            } else {
                resolvedAccountID = selectableAccounts.first?.id
                if preferredAccountID == nil {
                    await signingPreferenceStore?.setActiveAccountID(resolvedAccountID)
                }
            }

            // 快速显示应用列表
            apps = fetched
            accounts = fetchedAccounts
            activeAccountID = resolvedAccountID
            hasLoaded = true
            restorePendingBatchResultIfNeeded()

            // 后台执行耗时操作
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }

                if let selfAppRegistrar = self.selfAppRegistrar {
                    do {
                        try await selfAppRegistrar.ensureRegistered()
                        let refreshed = try? await self.appStore?.fetchAll()
                        if let refreshed {
                            await MainActor.run { self.apps = refreshed }
                        }
                    } catch {
                        try? await self.logStore?.append(category: .system, level: .error, message: "Seal 自身记录同步失败", code: "SEAL-SELF-REG-001")
                    }
                }

                if let fileStore = self.fileStore {
                    try? await fileStore.clearOrphanedAppFiles(validAppIDs: Set(fetched.map { $0.id }))
                }

                let emails = await self.loadFullAccountEmails(for: fetchedAccounts)
                await MainActor.run { self.fullAccountEmails = emails }

                var icons: [UUID: Data] = [:]
                if let fileStore = self.fileStore {
                    for app in fetched {
                        guard let path = app.displayIconRelativePath,
                              let data = try? await fileStore.read(relativePath: path) else { continue }
                        icons[app.id] = data
                    }
                }
                await MainActor.run { self.iconData = icons }

                await self.seedSigningHistoryIfNeeded(apps: fetched, accounts: fetchedAccounts)

                if let notificationScheduler = self.notificationScheduler,
                   let notificationPreferences = self.notificationPreferences {
                    do {
                        try await notificationScheduler.reschedule(apps: fetched, enabled: notificationPreferences.isEnabled, leadHours: notificationPreferences.leadHours)
                    } catch {
                        try? await self.logStore?.append(category: .system, level: .error, message: "通知调度失败", code: "SEAL-NOTIFY-002a")
                    }
                }
            }"""

content = content[:start_idx] + new_block + content[end_idx:]

with open(fpath, 'w', encoding='utf-8') as f:
    f.write(content)

print("Done!")
