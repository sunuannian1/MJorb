// Jackson Coxson

use std::collections::HashMap;
use std::io::{Cursor, Read};
use std::sync::{Mutex, OnceLock};

use idevice::{
    afc::{errors::AfcError, opcode::AfcFopenMode, AfcClient},
    installation_proxy::InstallationProxyClient,
    IdeviceError,
};
use plist::{Dictionary, Value};
use tokio::io::AsyncWriteExt;

use crate::idevice_support::rsd::connect_to_rsd_services;

/// AFC 暂存根目录（相对 AFC jail 根）。对齐 SideStore/minimuxer 真机 on-device 实现
/// （`MinimuxerConstants.pkgPath = "PublicStaging"`）。
const STAGING_DIR: &str = "PublicStaging";

/// yeet / install 两次独立 FFI 之间传递 `.app` 目录名的进程内缓存。
///
/// 背景：官方 SideStore/minimuxer 的 `syncsendAppBundleAfc` 与 `syncInstallAppBundle`
/// 在同一个 Swift 函数内先后调用，appName 已知，install 从不做 AFC `list_dir` 回读。
/// Seal 因 FFI 边界把 yeet（铺目录）与 install（触发安装）拆成两次调用，install 只收
/// `bundle_id`，此前被迫 `list_dir` 回读 .app 名——而 RSD / CoreDevice 隧道下 AFC
/// `list_dir` 对目录条目的返回在部分设备上不可靠（条目缺失或带尾部斜杠），导致
/// "暂存目录下未找到 .app 主程序"。此处用进程内缓存传递 appName，list_dir 仅作 fallback。
static APP_NAME_CACHE: OnceLock<Mutex<HashMap<String, String>>> = OnceLock::new();

fn cache_app_name(bundle_id: &str, app_name: &str) {
    let map = APP_NAME_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Ok(mut guard) = map.lock() {
        guard.insert(bundle_id.to_string(), app_name.to_string());
    }
}

fn cached_app_name(bundle_id: &str) -> Option<String> {
    let map = APP_NAME_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    map.lock().ok().and_then(|guard| guard.get(bundle_id).cloned())
}

/// 某个 Bundle ID 对应的设备端暂存目录：`PublicStaging/<bid>`。
/// 官方在其下铺一个与 IPA 内同名的 `<Name>.app` 目录树，再让 installd 安装该目录。
fn bundle_staging_dir(bundle_id: &str) -> String {
    format!("{STAGING_DIR}/{bundle_id}")
}

/// 构造 InstallationProxy 的 ClientOptions（RSD / CoreDevice 通道）。
///
/// 逐行对齐 SideStore/minimuxer `syncInstallAppBundle`：只放 `PackageType = Developer`。
/// Bundle 标识交给 installd 从铺好的 .app 包内 Info.plist 自读，不传 CFBundleIdentifier。
fn developer_client_options() -> Value {
    let mut opts = Dictionary::new();
    opts.insert("PackageType".into(), "Developer".into());
    Value::Dictionary(opts)
}

/// 建目录，忽略「已存在」（官方 Swift 端直接丢弃 afc_make_directory 的返回值），
/// 其余错误照常上抛，保证逐级幂等创建。
async fn mkdir_idempotent(afc: &mut AfcClient, path: &str) -> Result<(), IdeviceError> {
    match afc.mk_dir(path.to_string()).await {
        Ok(()) => Ok(()),
        Err(IdeviceError::Afc(AfcError::ObjectExists)) => Ok(()),
        Err(other) => Err(other),
    }
}

/// 沿 `/` 逐级创建目录（每一级都幂等），不依赖压缩包是否显式包含目录条目。
async fn ensure_directory_chain(afc: &mut AfcClient, remote_dir: &str) -> Result<(), IdeviceError> {
    let mut current = String::new();
    for part in remote_dir.split('/') {
        if part.is_empty() {
            continue;
        }
        if !current.is_empty() {
            current.push('/');
        }
        current.push_str(part);
        mkdir_idempotent(afc, &current).await?;
    }
    Ok(())
}

