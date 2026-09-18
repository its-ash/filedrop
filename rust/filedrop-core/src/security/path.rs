//! Path traversal prevention.

use crate::error::{FileDropError, Result};
use std::path::{Component, Path, PathBuf};

/// Joins `untrusted_relative` onto `base`, rejecting any path that would
/// escape `base` (parent-dir components, absolute paths, root/prefix
/// components, or embedded NUL bytes). Returns the resolved absolute path
/// under `base`.
///
/// This does NOT require the path to exist on disk (the destination file
/// for an incoming transfer usually doesn't yet), so it performs purely
/// lexical normalization rather than `canonicalize()`.
pub fn safe_join(base: &Path, untrusted_relative: &str) -> Result<PathBuf> {
    if untrusted_relative.contains('\0') {
        return Err(FileDropError::UnsafePath(
            "embedded NUL byte in path".into(),
        ));
    }
    if untrusted_relative.trim().is_empty() {
        return Err(FileDropError::UnsafePath("empty path".into()));
    }

    // Normalize Windows-style separators so traversal can't hide behind them
    // on platforms that don't treat '\\' as a separator natively.
    let normalized = untrusted_relative.replace('\\', "/");
    let candidate = Path::new(&normalized);

    let mut resolved = PathBuf::new();
    for component in candidate.components() {
        match component {
            Component::Normal(part) => resolved.push(part),
            Component::CurDir => {}
            Component::ParentDir => {
                return Err(FileDropError::UnsafePath(format!(
                    "parent directory traversal rejected: {untrusted_relative}"
                )));
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(FileDropError::UnsafePath(format!(
                    "absolute path rejected: {untrusted_relative}"
                )));
            }
        }
    }

    if resolved.as_os_str().is_empty() {
        return Err(FileDropError::UnsafePath("resolves to empty path".into()));
    }

    let joined = base.join(&resolved);

    // Belt-and-braces: ensure the resulting path still starts with `base`
    // lexically (protects against any component-parsing edge case above).
    if !joined.starts_with(base) {
        return Err(FileDropError::UnsafePath(format!(
            "resolved path escapes base directory: {untrusted_relative}"
        )));
    }

    Ok(joined)
}
