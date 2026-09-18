//! QR payload embedded in a scannable code shown by the "sender" device,
//! letting the "receiver" device pair without typing anything.
//!
//! Rendering the QR code image itself is a Flutter-side concern (e.g. via
//! a `qr_flutter` package); this struct only defines and (de)serializes the
//! payload that gets encoded into the QR code's data.

use serde::{Deserialize, Serialize};

/// Current version of the QR payload schema. Bump when the shape changes
/// so older/newer app versions can detect incompatibility instead of
/// silently misparsing.
pub const QR_PAYLOAD_VERSION: u8 = 1;

/// Data encoded into the pairing QR code. See `docs/PROTOCOL.md` for the
/// full pairing handshake this payload kicks off.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct QrPairingPayload {
    /// Schema version, see [`QR_PAYLOAD_VERSION`].
    pub version: u8,
    /// Stable device identifier of the device displaying the code.
    pub device_id: uuid::Uuid,
    /// Human-readable device name shown in the "Nearby Devices" list.
    pub device_name: String,
    /// IPv4 or IPv6 address the scanning device should connect to.
    pub address: String,
    /// TCP port the FileDrop HTTP/WebSocket server is listening on.
    pub port: u16,
    /// One-shot pairing token; the scanning device presents this back to
    /// prove it read the code rather than guessing the address/port.
    pub token: String,
    /// Unix timestamp (seconds) after which `token` is no longer valid.
    pub expires_at: i64,
}

impl QrPairingPayload {
    /// Serializes this payload to the compact JSON string that gets
    /// encoded into the QR code.
    pub fn to_qr_string(&self) -> crate::error::Result<String> {
        Ok(serde_json::to_string(self)?)
    }

    /// Parses a QR payload string produced by [`Self::to_qr_string`].
    pub fn from_qr_string(s: &str) -> crate::error::Result<Self> {
        Ok(serde_json::from_str(s)?)
    }
}
