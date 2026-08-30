import os

root = r"C:\Users\DMJ\Desktop\Seal--source-e50b594"

# (relative_path, old_string, new_string)
replacements = [
    # === SigningCertificateSelectionPolicy.swift ===
    (
        "Seal/Core/Signing/SigningCertificateSelectionPolicy.swift",
        '''                title: "续签记录不完整",
                reason: "未记录上次签名此 App 的 Apple ID。",
                recovery: "重新导入 IPA 签名并安装",''',
        '''                title: "缺少签名账号记录",
                reason: "这个应用没有记录上次签名使用的 Apple ID，无法自动续签。",
                recovery: "重新导入 IPA 并签名安装；Seal 自身请在「我的」中添加对应 Apple ID",'''
    ),
    (
        "Seal/Core/Signing/SigningCertificateSelectionPolicy.swift",
        '''                title: "Apple ID 不匹配",
                reason: "续签必须使用上次签名此 App 的 Apple ID。",
                recovery: "切换回原 Apple ID",''',
        '''                title: "Apple ID 不匹配",
                reason: "这个应用是用其他 Apple ID 签名的，续签必须使用原账号。",
                recovery: "在「我的」中切换到原 Apple ID，或用当前账号重新签名安装",'''
    ),
    (
        "Seal/Core/Signing/SigningCertificateSelectionPolicy.swift",
        '''                title: "续签记录不完整",
                reason: "未记录上次签名此 App 的 Team。",
                recovery: "重新导入 IPA 签名并安装",''',
        '''                title: "缺少团队记录",
                reason: "这个应用没有记录上次签名使用的开发者团队，无法自动续签。",
                recovery: "重新导入 IPA 并签名安装；Seal 自身请在「我的」中添加对应 Apple ID",'''
    ),
    (
        "Seal/Core/Signing/SigningCertificateSelectionPolicy.swift",
        '''                title: "Team 不匹配",
                reason: "续签必须使用上次签名此 App 的 Team。",
                recovery: "选择 Team",''',
        '''                title: "开发者团队不匹配",
                reason: "这个应用属于其他开发者团队，当前 Apple ID 无权续签。",
                recovery: "使用原开发者团队的 Apple ID 续签，或用当前账号重新签名安装",'''
    ),

    # === AppsViewModel.swift - AUTH-104, 104c ===
    (
        "Seal/Features/Apps/AppsViewModel.swift",
        '''                title: "Apple ID 不可用",
                reason: "此 App 没有保存上次签名使用的 Apple ID。",
                recovery: "查看详情",''',
        '''                title: "缺少签名账号",
                reason: "这个应用没有记录上次签名使用的 Apple ID，无法续签。",
                recovery: "重新导入 IPA 签名安装；Seal 自身请在「我的」中添加 Apple ID",'''
    ),
    (
        "Seal/Features/Apps/AppsViewModel.swift",
        '''                title: "Apple ID 不可用",
                reason: "上次签名此 App 的 Apple ID 不可用。",
                recovery: "前往设置",''',
        '''                title: "签名账号不可用",
                reason: "上次签名这个应用的 Apple ID 已被删除或凭据失效。",
                recovery: "在「我的」中重新添加原 Apple ID，或用当前账号重新签名安装",'''
    ),

    # === SettingsViewModel.swift - AUTH-103, 107 ===
    (
        "Seal/Features/Settings/SettingsViewModel.swift",
        '''                    title: "无法添加账号",
                    reason: "未找到开发团队",
                    recovery: "检查 Apple ID",''',
        '''                    title: "未找到开发者团队",
                    reason: "这个 Apple ID 没有可用的开发者团队（免费账号也会自动创建免费团队）。",
                    recovery: "确认该 Apple ID 已在 Apple 开发者网站同意协议，或更换其他 Apple ID",'''
    ),
    (
        "Seal/Features/Settings/SettingsViewModel.swift",
        '''                title: "没有可用 Team",
                reason: "Apple 返回的账号信息中没有可用于签名的 Team。",
                recovery: "重新验证",''',
        '''                title: "没有可用开发者团队",
                reason: "这个 Apple ID 下没有可用于签名的开发者团队。",
                recovery: "确认该 Apple ID 已注册开发者账号（免费账号即可），或更换其他 Apple ID",'''
    ),

    # === SelfRenewalContextValidator.swift - SELF-102, 103 ===
    (
        "Seal/Core/Signing/SelfRenewalContextValidator.swift",
        '''            title: "Seal 身份不匹配",
            reason: "Seal 自续签必须继续使用当前安装的 Bundle ID。",
            recovery: "恢复当前 Bundle ID",''',
        '''            title: "Seal 标识不匹配",
            reason: "Seal 自续签必须使用当前已安装的 Bundle ID，不能更换。",
            recovery: "恢复为当前安装的 Bundle ID 后续签",'''
    ),
    (
        "Seal/Core/Signing/SelfRenewalContextValidator.swift",
        '''            title: "Team 不匹配",
            reason: "当前 Seal 与所选 Apple ID 不属于同一个 Team。",
            recovery: "选择 Team",''',
        '''            title: "开发者团队不匹配",
            reason: "当前 Seal 属于其他开发者团队，所选 Apple ID 无权续签。",
            recovery: "使用签名 Seal 时的原 Apple ID 续签，或用当前账号重新安装 Seal",'''
    ),

    # === RenewalCoordinator.swift - RENEW-404, 500 ===
    (
        "Seal/Core/Renewal/RenewalCoordinator.swift",
        '''            title: "无法续签应用",
            reason: "应用记录不存在",
            recovery: "重新导入 IPA",''',
        '''            title: "无法续签应用",
            reason: "续签时未找到该应用的本地记录。",
            recovery: "重新导入 IPA 并签名安装",'''
    ),
    (
        "Seal/Core/Renewal/RenewalCoordinator.swift",
        '''            title: "无法续签应用",
            reason: "签名或安装失败",
            recovery: "重试",''',
        '''            title: "续签失败",
            reason: "续签过程中签名或安装步骤失败，具体原因请查看上方详情。",
            recovery: "根据上方错误提示处理后重试；如为账号问题请在「我的」中检查 Apple ID",'''
    ),

    # === MinimuxerInstallChannel.swift - INSTALL-702 ===
    (
        "Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift",
        '''            title: "无法安装应用",
            reason: "iOS 安装服务未能完成安装。技术信息已隐藏。",
            recovery: "重试",''',
        '''            title: "安装失败",
            reason: "iOS 安装服务未能完成安装。可能原因：设备未信任、存储空间不足、或应用与设备不兼容。",
            recovery: "确认设备已信任、存储空间充足后重试；如持续失败请查看日志",'''
    ),

    # === ApplePortalSigningService.swift - CERT-203, 204a, 216, SIGN-501 ===
    (
        "Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
        '''                title: "证书准备失败",
                reason: "Apple 返回：证书准备失败",
                recovery: "重试",''',
        '''                title: "证书准备失败",
                reason: "Apple 服务器未能准备好签名证书。可能原因：网络不稳定、或该账号证书数量已达上限。",
                recovery: "检查网络后重试；如持续失败请在「我的」中撤销旧证书后再试",'''
    ),
    (
        "Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
        '''                title: "签名失败",
                reason: "Apple 返回：无法创建签名证书",
                recovery: "重试",''',
        '''                title: "无法创建签名证书",
                reason: "Apple 服务器未能创建签名证书。可能原因：该账号证书数量已达上限、或网络不稳定。",
                recovery: "检查网络后重试；如持续失败请在「我的」中撤销旧证书后再试",'''
    ),
    (
        "Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
        '''            title: "签名失败",
            reason: "Apple 返回：证书撤销失败",
            recovery: "重试",''',
        '''            title: "证书撤销失败",
            reason: "Apple 服务器未能撤销指定证书。可能原因：网络不稳定、或该证书已被撤销。",
            recovery: "检查网络后重试；如持续失败请在「我的」中重新同步证书状态",'''
    ),
    (
        "Seal/Infrastructure/Signing/ApplePortalSigningService.swift",
        '''            title: "签名失败",
            reason: "Apple 返回：请求未能完成",
            recovery: "重试",''',
        '''            title: "签名请求失败",
            reason: "Apple 服务器未能完成签名请求。可能原因：网络不稳定、或 Apple 服务暂时不可用。",
            recovery: "检查网络后稍后重试；如持续失败请查看日志",'''
    ),
]

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
        # Debug: find which part is missing
        for line in old.split("\n")[:3]:
            if line.strip() and line.strip() not in content:
                print(f"  missing: {line.strip()[:60]}")
