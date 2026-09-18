//! UDP broadcast discovery fallback, used when mDNS/multicast is blocked
//! on the local network (common on some corporate/guest Wi-Fi that
//! isolates multicast traffic between clients). See `docs/PROTOCOL.md`
//! for the exact packet format.

use super::device::DiscoveredDevice;
use crate::error::Result;
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

/// UDP port used for broadcast discovery packets.
pub const BROADCAST_PORT: u16 = 53318;
/// How often this device re-announces itself via broadcast.
const ANNOUNCE_INTERVAL: Duration = Duration::from_secs(5);

/// Wire format for a UDP broadcast announcement. Serialized as JSON — the
/// packet is small (well under typical MTU) and JSON keeps the fallback
/// path trivially debuggable with `nc`/`tcpdump` during development. See
/// `docs/PROTOCOL.md` "Discovery Packet Format".
#[derive(Debug, Clone, Serialize, Deserialize)]
struct AnnouncePacket {
    magic: String,
    device_id: uuid::Uuid,
    name: String,
    port: u16,
    platform: String,
}

const MAGIC: &str = "FILEDROP_ANNOUNCE_V1";

/// Parses a received UDP datagram into an [`AnnouncePacket`], returning
/// `None` on any malformed input. Kept as a standalone (non-async)
/// function so the borrow of the caller's receive buffer stays entirely
/// within a synchronous call frame.
fn parse_announce(bytes: &[u8]) -> Option<AnnouncePacket> {
    serde_json::from_slice(bytes).ok()
}

pub struct UdpBroadcastDiscovery {
    running: Arc<AtomicBool>,
}

impl UdpBroadcastDiscovery {
    pub fn new() -> Self {
        Self {
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Starts periodic broadcast announcements of `self_device` and
    /// listens for peers' announcements, forwarding them on the returned
    /// channel.
    pub async fn start(
        &self,
        self_device: DiscoveredDevice,
    ) -> Result<mpsc::Receiver<DiscoveredDevice>> {
        self.running.store(true, Ordering::SeqCst);

        let listen_socket = UdpSocket::bind(("0.0.0.0", BROADCAST_PORT)).await?;
        listen_socket.set_broadcast(true)?;

        let send_socket = UdpSocket::bind(("0.0.0.0", 0)).await?;
        send_socket.set_broadcast(true)?;

        let (tx, rx) = mpsc::channel(32);

        // Announcer task.
        let running_announce = self.running.clone();
        let announce_device = self_device.clone();
        tokio::spawn(async move {
            let packet = AnnouncePacket {
                magic: MAGIC.to_string(),
                device_id: announce_device.device_id,
                name: announce_device.name.clone(),
                port: announce_device.port,
                platform: announce_device.platform.clone(),
            };
            let Ok(payload) = serde_json::to_vec(&packet) else {
                return;
            };
            let dest: SocketAddr = ([255, 255, 255, 255], BROADCAST_PORT).into();

            while running_announce.load(Ordering::SeqCst) {
                let _ = send_socket.send_to(&payload, dest).await;
                tokio::time::sleep(ANNOUNCE_INTERVAL).await;
            }
        });

        // Listener task.
        let running_listen = self.running.clone();
        let self_id = self_device.device_id;
        tokio::spawn(async move {
            let mut buf = vec![0u8; 4096];
            while running_listen.load(Ordering::SeqCst) {
                let Ok((n, from)) = listen_socket.recv_from(&mut buf).await else {
                    continue;
                };
                let packet = match parse_announce(&buf[..n]) {
                    Some(p) => p,
                    None => continue,
                };
                if packet.magic != MAGIC || packet.device_id == self_id {
                    continue;
                }
                let device = DiscoveredDevice {
                    device_id: packet.device_id,
                    name: packet.name,
                    address: from.ip().to_string(),
                    port: packet.port,
                    platform: packet.platform,
                    paired: false,
                };
                if tx.send(device).await.is_err() {
                    break;
                }
            }
        });

        Ok(rx)
    }

    pub async fn stop(&self) -> Result<()> {
        self.running.store(false, Ordering::SeqCst);
        Ok(())
    }
}

impl Default for UdpBroadcastDiscovery {
    fn default() -> Self {
        Self::new()
    }
}

/// Surfaced for callers that need to construct/validate the port
/// independent of a running discovery instance (e.g. firewall setup
/// docs/diagnostics).
pub fn broadcast_port() -> u16 {
    BROADCAST_PORT
}
