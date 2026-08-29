# Seal Full Optimization Static Report

生成时间：2026-07-25

## 基线

来源：用户上传 `Seal-current-source.zip`。

## 本源码包状态

- 已做静态修改与 `git diff --check`。
- 已确认 `project.yml` / `Base.xcconfig` 中 deployment target 保持 iOS 16.0。
- 已用 Linux Swift 6.2 对 PairingStore 相关 Foundation-only 文件做语法解析烟测。
- 未运行 Xcode 26.5。
- 未运行 GitHub Actions。
- 未做真机验证。

## 合入内容

### P2 永久配对 + 状态模型分离

- 已配对后，`markValidating()` / `markPendingValidation()` 不再降级已验证配对。
- 已配对后，运行时连接到不同 UDID 会拒绝，但不会覆盖已保存绑定。
- Minimuxer 设备匹配优先使用 `PairingRecord.effectiveDeviceIdentifier`。
- 补充 PairingStore 回归测试。

### P3 signOnly / InstallChannel 解耦

- `InstallChannel` 增加 `storedDeviceIdentifier()`。
- `signOnly` 使用已保存配对 UDID，不再启动安装通道。
- `beginSigning(... completionMode: .signOnly)` 不再提前刷新安装通道。

### P4 启动检查与连接恢复

- Root 启动检查增加 60 秒去重，避免前台频繁重复探测。
- LocalDevVPN callback 仅在存在待恢复动作时切回 Apps。

### P5 LocalDevVPN 透明 fallback

- 安装通道失败时保留 pending recovery。
- 恢复提示改为面向用户的“需要恢复连接”。

### P6 「我的」页面收口

- 签名环境主区仅保留：设备 / Apple ID / 签名证书。
- LocalDevVPN 与一键检测不再作为普通主入口。
- 外观选择器改成轻量胶囊式：跟随系统 / 浅色 / 深色，系统蓝 #007AFF。

### P7 Apple ID / Certificate 去重

- 证书对外显示统一为 `Apple Development`。
- 避免在主流程显示 `Seal-<serial suffix>`。

### P8 Apps 页面 + 文案 + 假进度

- 签名进度移除伪百分比与固定进度条。
- 阶段文案改为更准确的：准备设备、验证 Apple ID、准备证书、准备 App ID、准备描述文件、正在签名、正在安装、正在验证安装。

### P11 IPA 文件 I/O 性能

- SHA-256 改为 1MB 分块流式计算，避免一次性映射/读取整个 IPA 进行哈希。

## 未声明完成的部分

P9 Apple 官方签名 Fast Path 与 P10 批量续签优化涉及真实 Apple Portal、profile、certificate 与真机安装链路；本包只做低风险静态收口，没有声称完成线上/真机验证。

## 你需要执行的验证

```bat
cd /d C:\Users\DMJ\Desktop\Seal

git diff --check

git add -A

git commit -m "full optimization static source package"

git push
```

GitHub Actions 绿后，再做真机验证。
