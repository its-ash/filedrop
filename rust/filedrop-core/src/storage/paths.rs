//! Resolves and creates the on-disk locations FileDrop uses: where
//! received files land, and where app metadata (history, config) is kept.

use std::path::PathBuf;

/// Filesystem locations used by FileDrop, rooted under a single
/// `app_data_dir` that the Flutter/platform layer provides (e.g. via
/// `path_provider`'s application support directory), since Rust has no
/// portable notion of "the right place" on mobile sandboxes.
#[derive(Debug, Clone)]
pub struct StoragePaths {
    pub app_data_dir: PathBuf,
}

impl StoragePaths {
    pub fn new(app_data_dir: impl Into<PathBuf>) -> Self {
        Self {
            app_data_dir: app_data_dir.into(),
        }
    }

    /// Directory incoming files are written into by default. Callers may
    /// override the destination per-transfer (e.g. user picks a folder),
    /// but this is the fallback used by [`crate::transfer`].
    pub fn received_files_dir(&self) -> PathBuf {
        self.app_data_dir.join("received")
    }

    /// Directory used for partially-received files (`.part` suffix) so a
    /// crash mid-transfer never leaves a half-written file at its final
    /// name.
    pub fn staging_dir(&self) -> PathBuf {
        self.app_data_dir.join("staging")
    }

    /// Path to the transfer history JSON store.
    pub fn history_file(&self) -> PathBuf {
        self.app_data_dir.join("history.json")
    }

    /// Ensures all directories this struct points to exist, creating them
    /// recursively if necessary. Should be called once at startup.
    pub async fn ensure_dirs(&self) -> std::io::Result<()> {
        tokio::fs::create_dir_all(&self.app_data_dir).await?;
        tokio::fs::create_dir_all(self.received_files_dir()).await?;
        tokio::fs::create_dir_all(self.staging_dir()).await?;
        Ok(())
    }
}
