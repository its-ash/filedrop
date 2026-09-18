//! A single transfer's mutable runtime state: pause/cancel signalling and
//! rolling-window rate calculation, shared between the HTTP handler task
//! and whatever polls [`TransferProgress`].

use super::progress::{TransferProgress, TransferStatus};
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferDirection {
    Send,
    Receive,
}

/// Shared, cheaply-cloneable handle to one transfer's live state. Chunk
/// loops in [`super::client`]/[`super::server`] check `paused`/`cancelled`
/// between each [`crate::transfer::CHUNK_SIZE`] chunk so control signals
/// take effect within one chunk's latency, never mid-chunk (which would
/// require torn writes).
#[derive(Clone)]
pub struct TransferSession {
    pub id: Uuid,
    pub file_name: String,
    pub total_bytes: u64,
    pub direction: TransferDirection,
    bytes_transferred: Arc<AtomicU64>,
    paused: Arc<AtomicBool>,
    cancelled: Arc<AtomicBool>,
    started_at: Instant,
}

impl TransferSession {
    pub fn new(id: Uuid, file_name: String, total_bytes: u64, direction: TransferDirection) -> Self {
        Self {
            id,
            file_name,
            total_bytes,
            direction,
            bytes_transferred: Arc::new(AtomicU64::new(0)),
            paused: Arc::new(AtomicBool::new(false)),
            cancelled: Arc::new(AtomicBool::new(false)),
            started_at: Instant::now(),
        }
    }

    /// Starts the byte counter at `initial`, used when resuming a
    /// transfer from a non-zero offset.
    pub fn with_initial_bytes(self, initial: u64) -> Self {
        self.bytes_transferred.store(initial, Ordering::SeqCst);
        self
    }

    pub fn add_bytes(&self, n: u64) {
        self.bytes_transferred.fetch_add(n, Ordering::SeqCst);
    }

    pub fn bytes_transferred(&self) -> u64 {
        self.bytes_transferred.load(Ordering::SeqCst)
    }

    pub fn pause(&self) {
        self.paused.store(true, Ordering::SeqCst);
    }

    pub fn resume(&self) {
        self.paused.store(false, Ordering::SeqCst);
    }

    pub fn is_paused(&self) -> bool {
        self.paused.load(Ordering::SeqCst)
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::SeqCst);
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    pub fn progress(&self, status: TransferStatus, error: Option<String>) -> TransferProgress {
        let elapsed = self.started_at.elapsed().as_secs_f64().max(0.001);
        let transferred = self.bytes_transferred() as f64;
        TransferProgress {
            transfer_id: self.id,
            file_name: self.file_name.clone(),
            bytes_transferred: self.bytes_transferred(),
            total_bytes: self.total_bytes,
            status,
            bytes_per_sec: transferred / elapsed,
            error,
        }
    }
}
