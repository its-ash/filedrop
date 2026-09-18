# FFI Interface: Rust <-> Dart Contract

This document is the API contract between `rust/filedrop-ffi` and the
Flutter app (Android-only build; see `docs/ARCHITECTURE.md` "Build
target"). The live boundary is `flutter_rust_bridge` 2.13.0-generated
bindings (`flutter/lib/src/rust/`, `rust/filedrop-ffi/src/frb_generated.rs`,
regenerated from `api.rs` via `flutter_rust_bridge_codegen generate`,
config in `flutter_rust_bridge.yaml` at the repo root) — Dart calls
through this generated layer exclusively.

On Android, the generated bridge loads the native library via the
standard Android convention: `libfiledrop_ffi.so` files cross-compiled
with `cargo-ndk` and bundled under
`flutter/android/app/src/main/jniLibs/<abi>/`, found automatically by
the Android runtime's native library search path — no filesystem path
is configured on the Dart side.

## Why two layers

- **`api.rs`** — plain `pub async fn` functions taking/returning
  serde-friendly types. This is what `flutter_rust_bridge_codegen`
  introspects directly to generate the Dart bindings in
  `flutter/lib/src/rust/`.
- **`c_abi.rs`** — the original hand-written `#[no_mangle] extern "C"`
  wrappers around `api.rs`. Superseded by the FRB-generated bridge as
  the boundary Dart actually calls; kept in the workspace, unused, as a
  documented lower-level ABI in case a non-Dart consumer is ever needed.

Every function below is described once; both layers implement it
identically in spirit (the C ABI adds JSON string marshalling and a
`{"ok": bool, ...}` envelope, documented per-function in `c_abi.rs`'s doc
comments).

## Calls

| Function | Signature (conceptual) | Notes |
|---|---|---|
| `start_server` | `() -> Result<{address, port}, String>` | Binds the axum HTTP server on a free port (53317, scanning up to 53350). |
| `stop_server` | `() -> Result<(), String>` | Graceful shutdown via a oneshot channel. |
| `start_discovery` | `(self_device) -> Result<(), String>` | Starts mDNS advertise+browse and UDP broadcast announce+listen. Results arrive as `DeviceDiscovered` events, not a return value. |
| `stop_discovery` | `() -> Result<(), String>` | Tears down the running discovery service (mDNS daemon + UDP broadcast sockets), if any. The handle is retained in `FfiRuntime` across the `start_discovery`/`stop_discovery` call pair. |
| `get_nearby_devices` | `() -> Result<Vec<Device>, String>` | Point-in-time snapshot read from the running `DiscoveryService`'s in-memory device cache (empty if discovery hasn't been started, or has been stopped). |
| `pair_device` | `(peer_device_id, peer_name) -> Result<QrPairingPayload, String>` | Generates a token + QR payload, registers a pending pairing request, emits `PairingRequested`. |
| `send_files` | `(peer_address, peer_port, peer_device_id, file_paths) -> Result<Vec<TransferId>, String>` | Queues each file, returns transfer IDs immediately; progress via events. |
| `accept_transfer` | `(transfer_id) -> Result<(), String>` | Confirms a pending pairing/transfer request. |
| `reject_transfer` | `(transfer_id) -> Result<(), String>` | Rejects it. |
| `pause_transfer` | `(transfer_id) -> Result<(), String>` | Sets the session's pause flag; the chunk loop checks it between chunks. |
| `resume_transfer` | `(transfer_id) -> Result<(), String>` | Clears the pause flag. |
| `cancel_transfer` | `(transfer_id) -> Result<(), String>` | Sets the cancel flag; the chunk loop aborts and deletes the partial file. |
| `get_transfer_status` | `(transfer_id) -> Result<TransferProgress, String>` | Point-in-time progress snapshot for an active transfer. |
| `get_transfer_history` | `() -> Result<Vec<TransferRecord>, String>` | Full persisted history (see `storage::HistoryStore`). |
| `init_engine` | `(device_name, app_data_dir) -> Result<DeviceId, String>` | Must be called once before anything else. |

## Events

Delivered as a single tagged union, `FileDropEvent` (`filedrop-ffi/src/events.rs`),
serialized as `{"type": "<Variant>", "data": {...}}`:

| Variant | Payload | Emitted when |
|---|---|---|
| `DeviceDiscovered` | `{ device: Device }` | mDNS or UDP broadcast resolves a peer. |
| `DeviceConnected` | `{ device_id }` | Reserved for when a live connection (as opposed to a one-shot discovery ping) is established. |
| `PairingRequested` | `{ device_id, device_name, token }` | A pairing request enters `AwaitingConfirmation`, or (in `pair_device`) is freshly created locally. |
| `TransferStarted` | `{ transfer_id, file_name, total_bytes }` | A queued transfer's chunk loop begins. |
| `TransferProgress` | `{ progress: TransferProgress }` | Periodically during an active transfer (roughly once per chunk). |
| `TransferPaused` | `{ transfer_id }` | `pause_transfer` was called. |
| `TransferCompleted` | `{ transfer_id, sha256 }` | Transfer finished and (if applicable) checksum-verified. |
| `TransferFailed` | `{ transfer_id, error }` | Network error, checksum mismatch, or filesystem error. |
| `DeviceDisconnected` | `{ device_id }` | Reserved for LAN presence timeout / explicit disconnect. |

### Delivery mechanism

- **Live (FRB-generated bridge)**: `subscribe_events` takes an FRB
  `StreamSink<FileDropEventDto>`, giving Dart a real `Stream` with push
  delivery — `RustLib.instance.api.crateApiSubscribeEvents()`, surfaced
  publicly as `FileDropFfiService.events`. Backed by the same
  `tokio::sync::broadcast` channel with one persistent receiver on the
  Rust side described in the doc comment on `FfiRuntime::poll_rx`.
- **Legacy (hand-written `c_abi.rs`, unused by Dart)**: `filedrop_poll_event()`
  polling and a JSON `{"ok": bool, ...}` envelope. Kept in the workspace
  for reference/non-Dart consumers only.

## Error handling

Every fallible call returns `Result<T, String>` on the Rust side. FRB
maps a Rust `Err` to a thrown Dart exception natively, which is why every
public `FileDropFfiService` method's Dart signature is a plain
`Future<T>` (errors surface as exceptions, not a wrapper type). The
unused legacy C ABI instead encodes failure as a JSON envelope:

```json
{"ok": false, "error": "transfer 3f2...  not active"}
```

## Memory ownership (legacy hand-written ABI only, unused by Dart)

Every `*mut c_char` returned by a `filedrop_*` function is heap-allocated
on the Rust side and **must** be released by calling
`filedrop_free_string` exactly once. Never free it with Dart's own
allocator or C's `free()` — allocator mismatches across the FFI boundary
are undefined behavior. This concern does not apply to the live
FRB-generated bridge, which manages this automatically.
