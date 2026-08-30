import re

fpath = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Features\Settings\SettingsViewModel.swift"
with open(fpath, 'r', encoding='utf-8') as f:
    content = f.read()

# 找到 load 方法中从 "let fetchedAccounts" 到 "hasLoaded = true" 的部分
old_block_start = "            let fetchedAccounts = try await accountRepository.fetchAll()"
old_block_end = "            hasLoaded = true"

start_idx = content.find(old_block_start)
end_idx = content.find(old_block_end, start_idx) + len(old_block_end)

if start_idx == -1 or end_idx == -1:
    print("ERROR: Could not find block")
    print(f"start_idx={start_idx}, end_idx={end_idx}")
    exit(1)

old_block = content[start_idx:end_idx]
print(f"Found block of length {len(old_block)}")

new_block = """            let fetchedAccounts = try await accountRepository.fetchAll()
            guard generation == loadGeneration else { return }
            let repairedAccounts = try await repairLegacyAccountStatuses(fetchedAccounts)
            guard generation == loadGeneration else { return }
            let displayedAccounts = try await refreshedAccountDisplayNames(repairedAccounts)
            guard generation == loadGeneration else { return }

            let loadedPairing: PairingRecord?
            do {
                loadedPairing = try await pairingStore.current()
            } catch {
                loadedPairing = PairingRecord(
                    deviceIdentifier: nil,
                    isRemotePairing: false,
                    validationStatus: .fileUnreadable
                )
            }
            guard generation == loadGeneration else { return }

            let preferredAccountID: UUID?
            if let signingPreferenceStore {
                preferredAccountID = await signingPreferenceStore.activeAccountID()
            } else {
                preferredAccountID = nil
            }
            guard generation == loadGeneration else { return }

            let selectableAccounts = displayedAccounts.filter { AccountAvailabilityPolicy.isSelectable($0) }
            let resolvedAccountID: UUID?
            if let preferredAccountID, displayedAccounts.contains(where: { $0.id == preferredAccountID }) {
                resolvedAccountID = preferredAccountID
            } else if let current = activeAccountID, displayedAccounts.contains(where: { $0.id == current }) {
                resolvedAccountID = current
            } else {
                resolvedAccountID = selectableAccounts.first?.id
                if preferredAccountID == nil {
                    await signingPreferenceStore?.setActiveAccountID(resolvedAccountID)
                }
            }

            // 快速显示核心数据
            accounts = displayedAccounts
            pairingRecord = loadedPairing
            activeAccountID = resolvedAccountID
            hasLoaded = true

            // 后台加载非关键数据
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }

                _ = await self.importPairingAssistantInboxIfPresent()

                let emails = await self.loadFullAccountEmails(for: displayedAccounts)
                await MainActor.run { self.fullAccountEmails = emails }

                let storedApps = (try? await self.appStore?.fetchAll()) ?? []
                let appIcons = await self.loadAppIcons(for: storedApps)
                await MainActor.run { self.appIconData = appIcons }

                self.loadCertificateInventoryCache(for: displayedAccounts)

                let loadedLogs = (try? await self.logStore?.entries()) ?? []
                let loadedHistory = (try? await self.signingHistoryStore?.records()) ?? []
                let historyIcons = await self.loadSigningHistoryIcons(for: loadedHistory)
                await MainActor.run {
                    self.logs = loadedLogs
                    self.signingHistory = loadedHistory
                    self.signingHistoryIconData = historyIcons
                }

                var loadedServers: [AnisetteServer] = await MainActor.run { self.anisetteServers }
                var loadedSelectedServerID: String? = await MainActor.run { self.selectedAnisetteServerID }
                if let anisetteEnvironment = self.anisetteEnvironment {
                    async let availableServers = anisetteEnvironment.availableServers()
                    async let selectedServerID = anisetteEnvironment.selectedServerID()
                    loadedServers = await availableServers
                    loadedSelectedServerID = (await selectedServerID) ?? loadedServers.first?.id
                }
                await MainActor.run {
                    self.anisetteServers = loadedServers
                    self.selectedAnisetteServerID = loadedSelectedServerID
                }

                var loadedNotificationsEnabled = await MainActor.run { self.notificationsEnabled }
                var loadedReminderHours = await MainActor.run { self.reminderHours }
                var loadedNotificationStatus = await MainActor.run { self.notificationStatus }
                if let notificationPreferences = self.notificationPreferences {
                    loadedNotificationsEnabled = notificationPreferences.isEnabled
                    loadedReminderHours = notificationPreferences.leadHours
                    if let notificationScheduler = self.notificationScheduler {
                        loadedNotificationStatus = await notificationScheduler.status(sealEnabled: loadedNotificationsEnabled)
                    }
                }
                await MainActor.run {
                    self.notificationsEnabled = loadedNotificationsEnabled
                    self.reminderHours = loadedReminderHours
                    self.notificationStatus = loadedNotificationStatus
                }

                let loadedStorageUsage: SettingsStorageUsage
                if let fileStore = self.fileStore {
                    loadedStorageUsage = (try? await fileStore.storageUsage()) ?? .empty
                } else {
                    loadedStorageUsage = .empty
                }
                await MainActor.run {
                    self.storageUsage = loadedStorageUsage
                    self.refreshLogExportText()
                }
            }"""

content = content[:start_idx] + new_block + content[end_idx:]

with open(fpath, 'w', encoding='utf-8') as f:
    f.write(content)

print("Done!")
