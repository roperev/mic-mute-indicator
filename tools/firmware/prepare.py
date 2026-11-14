#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Rebuild only the pinned sketch; never uploads, opens a port, or reads a board."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
SKETCH = ROOT / "firmware/MicMatrix"
OUTPUT = ROOT / "build/firmware-clean/output"
RESOURCES = ROOT / "Resources/Firmware"


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def source_hash():
    hasher = hashlib.sha256()
    for path in sorted(SKETCH.iterdir()):
        if path.is_file() and path.suffix in (".ino", ".h", ".yaml"):
            hasher.update(path.name.encode() + b"\0" + path.read_bytes() + b"\0")
    return hasher.hexdigest()


def main():
    if sys.version_info < (3, 10):
        raise SystemExit("Use the pinned developer environment (Python >= 3.10).")
    build = ROOT / "build/firmware-clean"
    if build.exists():
        shutil.rmtree(build)
    build.mkdir(parents=True)
    environment = dict(os.environ, TMPDIR=str(build))
    subprocess.run([
        "arduino-cli", "compile", "--profile", "matrix",
        "--build-path", str(build / "cache"), "--output-dir", str(OUTPUT),
        str(SKETCH),
    ], check=True, cwd=ROOT, env=environment)
    flash = bytearray(b"\xff" * 4194304)
    parts = [
        (0, OUTPUT / "MicMatrix.ino.bootloader.bin", 0x8000),
        (0x8000, OUTPUT / "MicMatrix.ino.partitions.bin", 0xe000),
        (0xe000, build / "cache/boot_app0.bin", 0x10000),
        (0x10000, OUTPUT / "MicMatrix.ino.bin", 0x150000),
    ]
    for offset, path, limit in parts:
        data = path.read_bytes()
        if not data or offset + len(data) > limit:
            raise SystemExit(f"Invalid fresh build component: {path.name}")
        flash[offset:offset + len(data)] = data
    compiled = (OUTPUT / "MicMatrix.ino.merged.bin").read_bytes()
    if bytes(flash) != compiled:
        raise SystemExit("Clean merged image does not match the pinned Arduino merge.")
    if flash[0] != 0xe9 or flash[0x10000] != 0xe9:
        raise SystemExit("Missing ESP32-S3 bootloader/app headers.")
    if flash[12:14] != b"\x09\x00" or flash[0x1000c:0x1000e] != b"\x09\x00":
        raise SystemExit("Fresh firmware is not an ESP32-S3 image.")
    RESOURCES.mkdir(parents=True, exist_ok=True)
    (RESOURCES / "micmatrix.bin").write_bytes(flash)
    manifest = {
        "formatVersion": 1, "chip": "esp32s3", "flashSize": 4194304,
        "protocol": 4, "buildID": source_hash(), "image": "micmatrix.bin",
        "sha256": sha256(flash),
    }
    (RESOURCES / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    app = (OUTPUT / "MicMatrix.ino.bin").read_bytes()
    fingerprints = {"micmatrixLength": len(app), "micmatrixSHA256": sha256(app),
                    "micmatrixImageSHA256": manifest["sha256"]}
    (ROOT / "tools/firmware/fingerprints.json").write_text(json.dumps(fingerprints, indent=2) + "\n")
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
