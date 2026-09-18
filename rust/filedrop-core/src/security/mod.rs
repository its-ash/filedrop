//! Security-sensitive helpers: path traversal prevention, filename
//! sanitization, pairing token validation, and SHA-256 verification.
//!
//! Every file that touches disk (received transfers, history metadata)
//! MUST go through [`sanitize_filename`] and [`safe_join`] before any
//! filesystem call. Never trust a filename or relative path that arrived
//! over the network.

mod checksum;
mod filename;
mod path;
mod token;

pub use checksum::{sha256_file, Sha256Hasher};
pub use filename::sanitize_filename;
pub use path::safe_join;
pub use token::{tokens_match, validate_token_format, TOKEN_BYTE_LEN};

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn rejects_parent_traversal() {
        let base = Path::new("/tmp/filedrop/received");
        assert!(safe_join(base, "../../etc/passwd").is_err());
        assert!(safe_join(base, "..\\..\\windows\\system32").is_err());
    }

    #[test]
    fn accepts_plain_filename() {
        let base = Path::new("/tmp/filedrop/received");
        assert!(safe_join(base, "report.pdf").is_ok());
    }

    #[test]
    fn sanitizes_dangerous_characters() {
        let cleaned = sanitize_filename("../../../etc/passwd");
        assert!(!cleaned.contains(".."));
        assert!(!cleaned.contains('/'));
    }
}
