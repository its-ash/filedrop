//! Phase 1: real axum HTTP server that receives files over LAN with
//! chunked streaming I/O — the request body is streamed directly to disk
//! via a `tokio::io::copy`-style loop, never buffered fully in memory.
//!
//! Wire protocol (full detail in `docs/PROTOCOL.md`):
//! - `POST /api/v1/transfer/:transfer_id` — start or continue a transfer.
//!   Headers: `X-FileDrop-Filename`, `X-FileDrop-Total-Size`,
//!   `X-FileDrop-Sha256` (optional, sender-computed, verified on
//!   completion). Body: raw file bytes (or the remaining bytes, if a
//!   `Content-Range` header is present for a resumed transfer).
//! - `GET /api/v1/transfer/:transfer_id/status` — current byte offset
//!   already received, so a resuming sender knows where to seek from.
//! - `GET /health` — liveness check, used by the nginx example config.

use super::progress::TransferStatus;
use super::queue::TransferQueue;
use super::session::{TransferDirection, TransferSession};
use crate::pairing::PairingStateMachine;
use crate::security::{safe_join, sanitize_filename, Sha256Hasher};
use crate::storage::{HistoryStore, StoragePaths};
use axum::{
    extract::{Path as AxumPath, Request, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use futures::StreamExt;
use serde::Serialize;
use std::sync::Arc;
use tokio::fs::OpenOptions;
use tokio::io::{AsyncSeekExt, AsyncWriteExt};
use uuid::Uuid;

/// Shared server state injected into every handler.
#[derive(Clone)]
pub struct AppState {
    pub paths: Arc<StoragePaths>,
    pub queue: Arc<TransferQueue>,
    pub history: Arc<HistoryStore>,
    pub pairing: Arc<PairingStateMachine>,
    pub sessions: Arc<tokio::sync::RwLock<std::collections::HashMap<Uuid, TransferSession>>>,
}

/// Builds the axum [`Router`] exposing FileDrop's HTTP transfer API. Can
/// be served standalone (`axum::serve`) or fronted by the optional nginx
/// reverse proxy (`nginx/filedrop.conf.example`) — the server never
/// assumes nginx is present.
pub fn build_router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/api/v1/transfer/{transfer_id}", post(receive_transfer))
        .route(
            "/api/v1/transfer/{transfer_id}/status",
            get(transfer_status),
        )
        .with_state(state)
}

async fn health() -> &'static str {
    "ok"
}

#[derive(Serialize)]
struct TransferStatusResponse {
    transfer_id: Uuid,
    bytes_received: u64,
    total_bytes: u64,
    status: TransferStatus,
}

async fn transfer_status(
    State(state): State<AppState>,
    AxumPath(transfer_id): AxumPath<Uuid>,
) -> Response {
    let sessions = state.sessions.read().await;
    match sessions.get(&transfer_id) {
        Some(session) => Json(TransferStatusResponse {
            transfer_id,
            bytes_received: session.bytes_transferred(),
            total_bytes: session.total_bytes,
            status: if session.is_paused() {
                TransferStatus::Paused
            } else {
                TransferStatus::InProgress
            },
        })
        .into_response(),
        None => (StatusCode::NOT_FOUND, "unknown transfer").into_response(),
    }
}

