//! Persistence: transfer history, received-files location, and metadata.
//!
//! Design choice: plain JSON files on disk rather than `sled`, even though
//! `sled` is a workspace dependency (kept available for a future pass that
//! needs indexed queries over large histories). For a local-first single-user
//! app, history is small (hundreds to low-thousands of entries), so a single
//! JSON file guarded by an async `RwLock` is simpler to reason about, trivial
//! to inspect/debug by hand, and has zero risk of lock-file/db-corruption
//! issues across app restarts or crashes mid-write (we write via a temp file
//! + atomic rename).

mod history;
mod paths;

pub use history::{HistoryStore, TransferRecord, TransferRecordStatus};
pub use paths::StoragePaths;
