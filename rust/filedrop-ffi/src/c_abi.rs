//! Hand-written `#[no_mangle] extern "C"` ABI, used only until
//! `flutter_rust_bridge_codegen generate` is run in this environment (see
//! the note at the top of `Cargo.toml`). Once codegen is available, the
//! generated bridge in `flutter/lib/src/rust/` calls into `api.rs`
//! directly and this file becomes optional.
//!
//! ## Design
//! - All Dart-facing arguments/returns cross the boundary as UTF-8,
//!   NUL-terminated `*const c_char` / `*mut c_char` JSON strings. This
//!   keeps the ABI stable and simple (no struct layout to keep in sync)
//!   at the cost of a JSON encode/decode per call — negligible next to
//!   network I/O for a file-transfer app.
//! - Every `extern "C"` function is synchronous from the caller's
//!   perspective (returns immediately) but dispatches the real async
//!   work onto the shared tokio runtime; long-running results are
//!   delivered via the event stream (`filedrop_poll_event`), not a
//!   blocking return value, matching how the eventual FRB stream-based
//!   API will behave.
//! - Strings returned to Dart are heap-allocated with `CString::into_raw`
//!   and MUST be freed by calling [`filedrop_free_string`] exactly once.
//!   Never call Rust's `free`/`drop` from Dart directly — allocator
//!   mismatches across the FFI boundary are undefined behavior.

use crate::api;
use crate::events::FileDropEvent;
use crate::runtime::runtime;
use std::ffi::{c_char, CStr, CString};
use tokio::sync::broadcast;
use uuid::Uuid;

/// Converts a Rust `String` into a heap-allocated, NUL-terminated C
/// string the caller owns and must release via [`filedrop_free_string`].
fn to_c_string(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(cs) => cs.into_raw(),
        Err(_) => CString::new("{\"error\":\"interior NUL in response\"}")
            .unwrap()
            .into_raw(),
    }
}

/// Reads a `*const c_char` argument from Dart into an owned `String`.
/// Returns `None` if the pointer is null or not valid UTF-8.
///
/// # Safety
/// `ptr` must be a valid pointer to a NUL-terminated UTF-8 C string, or
/// null, for the duration of this call.
unsafe fn from_c_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(str::to_string)
}

/// Frees a string previously returned by any `filedrop_*` function.
/// Calling this on a pointer not obtained from this library, or calling
/// it twice on the same pointer, is undefined behavior.
///
/// # Safety
/// `ptr` must be a pointer previously returned by a `filedrop_*`
/// function and not yet freed.
#[no_mangle]
pub unsafe extern "C" fn filedrop_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

