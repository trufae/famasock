# Implementation and verification checklist

This repository started empty. History intentionally separates the workspace,
identity/framing, networking, SOCKS, packet transport, CLI, C ABI, SwiftUI,
NetworkExtension, CI and subsequent fixes. Work is on `feat/famasock`, PR #1.

## Implemented and verified locally

- [x] Rust workspace builds; warnings checked with strict Clippy.
- [x] Persistent restricted-permission identity/state and exclusive owner lock.
- [x] External-key support for iOS Keychain; no external key written to identity file.
- [x] Versioned, bounded protocol and expiring random single-use invitation URI.
- [x] Explicit pairing approval/rejection; paired TCP access defaults to acceptance with request logs and optional restrictions.
- [x] Multi-peer Iroh transport, connection reuse, bounded streams/tasks/queues.
- [x] Concurrent TCP forwarding, EOF/half-close and live-session revocation.
- [x] Paired reverse listeners, optional port restrictions and listener cleanup.
- [x] SOCKS CONNECT, remote DNS and CIDR/port destination checks.
- [x] IPv4 packet validation, QUIC datagram transfer and spoofing rejection.
- [x] C ABI command/event/packet interfaces; blocked-reader shutdown test.

## Implemented, with platform verification in progress

- [x] CLI, daemon control socket, terminal QR and user systemd example.
- [x] Socket-only forwarding/SOCKS require no TUN or root; CLI smoke test
      explicitly refuses root execution. Privileged kernel tests are separate.
- [x] Native SwiftUI peers, scanner, permission editor and tunnel screens.
- [x] Shared Keychain identity and app/extension endpoint ownership handoff.
- [x] NEPacketTunnelProvider and Xcode project/build configuration.
- [x] Linux TUN attachment and per-peer VPN policies.
- [x] CI: Linux/macOS tests, daemon smoke test, real TUN namespace test,
      unsigned iOS device/simulator builds.
- [x] Linux/macOS CLI and real Linux kernel TUN traffic: CI run 38062833960.
- [x] Unsigned native iOS device and simulator builds: CI run 38062833960;
      app/extension bundles uploaded. Physical-device behavior is still unverified.
- [ ] Physical-device signing, Keychain/App Group access and background VPN tests.
- [ ] Wi-Fi/cellular/NAT transitions and physical relay fallback measurements.
- [x] Forced public relay pairing, transfer and revocation: CI run 38062833960.
      Both endpoints disable direct UDP; local development network cannot reach relays.

The development container permits loopback TCP/UDP but denies AF_UNIX creation
and has no TUN/CAP_NET_ADMIN. Thus local tests validate real QUIC/TCP/datagrams;
CLI socket and kernel TUN integration are assigned to CI. macOS/iOS require the
Apple CI runner. No physical iPhone or signing credentials were used.

The iOS builds exposed libc 0.2.190 Apple binding removals used by upstream
netdev/netwatch. The workspace pins libc 0.2.188 until these dependencies migrate
their mobile bindings. This supersedes the temporary netdev source patch; no
vendored networking implementation is needed. Physical-device behavior still
requires validation.

## Remaining engineering work (not represented as working)

- [ ] Privileged Linux route/NAT/DNS setup helper with automatic cleanup;
      current TUN and route provisioning is explicit, documented administration.
- [ ] Full-tunnel IPv4 with transport bypass and exit-node policy/firewall tests.
- [ ] IPv6 VPN and macOS CLI VPN.
- [ ] SOCKS UDP ASSOCIATE, bounded flow mapping and remote UDP/DNS policies.
- [ ] VPN automatic reconnect/backoff and physical-device network-change tests.
- [ ] Persist/re-enable saved tunnel profiles and richer connection history.
- [ ] Optional Chatmail account/contact/messaging/control integration.
- [ ] App icon, accessibility/localization pass, signed distribution packaging.

## Next-session entry point

Read this file, inspect PR #1 checks, fix remaining build/test failures first.
Run `cargo fmt --all --check`, `cargo clippy --workspace --all-targets -- -D warnings`,
and `cargo test --workspace --locked`. Run the two Python integration scripts on
a normal Linux host (the kernel script requires a disposable privileged VM).
Use `docs/ios.md` for Apple builds and device validation. Keep each logical fix in
its own commit. Do not describe checklist items as done without the corresponding
build/test evidence; do not replace missing features with successful no-ops.
