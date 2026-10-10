# Optional Chatmail integration evaluation

Direct pairing and authorized tunnels deliberately do not depend on mail delivery.
There is no Chatmail adapter in this version.

Upstream https://github.com/chatmail/core provides the Rust Delta Chat core,
`deltachat-ffi` C bindings used by mobile clients, JSON-RPC bindings and SecureJoin
support. Embedding it is practical in principle on Linux and iOS, but account
lifecycle, its database/blob storage, provider onboarding, contacts, encrypted
message verification and iOS background delivery are substantial independent work.
Adding a dependency and an empty adapter would not deliver those behaviors.

The integration boundary should be a local control-plane operation that produces
an approval request for an already authenticated contact. Bind that contact's
verified cryptographic identity to an Iroh endpoint during a confirmed exchange;
an email address or an unverified plaintext message must never grant permission.
Include protocol version, random operation ID, expiry and exact scope; persist
processed IDs to prevent replay. Surface explicit approve/reject choices and
apply the same core policy APIs used by the CLI/app. Mail transport must not
carry TCP streams or VPN packets, and established tunnels must continue to work
when mail is unavailable. Revocation remains a local authoritative operation.

Before implementation, pin a specific Chatmail release, assess its license and
mobile storage/runtime requirements, and build its iOS FFI alongside Iroh. Test
SecureJoin/contact authentication and duplicate/out-of-order/offline authorization
messages separately. The current small C ABI does not claim to implement any of
this messaging functionality.
