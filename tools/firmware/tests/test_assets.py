# SPDX-License-Identifier: GPL-2.0-or-later
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[3]


class FirmwareAssetsTests(unittest.TestCase):
    def test_exact_manifest_image_and_embedded_fingerprint(self):
        directory = ROOT / "Resources/Firmware"
        manifest = json.loads((directory / "manifest.json").read_bytes())
        self.assertEqual(set(manifest), {
            "formatVersion", "chip", "flashSize", "protocol", "buildID", "image", "sha256"})
        image = (directory / manifest["image"]).read_bytes()
        self.assertEqual(len(image), 4194304)
        self.assertEqual(manifest["sha256"], hashlib.sha256(image).hexdigest())
        fingerprints = json.loads((ROOT / "tools/firmware/fingerprints.json").read_bytes())
        self.assertEqual(fingerprints["micmatrixImageSHA256"], manifest["sha256"])
        app = image[0x10000:0x10000 + fingerprints["micmatrixLength"]]
        self.assertEqual(hashlib.sha256(app).hexdigest(), fingerprints["micmatrixSHA256"])
        self.assertEqual(image[0x9000:0xe000], b"\xff" * 0x5000)
        self.assertEqual(image[0x10000 + len(app):], b"\xff" * (len(image) - 0x10000 - len(app)))
        import sys
        sys.path.insert(0, str(ROOT / "tools/firmware"))
        import prepare
        self.assertEqual(manifest["buildID"], prepare.source_hash())
