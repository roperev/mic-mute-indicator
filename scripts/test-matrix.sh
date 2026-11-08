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
