//! Crate-wide error type shared across all `filedrop-core` modules.

use thiserror::Error;

/// Unified error type returned by `filedrop-core` public APIs.
#[derive(Debug, Error)]
pub enum FileDropError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),

    #[error("invalid or unsafe path: {0}")]
    UnsafePath(String),

    #[error("invalid filename: {0}")]
    InvalidFilename(String),

    #[error("pairing token invalid or expired")]
    InvalidPairingToken,

    #[error("checksum mismatch: expected {expected}, got {actual}")]
    ChecksumMismatch { expected: String, actual: String },

    #[error("transfer not found: {0}")]
    TransferNotFound(uuid::Uuid),

    #[error("device not found: {0}")]
    DeviceNotFound(uuid::Uuid),

    #[error("storage error: {0}")]
    Storage(String),

    #[error("discovery error: {0}")]
    Discovery(String),

    #[error("network error: {0}")]
    Network(String),

    #[error("serialization error: {0}")]
    Serde(#[from] serde_json::Error),

    #[error("operation not supported on this platform: {0}")]
    UnsupportedOnPlatform(String),

    #[error("invalid state transition: {0}")]
    InvalidState(String),
}

pub type Result<T> = std::result::Result<T, FileDropError>;
