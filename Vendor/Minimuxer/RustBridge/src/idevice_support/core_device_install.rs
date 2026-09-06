// CoreDevice 隧道安装路径（iOS 17+ / rpp 配对的正统流程）。
//
// 背景：RSD shim 通道（com.apple.afc.shim.remote + installation_proxy.shim.remote）
// 在 iOS 18.7 上 installd 无法定位经 shim AFC 暂存的包（所有路径形态均报
// MissingPackagePath）。本路径改走正规工具链（Xcode / pymobiledevice3）相同的方式：
//   RSD → CoreDeviceProxy → 软件隧道 Adapter → lockdown 会话（rpp 配对）
//   → 经典 AFC 暂存 → 经典 instproxy 安装。
// 经典服务通道与本设备 lockdown 配对时代验证可用的流程完全一致。

use std::borrow::Cow;
use std::future::Future;
use std::pin::Pin;

use idevice::{
    afc::AfcClient,
    installation_proxy::InstallationProxyClient,
    pairing_file::PairingFile,
    provider::IdeviceProvider,
    services::core_device_proxy::CoreDeviceProxy,
    tcp::handle::AdapterHandle,
    Idevice, IdeviceError, IdeviceService, RsdService, ReadWrite,
};

use crate::idevice_support::install::{run_install_chain, stage_via_afc, IPA_STAGING_NAME};
use crate::idevice_support::rsd::{connect_to_rsd_services, get_rpp_raw};

/// 经 RSD 连接的 CoreDeviceProxy。
/// idevice crate 未为 CoreDeviceProxy 实现 RsdService，用本地 newtype 补上：
/// RSD 握手会返回设备暴露的服务端口表，按名字连接 devicecompute 服务。
pub struct CoreDeviceProxyOverRsd(pub CoreDeviceProxy);

impl RsdService for CoreDeviceProxyOverRsd {
    fn rsd_service_name() -> Cow<'static, str> {
        Cow::Borrowed("com.apple.internal.devicecompute.CoreDeviceProxy")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        let idevice = Idevice::new(stream, "Seal");
        Ok(CoreDeviceProxyOverRsd(CoreDeviceProxy::new(idevice).await?))
    }
}

/// 基于软件隧道的设备连接提供者：
/// 实现 IdeviceProvider 后，所有经典服务（lockdown/AFC/instproxy）
/// 都能通过 `Service::connect(&provider)` 走标准流程（含 TLS 升级）。
pub struct TunnelProvider {
    pub handle: std::sync::Arc<tokio::sync::Mutex<AdapterHandle>>,
    pub pairing_file: PairingFile,
    pub label: String,
}

impl std::fmt::Debug for TunnelProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TunnelProvider")
            .field("label", &self.label)
            .finish()
    }
}

impl IdeviceProvider for TunnelProvider {
    fn connect(
        &self,
        port: u16,
    ) -> Pin<Box<dyn Future<Output = Result<Idevice, IdeviceError>> + Send>> {
        let handle = std::sync::Arc::clone(&self.handle);
        let label = self.label.clone();
        Box::pin(async move {
            let mut guard = handle.lock().await;
            let stream = guard
                .connect(port)
                .await
                .map_err(|e| IdeviceError::Socket(e))?;
            Ok(Idevice::new(Box::new(stream), label))
        })
    }

    fn label(&self) -> &str {
        &self.label
    }

    fn get_pairing_file(
        &self,
    ) -> Pin<Box<dyn Future<Output = Result<PairingFile, IdeviceError>> + Send>> {
        let pairing_file = self.pairing_file.clone();
        Box::pin(async move { Ok(pairing_file) })
    }
}

/// CoreDevice 隧道：上传 + 安装合并调用。
/// 若任何一步失败，错误文案带 tunnel/ 阶段前缀，便于真机定位。
pub async fn stage_and_install_via_core_tunnel(
    bundle_id: String,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    // 1. rpp 配对文件原文（set_rppairing_file 时保存）
    let rpp_raw = get_rpp_raw()
        .ok_or_else(|| IdeviceError::UnexpectedResponse("rpp 配对文件未加载".into()))?;

    // 2. 经 RSD 连接 CoreDeviceProxy
    let proxy = connect_to_rsd_services::<CoreDeviceProxyOverRsd>()
        .await
        .map_err(|e| ctx_err(e, "tunnel/连接CoreDeviceProxy"))?;

    // 3. 建软件隧道
    let mut adapter = proxy
        .0
        .create_software_tunnel()
        .map_err(|e| ctx_err(e, "tunnel/创建软件隧道"))?;
    let handle = adapter.to_async_handle();

    // 4. rpp → lockdown 配对记录
    let pairing_file = PairingFile::from_bytes(rpp_raw.as_bytes())
        .map_err(|e| ctx_err(e, "tunnel/解析rpp配对文件为lockdown格式"))?;

    let provider = TunnelProvider {
        handle: std::sync::Arc::new(tokio::sync::Mutex::new(handle)),
        pairing_file,
        label: "Seal".to_string(),
    };

    // 5. 经典 AFC 暂存（lockdown 服务的 AFC，写提交语义与 shim 不同）
    let mut afc = AfcClient::connect(&provider)
        .await
        .map_err(|e| ctx_err(e, "tunnel/连接AFC"))?;
    stage_via_afc(&mut afc, &bundle_id, ipa_bytes).await?;
    drop(afc);

    // 6. 经典 instproxy 安装（原版形态候选链）
    let mut inst_client = InstallationProxyClient::connect(&provider)
        .await
        .map_err(|e| ctx_err(e, "tunnel/连接instproxy"))?;

    let already_installed = inst_client
        .get_apps(None, Some(vec![bundle_id.clone()]))
        .await
        .map(|apps| apps.contains_key(&bundle_id))
        .unwrap_or(false);

    run_install_chain(
        &mut inst_client,
        already_installed,
        &bundle_id,
        IPA_STAGING_NAME,
    )
    .await
}

fn ctx_err(error: IdeviceError, stage: &str) -> IdeviceError {
    IdeviceError::UnexpectedResponse(format!("{stage}: {error:?}"))
}
