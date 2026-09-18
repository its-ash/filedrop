//! `filedrop-core`: cross-platform LAN file-transfer engine.
//!
//! This crate is UI- and FFI-agnostic. It is consumed by `filedrop-ffi`,
//! which exposes it across the Dart FFI boundary to the Flutter app. See
//! `docs/ARCHITECTURE.md` for the overall system design and
//! `docs/PROTOCOL.md` for the wire protocol implemented in
//! [`transfer::server`]/[`transfer::client`].
//!
//! ## Module map
//! - [`discovery`] — mDNS/DNS-SD + UDP broadcast peer discovery on an
//!   existing LAN.
//! - [`networking`] — connection mode selection and address/port
//!   resolution; also documents which "no router" modes require
//!   platform-specific native code outside this crate's scope.
//! - [`transfer`] — the Phase 1 working core: chunked streaming
//!   send/receive over HTTP, transfer queue, resume, progress.
//! - [`pairing`] — token generation, QR payload, pairing state machine.
//! - [`security`] — path traversal prevention, filename sanitization,
//!   token validation, SHA-256 verification.
//! - [`storage`] — transfer history and received-file location metadata.

pub mod discovery;
pub mod error;
pub mod networking;
pub mod pairing;
pub mod security;
pub mod storage;
pub mod transfer;

pub use error::{FileDropError, Result};

use std::sync::Arc;
use uuid::Uuid;

/// Top-level handle bundling every subsystem, constructed once at app
/// startup and held by `filedrop-ffi`. Cheap to clone (everything inside
/// is `Arc`-backed).
#[derive(Clone)]
pub struct FileDropEngine {
    pub device_id: Uuid,
    pub device_name: String,
    pub paths: Arc<storage::StoragePaths>,
    pub history: Arc<storage::HistoryStore>,
    pub queue: Arc<transfer::TransferQueue>,
    pub pairing: Arc<pairing::PairingStateMachine>,
    pub sessions: Arc<tokio::sync::RwLock<std::collections::HashMap<Uuid, transfer::TransferSession>>>,
}

impl FileDropEngine {
    /// Initializes all subsystems and ensures on-disk directories exist.
    /// `app_data_dir` should be a per-platform writable directory
    /// (Flutter's `path_provider` application support directory is the
    /// intended source on mobile/desktop).
    pub async fn init(
        device_name: String,
        app_data_dir: impl Into<std::path::PathBuf>,
    ) -> Result<Self> {
        let paths = storage::StoragePaths::new(app_data_dir);
        paths.ensure_dirs().await?;

        let history = storage::HistoryStore::load(paths.history_file()).await?;

        Ok(Self {
            device_id: Uuid::new_v4(),
            device_name,
            paths: Arc::new(paths),
            history: Arc::new(history),
            queue: Arc::new(transfer::TransferQueue::new()),
            pairing: Arc::new(pairing::PairingStateMachine::new()),
            sessions: Arc::new(tokio::sync::RwLock::new(std::collections::HashMap::new())),
        })
    }

    /// Builds the axum [`axum::Router`] for this engine's HTTP transfer
    /// server (see [`transfer::build_router`]).
    pub fn router(&self) -> axum::Router {
        transfer::build_router(transfer::AppState {
            paths: self.paths.clone(),
            queue: self.queue.clone(),
            history: self.history.clone(),
            pairing: self.pairing.clone(),
            sessions: self.sessions.clone(),
        })
    }
}
