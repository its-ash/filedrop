//! Pairing state machine. Tracks in-flight pairing requests between this
//! device and a peer, from initial request through acceptance/rejection.

use crate::error::{FileDropError, Result};
use crate::security::tokens_match;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::RwLock;
use uuid::Uuid;

/// Lifecycle of a single pairing attempt with one peer device.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PairingState {
    /// Token generated, waiting for the peer to present it.
    Pending,
    /// Peer presented a valid token; awaiting local user confirmation.
    AwaitingConfirmation,
    /// User accepted; devices are paired and may transfer files.
    Paired,
    /// User rejected, or the token expired before confirmation.
    Rejected,
}

/// A single pairing request/record between this device and `peer_device_id`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairingRequest {
    pub peer_device_id: Uuid,
    pub peer_name: String,
    pub token: String,
    pub state: PairingState,
    pub created_at: i64,
    pub expires_at: i64,
}

impl PairingRequest {
    fn is_expired(&self, now: i64) -> bool {
        now >= self.expires_at
    }
}

/// In-memory pairing state machine, keyed by peer device id. Persisted
/// pairings (so re-pairing isn't required on every app launch) are the
/// responsibility of [`crate::storage`]; this type only governs the live
/// handshake.
#[derive(Default, Clone)]
pub struct PairingStateMachine {
    requests: Arc<RwLock<HashMap<Uuid, PairingRequest>>>,
}

impl PairingStateMachine {
    pub fn new() -> Self {
        Self::default()
    }

    /// Registers a new outbound or inbound pairing request in `Pending`
    /// state with a token valid for `ttl_secs` seconds.
    pub async fn create_request(
        &self,
        peer_device_id: Uuid,
        peer_name: String,
        token: String,
        ttl_secs: i64,
    ) -> PairingRequest {
        let now = now_unix();
        let request = PairingRequest {
            peer_device_id,
            peer_name,
            token,
            state: PairingState::Pending,
            created_at: now,
            expires_at: now + ttl_secs,
        };
        self.requests
            .write()
            .await
            .insert(peer_device_id, request.clone());
        request
    }

    /// Called when a peer presents a token for verification. Moves the
    /// matching request to `AwaitingConfirmation` if the token matches and
    /// hasn't expired.
    pub async fn present_token(&self, peer_device_id: Uuid, presented_token: &str) -> Result<()> {
        let mut guard = self.requests.write().await;
        let request = guard
            .get_mut(&peer_device_id)
            .ok_or(FileDropError::InvalidPairingToken)?;

        if request.is_expired(now_unix()) {
            request.state = PairingState::Rejected;
            return Err(FileDropError::InvalidPairingToken);
        }
        if !tokens_match(&request.token, presented_token) {
            return Err(FileDropError::InvalidPairingToken);
        }
        request.state = PairingState::AwaitingConfirmation;
        Ok(())
    }

    /// User-driven decision: accept or reject a pairing awaiting
    /// confirmation.
    pub async fn confirm(&self, peer_device_id: Uuid, accept: bool) -> Result<PairingState> {
        let mut guard = self.requests.write().await;
        let request = guard
            .get_mut(&peer_device_id)
            .ok_or_else(|| FileDropError::DeviceNotFound(peer_device_id))?;

        request.state = if accept {
            PairingState::Paired
        } else {
            PairingState::Rejected
        };
        Ok(request.state)
    }

    pub async fn get(&self, peer_device_id: Uuid) -> Option<PairingRequest> {
        self.requests.read().await.get(&peer_device_id).cloned()
    }

    pub async fn is_paired(&self, peer_device_id: Uuid) -> bool {
        matches!(
            self.requests.read().await.get(&peer_device_id),
            Some(r) if r.state == PairingState::Paired
        )
    }

    /// Sweeps expired `Pending`/`AwaitingConfirmation` requests. Should be
    /// called periodically (e.g. every 30s) by the server's background
    /// task loop.
    pub async fn sweep_expired(&self) {
        let now = now_unix();
        let mut guard = self.requests.write().await;
        for request in guard.values_mut() {
            if request.state != PairingState::Paired && request.is_expired(now) {
                request.state = PairingState::Rejected;
            }
        }
    }
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}
