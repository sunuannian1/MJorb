fpath = r"C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Core\Renewal\SelfAppRegistrar.swift"
with open(fpath, 'r', encoding='utf-8') as f:
    content = f.read()

# 修复 1: ipaRelativePath 是非 Optional，不需要 if let
old1 = """        if let existing,
           existing.version == metadata.version,
           existing.buildNumber == metadata.buildNumber,
           let ipaPath = existing.ipaRelativePath,
           try await fileStore.exists(relativePath: ipaPath) {"""
new1 = """        if let existing,
           existing.version == metadata.version,
           existing.buildNumber == metadata.buildNumber,
           try await fileStore.exists(relativePath: existing.ipaRelativePath) {"""

content = content.replace(old1, new1)

# 修复 2: flatMap 中不能用 async，改成先读取
old2 = """            // 3. 图标：优先用新提取的，失败则复用旧图标
            let iconData = metadata.iconData
                ?? existing?.iconRelativePath.flatMap { path in
                    try? await fileStore.read(relativePath: path)
                }"""
new2 = """            // 3. 图标：优先用新提取的，失败则复用旧图标
            var iconData = metadata.iconData
            if iconData == nil, let oldIconPath = existing?.iconRelativePath {
                iconData = try? await fileStore.read(relativePath: oldIconPath)
            }"""

content = content.replace(old2, new2)

with open(fpath, 'w', encoding='utf-8') as f:
    f.write(content)
print("Done!")
