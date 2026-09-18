//! Safe, `async fn`-based API surface — this is the layer flutter_rust_bridge
//! would introspect and generate Dart bindings for directly (FRB 2.x
//! supports plain `pub async fn` free functions taking/returning
//! serde-friendly types, which is exactly the shape below). The
//! hand-written `extern "C"` ABI in `c_abi.rs` wraps these same functions
//! for use before codegen is run.
//!
//! Every function here is intentionally `async` and returns
//! `Result<T, String>` (FRB maps Rust `Result::Err` to a Dart exception;
//! `String` keeps the error boundary simple and serializable without a
//! custom FRB error-type mirror).

use crate::events::FileDropEvent;
use crate::runtime::runtime;
use filedrop_core::discovery::DiscoveredDevice;
use filedrop_core::networking::{ConnectionMode, PlatformDirectCapability};
use filedrop_core::pairing::QrPairingPayload;
use filedrop_core::storage::TransferRecord;
use filedrop_core::transfer::{QueuedTransfer, TransferDirection, TransferProgress};
use filedrop_core::FileDropEngine;
use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use uuid::Uuid;

/// flutter_rust_bridge's required startup hook: wires up the Rust logic
/// layer (panic handling, logging bridge) exactly once before any other
/// `api` function is called from Dart. Called automatically by the
/// generated `RustLib.init()` on the Dart side — do not call it manually.
#[frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Push-based event subscription: forwards every `FileDropEvent` emitted
/// on the shared `tokio::sync::broadcast` channel (see `runtime.rs`) into
/// an FRB `StreamSink`, giving Dart a real `Stream<FileDropEvent>` with
/// push delivery. Replaces the hand-written ABI's `filedrop_poll_event`
/// polling loop — see `docs/FFI_INTERFACE.md`'s "Delivery mechanism"
/// section. Call once from Dart at startup and keep the returned stream
/// subscription alive for the app's lifetime.
pub async fn subscribe_events(sink: StreamSink<FileDropEventDto>) -> Result<(), String> {
    let mut rx = runtime().events_tx.subscribe();
    loop {
        match rx.recv().await {
            Ok(event) => {
                if sink.add(FileDropEventDto::from(event)).is_err() {
                    // Dart-side listener was torn down; stop forwarding.
                    break;
                }
            }
            // Lagged: some events were dropped from the ring buffer because
            // this subscriber fell behind. Not fatal — resync by continuing
            // to the next available event rather than terminating the
            // stream (mirrors the hand-written poller's same tolerance).
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
        }
    }
    Ok(())
}

/// One-time setup: initializes logging and the core engine. Must be
/// called once before any other API function. `app_data_dir` is a
/// writable directory supplied by the Dart side (via `path_provider`).
pub async fn init_engine(device_name: String, app_data_dir: String) -> Result<Uuid, String> {
    let _ = tracing_subscriber::fmt::try_init();

    let engine = FileDropEngine::init(device_name, PathBuf::from(app_data_dir))
        .await
        .map_err(|e| e.to_string())?;
    let device_id = engine.device_id;

    runtime()
        .engine
        .set(Arc::new(engine))
        .map_err(|_| "engine already initialized".to_string())?;

    Ok(device_id)
}

fn engine() -> Result<Arc<FileDropEngine>, String> {
    runtime()
        .engine
        .get()
        .cloned()
        .ok_or_else(|| "engine not initialized; call init_engine first".to_string())
}

/// Starts the HTTP/WebSocket transfer server on a free local port,
/// returning the resolved address/port it bound to.
pub async fn start_server() -> Result<ResolvedEndpointDto, String> {
    let eng = engine()?;
    let port = filedrop_core::networking::pick_server_port().map_err(|e| e.to_string())?;
    let router = eng.router();

    let listener = tokio::net::TcpListener::bind(("0.0.0.0", port))
        .await
        .map_err(|e| e.to_string())?;
    let local_addr = listener.local_addr().map_err(|e| e.to_string())?;

    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();
    *runtime().server_shutdown.lock().await = Some(shutdown_tx);

    tokio::spawn(async move {
        let graceful = axum::serve(listener, router).with_graceful_shutdown(async {
            let _ = shutdown_rx.await;
        });
        if let Err(e) = graceful.await {
            tracing::error!("filedrop server error: {e}");
        }
    });

    let addresses = filedrop_core::networking::local_ipv4_addresses().unwrap_or_default();
    let address = addresses
        .first()
        .map(|a| a.to_string())
        .unwrap_or_else(|| local_addr.ip().to_string());

    Ok(ResolvedEndpointDto {
        address,
        port: local_addr.port(),
    })
}

