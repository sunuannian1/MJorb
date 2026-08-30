fpath = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Features\Settings\SettingsViewModel.swift"
with open(fpath, 'r', encoding='utf-8') as f:
    content = f.read()

old = """                var loadedNotificationsEnabled = await MainActor.run { self.notificationsEnabled }
                var loadedReminderHours = await MainActor.run { self.reminderHours }
                var loadedNotificationStatus = await MainActor.run { self.notificationStatus }
                if let notificationPreferences = self.notificationPreferences {
                    loadedNotificationsEnabled = notificationPreferences.isEnabled
                    loadedReminderHours = notificationPreferences.leadHours
                    if let notificationScheduler = self.notificationScheduler {
                        loadedNotificationStatus = await notificationScheduler.status(sealEnabled: loadedNotificationsEnabled)
                    }
                }"""

new = """                var loadedNotificationsEnabled = await MainActor.run { self.notificationsEnabled }
                var loadedReminderHours = await MainActor.run { self.reminderHours }
                var loadedNotificationStatus = await MainActor.run { self.notificationStatus }
                let prefsEnabled = await MainActor.run { self.notificationPreferences?.isEnabled }
                let prefsLeadHours = await MainActor.run { self.notificationPreferences?.leadHours }
                if let prefsEnabled, let prefsLeadHours {
                    loadedNotificationsEnabled = prefsEnabled
                    loadedReminderHours = prefsLeadHours
                    if let notificationScheduler = self.notificationScheduler {
                        loadedNotificationStatus = await notificationScheduler.status(sealEnabled: loadedNotificationsEnabled)
                    }
                }"""

if old in content:
    content = content.replace(old, new)
    with open(fpath, 'w', encoding='utf-8') as f:
        f.write(content)
    print("Done!")
else:
    print("ERROR: old string not found")