/// Initializes logging + the core engine. `device_name` and
/// `app_data_dir` are NUL-terminated UTF-8 strings. Returns a JSON string
/// `{"ok": true, "device_id": "..."}` or `{"ok": false, "error": "..."}`.
///
/// # Safety
/// `device_name` and `app_data_dir` must be valid NUL-terminated UTF-8 C
/// strings for the duration of this call.
#[no_mangle]
pub unsafe extern "C" fn filedrop_init_engine(
    device_name: *const c_char,
    app_data_dir: *const c_char,
) -> *mut c_char {
    let Some(device_name) = from_c_string(device_name) else {
        return to_c_string(json_err("invalid device_name"));
    };
    let Some(app_data_dir) = from_c_string(app_data_dir) else {
        return to_c_string(json_err("invalid app_data_dir"));
    };

    let result = runtime()
        .tokio
        .block_on(api::init_engine(device_name, app_data_dir));

    to_c_string(match result {
        Ok(device_id) => format!(r#"{{"ok":true,"device_id":"{device_id}"}}"#),
        Err(e) => json_err(&e),
    })
}

/// Starts the HTTP/WebSocket transfer server. Returns JSON
/// `{"ok":true,"address":"...","port":N}` or an error envelope.
#[no_mangle]
pub extern "C" fn filedrop_start_server() -> *mut c_char {
    let result = runtime().tokio.block_on(api::start_server());
    to_c_string(match result {
        Ok(endpoint) => serde_json::to_string(&endpoint)
            .map(|body| format!(r#"{{"ok":true,"endpoint":{body}}}"#))
            .unwrap_or_else(|_| json_err("serialization failure")),
        Err(e) => json_err(&e),
    })
}

#[no_mangle]
pub extern "C" fn filedrop_stop_server() -> *mut c_char {
    let result = runtime().tokio.block_on(api::stop_server());
    to_c_string(ok_or_err(result))
}

/// Starts discovery for the given self-device JSON payload
/// (`DiscoveredDeviceDto`).
///
/// # Safety
/// `self_device_json` must be a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn filedrop_start_discovery(self_device_json: *const c_char) -> *mut c_char {
    let Some(json) = from_c_string(self_device_json) else {
        return to_c_string(json_err("invalid self_device_json"));
    };
    let dto: api::DiscoveredDeviceDto = match serde_json::from_str(&json) {
        Ok(d) => d,
        Err(e) => return to_c_string(json_err(&format!("bad device json: {e}"))),
    };
    let result = runtime().tokio.block_on(api::start_discovery(dto));
    to_c_string(ok_or_err(result))
}

#[no_mangle]
pub extern "C" fn filedrop_stop_discovery() -> *mut c_char {
    let result = runtime().tokio.block_on(api::stop_discovery());
    to_c_string(ok_or_err(result))
}

#[no_mangle]
pub extern "C" fn filedrop_get_nearby_devices() -> *mut c_char {
    let result = runtime().tokio.block_on(api::get_nearby_devices());
    to_c_string(match result {
        Ok(devices) => serde_json::to_string(&devices)
            .unwrap_or_else(|_| "[]".to_string()),
        Err(e) => json_err(&e),
    })
}

/// # Safety
/// `peer_device_id` and `peer_name` must be valid NUL-terminated UTF-8 C
/// strings.
#[no_mangle]
pub unsafe extern "C" fn filedrop_pair_device(
    peer_device_id: *const c_char,
    peer_name: *const c_char,
) -> *mut c_char {
    let (Some(id_str), Some(name)) = (from_c_string(peer_device_id), from_c_string(peer_name))
    else {
        return to_c_string(json_err("invalid arguments"));
    };
    let Ok(id) = Uuid::parse_str(&id_str) else {
        return to_c_string(json_err("invalid peer_device_id"));
    };

    let result = runtime().tokio.block_on(api::pair_device(id, name));
    to_c_string(match result {
        Ok(payload) => serde_json::to_string(&payload)
            .map(|body| format!(r#"{{"ok":true,"payload":{body}}}"#))
            .unwrap_or_else(|_| json_err("serialization failure")),
        Err(e) => json_err(&e),
    })
}

/// `request_json`: `{"peer_address":"...","peer_port":N,"peer_device_id":"...","file_paths":["..."]}`
///
/// # Safety
/// `request_json` must be a valid NUL-terminated UTF-8 C string.
#[no_mangle]
pub unsafe extern "C" fn filedrop_send_files(request_json: *const c_char) -> *mut c_char {
    #[derive(serde::Deserialize)]
    struct Req {
        peer_address: String,
        peer_port: u16,
        peer_device_id: Uuid,
        file_paths: Vec<String>,
    }

    let Some(json) = from_c_string(request_json) else {
        return to_c_string(json_err("invalid request_json"));
    };
    let req: Req = match serde_json::from_str(&json) {
        Ok(r) => r,
        Err(e) => return to_c_string(json_err(&format!("bad request json: {e}"))),
    };

    let result = runtime().tokio.block_on(api::send_files(
        req.peer_address,
        req.peer_port,
        req.peer_device_id,
        req.file_paths,
    ));

    to_c_string(match result {
        Ok(ids) => serde_json::to_string(&ids)
            .map(|body| format!(r#"{{"ok":true,"transfer_ids":{body}}}"#))
            .unwrap_or_else(|_| json_err("serialization failure")),
        Err(e) => json_err(&e),
    })
}

macro_rules! transfer_id_fn {
    ($name:ident, $api_fn:path) => {
        /// # Safety
        /// `transfer_id` must be a valid NUL-terminated UTF-8 C string
        /// containing a UUID.
        #[no_mangle]
        pub unsafe extern "C" fn $name(transfer_id: *const c_char) -> *mut c_char {
            let Some(id_str) = from_c_string(transfer_id) else {
                return to_c_string(json_err("invalid transfer_id"));
            };
            let Ok(id) = Uuid::parse_str(&id_str) else {
                return to_c_string(json_err("transfer_id is not a valid UUID"));
            };
            let result = runtime().tokio.block_on($api_fn(id));
            to_c_string(ok_or_err(result))
        }
    };
}

transfer_id_fn!(filedrop_accept_transfer, api::accept_transfer);
transfer_id_fn!(filedrop_reject_transfer, api::reject_transfer);
transfer_id_fn!(filedrop_pause_transfer, api::pause_transfer);
transfer_id_fn!(filedrop_resume_transfer, api::resume_transfer);
transfer_id_fn!(filedrop_cancel_transfer, api::cancel_transfer);

/// # Safety
/// `transfer_id` must be a valid NUL-terminated UTF-8 C string containing
/// a UUID.
#[no_mangle]
pub unsafe extern "C" fn filedrop_get_transfer_status(transfer_id: *const c_char) -> *mut c_char {
    let Some(id_str) = from_c_string(transfer_id) else {
        return to_c_string(json_err("invalid transfer_id"));
    };
    let Ok(id) = Uuid::parse_str(&id_str) else {
        return to_c_string(json_err("transfer_id is not a valid UUID"));
    };
    let result = runtime().tokio.block_on(api::get_transfer_status(id));
    to_c_string(match result {
        Ok(progress) => serde_json::to_string(&progress)
            .map(|body| format!(r#"{{"ok":true,"progress":{body}}}"#))
            .unwrap_or_else(|_| json_err("serialization failure")),
        Err(e) => json_err(&e),
    })
}

#[no_mangle]
pub extern "C" fn filedrop_get_transfer_history() -> *mut c_char {
    let result = runtime().tokio.block_on(api::get_transfer_history());
    to_c_string(match result {
        Ok(history) => serde_json::to_string(&history).unwrap_or_else(|_| "[]".to_string()),
        Err(e) => json_err(&e),
    })
}

/// Polls the next queued event as a JSON string (see `events.rs`), or
/// returns `null` (the string `"null"`) if none is currently available.
/// Dart's service layer should call this in a loop (e.g. every 100ms via
/// a `Timer.periodic`, or ideally a dedicated polling isolate) until
/// `flutter_rust_bridge_codegen` replaces this with a real `StreamSink`
/// push-based subscription.
#[no_mangle]
pub extern "C" fn filedrop_poll_event() -> *mut c_char {
    let rt = runtime();
    let event: Option<FileDropEvent> = rt.tokio.block_on(async {
        let mut rx = rt.poll_rx.lock().await;
        match tokio::time::timeout(std::time::Duration::from_millis(50), rx.recv()).await {
            Ok(Ok(event)) => Some(event),
            // Lagged: this poller fell behind and the broadcast ring
            // buffer overwrote some events. Not fatal — resync by
            // continuing to the next available event rather than
            // returning stale/duplicate data.
            Ok(Err(broadcast::error::RecvError::Lagged(_))) => None,
            Ok(Err(broadcast::error::RecvError::Closed)) => None,
            Err(_elapsed) => None,
        }
    });
    to_c_string(match event {
        Some(e) => e.to_json(),
        None => "null".to_string(),
    })
}

fn json_err(msg: &str) -> String {
    format!(r#"{{"ok":false,"error":{}}}"#, serde_json::to_string(msg).unwrap_or_default())
}

fn ok_or_err(result: Result<(), String>) -> String {
    match result {
        Ok(()) => r#"{"ok":true}"#.to_string(),
        Err(e) => json_err(&e),
    }
}
