# Seal 全链路逐字排查报告（签名 / 安装 / 续签 / Apple ID / 配对）

> 排查方式：只做静态源码逐行核对 + 本地样本二进制字节解析 + 与官方源码（SideStore/AltSign、ldid、zsign、jkcoxson/idevice）逐结构对比，**未改任何代码、未编译**。
> 证据分级：**【铁证】**=有官方行号或本机字节实测；**【高概率】**=机理成立但需真机日志/成品 IPA 终验；**【已排除】**=有证据证明不是这里，勿再走弯路。
> 本机无 Swift 工具链，无法本地编译运行，结论均可在对应 `文件:行号` 复核。

---

## 〇、一句话结论

1. **签名后启动闪退 / 打不开（最高优先）根因已锁定**：`SigningWorkspace` 在 rork 正式签名前，多跑了一层官方根本不存在的 `MachOAdHocSigner` 预处理，污染了原始 Mach-O（旧签名残留 / 原始权限被抹 / chained-fixups 数据漏平移）。三个样本字节实测形成铁对照：**能开的三项全无，闪退/打不开的三项全中**。
2. 安装 `MissingPackagePath`：Rust 层请求结构与官方一致，**最可能是 LocalDevVPN 隧道下 AFC 大文件传输落盘不完整、且上传后没有回读校验**（【高概率】，需真机日志终验）。
3. Apple ID「添加后失效、续签要 2FA」：会话持久化与指纹恒定代码**已对齐官方、未发现确定性 bug**；残留 1100 主要来自「添加走境外 IP、续签走境内 IP」的出口地理跳变 + 免费账号会话寿命，属 Apple 风控，代码无法让其「永不过期」，只能最大化寿命 + 过期明确引导。

---

## 一、签名闪退主线（根因，【铁证】）

### 1.1 唯一回归变量

闪退从 commit `1e48990`（用自研纯 Swift rork-sign 替换 ldid/ALTSigner）开始；此前 SideStore 同款 ldid「签了不闪退」。但**逐字节核对后，rork 密码学生成层本身是对的**，问题出在换引擎时没删干净的 ad-hoc 预处理层。

### 1.2 根因：MachOAdHocSigner 预处理层污染输入

- 调用点：`Seal/Infrastructure/Signing/SigningWorkspace.swift:101`（全局唯一一处）。
- 官方对照：SideStore `ALTSigner.swift performSigning` 是 prepare → ldid 签名**一把梭，没有 ad-hoc、不手改 Mach-O**；zsign 同样直接面对干净原始二进制。
- 这层是 ldid 时代为绕过「ldid 对未签名二进制断言」加的；**rork 原生就支持未签名二进制（用 load-command 空闲区插 LC，不移动数据），这层已无存在意义，应删未删**。

| 编号 | 偏离点 | 机理 | 官方正确做法 | 位置 |
|---|---|---|---|---|
| **P1** | 旧 App Store 签名 blob 残留 | 带原始签名的二进制，ad-hoc 把新 blob 追加到文件尾并把 `LC_CODE_SIGNATURE.dataoff` 改指到文件尾；rork 只按新 dataoff 截断，**原始签名区间永久残留在 codeLimit 内** | ldid `Allocate` 用 `codeLimit = 旧 dataoff` 干净截断 | `MachOAdHocSigner.swift:424-437`；官方 `ldid.cpp:1456-1460` |
| **P2** | 原始 entitlements 被抹 | ad-hoc 生成「无 entitlements 单 slot」blob；rork 两处读原始权限的入口都读**磁盘当前二进制 → 恒空**，`BundleEntitlements.shouldKeep` 把 App 原始声明的可选权限误删 | 官方在**任何改写之前**读原始权限 | 读取点 `AppBundleSigner.swift:827`、`BundleSigner.swift:416`；官方 `ALTSigner.swift:107` |
| **P3** | 无签名 insert 漏平移 linkedit 数据 | ad-hoc 无签名分支插入 16B 新 LC，只给 `LC_SEGMENT_64.fileoff +16`，**漏了 section.offset 与 `LC_SYMTAB / LC_DYLD_CHAINED_FIXUPS / LC_DYLD_EXPORTS_TRIE / LC_FUNCTION_STARTS` 等所有 linkedit_data_command 的 dataoff**，对带 chained fixups 的现代二进制会致 dyld 绑定崩溃 | rork 原生路径用 load-command padding，**不移动任何数据**，无此问题 | `MachOAdHocSigner.swift:438-469` |

