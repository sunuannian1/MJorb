// Jackson Coxson

use idevice::{
    afc::{opcode::AfcFopenMode, AfcClient},
    installation_proxy::InstallationProxyClient,
    IdeviceError,
};
use plist::{Dictionary, Value};

use crate::idevice_support::rsd::connect_to_rsd_services;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// AFC 暂存根目录（相对 AFC 根）。
const STAGING_DIR: &str = "PublicStaging";

/// Seal 专用暂存子目录：每个 Bundle ID 一个独立暂存文件，避免固定单文件被上一次
/// 安装的残留/并发任务污染（对齐 pymobiledevice3 的唯一临时暂存路径策略）。
const STAGING_SUBDIR: &str = "PublicStaging/seal";

/// 回读校验时的分块大小。逐块读取、逐块比对，额外内存恒定，不随 IPA 体积增长。
const VERIFY_CHUNK: usize = 4 * 1024 * 1024;

/// 某个 Bundle ID 对应的设备端暂存路径。yeet（push）与 install 是两次独立 FFI 调用，
/// 因此路径必须由 bundle_id 确定性推导，两次调用才能指向同一文件。
fn staged_ipa_path(bundle_id: &str) -> String {
    format!("{STAGING_SUBDIR}/{bundle_id}.ipa")
}

/// 构造 InstallationProxy 的 ClientOptions。
///
/// 关键（MissingPackagePath 的决定性根因）：侧载的是**开发者包**，RSD/CoreDevice 通道的
/// installd 必须收到 `PackageType = Developer` 才会按开发者安装语义去 AFC 暂存区定位
/// PackagePath；缺省（按 User 包处理）会在定位阶段回 MissingPackagePath。该结论由两个
/// 独立、真机可用的实现交叉验证：idevice 作者本人的 jkcoxson/jas（sideload）与
/// pymobiledevice3（install_from_local(developer=True) 强制 PackageType=Developer）。
/// 同时带 CFBundleIdentifier（官方 idevice helpers 对 .ipa 的要求）以关联目标 App。
fn developer_client_options(bundle_id: &str) -> Value {
    let mut opts = Dictionary::new();
    opts.insert("PackageType".into(), "Developer".into());
    opts.insert("CFBundleIdentifier".into(), bundle_id.to_string().into());
    Value::Dictionary(opts)
}

pub async fn yeet_app_afc_rppairing(
    bundle_id: String,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    let staged_path = staged_ipa_path(&bundle_id);

    // 第一步：在一条 AFC 服务通道上完成写入。
    {
        let mut afc = connect_to_rsd_services::<AfcClient>().await?;

        ensure_afc_directory(&mut afc, STAGING_DIR).await?;
        ensure_afc_directory(&mut afc, STAGING_SUBDIR).await?;

        // 覆盖上传前先删除旧包：AFC 的 WrOnly 打开不保证把更短的新文件截断，若旧包比新包
        // 大会残留尾部字节形成损坏 zip。remove 对「文件不存在」幂等，错误可安全忽略。
        let _ = afc.remove(&staged_path).await;

        let mut handle = afc.open(&staged_path, AfcFopenMode::WrOnly).await?;
        handle.write_all(ipa_bytes).await?;
        handle.shutdown().await?;
        handle.close().await?;
        // 作用域结束 drop 写通道。
    }

    // 第二步：换一条「未参与写入」的全新 AFC 服务通道回读校验（纵深防御）。
    //
    // iOS 的 afcd 会把 AFC 写先缓存在内存，FileClose 应答并不等于已提交到 NAND；写通道
    // 自身随后读取可能命中未落盘缓冲，`get_file_info` 的 size 也只是元数据。这里在写通道
    // 关闭后新建一条 AFC 通道（与 installd 一样不持有写缓冲），从存储后端重开暂存包按字节
    // 比对，确认 installd 能读到完整文件后才放行。校验失败返回错误，交由 Swift `pushIpa`
    // 的重传循环重新上传（原因级闭环，非盲目重试）。
    verify_staged_package(ipa_bytes, &staged_path).await
}

