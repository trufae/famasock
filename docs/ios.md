# Native iOS build and device validation

Requirements: Xcode with an iOS SDK, Rust, and the Apple Rust targets:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
open apps/ios/Famasock.xcodeproj
```

The checked-in project has two targets: Famasock (SwiftUI) and PacketTunnel
(NetworkExtension). A build phase compiles the shared Rust static library for the
selected SDK/architecture. No Swift copy of the networking protocol exists.
The project can be regenerated deterministically with
`python3 scripts/generate-xcode.py`; change the generator when changing targets
or build settings.

For unsigned compilation (does not install a working VPN on a phone):

```sh
xcodebuild -project apps/ios/Famasock.xcodeproj -scheme Famasock \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  ARCHS=arm64 CODE_SIGNING_ALLOWED=NO build
```

For a physical device, select your development team for BOTH targets. Register
unique app and extension bundle identifiers and replace the defaults as needed:

- app: `org.radare.famasock`
- extension: `org.radare.famasock.PacketTunnel`
- shared App Group build setting: `group.org.radare.famasock`
- shared Keychain suffix: `org.radare.famasock.shared`

Enable Network Extensions (packet-tunnel-provider), App Groups and Keychain
Sharing for the appropriate App IDs/profiles. The Keychain group includes the
team's `AppIdentifierPrefix`. Both targets must have access to the same groups.
The app derives the provider bundle ID by appending `.PacketTunnel` to its own
bundle ID. Do not put signing keys, certificates, profiles or a team credential
in source control. Provisioning and distribution eligibility must be checked in
your Apple developer account.

The app and extension cannot open the same state directory simultaneously. The
app shuts down Rust before starting VPN; the extension shuts down and joins its
packet/event readers before releasing the shared state. If starting the app
while VPN is connected, peer/status information comes from provider messages.
Neither process generates a replacement identity just because the Keychain is
locked or inaccessible: that is an error requiring user attention.

## Physical-device checklist (not yet verified)

1. Install a signed build with both extensions and correct shared entitlements.
2. Scan a QR displayed on a dark and a light terminal; test denied camera access.
3. Check both identities, approve/reject/expire/cancel pairing, restart the app.
4. Forward a service from a Linux host, including a large response and half-close.
5. Verify that unauthorized services/SOCKS destinations are refused.
6. Configure the Linux TUN and policy from vpn.md, start VPN, test allowed subnet.
7. Lock the phone; test traffic, Wi-Fi/cellular changes, sleep and reconnection.
8. Stop VPN, verify route/DNS removal and that foreground networking can reopen.
9. Revoke the phone at the server during live TCP and VPN transfers.
10. Measure extension memory and battery use; validate relay fallback on real NATs.

Sources inspected during implementation:
- https://developer.apple.com/documentation/networkextension/nepackettunnelprovider
- https://developer.apple.com/documentation/networkextension/routing-your-vpn-network-traffic
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.networkextension

An unsigned build is a compilation check, not proof of background VPN behavior,
provisioning correctness, App Store approval or successful physical-device use.