/// Receives a (possibly resumed) file upload, streaming the request body
/// directly to a `.part` staging file in [`StoragePaths::staging_dir`],
/// then atomically renaming it into [`StoragePaths::received_files_dir`]
/// once complete and (if a checksum header was sent) verified.
async fn receive_transfer(
    State(state): State<AppState>,
    AxumPath(transfer_id): AxumPath<Uuid>,
    headers: HeaderMap,
    request: Request,
) -> Response {
    let raw_filename = match headers
        .get("X-FileDrop-Filename")
        .and_then(|v| v.to_str().ok())
    {
        Some(name) => name.to_string(),
        None => return (StatusCode::BAD_REQUEST, "missing X-FileDrop-Filename").into_response(),
    };
    let total_size: u64 = match headers
        .get("X-FileDrop-Total-Size")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse().ok())
    {
        Some(size) => size,
        None => {
            return (StatusCode::BAD_REQUEST, "missing X-FileDrop-Total-Size").into_response()
        }
    };
    let expected_sha256 = headers
        .get("X-FileDrop-Sha256")
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);

    let safe_name = sanitize_filename(&raw_filename);
    let staging_path = match safe_join(&state.paths.staging_dir(), &format!("{transfer_id}.part"))
    {
        Ok(p) => p,
        Err(e) => return (StatusCode::BAD_REQUEST, e.to_string()).into_response(),
    };
    let final_path = match safe_join(&state.paths.received_files_dir(), &safe_name) {
        Ok(p) => p,
        Err(e) => return (StatusCode::BAD_REQUEST, e.to_string()).into_response(),
    };

    // Resume support: a `Content-Range: bytes START-END/TOTAL` header
    // means the client is continuing from `START`. We seek the staging
    // file to that offset and append from there rather than truncating.
    let resume_offset = parse_resume_offset(&headers).unwrap_or(0);

    if let Some(parent) = staging_path.parent() {
        if let Err(e) = tokio::fs::create_dir_all(parent).await {
            return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response();
        }
    }

    let mut file = match OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(resume_offset == 0)
        .open(&staging_path)
        .await
    {
        Ok(f) => f,
        Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    };
    if resume_offset > 0 {
        if let Err(e) = file.seek(std::io::SeekFrom::Start(resume_offset)).await {
            return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response();
        }
    }

    let session = TransferSession::new(
        transfer_id,
        safe_name.clone(),
        total_size,
        TransferDirection::Receive,
    )
    .with_initial_bytes(resume_offset);
    state
        .sessions
        .write()
        .await
        .insert(transfer_id, session.clone());

    let mut hasher = Sha256Hasher::new();
    let mut stream = request.into_body().into_data_stream();
    let mut written: u64 = resume_offset;

    while let Some(chunk) = stream.next().await {
        let chunk = match chunk {
            Ok(c) => c,
            Err(e) => {
                state.sessions.write().await.remove(&transfer_id);
                return (StatusCode::BAD_REQUEST, format!("stream error: {e}")).into_response();
            }
        };
        if session.is_cancelled() {
            state.sessions.write().await.remove(&transfer_id);
            let _ = tokio::fs::remove_file(&staging_path).await;
            return (StatusCode::from_u16(499).unwrap(), "transfer cancelled").into_response();
        }
        while session.is_paused() {
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        }

        hasher.update(&chunk);
        if let Err(e) = file.write_all(&chunk).await {
            state.sessions.write().await.remove(&transfer_id);
            return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response();
        }
        written += chunk.len() as u64;
        session.add_bytes(chunk.len() as u64);
    }

    if let Err(e) = file.flush().await {
        return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response();
    }
    drop(file);

    if written != total_size {
        // Partial upload (connection dropped mid-stream). Leave the
        // `.part` file in place so the sender can resume later via
        // `Content-Range`; do not treat as fatal.
        state.sessions.write().await.remove(&transfer_id);
        return (
            StatusCode::PARTIAL_CONTENT,
            format!("received {written} of {total_size} bytes; resumable"),
        )
            .into_response();
    }

    if let Some(expected) = &expected_sha256 {
        // Note: this hashes only the bytes streamed in THIS request. For a
        // resumed transfer (resume_offset > 0) this hasher didn't see the
        // earlier bytes, so we re-hash the full file from disk instead to
        // get a correct end-to-end digest. See docs/PROTOCOL.md "SHA-256
        // Verification Flow".
        let actual = if resume_offset == 0 {
            hasher.finalize_hex()
        } else {
            match crate::security::sha256_file(&staging_path).await {
                Ok(h) => h,
                Err(e) => return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
            }
        };
        if &actual != expected {
            state.sessions.write().await.remove(&transfer_id);
            let _ = tokio::fs::remove_file(&staging_path).await;
            return (
                StatusCode::UNPROCESSABLE_ENTITY,
                format!("checksum mismatch: expected {expected}, got {actual}"),
            )
                .into_response();
        }
    }

    if let Err(e) = tokio::fs::rename(&staging_path, &final_path).await {
        return (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response();
    }

    state.sessions.write().await.remove(&transfer_id);
    (StatusCode::OK, "transfer complete").into_response()
}

fn parse_resume_offset(headers: &HeaderMap) -> Option<u64> {
    let raw = headers.get("Content-Range")?.to_str().ok()?;
    // Format: "bytes START-END/TOTAL"
    let after_bytes = raw.strip_prefix("bytes ")?;
    let start = after_bytes.split('-').next()?;
    start.parse().ok()
}