/// 通过全新 AFC 通道确认暂存包在设备存储后端字节级完整且与本地一致。
async fn verify_staged_package(expected: &[u8], staged_path: &str) -> Result<(), IdeviceError> {
    let mut afc = connect_to_rsd_services::<AfcClient>().await?;

    // 1) 长度必须精确一致（覆盖文件缺失 / 整体截断）。
    let device_size = afc.get_file_info(staged_path).await?.size;
    if device_size != expected.len() {
        return Err(IdeviceError::NotEnoughBytes(device_size, expected.len()));
    }

    if expected.is_empty() {
        return Ok(());
    }

    // 2) 分块回读并逐字节比对（覆盖尾部未 flush / 局部截断 / 内容错乱）。
    let mut reader = afc.open(staged_path, AfcFopenMode::RdOnly).await?;

    let mut offset = 0usize;
    let mut buf = vec![0u8; VERIFY_CHUNK];
    while offset < expected.len() {
        let want = (expected.len() - offset).min(buf.len());

        // read_exact 读不满即 UnexpectedEof，说明设备端文件被截断：按不完整处理以触发重传。
        if reader.read_exact(&mut buf[..want]).await.is_err() {
            return Err(IdeviceError::NotEnoughBytes(offset, expected.len()));
        }

        if buf[..want] != expected[offset..offset + want] {
            return Err(IdeviceError::UnexpectedResponse(format!(
                "staged IPA content mismatch at byte {offset}"
            )));
        }

        offset += want;
    }

    reader.close().await?;
    Ok(())
}

pub async fn install_ipa_rppairing(bundle_id: String) -> Result<(), IdeviceError> {
    let staged_path = staged_ipa_path(&bundle_id);
    let opts = developer_client_options(&bundle_id);

    // 设备已存在同一 Bundle ID（失败占位残留、多开副本、续签覆盖）时走 Upgrade，否则全新
    // Install；二者都带 PackageType=Developer。查询出错降级 Install，不阻断首装。
    let command = select_install_command(lookup_app_rppairing(bundle_id.clone()).await);

    let result = {
        let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>().await?;
        match command {
            InstallCommand::Upgrade => inst_client.upgrade(&staged_path, Some(opts)).await,
            InstallCommand::Install => inst_client.install(&staged_path, Some(opts)).await,
        }
    };

    // 安装结束（无论成败）后尽力清理设备端暂存包，释放空间（大包可达数百 MB）；清理失败
    // 不影响安装结果，下一次上传前也会先 remove 同名文件。
    cleanup_staged_package(&staged_path).await;

    result
}

/// 最佳努力删除设备端暂存文件，忽略任何错误。
async fn cleanup_staged_package(staged_path: &str) {
    if let Ok(mut afc) = connect_to_rsd_services::<AfcClient>().await {
        let _ = afc.remove(staged_path).await;
    }
}

/// installd 安装命令选择（纯逻辑，便于单测）：lookup 命中已存在记录 → Upgrade；
/// 查询无记录或查询出错 → Install（出错降级，不阻断首装）。
fn select_install_command(lookup: Result<Option<String>, IdeviceError>) -> InstallCommand {
    match lookup {
        Ok(Some(_)) => InstallCommand::Upgrade,
        Ok(None) | Err(_) => InstallCommand::Install,
    }
}

#[derive(Debug, PartialEq, Eq)]
enum InstallCommand {
    Install,
    Upgrade,
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

async fn ensure_afc_directory(afc: &mut AfcClient, path: &str) -> Result<(), IdeviceError> {
    if afc.get_file_info(path).await.is_err() {
        afc.mk_dir(path).await?;

        afc.get_file_info(path).await?;
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn existing_bundle_id_selects_upgrade() {
        let lookup = Ok(Some("com.example.app".to_string()));
        assert_eq!(select_install_command(lookup), InstallCommand::Upgrade);
    }

    #[test]
    fn absent_bundle_id_selects_install() {
        assert_eq!(select_install_command(Ok(None)), InstallCommand::Install);
    }

    #[test]
    fn lookup_error_falls_back_to_install() {
        // 查询抖动不得阻断全新安装：降级 Install 而不是直接失败。
        let lookup = Err(IdeviceError::NotFound);
        assert_eq!(select_install_command(lookup), InstallCommand::Install);
    }

    #[test]
    fn developer_options_include_package_type_and_bundle_id() {
        let v = developer_client_options("com.example.app");
        // RustBridge 源码审计（含测试模块）禁止显式 panic 快捷方式，故用 match 断言而非之。
        match v.as_dictionary() {
            Some(dict) => {
                assert_eq!(
                    dict.get("PackageType").and_then(|x| x.as_string()),
                    Some("Developer")
                );
                assert_eq!(
                    dict.get("CFBundleIdentifier").and_then(|x| x.as_string()),
                    Some("com.example.app")
                );
            }
            None => assert!(false, "options must be a dictionary"),
        }
    }

    #[test]
    fn staged_path_is_deterministic_per_bundle() {
        assert_eq!(
            staged_ipa_path("com.a.b"),
            "PublicStaging/seal/com.a.b.ipa"
        );
        // push 与 install 两次推导结果必须一致。
        assert_eq!(staged_ipa_path("com.a.b"), staged_ipa_path("com.a.b"));
    }
}
