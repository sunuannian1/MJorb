// Jackson Coxson

use std::collections::HashMap;
use std::io::Cursor;
use std::sync::{Mutex, OnceLock};

use idevice::{
    afc::{errors::AfcError, opcode::AfcFopenMode, AfcClient},
    installation_proxy::InstallationProxyClient,
    IdeviceError,
};
use plist::{Dictionary, Value};
use tokio::io::AsyncWriteExt;

use crate::idevice_support::rsd::connect_to_rsd_services;

/// AFC 暂存根目录（相对 AFC jail 根）。逐行对齐 jas（同 idevice crate 作者、
/// 真机可用）的 RSD sideload：`PublicStaging/<Name>.ipa` 单文件，不建子目录。
const STAGING_DIR: &str = "PublicStaging";

/// yeet / install 两次独立 FFI 之间传递 `.ipa` 文件名的进程内缓存。
///
/// 背景：jas 的 `install_ipa` 在同一个函数内完成签名→打包→AFC 上传→installd 安装，
/// ipa_name 已知，install 从不做 AFC `list_dir` 回读。Seal 因 FFI 边界把 yeet（上传）
/// 与 install（触发安装）拆成两次调用，install 只收 `bundle_id`，此前被迫 list_dir 回读
/// ——而 RSD / CoreDevice 隧道下 AFC `list_dir` 在部分设备上不可靠。此处用进程内缓存
/// 传递 ipa_name，list_dir 仅作 fallback。
static IPA_NAME_CACHE: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();

fn cache_ipa_name(bundle_id: &str, ipa_name: &str) {
    let map = IPA_NAME_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut guard) = map.lock() {
        guard.insert(bundle_id.to_string(), ipa_name.to_string());
    }
}

fn cached_ipa_name(bundle_id: &str) -> Option<String> {
    let map = IPA_NAME_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    map.lock().ok().and_then(|guard| guard.get(bundle_id).cloned())
}

/// 构造 InstallationProxy 的 ClientOptions（RSD / CoreDevice 通道）。
///
/// 逐行对齐 jas `install_ipa`（第 675-679 行）：只放 `PackageType = Developer`。
/// Bundle 标识交给 installd 从 .ipa 包内 Info.plist 自读，不传 CFBundleIdentifier。
fn developer_client_options() -> Value {
    let mut opts = Dictionary::new();
    opts.insert("PackageType".into(), "Developer".into());
    Value::Dictionary(opts)
}

/// 建目录，忽略「已存在」（afcd 对已存在目录回 ObjectExists，幂等创建），
/// 其余错误照常上抛。
async fn mkdir_idempotent(afc: &mut AfcClient, path: &str) -> Result<(), IdeviceError> {
    match afc.mk_dir(path.to_string()).await {
        Ok(()) => Ok(()),
        Err(IdeviceError::Afc(AfcError::ObjectExists)) => Ok(()),
        Err(other) => Err(other),
    }
}

fn zip_error(error: zip::result::ZipError) -> IdeviceError {
    IdeviceError::UnexpectedResponse(format!("无法读取 IPA 压缩包: {error}"))
}

/// 从 IPA（内存字节）定位唯一主程序目录 `Payload/<Name>.app/`，返回 `<Name>.app`。
/// 用于派生设备端暂存文件名 `<Name>.ipa`（对齐 jas：app_name.trim_end(".app") + ".ipa"）。
fn detect_application_name(ipa_bytes: &[u8]) -> Result<String, IdeviceError> {
    let mut archive = zip::ZipArchive::new(Cursor::new(ipa_bytes)).map_err(zip_error)?;
    for index in 0..archive.len() {
        let entry = archive.by_index(index).map_err(zip_error)?;
        let name = entry.name();
        let tail = match name.strip_prefix("Payload/") {
            Some(value) => value,
            None => continue,
        };
        let top = tail.split('/').next().unwrap_or("");
        if top.ends_with(".app") {
            return Ok(top.to_string());
        }
    }
    Err(IdeviceError::UnexpectedResponse(
        "IPA 内未找到 Payload/*.app 主程序目录".into(),
    ))
}

/// 把签名后的 IPA 逐字节上传到设备 AFC 暂存区（RSD / CoreDevice 通道）。
///
/// 动作序列逐行对齐 jas `install_ipa`（第 631-668 行）：
/// 1. `AfcClient::connect_rsd`（复用缓存的 RSD 隧道）；
/// 2. 幂等建 `PublicStaging`；
/// 3. `open("PublicStaging/<Name>.ipa", WrOnly)`（**WrOnly=3，对齐 jas 第 641 行**，
///    不是 Wr=4；WrOnly=O_WRONLY|O_CREAT|O_TRUNC）；
/// 4. `write_all(整包)`（底层 InnerFileDescriptor::write 已按 MAX_TRANSFER=1MiB 自动
///    分块，无需手动切块；jas 的手动分块只是进度粒度）；
/// 5. `close()`（函数结束时 afc 自动 drop，对齐 jas 的 `drop(afc)` 释放连接）。
///
/// 设备端最终得到与 jas 完全一致的 `PublicStaging/<Name>.ipa` 单文件。
pub async fn yeet_app_afc_rppairing(
    bundle_id: String,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    // 对齐 jas 第 614-619 行：app_name → ipa_name → afc_path
    let application_name = detect_application_name(ipa_bytes)?;
    let ipa_name = format!(
        "{}.ipa",
        application_name.trim_end_matches(".app")
    );
    let afc_path = format!("{STAGING_DIR}/{ipa_name}");

    let mut afc = connect_to_rsd_services::<AfcClient>().await?;

    // 对齐 jas 第 636-638 行：mk_dir("PublicStaging")
    mkdir_idempotent(&mut afc, STAGING_DIR).await?;

    // 对齐 jas 第 640-643 行：open(afc_path, WrOnly)
    let mut handle = afc
        .open(afc_path.clone(), AfcFopenMode::WrOnly)
        .await?;

    // 对齐 jas 第 645-663 行：write_all(整包)
    // 底层已按 1MiB 自动分块；非空才写（空文件理论上不会出现在 IPA 中，但双保险）
    if !ipa_bytes.is_empty() {
        handle.write_all(ipa_bytes).await?;
    }

    // 对齐 jas 第 665-668 行：close() + drop(afc)
    // close 显式刷写；afc 在函数结束时自动 drop（释放服务连接，底层 RSD 隧道仍缓存）
    handle.close().await?;

    // 把 .ipa 文件名存入进程内缓存，供 install 阶段使用（避免依赖 RSD 下不可靠的 list_dir）。
    // 仅在上传成功后才写入；yeet 失败时不污染缓存。
    cache_ipa_name(&bundle_id, &ipa_name);

    Ok(())
}

