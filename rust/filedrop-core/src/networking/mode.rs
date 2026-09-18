//! Connection mode enum and per-platform direct-connect capability
//! reporting.
//!
//! IMPORTANT: this module deliberately does NOT implement the "no router"
//! direct-connect mechanisms themselves. Those are real OS-level APIs that
//! Rust cannot reach generically:
//!
//! - **Android Wi-Fi Direct** requires `android.net.wifi.p2p.WifiP2pManager`,
//!   which is a Kotlin/Java Android SDK API. It must be driven from Kotlin
//!   via a Flutter platform channel (`MethodChannel`); there is no
//!   Android NDK/Rust binding for `WifiP2pManager` because it is not
//!   exposed through `libandroid` — it's a Java framework service reached
//!   via Binder IPC. Out of scope for the Rust-side pass.
//! - **macOS Local-only hotspot / Bonjour direct link** requires
//!   `NEHotspotConfiguration` / `Network.framework` (Swift/Objective-C),
//!   driven from Swift via a platform channel. Rust's `mdns-sd` crate
//!   (used in [`crate::discovery`]) covers Bonjour *discovery* once both
//!   devices are on a shared link, but establishing that link ad hoc
//!   (personal hotspot) is a system UI/entitlement-gated action Rust
//!   cannot trigger.
//! - **Windows** direct networking (Wi-Fi Direct / Mobile Hotspot) requires
//!   the WinRT `Windows.Devices.WiFiDirect` API, reachable from Rust via
//!   the `windows` crate in principle, but requires a real Windows target
//!   and manifest capability declarations to test — deferred to a
//!   Windows-focused pass.
//! - **Linux** has no single standard direct-connect API; NetworkManager's
//!   D-Bus API can create an ad hoc/hotspot AP, which IS reachable from
//!   Rust (e.g. via `zbus`), making Linux the one "no router" platform
//!   that could plausibly be implemented in pure Rust. Deferred to a
//!   later pass rather than half-implemented here.
//!
//! What Rust CAN and does do generically: once a link exists (by whatever
//! platform mechanism), everything after that — discovery handshake,
//! pairing, chunked transfer — is identical LAN-style networking over the
//! resulting IP link, using the same [`ConnectionMode::ExistingLan`] code
//! path.

use serde::{Deserialize, Serialize};

/// The network topology a transfer session is running under.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ConnectionMode {
    /// Both devices are already on a shared LAN (home/office Wi-Fi,
    /// Ethernet). Discovery via mDNS/DNS-SD + UDP broadcast fallback.
    /// Fully implemented.
    ExistingLan,
    /// No shared network exists; this device is hosting (or connected to)
    /// a local-only Wi-Fi hotspot with no internet uplink, used purely to
    /// create a transient LAN between the two devices. Platform-specific
    /// setup (see module docs); once the link exists, transfer logic is
    /// identical to `ExistingLan`.
    LocalOnlyHotspot,
    /// No shared network exists; using Wi-Fi Direct (Android) or an
    /// equivalent peer-to-peer Wi-Fi association to link the two devices
    /// directly without an access point. Platform-specific setup (see
    /// module docs).
    WifiDirect,
}

/// Whether direct (no-router) connectivity is available on the current
/// platform, and if not, why — surfaced to the UI so "Network Setup" can
/// explain rather than silently fail.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum PlatformDirectCapability {
    /// This platform's direct-connect mechanism is implemented and ready.
    Available { mode: ConnectionMode },
    /// This platform's direct-connect mechanism requires a platform
    /// channel call into native code that has not been wired up in this
    /// pass. `reason` explains what's needed.
    RequiresPlatformChannel { mode: ConnectionMode, reason: String },
    /// This platform has no known direct-connect mechanism FileDrop can
    /// use; only `ExistingLan` mode is available.
    Unsupported,
}

impl ConnectionMode {
    /// Reports what's actually available for `target_os` (one of Rust's
    /// `std::env::consts::OS` values: "android", "ios", "macos", "windows",
    /// "linux"). This is a static capability description, not a live
    /// runtime check — actual availability (e.g. is Wi-Fi Direct hardware
    /// present) can only be determined by the native platform code itself.
    pub fn platform_capability(target_os: &str) -> PlatformDirectCapability {
        match target_os {
            "android" => PlatformDirectCapability::RequiresPlatformChannel {
                mode: ConnectionMode::WifiDirect,
                reason:
                    "Android Wi-Fi Direct requires android.net.wifi.p2p.WifiP2pManager, callable \
                     only from Kotlin/Java via a Flutter MethodChannel. TODO(phase5): implement \
                     the Kotlin platform-channel handler and have it report link-established \
                     IP/port back to Rust over FFI so filedrop-core can start its HTTP server on \
                     that interface."
                        .to_string(),
            },
            "macos" => PlatformDirectCapability::RequiresPlatformChannel {
                mode: ConnectionMode::LocalOnlyHotspot,
                reason:
                    "macOS local-only hotspot / direct Bonjour link requires \
                     NEHotspotConfiguration / Network.framework, callable only from \
                     Swift/Objective-C via a Flutter platform channel, and requires the \
                     Hotspot Configuration entitlement. TODO(phase5): implement the Swift \
                     platform-channel handler; mdns-sd discovery (crate::discovery) can run \
                     over the resulting link unmodified once it exists."
                        .to_string(),
            },
            "windows" => PlatformDirectCapability::RequiresPlatformChannel {
                mode: ConnectionMode::WifiDirect,
                reason:
                    "Windows direct networking requires the WinRT Windows.Devices.WiFiDirect \
                     API. Reachable from Rust via the `windows` crate in principle, but needs a \
                     Windows target, appxmanifest capability declarations, and hardware to \
                     validate. TODO(phase5): implement using the `windows` crate on a \
                     Windows-focused pass."
                        .to_string(),
            },
            "linux" => PlatformDirectCapability::RequiresPlatformChannel {
                mode: ConnectionMode::LocalOnlyHotspot,
                reason:
                    "Linux ad hoc hotspot AP creation is reachable generically via \
                     NetworkManager's D-Bus API (e.g. through the `zbus` crate) without a \
                     Flutter platform channel, making it the one 'no router' mode Rust could \
                     plausibly own end-to-end. TODO(phase5): implement NetworkManager D-Bus \
                     hotspot control in filedrop-core::networking."
                        .to_string(),
            },
            "ios" => PlatformDirectCapability::Unsupported,
            _ => PlatformDirectCapability::Unsupported,
        }
    }
}
