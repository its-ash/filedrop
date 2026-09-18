# FileDrop Architecture

FileDrop is an Android-only, local-first file-transfer app. There is no
cloud backend, no account system, and no central database — every
transfer happens directly between two devices over LAN or a transient
direct link, and every piece of state lives on-device. The wire protocol
and peer-discovery model are platform-agnostic (a FileDrop peer may run
on any OS in principle), but this app is built and shipped for Android
only — see "Build target" below.

## High-level components

```
+----------------------------------------------------------------+
|                         Flutter App (Dart)                     |
|  Screens (Home, Nearby Devices, File Picker, Send Confirmation,|
|  Incoming Transfer, Active Transfers, History, Network Setup,  |
|  Settings) -- Riverpod state -- FileDropFfiService              |
+---------------------------+--------------------------------------+
                            | FFI (flutter_rust_bridge 2.13.0-generated
                            | bindings; see docs/FFI_INTERFACE.md)
+---------------------------v--------------------------------------+
|                     filedrop-ffi (Rust cdylib)                 |
|  api.rs (safe async surface) -- events.rs -- c_abi.rs -- runtime|
+---------------------------+--------------------------------------+
                            |
+---------------------------v--------------------------------------+
|                    filedrop-core (Rust lib)                    |
|  discovery/  networking/  transfer/  pairing/  security/       |
|  storage/                                                       |
+---------------------------+--------------------------------------+
                            | HTTP / WebSocket (axum), LAN sockets
                            v
                    +-------+--------+
                    |  Peer device   |
                    | (same stack)   |
                    +----------------+

        [optional] nginx reverse proxy in front of the axum server
        (nginx/filedrop.conf.example) -- server runs standalone without it.
```

## Why this split

- **Flutter** owns UI, platform lifecycle, and anything that must call a
  native OS API not reachable from Rust (permissions, hotspot/Wi-Fi
  Direct system dialogs, file pickers, notifications).
- **Rust (`filedrop-core`)** owns everything platform-agnostic and
  performance/correctness-sensitive: chunked streaming I/O, the wire
  protocol, discovery, security-sensitive path/filename handling, and
  persistence. This is also the part most worth having memory-safe and
  fast, since it moves the actual file bytes.
- **`filedrop-ffi`** is a thin boundary crate. It never contains business
  logic — only (de)serialization, a shared tokio runtime, and event
  plumbing to Dart. See `docs/FFI_INTERFACE.md`.

## Two network modes

### 1. Existing LAN (fully implemented)

Both devices are already on the same Wi-Fi/Ethernet network. FileDrop:

1. Advertises itself via mDNS/DNS-SD (`_filedrop._tcp.local.`) using the
   `mdns-sd` crate, and simultaneously broadcasts a small JSON
   announcement over UDP port 53318 as a fallback for networks that
   filter multicast traffic (common on some corporate/guest Wi-Fi) — see
   `rust/filedrop-core/src/discovery/`.
2. Once a peer is discovered, an HTTP `POST` to `/api/v1/transfer/:id`
   on the peer's resolved `address:port` starts the actual file
   transfer, streamed in 1 MiB chunks in both directions — see
   `docs/PROTOCOL.md`.

This path requires no platform-specific native code at all; it is pure
Rust (`filedrop-core::discovery`, `filedrop-core::transfer`) driven
through the FFI layer.

### 2. No router / direct connect (partially implemented — platform work
required)

When there's no shared network (e.g. two devices in a location with no
Wi-Fi, or on networks that isolate clients from each other), FileDrop
needs to establish a transient direct link first. **This part is
inherently platform-specific system API territory and cannot be
implemented generically in Rust.** `filedrop-core::networking::mode`
documents, per platform, exactly which native API is required and why —
this table describes the capability-negotiation surface for *peer*
devices in the wire protocol (a peer may run on any OS), not this app's
own build target, which is Android-only:

