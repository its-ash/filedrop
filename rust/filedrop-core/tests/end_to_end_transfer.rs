//! Integration test proving Phase 1 works end-to-end: a real axum server
//! bound to 127.0.0.1, and a real HTTP client streaming a file to it over
//! an actual TCP socket, verified byte-for-byte with SHA-256.

use filedrop_core::pairing::PairingStateMachine;
use filedrop_core::security::sha256_file;
use filedrop_core::storage::{HistoryStore, StoragePaths};
use filedrop_core::transfer::{build_router, send_file, AppState, SendOptions, TransferDirection, TransferSession};
use std::sync::Arc;
use uuid::Uuid;

#[tokio::test]
async fn sends_and_receives_a_real_file_over_tcp() {
    let dir = tempfile::tempdir().unwrap();
    let paths = Arc::new(StoragePaths::new(dir.path().join("appdata")));
    paths.ensure_dirs().await.unwrap();

    let history = Arc::new(HistoryStore::load(paths.history_file()).await.unwrap());
    let queue = Arc::new(filedrop_core::transfer::TransferQueue::new());
    let pairing = Arc::new(PairingStateMachine::new());
    let sessions = Arc::new(tokio::sync::RwLock::new(std::collections::HashMap::new()));

    let state = AppState {
        paths: paths.clone(),
        queue,
        history,
        pairing,
        sessions,
    };
    let app = build_router(state);

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    // Give the server a moment to start accepting.
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;

    // Create a source file large enough to span several chunks.
    let src_dir = tempfile::tempdir().unwrap();
    let src_path = src_dir.path().join("payload.bin");
    let payload: Vec<u8> = (0..(3 * 1024 * 1024 + 777))
        .map(|i| (i % 256) as u8)
        .collect();
    tokio::fs::write(&src_path, &payload).await.unwrap();
    let expected_hash = sha256_file(&src_path).await.unwrap();

    let transfer_id = Uuid::new_v4();
    let session = TransferSession::new(
        transfer_id,
        "payload.bin".to_string(),
        payload.len() as u64,
        TransferDirection::Send,
    );

    send_file(addr, transfer_id, &src_path, &session, SendOptions::default())
        .await
        .expect("send_file should succeed against the real server");

    let received_path = paths.received_files_dir().join("payload.bin");
    assert!(tokio::fs::try_exists(&received_path).await.unwrap());

    let received_hash = sha256_file(&received_path).await.unwrap();
    assert_eq!(received_hash, expected_hash);

    let received_bytes = tokio::fs::read(&received_path).await.unwrap();
    assert_eq!(received_bytes, payload);
}
