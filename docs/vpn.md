# IPv4 split VPN

Current scope: private IPv4 split routes, one VPN session per peer, up to eight
sessions per endpoint. Each peer requires its own TUN and assigned source IP on
the Linux exit. Packet queues hold at most 64 packets. Packets are sent as one
QUIC datagram each; no fragmentation/reassembly or custom TCP/IP stack is added.
Malformed headers, incorrect lengths/checksums, options, fragments, oversize
packets, spoofed sources and destinations outside the negotiated policy are
rejected. The MTU is 1100, checked against the QUIC datagram capacity.

## Home Linux configuration

Example: the home LAN is `192.168.1.0/24`, home tunnel address `10.250.0.1`, phone
address `10.250.0.2`. Run the following administrative setup explicitly; the
Famasock daemon itself can continue running as your ordinary user:

```sh
sudo ip tuntap add dev famasock0 mode tun user "$(id -un)"
sudo ip addr add 10.250.0.1/32 dev famasock0
sudo ip link set famasock0 mtu 1100 up
sudo ip route add 10.250.0.2/32 dev famasock0
```

Grant the phone this policy (merge existing service grants into the same file if
needed; `policy` replaces the whole policy):

```json
{
  "vpn": {
    "routes": ["192.168.1.0/24"],
    "local_ip": "10.250.0.1",
    "peer_ip": "10.250.0.2",
    "tun": "famasock0"
  }
}
```

```sh
famasock policy iPhone vpn-policy.json
```

To reach other LAN machines, Linux needs IPv4 forwarding and your firewall must
allow the specific TUN-to-LAN traffic. The LAN must have a return route for
`10.250.0.2/32` via the home Linux host. An administrator can instead configure
narrow source NAT for that source, the allowed destination subnet and the LAN
interface. Famasock does not modify forwarding, firewall or NAT settings silently.
This is not an internet exit node. Preserve your original sysctl/firewall settings
and undo only changes you made; do not flush a shared firewall.

In the iOS app select home, VPN, `192.168.1.0/24`, then Connect. An optional DNS
server must be inside an allowed route. With no DNS override, the existing system
resolver remains in use: private DNS names may require an explicit server.
IPv6 and ordinary internet traffic remain on the original connection. Stop VPN
removes the system Packet Tunnel network settings, including its DNS override.

## Linux client

Use a second TUN on the client with the assigned client address, add the route,
then start the session:

```sh
sudo ip tuntap add dev famasock0 mode tun user "$(id -un)"
sudo ip addr add 10.250.0.2/32 dev famasock0
sudo ip link set famasock0 mtu 1100 up
sudo ip route add 192.168.1.0/24 dev famasock0
famasock vpn home --route 192.168.1.0/24 --tun famasock0
famasock stop-vpn SESSION_ID
sudo ip route del 192.168.1.0/24 dev famasock0
sudo ip link del famasock0
```

Routes/interfaces are administratively provisioned and **must be removed with
the explicit cleanup commands above**. The current CLI does not manage privileged
routes or DNS. While the route remains after a stopped session, its traffic will
be blackholed. This limitation is tracked for a privileged setup/cleanup helper.
Server cleanup: stop/revoke the VPN, delete its peer route, then delete its TUN.

## Transport and reconnect limitations

Only RFC1918 private routes are accepted. Public Iroh UDP/relay traffic therefore
remains outside the tunnel; routes overlapping local endpoint addresses are
rejected. Selected remote transport addresses are checked too; an incompatible
path change cancels the VPN. Avoid overlapping home/remote LANs. Full tunnel support needs a separate,
verified transport-exclusion implementation on each platform and is intentionally
rejected in this version. IPv6 VPN is also rejected.

A failed QUIC session closes the VPN; reconnect creates a new packet session.
Broken TCP streams are not resumed. Seamless background reconnect and broader
network-change validation remain on the device-test checklist.
