//! Networking mode selection and address/port resolution.
//!
//! FileDrop supports two network topologies (see `docs/ARCHITECTURE.md`):
//! 1. **Existing LAN** — both devices already share a Wi-Fi/Ethernet network;
//!    we discover peers via mDNS/DNS-SD with UDP broadcast fallback
//!    ([`crate::discovery`]) and connect directly over the LAN's own IP
//!    routing. Fully implemented, platform-agnostic.
//! 2. **No router** — there is no shared network to join, so a direct
//!    device-to-device link must be established first. The mechanism for
//!    that is inherently platform-specific system API territory (see
//!    [`ConnectionMode`] docs below) and is stubbed here accordingly.

mod local_iface;
mod mode;
mod resolve;

pub use local_iface::local_ipv4_addresses;
pub use mode::{ConnectionMode, PlatformDirectCapability};
pub use resolve::{pick_server_port, ResolvedEndpoint, DEFAULT_PORT};
