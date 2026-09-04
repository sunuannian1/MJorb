// Jackson Coxson

use idevice::{
    afc::{opcode::AfcFopenMode, AfcClient},
    installation_proxy::InstallationProxyClient,
    IdeviceError,
};
use plist::{Dictionary, Value};

use crate::idevice_support::rsd::connect_to_rsd_services;
use tokio::io::AsyncWriteExt;

/// AFC 暂存目录（相对 AFC 根）。
const STAGING_DIR: &str = "PublicStaging";

/// 暂存 IPA 的固定相对路径。
///
/// 对齐官方 idevice（jkcoxson/idevice `utils/installation/helpers.rs` 的 `IPA_REMOTE_FILE`）：
/// iOS 17+ 走 RSD/远程配对安装时，InstallationProxy 在固定的单文件
/// `PublicStaging/idevice.ipa` 上定位 PackagePath。旧的 `PublicStaging/<bundle_id>/app.ipa`
/// 子目录写法来自 SideStore 旧 usbmuxd 通道，在新版系统（RSD/CoreDevice）上会让 installd
/// 间歇性报 `MissingPackagePath`（表现为部分 IPA 可装、部分不可装）。Seal 的安装是串行的，
/// 固定文件名每次覆盖即可，不需要按 bundle id 分子目录。
const STAGED_IPA_PATH: &str = "PublicStaging/idevice.ipa";

pub async fn yeet_app_afc_rppairing(
    _bundle_id: String,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    let mut afc = connect_to_rsd_services::<AfcClient>().await?;

    ensure_afc_directory(&mut afc, STAGING_DIR).await?;

    // 覆盖上传前先删除旧包：AFC 的 WrOnly 打开不保证把更短的新文件截断，若旧包比新包
    // 大会残留尾部字节形成损坏 zip。remove 对「文件不存在」幂等，错误可安全忽略。
    let _ = afc.remove(STAGED_IPA_PATH).await;

    let mut handle = afc.open(STAGED_IPA_PATH, AfcFopenMode::WrOnly).await?;

    handle.write_all(ipa_bytes).await?;

    handle.shutdown().await?;

    // close() consumes the borrowed FileDescriptor, releasing the &mut borrow
    // on `afc` so it can be queried again below.
    handle.close().await?;

    // Read back the on-device size. Across the LocalDevVPN wireless AFC tunnel
    // a large transfer can be truncated even though `write_all` reports success,
    // which later surfaces as installd "MissingPackagePath". Fail fast here so
    // the Swift `pushIpa` retry loop re-pushes instead of installing a partial
    // file. NotEnoughBytes(got, expected) renders as "expected {1}, got {0}".
    let device_size = afc.get_file_info(STAGED_IPA_PATH).await?.size;
    let expected_size = ipa_bytes.len();
    if device_size != expected_size {
        return Err(IdeviceError::NotEnoughBytes(device_size, expected_size));
    }

    Ok(())
}

pub async fn install_ipa_rppairing(bundle_id: String) -> Result<(), IdeviceError> {
    let mut inst_client = connect_to_rsd_services::<InstallationProxyClient>().await?;

    // bundle_id 由 Swift 侧从「签名后成品包内 Payload/*.app/Info.plist」回读，
    // 与暂存包内真实 CFBundleIdentifier 严格一致，避免外部计算值与包内 ID 不一致。
    let mut client_opts = Dictionary::new();
    client_opts.insert("CFBundleIdentifier".into(), bundle_id.into());

    inst_client
        .install(STAGED_IPA_PATH, Some(Value::Dictionary(client_opts)))
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

async fn ensure_afc_directory(afc: &mut AfcClient, path: &str) -> Result<(), IdeviceError> {
    if afc.get_file_info(path).await.is_err() {
        afc.mk_dir(path).await?;

        afc.get_file_info(path).await?;
    }

    Ok(())
}
