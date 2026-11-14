#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail
cd "$(dirname "$0")/../.."
PYTHON="${FIRMWARE_PYTHON:-/opt/homebrew/opt/python@3.13/bin/python3.13}"
if [[ ! -x "$PYTHON" ]]; then
  echo "Install Python 3.13 (brew install python@3.13), or set FIRMWARE_PYTHON." >&2
  exit 1
fi
[[ "$(uname -m)" == arm64 ]] || { echo "Build on Apple Silicon." >&2; exit 1; }
mkdir -p build/firmware-work build/FirmwareTools build/firmware-runtime
export TMPDIR="$PWD/build/firmware-work"
export PYINSTALLER_CONFIG_DIR="$PWD/build/firmware-work/config"
if [[ ! -x build/firmware-python/bin/python ]]; then
  "$PYTHON" -m venv build/firmware-python
fi
PYTHON="$PWD/build/firmware-python/bin/python"
"$PYTHON" -m pip install --quiet --disable-pip-version-check -r tools/firmware/requirements.txt
"$PYTHON" -m pip check
if [[ "${1:-}" != "--helper-only" ]]; then
  "$PYTHON" tools/firmware/prepare.py
fi
"$PYTHON" -m unittest discover -s tools/firmware/tests -v
"$PYTHON" -m PyInstaller --noconfirm --clean --onefile --console --log-level WARN \
  --target-architecture arm64 --name MicMatrixFlasher \
  --distpath build/FirmwareTools --workpath build/firmware-work/pyinstaller \
  --specpath build/firmware-work \
  --add-data "$PWD/tools/firmware/esptool.cfg:." \
  --add-data "$PWD/tools/firmware/fingerprints.json:." \
  --collect-data esptool \
  --exclude-module tkinter --exclude-module readline \
  tools/firmware/flasher.py
file build/FirmwareTools/MicMatrixFlasher
TMPDIR="$PWD/build/firmware-runtime" build/FirmwareTools/MicMatrixFlasher --version
"$PYTHON" tools/firmware/tests/frozen_smoke.py build/FirmwareTools/MicMatrixFlasher
"$PYTHON" tools/firmware/tests/audit_frozen.py build/FirmwareTools/MicMatrixFlasher
"$PYTHON" tools/firmware/package_sources.py
