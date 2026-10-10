#!/bin/sh
set -eu
export PATH="$HOME/.cargo/bin:$PATH"
cd "$SRCROOT/../.."
arch="${CURRENT_ARCH:-undefined_arch}"
if [ "$arch" = undefined_arch ]; then set -- $ARCHS; arch="$1"; fi
case "$PLATFORM_NAME:$arch" in
  iphoneos:arm64) target=aarch64-apple-ios ;;
  iphonesimulator:arm64) target=aarch64-apple-ios-sim ;;
  iphonesimulator:x86_64) target=x86_64-apple-ios ;;
  *) echo "Unsupported Rust Apple target: $PLATFORM_NAME:$CURRENT_ARCH" >&2; exit 1 ;;
esac
# Xcode's SDKROOT is correct for C dependencies (ring) on this destination.
# Avoid inheriting simulator deployment flags into host build scripts.
export IPHONEOS_DEPLOYMENT_TARGET=17.0
cargo build --locked --release -p famasock --target "$target"
mkdir -p "$DERIVED_FILE_DIR"
cp "target/$target/release/libfamasock.a" "$DERIVED_FILE_DIR/libfamasock.a"