/// Stops the running transfer server, if any.
pub async fn stop_server() -> Result<(), String> {
    if let Some(tx) = runtime().server_shutdown.lock().await.take() {
        let _ = tx.send(());
    }
    Ok(())
}

/// Starts mDNS + UDP broadcast discovery, emitting `DeviceDiscovered`
/// events as peers are found. The `DiscoveryService` handle is retained
/// in `FfiRuntime` (same `Arc` + async-`Mutex` pattern `server_shutdown`
/// uses for `start_server`/`stop_server`) so `stop_discovery` can tear
/// down the mDNS/UDP listeners it owns, and so `get_nearby_devices` can
/// read its live device cache.
pub async fn start_discovery(self_device: DiscoveredDeviceDto) -> Result<(), String> {
    let service =
        Arc::new(filedrop_core::discovery::DiscoveryService::new("filedrop").map_err(|e| e.to_string())?);
    let (tx, mut rx) = tokio::sync::mpsc::channel(32);

    service
        .start(self_device.into(), tx)
        .await
        .map_err(|e| e.to_string())?;

    *runtime().discovery.lock().await = Some(service);

    tokio::spawn(async move {
        while let Some(device) = rx.recv().await {
            runtime().emit(FileDropEvent::DeviceDiscovered { device });
        }
    });

    Ok(())
}