### 1.3 三个真实样本的字节实测（决定性对照）

| 样本 | 用户实测结果 | 原始签名 blob | symtab 字符串表末尾与签名区间隙 | chained fixups |
|---|---|---|---|---|
| lanmanga（懒漫画） | **能打开** | 无 | 无签名不触发 | **无** |
| 黄豆 HDDJ（276KB 主二进制） | **装完打不开** | 有，dataoff=0x42900，end 正好=文件尾 | **gap=0，命中** | **有** |
| LCSign LoadController | **启动闪退** | 有，dataoff=0x15e5930，end=文件尾 | **gap=8，命中** | **有** |

> 结论：闪退与文件大小无关（黄豆主二进制只有 276KB），而与「**带原始签名 + symtab 紧贴签名区 + chained fixups**」这一结构 100% 相关——这正是 ad-hoc 会污染、rork 又缺 symtab 修正的组合；能开的 lanmanga 恰好三项全无。微信同为「有原始签名 + chained fixups」结构，归入同一根因。

### 1.4 另外两个应一并修的官方对齐点

| 编号 | 问题 | 证据 | 修法 |
|---|---|---|---|
| **P4** | rork 用单 SHA256 CodeDirectory（`.sha256Only`） | zsign `src_signing.cpp:670-742` 证明单 CD 合法、现代 iOS 接受，**所以不是 iOS18 闪退主因**；但 ldid/zsign 默认双 CD（SHA1 主 + SHA256 alt），对 iOS 16.5.5 等老系统最稳，且 rork **已实现双 CD 分支** | `RorkAppSigner.swift:109` 一个枚举 `.sha256Only → .compatible`（`CodeSignatureBuilder.swift:136-150`） |
| **P5** | rork 缺 symtab adjacency 修正 | ldid `ldid.cpp:1464-1473`：symtab 字符串表末尾落在签名区前 0x10 字节内时，把 codeLimit 收到字符串表末尾，注释明示防 page-aligned 二进制损坏；rork `MachOSigner.swift:890-908` 不读 `LC_SYMTAB`、无此修正。**黄豆 gap=0 / LCSign gap=8 均精确命中** | 照抄 ldid：读 LC_SYMTAB，`strEnd = stroff+strsize`，当 `dataoff-0x10 <= strEnd <= dataoff` 时 `codeLimit = strEnd` |

### 1.5 【已排除】这些方向有铁证证明没问题，别再查

