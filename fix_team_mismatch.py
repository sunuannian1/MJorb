fpath = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Core\Renewal\SelfAppRegistrar.swift"
with open(fpath, 'r', encoding='utf-8') as f:
    content = f.read()

# 修复 1：版本一致时的 accountID 修复，去掉 accounts.first?.id 兜底
old1 = """            // accountID 为 nil 时修复，确保能出现在续签队列中
            if existing.accountID == nil {
                let resolvedID = SelfAppAccountBinding.resolvedAccountID(
                    teamIdentifier: metadata.signingTeamIdentifier,
                    accounts: accounts,
                    fallbackAccountID: existing.accountID
                ) ?? accounts.first?.id
                if let resolvedID {
                    var updated = existing
                    updated.accountID = resolvedID
                    try await appStore.save(updated)
                }
            }"""

new1 = """            // accountID 为 nil 时修复，但只在 teamID 匹配时才设置，避免续签时 Team 不匹配
            if existing.accountID == nil {
                let resolvedID = SelfAppAccountBinding.resolvedAccountID(
                    teamIdentifier: metadata.signingTeamIdentifier,
                    accounts: accounts,
                    fallbackAccountID: existing.accountID
                )
                if let resolvedID {
                    var updated = existing
                    updated.accountID = resolvedID
                    try await appStore.save(updated)
                }
            }"""

content = content.replace(old1, new1)

# 修复 2：atomicallyUpdateSealRecord 中也去掉 accounts.first?.id 兜底
old2 = """            // 7. 解析账户绑定，确保不为 nil（用第一个可用账户兜底）
            let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: metadata.signingTeamIdentifier,
                accounts: accounts,
                fallbackAccountID: existing?.accountID
            ) ?? accounts.first?.id"""

new2 = """            // 7. 解析账户绑定，只在 teamID 匹配时设置，避免续签时 Team 不匹配
            let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: metadata.signingTeamIdentifier,
                accounts: accounts,
                fallbackAccountID: existing?.accountID
            )"""

content = content.replace(old2, new2)

with open(fpath, 'w', encoding='utf-8') as f:
    f.write(content)
print("Done!")
