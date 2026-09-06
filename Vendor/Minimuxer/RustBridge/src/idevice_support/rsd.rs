use idevice::{
    heartbeat::HeartbeatClient,
    remote_pairing::{RemotePairingClient, RpPairingSocket},
    rsd::RsdHandshake,
    IdeviceError, RsdService,
};

use log::{error, info, warn};

use std::{
    net::{Ipv4Addr, SocketAddrV4},
    sync::{Mutex, MutexGuard, OnceLock},
};

type RsdAdapter = idevice::tcp::handle::AdapterHandle;

pub struct CachedRsdConnection {
    pub adapter: RsdAdapter,
    pub handshake: RsdHandshake,
    generation: u64,
}

struct PairingState {
    file: Option<idevice::remote_pairing::RpPairingFile>,
    generation: u64,
    /// rpp 配对文件原文（plist），供 CoreDevice 隧道的 lockdown 配对解析使用
    raw: Option<String>,
}

static RPPAIRING_STATE: OnceLock<Mutex<PairingState>> = OnceLock::new();
static RPPAIRING_RSD_CONNECTION: OnceLock<Mutex<Option<CachedRsdConnection>>> = OnceLock::new();

fn pairing_state() -> &'static Mutex<PairingState> {
    RPPAIRING_STATE.get_or_init(|| {
        Mutex::new(PairingState {
            file: None,
            generation: 0,
            raw: None,
        })
    })
}

fn connection_state() -> &'static Mutex<Option<CachedRsdConnection>> {
    RPPAIRING_RSD_CONNECTION.get_or_init(|| Mutex::new(None))
}

fn lock_recover<T>(mutex: &'static Mutex<T>, name: &str) -> MutexGuard<'static, T> {
    match mutex.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            warn!("Recovering poisoned RustBridge mutex: {name}");
            poisoned.into_inner()
        }
    }
}

fn current_generation() -> u64 {
    lock_recover(pairing_state(), "pairing_state").generation
}

fn pairing_snapshot() -> Result<(idevice::remote_pairing::RpPairingFile, u64), IdeviceError> {
    let state = lock_recover(pairing_state(), "pairing_state");
    match state.file.as_ref() {
        Some(file) => Ok((file.clone(), state.generation)),
        None => Err(IdeviceError::UserDeniedPairing),
    }
}

pub fn set_rppairing_file(pairing_file_string: String) -> Result<(), IdeviceError> {
    let pairing_file =
        idevice::remote_pairing::RpPairingFile::from_bytes(pairing_file_string.as_bytes())?;

    let generation = {
        let mut state = lock_recover(pairing_state(), "pairing_state");
        state.generation = state.generation.wrapping_add(1);
        state.file = Some(pairing_file);
        state.raw = Some(pairing_file_string);
        state.generation
    };

    // A cached RSD connection is bound to the previous pairing identity. Never
    // reuse it after the pairing file changes.
    *lock_recover(connection_state(), "rsd_connection") = None;
    info!("Remote pairing file updated; generation={generation}");
    Ok(())
}

/// rpp 配对文件原文（plist），供 CoreDevice 隧道路径解析 lockdown 配对使用
pub fn get_rpp_raw() -> Option<String> {
    let state = lock_recover(pairing_state(), "pairing_state");
    state.raw.clone()
}

/// 创建一条独占的 RSD 连接（不入缓存）。
/// CoreDeviceProxy 是长生命周期隧道服务，与 shim 服务共用缓存连接时
/// 会在握手阶段被 ConnectionReset，需要独占连接。
pub async fn create_dedicated_rsd_connection() -> Result<(RsdAdapter, RsdHandshake), IdeviceError> {
    let connection = create_rppairing_rsd_connection().await?;
    Ok((connection.adapter, connection.handshake))
}

/// 主动废弃缓存的 RSD 连接（隧道可能已断、或连续服务调用失败）。
/// 下一次 connect_to_rsd_services 会重建隧道连接；
/// 没有它，Minimuxer.reset() 后的重试仍复用死连接，重试形同虚设。
pub fn invalidate_rsd_connection() {
    *lock_recover(connection_state(), "rsd_connection") = None;
    info!("RSD connection cache invalidated");
}

/// 建立一条全新的 RemotePairing TLS-PSK 隧道（不入缓存），返回隧道句柄与内层 RSD 握手。
/// 内层 RSD 暴露真实服务（com.apple.afc / com.apple.mobile.installation_proxy），
/// 其 AFC 视图为真实媒体目录（与 shim 的临时视图不同），写入对 installd 持久可见。
pub async fn create_fresh_tunnel_context() -> Result<(RsdAdapter, RsdHandshake), IdeviceError> {
    let connection = create_rppairing_rsd_connection().await?;
    Ok((connection.adapter, connection.handshake))
}