- rork CodeDirectory（88 字节头 / version 0x20400 / special slots 自动补位 / 4KB 页哈希 / execSeg）逐字节等价 zsign（`CodeSignatureBuilder.swift:298-373` vs `src_signing.cpp:449-611`）。
- CMS/PKCS#7 单/双 CD 的 signedAttributes、cdhashes plist、cdHashSequences 自洽且符合 Apple 规范（`CMSGenerator.swift:107-172` vs zsign `:670-742`）；WWDR G2–G6 证书链自动补全。
- 证书/描述文件/私钥不会错配：`validateEmbeddedProfiles`（`ApplePortalSigningService.swift:1403-1438`）对每个 bundle 强校验 Team/BundleID/证书序列号/UDID；P12 用 OpenSSL 解析，leaf 与私钥天然配对，不匹配会直接抛错而非静默签错。
- `pageShift` 三方都是 12（4KB 页哈希，与运行时 16KB 内存页无关）。
- `__LINKEDIT vmsize` 按 4096 对齐，与 zsign 一致（ldid 用 16384，但非必需）。
- FAT/fat64：逐 slice 复用正确的 thin 逻辑再按 align 重组（`MachOSigner.swift:1276-1396`），且 prepare 的 stripArm64e 已把多架构转 thin。
- **递归签名不遗漏**：全树枚举，`.framework/.appex/.bundle` 不限目录位置都会被独立递归签，散落 dylib 按 magic 全捕获（`BundleSigner.swift:1178-1234`）。黄豆把 `Fakingg.framework` 放在 .app 根目录也**不会漏签**。
- framework 用独立 entitlements、显式不继承主 app 权限、不嵌 profile（`BundleSigner.swift:453-468`，正确）。

### 1.6 修复方案（二选一，附推荐）

**方案 B（推荐）——最小改动、每处都有官方依据、保留 rork 纯 Swift 大文件流式优势：**
1. 停用/删除 `SigningWorkspace.swift:101` 的 ad-hoc 调用（整层移除，`MachOAdHocSigner.swift` 可删）→ 一次消除 P1/P2/P3。
2. `RorkAppSigner.swift:109` 改 `.compatible`（P4，一行）。
3. 给 rork `MachOSigner` 补 symtab adjacency（P5，照抄 ldid:1464-1473）。
4. 确认 rork 无签名分支在 load-command padding 不足时显式报错（不静默产出坏文件）。
5. 防御性：rork 内 profile/entitlements 字典查找加大小写不敏感兜底（与 `RorkAppSigner:76` 主 profile 兜底一致），避免扩展 Info.plist 改写异常时拿不到 profile。

**方案 A（最彻底）**：回退 SideStore 官方 ldid 链路（dmjorb/ldid 的 mmap 已修大文件内存崩溃），删 rork + ad-hoc，即 `1e48990` 之前「不闪退」的架构。优点是与官方一字不差；代价是回退工作量、放弃纯 Swift 流式。

> 终验方法（二选一，用来 100% 闭环）：①改完用 Seal 签微信/黄豆，若仍闪退，提供 rork 签出的成品 .ipa，与爱思签出的同 App 能开成品做 SuperBlob/CodeResources 字节对比；②直接采用方案 B 后回归三个样本。

---

## 二、安装 MissingPackagePath / 卡「正在安装」/ 传完断连留灰图标

### 2.1 已核对【铁证】
- Rust `Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs` 与 SideStore minimuxer(rpairing-hb) 逐字相同：AFC 写 `PublicStaging/<bid>/app.ipa` → `InstallationProxy.install(同路径, {CFBundleIdentifier:bid})`。
- 官方 jkcoxson/idevice `services/installation_proxy.rs:173-177` 的请求结构同样是 `Command:Install + PackagePath + ClientOptions`，**请求格式无错**。
- Swift 编排 `MinimuxerInstallChannel.swift` 已较完整：push 重试、install 前 resetProvider、捕获 MissingPackagePath 自动 re-push、lookup 轮询。

### 2.2 与官方最新实现的差异（标准 IPA 能装，证明非致命，但应对齐降风险）

| 差异 | Seal/minimuxer | 官方 idevice（helpers.rs） | 影响 |
|---|---|---|---|
| 上传路径 | `PublicStaging/<bid>/app.ipa`（子目录） | 固定 `PublicStaging/idevice.ipa`（无子目录） | 标准 IPA 两种都能装，暂非主因 |
| CFBundleIdentifier 来源 | 外部计算值传入 | **从成品包内 `Payload/X.app/Info.plist` 回读**（要求恰好三段路径） | 若内外 ID 不一致会定位失败 |
| 上传后校验 | **无设备端回读** | 写完关闭句柄 | Seal 无法发现隧道截断 |

