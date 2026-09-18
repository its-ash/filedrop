//! Enumerates local IPv4 addresses this device can be reached on, for
//! advertising in mDNS records / QR pairing payloads.
//!
//! Implemented without a third-party interface-listing crate: we open a
//! UDP socket "connected" to a public IP (no packets are actually sent
//! for a UDP connect) and read back the local address the OS would route
//! through — a common portable trick that works without extra
//! dependencies or platform-specific code.

use crate::error::Result;
use std::net::{IpAddr, UdpSocket};

/// Returns the primary local IPv4 address the OS would use to reach the
/// outside world (i.e. the LAN-facing address other devices should
/// connect to), or an empty vec if no route is available (e.g. Wi-Fi is
/// off and there is no fallback link).
pub fn local_ipv4_addresses() -> Result<Vec<IpAddr>> {
    let socket = UdpSocket::bind("0.0.0.0:0")?;
    // 203.0.113.1 is documentation/test-only address space (TEST-NET-3,
    // RFC 5737); connecting a UDP socket to it sends no packets, it just
    // makes the kernel pick a local source address/route.
    match socket.connect("203.0.113.1:80") {
        Ok(()) => {
            let addr = socket.local_addr()?;
            Ok(vec![addr.ip()])
        }
        Err(_) => Ok(Vec::new()),
    }
}
