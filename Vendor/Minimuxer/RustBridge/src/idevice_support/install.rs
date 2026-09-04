// Jackson Coxson

use idevice::{
    afc::{opcode::AfcFopenMode, AfcClient},
    installation_proxy::InstallationProxyClient,
    IdeviceError,
};
use plist::{Dictionary, Value};

use crate::idevice_support::rsd::connect_to_rsd_services;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// AFC 暂存目录（相对 AFC 根）。
const STAGING_DIR: &str = "PublicStaging";

/// 暂存 IPA 的固定相对路径。
///
/// 对齐官方 idevice（jkcoxson/idevice `utils/installation/helpers.rs` 的 `IPA_REMOTE_FILE`）：
/// iOS 17+ 走 RSD/远程配对安装时，InstallationProxy 在固定的单文件
/// `PublicStaging/idevice.ipa` 上定位 PackagePath。安装是串行的，固定文件名每次覆盖即可。
/// 注意：经典 lockdown 通道（非 RSD）的路径约定不同，见 Swift 侧 `LockDownInstall`，两条
/// 通道不能共用同一套路径规则。
const STAGED_IPA_PATH: &str = "PublicStaging/idevice.ipa";

/// 回读校验时的分块大小。逐块读取、逐块比对，额外内存恒定，不随 IPA 体积增长。
const VERIFY_CHUNK: usize = 4 * 1024 * 1024;

pub async fn yeet_app_afc_rppairing(
    _bundle_id: String,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    // 第一步：在一条 AFC 服务通道上完成写入。
    {
        let mut afc = connect_to_rsd_services::<AfcClient>().await?;

        ensure_afc_directory(&mut afc, STAGING_DIR).await?;

        // 覆盖上传前先删除旧包：AFC 的 WrOnly 打开不保证把更短的新文件截断，若旧包比新包
        // 大会残留尾部字节形成损坏 zip。remove 对「文件不存在」幂等，错误可安全忽略。
        let _ = afc.remove(STAGED_IPA_PATH).await;

        let mut handle = afc.open(STAGED_IPA_PATH, AfcFopenMode::WrOnly).await?;
        handle.write_all(ipa_bytes).await?;
        handle.shutdown().await?;
        handle.close().await?;
        // 作用域结束 drop 写通道。
    }

    // 第二步：换一条「未参与写入」的全新 AFC 服务通道回读校验。
    //
    // 根因（MissingPackagePath 的通用来源之一）：iOS 的 afcd 会把 AFC 写先缓存在内存
    // （in-core state），FileClose 应答并不等于已提交到 NAND；写通道自身随后读取可能命中
    // 未落盘的缓冲，`get_file_info` 的 size 也只是元数据。若紧接着在独立的 installd 通道上
    // 发 Install，installd 在存储后端定位不到完整 PackagePath，即报 MissingPackagePath——
    // 无线 LocalDevVPN 隧道 + 大文件时趋近必现。
    //
    // 因此必须在写通道关闭后新建一条 AFC 通道（与 installd 一样不持有写缓冲），从存储后端
    // 重新打开暂存包，按字节比对完整内容，确认 installd 一定能读到完整文件后才放行安装。
    // 校验失败返回错误，由 Swift 侧 `pushIpa` 的重传循环重新上传（原因级闭环，非盲目重试）。
    verify_staged_package(ipa_bytes).await
}

/// 通过全新 AFC 通道确认暂存包在设备存储后端字节级完整且与本地一致。
async fn verify_staged_package(expected: &[u8]) -> Result<(), IdeviceError> {
    let mut afc = connect_to_rsd_services::<AfcClient>().await?;

    // 1) 长度必须精确一致（覆盖文件缺失 / 整体截断）。
    let device_size = afc.get_file_info(STAGED_IPA_PATH).await?.size;
    if device_size != expected.len() {
        return Err(IdeviceError::NotEnoughBytes(device_size, expected.len()));
    }

    if expected.is_empty() {
        return Ok(());
    }

    // 2) 分块回读并逐字节比对（覆盖尾部未 flush / 局部截断 / 内容错乱）。
    let mut reader = afc.open(STAGED_IPA_PATH, AfcFopenMode::RdOnly).await?;

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
    let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>().await?;

    // bundle_id 由 Swift 侧从「签名后成品包内 Payload/*.app/Info.plist」回读，
    // 与暂存包内真实 CFBundleIdentifier 严格一致，避免外部计算值与包内 ID 不一致。
    let mut client_opts = Dictionary::new();
    client_opts.insert("CFBundleIdentifier".into(), bundle_id.clone().into());
    let opts = Value::Dictionary(client_opts);

    // MissingPackagePath 的另一个通用来源：设备上已存在同一 Bundle ID（上次失败留下的灰色
    // 占位、多开副本、续签覆盖）时，installd 要求走 Upgrade；对已存在的 Bundle ID 发全新
    // Install 会在定位阶段报 MissingPackagePath。安装前先 lookup，已存在则 Upgrade，否则
    // Install，对「首装 / 重装 / 多开 / 续签覆盖」全部通用。lookup 自身失败不阻断安装，
    // 降级为 Install（避免查询抖动导致无法全新安装）。
    let command = select_install_command(lookup_app_rppairing(bundle_id.clone()).await);

    match command {
        InstallCommand::Upgrade => inst_client.upgrade(STAGED_IPA_PATH, Some(opts)).await,
        InstallCommand::Install => inst_client.install(STAGED_IPA_PATH, Some(opts)).await,
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
}