fn zip_error(error: zip::result::ZipError) -> IdeviceError {
    IdeviceError::UnexpectedResponse(format!("无法读取 IPA 压缩包: {error}"))
}

fn io_error(error: std::io::Error) -> IdeviceError {
    IdeviceError::UnexpectedResponse(format!("读取 IPA 条目失败: {error}"))
}

/// 压缩包内待铺设条目的种类。
#[derive(Clone, Copy, PartialEq, Eq)]
enum EntryKind {
    Directory,
    File,
    /// 符号链接不铺到设备（签名阶段已拒绝输入含 symlink，这里是双保险）。
    Symlink,
}

/// 从 IPA（内存字节）定位唯一主程序目录 `Payload/<Name>.app/`，返回其前缀与 `<Name>.app`。
fn detect_application(ipa_bytes: &[u8]) -> Result<(String, String), IdeviceError> {
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
            let application_name = top.to_string();
            let prefix = format!("Payload/{application_name}/");
            return Ok((prefix, application_name));
        }
    }
    Err(IdeviceError::UnexpectedResponse(
        "IPA 内未找到 Payload/*.app 主程序目录".into(),
    ))
}

/// 把 IPA 内的主程序解包并逐文件铺到设备 AFC 暂存区（RSD / CoreDevice 通道）。
///
/// 动作序列逐行对齐 SideStore/minimuxer on-device 的 `syncsendAppBundleAfc`：
/// 1. 幂等建 `PublicStaging`，清掉同 Bundle ID 的旧暂存后建 `PublicStaging/<bid>`；
/// 2. 遍历 IPA 内 `Payload/<Name>.app/**`：逐级建子目录；每个文件用 `Wr`(=4,
///    O_RDWR|O_CREAT|O_TRUNC) 打开、写入整文件、关闭；空文件只开/关创建、不写；
/// 3. 流式处理：同一时刻只把「单个文件」读入内存，避免 400MB+ 大包整体驻留。
///
/// 设备端最终得到与官方完全一致的 `PublicStaging/<bid>/<Name>.app/...` 目录树。
pub async fn yeet_app_afc_rppairing(
    bundle_id: String,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    let (app_prefix, application_name) = detect_application(ipa_bytes)?;

    // 第一遍：建立铺设计划（索引 + 设备端相对路径 + 种类），不读文件内容。
    let mut planned: Vec<(usize, String, EntryKind)> = Vec::new();
    {
        let mut archive = zip::ZipArchive::new(Cursor::new(ipa_bytes)).map_err(zip_error)?;
        for index in 0..archive.len() {
            let entry = archive.by_index(index).map_err(zip_error)?;
            let name = entry.name().to_string();
            let is_directory = entry.is_dir();
            let is_symlink = entry
                .unix_mode()
                .map(|mode| mode & 0o170000 == 0o120000)
                .unwrap_or(false);
            drop(entry);

            let relative = if name == app_prefix.trim_end_matches('/')
                || name == app_prefix
            {
                application_name.clone()
            } else {
                match name.strip_prefix(&app_prefix) {
                    Some(tail) if !tail.is_empty() => {
                        format!("{application_name}/{tail}")
                    }
                    _ => continue,
                }
            };
            // 压缩包里目录条目名常以 `/` 结尾，归一去掉，便于统一推导。
            let relative = relative.trim_end_matches('/').to_string();
            let kind = if is_symlink {
                EntryKind::Symlink
            } else if is_directory {
                EntryKind::Directory
            } else {
                EntryKind::File
            };
            planned.push((index, relative, kind));
        }
    }

    let bundle_dir = bundle_staging_dir(&bundle_id);
    let mut afc = connect_to_rsd_services::<AfcClient>().await?;

    mkdir_idempotent(&mut afc, STAGING_DIR).await?;
    // 覆盖安装/续签前清掉同 Bundle ID 旧暂存目录，避免旧版本残留文件污染；
    // 暂存尚不存在时 afcd 返回 ObjectNotFound，属正常。
    match afc.remove_all(bundle_dir.clone()).await {
        Ok(()) => {}
        Err(IdeviceError::Afc(AfcError::ObjectNotFound)) => {}
        Err(other) => return Err(other),
    }
    mkdir_idempotent(&mut afc, &bundle_dir).await?;

    // 第二遍：按计划逐目录/逐文件铺设。
    for (index, relative, kind) in planned {
        let remote_path = format!("{bundle_dir}/{relative}");
        match kind {
            EntryKind::Symlink => continue,
            EntryKind::Directory => {
                ensure_directory_chain(&mut afc, &remote_path).await?;
            }
            EntryKind::File => {
                if let Some(parent) = remote_path.rsplit_once('/').map(|(dir, _)| dir) {
                    ensure_directory_chain(&mut afc, parent).await?;
                }
                // 先把这一个文件读入内存（读完即释放对 archive 的借用）。
                let mut contents = Vec::new();
                {
                    let mut archive =
                        zip::ZipArchive::new(Cursor::new(ipa_bytes)).map_err(zip_error)?;
                    let mut entry = archive.by_index(index).map_err(zip_error)?;
                    entry.read_to_end(&mut contents).map_err(io_error)?;
                }

                // 对齐官方：Wr(=4) 打开（自带创建+截断），非空才写，随后关闭。
                let mut handle = afc
                    .open(remote_path.clone(), AfcFopenMode::Wr)
                    .await?;
                if !contents.is_empty() {
                    handle.write_all(&contents).await?;
                }
                handle.close().await?;
            }
        }
    }

    // 把 .app 目录名存入进程内缓存，供 install 阶段使用（避免依赖 RSD 下不可靠的 list_dir 回读）。
    // 仅在所有文件铺设成功后才写入；yeet 失败时不污染缓存。
    cache_app_name(&bundle_id, &application_name);

    Ok(())
}

