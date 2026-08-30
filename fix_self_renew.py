fpath = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Core\Renewal\SelfAppRegistrar.swift"
with open(fpath, 'r', encoding='utf-8') as f:
    content = f.read()

# 修改 atomicallyUpdateSealRecord 中的账户和 teamID 逻辑
old = """            // 7. 解析账户绑定，只在 teamID 匹配时设置，避免续签时 Team 不匹配
            let resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: metadata.signingTeamIdentifier,
                accounts: accounts,
                fallbackAccountID: existing?.accountID
            )"""

new = """            // 7. 解析账户绑定，确保 Seal 始终有匹配的账户和 teamID 以支持自续签
            var resolvedAccountID = SelfAppAccountBinding.resolvedAccountID(
                teamIdentifier: metadata.signingTeamIdentifier,
                accounts: accounts,
                fallbackAccountID: existing?.accountID
            )
            var effectiveTeamID = metadata.signingTeamIdentifier ?? existing?.signingTeamID
            // 如果匹配不到账户，用第一个可用账户，并用该账户的 teamID，确保能自续签
            if resolvedAccountID == nil, let firstAccount = accounts.first {
                resolvedAccountID = firstAccount.id
                effectiveTeamID = firstAccount.teamID
            }"""

content = content.replace(old, new)

# 修改 record 中的 signingTeamID
old2 = """                signingTeamID: metadata.signingTeamIdentifier ?? existing?.signingTeamID,"""
new2 = """                signingTeamID: effectiveTeamID,"""

content = content.replace(old2, new2)

# 修改版本一致时的 accountID 修复逻辑
old3 = """            // accountID 为 nil 或 teamID 不匹配时修复，只在 teamID 匹配时才设置
            let currentAccount = accounts.first { $0.id == existing.accountID }
            let teamMismatch = currentAccount != nil
                && metadata.signingTeamIdentifier?.isEmpty == false
                && currentAccount?.teamID.caseInsensitiveCompare(metadata.signingTeamIdentifier!) != .orderedSame
            if existing.accountID == nil || teamMismatch {
                let resolvedID = SelfAppAccountBinding.resolvedAccountID(
                    teamIdentifier: metadata.signingTeamIdentifier,
                    accounts: accounts,
                    fallbackAccountID: existing.accountID
                )
                if let resolvedID, resolvedID != existing.accountID {
                    var updated = existing
                    updated.accountID = resolvedID
                    try await appStore.save(updated)
                }
            }"""

new3 = """            // accountID 为 nil 或 teamID 不匹配时修复，确保 Seal 始终能自续签
            let currentAccount = accounts.first { $0.id == existing.accountID }
            let teamMismatch = currentAccount != nil
                && existing.signingTeamID?.isEmpty == false
                && currentAccount?.teamID.caseInsensitiveCompare(existing.signingTeamID!) != .orderedSame
            if existing.accountID == nil || teamMismatch {
                var resolvedID = SelfAppAccountBinding.resolvedAccountID(
                    teamIdentifier: metadata.signingTeamIdentifier,
                    accounts: accounts,
                    fallbackAccountID: existing.accountID
                )
                var effectiveTeamID = metadata.signingTeamIdentifier ?? existing.signingTeamID
                if resolvedID == nil, let firstAccount = accounts.first {
                    resolvedID = firstAccount.id
                    effectiveTeamID = firstAccount.teamID
                }
                if let resolvedID, resolvedID != existing.accountID || teamMismatch {
                    var updated = existing
                    updated.accountID = resolvedID
                    updated.signingTeamID = effectiveTeamID
                    try await appStore.save(updated)
                }
            }"""

content = content.replace(old3, new3)

with open(fpath, 'w', encoding='utf-8') as f:
    f.write(content)
print("Done!")