| Platform | Mechanism | Why Rust can't do it alone |
|---|---|---|
| Android | Wi-Fi Direct via `android.net.wifi.p2p.WifiP2pManager` | Java/Kotlin Android framework service reached over Binder IPC; no NDK/Rust binding exists. Must be driven from Kotlin via a Flutter `MethodChannel`. |
| macOS | Local-only hotspot / direct Bonjour link via `NEHotspotConfiguration` / `Network.framework` | Swift/Objective-C only, gated by the Hotspot Configuration entitlement and system UI. Must be driven from Swift via a platform channel. |
| Windows | `Windows.Devices.WiFiDirect` (WinRT) | Reachable from Rust in principle via the `windows` crate, but needs a Windows target, appxmanifest capability declarations, and real hardware to validate — deferred to a Windows-focused pass. |
| Linux | NetworkManager D-Bus hotspot API | The one "no router" platform that could plausibly be implemented in pure Rust (e.g. via the `zbus` crate) without a Flutter platform channel. Deferred to a later pass rather than half-implemented. |
| iOS | No usable direct-connect API available to third-party apps without MultipeerConnectivity, which is a different transport model than this project's TCP/HTTP wire protocol | Not attempted in this pass; `Unsupported`. |

This app itself only ever runs the Android row of this table (see
`flutter/lib/screens/network_setup_screen.dart`); the other rows remain
documented here because a FileDrop peer on another OS is a valid remote
endpoint in the wire protocol's `platform` field, even though this app
is not built for those OSes.

Each of these is stubbed in `filedrop-core::networking::mode` as a
`PlatformDirectCapability::RequiresPlatformChannel { mode, reason }`
value with a `TODO(phase5):` comment explaining exactly what native call
is needed — never faked as working. **Once any of these mechanisms
establishes a link** (by whatever platform-specific means), the
resulting IP connection is handed to the exact same
`ConnectionMode::ExistingLan`-shaped code path: mDNS/UDP discovery and
the chunked HTTP transfer protocol run completely unmodified over it.

## Data flow for a single file send

1. User picks files (File Picker screen) and a target device (Nearby
   Devices screen, populated by `DeviceDiscoveredEvent`s).
2. Send Confirmation screen calls `send_files` (FFI), which enqueues a
   `QueuedTransfer` per file in `filedrop-core::transfer::TransferQueue`
   and spawns a task per file (bounded to `MAX_PARALLEL_TRANSFERS = 3`
   concurrent transfers via a semaphore).
3. Each task calls `filedrop-core::transfer::send_file`, which streams
   the file in `CHUNK_SIZE` (1 MiB) pieces over HTTP directly to the
   peer's `/api/v1/transfer/:id` endpoint — never loading the whole file
   into memory.
4. The receiving device's axum server (`filedrop-core::transfer::server`)
   streams the request body straight to a `.part` staging file, verifies
   the SHA-256 checksum once complete, and atomically renames it into
   the received-files directory.
5. Progress is tracked via a shared `TransferSession` (atomic byte
   counter + pause/cancel flags) and surfaced to Dart as
   `TransferProgress` events roughly every chunk.
6. On completion, both sides record a `TransferRecord` in
   `filedrop-core::storage::HistoryStore` (plain JSON file, atomic
   write-then-rename).

## Persistence

Deliberately simple: JSON files under the app's data directory rather
than an embedded database. See the design note at the top of
`rust/filedrop-core/src/storage/mod.rs` for the reasoning (small dataset,
single-user, crash-safety via write-to-temp + rename, and trivial to
inspect/debug by hand).

## Build target

FileDrop ships for Android only. `rust/filedrop-ffi` (a `cdylib`) is
cross-compiled with `cargo-ndk` to `aarch64-linux-android` (arm64-v8a)
and `x86_64-linux-android` (emulator/x86_64 devices); the resulting
`libfiledrop_ffi.so` files are placed directly under
`flutter/android/app/src/main/jniLibs/<abi>/`, which is the standard
Flutter/Android convention — the Android runtime's normal native library
search path finds and loads them automatically (`System.loadLibrary` /
`DynamicLibrary.open('libfiledrop_ffi.so')`), with no Dart-side path
configuration needed. See the root `Makefile`'s `run`/`build` targets for
the exact `cargo ndk` invocation.

iOS, macOS, Linux, and Windows Flutter targets have been removed from
this repository; there is no desktop or iOS build path.

## Known limitations of this pass

- No-router direct-connect modes are stubbed per the table above; only
  `ExistingLan` is exercised end-to-end.
