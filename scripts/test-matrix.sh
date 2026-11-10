#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc Sources/TeamsMuteLight/Models.swift \
  Sources/TeamsMuteLight/Effects.swift \
  Sources/TeamsMuteLight/Outputs/MatrixProtocol.swift \
  Tests/MatrixTests.swift -o build/matrix-swift-tests
build/matrix-swift-tests
c++ -std=c++11 -Wall -Wextra -Werror firmware/tests/protocol.cpp -o build/matrix-protocol-tests
build/matrix-protocol-tests
bash scripts/generate-matrix-firmware-artwork.sh build/Artwork.h
cmp build/Artwork.h firmware/MicMatrix/Artwork.h
swiftc Sources/TeamsMuteLight/Models.swift Sources/TeamsMuteLight/Effects.swift \
  Sources/TeamsMuteLight/Outputs/MatrixProtocol.swift scripts/MatrixPresetFixtures.swift \
  -o build/matrix-preset-fixtures
c++ -std=c++11 -Wall -Wextra -Werror firmware/tests/preset-parity.cpp -o build/matrix-preset-parity
build/matrix-preset-fixtures | build/matrix-preset-parity
