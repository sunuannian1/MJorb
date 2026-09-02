import io

path = r'C:\Users\DMJ\Desktop\Seal--source-e50b594\Seal\Features\Settings\SigningCertificateSettingsView.swift'
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    content = f.read()

old = '    private func certificateSummary(_ health: CertificateHealthStatus?) -> String {\r\n        guard let health else { return "检查中" }\r\n        if health.expirationState == .invalid { return "已过期" }\r\n        return health.isUsable ? "可用" : "不可用"\r\n    }'

new = '    private func certificateSummary(_ health: CertificateHealthStatus?, serial: String?) -> String {\r\n        guard let health else { return "检查中" }\r\n        if health.expirationState == .invalid { return "已过期" }\r\n        guard health.isUsable else { return "不可用" }\r\n        if let serial, serial.isEmpty == false {\r\n            return AppSigningPresentationHelpers.certificateName(serial: serial)\r\n        }\r\n        return "可用"\r\n    }'

if old in content:
    content = content.replace(old, new)
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(content)
    print('修改成功')
else:
    # 尝试 LF 换行
    old_lf = old.replace('\r\n', '\n')
    new_lf = new.replace('\r\n', '\n')
    if old_lf in content:
        content = content.replace(old_lf, new_lf)
        with io.open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(content)
        print('修改成功(LF)')
    else:
        print('未找到匹配内容')
        # 打印附近内容用于调试
        idx = content.find('certificateSummary(_ health')
        if idx >= 0:
            print(repr(content[idx:idx+300]))
