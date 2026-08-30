import os

# 定义所有需要修改的文案替换
replacements = [
    # ApplePortalSigningService.swift - App ID 相关
    (
        'Seal/Infrastructure/Signing/ApplePortalSigningService.swift',
        'title: "Bundle ID 不可用",\n                reason: "Apple 返回：App ID 的 Bundle ID 不可用",\n                recovery: "更换 Bundle ID",',
        'title: "Bundle ID 已被占用",\n                reason: "这个 Bundle ID 已被其他开发者账号注册，当前账号无法使用。",\n                recovery: "更换一个新的 Bundle ID，或使用注册该 Bundle ID 的原账号签名",'
    ),
    (
        'Seal/Infrastructure/Signing/ApplePortalSigningService.swift',
        'title: "App ID 操作失败",\n            reason: "Apple 返回：App ID 操作失败",\n            recovery: "重试",',
        'title: "App ID 创建失败",\n            reason: "Apple 服务器未能创建该应用的 App ID。可能原因：网络不稳定、免费账号 App ID 数量已达上限、或 Bundle ID 与其他账号冲突。",\n            recovery: "检查网络后重试；如持续失败，尝试更换 Bundle ID 或使用其他开发者账号",'
    ),
]

root = r"C:\Users\DMJ\Desktop\Seal--source-e50b594"
for rel_path, old, new in replacements:
    fp = os.path.join(root, rel_path)
    with open(fp, encoding="utf-8") as f:
        content = f.read()
    if old in content:
        content = content.replace(old, new)
        with open(fp, "w", encoding="utf-8", newline="") as f:
            f.write(content)
        print(f"OK: {rel_path}")
    else:
        print(f"NOT FOUND: {rel_path}")
        # Try to find similar text
        if "Bundle ID 不可用" in content:
            print("  -> 'Bundle ID 不可用' exists but pattern mismatch")
        if "App ID 操作失败" in content:
            print("  -> 'App ID 操作失败' exists but pattern mismatch")
