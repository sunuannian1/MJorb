fpath = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Features\Apps\AppsViewModel.swift"
with open(fpath, 'r', encoding='utf-8') as f:
    content = f.read()

old = """            // 后台执行耗时操作
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

new = """            // 后台执行耗时操作
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }

                // Seal 自身注册后，重新获取最新数据，确保后续操作用最新列表
                var latestApps = fetched
                if let selfAppRegistrar = self.selfAppRegistrar {
                    do {
                        try await selfAppRegistrar.ensureRegistered()
                        if let refreshed = try? await self.appStore?.fetchAll() {
                            latestApps = refreshed
                            await MainActor.run { self.apps = refreshed }
                        }
                    } catch {
                        try? await self.logStore?.append(category: .system, level: .error, message: "Seal 自身记录同步失败", code: "SEAL-SELF-REG-001")
                    }
                }

                // 用最新数据清理孤儿文件，避免误删新创建的 Seal 文件夹
                if let fileStore = self.fileStore {
                    try? await fileStore.clearOrphanedAppFiles(validAppIDs: Set(latestApps.map { $0.id }))
                }

                let emails = await self.loadFullAccountEmails(for: fetchedAccounts)
                await MainActor.run { self.fullAccountEmails = emails }

                // 用最新数据加载图标
                var icons: [UUID: Data] = [:]
                if let fileStore = self.fileStore {
                    for app in latestApps {
                        guard let path = app.displayIconRelativePath,
                              let data = try? await fileStore.read(relativePath: path) else { continue }
                        icons[app.id] = data
                    }
                }
                await MainActor.run { self.iconData = icons }

                await self.seedSigningHistoryIfNeeded(apps: latestApps, accounts: fetchedAccounts)

                // 用最新数据调度通知
                if let notificationScheduler = self.notificationScheduler,
                   let notificationPreferences = self.notificationPreferences {
                    do {
                        try await notificationScheduler.reschedule(apps: latestApps, enabled: notificationPreferences.isEnabled, leadHours: notificationPreferences.leadHours)
                    } catch {
                        try? await self.logStore?.append(category: .system, level: .error, message: "通知调度失败", code: "SEAL-NOTIFY-002a")
                    }
                }
            }"""

if old in content:
    content = content.replace(old, new)
    with open(fpath, 'w', encoding='utf-8') as f:
        f.write(content)
    print("Done!")
else:
    print("ERROR: old string not found")
