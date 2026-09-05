// Jackson Coxson

use idevice::{
    afc::{opcode::AfcFopenMode, AfcClient},
    installation_proxy::InstallationProxyClient,
    IdeviceError,
};
use plist::{Dictionary, Value};

use crate::idevice_support::rsd::connect_to_rsd_services;
use tokio::io::AsyncWriteExt;

/// AFC 暂存根目录（相对 AFC jail 根）。包就放在这一层下面，与真机可用的 jas
/// （同一套 idevice crate + CoreDevice RSD）严格一致：只建 `PublicStaging`，
/// 不再自建 `seal` 子目录——CoreDevice 的 installd 只在该暂存根定位 PackagePath。
const STAGING_DIR: &str = "PublicStaging";

/// 某个 Bundle ID 对应的设备端暂存路径（`PublicStaging/<bid>.ipa`，根目录单层）。
/// yeet（push）与 install 是两次独立 FFI 调用，因此路径必须由 bundle_id 确定性
/// 推导，两次调用才能指向同一个文件。
fn staged_ipa_path(bundle_id: &str) -> String {
    format!("{STAGING_DIR}/{bundle_id}.ipa")
}

/// 构造 InstallationProxy 的 ClientOptions（RSD / CoreDevice 通道）。
///
/// 只放 `PackageType = Developer`，**不放 CFBundleIdentifier**——与两个真机可用实现严格对齐：
/// jkcoxson/jas（sideload）与 pymobiledevice3（install_from_local 的 developer=True）在
/// Developer 安装时 ClientOptions 都只含 PackageType。Bundle 标识交给 installd 从包内
/// Info.plist 自读。注意经典 lockdown 通道（LockDownInstall）仍需 CFBundleIdentifier，
/// 两条通道协议不同、不可统一。
fn developer_client_options() -> Value {
    let mut opts = Dictionary::new();
    opts.insert("PackageType".into(), "Developer".into());
    Value::Dictionary(opts)
}

/// 把 IPA 字节上传到设备 AFC 暂存区（RSD / CoreDevice 通道）。
///
/// 动作序列逐行对齐 jas 的 sideload：建 `PublicStaging` → WrOnly 打开暂存包
/// （WrOnly 自带 O_CREAT|O_TRUNC，覆盖写无需先 remove）→ write_all 写入（底层
/// AFC 写已按 1 MiB 自动分块）→ close 落盘 → 关闭这条 AFC。不做额外的二次回读、
/// 不做 shutdown、不预删除、不建子目录。
pub async fn yeet_app_afc_rppairing(
    bundle_id: String,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    let staged_path = staged_ipa_path(&bundle_id);

    let mut afc = connect_to_rsd_services::<AfcClient>().await?;

    // 对齐 jas：直接创建 PublicStaging（iOS afcd 对已存在目录幂等返回成功）。
    afc.mk_dir(STAGING_DIR).await?;

    let mut handle = afc.open(&staged_path, AfcFopenMode::WrOnly).await?;
    handle.write_all(ipa_bytes).await?;
    handle.close().await?;

    Ok(())
}

/// 触发 installd 安装已暂存的包（RSD / CoreDevice 通道）。
///
/// 恒用 Install（对齐 jas 恒 Install、pymobiledevice3 默认 Install）：Install 本身即可
/// 覆盖同一 Bundle ID（续签 / 重装）。Upgrade 按 idevice crate 文档只适用于“确知已完整
/// 安装”的包，安装前 lookup 会把失败灰占位 / offload 残留误判为已存在而错发 Upgrade，
/// 反而 MissingPackagePath。是否已装的校验放到安装后的 verifyInstalled（lookup 保留给它）。
pub async fn install_ipa_rppairing(bundle_id: String) -> Result<(), IdeviceError> {
    let staged_path = staged_ipa_path(&bundle_id);
    let opts = developer_client_options();

    let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>().await?;
    inst_client.install(&staged_path, Some(opts)).await
}

pub async fn remove_app_rppairing(bundle_id: String) -> Result<(), IdeviceError> {
    let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>().await?;

    inst_client.uninstall(bundle_id, None).await
}

pub async fn lookup_app_rppairing(bundle_id: String) -> Result<Option<String>, IdeviceError> {
    let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>().await?;
    let apps = inst_client
        .get_apps(None, Some(vec![bundle_id.clone()]))
        .await?;
    Ok(apps.contains_key(&bundle_id).then_some(bundle_id))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn developer_options_only_carry_package_type() {
        let v = developer_client_options();
        // RustBridge 源码审计（含测试模块）禁止显式 panic 快捷方式，故用 match 断言而非之。
        // 对齐 jas / pymobiledevice3：Developer 安装只给 PackageType，不得额外携带
        // CFBundleIdentifier（避免与包内真实 ID 不一致时被 installd 拒绝）。
        match v.as_dictionary() {
            Some(dict) => {
                assert_eq!(
                    dict.get("PackageType").and_then(|x| x.as_string()),
                    Some("Developer")
                );
                assert!(dict.get("CFBundleIdentifier").is_none());
                assert_eq!(dict.len(), 1);
            }
            None => assert!(false, "options must be a dictionary"),
        }
    }

    #[test]
    fn staged_path_lives_at_staging_root() {
        // 对齐 jas：包直接在 PublicStaging 根下、单层、无子目录；push/install 两次推导一致。
        assert_eq!(staged_ipa_path("com.a.b"), "PublicStaging/com.a.b.ipa");
        assert_eq!(staged_ipa_path("com.a.b"), staged_ipa_path("com.a.b"));
        assert!(!staged_ipa_path("com.a.b").contains("/seal/"));
    }
}
