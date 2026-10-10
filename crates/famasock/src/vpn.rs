//! IPv4 split-tunnel packets over unreliable QUIC datagrams; no custom IP stack.
use crate::{Node, node::Request, store::Policy};
#[cfg(target_os = "linux")]
use crate::{node::Reply, wire};
use anyhow::{Context, Result, ensure};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use bytes::Bytes;
use ipnet::Ipv4Net;
use iroh::endpoint::{Connection, RecvStream, SendStream};
use serde_json::json;
use std::{
    net::Ipv4Addr,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

pub const MTU: usize = 1100;
const TAG: usize = 32;
pub(crate) struct PacketSession {
    conn: Connection,
    tag: [u8; TAG],
    rx: mpsc::Sender<Vec<u8>>,
    pub(crate) cancel: CancellationToken,
    routes: Vec<Ipv4Net>,
    local: Ipv4Addr,
    remote: Ipv4Addr,
    server: bool,
    sent: AtomicU64,
    received: AtomicU64,
}
pub struct VpnLink {
    pub id: String,
    pub local_ip: Ipv4Addr,
    pub remote_ip: Ipv4Addr,
    pub routes: Vec<Ipv4Net>,
    pub packets: mpsc::Receiver<Vec<u8>>,
}
/// Exact IPv4 length/header checks; reject fragments, source routing/options and spoofing.
pub fn validate_packet(packet: &[u8]) -> Result<(Ipv4Addr, Ipv4Addr)> {
    ensure!(
        (20..=MTU).contains(&packet.len()),
        "invalid VPN packet size"
    );
    ensure!(packet[0] == 0x45, "only IPv4 without options supported");
    ensure!(
        u16::from_be_bytes([packet[2], packet[3]]) as usize == packet.len(),
        "IP length mismatch"
    );
    ensure!(
        u16::from_be_bytes([packet[6], packet[7]]) & 0x3fff == 0,
        "fragmented VPN packet"
    );
    let mut sum: u32 = packet[..20]
        .as_chunks::<2>()
        .0
        .iter()
        .map(|p| u16::from_be_bytes([p[0], p[1]]) as u32)
        .sum();
    while sum > 0xffff {
        sum = (sum & 0xffff) + (sum >> 16);
    }
    ensure!(sum == 0xffff, "invalid IPv4 checksum");
    Ok((
        Ipv4Addr::new(packet[12], packet[13], packet[14], packet[15]),
        Ipv4Addr::new(packet[16], packet[17], packet[18], packet[19]),
    ))
}
fn route_valid(routes: &[Ipv4Net]) -> Result<()> {
    ensure!(
        !routes.is_empty() && routes.len() <= 16,
        "specify 1–16 split routes"
    );
    // Constrain first release to private split routes. This prevents capturing Iroh's
    // public relay/UDP transport; full tunnel needs platform-specific route exclusion.
    let private: [Ipv4Net; 3] = [
        "10.0.0.0/8".parse()?,
        "172.16.0.0/12".parse()?,
        "192.168.0.0/16".parse()?,
    ];
    ensure!(
        routes.iter().all(|r| private
            .iter()
            .any(|p| p.contains(&r.network()) && p.prefix_len() <= r.prefix_len())),
        "only private IPv4 split routes are supported"
    );
    Ok(())
}
impl PacketSession {
    fn allowed(&self, packet: &[u8], sending: bool) -> Result<()> {
        let (src, dst) = validate_packet(packet)?;
        let from_client = self.server != sending;
        if from_client {
            let client = if self.server { self.remote } else { self.local };
            ensure!(
                src == client && self.routes.iter().any(|r| r.contains(&dst)),
                "VPN source or destination denied"
            );
        } else {
            let client = if self.server { self.remote } else { self.local };
            ensure!(
                dst == client && self.routes.iter().any(|r| r.contains(&src)),
                "VPN reply source or destination denied"
            );
        }
        Ok(())
    }
}
impl Node {
    fn install_packets(
        &self,
        conn: Connection,
        tag: String,
        routes: Vec<Ipv4Net>,
        addresses: (Ipv4Addr, Ipv4Addr),
        server: bool,
        cancel: CancellationToken,
    ) -> Result<mpsc::Receiver<Vec<u8>>> {
        let bytes: [u8; TAG] = URL_SAFE_NO_PAD
            .decode(&tag)?
            .try_into()
            .map_err(|_| anyhow::anyhow!("invalid VPN session"))?;
        ensure!(
            conn.max_datagram_size().unwrap_or(0) >= MTU + TAG,
            "QUIC datagram MTU insufficient"
        );
        let mut sessions = self.vpn.lock().unwrap();
        ensure!(
            !sessions
                .values()
                .any(|s| s.conn.remote_id() == conn.remote_id()),
            "VPN already active for peer"
        );
        ensure!(sessions.len() < 8, "VPN session limit");
        let (tx, rx) = mpsc::channel(64);
        sessions.insert(
            tag,
            PacketSession {
                conn,
                tag: bytes,
                rx: tx,
                routes,
                local: addresses.0,
                remote: addresses.1,
                server,
                cancel,
                sent: AtomicU64::new(0),
                received: AtomicU64::new(0),
            },
        );
        Ok(rx)
    }
    pub fn send_packet(&self, id: &str, packet: &[u8]) -> Result<()> {
        let sessions = self.vpn.lock().unwrap();
        let session = sessions.get(id).context("VPN session stopped")?;
        ensure!(!session.cancel.is_cancelled(), "VPN stopped");
        session.allowed(packet, true)?;
        let mut data = Vec::with_capacity(TAG + packet.len());
        data.extend_from_slice(&session.tag);
        data.extend_from_slice(packet);
        session.conn.send_datagram(Bytes::from(data))?;
        session
            .sent
            .fetch_add(packet.len() as u64, Ordering::Relaxed);
        Ok(())
    }
    pub(crate) fn receive_packet(&self, conn: &Connection, data: Bytes) {
        if data.len() < TAG + 20 || data.len() > TAG + MTU {
            return;
        }
        let id = URL_SAFE_NO_PAD.encode(&data[..TAG]);
        let sessions = self.vpn.lock().unwrap();
        if let Some(s) = sessions.get(&id)
            && s.conn.remote_id() == conn.remote_id()
            && !s.cancel.is_cancelled()
            && s.allowed(&data[TAG..], false).is_ok()
            && s.rx.try_send(data[TAG..].to_vec()).is_ok()
        {
            s.received
                .fetch_add((data.len() - TAG) as u64, Ordering::Relaxed);
        }
    }
    pub fn vpn_stats(&self, id: &str) -> serde_json::Value {
        self.vpn.lock().unwrap().get(id).map(|s| json!({"sent":s.sent.load(Ordering::Relaxed),"received":s.received.load(Ordering::Relaxed)})).unwrap_or_default()
    }
    pub async fn start_vpn(self: &Arc<Self>, peer: &str, routes: Vec<Ipv4Net>) -> Result<VpnLink> {
        route_valid(&routes)?;
        let conn = self.connection(peer).await?;
        let session = crate::pairing::random()?;
        // Never capture an already selected local direct Iroh address.
        self.check_transport_routes(&routes)?;
        let ((mut send, mut recv), info) = Self::request(
            &conn,
            &Request::Vpn {
                routes: routes.clone(),
                session: session.clone(),
            },
        )
        .await?;
        let local: Ipv4Addr = serde_json::from_value(info["client_ip"].clone())?;
        let remote: Ipv4Addr = serde_json::from_value(info["server_ip"].clone())?;
        let (tunnel, cancel) = self.add_tunnel(
            conn.remote_id().to_string(),
            "vpn",
            routes
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>()
                .join(","),
        )?;
        let packets = match self.install_packets(
            conn.clone(),
            session.clone(),
            routes.clone(),
            (local, remote),
            false,
            cancel.clone(),
        ) {
            Ok(r) => r,
            Err(e) => {
                self.remove_tunnel(&tunnel);
                return Err(e);
            }
        };
        let n = self.clone();
        let tag = session.clone();
        self.tasks.spawn(async move {
            let mut byte = [0];
            tokio::select! { _ = cancel.cancelled() => {}, _ = recv.read(&mut byte) => {}, _ = conn.closed() => {} }
            let _ = send.finish(); n.vpn.lock().unwrap().remove(&tag); n.remove_tunnel(&tunnel);
        });
        Ok(VpnLink {
            id: session,
            local_ip: local,
            remote_ip: remote,
            routes,
            packets,
        })
    }
    pub fn stop_vpn(&self, id: &str) {
        if let Some(s) = self.vpn.lock().unwrap().remove(id) {
            s.cancel.cancel();
        }
    }
    fn check_transport_routes(&self, routes: &[Ipv4Net]) -> Result<()> {
        // Conservative: reject any route overlapping this device's direct addresses.
        // This keeps LAN Iroh paths outside the packet tunnel as well as public relays.
        for a in &self.endpoint.addr().addrs {
            if let iroh::TransportAddr::Ip(addr) = a
                && let std::net::IpAddr::V4(ip) = addr.ip()
            {
                ensure!(
                    !routes.iter().any(|r| r.contains(&ip)),
                    "VPN route overlaps a local transport network"
                );
            }
        }
        Ok(())
    }
    pub(crate) async fn accept_vpn(
        self: &Arc<Self>,
        conn: Connection,
        policy: Policy,
        routes: Vec<Ipv4Net>,
        session: String,
        mut send: SendStream,
        recv: RecvStream,
    ) -> Result<()> {
        let p = Self::checked(
            &mut send,
            (|| {
                route_valid(&routes)?;
                let p = policy.vpn.context("VPN not authorized")?;
                ensure!(
                    routes.iter().all(|r| p
                        .routes
                        .iter()
                        .any(|a| a.prefix_len() <= r.prefix_len() && a.contains(&r.network()))),
                    "VPN route not authorized"
                );
                Ok(p)
            })(),
        )
        .await?;
        #[cfg(target_os = "linux")]
        {
            let mut recv = recv;
            let device = Self::checked(&mut send, open_tun(&p.tun)).await?;
            let cancel = self.cancel.child_token();
            let packets = self.install_packets(
                conn.clone(),
                session.clone(),
                routes,
                (p.local_ip, p.peer_ip),
                true,
                cancel.clone(),
            )?;
            let result = async {
                wire::write(
                    &mut send,
                    &Reply::ok(json!({"client_ip":p.peer_ip,"server_ip":p.local_ip,"mtu":MTU})),
                )
                .await?;
                let mut byte = [0];
                tokio::select! {
                    r = self.pump_tun(&session,device,packets) => r,
                    _ = recv.read(&mut byte) => Ok(()),
                    _ = conn.closed() => Ok(()),
                    _ = cancel.cancelled() => Ok(()),
                }
            }
            .await;
            self.stop_vpn(&session);
            let _ = send.finish();
            result
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (conn, session, recv, p);
            Self::checked(&mut send, Err(anyhow::anyhow!("VPN exit requires Linux"))).await
        }
    }
    #[cfg(target_os = "linux")]
    async fn pump_tun(
        &self,
        id: &str,
        device: tun::AsyncDevice,
        mut packets: mpsc::Receiver<Vec<u8>>,
    ) -> Result<()> {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let (mut read, mut write) = tokio::io::split(device);
        // Large enough to detect oversize, never truncate silently.
        let mut buf = vec![0; 65536];
        loop {
            tokio::select! {
                n = read.read(&mut buf) => { let n = n?; ensure!(n>0,"TUN closed"); if let Err(e) = self.send_packet(id,&buf[..n]) { self.emit(json!({"event":"packet_dropped","error":e.to_string()})); } },
                p = packets.recv() => { match p { Some(p) => { write.write_all(&p).await?; }, None => break } },
                _ = self.cancel.cancelled() => break,
            }
        }
        Ok(())
    }
    #[cfg(target_os = "linux")]
    pub async fn vpn_tun(
        self: &Arc<Self>,
        peer: &str,
        routes: Vec<Ipv4Net>,
        name: &str,
    ) -> Result<String> {
        let device = open_tun(name)?;
        let link = self.start_vpn(peer, routes).await?;
        let n = self.clone();
        let id = link.id.clone();
        self.tasks.spawn(async move {
            let result = n.pump_tun(&link.id, device, link.packets).await;
            n.stop_vpn(&link.id);
            if let Err(e) = result {
                n.emit(json!({"event":"vpn_error","error":e.to_string()}));
            }
        });
        Ok(id)
    }
}
#[cfg(target_os = "linux")]
fn open_tun(name: &str) -> Result<tun::AsyncDevice> {
    ensure!(
        !name.is_empty()
            && name.len() < 16
            && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'),
        "invalid TUN name"
    );
    // Refuse to create/configure an interface with daemon privileges.
    ensure!(
        std::path::Path::new("/sys/class/net").join(name).exists(),
        "provision the TUN first (see docs/vpn.md)"
    );
    let mut config = tun::Configuration::default();
    config.tun_name(name).platform_config(|c| {
        c.ensure_root_privileges(false);
    });
    let device = tun::create_as_async(&config)?;
    use tun::AbstractDevice;
    ensure!(
        device.mtu()? as usize == MTU,
        "set TUN MTU to 1100 before connecting"
    );
    Ok(device)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Peer;
    fn packet(src: [u8; 4], dst: [u8; 4]) -> Vec<u8> {
        let mut p = vec![0; 28];
        p[0] = 0x45;
        p[2..4].copy_from_slice(&28u16.to_be_bytes());
        p[8] = 64;
        p[9] = 17;
        p[12..16].copy_from_slice(&src);
        p[16..20].copy_from_slice(&dst);
        let mut sum: u32 = p[..20]
            .as_chunks::<2>()
            .0
            .iter()
            .map(|x| u16::from_be_bytes([x[0], x[1]]) as u32)
            .sum();
        while sum > 0xffff {
            sum = (sum & 0xffff) + (sum >> 16);
        }
        p[10..12].copy_from_slice(&(!(sum as u16)).to_be_bytes());
        p
    }
    #[test]
    fn ipv4_validation_rejects_truncation_checksum_options_fragments_and_oversize() {
        let p = packet([10, 1, 0, 2], [10, 1, 0, 1]);
        assert!(validate_packet(&p).is_ok());
        for len in 0..p.len() {
            assert!(validate_packet(&p[..len]).is_err());
        }
        for (index, value) in [(0, 0x65), (0, 0x46), (6, 0x20), (7, 1), (10, 0), (2, 1)] {
            let mut bad = p.clone();
            bad[index] = value;
            assert!(validate_packet(&bad).is_err());
        }
        assert!(validate_packet(&vec![0; MTU + 1]).is_err());
        assert!(route_valid(&["0.0.0.0/0".parse().unwrap()]).is_err());
        assert!(route_valid(&["192.168.1.0/24".parse().unwrap()]).is_ok());
    }
    #[tokio::test]
    async fn real_quic_datagrams_are_session_bound_and_filtered() {
        let a = tempfile::tempdir().unwrap();
        let b = tempfile::tempdir().unwrap();
        let client = Node::open(a.path(), "client", None, true).await.unwrap();
        let server = Node::open(b.path(), "server", None, true).await.unwrap();
        for (node, other) in [(&client, &server), (&server, &client)] {
            node.store
                .lock()
                .unwrap()
                .update(|s| {
                    s.peers.insert(
                        other.endpoint.id().to_string(),
                        Peer {
                            name: "other".into(),
                            device: "test".into(),
                            addr: other.endpoint.addr(),
                            policy: Policy::default(),
                        },
                    );
                })
                .unwrap();
        }
        // Services waits until the receiving node has registered the shared connection.
        client
            .services(&server.endpoint.id().to_string())
            .await
            .unwrap();
        let c = client
            .connection(&server.endpoint.id().to_string())
            .await
            .unwrap();
        let s = server
            .connection(&client.endpoint.id().to_string())
            .await
            .unwrap();
        let id = crate::pairing::random().unwrap();
        let routes = vec!["10.1.0.0/24".parse().unwrap()];
        let mut received = server
            .install_packets(
                s,
                id.clone(),
                routes.clone(),
                ("10.1.0.1".parse().unwrap(), "10.1.0.2".parse().unwrap()),
                true,
                server.cancel.child_token(),
            )
            .unwrap();
        let mut replies = client
            .install_packets(
                c.clone(),
                id.clone(),
                routes,
                ("10.1.0.2".parse().unwrap(), "10.1.0.1".parse().unwrap()),
                false,
                client.cancel.child_token(),
            )
            .unwrap();
        let p = packet([10, 1, 0, 2], [10, 1, 0, 1]);
        client.send_packet(&id, &p).unwrap();
        assert_eq!(
            tokio::time::timeout(std::time::Duration::from_secs(3), received.recv())
                .await
                .unwrap()
                .unwrap(),
            p
        );
        let reply = packet([10, 1, 0, 1], [10, 1, 0, 2]);
        server.send_packet(&id, &reply).unwrap();
        assert_eq!(
            tokio::time::timeout(std::time::Duration::from_secs(3), replies.recv())
                .await
                .unwrap()
                .unwrap(),
            reply
        );
        let forged = packet([10, 1, 0, 9], [10, 1, 0, 1]);
        assert!(client.send_packet(&id, &forged).is_err());
        // Bypass the client-side check to exercise the receiving trust boundary.
        let mut raw = URL_SAFE_NO_PAD.decode(&id).unwrap();
        raw.extend(forged);
        c.send_datagram(raw.into()).unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(100), received.recv())
                .await
                .is_err()
        );
        client.stop_vpn(&id);
        assert!(client.send_packet(&id, &p).is_err());
        client.shutdown().await;
        server.shutdown().await;
    }
}
