import Foundation

struct RefreshPlanner: Sendable {
    func makeQueue(
        apps: [AppRecord],
        fallbackAccountID: UUID? = nil,
        accounts: [AppleAccountRecord] = [],
        now: Date = Date()
    ) -> [RefreshQueueItem] {
        apps
            .filter { $0.belongsInInstalledList }
            .sorted { lhs, rhs in
                priority(for: lhs, now: now) < priority(for: rhs, now: now)
            }
            .compactMap { app in
                var accountID = app.accountID ?? fallbackAccountID
                // Seal 应用：如果 accountID 为空，尝试根据 signingTeamID 重新匹配账号
                // 解决"先添加非签名账号，后添加签名账号"导致续签选不到正确账号的问题
                if app.isSeal, accountID == nil, let teamID = app.signingTeamID {
                    accountID = accounts.first { account in
                        account.teamID.caseInsensitiveCompare(teamID) == .orderedSame
                    }?.id
                }
                guard let accountID else { return nil }
                return RefreshQueueItem(appID: app.id, accountID: accountID)
            }
    }

    private func priority(for app: AppRecord, now: Date) -> Priority {
        let expiry = app.expiryDate ?? .distantPast
        let isUrgent = expiry.timeIntervalSince(now) < 86_400
        return Priority(
            group: app.isSeal ? 2 : (isUrgent ? 0 : 1),
            expiry: expiry,
            importedAt: app.importedAt
        )
    }
}

private struct Priority: Comparable {
    let group: Int
    let expiry: Date
    let importedAt: Date

    static func < (lhs: Priority, rhs: Priority) -> Bool {
        if lhs.group != rhs.group { return lhs.group < rhs.group }
        if lhs.expiry != rhs.expiry { return lhs.expiry < rhs.expiry }
        return lhs.importedAt < rhs.importedAt
    }
}
