fpath = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Core\Renewal\SelfAppRegistrar.swift"
with open(fpath, 'r', encoding='utf-8') as f:
    content = f.read()

old = """            // accountID 为 nil 时修复，但只在 teamID 匹配时才设置，避免续签时 Team 不匹配
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

new = """            // accountID 为 nil 或 teamID 不匹配时修复，只在 teamID 匹配时才设置
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

if old in content:
    content = content.replace(old, new)
    with open(fpath, 'w', encoding='utf-8') as f:
        f.write(content)
    print("Done!")
else:
    print("ERROR: old string not found")