/// Stops the running discovery service, if any, tearing down its mDNS
/// daemon and UDP broadcast sockets and clearing its device cache.
pub async fn stop_discovery() -> Result<(), String> {
    if let Some(service) = runtime().discovery.lock().await.take() {
        service.stop().await.map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Returns the current snapshot of devices discovered by the running
/// discovery service (empty if discovery hasn't been started, or has
/// been stopped).
pub async fn get_nearby_devices() -> Result<Vec<DiscoveredDeviceDto>, String> {
    match runtime().discovery.lock().await.as_ref() {
        Some(service) => Ok(service
            .nearby_devices()
            .await
            .into_iter()
            .map(DiscoveredDeviceDto::from)
            .collect()),
        None => Ok(Vec::new()),
    }
}

pub async fn pair_device(peer_device_id: Uuid, peer_name: String) -> Result<QrPairingPayloadDto, String> {
    let eng = engine()?;
    let token = filedrop_core::pairing::generate_pairing_token();
    eng.pairing
        .create_request(peer_device_id, peer_name.clone(), token.clone(), 300)
        .await;

    runtime().emit(FileDropEvent::PairingRequested {
        device_id: peer_device_id,
        device_name: peer_name,
        token: token.clone(),
    });

    let addresses = filedrop_core::networking::local_ipv4_addresses().unwrap_or_default();
    let address = addresses
        .first()
        .map(|a| a.to_string())
        .unwrap_or_default();

    Ok(QrPairingPayloadDto {
        version: 1,
        device_id: eng.device_id,
        device_name: eng.device_name.clone(),
        address,
        port: filedrop_core::networking::DEFAULT_PORT,
        token,
        expires_at: chrono_now_plus_secs(300),
    })
}

pub async fn send_files(
    peer_address: String,
    peer_port: u16,
    peer_device_id: Uuid,
    file_paths: Vec<String>,
) -> Result<Vec<Uuid>, String> {
    let eng = engine()?;
    let addr: SocketAddr = format!("{peer_address}:{peer_port}")
        .parse()
        .map_err(|e| format!("invalid peer address: {e}"))?;

    let mut ids = Vec::with_capacity(file_paths.len());
    for path_str in file_paths {
        let path = PathBuf::from(&path_str);
        let metadata = tokio::fs::metadata(&path)
            .await
            .map_err(|e| format!("cannot read {path_str}: {e}"))?;
        let file_name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("unnamed_file")
            .to_string();

        let transfer_id = Uuid::new_v4();
        ids.push(transfer_id);

        eng.queue
            .enqueue(QueuedTransfer {
                id: transfer_id,
                file_path: path.clone(),
                file_name: file_name.clone(),
                total_bytes: metadata.len(),
                peer_device_id,
                direction: TransferDirection::Send,
                status: filedrop_core::transfer::TransferStatus::Queued,
            })
            .await;

        let queue = eng.queue.clone();
        tokio::spawn(async move {
            run_queued_send(queue, addr, transfer_id, path, file_name, metadata.len()).await;
        });
    }

    Ok(ids)
}

async fn run_queued_send(
    queue: Arc<filedrop_core::transfer::TransferQueue>,
    addr: SocketAddr,
    transfer_id: Uuid,
    path: PathBuf,
    file_name: String,
    total_bytes: u64,
) {
    let Some((_, session, _permit)) = queue.next().await else {
        return;
    };

    runtime().emit(FileDropEvent::TransferStarted {
        transfer_id,
        file_name: file_name.clone(),
        total_bytes,
    });

    let result = filedrop_core::transfer::send_file(
        addr,
        transfer_id,
        &path,
        &session,
        filedrop_core::transfer::SendOptions::default(),
    )
    .await;

    match result {
        Ok(()) => {
            let sha256 = filedrop_core::security::sha256_file(&path)
                .await
                .unwrap_or_default();
            runtime().emit(FileDropEvent::TransferCompleted { transfer_id, sha256 });
        }
        Err(e) => {
            runtime().emit(FileDropEvent::TransferFailed {
                transfer_id,
                error: e.to_string(),
            });
        }
    }

    queue.mark_finished(transfer_id).await;
}

pub async fn accept_transfer(transfer_id: Uuid) -> Result<(), String> {
    let eng = engine()?;
    eng.pairing.confirm(transfer_id, true).await.map_err(|e| e.to_string())?;
    Ok(())
}

pub async fn reject_transfer(transfer_id: Uuid) -> Result<(), String> {
    let eng = engine()?;
    eng.pairing.confirm(transfer_id, false).await.map_err(|e| e.to_string())?;
    Ok(())
}

pub async fn pause_transfer(transfer_id: Uuid) -> Result<(), String> {
    let eng = engine()?;
    match eng.queue.find_session(transfer_id).await {
        Some(session) => {
            session.pause();
            runtime().emit(FileDropEvent::TransferPaused { transfer_id });
            Ok(())
        }
        None => Err(format!("transfer {transfer_id} not active")),
    }
}

pub async fn resume_transfer(transfer_id: Uuid) -> Result<(), String> {
    let eng = engine()?;
    match eng.queue.find_session(transfer_id).await {
        Some(session) => {
            session.resume();
            Ok(())
        }
        None => Err(format!("transfer {transfer_id} not active")),
    }
}

pub async fn cancel_transfer(transfer_id: Uuid) -> Result<(), String> {
    let eng = engine()?;
    match eng.queue.find_session(transfer_id).await {
        Some(session) => {
            session.cancel();
            Ok(())
        }
        None => Err(format!("transfer {transfer_id} not active")),
    }
}

pub async fn get_transfer_status(transfer_id: Uuid) -> Result<TransferProgressDto, String> {
    let eng = engine()?;
    eng.queue
        .find_session(transfer_id)
        .await
        .map(|s| TransferProgressDto::from(s.progress(filedrop_core::transfer::TransferStatus::InProgress, None)))
        .ok_or_else(|| format!("transfer {transfer_id} not found"))
}

pub async fn get_transfer_history() -> Result<Vec<TransferRecordDto>, String> {
    let eng = engine()?;
    Ok(eng.history.list().await.into_iter().map(TransferRecordDto::from).collect())
}

pub async fn platform_direct_capability(target_os: String) -> PlatformDirectCapabilityDto {
    PlatformDirectCapabilityDto::from(ConnectionMode::platform_capability(&target_os))
}

/// Checks whether a usable LAN interface exists right now, via real
/// non-loopback IPv4 interface enumeration filtered to private ranges
/// (see `filedrop_core::networking::usable_lan_ipv4`) — not the
/// UDP-default-route heuristic `local_ipv4_addresses` uses internally for
/// address advertising, which is not a reliable "do we have a LAN"
/// signal. Returns `Some(ip)` if a usable interface was found, `None`
/// otherwise (e.g. Wi-Fi off, only a cellular/public-IP route present).
/// Intended to be called by Dart before entering receive mode, to decide
/// between showing the waiting-to-receive screen directly or prompting
/// the user to create a Wi-Fi Direct group first.
pub async fn check_usable_lan() -> Result<Option<String>, String> {
    filedrop_core::networking::usable_lan_ipv4()
        .map(|opt| opt.map(|ip| ip.to_string()))
        .map_err(|e| e.to_string())
}

fn chrono_now_plus_secs(secs: i64) -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
        + secs
}

// --- DTOs -------------------------------------------------------------
// Thin serde-friendly wrappers around filedrop-core types, mirroring what
// flutter_rust_bridge would generate Dart classes for automatically. Kept
// explicit here since we're hand-writing the boundary.

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResolvedEndpointDto {
    pub address: String,
    pub port: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredDeviceDto {
    pub device_id: Uuid,
    pub name: String,
    pub address: String,
    pub port: u16,
    pub platform: String,
    pub paired: bool,
}

impl From<DiscoveredDeviceDto> for DiscoveredDevice {
    fn from(dto: DiscoveredDeviceDto) -> Self {
        DiscoveredDevice {
            device_id: dto.device_id,
            name: dto.name,
            address: dto.address,
            port: dto.port,
            platform: dto.platform,
            paired: dto.paired,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QrPairingPayloadDto {
    pub version: u8,
    pub device_id: Uuid,
    pub device_name: String,
    pub address: String,
    pub port: u16,
    pub token: String,
    pub expires_at: i64,
}

impl From<QrPairingPayloadDto> for QrPairingPayload {
    fn from(dto: QrPairingPayloadDto) -> Self {
        QrPairingPayload {
            version: dto.version,
            device_id: dto.device_id,
            device_name: dto.device_name,
            address: dto.address,
            port: dto.port,
            token: dto.token,
            expires_at: dto.expires_at,
        }
    }
}

impl From<DiscoveredDevice> for DiscoveredDeviceDto {
    fn from(d: DiscoveredDevice) -> Self {
        DiscoveredDeviceDto {
            device_id: d.device_id,
            name: d.name,
            address: d.address,
            port: d.port,
            platform: d.platform,
            paired: d.paired,
        }
    }
}

/// DTO mirror of `filedrop_core::transfer::TransferStatus`. `TransferStatus`
/// itself is a plain fieldless enum, but it lives in `filedrop-core` (a
/// separate crate from this `api` module), so it is redeclared here rather
/// than relying on `#[frb(mirror(..))]` — kept simple and consistent with
/// the rest of this file's hand-rolled DTO pattern.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferStatusDto {
    Queued,
    Connecting,
    InProgress,
    Paused,
    Completed,
    Failed,
    Cancelled,
}

impl From<filedrop_core::transfer::TransferStatus> for TransferStatusDto {
    fn from(s: filedrop_core::transfer::TransferStatus) -> Self {
        use filedrop_core::transfer::TransferStatus as S;
        match s {
            S::Queued => Self::Queued,
            S::Connecting => Self::Connecting,
            S::InProgress => Self::InProgress,
            S::Paused => Self::Paused,
            S::Completed => Self::Completed,
            S::Failed => Self::Failed,
            S::Cancelled => Self::Cancelled,
        }
    }
}

/// DTO mirror of `filedrop_core::transfer::TransferProgress`. Structs with
/// only primitive/serde-friendly fields (no external enum types) could be
/// mirrored via `#[frb(mirror(..))]`, but `TransferProgress` embeds
/// `TransferStatus`, so it's redeclared explicitly for clarity alongside
/// `TransferStatusDto` above.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferProgressDto {
    pub transfer_id: Uuid,
    pub file_name: String,
    pub bytes_transferred: u64,
    pub total_bytes: u64,
    pub status: TransferStatusDto,
    pub bytes_per_sec: f64,
    pub error: Option<String>,
}

impl From<TransferProgress> for TransferProgressDto {
    fn from(p: TransferProgress) -> Self {
        TransferProgressDto {
            transfer_id: p.transfer_id,
            file_name: p.file_name,
            bytes_transferred: p.bytes_transferred,
            total_bytes: p.total_bytes,
            status: p.status.into(),
            bytes_per_sec: p.bytes_per_sec,
            error: p.error,
        }
    }
}

/// DTO mirror of `filedrop_core::storage::TransferRecordStatus`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferRecordStatusDto {
    Completed,
    Failed,
    Cancelled,
}

impl From<filedrop_core::storage::TransferRecordStatus> for TransferRecordStatusDto {
    fn from(s: filedrop_core::storage::TransferRecordStatus) -> Self {
        use filedrop_core::storage::TransferRecordStatus as S;
        match s {
            S::Completed => Self::Completed,
            S::Failed => Self::Failed,
            S::Cancelled => Self::Cancelled,
        }
    }
}

/// DTO mirror of `filedrop_core::storage::TransferRecord`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferRecordDto {
    pub id: Uuid,
    pub file_name: String,
    pub file_size_bytes: u64,
    pub peer_device_id: Uuid,
    pub peer_name: String,
    pub outgoing: bool,
    pub status: TransferRecordStatusDto,
    pub sha256: Option<String>,
    pub started_at: i64,
    pub completed_at: i64,
    pub saved_path: Option<String>,
}

impl From<TransferRecord> for TransferRecordDto {
    fn from(r: TransferRecord) -> Self {
        TransferRecordDto {
            id: r.id,
            file_name: r.file_name,
            file_size_bytes: r.file_size_bytes,
            peer_device_id: r.peer_device_id,
            peer_name: r.peer_name,
            outgoing: r.outgoing,
            status: r.status.into(),
            sha256: r.sha256,
            started_at: r.started_at,
            completed_at: r.completed_at,
            saved_path: r.saved_path.map(|p| p.to_string_lossy().into_owned()),
        }
    }
}

/// DTO mirror of `filedrop_core::networking::ConnectionMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ConnectionModeDto {
    ExistingLan,
    LocalOnlyHotspot,
    WifiDirect,
}

