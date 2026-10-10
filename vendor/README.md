# netdev iOS build fix

`netdev/` is the source of crates.io `netdev` 0.46.3 (MIT), retaining its
upstream license. Cargo resolves it through `[patch.crates-io]`.

The only source modification is in `src/os/darwin/ipv6_addr_flags.rs`:
provide the XNU `in6_ifreq` layout on iOS, where libc exposes neither the
request nor its union. The ioctl encodes a 288-byte request; the union's
largest member is `icmp6_ifstat` (34 u64 counters). The existing macOS code
continues to use libc. A compile-time size assertion covers the iOS layout.

Observed failure: iOS device CI compiling Iroh 1.3 -> netwatch 0.19.3 ->
netdev 0.46.3, `cannot find type in6_ifreq in crate libc`. All available
netdev 0.46 releases have the same issue. This small source patch avoids
runtime dependency-cache edits and makes builds reproducible and offline
once Cargo has downloaded the other dependencies. Remove the patch after
an upstream release fixes the iOS build.

Sources:
- https://github.com/shellrow/netdev/tree/v0.46.3
- https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet6/in6_var.h
- https://github.com/rust-lang/libc/blob/main/src/unix/bsd/apple/mod.rs
