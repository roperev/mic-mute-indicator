#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc Sources/TeamsMuteLight/Models.swift \
  Sources/TeamsMuteLight/Outputs/MatrixProtocol.swift \
  scripts/MatrixGallery.swift -o build/matrix-gallery-generator
build/matrix-gallery-generator Resources/matrix-gallery.svg
build/matrix-gallery-generator Resources/matrix-gallery-animated.svg --animated
