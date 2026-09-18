//! Transfer history: a durable record of past sends/receives, independent
//! of the live in-memory transfer queue in [`crate::transfer`].

use crate::error::Result;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TransferRecordStatus {
    Completed,
    Failed,
    Cancelled,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TransferRecord {
    pub id: Uuid,
    pub file_name: String,
    pub file_size_bytes: u64,
    pub peer_device_id: Uuid,
    pub peer_name: String,
    /// True if this device was the sender; false if it was the receiver.
    pub outgoing: bool,
    pub status: TransferRecordStatus,
    pub sha256: Option<String>,
    pub started_at: i64,
    pub completed_at: i64,
    /// Absolute path on disk for received files; `None` for sent files.
    pub saved_path: Option<PathBuf>,
}

/// Append-only(ish) JSON-backed history store. Reads the whole file into
/// memory on load (fine for a local history of this scale) and persists
/// via write-to-temp-file + atomic rename on every mutation, so a crash
/// mid-write can never corrupt the store.
pub struct HistoryStore {
    path: PathBuf,
    records: Arc<RwLock<HashMap<Uuid, TransferRecord>>>,
}

impl HistoryStore {
    /// Loads history from `path`, creating an empty store if the file
    /// doesn't exist yet.
    pub async fn load(path: PathBuf) -> Result<Self> {
        let records = if tokio::fs::try_exists(&path).await.unwrap_or(false) {
            let raw = tokio::fs::read(&path).await?;
            if raw.is_empty() {
                HashMap::new()
            } else {
                let list: Vec<TransferRecord> = serde_json::from_slice(&raw)?;
                list.into_iter().map(|r| (r.id, r)).collect()
            }
        } else {
            HashMap::new()
        };

        Ok(Self {
            path,
            records: Arc::new(RwLock::new(records)),
        })
    }

    pub async fn add(&self, record: TransferRecord) -> Result<()> {
        {
            let mut guard = self.records.write().await;
            guard.insert(record.id, record);
        }
        self.persist().await
    }

    pub async fn list(&self) -> Vec<TransferRecord> {
        let mut records: Vec<_> = self.records.read().await.values().cloned().collect();
        records.sort_by_key(|r| std::cmp::Reverse(r.completed_at));
        records
    }

    pub async fn get(&self, id: Uuid) -> Option<TransferRecord> {
        self.records.read().await.get(&id).cloned()
    }

    pub async fn clear(&self) -> Result<()> {
        self.records.write().await.clear();
        self.persist().await
    }

    async fn persist(&self) -> Result<()> {
        let list: Vec<TransferRecord> = self.records.read().await.values().cloned().collect();
        let json = serde_json::to_vec_pretty(&list)?;

        let tmp_path = self.path.with_extension("json.tmp");
        if let Some(parent) = self.path.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        tokio::fs::write(&tmp_path, json).await?;
        tokio::fs::rename(&tmp_path, &self.path).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn round_trips_through_disk() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("history.json");

        let store = HistoryStore::load(path.clone()).await.unwrap();
        let record = TransferRecord {
            id: Uuid::new_v4(),
            file_name: "photo.jpg".into(),
            file_size_bytes: 1024,
            peer_device_id: Uuid::new_v4(),
            peer_name: "Ashvini's MacBook".into(),
            outgoing: true,
            status: TransferRecordStatus::Completed,
            sha256: Some("deadbeef".into()),
            started_at: 100,
            completed_at: 200,
            saved_path: None,
        };
        store.add(record.clone()).await.unwrap();

        let reloaded = HistoryStore::load(path).await.unwrap();
        let listed = reloaded.list().await;
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, record.id);
    }
}
