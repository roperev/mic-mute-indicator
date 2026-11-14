#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
sources=()
while IFS= read -r source; do
  sources+=("$source")
done < <(find Sources/TeamsMuteLight -name '*.swift' ! -name Entry.swift | sort)
swiftc "${sources[@]}" Tests/FirmwareTests.swift -o build/firmware-swift-tests \
  -framework IOKit -framework CoreAudio -framework ApplicationServices \
  -framework ServiceManagement -framework Security
build/firmware-swift-tests
