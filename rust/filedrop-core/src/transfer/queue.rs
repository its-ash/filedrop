//! Transfer queue: multiple files queued for send/receive, processed with
//! bounded parallelism.

use super::progress::TransferStatus;
use super::session::{TransferDirection, TransferSession};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{RwLock, Semaphore};
use uuid::Uuid;

/// Maximum number of transfers actively streaming at once. Additional
/// queued transfers wait for a permit; this bounds memory (chunk buffers)
/// and LAN bandwidth contention when a user selects many files at once.
const MAX_PARALLEL_TRANSFERS: usize = 3;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct QueuedTransfer {
    pub id: Uuid,
    pub file_path: PathBuf,
    pub file_name: String,
    pub total_bytes: u64,
    pub peer_device_id: Uuid,
    pub direction: TransferDirection,
    pub status: TransferStatus,
}

/// FIFO queue of transfers with a semaphore bounding how many run
/// concurrently. Callers pull a permit via [`TransferQueue::next`] before
/// starting a transfer's chunk loop, and release it (implicitly, via drop)
/// when the transfer finishes.
pub struct TransferQueue {
    pending: Arc<RwLock<VecDeque<QueuedTransfer>>>,
    active: Arc<RwLock<Vec<(QueuedTransfer, TransferSession)>>>,
    permits: Arc<Semaphore>,
}

impl TransferQueue {
    pub fn new() -> Self {
        Self {
            pending: Arc::new(RwLock::new(VecDeque::new())),
            active: Arc::new(RwLock::new(Vec::new())),
            permits: Arc::new(Semaphore::new(MAX_PARALLEL_TRANSFERS)),
        }
    }

    pub async fn enqueue(&self, transfer: QueuedTransfer) {
        self.pending.write().await.push_back(transfer);
    }

    /// Blocks until a concurrency permit is available, then pops and
    /// returns the next pending transfer paired with a fresh
    /// [`TransferSession`] to track it. Returns `None` if the queue is
    /// empty (permit is released automatically).
    pub async fn next(&self) -> Option<(QueuedTransfer, TransferSession, tokio::sync::OwnedSemaphorePermit)> {
        let permit = self.permits.clone().acquire_owned().await.ok()?;
        let mut queued = self.pending.write().await.pop_front()?;
        queued.status = TransferStatus::Connecting;

        let session = TransferSession::new(
            queued.id,
            queued.file_name.clone(),
            queued.total_bytes,
            queued.direction,
        );
        self.active.write().await.push((queued.clone(), session.clone()));
        Some((queued, session, permit))
    }

    pub async fn active_sessions(&self) -> Vec<(QueuedTransfer, TransferSession)> {
        self.active.read().await.clone()
    }

    pub async fn find_session(&self, id: Uuid) -> Option<TransferSession> {
        self.active
            .read()
            .await
            .iter()
            .find(|(q, _)| q.id == id)
            .map(|(_, s)| s.clone())
    }

    pub async fn mark_finished(&self, id: Uuid) {
        self.active.write().await.retain(|(q, _)| q.id != id);
    }

    pub async fn pending_count(&self) -> usize {
        self.pending.read().await.len()
    }
}

impl Default for TransferQueue {
    fn default() -> Self {
        Self::new()
    }
}
