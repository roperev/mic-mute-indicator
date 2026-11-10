#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc Sources/TeamsMuteLight/Models.swift \
  Sources/TeamsMuteLight/Outputs/MatrixProtocol.swift \
  scripts/MatrixFirmwareArtwork.swift -o build/matrix-firmware-artwork
build/matrix-firmware-artwork "${1:-firmware/MicMatrix/Artwork.h}"
