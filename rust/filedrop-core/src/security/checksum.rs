//! SHA-256 verification for received files, streamed in fixed-size chunks
//! so the whole file never needs to sit in memory.

use crate::error::Result;
use sha2::{Digest, Sha256};
use std::path::Path;
use tokio::fs::File;
use tokio::io::{AsyncReadExt, BufReader};

/// Read buffer size for streaming hashing (1 MiB).
const HASH_BUF_SIZE: usize = 1024 * 1024;

/// Incremental SHA-256 hasher wrapper used while a file is being written
/// to disk during a transfer, so the digest is available the instant the
/// last chunk lands without a second read pass over the file.
#[derive(Default)]
pub struct Sha256Hasher {
    inner: Sha256,
}

impl Sha256Hasher {
    pub fn new() -> Self {
        Self { inner: Sha256::new() }
    }

    pub fn update(&mut self, chunk: &[u8]) {
        self.inner.update(chunk);
    }

    pub fn finalize_hex(self) -> String {
        hex_encode(&self.inner.finalize())
    }
}

/// Computes the SHA-256 digest of a file already on disk, streaming reads
/// in [`HASH_BUF_SIZE`] chunks. Used to (re-)verify received files, e.g.
/// after a resumed transfer completes.
pub async fn sha256_file(path: &Path) -> Result<String> {
    let file = File::open(path).await?;
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; HASH_BUF_SIZE];

    loop {
        let n = reader.read(&mut buf).await?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }

    Ok(hex_encode(&hasher.finalize()))
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::AsyncWriteExt;

    #[tokio::test]
    async fn hashes_known_content() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.txt");
        let mut f = File::create(&path).await.unwrap();
        f.write_all(b"hello world").await.unwrap();
        f.flush().await.unwrap();

        let digest = sha256_file(&path).await.unwrap();
        // Known SHA-256("hello world")
        assert_eq!(
            digest,
            "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
        );
    }
}
