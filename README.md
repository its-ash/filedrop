# FileDrop

Send files to nearby phones without the internet.

**[Website](https://filedrop.itsash.in)** · **[Download APK](https://github.com/its-ash/filedrop/releases/latest/download/filedrop.apk)** · Get it in **[Ash Store](https://store.itsash.in)**

FileDrop moves files directly between nearby Android devices over Wi-Fi. When
both devices are on the same network, they find each other over mDNS. When
there is no network at all, FileDrop creates a direct Wi-Fi Direct link. Every
transfer streams chunk by chunk from disk, resumes if interrupted, and is
checked end to end with SHA-256.

## Features

- **Send**: pick your files, pick the nearby device.
- **Receive**: on Wi-Fi, FileDrop listens right away. With no network, it offers
  a direct Wi-Fi Direct link.
- **Transfer**: live progress, speed and ETA; pause, resume or cancel; every
  file is SHA-256 verified when it lands.
- **Secure**: devices pair with a temporary token; remote filenames are
  sanitized and paths checked against traversal; only files you pick are shared.
- No cloud, no account, no router required.

## Install

- **Ash Store**: install [Ash Store](https://store.itsash.in) once, then install and update FileDrop from it.
- **APK**: download the [latest APK](https://github.com/its-ash/filedrop/releases/latest/download/filedrop.apk) on your phone and open it. Allow your browser to install unknown apps if Android asks.

## Develop

Needs Flutter ≥ 3.44, the shared theme package, Rust with the Android targets
(`rustup target add aarch64-linux-android x86_64-linux-android`), `cargo-ndk`
and the Android NDK.

```bash
make run      # cross-compile the Rust engine, run on a connected device
make build    # cross-compile + release APK
make deploy   # bump version, build, tag, push, GitHub release (see store.mk)
```

## Release

`make deploy` follows the Ash Store kit (`store.mk`, `store.json`): it bumps the
version in `flutter/pubspec.yaml`, builds, commits, tags `vX.Y.Z`, pushes, and
publishes a GitHub release with `filedrop.apk`. Ash Store and the website pick
up the new version from that release.

## Project layout

```
filedrop/
├── flutter/            Android app (Flutter + Dart, Riverpod)
├── rust/
│   ├── filedrop-core/  discovery, networking, transfer, pairing, security, storage
│   └── filedrop-ffi/   flutter_rust_bridge boundary crate
├── nginx/              optional reverse-proxy config (not required to run)
├── docs/               architecture, wire protocol, FFI interface
└── index.html          landing page (GitHub Pages, filedrop.itsash.in)
```

```
Flutter (Dart): UI, platform lifecycle, native permission dialogs
      │ flutter_rust_bridge (FFI)
      ▼
filedrop-ffi (Rust cdylib): thin async boundary, event stream to Dart
      │
      ▼
filedrop-core (Rust): discovery · networking · transfer · pairing · security · storage
      │ HTTP/WebSocket (axum) over LAN or Wi-Fi Direct
      ▼
  Peer device (same stack)
```

Full writeups: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md),
[docs/PROTOCOL.md](docs/PROTOCOL.md), [docs/FFI_INTERFACE.md](docs/FFI_INTERFACE.md).

## License

No license file is included yet.

Built by [itsash.in](https://itsash.in).
