# Famasock

Pair your Android device, iPhone, Linux machine or Mac, then choose TCP destinations on your peers
through encrypted Iroh connections. Direct QR pairing does not need an email
account, public IP address or router port forwarding.

This is an **early implementation**, under active validation. See
[the implementation checklist](docs/implementation.md) for tested features and
remaining work. In particular, full-tunnel VPN, IPv6 VPN, SOCKS UDP and Chatmail
integration are not implemented. Do not infer physical-iPhone testing from an
unsigned CI build.

## No root needed for forwarding or SOCKS

TCP forwarding, reverse forwarding and SOCKS5 use ordinary TCP sockets carried
by independent encrypted Iroh QUIC streams. Run `serve`, `pair`, `forward`,
`reverse` and `socks` as your normal user. They do not create or open a TUN device,
change routes/DNS/firewall rules, or require VPN configuration. Choose unprivileged
listening ports (for example 2222, 8080 and 1080); operating-system restrictions
on privileged ports still apply.

The IP-layer VPN is separate and optional. Only `vpn` needs a provisioned Linux
TUN or the iOS Packet Tunnel extension. On iOS, ordinary socket tunnels run in
the foreground; persistent VPN networking belongs to the extension.

## Build and run

Install stable Rust (minimum 1.91; development/CI currently uses 1.99):

```sh
cargo build --workspace --locked
cargo test --workspace --locked
cargo install --path crates/famasock-cli --locked
famasock serve --name home
```

In another terminal on the same machine:

```sh
famasock pair
```

Scan the terminal QR in the native iOS app. Confirm the invitation on the phone,
then check the requesting device identity and type `y` in the terminal. The
invitation expires after five minutes and is consumed by the first valid scan,
even if subsequently rejected. After approval, paired devices can open TCP and
SOCKS destinations and create reverse forwards without additional grants.
Requests are logged by the receiving device. This also applies to saved peers
whose policy has no `restricted` field. Unpaired devices cannot open tunnels.

```sh
famasock peers
# Optional names for frequently used destinations:
famasock allow iPhone ssh 127.0.0.1:22
famasock allow iPhone web 127.0.0.1:8080
```

Names are case-sensitive and need to be unique when used in commands. An endpoint
ID always identifies a peer unambiguously. `--state DIRECTORY` selects a separate
identity/state directory; every command controlling a daemon must use that same
path. The default is `$XDG_STATE_HOME/famasock` or `~/.local/state/famasock`.
The daemon owns the identity; commands use its owner-only Unix socket.

## Linux/macOS client

Run a second daemon with its own state directory on the client machine. Accept the
server invitation on standard input so the secret does not enter shell history:

```sh
famasock serve --name laptop
# In another terminal; paste the invitation URI, then press Return:
famasock pair --accept -
famasock connect home
famasock forward home 2222:127.0.0.1:22
famasock socks home --listen 127.0.0.1:1080
famasock status
famasock stop TUNNEL_ID
famasock disconnect home
```

For connectivity diagnostics, `famasock serve --relay-only` disables direct UDP
and requires encrypted relay transport. Normal mode prefers direct connections.

Multiple peers and tunnels can run together. TCP forwards bind the requested
listening address; the CLI defaults to loopback and iOS offers an all-interfaces
toggle (`0.0.0.0`) for connections from other devices. SOCKS and reverse listeners
bind loopback only.
A dropped TCP stream is never replayed. A new TCP connection may establish a new
Iroh session after disconnection. Tunnels are runtime configuration: restart them
after a daemon restart. `status` reports tunnel IDs and errors are emitted by the
daemon and by the app's event stream.

`famasock --version` (or `famasock version`) shows the CLI's bundled Rust core
version without starting a daemon. `serve` prints its version at startup, and
`famasock status` includes the running daemon's version, so it also works when
the installed CLI has been updated but the daemon has not been restarted. The
iOS peer list shows the app version/build and bundled Rust core version under
**About Famasock**.

## Optional access restrictions

