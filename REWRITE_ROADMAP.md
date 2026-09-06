# Seal 重写路线图（签名 / 安装 / 续签）

> 目标：用成熟、经过大规模验证的技术栈替换自研的脆弱链路。
> 原则：每期完成后独立可用、可回退，与现有链路并存做双保险。

## 现状问题（真机日志定位）

| 环节 | 问题 | 根因 |
|---|---|---|
| 安装（RSD shim 通道） | MissingPackagePath | shim AFC（`*.shim.remote`）的视图是临时的：写入的暂存包 installd 完全不可见，目录内容会自行消失 |
| 安装（CoreDeviceProxy） | ConnectionReset | devicecompute 服务在 WiFi/RSD 通道上硬重置连接（独占连接+重试均无效） |
| Apple ID / 续签 | 503 | 国内直连 gsa.apple.com 线路时通时断 + 反复重置触发的设备级临时标记 |

## 第一期（已完成）：OTA 本地安装——绕开全部自建安装链路

签名完成后不再把包推给 installd，改由 **iOS 系统安装器接管**：

```
签名完成 → 内嵌 HTTPS 服务器（127.0.0.1，Rust rustls + rcgen 自签证书）
  → /manifest.plist + /app.ipa（itms-services 清单）
  → itms-services:// 协议调起系统安装
```

- 零外部依赖：服务器跑在手机里，飞行模式下也能安装
- 一次性引导：文件 App 安装 `SealCA.mobileconfig` + 证书信任设置开启完全信任（约 30 秒）
- 隧道路径保留为后备（设置开关 `SealOTA.enabled`）
- 已知边界：安装执行阶段零报错；安装期间隧道断连不影响结果（installd 本地执行，见
  `install_via_core_tunnel` 的安装后查证逻辑）

代码：
- `Vendor/Minimuxer/RustBridge/src/ota_server.rs`（rustls HTTPS 服务器 + rcgen 证书生成）
- `Seal/Infrastructure/Installation/OtaInstallService.swift`（编排：身份/清单/服务器/调起）
- `SigningCoordinator.installSignedArtifact`（OTA 优先，隧道回退；CA 引导错误直达用户）

## 第二期：签名加固（zsign 核心 + IPA 结构处理）

现状：签名走 ALTSign（rust sign_app），本身稳定；问题是**兼容性长尾**
（特殊 entitlements/插件/二进制形态的 App 在 ALTSign 上偶发失败）。

计划：
1. **进程内引入 zsign 核心**（C++ → 静态库，OpenSSL 复用 AltSign 的
   OpenSSL-Universal xcframework）：
   - CMS/CodeDirectory 签名（对齐 zsign 的 -z 流程）
   - entitlements 注入/改写（支持受管/非受管形态）
   - 多 arch（arm64/armv7 遗留）与 extension 全覆盖签名
   - C FFI：`zsign_sign(ipa_in, ipa_out, cert_pem, key_pem, provision, entitlements)`
2. **ZIPFoundation 重写 IPA 结构处理**：
   - 解包（保留 entry 顺序/压缩参数，修复中文名编码）
   - 重打包（确定性输出，避免 shim AFC 对非 ASCII/大文件的问题）
   - 与 SignedArtifactValidator 合并做签名前后双验证
3. 双签名器并存：zsign 失败自动回退 ALTSign，报错带签名器标识

里程碑验收：黄豆短剧/微信/企业微信等历史失败样本全部可签可装。

## 第三期：二进制处理与注入（MachOKit / optool / ellekit）

1. **MachOKit**（已加入依赖）：MachO 解析
   - 架构列表 / LC 码签名段检查 / embedded entitlements 提取
   - `MachOInspector` 模块输出到签名前校验与日志
2. **optool 对齐**：二进制注入（insert_dylib）与 remove-provision 改写
3. **ellekit / TrollFools 对齐**：dylib 注入产品的完整化（依赖第二期 zsign 重签）
4. UI：注入管理面板（选择 tweak dylib → 注入 → 重签 → OTA 安装）

## 已知不可消除的限制（Apple 政策/环境，任何工具相同）

- 免费证书 7 天有效期：续签必须连 Apple 服务器
- gsa.apple.com 国内直连时通时断：503 自动重试已内置（3s/8s 间隔），持续 503 需梯子或等冷却
- 免费 App ID 上限 10 个 / 单证书 3 台设备
- 手机存储不足、iOS 偶发安装失败：重试可解

## 一次性和日常使用成本

- 零服务器、零域名、零费用（OTA 服务器内嵌于 App，127.0.0.1 本机回环）
- 首次 OTA 安装需信任本地 CA 描述文件（一次性约 30 秒）
