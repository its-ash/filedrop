//! Event types streamed from Rust to Dart. In the eventual
//! flutter_rust_bridge-generated bridge, this enum becomes a Dart sealed
//! class (`FileDropEvent`) delivered via an FRB `StreamSink`; here it is
//! the payload serialized to JSON and pushed across the hand-written
//! event-stream ABI (see `c_abi.rs`).

use filedrop_core::discovery::DiscoveredDevice;
use filedrop_core::transfer::TransferProgress;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "data")]
pub enum FileDropEvent {
    DeviceDiscovered { device: DiscoveredDevice },
    DeviceConnected { device_id: Uuid },
    PairingRequested { device_id: Uuid, device_name: String, token: String },
    TransferStarted { transfer_id: Uuid, file_name: String, total_bytes: u64 },
    TransferProgress { progress: TransferProgress },
    TransferPaused { transfer_id: Uuid },
    TransferCompleted { transfer_id: Uuid, sha256: String },
    TransferFailed { transfer_id: Uuid, error: String },
    DeviceDisconnected { device_id: Uuid },
}

impl FileDropEvent {
    pub fn to_json(&self) -> String {
        serde_json::to_string(self).unwrap_or_else(|_| "{}".to_string())
    }
}
