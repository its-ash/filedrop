//! File transfer engine: chunked streaming send/receive over HTTP, a
//! transfer queue, byte-range resume, and progress tracking.
//!
//! This module is the Phase 1 core: [`server::build_router`] +
//! [`client::send_file`] form a real, working axum-based HTTP file
//! transfer that streams chunks (never loading a full file into memory)
//! and supports resuming a partial transfer via a `Range` header, exactly
//! as documented in `docs/PROTOCOL.md`.

mod client;
mod progress;
mod queue;
mod server;
mod session;

pub use client::{send_file, SendOptions};
pub use progress::{TransferProgress, TransferStatus};
pub use queue::{TransferQueue, QueuedTransfer};
pub use server::{build_router, AppState};
pub use session::{TransferDirection, TransferSession};

/// Size of each streamed chunk read/write, in bytes (1 MiB). Chosen as a
/// balance between syscall overhead (too small) and responsiveness of
/// progress/pause signalling (too large). Documented in
/// `docs/PROTOCOL.md`.
pub const CHUNK_SIZE: usize = 1024 * 1024;
