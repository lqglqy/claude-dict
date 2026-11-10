#!/bin/bash
# Compile Sources/Core with the self-tests and run them.
# (SwiftPM/XCTest are not usable with a Command Line Tools-only install, so this uses swiftc directly.)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
chmod +x Tests/fixtures/*.sh
swiftc -swift-version 5 -Onone \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/Core/*.swift Tests/*.swift \
  -o build/selftest
./build/selftest
