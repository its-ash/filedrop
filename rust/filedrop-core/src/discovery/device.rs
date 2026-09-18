//! Shared device-info type surfaced by both discovery mechanisms.

use serde::{Deserialize, Serialize};
use std::net::IpAddr;
use uuid::Uuid;

/// A device seen via mDNS or UDP broadcast discovery.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct DiscoveredDevice {
    pub device_id: Uuid,
    pub name: String,
    pub address: String,
    pub port: u16,
    pub platform: String,
    /// True once this device has completed pairing (see [`crate::pairing`])
    /// and can be sent to without a fresh handshake.
    pub paired: bool,
}

impl DiscoveredDevice {
    pub fn socket_addr(&self) -> Option<std::net::SocketAddr> {
        self.address
            .parse::<IpAddr>()
            .ok()
            .map(|ip| std::net::SocketAddr::new(ip, self.port))
    }
}
