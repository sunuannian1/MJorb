// CoreDevice 隧道安装路径（iOS 17+ rpp 配对的正统流程）。
//
// 结论（真机日志证实）：
// 1. RSD shim 服务（com.apple.afc.shim.remote）的 AFC 视图在 iOS 18.7 上是临时的
//    ——写入的暂存包 installd 完全不可见（所有路径+选项组合均 MissingPackagePath）
// 2. CoreDeviceProxy 服务在 WiFi/RSD 通道上被设备硬重置（独占连接+重试亦然）
//
// 最终方案：复用已验证可用的 RemotePairing TLS-PSK 隧道
// （rsd::create_fresh_tunnel_context：rpp 配对验证 → 设备开监听 → TLS-PSK+CDTunnel），
// 在隧道内层 RSD 连接真实服务（com.apple.afc / com.apple.mobile.installation_proxy），
// 经典暂存写入真实媒体目录（对 installd 持久），原版形态候选链安装。
// 真实服务名连接失败时自动回退 shim 名。

use std::borrow::Cow;
use std::sync::Arc;

use idevice::{
    afc::AfcClient,
    installation_proxy::InstallationProxyClient,
    provider::RsdProvider,
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
    Idevice, IdeviceError, RsdService, ReadWrite,
};

use crate::idevice_support::install::{run_install_chain, stage_via_afc, IPA_STAGING_NAME};
use crate::idevice_support::rsd::get_rpp_raw;

// ---------- 隧道内层服务的 RsdService newtype（真实名 + shim 名回退） ----------

/// 隧道内层 RSD 的真实 AFC 服务
pub struct RealAfc(pub AfcClient);

impl RsdService for RealAfc {
    fn rsd_service_name() -> Cow<'static, str> {
        Cow::Borrowed("com.apple.afc")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        Ok(RealAfc(AfcClient::new(Idevice::new(stream, "Seal"))))
    }
}

/// 回退：shim AFC 服务名
pub struct ShimAfc(pub AfcClient);

impl RsdService for ShimAfc {
    fn rsd_service_name() -> Cow<'static, str> {
        Cow::Borrowed("com.apple.afc.shim.remote")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        Ok(ShimAfc(AfcClient::new(Idevice::new(stream, "Seal"))))
    }
}

/// 隧道内层 RSD 的真实安装代理服务
pub struct RealInstProxy(pub InstallationProxyClient);

impl RsdService for RealInstProxy {
    fn rsd_service_name() -> Cow<'static, str> {
        Cow::Borrowed("com.apple.mobile.installation_proxy")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        Ok(RealInstProxy(InstallationProxyClient::new(Idevice::new(
            stream,
            "Seal",
        ))))
    }
}

/// 回退：shim 安装代理服务名
pub struct ShimInstProxy(pub InstallationProxyClient);

impl RsdService for ShimInstProxy {
    fn rsd_service_name() -> Cow<'static, str> {
        Cow::Borrowed("com.apple.mobile.installation_proxy.shim.remote")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        Ok(ShimInstProxy(InstallationProxyClient::new(Idevice::new(
            stream,
            "Seal",
        ))))
    }
}

/// 基于隧道 AdapterHandle 的 RSD 提供者：
/// 服务连接 = 经隧道句柄连到内层 RSD 暴露的服务端口
pub struct TunnelRsdProvider {
    pub handle: Arc<tokio::sync::Mutex<AdapterHandle>>,
    pub label: String,
}

impl std::fmt::Debug for TunnelRsdProvider {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TunnelRsdProvider")
            .field("label", &self.label)
            .finish()
    }
}

impl RsdProvider for TunnelRsdProvider {
    fn connect_to_service_port(
        &mut self,
        port: u16,
    ) -> impl std::future::Future<Output = Result<Box<dyn ReadWrite>, IdeviceError>> + Send {
        let handle = std::sync::Arc::clone(&self.handle);
        async move {
            let mut guard = handle.lock().await;
            let stream = guard.connect(port).await.map_err(|e| IdeviceError::Socket(e))?;
            Ok(Box::new(stream) as Box<dyn ReadWrite>)
        }
    }
}

fn ctx_err(error: IdeviceError, stage: &str) -> IdeviceError {
    IdeviceError::UnexpectedResponse(format!("{stage}: {error:?}"))
}

/// 建立隧道上下文：隧道句柄 + 内层 RSD 握手（真实/shim 服务名均可解析）
async fn core_tunnel_context() -> Result<(Arc<tokio::sync::Mutex<AdapterHandle>>, RsdHandshake), IdeviceError>
{
    let rpp_raw = get_rpp_raw()
        .ok_or_else(|| IdeviceError::UnexpectedResponse("rpp 配对文件未加载".into()))?;
    let _ = rpp_raw;

    let (adapter, handshake) = crate::idevice_support::rsd::create_fresh_tunnel_context()
        .await
        .map_err(|e| ctx_err(e, "tunnel/建立RemotePairing隧道"))?;
    let handle = std::sync::Arc::new(tokio::sync::Mutex::new(adapter));

    Ok((handle, handshake))
}

/// 隧道：上传暂存（真实 AFC 优先，shim 名回退；写入真实媒体目录，持久）
pub async fn stage_via_core_tunnel(bundle_id: String, ipa_bytes: &[u8]) -> Result<(), IdeviceError> {
    let (handle, mut handshake) = core_tunnel_context().await?;
    let mut provider = TunnelRsdProvider {
        handle,
        label: "Seal".to_string(),
    };

    let mut afc = match RealAfc::connect_rsd(&mut provider, &mut handshake).await {
        Ok(r) => r.0,
        Err(e) => {
            let real_err = format!("{e:?}");
            ShimAfc::connect_rsd(&mut provider, &mut handshake)
                .await
                .map_err(|e2| ctx_err(e2, &format!("tunnel/连接com.apple.afc失败({real_err})，shim名亦失败")))?
                .0
        }
    };
    stage_via_afc(&mut afc, &bundle_id, ipa_bytes).await
}

/// 隧道：触发安装（真实 instproxy 优先，shim 名回退；原版形态候选链）
pub async fn install_via_core_tunnel(bundle_id: String) -> Result<(), IdeviceError> {
    let (handle, mut handshake) = core_tunnel_context().await?;
    let mut provider = TunnelRsdProvider {
        handle,
        label: "Seal".to_string(),
    };

    let mut inst_client = match RealInstProxy::connect_rsd(&mut provider, &mut handshake).await {
        Ok(r) => r.0,
        Err(e) => {
            let real_err = format!("{e:?}");
            ShimInstProxy::connect_rsd(&mut provider, &mut handshake)
                .await
                .map_err(|e2| {
                    ctx_err(e2, &format!("tunnel/连接instproxy失败({real_err})，shim名亦失败"))
                })?
                .0
        }
    };

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

/// 隧道：上传 + 安装合并调用
pub async fn stage_and_install_via_core_tunnel(
    bundle_id: String,
    ipa_bytes: &[u8],
) -> Result<(), IdeviceError> {
    stage_via_core_tunnel(bundle_id.clone(), ipa_bytes).await?;
    install_via_core_tunnel(bundle_id).await
}
