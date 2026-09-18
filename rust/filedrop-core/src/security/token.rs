//! Pairing token validation. Token *generation* lives in [`crate::pairing`];
//! this module only validates the shape/format of a token presented by a
//! peer before it is looked up against in-memory pairing state.

use crate::error::{FileDropError, Result};

/// Number of random bytes backing a pairing token before base64 encoding.
pub const TOKEN_BYTE_LEN: usize = 32;

/// Base64 (URL-safe, unpadded) encoding of [`TOKEN_BYTE_LEN`] bytes.
const EXPECTED_ENCODED_LEN: usize = 43;

/// Validates that `token` has the expected length/charset of a FileDrop
/// pairing token. This is a cheap format check performed before the more
/// expensive constant-time comparison against the expected token; it does
/// NOT confirm the token is valid/unexpired — that is [`crate::pairing`]'s
/// responsibility.
pub fn validate_token_format(token: &str) -> Result<()> {
    if token.len() != EXPECTED_ENCODED_LEN {
        return Err(FileDropError::InvalidPairingToken);
    }
    let valid_charset = token
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if !valid_charset {
        return Err(FileDropError::InvalidPairingToken);
    }
    Ok(())
}

/// Constant-time comparison of two tokens to avoid timing side-channels
/// leaking how many leading bytes matched.
pub fn tokens_match(a: &str, b: &str) -> bool {
    let a = a.as_bytes();
    let b = b.as_bytes();
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}
