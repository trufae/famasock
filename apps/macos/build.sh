#!/bin/sh
set -eu
mac_root=$(CDPATH= cd "$(dirname "$0")" && pwd)
repo_root=$(CDPATH= cd "$mac_root/../.." && pwd)
export PATH="$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=14.0
export CFLAGS="${CFLAGS:-} -mmacosx-version-min=14.0"
cd "$repo_root"
cargo build --locked --release -p famasock
app="$mac_root/build/Famasock.app"
mkdir -p "$app/Contents/MacOS"
cp "$mac_root/Famasock/Info.plist" "$app/Contents/Info.plist"
swiftc -swift-version 5 -O -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -import-objc-header "$repo_root/crates/famasock/include/famasock.h" \
  "$mac_root"/Famasock/*.swift "$repo_root/target/release/libfamasock.a" \
  -framework SwiftUI -framework AppKit -framework Network -framework Security \
  -framework SystemConfiguration -framework CoreFoundation -lresolv -liconv \
  -o "$app/Contents/MacOS/Famasock"
codesign --force --sign - --identifier org.radare.famasock.macos "$app"
echo "Built $app"
