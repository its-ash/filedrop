//! mDNS/DNS-SD discovery via the `mdns-sd` crate. Primary discovery
//! mechanism on networks where multicast is allowed (the common case on
//! home/office LANs).

use super::device::DiscoveredDevice;
use crate::error::{FileDropError, Result};
use mdns_sd::{ServiceDaemon, ServiceEvent, ServiceInfo};
use std::collections::HashMap;
use tokio::sync::mpsc;
use uuid::Uuid;

/// DNS-SD service type FileDrop advertises under. `_filedrop._tcp.local.`
const SERVICE_TYPE: &str = "_filedrop._tcp.local.";

pub struct MdnsDiscovery {
    daemon: ServiceDaemon,
    service_name: String,
}

impl MdnsDiscovery {
    pub fn new(service_name: &str) -> Result<Self> {
        let daemon = ServiceDaemon::new()
            .map_err(|e| FileDropError::Discovery(format!("mdns daemon init failed: {e}")))?;
        Ok(Self {
            daemon,
            service_name: service_name.to_string(),
        })
    }

    /// Advertises `device` on the local network under [`SERVICE_TYPE`].
    /// Device metadata (id, platform) is carried in DNS-SD TXT records.
    pub async fn advertise(&self, device: &DiscoveredDevice) -> Result<()> {
        let mut properties: HashMap<String, String> = HashMap::new();
        properties.insert("device_id".to_string(), device.device_id.to_string());
        properties.insert("platform".to_string(), device.platform.clone());

        let host_name = format!("{}.local.", sanitize_instance(&device.name));
        let ip: std::net::IpAddr = device
            .address
            .parse()
            .map_err(|_| FileDropError::Discovery("invalid advertise address".into()))?;

        let info = ServiceInfo::new(
            SERVICE_TYPE,
            &sanitize_instance(&self.service_name),
            &host_name,
            ip,
            device.port,
            Some(properties),
        )
        .map_err(|e| FileDropError::Discovery(format!("service info build failed: {e}")))?;

        self.daemon
            .register(info)
            .map_err(|e| FileDropError::Discovery(format!("mdns register failed: {e}")))?;
        Ok(())
    }

    /// Starts browsing for other `_filedrop._tcp.local.` services and
    /// forwards resolved peers over the returned channel.
    pub async fn browse(&self) -> Result<mpsc::Receiver<DiscoveredDevice>> {
        let receiver = self
            .daemon
            .browse(SERVICE_TYPE)
            .map_err(|e| FileDropError::Discovery(format!("mdns browse failed: {e}")))?;

        let (tx, rx) = mpsc::channel(32);
        tokio::spawn(async move {
            while let Ok(event) = receiver.recv_async().await {
                if let ServiceEvent::ServiceResolved(info) = event {
                    let device_id = info
                        .get_property_val_str("device_id")
                        .and_then(|s| Uuid::parse_str(s).ok())
                        .unwrap_or_else(Uuid::new_v4);
                    let platform = info
                        .get_property_val_str("platform")
                        .unwrap_or("unknown")
                        .to_string();
                    let addr = info.get_addresses_v4().into_iter().next();

                    if let Some(addr) = addr {
                        let device = DiscoveredDevice {
                            device_id,
                            name: info
                                .get_fullname()
                                .trim_end_matches(SERVICE_TYPE)
                                .trim_end_matches('.')
                                .to_string(),
                            address: addr.to_string(),
                            port: info.get_port(),
                            platform,
                            paired: false,
                        };
                        if tx.send(device).await.is_err() {
                            break;
                        }
                    }
                }
            }
        });

        Ok(rx)
    }

    pub async fn stop(&self) -> Result<()> {
        let _ = self.daemon.stop_browse(SERVICE_TYPE);
        Ok(())
    }
}

/// DNS-SD instance names can't contain dots; replace them defensively.
fn sanitize_instance(name: &str) -> String {
    name.replace('.', "-")
}
