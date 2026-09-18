//! Process-wide runtime: a lazily-initialized tokio runtime, the
//! `FileDropEngine` singleton, and the global event broadcast channel
//! Dart subscribes to. Kept as a singleton because there is exactly one
//! FileDrop instance per app process.

use filedrop_core::discovery::DiscoveryService;
use filedrop_core::FileDropEngine;
use std::sync::{Arc, OnceLock};
use tokio::runtime::Runtime;
use tokio::sync::broadcast;

use crate::events::FileDropEvent;

/// Broadcast channel capacity: generous enough that a slow Dart-side
/// consumer doesn't drop events under normal transfer-progress cadence
/// (progress events are emitted at most a few times/sec per transfer).
const EVENT_CHANNEL_CAPACITY: usize = 1024;

pub struct FfiRuntime {
    pub tokio: Runtime,
    pub engine: tokio::sync::OnceCell<Arc<FileDropEngine>>,
    pub events_tx: broadcast::Sender<FileDropEvent>,
    /// Single persistent receiver used by `filedrop_poll_event`, so
    /// polling from Dart never misses events emitted between calls (each
    /// `broadcast::Sender::subscribe()` call only sees events sent AFTER
    /// it subscribes, so a fresh subscriber per poll would silently drop
    /// anything emitted in the gap).
    pub poll_rx: tokio::sync::Mutex<broadcast::Receiver<FileDropEvent>>,
    pub server_shutdown: tokio::sync::Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    /// Handle to the currently-running discovery service (mDNS + UDP
    /// broadcast listeners), retained across the `start_discovery` /
    /// `stop_discovery` FFI calls so `stop_discovery` can actually tear
    /// down the listeners instead of being a no-op, and so
    /// `get_nearby_devices` can read the service's live device cache
    /// on demand. `None` when discovery has not been started (or has
    /// been stopped).
    pub discovery: tokio::sync::Mutex<Option<Arc<DiscoveryService>>>,
}

impl FfiRuntime {
    fn new() -> Self {
        let tokio_rt = Runtime::new().expect("failed to start tokio runtime for filedrop-ffi");
        let (events_tx, poll_rx) = broadcast::channel(EVENT_CHANNEL_CAPACITY);
        Self {
            tokio: tokio_rt,
            engine: tokio::sync::OnceCell::new(),
            events_tx,
            poll_rx: tokio::sync::Mutex::new(poll_rx),
            server_shutdown: tokio::sync::Mutex::new(None),
            discovery: tokio::sync::Mutex::new(None),
        }
    }

    pub fn emit(&self, event: FileDropEvent) {
        // A send error just means no receiver is currently subscribed
        // (e.g. Dart hasn't called `subscribe_events` yet); that's not a
        // failure condition, events are fire-and-forget from Rust's side.
        let _ = self.events_tx.send(event);
    }
}

static RUNTIME: OnceLock<FfiRuntime> = OnceLock::new();

pub fn runtime() -> &'static FfiRuntime {
    RUNTIME.get_or_init(FfiRuntime::new)
}
