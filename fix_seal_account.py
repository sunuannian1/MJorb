fpath = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Core\Renewal\SelfAppRegistrar.swift"
with open(fpath, 'r', encoding='utf-8') as f:
    content = f.read()

# 修复：版本一致但 accountID 为 nil 时，也要更新
old = """        // 版本一致且文件存在 → 直接跳过，只清理重复记录
        if let existing,
           existing.version == metadata.version,
           existing.buildNumber == metadata.buildNumber,
           try await fileStore.exists(relativePath: existing.ipaRelativePath) {
            try await cleanupDuplicateSealRecords(records: records, keepID: existing.id)
            return
        }"""

new = """        // 版本一致且文件存在 → 检查是否需要修复 accountID
        if let existing,
           existing.version == metadata.version,
           existing.buildNumber == metadata.buildNumber,
           try await fileStore.exists(relativePath: existing.ipaRelativePath) {
            // accountID 为 nil 时修复，确保能出现在续签队列中
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
            }
            try await cleanupDuplicateSealRecords(records: records, keepID: existing.id)
            return
        }"""

content = content.replace(old, new)

# 修复：atomicallyUpdateSealRecord 中 resolvedAccountID 为 nil 时用第一个可用账户
old2 = """            // 7. 解析账户绑定
            let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: metadata.signingTeamIdentifier,
                accounts: accounts,
                fallbackAccountID: existing?.accountID
            )"""

new2 = """            // 7. 解析账户绑定，确保不为 nil（用第一个可用账户兜底）
            let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: metadata.signingTeamIdentifier,
                accounts: accounts,
                fallbackAccountID: existing?.accountID
            ) ?? accounts.first?.id"""

content = content.replace(old2, new2)

with open(fpath, 'w', encoding='utf-8') as f:
    f.write(content)
print("Done!")