impl From<ConnectionMode> for ConnectionModeDto {
    fn from(m: ConnectionMode) -> Self {
        match m {
            ConnectionMode::ExistingLan => Self::ExistingLan,
            ConnectionMode::LocalOnlyHotspot => Self::LocalOnlyHotspot,
            ConnectionMode::WifiDirect => Self::WifiDirect,
        }
    }
}

/// DTO mirror of `filedrop_core::networking::PlatformDirectCapability`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PlatformDirectCapabilityDto {
    Available { mode: ConnectionModeDto },
    RequiresPlatformChannel { mode: ConnectionModeDto, reason: String },
    Unsupported,
}

impl From<PlatformDirectCapability> for PlatformDirectCapabilityDto {
    fn from(c: PlatformDirectCapability) -> Self {
        match c {
            PlatformDirectCapability::Available { mode } => {
                Self::Available { mode: mode.into() }
            }
            PlatformDirectCapability::RequiresPlatformChannel { mode, reason } => {
                Self::RequiresPlatformChannel { mode: mode.into(), reason }
            }
            PlatformDirectCapability::Unsupported => Self::Unsupported,
        }
    }
}

/// DTO mirror of `crate::events::FileDropEvent`. Declared here (inside the
/// `api` module FRB scans) rather than reusing `crate::events::FileDropEvent`
/// directly or via `#[frb(mirror(..))]`, because FRB 2.13's enum mirroring
/// only supports fieldless enum variants — every variant here carries named
/// fields, which would otherwise force the type to cross the bridge as an
/// opaque Rust handle instead of a real Dart sealed class. See
/// `docs/FFI_INTERFACE.md`'s event catalogue for the semantics of each
/// variant; this is a 1:1 structural copy.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum FileDropEventDto {
    DeviceDiscovered { device: DiscoveredDeviceDto },
    DeviceConnected { device_id: Uuid },
    PairingRequested { device_id: Uuid, device_name: String, token: String },
    TransferStarted { transfer_id: Uuid, file_name: String, total_bytes: u64 },
    TransferProgress { progress: TransferProgressDto },
    TransferPaused { transfer_id: Uuid },
    TransferCompleted { transfer_id: Uuid, sha256: String },
    TransferFailed { transfer_id: Uuid, error: String },
    DeviceDisconnected { device_id: Uuid },
}

