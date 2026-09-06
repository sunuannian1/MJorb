// CoreDevice 隧道安装路径（iOS 17+ rpp 配对的正统流程）。
//
// 结论（真机日志证实）：RSD shim 服务（com.apple.afc.shim.remote）的 AFC 视图
// 在 iOS 18.7 上是临时的——写入的暂存包 installd 完全不可见（所有路径+选项组合
// 均 MissingPackagePath，且目录内容会自行消失）。
//
// 本模块改走 pymobiledevice3/Xcode 相同的方式：
//   rpp 配对 → CoreDevice 软件隧道（TLS-PSK）→ 隧道内层 RSD
//   → 真实服务 com.apple.afc / com.apple.mobile.installation_proxy
//   → 经典暂存 + 原版形态候选链安装

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
use crate::idevice_support::rsd::{create_dedicated_rsd_connection, get_rpp_raw};

// ---------- 隧道内层真实服务的 RsdService newtype ----------

/// 隧道内层 RSD 的真实 AFC 服务（非 shim）
pub struct RealAfc(pub AfcClient);

impl RsdService for RealAfc {
    fn rsd_service_name() -> Cow<'static, str> {
        Cow::Borrowed("com.apple.afc")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        Ok(RealAfc(AfcClient::new(Idevice::new(stream, "Seal"))))
    }
}

/// 回退：shim AFC 服务名（若内层 RSD 只暴露 shim 名）
pub struct ShimAfc(pub AfcClient);

impl RsdService for ShimAfc {
    fn rsd_service_name() -> Cow<'static, str> {
        Cow::Borrowed("com.apple.afc.shim.remote")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        Ok(ShimAfc(AfcClient::new(Idevice::new(stream, "Seal"))))
    }
}

/// 隧道内层 RSD 的真实安装代理服务（非 shim）
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

/// 基于软件隧道 AdapterHandle 的 RSD 提供者：
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

/// 建立隧道上下文：软件隧道句柄 + 内层 RSD 握手（服务名可解析）
async fn core_tunnel_context() -> Result<(Arc<tokio::sync::Mutex<AdapterHandle>>, RsdHandshake), IdeviceError>
{
    // 1. rpp 配对文件原文
    let rpp_raw = get_rpp_raw()
        .ok_or_else(|| IdeviceError::UnexpectedResponse("rpp 配对文件未加载".into()))?;

    // 2. 独占 RSD 连接 + CoreDeviceProxy（TLS-PSK + CDTunnel；ConnectionReset 重试一次）
    let proxy = {
        let mut attempt = 0;
        loop {
            let (mut rsd_adapter, mut rsd_handshake) = create_dedicated_rsd_connection()
                .await
                .map_err(|e| ctx_err(e, "tunnel/建立RSD连接"))?;
            match CoreDeviceProxyOverRsd::connect_rsd(&mut rsd_adapter, &mut rsd_handshake).await {
                Ok(p) => break p,
                Err(e) => {
                    let msg = format!("{e:?}");
                    if msg.contains("ConnectionReset") && attempt == 0 {
                        attempt += 1;
                        tokio::time::sleep(std::time::Duration::from_millis(800)).await;
                        continue;
                    }
                    return Err(ctx_err(e, "tunnel/连接CoreDeviceProxy"));
                }
            }
        }
    };

    // 3. 软件隧道
    let mut adapter = proxy
        .0
        .create_software_tunnel()
        .map_err(|e| ctx_err(e, "tunnel/创建软件隧道"))?;
    let handle = adapter.to_async_handle();

    Ok((handle, rsd_handshake))
}

/// CoreDeviceProxy 经独占 RSD 连接的 newtype（CDTunnel 握手）
pub struct CoreDeviceProxyOverRsd(pub idevice::services::core_device_proxy::CoreDeviceProxy);

impl RsdService for CoreDeviceProxyOverRsd {
    fn rsd_service_name() -> Cow<'static, str> {
        Cow::Borrowed("com.apple.internal.devicecompute.CoreDeviceProxy")
    }

    async fn from_stream(stream: Box<dyn ReadWrite>) -> Result<Self, IdeviceError> {
        let idevice = Idevice::new(stream, "Seal");
        Ok(CoreDeviceProxyOverRsd(
            idevice::services::core_device_proxy::CoreDeviceProxy::new(idevice).await?,
        ))
    }
}

/// 隧道：上传暂存（真实 AFC，写入持久）
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

/// 隧道：触发安装（真实 instproxy，原版形态候选链）
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