pub async fn connect_to_rsd_services<Service: RsdService>() -> Result<Service, IdeviceError> {
    let generation = current_generation();
    {
        let mut guard = lock_recover(connection_state(), "rsd_connection");
        if let Some(connection) = guard.as_mut() {
            if connection.generation != generation {
                *guard = None;
            } else {
                match Service::connect_rsd(&mut connection.adapter, &mut connection.handshake).await {
                    Ok(service) => {
                        info!("using existing RSD connection");
                        return Ok(service);
                    }
                    Err(IdeviceError::Socket(_)) => {
                        *guard = None;
                    }
                    Err(error) => return Err(error),
                }
            }
        }
    }

    let connection = create_rppairing_rsd_connection().await?;
    let connection_generation = connection.generation;
    if current_generation() != connection_generation {
        warn!("Pairing identity changed while creating RSD connection");
        return Err(IdeviceError::UserDeniedPairing);
    }

    let mut guard = lock_recover(connection_state(), "rsd_connection");
    *guard = Some(connection);
    let Some(connection) = guard.as_mut() else {
        return Err(IdeviceError::InvalidArgument);
    };
    Service::connect_rsd(&mut connection.adapter, &mut connection.handshake).await
}

pub async fn get_or_create_rppairing_rsd_connection(
) -> Result<MutexGuard<'static, Option<CachedRsdConnection>>, IdeviceError> {
    let generation = current_generation();
    {
        let mut guard = lock_recover(connection_state(), "rsd_connection");
        if let Some(connection) = guard.as_mut() {
            if connection.generation != generation {
                *guard = None;
            } else if HeartbeatClient::connect_rsd(
                &mut connection.adapter,
                &mut connection.handshake,
            )
            .await
            .is_ok()
            {
                info!("using existing RSD connection");
                return Ok(guard);
            } else {
                *guard = None;
            }
        }
    }

    let connection = create_rppairing_rsd_connection().await?;
    let connection_generation = connection.generation;
    if current_generation() != connection_generation {
        warn!("Pairing identity changed while creating RSD connection");
        return Err(IdeviceError::UserDeniedPairing);
    }

    let mut guard = lock_recover(connection_state(), "rsd_connection");
    *guard = Some(connection);
    Ok(guard)
}

async fn create_rppairing_rsd_connection() -> Result<CachedRsdConnection, IdeviceError> {
    let (mut pairing_file, generation) = pairing_snapshot().map_err(|error| {
        error!("No remote pairing file is available");
        error
    })?;

    let socket_addr = SocketAddrV4::new(Ipv4Addr::new(10, 7, 0, 1), 49152);
    let stream = tokio::net::TcpStream::connect(socket_addr)
        .await
        .map_err(|error| IdeviceError::Socket(error))?;

    let conn = RpPairingSocket::new(stream);
    let mut rpc = RemotePairingClient::new(conn, &"minimuxer", &mut pairing_file);
    rpc.connect(async |_| "000000".to_string(), 0u8).await?;

    use idevice::remote_pairing::connect_tls_psk_tunnel_native;

    let tunnel_port = rpc.create_tcp_listener().await?;
    let tunnel_addr =
        std::net::SocketAddr::new(std::net::IpAddr::V4(*socket_addr.ip()), tunnel_port);
    let tunnel_stream = tokio::net::TcpStream::connect(tunnel_addr).await?;
    let tunnel = connect_tls_psk_tunnel_native(tunnel_stream, rpc.encryption_key()).await?;
    let client_ip: std::net::IpAddr = tunnel
        .info
        .client_address
        .parse()
        .map_err(|error| IdeviceError::AddrParseError(error))?;
    let server_ip: std::net::IpAddr = tunnel
        .info
        .server_address
        .parse()
        .map_err(|error| IdeviceError::AddrParseError(error))?;
    let mtu = tunnel.info.mtu as usize;
    let rsd_port = tunnel.info.server_rsd_port;

    let raw = tunnel.into_inner();
    let mut adapter = idevice::tcp::adapter::Adapter::new(Box::new(raw), client_ip, server_ip);
    adapter.set_mss(mtu.saturating_sub(60));
    let mut adapter = adapter.to_async_handle();

    let rsd_stream = adapter.connect(rsd_port).await?;
    let handshake = RsdHandshake::new(rsd_stream).await?;

    Ok(CachedRsdConnection {
        adapter,
        handshake,
        generation,
    })
}