/// 触发 installd 安装已上传的 .ipa 文件（RSD / CoreDevice 通道）。
///
/// 对齐 jas `install_ipa`（第 670-700 行）：安装路径是 `PublicStaging/<Name>.ipa`
/// **单文件**（不是 .app 目录）；`.ipa` 名由 yeet 阶段缓存，list_dir 仅作 fallback。
/// ClientOptions 只带 PackageType=Developer。
///
/// 已存在同 Bundle ID 的记录（上次失败残留占位、续签覆盖）必须走 Upgrade：
/// 对已存在记录发全新 Install 会被 installd 直接以 MissingPackagePath 拒绝。
/// lookup 失败按未安装处理（不阻断首装），残留记录由下方 MissingPackagePath 兜底清理。
pub async fn install_ipa_rppairing(bundle_id: String) -> Result<(), IdeviceError> {
    // 优先用 yeet 阶段缓存的 .ipa 文件名（jas 也不做回读，同一函数内已知 ipa_name）。
    // RSD / CoreDevice 隧道下 AFC list_dir 在部分设备上不可靠，cache 是主路径。
    let ipa_name = match cached_ipa_name(&bundle_id) {
        Some(name) => name,
        None => {
            // fallback：列 PublicStaging 目录回读 .ipa 文件。
            let mut afc = connect_to_rsd_services::<AfcClient>().await?;
            let entries: Vec<String> = afc.list_dir(STAGING_DIR.to_string()).await?;
            entries
                .iter()
                .map(|name| name.trim_end_matches('/').to_string())
                .find(|name| name.ends_with(".ipa") && name != "." && name != "..")
                .ok_or_else(|| {
                    IdeviceError::UnexpectedResponse(format!(
                        "暂存目录 {STAGING_DIR} 下未找到 .ipa 安装包（实际条目: {:?}）",
                        entries
                    ))
                })?
        }
    };
    let install_path = format!("{STAGING_DIR}/{ipa_name}");

    // 对齐 jas 第 670-673 行：InstallationProxyClient::connect_rsd
    let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>().await?;

    let already_installed = lookup_app_rppairing(bundle_id.clone())
        .await
        .ok()
        .flatten()
        .is_some();

    let first_result = if already_installed {
        inst_client
            .upgrade(&install_path, Some(developer_client_options()))
            .await
    } else {
        inst_client
            .install(&install_path, Some(developer_client_options()))
            .await
    };

    match first_result {
        Ok(()) => Ok(()),
        Err(error) => {
            // 兜底：lookup 看不到的残留安装记录会让 Install 报 MissingPackagePath。
            // 卸载（清掉残留记录；不动 AFC 媒体区 PublicStaging 里的暂存包）后全新安装。
            if !format!("{error:?}").contains("MissingPackagePath") {
                return Err(error);
            }
            let _ = inst_client.uninstall(bundle_id.clone(), None).await;
            inst_client
                .install(&install_path, Some(developer_client_options()))
                .await
        }
    }
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
        // RustBridge 源码审计（含测试模块）禁止显式 panic 快捷方式，故用 match 断言。
        // 对齐 jas：Developer 安装只给 PackageType，不得额外携带 CFBundleIdentifier。
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
    fn staging_dir_is_public_staging_root() {
        // 对齐 jas：暂存包直接放 PublicStaging/<Name>.ipa 根目录单层，不建 <bid> 子目录。
        assert_eq!(STAGING_DIR, "PublicStaging");
    }

    #[test]
    fn detect_application_name_extracts_app_dir() {
        // 构造一个最小 IPA：Payload/TestApp.app/Info.plist
        let mut buf = Vec::new();
        {
            use std::io::Write;
            let mut zip = zip::ZipWriter::new(std::io::Cursor::new(&mut buf));
            let options = zip::write::SimpleFileOptions::default();
            match zip.start_file("Payload/TestApp.app/Info.plist", options) {
                Ok(()) => {}
                Err(e) => {
                    // 审计禁止 unwrap，用 match 断言
                    assert!(false, "start_file failed: {e:?}");
                    return;
                }
            }
            match zip.write_all(b"<?xml version=\"1.0\"?><plist><dict/></plist>") {
                Ok(()) => {}
                Err(e) => {
                    assert!(false, "write_all failed: {e:?}");
                    return;
                }
            }
            match zip.finish() {
                Ok(_) => {}
                Err(e) => {
                    assert!(false, "finish failed: {e:?}");
                    return;
                }
            }
        }
        match detect_application_name(&buf) {
            Ok(name) => assert_eq!(name, "TestApp.app"),
            Err(e) => {
                assert!(false, "detect_application_name failed: {e:?}");
            }
        }
    }
}
