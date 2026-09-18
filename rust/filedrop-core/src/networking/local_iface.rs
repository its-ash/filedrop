//! Enumerates local IPv4 addresses this device can be reached on, for
//! advertising in mDNS records / QR pairing payloads.
//!
//! Implemented without a third-party interface-listing crate: we open a
//! UDP socket "connected" to a public IP (no packets are actually sent
//! for a UDP connect) and read back the local address the OS would route
//! through — a common portable trick that works without extra
//! dependencies or platform-specific code.

use crate::error::Result;
use std::net::{IpAddr, Ipv4Addr, UdpSocket};

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

/// Returns `true` if `addr` falls in one of the RFC 1918 private IPv4
/// ranges: 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16.
fn is_private_ipv4(addr: &Ipv4Addr) -> bool {
    let o = addr.octets();
    match o[0] {
        10 => true,
        172 => (16..=31).contains(&o[1]),
        192 => o[1] == 168,
        _ => false,
    }
}

/// Real interface enumeration (via the `if-addrs` crate, not the UDP
/// default-route trick `local_ipv4_addresses` uses): lists every
/// non-loopback network interface on the device and returns the first
/// IPv4 address found that falls in a private range (10.0.0.0/8,
/// 172.16.0.0/12, 192.168.0.0/16).
///
/// This exists because `local_ipv4_addresses` is not a reliable "do we
/// have a usable LAN right now" signal: the UDP-connect trick can return
/// a public/non-private address, or silently succeed with a route that
/// doesn't correspond to any real, usable local network (and it never
/// looks at interfaces that aren't the OS's chosen default route — e.g.
/// a Wi-Fi Direct group interface typically isn't the default route).
/// Interface enumeration with explicit private-range filtering is the
/// honest way to answer "is there a usable LAN interface right now".
pub fn usable_lan_ipv4() -> Result<Option<IpAddr>> {
    let interfaces = if_addrs::get_if_addrs()?;
    for iface in interfaces {
        if iface.is_loopback() {
            continue;
        }
        if let IpAddr::V4(v4) = iface.ip() {
            if is_private_ipv4(&v4) {
                return Ok(Some(IpAddr::V4(v4)));
            }
        }
    }
    Ok(None)
}
