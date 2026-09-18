# FileDrop — Project Instructions

FileDrop is a cross-platform, local-first LAN file-transfer app. No
cloud, no accounts, no central database. Flutter/Dart frontend, Rust
native engine via FFI, optional Nginx reverse proxy.

## Architecture summary

```
Flutter app (flutter/) --FFI--> filedrop-ffi (rust/filedrop-ffi)
                                        |
                                 filedrop-core (rust/filedrop-core)
                                 discovery/ networking/ transfer/
                                 pairing/ security/ storage/
                                        |
                                 axum HTTP server <--LAN--> peer device
```

Full detail: `docs/ARCHITECTURE.md` (system design + per-platform
no-router limitations), `docs/PROTOCOL.md` (wire protocol), and
`docs/FFI_INTERFACE.md` (Rust<->Dart contract).

## Build & run

### Rust (`rust/`)

```sh
cd rust
cargo build --release          # builds filedrop-core + filedrop-ffi
cargo test                      # unit tests + the real end-to-end LAN transfer test
cargo build -p filedrop-core    # core lib only
cargo build -p filedrop-ffi     # FFI cdylib only
```

`filedrop-ffi` builds a `cdylib`/`staticlib` consumable from Dart via
`dart:ffi`. Its Dart-facing bindings are currently **hand-written**
(`rust/filedrop-ffi/src/c_abi.rs`) rather than generated, because
`flutter_rust_bridge_codegen` wasn't available when this project was
scaffolded. See the note at the top of `rust/filedrop-ffi/Cargo.toml`
for the exact migration steps once that tool is installed — it does not
require restructuring `api.rs`, which is already written in the
`pub async fn` shape FRB expects.

### Flutter (`flutter/`)

```sh
cd flutter
flutter pub get
flutter analyze
flutter test
flutter run                     # requires rust/ built first (see Makefile)
```

Flutter must link against the Rust `cdylib`/`staticlib` at build time;
until FRB codegen or manual `dart:ffi` wiring loads the real library,
`FileDropFfiService`'s `_RustBindings` throws `UnimplementedError` with a
message naming the exact `filedrop_*` C symbol each call maps to (see
`flutter/lib/services/filedrop_ffi_service.dart`).

### Whole project

```sh
make run       # cargo build --release && flutter run
make build     # cargo build --release && flutter build
make deploy    # build, then commit + push to main (see Makefile)
```

## Key conventions

- **State management**: Riverpod (`flutter_riverpod`), not Provider or
  Bloc. See `flutter/lib/providers/filedrop_providers.dart`.
- **Theming**: the shared `theme` package
  (`/Users/ashvinijangid/Desktop/android/theme`, `its-ash/theme` on
  GitHub) is the *only* source of `ThemeData` — `AppTheme.lightTheme()` /
  `AppTheme.darkTheme()` in `flutter/lib/main.dart`. Do not add a
  bespoke theme file; use the `ThemeX` component library
  (`ThemeCard`, `ThemeEmptyState`, `ThemeSectionHeader`, etc.) for new UI.
- **Chunked I/O only**: any code touching file bytes (`rust/filedrop-core/src/transfer/`)
  must stream in `CHUNK_SIZE` (1 MiB) pieces — never read/write a whole
  file into memory. This is load-bearing for large-file transfers.
- **Security-sensitive filesystem paths**: every filename/path arriving
  over the wire must go through `filedrop_core::security::{sanitize_filename, safe_join}`
  before touching disk. See `docs/PROTOCOL.md` §5.
- **Platform-specific "no router" networking**: never fake capability
  Rust can't actually provide. `filedrop_core::networking::ConnectionMode::platform_capability`
  is the single source of truth for what's implemented vs. what needs a
  Flutter platform channel per OS — extend that function's match arms
  rather than adding ad hoc platform checks elsewhere.
- **No git commits/pushes are automated except via `make deploy`**,
  which itself only runs when explicitly invoked — this repo was
  scaffolded with `git init` + a `main` branch but no commits.
