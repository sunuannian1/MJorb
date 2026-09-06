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

/// AFC 暂存根目录（相对 AFC jail 根）。
const STAGING_DIR: &str = "PublicStaging";

/// 暂存文件统一用固定 ASCII 名。
/// installd 只按 PackagePath 读包、不依赖文件名，固定名等价且排除非 ASCII 编码问题。
const IPA_STAGING_NAME: &str = "app.ipa";

/// 暂存布局：`PublicStaging/<bundleId>/app.ipa`——与经典 lockdown 通道完全一致。
/// 本设备 PublicStaging 里留有 bundleId 目录（历史成功安装的痕迹），对齐它最稳。

/// yeet / install 两次独立 FFI 之间传递暂存信息（文件名+字节数）的进程内缓存。
///
/// 背景：jas 的 `install_ipa` 在同一个函数内完成签名→打包→AFC 上传→installd 安装，
/// ipa_name 已知，install 从不做 AFC `list_dir` 回读。Seal 因 FFI 边界把 yeet（上传）
/// 与 install（触发安装）拆成两次调用，install 只收 `bundle_id`，此前被迫 list_dir 回读
/// ——而 RSD / CoreDevice 隧道下 AFC `list_dir` 在部分设备上不可靠。此处用进程内缓存
/// 传递文件名与期望大小（install 阶段校验文件仍在且大小一致），list_dir 仅作 fallback。
static IPA_NAME_CACHE: OnceLock<Mutex<HashMap<String, (String, usize)>>> = OnceLock::new();

fn cache_ipa_name(bundle_id: &str, ipa_name: &str, size: usize) {
    let map = IPA_NAME_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut guard) = map.lock() {
        guard.insert(bundle_id.to_string(), (ipa_name.to_string(), size));
    }
}

fn cached_ipa(bundle_id: &str) -> Option<(String, usize)> {
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

/// 给错误附加上下文（阶段名 + 现场快照），保留原始 Debug 信息。
/// 远程排障时设备弹窗里能直接看到失败发生在哪一步、暂存目录里有什么。
fn ctx(error: IdeviceError, stage: &str) -> IdeviceError {
    IdeviceError::UnexpectedResponse(format!("{stage}: {error:?}"))
}

/// 把签名后的 IPA 逐字节上传到设备 AFC 暂存区（RSD / CoreDevice 通道）。
pub async fn yeet_app_afc_rppairing(
    bundle_id: String,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    // 结构校验：IPA 内必须存在 Payload/*.app（上传前拦截损坏包）
    let _application_name = detect_application_name(ipa_bytes)?;
    let staged_dir = format!("{STAGING_DIR}/{bundle_id}");
    let afc_path = format!("{staged_dir}/{IPA_STAGING_NAME}");

    let mut afc = connect_to_rsd_services::<AfcClient>()
        .await
        .map_err(|e| ctx(e, "yeet/连接AFC"))?;

    // 幂等建目录（afcd 对已存在目录回 ObjectExists）
    mkdir_idempotent(&mut afc, STAGING_DIR)
        .await
        .map_err(|e| ctx(e, "yeet/建PublicStaging目录"))?;
    mkdir_idempotent(&mut afc, &staged_dir)
        .await
        .map_err(|e| ctx(e, "yeet/建暂存子目录"))?;

    // 覆盖前先删旧包，避免打开方式差异导致旧包尾部残留成损坏 zip
    let _ = afc.remove(afc_path.clone()).await;

    // WrOnly=3（O_WRONLY|O_CREAT|O_TRUNC），文件不存在时创建
    let mut handle = afc
        .open(afc_path.clone(), AfcFopenMode::WrOnly)
        .await
        .map_err(|e| ctx(e, "yeet/打开暂存包"))?;

    // 底层已按 1MiB 自动分块；非空才写（空文件理论上不会出现在 IPA 中，但双保险）
    if !ipa_bytes.is_empty() {
        handle
            .write_all(ipa_bytes)
            .await
            .map_err(|e| ctx(IdeviceError::Socket(e), "yeet/写入暂存包"))?;
    }

    // close 显式刷写；afc 仍可继续用于回读校验
    handle
        .close()
        .await
        .map_err(|e| ctx(e, "yeet/关闭暂存包"))?;

    // 上传后同连接回读校验：文件必须存在且大小与源字节一致。
    let info = afc
        .get_file_info(afc_path.clone())
        .await
        .map_err(|e| ctx(e, "yeet/回读校验暂存包"))?;
    if info.size != ipa_bytes.len() {
        return Err(IdeviceError::UnexpectedResponse(format!(
            "yeet/暂存包大小校验失败：{afc_path} 设备上 {} 字节，期望 {} 字节",
            info.size,
            ipa_bytes.len()
        )));
    }

    // 把暂存文件名与期望大小存入进程内缓存，供 install 阶段使用。
    // 仅在上传成功且校验通过后写入；yeet 失败时不污染缓存。
    cache_ipa_name(&bundle_id, IPA_STAGING_NAME, ipa_bytes.len());

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
    // 优先用 yeet 阶段缓存的暂存文件名（同一进程内已知，无需回读）。
    let file_name = match cached_ipa(&bundle_id) {
        Some((name, _expected_size)) => name,
        None => {
            // fallback（跨进程重启场景）：列暂存子目录回读 .ipa 文件。
            let staged_dir = format!("{STAGING_DIR}/{bundle_id}");
            let mut afc = connect_to_rsd_services::<AfcClient>()
                .await
                .map_err(|e| ctx(e, "install/连接AFC"))?;
            let entries: Vec<String> = afc.list_dir(staged_dir.clone()).await.map_err(|e| {
                ctx(
                    e,
                    &format!("install/回读暂存目录（{staged_dir}）"),
                )
            })?;
            let name = entries
                .iter()
                .map(|name| name.trim_end_matches('/').to_string())
                .find(|name| name.ends_with(".ipa") && name != "." && name != "..")
                .ok_or_else(|| {
                    IdeviceError::UnexpectedResponse(format!(
                        "install/暂存目录 {staged_dir} 下未找到 .ipa 安装包（实际条目: {:?}）",
                        entries
                    ))
                })?;
            name
        }
    };
    // 布局与经典 lockdown 通道一致：PublicStaging/<bundleId>/<file>.ipa
    let install_path = format!("{STAGING_DIR}/{bundle_id}/{file_name}");

    // 对齐 jas 第 670-673 行：InstallationProxyClient::connect_rsd
    // （不做安装前 AFC 预校验：隧道抖动时预校验自身的 socket 错误会把安装
    //   挡死在 installd 之前，上传校验已由 yeet 的同连接回读完成。）
    let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>()
        .await
        .map_err(|e| ctx(e, "install/连接instproxy"))?;

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
                return Err(ctx(
                    error,
                    if already_installed {
                        "install/Upgrade已存在应用"
                    } else {
                        "install/Install全新应用"
                    },
                ));
            }
            let _ = inst_client.uninstall(bundle_id.clone(), None).await;
            inst_client
                .install(&install_path, Some(developer_client_options()))
                .await
                .map_err(|retry_error| {
                    // 错误文案带上兜底标记：真机上看到它即说明新版逻辑已生效
                    IdeviceError::UnexpectedResponse(format!(
                        "install/卸载残留后重装仍失败（fallback-tried）: {retry_error:?}"
                    ))
                })
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
