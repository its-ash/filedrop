//! Port selection and endpoint resolution.

use crate::error::{FileDropError, Result};
use serde::{Deserialize, Serialize};
use std::net::{IpAddr, SocketAddr, TcpListener};

/// Default TCP port the FileDrop HTTP/WebSocket server tries first.
pub const DEFAULT_PORT: u16 = 53317;

/// Range scanned for a free port if [`DEFAULT_PORT`] is taken (e.g. two
/// FileDrop instances running on one machine during development).
const PORT_SCAN_RANGE: std::ops::RangeInclusive<u16> = 53317..=53350;

/// A resolved address/port this device's server is reachable on.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ResolvedEndpoint {
    pub address: IpAddr,
    pub port: u16,
}

impl ResolvedEndpoint {
    pub fn socket_addr(&self) -> SocketAddr {
        SocketAddr::new(self.address, self.port)
    }
}

/// Picks a free TCP port for the server to bind, starting at
/// [`DEFAULT_PORT`] and scanning [`PORT_SCAN_RANGE`] if it's taken.
pub fn pick_server_port() -> Result<u16> {
    for port in PORT_SCAN_RANGE {
        if TcpListener::bind(("0.0.0.0", port)).is_ok() {
            return Ok(port);
        }
    }
    Err(FileDropError::Network(format!(
        "no free port found in range {}-{}",
        PORT_SCAN_RANGE.start(),
        PORT_SCAN_RANGE.end()
    )))
}
