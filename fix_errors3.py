import os, re

root = r"C:\Users\DMJ\Desktop\Seal--source-e50b594"

def replace_in_file(rel_path, replacements):
    fp = os.path.join(root, rel_path)
    with open(fp, encoding="utf-8") as f:
        content = f.read()
    changed = False
    for old_pattern, new_text in replacements:
        # old_pattern is a regex with named groups for indentation
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

# === AppsViewModel.swift ===
print("AppsViewModel.swift:")
replace_in_file("Seal/Features/Apps/AppsViewModel.swift", [
    # AUTH-104c: 普通字符串版本
    (
        r'title: "Apple ID 不可用",\s*\n\s*reason: "上次签名此 App 的 Apple ID 不可用。",\s*\n\s*recovery: "前往设置",',
        'title: "签名账号不可用",\n                reason: "上次签名这个应用的 Apple ID 已被删除或凭据失效。",\n                recovery: "在「我的」中重新添加原 Apple ID，或用当前账号重新签名安装",'
    ),
    # AUTH-110a: 续签记录不完整
    (
        r'title: "续签记录不完整",\s*\n\s*reason: "未记录上次签名此 App 的 Apple ID。",\s*\n\s*recovery: "重新导入 IPA 签名并安装",',
        'title: "缺少签名账号记录",\n                reason: "这个应用没有记录上次签名使用的 Apple ID，无法自动续签。",\n                recovery: "重新导入 IPA 并签名安装；Seal 自身请在「我的」中添加对应 Apple ID",'
    ),
])

# === SettingsViewModel.swift ===
print("SettingsViewModel.swift:")
replace_in_file("Seal/Features/Settings/SettingsViewModel.swift", [
    # AUTH-103: 未找到开发团队
    (
        r'title: "无法添加账号",\s*\n\s*reason: "未找到开发团队",\s*\n\s*recovery: "检查 Apple ID",',
        'title: "未找到开发者团队",\n                    reason: "这个 Apple ID 没有可用的开发者团队（免费账号也会自动创建免费团队）。",\n                    recovery: "确认该 Apple ID 已在 Apple 开发者网站同意协议，或更换其他 Apple ID",'
    ),
    # AUTH-107: 没有可用 Team
    (
        r'title: "没有可用 Team",\s*\n\s*reason: "Apple 返回的账号信息中没有可用于签名的 Team。",\s*\n\s*recovery: "重新验证",',
        'title: "没有可用开发者团队",\n                reason: "这个 Apple ID 下没有可用于签名的开发者团队。",\n                recovery: "确认该 Apple ID 已注册开发者账号（免费账号即可），或更换其他 Apple ID",'
    ),
])

# === SelfRenewalContextValidator.swift ===
print("SelfRenewalContextValidator.swift:")
replace_in_file("Seal/Core/Signing/SelfRenewalContextValidator.swift", [
    # SELF-102
    (
        r'title: "Seal 身份不匹配",\s*\n\s*reason: "Seal 自续签必须继续使用当前安装的 Bundle ID。",\s*\n\s*recovery: "恢复当前 Bundle ID",',
        'title: "Seal 标识不匹配",\n            reason: "Seal 自续签必须使用当前已安装的 Bundle ID，不能更换。",\n            recovery: "恢复为当前安装的 Bundle ID 后续签",'
    ),
    # SELF-103
    (
        r'title: "Team 不匹配",\s*\n\s*reason: "当前 Seal 与所选 Apple ID 不属于同一个 Team。",\s*\n\s*recovery: "选择 Team",',
        'title: "开发者团队不匹配",\n            reason: "当前 Seal 属于其他开发者团队，所选 Apple ID 无权续签。",\n            recovery: "使用签名 Seal 时的原 Apple ID 续签，或用当前账号重新安装 Seal",'
    ),
])

# === RenewalCoordinator.swift ===
print("RenewalCoordinator.swift:")
replace_in_file("Seal/Core/Renewal/RenewalCoordinator.swift", [
    # RENEW-404
    (
        r'title: "无法续签应用",\s*\n\s*reason: "应用记录不存在",\s*\n\s*recovery: "重新导入 IPA",',
        'title: "无法续签应用",\n            reason: "续签时未找到该应用的本地记录。",\n            recovery: "重新导入 IPA 并签名安装",'
    ),
    # RENEW-500
    (
        r'title: "无法续签应用",\s*\n\s*reason: "签名或安装失败",\s*\n\s*recovery: "重试",',
        'title: "续签失败",\n            reason: "续签过程中签名或安装步骤失败，具体原因请查看详情。",\n            recovery: "根据错误提示处理后重试；如为账号问题请在「我的」中检查 Apple ID",'
    ),
])

# === ApplePortalSigningService.swift ===
print("ApplePortalSigningService.swift:")
replace_in_file("Seal/Infrastructure/Signing/ApplePortalSigningService.swift", [
    # CERT-203
    (
        r'title: "证书准备失败",\s*\n\s*reason: "Apple 返回：证书准备失败",\s*\n\s*recovery: "重试",',
        'title: "证书准备失败",\n                reason: "Apple 服务器未能准备好签名证书。可能原因：网络不稳定、或该账号证书数量已达上限。",\n                recovery: "检查网络后重试；如持续失败请在「我的」中撤销旧证书后再试",'
    ),
    # CERT-216
    (
        r'title: "签名失败",\s*\n\s*reason: "Apple 返回：证书撤销失败",\s*\n\s*recovery: "重试",',
        'title: "证书撤销失败",\n            reason: "Apple 服务器未能撤销指定证书。可能原因：网络不稳定、或该证书已被撤销。",\n            recovery: "检查网络后重试；如持续失败请在「我的」中重新同步证书状态",'
    ),
    # SIGN-501
    (
        r'title: "签名失败",\s*\n\s*reason: "Apple 返回：请求未能完成",\s*\n\s*recovery: "重试",',
        'title: "签名请求失败",\n            reason: "Apple 服务器未能完成签名请求。可能原因：网络不稳定、或 Apple 服务暂时不可用。",\n            recovery: "检查网络后稍后重试；如持续失败请查看日志",'
    ),
])

print("\nDone!")