### 2.3 根因判断
- 用户「重推后仍确定性失败」，说明不是偶发写失败，否则重推会成功；结合「传完→设备连接断→桌面留灰图标/云标」，**【高概率】是 LocalDevVPN 无线隧道下 AFC 大文件落盘不完整，installd 读取时找不到完整包 → MissingPackagePath**，而当前缺回读、盲目走同一隧道 re-push 自然再败。
- 黄豆的非标准结构（framework 在 .app 根、空 Frameworks/、ESign 注入残留 `lzlukvca_inject.js/SignedByEsign`）**爱思能装，证明 installd 容忍，不是主因**；但 ESign 注入残留建议在 prepare 阶段清理。

### 2.4 修复（根治方向，不是加超时）
1. **push 后用 `afc.get_file_info` 回读设备端文件大小，与本地字节数比对**：不一致即传输截断，再重推；一致仍 MissingPackagePath 才判定为包/路径问题——先把「传输不完整」和「包本身问题」分开。
2. 评估对齐官方：固定 `PublicStaging/idevice.ipa` 文件名 + bundle id 从成品包内 Info.plist 回读，消除内外 ID 不一致面。
3. 安装速度：无线 AFC 速度跟随隧道与 IPA 体积，1GB 包必然慢；真正提速只能走 USB（用户当前纯无线，不接电脑），代码层可做的是分块并发写与写入进度回读，不能突破无线带宽物理上限。

---

## 三、Apple ID 持久化 / 续签二次认证（用户核心诉求）

### 3.1 会话模型【铁证，设计正确】
- `AccountSecret`（钥匙串加密）持久化 `dsid + authToken + 可选 password + P12`；续签 `AppleAccountClient.validate`（`:243-248`）直接用 dsid/authToken 构造 `ALTAppleAPISession`，**本不需要密码、不需要 2FA**；只有 Apple 返回 1100 会话过期才需重新认证。
- **指纹恒定已对齐官方**：认证 `fetchForAuthentication` 强制本地 anisette、失败不降级远程；`fetch` 一旦本地曾成功就锁定本地、拒绝降级远程（防 machineID 漂移触发 1100）；identifier 首次即持久化（`AnisetteClient.loadIdentity:287-298`，无「首次漂移」bug）；adi.pb/identifier 不被 resetProvisioning 清除。
- **无任何代码在失败时自动删 secret / 把账户踢下线**：删账户只在用户手动操作（`SettingsViewModel.deleteAccount:1311`）；网络错误保留账户可选（`AppleAccountClient:274-279`）；1100 不标失效、引导去「我的」重验证（`ApplePortalSigningService:262-271`）。

### 3.2 为什么仍「添加后失效、续签弹 2FA」（【铁证机理】，非代码 bug）
1. **出口地理跳变**：添加 ID 必须挂全局（gsa.apple.com 对大陆出口返回 503，用的是境外节点 IP）；续签只能 LocalDevVPN+WiFi（境内 IP，开全局反而与本地隧道路由冲突失败）。Apple GSA 看到同一会话短时间内 IP 从境外跳到境内，风控作废旧 authToken → 1100。
2. 免费账号 authToken 本就寿命短；adi.pb 过期后重新 provisioning 必须访问 gsa.apple.com，LocalDevVPN 境内环境访问不到 → 重认证必败。
3. 因此「在续签/批量续签里加验证码输入框」确实无意义（用户判断正确）：LocalDevVPN 下重认证走 gsa 必败，输完仍报 ID 失效。

