# FileDrop

Cross-device local file transfer for Android. No cloud, no accounts, no router required.

FileDrop moves files directly between nearby Android devices over Wi-Fi. When both devices are already on the same network, they discover each other automatically over mDNS. When there's no network at all, FileDrop creates a direct Wi-Fi Direct link between the two devices. Every transfer is streamed chunk-by-chunk straight from disk, resumable if interrupted, and verified end-to-end with SHA-256.

**[filedrop.itsash.in](https://filedrop.itsash.in)**

## Why

Sending a large file to someone in the same room shouldn't require uploading it to a server you don't control, waiting on your upload bandwidth, then having the other person download it back down. FileDrop skips all of that — the bytes go straight from one device to the other over the network that's already between you.

## How it works

1. **Send** — pick your files, pick the nearby device to send to.
2. **Receive** — FileDrop checks for a usable network. If you're already on Wi-Fi, it starts listening immediately. If there's no network, it offers to create a direct Wi-Fi Direct link.
3. **Transfer** — live progress, speed, and ETA; pause, resume, or cancel any transfer; every file is SHA-256 verified once it lands.

## Architecture

```
Flutter (Dart) — UI, platform lifecycle, native permission dialogs
      │ flutter_rust_bridge (FFI)
      ▼
filedrop-ffi (Rust cdylib) — thin async boundary, event stream to Dart
      │
      ▼
filedrop-core (Rust) — discovery · networking · transfer · pairing · security · storage
      │ HTTP/WebSocket (axum) over LAN or Wi-Fi Direct
      ▼
  Peer device (same stack)
```

Flutter handles UI and anything that must call a native Android API — permissions, Wi-Fi Direct system dialogs, file pickers. Rust owns everything platform-agnostic and performance-sensitive: chunked streaming I/O, the wire protocol, discovery, and security-sensitive path/filename handling.

Full writeups: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md), [docs/PROTOCOL.md](docs/PROTOCOL.md), [docs/FFI_INTERFACE.md](docs/FFI_INTERFACE.md).

## Project layout

```
filedrop/
├── flutter/           Android app (Flutter + Dart, Riverpod)
├── rust/
│   ├── filedrop-core/  discovery, networking, transfer, pairing, security, storage
│   └── filedrop-ffi/   flutter_rust_bridge boundary crate
├── nginx/              optional reverse-proxy config (not required to run)
├── docs/                architecture, wire protocol, FFI interface
└── index.html           this site
```

## Building

Requires Flutter, Rust with the Android targets (`rustup target add aarch64-linux-android x86_64-linux-android`), `cargo-ndk`, and the Android NDK.

```sh
make run     # cross-compile the Rust engine, run on a connected device/emulator
make build   # cross-compile + flutter build apk
```

## Security

- Devices pair via a temporary token, not a persistent credential.
- Filenames from remote peers are sanitized; paths are validated against traversal.
- Only files explicitly selected by the user are ever exposed to a transfer.
- Every transfer is verified with SHA-256 after completion.

## License

No license file is currently included in this repository.