Paired access is open by default. To restrict it, set `"restricted": true` in a
peer's policy. Policies describe what a peer may access **on the machine storing that policy**.
Use `famasock policy PEER policy.json` to replace a peer's inbound policy. This
closes existing sessions so removed grants take effect immediately.

```json
{
  "restricted": true,
  "services": {"ssh": "127.0.0.1:22"},
  "reverse_ports": [8080],
  "socks_networks": ["192.168.1.0/24"],
  "socks_ports": [80, 443]
}
```

Reverse forwarding listens on the peer and connects back to this device. With
the default open access, no port grant is needed; a restricted peer must be
granted the listening port:

```sh
# Runs on the laptop. A home listener at 127.0.0.1:8080 connects back to
# the laptop's 127.0.0.1:3000, over the existing authenticated connection.
famasock reverse home 8080:127.0.0.1:3000
```

SOCKS supports CONNECT, IPv4, IPv6 destinations and remote DNS resolution. With
restrictions enabled, both the destination network and port must be granted.
Every resolved DNS address is
checked before connecting to that numeric address. A SOCKS listener does not
redirect system traffic; applications must explicitly use it (for example,
`curl --socks5-hostname 127.0.0.1:1080 ...`). VPN still needs explicit interface and
route configuration.

```sh
famasock rename PEER new-name
famasock revoke PEER       # removes trust and terminates active sessions
famasock pending
famasock approve REQUEST_ID --reject
famasock cancel-pair       # cancels an outgoing pairing attempt
```

## iOS

Open `apps/ios/Famasock.xcodeproj`. The SwiftUI application includes peer
management, a native camera scanner, forwarding and SOCKS controls, and a VPN
screen backed by an `NEPacketTunnelProvider`. Networking and authorization remain
in Rust. See [iOS build/signing instructions](docs/ios.md).

Ordinary forwarding/SOCKS are foreground-only on iOS. The Packet Tunnel extension
owns the Rust endpoint during VPN use. The app closes its endpoint first and
reopens it after the extension releases the shared state lock. The long-term key
is held in a shared Keychain access group, not in the shared filesystem.

## Android

Open `apps/android` in Android Studio, or use its Gradle wrapper. The native app
supports Android 8.0+ on arm64 and x86_64, QR/paste pairing, multiple peers,
TCP/reverse forwards, SOCKS5, inbound policy editing and private IPv4 split VPN.
It uses the same Rust endpoint as the CLI and iOS app through a small JNI bridge.

A foreground notification keeps networking active after leaving the screen;
its **Stop** action closes all tunnels. Identity is encrypted with an Android
Keystore key and excluded from backup. VPN uses Android's consent screen and
`VpnService`; it does not need root. See [Android build and testing](docs/android.md).

## VPN

The current VPN carries IPv4 packets over QUIC datagrams with MTU 1100. It supports
explicitly allowed **private split routes**. Linux uses pre-provisioned TUN devices;
iOS uses the system Packet Tunnel interface. Linux setup, return routing and
cleanup are described in [docs/vpn.md](docs/vpn.md). macOS CLI VPN is not implemented.

## Start at login on Linux

The example is a **user** systemd service; ordinary forwarding needs no root:

```sh
mkdir -p ~/.local/state/famasock ~/.config/systemd/user
cp packaging/famasock.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now famasock
```

Edit the service if Cargo installs binaries somewhere other than `~/.cargo/bin`,
or if you set a custom state directory. For a headless server, configure user
lingering separately according to your system's policy.

## Development

```sh
cargo fmt --all --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --locked
cargo build --workspace --locked
python3 scripts/cli-smoke.py
# Disposable Linux VM with network namespace/TUN privileges:
sudo python3 scripts/vpn-kernel.py
```

The local network tests use actual Iroh QUIC connections and TCP sockets, with
external relays disabled. CI additionally builds Linux/macOS and unsigned iOS
device/simulator targets. The kernel test creates and removes isolated network
namespaces, forwards ICMP and a 130 KB TCP response over actual TUN devices, then
checks revocation. libc is pinned to 0.2.188 while upstream Iroh dependencies
migrate their Apple mobile declarations removed in libc 0.2.190.