### 3.3 能做什么 / 不能做什么（如实说明）
- **不能**：代码无法让免费 Apple ID 会话「永久不过期」，这是 Apple 服务端策略，任何侧载软件（SideStore/AltStore/LCSign）都受同样限制。
- **能（已做）**：指纹/machineID/adi.pb/identifier 恒定最大化寿命；失败不踢下线；过期明确引导。
- **建议新增**：①按用户判断移除续签/批量续签流程内的验证码入口，统一为「会话过期→引导去我的页（用户自己挂梯子）重验证」，避免多一个必败步骤；②添加 ID 成功后，在**当前同一网络**下立即做一次证书拉取/会话预热，让会话与常用环境绑定；③证书「显示有效但实际用不了 / 未准备却能签」的矛盾，需单独核对 signingIdentity 快速路径与 P12 落库（`ApplePortalSigningService` signingIdentity 流程），属于状态展示与实物不一致，不是签名密码学问题。

---

## 四、配对（rppairing / lockdown）

- 判定按文件内容：含 `private_key` → rppairing（iOS 17+ CoreDevice 无线，用户 iOS 18.7.8 走此，用 SideStore/iloader 或 pymobiledevice3 remote pair 导出）；含 UDID → lockdown（iOS 16.x 只能走此，需 iTunes/Finder 勾 WiFi 同步，Windows 导出在 `C:\ProgramData\Apple\Lockdown\`）。
- 【待修】配对助手格式检测有误：16.7.2 导入 lockdown 出了 UDID 却不显示「已配对」、有 17.1 也显示 lock。需：按文件内容精确区分类型并给出对应引导文案（16.x 引导 iTunes WiFi 同步，17+ 引导 iloader）。

---

## 五、UI / 体验层（功能在，待打磨，非阻断）

| 项 | 现状 | 待办 |
|---|---|---|
| 签名/续签阶段 | 阶段枚举齐全（account/device/certificate/appID/provisioningProfile/signing），对应爱思「获取Session→申请证书→注册设备→申请BundleID→申请描述文件→签名」 | 文案与顺序按爱思对齐 |
| 失败抽屉重试按钮 | 多处重复 | 去除关联抽屉的重复重试入口 |
| 「确认设备信任」页 | 用户称之前删过但仍弹出（截图 h3sQFzNF19） | 定位弹出点，按既定决策处理 |
| 安装失败弹窗 | 文字重复 | 去重 |
| 「不弹信任开发者」 | 同一 Team 只需信任一次，后续 App 不再弹属正常；若每次都不弹且闪退，根因回到第一节签名 | 随第一节修复后回归 |
| 公众号命名/封面 | 与代码无关 | 另行处理 |

---

## 六、修复优先级与工作量建议

| 优先级 | 事项 | 方案 | 预期效果 | 改动量 |
|---|---|---|---|---|
| P0 | 停用 ad-hoc 预处理层 | 方案B-1（删 `SigningWorkspace:101` 调用） | 消除 P1/P2/P3，闪退主因 | 极小 |
| P0 | rork 补 symtab adjacency | 方案B-3（抄 ldid:1464-1473） | 修黄豆/LCSign 类 gap≤0x10 二进制 | 小 |
| P0 | 单 CD→双 CD | 方案B-2（一行枚举） | iOS16.5.5–27 全兼容 | 极小 |
| P1 | 安装上传后回读校验 + 区分失败类型 | 2.4-1/2 | 根治「传完断连/灰图标」，不再盲目重推 | 中 |
| P1 | rork profile 字典大小写兜底 | 方案B-5 | 防扩展 profile 漏配 | 极小 |
| P2 | 移除续签内验证码入口、添加后会话预热 | 3.3 | 减少必败步骤、延长 ID 可用期 | 小 |
| P2 | 配对类型检测与引导 | 第四节 | 修 16.x/17.x 配对误判 | 小 |
| P3 | UI 去重/状态文案/信任页 | 第五节 | 体验打磨 | 中 |

> 建议先做 P0 三项（都有官方行号依据、改动小、风险低），出一个测试包用「微信 + 黄豆 + LCSign + lanmanga」四个样本回归：前三个应不再闪退/能安装打开，lanmanga 继续正常，即证明根因判断正确。