/// 触发 installd 安装已铺设好的 .app 目录（RSD / CoreDevice 通道）。
///
/// 对齐 SideStore/minimuxer `syncInstallAppBundle`：安装路径是
/// `PublicStaging/<bid>/<Name>.app` **目录**（不是 .ipa 文件）；`.app` 名由 yeet 阶段
/// 铺就，这里列暂存目录读回（yeet/install 是两次独立 FFI，install 只收 bundle_id）。
/// ClientOptions 只带 PackageType=Developer。恒用 Install，Install 本身可覆盖同 Bundle ID。
pub async fn install_ipa_rppairing(bundle_id: String) -> Result<(), IdeviceError> {
    let bundle_dir = bundle_staging_dir(&bundle_id);

    // 优先用 yeet 阶段缓存的 .app 目录名（官方 SideStore 也不做回读，同一函数内已知 appName）。
    // RSD / CoreDevice 隧道下 AFC list_dir 在部分设备上不可靠，cache 是主路径。
    let application_name = match cached_app_name(&bundle_id) {
        Some(name) => name,
        None => {
            // fallback：列暂存目录回读。trim 尾部斜杠后再匹配 .app；
            // 错误信息列出实际条目，便于诊断。
            let mut afc = connect_to_rsd_services::<AfcClient>().await?;
            let entries: Vec<String> = afc.list_dir(bundle_dir.clone()).await?;
            entries
                .iter()
                .map(|name| name.trim_end_matches('/').to_string())
                .find(|name| name.ends_with(".app") && name != "." && name != "..")
                .ok_or_else(|| {
                    IdeviceError::UnexpectedResponse(format!(
                        "暂存目录 {bundle_dir} 下未找到 .app 主程序（实际条目: {:?}）",
                        entries
                    ))
                })?
        }
    };
    let install_path = format!("{bundle_dir}/{application_name}");

    let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>().await?;
    inst_client
        .install(&install_path, Some(developer_client_options()))
        .await
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
        // 对齐 SideStore on-device：Developer 安装只给 PackageType，不得额外携带
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
    fn staging_directory_is_keyed_by_bundle_id() {
        // 对齐 SideStore：每个 Bundle ID 独立暂存目录 PublicStaging/<bid>，其下铺 <Name>.app。
        assert_eq!(
            bundle_staging_dir("com.a.b"),
            "PublicStaging/com.a.b"
        );
        assert_eq!(
            bundle_staging_dir("com.a.b"),
            bundle_staging_dir("com.a.b")
        );
    }
}
