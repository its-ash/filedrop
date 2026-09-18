//! Peer discovery on an existing LAN: mDNS/DNS-SD as the primary
//! mechanism, with a UDP broadcast fallback for networks that block
//! multicast (common on some corporate/guest Wi-Fi).
//!
//! Discovery for the "no router" modes ([`crate::networking::ConnectionMode::WifiDirect`],
//! [`crate::networking::ConnectionMode::LocalOnlyHotspot`]) is out of scope
//! here — those platforms establish their own link first (see
//! `networking::mode` docs), after which THIS module's mDNS/UDP discovery
//! runs unmodified over that link.

mod device;
mod mdns;
mod udp_broadcast;

pub use device::DiscoveredDevice;
pub use mdns::MdnsDiscovery;
pub use udp_broadcast::UdpBroadcastDiscovery;

use crate::error::Result;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};
use uuid::Uuid;

/// Aggregates mDNS + UDP broadcast discovery into a single service with
/// one merged view of nearby devices, deduplicated by device id (mDNS is
/// preferred; UDP broadcast fills gaps where multicast is blocked).
pub struct DiscoveryService {
    mdns: MdnsDiscovery,
    udp: UdpBroadcastDiscovery,
    devices: Arc<RwLock<std::collections::HashMap<Uuid, DiscoveredDevice>>>,
}

impl DiscoveryService {
    pub fn new(service_name: &str) -> Result<Self> {
        Ok(Self {
            mdns: MdnsDiscovery::new(service_name)?,
            udp: UdpBroadcastDiscovery::new(),
            devices: Arc::new(RwLock::new(std::collections::HashMap::new())),
        })
    }

    /// Starts advertising this device and browsing for peers via both
    /// mechanisms. `on_device` is invoked (possibly repeatedly, e.g. on
    /// TTL refresh) whenever a device is newly seen or its info changes.
    pub async fn start(
        &self,
        self_device: DiscoveredDevice,
        on_device: mpsc::Sender<DiscoveredDevice>,
    ) -> Result<()> {
        self.mdns.advertise(&self_device).await?;

        let devices_mdns = self.devices.clone();
        let tx_mdns = on_device.clone();
        let mdns_rx = self.mdns.browse().await?;
        tokio::spawn(async move {
            forward_devices(mdns_rx, devices_mdns, tx_mdns).await;
        });

        let devices_udp = self.devices.clone();
        let tx_udp = on_device.clone();
        let udp_rx = self.udp.start(self_device).await?;
        tokio::spawn(async move {
            forward_devices(udp_rx, devices_udp, tx_udp).await;
        });

        Ok(())
    }

    pub async fn stop(&self) -> Result<()> {
        self.mdns.stop().await?;
        self.udp.stop().await?;
        self.devices.write().await.clear();
        Ok(())
    }

    pub async fn nearby_devices(&self) -> Vec<DiscoveredDevice> {
        self.devices.read().await.values().cloned().collect()
    }
}

async fn forward_devices(
    mut rx: mpsc::Receiver<DiscoveredDevice>,
    devices: Arc<RwLock<std::collections::HashMap<Uuid, DiscoveredDevice>>>,
    tx: mpsc::Sender<DiscoveredDevice>,
) {
    while let Some(device) = rx.recv().await {
        devices.write().await.insert(device.device_id, device.clone());
        if tx.send(device).await.is_err() {
            break;
        }
    }
}
