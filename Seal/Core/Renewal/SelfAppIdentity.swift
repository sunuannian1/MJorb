import Foundation

enum SelfAppBundleIdentity {
    static func originalBundleIdentifier(
        currentBundleIdentifier: String,
        declaredOriginalBundleIdentifier: String?,
        existingOriginalBundleIdentifier: String?
    ) -> String {
        existingOriginalBundleIdentifier
            ?? declaredOriginalBundleIdentifier
            ?? currentBundleIdentifier
    }
}

enum SelfAppAccountBinding {
    static func matchedAccountID(
        teamIdentifier: String?,
        accounts: [AppleAccountRecord]
    ) -> UUID? {
        guard let teamIdentifier = normalizedTeamIdentifier(teamIdentifier) else {
            return nil
        }
        return accounts.first { account in
            account.teamID.caseInsensitiveCompare(teamIdentifier) == .orderedSame
        }?.id
    }

    static func resolvedAccountID(
        teamIdentifier: String?,
        accounts: [AppleAccountRecord],
        fallbackAccountID: UUID?
    ) -> UUID? {
        guard normalizedTeamIdentifier(teamIdentifier) != nil else {
            return fallbackAccountID
        }
        // 匹配到则用匹配的，匹配不到回退到 fallback，确保 Seal 始终有 accountID
        return matchedAccountID(
            teamIdentifier: teamIdentifier,
            accounts: accounts
        ) ?? fallbackAccountID
    }

    private static func normalizedTeamIdentifier(_ value: String?) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              normalized.isEmpty == false else {
            return nil
        }
        return normalized
    }
}

enum SelfAppRecordSelection {
    static func preferredExistingSealRecord(
        in records: [AppRecord],
        currentBundleIdentifier: String
    ) -> AppRecord? {
        records.first { record in
            record.isSeal && matchesSealBundleIdentifier(
                currentBundleIdentifier,
                record: record
            )
        }
    }

    static func preferredExistingSealRecordForImportedIPA(
        in records: [AppRecord],
        importedBundleIdentifier: String
    ) -> AppRecord? {
        let normalizedImportedBundleIdentifier = normalize(importedBundleIdentifier)
        let matchingRecords = records.filter { record in
            record.isSeal
                && record.userIdentityKeys.contains(normalizedImportedBundleIdentifier)
        }
        return matchingRecords.sorted { lhs, rhs in
            if lhs.belongsInInstalledList != rhs.belongsInInstalledList {
                return lhs.belongsInInstalledList
            }
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.importedAt > rhs.importedAt
        }.first
    }

    private static func matchesSealBundleIdentifier(
        _ bundleIdentifier: String,
        record: AppRecord
    ) -> Bool {
        let installedIdentifiers = [
            record.mappedBundleIdentifier,
            record.preferredBundleIdentifier
        ].compactMap { value in
            value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { $0.isEmpty == false }

        if installedIdentifiers.isEmpty == false {
            return installedIdentifiers.contains { identifier in
                bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame
            }
        }

        return bundleIdentifier.caseInsensitiveCompare(record.originalBundleIdentifier) == .orderedSame
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
