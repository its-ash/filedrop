//! Pairing token generation.

use crate::security::TOKEN_BYTE_LEN;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::Rng;

/// Generates a cryptographically random pairing token: 32 random bytes,
/// URL-safe base64 (unpadded) encoded, giving a 43-character token safe to
/// embed in a QR payload or short-lived UDP broadcast.
pub fn generate_pairing_token() -> String {
    let mut bytes = [0u8; TOKEN_BYTE_LEN];
    rand::rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}
