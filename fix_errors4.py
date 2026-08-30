import os, re

root = r"C:\Users\DMJ\Desktop\Seal--source-e50b594"

def replace_in_file(rel_path, replacements):
    fp = os.path.join(root, rel_path)
    with open(fp, encoding="utf-8") as f:
        content = f.read()
    changed = False
    for old_pattern, new_text in replacements:
        matches = list(re.finditer(old_pattern, content))
        if matches:
            for m in reversed(matches):
                content = content[:m.start()] + new_text + content[m.end():]
            changed = True
            print(f"  OK ({len(matches)}x): {old_pattern[:50]}...")
        else:
            print(f"  NOT FOUND: {old_pattern[:50]}...")
    if changed:
        with open(fp, "w", encoding="utf-8", newline="") as f:
            f.write(content)
    return changed

# === AppleAccountClient.swift - AUTH-103 ===
print("AppleAccountClient.swift:")
replace_in_file("Seal/Infrastructure/Accounts/AppleAccountClient.swift", [
    (
        r'title: "无法添加账号",\s*\n\s*reason: "未找到开发团队",\s*\n\s*recovery: "检查 Apple ID",',
        'title: "未找到开发者团队",\n                    reason: "这个 Apple ID 没有可用的开发者团队（免费账号也会自动创建免费团队）。",\n                    recovery: "确认该 Apple ID 已在 Apple 开发者网站同意协议，或更换其他 Apple ID",'
    ),
])

# === SettingsViewModel.swift - CERT-216 ===
print("SettingsViewModel.swift:")
replace_in_file("Seal/Features/Settings/SettingsViewModel.swift", [
    (
        r'title: "签名失败",\s*\n\s*reason: "Apple 返回：证书撤销失败",\s*\n\s*recovery: "重试",',
        'title: "证书撤销失败",\n                reason: "Apple 服务器未能撤销指定证书。可能原因：网络不稳定、或该证书已被撤销。",\n                recovery: "检查网络后重试；如持续失败请在「我的」中重新同步证书状态",'
    ),
])

# === ApplePortalCertificateService.swift - CERT-210a ===
print("ApplePortalCertificateService.swift:")
replace_in_file("Seal/Infrastructure/Signing/ApplePortalCertificateService.swift", [
    (
        r'title: "证书不存在",\s*\n\s*reason: "Apple 返回：证书撤销失败",\s*\n\s*recovery: "重新同步证书",',
        'title: "证书撤销失败",\n                reason: "Apple 服务器未能撤销指定证书。可能原因：网络不稳定、或该证书已被撤销。",\n                recovery: "检查网络后重试；如持续失败请重新同步证书状态",'
    ),
])

print("\nDone!")
