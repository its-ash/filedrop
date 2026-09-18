//! Filename sanitization for received files.

/// Reserved device names on Windows that cannot be used as filenames
/// regardless of extension (e.g. `CON.txt` is still invalid).
const WINDOWS_RESERVED: &[&str] = &[
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

const MAX_FILENAME_LEN: usize = 255;

/// Sanitizes an untrusted filename received over the wire into something
/// safe to create on disk across macOS, Linux, and Windows filesystems.
///
/// - Strips any path separators (`/`, `\`) and `..` sequences.
/// - Strips control characters and characters invalid on Windows/NTFS.
/// - Trims leading/trailing dots and whitespace (Windows disallows trailing
///   dots/spaces; leading dots create hidden files on Unix unintentionally).
/// - Falls back to `unnamed_file` if the result is empty.
/// - Rejects Windows-reserved device names by appending an underscore.
/// - Truncates to `MAX_FILENAME_LEN` bytes, preserving the extension.
pub fn sanitize_filename(untrusted: &str) -> String {
    let no_path = untrusted
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(untrusted);

    let filtered: String = no_path
        .chars()
        .filter(|c| !matches!(c, '<' | '>' | ':' | '"' | '|' | '?' | '*') && !c.is_control())
        .collect();

    let trimmed = filtered.trim_matches(|c: char| c == '.' || c.is_whitespace());

    let mut result = if trimmed.is_empty() {
        "unnamed_file".to_string()
    } else {
        trimmed.to_string()
    };

    let stem_upper = result
        .split('.')
        .next()
        .unwrap_or(&result)
        .to_ascii_uppercase();
    if WINDOWS_RESERVED.contains(&stem_upper.as_str()) {
        result = format!("_{result}");
    }

    if result.len() > MAX_FILENAME_LEN {
        let (stem, ext) = match result.rfind('.') {
            Some(idx) if idx > 0 => (&result[..idx], &result[idx..]),
            _ => (result.as_str(), ""),
        };
        let keep = MAX_FILENAME_LEN.saturating_sub(ext.len());
        let mut truncated_stem = stem.to_string();
        truncated_stem.truncate(keep);
        result = format!("{truncated_stem}{ext}");
    }

    result
}