impl From<FileDropEvent> for FileDropEventDto {
    fn from(e: FileDropEvent) -> Self {
        match e {
            FileDropEvent::DeviceDiscovered { device } => {
                Self::DeviceDiscovered { device: device.into() }
            }
            FileDropEvent::DeviceConnected { device_id } => Self::DeviceConnected { device_id },
            FileDropEvent::PairingRequested { device_id, device_name, token } => {
                Self::PairingRequested { device_id, device_name, token }
            }
            FileDropEvent::TransferStarted { transfer_id, file_name, total_bytes } => {
                Self::TransferStarted { transfer_id, file_name, total_bytes }
            }
            FileDropEvent::TransferProgress { progress } => {
                Self::TransferProgress { progress: progress.into() }
            }
            FileDropEvent::TransferPaused { transfer_id } => {
                Self::TransferPaused { transfer_id }
            }
            FileDropEvent::TransferCompleted { transfer_id, sha256 } => {
                Self::TransferCompleted { transfer_id, sha256 }
            }
            FileDropEvent::TransferFailed { transfer_id, error } => {
                Self::TransferFailed { transfer_id, error }
            }
            FileDropEvent::DeviceDisconnected { device_id } => {
                Self::DeviceDisconnected { device_id }
            }
        }
    }
}
