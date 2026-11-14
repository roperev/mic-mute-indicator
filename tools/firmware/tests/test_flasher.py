# SPDX-License-Identifier: GPL-2.0-or-later
import io
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import struct
import sys
import unittest
from unittest.mock import Mock, patch
import uuid

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import flasher as f

MAC = "aa:bb:cc:dd:ee:ff"
IMAGE = bytes([0x42]) * f.FLASH_SIZE
FLASH = bytes([0x19]) * f.FLASH_SIZE


class FakeBackend:
    def __init__(self):
        self.flash = FLASH
        self.calls = []
        self.device = {"mac": MAC, "chip": "esp32s3", "flashSize": f.FLASH_SIZE, "secured": False}
        self.corrupt_backup = False
        self.corrupt_write = False
        self.short_read = False
        self.fail_write = False
        self.fail_reset = False
        self.full_reads = 0

    def connect(self, port):
        self.calls.append("connect")

    def identify(self):
        self.calls.append("identify")
        return dict(self.device)

    def prepare(self):
        self.calls.append("prepare")

    def read(self, offset, length):
        self.calls.append(("read", offset, length))
        if offset == 0:
            self.full_reads += 1
        data = self.flash[offset:offset + length]
        if self.short_read:
            return data[:-1]
        if self.corrupt_backup and self.full_reads >= 2:
            return b"\x00" + data[1:]
        return data

    def write(self, data):
        self.calls.append("write")
        if self.fail_write:
            raise OSError("Connection lost")
        self.flash = data if not self.corrupt_write else bytes([0]) * len(data)

    def reset(self):
        self.calls.append("reset")
        if self.fail_reset:
            raise OSError("Reset failed")

    def close(self):
        self.calls.append("close")


class FakeGate:
    def __init__(self, events):
        self.events = events
        self.cancel = False
        self.authorization_error = None
        self.calls = 0

    def check_cancel(self):
        self.calls += 1
        if self.cancel:
            raise f.SafetyError("Cancelled")

    def authorize(self, mac):
        assert self.events[-1]["type"] == "readyToWrite"
        assert self.events[-1]["mac"] == mac
        if self.authorization_error:
            raise f.SafetyError(self.authorization_error)


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.root = TOOLS.parents[1] / "build/firmware-tests" / uuid.uuid4().hex
        self.root.mkdir(parents=True, mode=0o700)
        self.image = self.root / "micmatrix.bin"
        self.image.write_bytes(IMAGE)
        reference = {"micmatrixLength": 350000, "micmatrixSHA256": f.digest(IMAGE[:350000]),
                     "micmatrixImageSHA256": f.digest(IMAGE)}
        (self.root / "fingerprints.json").write_text(json.dumps(reference))
        self.root_patch = patch.object(f, "ROOT", self.root)
        self.root_patch.start()
        self.request = {"operation": "install", "port": "/dev/cu.fake-test",
                        "expectedMAC": MAC, "imagePath": str(self.image),
                        "imageSHA256": f.digest(IMAGE), "backupDirectory": str(self.root / "backups")}
        self.backend = FakeBackend()
        self.events = []
        self.gate = FakeGate(self.events)

    def tearDown(self):
        self.root_patch.stop()
        shutil.rmtree(self.root)

    def emit(self, kind, **values):
        self.events.append({"type": kind, **values})

    def run_transaction(self):
        f.transaction(self.request, self.backend, self.gate, self.emit)

    def assert_no_write(self):
        self.assertNotIn("write", self.backend.calls)
        self.assertNotIn("readyToWrite", [e["type"] for e in self.events])

    def test_default_backup_verify_authorization_write_verify_reset(self):
        self.run_transaction()
        types = [e["type"] for e in self.events]
        self.assertLess(types.index("backup"), types.index("readyToWrite"))
        self.assertEqual(types[-1], "complete")
        self.assertEqual(self.backend.calls.count("connect"), 1)
        self.assertEqual(self.backend.calls.count("reset"), 1)
        write = self.backend.calls.index("write")
        self.assertEqual(len([c for c in self.backend.calls[write + 1:] if isinstance(c, tuple)]), 64)
        self.assertLess(write, self.backend.calls.index("reset"))
        backup = next(e for e in self.events if e["type"] == "backup")
        self.assertEqual(Path(backup["backupPath"]).read_bytes(), FLASH)
        self.assertEqual(f.digest(FLASH), backup["sha256"])
        self.assertEqual(stat.S_IMODE(Path(backup["backupPath"]).stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(Path(backup["backupPath"]).parent.stat().st_mode), 0o700)
        self.assertEqual(json.loads(Path(backup["metadataPath"]).read_text())["role"], "snapshot")
        self.assertEqual(json.loads((self.root / "backups/transaction.json").read_text())["state"], "complete")

    def test_inspect_reads_fingerprint_never_writes_or_backs_up(self):
        self.request = {"operation": "inspect", "port": "/dev/cu.fake-test", "backupDirectory": str(self.root / "backups")}
        self.run_transaction()
        self.assert_no_write()
        reads = [c for c in self.backend.calls if isinstance(c, tuple)]
        self.assertEqual(reads[0][1], f.ORIGINAL_OFFSET)
        self.assertEqual(sum(c[2] for c in reads), f.ORIGINAL_LENGTH)
        self.assertEqual(self.backend.calls[-2:], ["reset", "close"])
        self.assertEqual(json.loads((self.root / "backups/transaction.json").read_text())["state"], "inspected")

    def test_wrong_mac_fails_before_backup_and_stub(self):
        self.backend.device["mac"] = "00:11:22:33:44:55"
        with self.assertRaisesRegex(f.SafetyError, "MAC"):
            self.run_transaction()
        self.assert_no_write()
        self.assertNotIn("prepare", self.backend.calls)
        self.assertFalse(any(isinstance(c, tuple) for c in self.backend.calls))

    def test_unsupported_chip_size_or_security(self):
        for key, value in [("chip", "esp32"), ("flashSize", 8388608), ("secured", True)]:
            with self.subTest(key=key):
                self.backend = FakeBackend()
                self.backend.device[key] = value
                with self.assertRaises(f.SafetyError):
                    self.run_transaction()
                self.assert_no_write()
                self.assertNotIn("prepare", self.backend.calls)

    def test_missing_mac_or_skip_confirmation_never_connects(self):
        for field in ("expectedMAC", "skipBackupConfirmed"):
            request = dict(self.request)
            if field == "expectedMAC":
                del request[field]
            else:
                request["backup"] = False
            with self.subTest(field=field), self.assertRaises(f.SafetyError):
                f.transaction(request, self.backend, self.gate, self.emit)
        self.assertEqual(self.backend.calls, [])

    def test_explicit_skip_still_requires_write_gate(self):
        self.request.update(backup=False, skipBackupConfirmed=True)
        self.gate.authorization_error = "Cancelled"
        with self.assertRaisesRegex(f.SafetyError, "Cancelled"):
            self.run_transaction()
        self.assertNotIn("write", self.backend.calls)
        self.assertNotIn("backup", [e["type"] for e in self.events])
        self.assertEqual(self.backend.calls[-2:], ["reset", "close"])

    def test_backup_independent_verification_failure_aborts_and_removes_partial(self):
        self.backend.corrupt_backup = True
        with self.assertRaisesRegex(f.SafetyError, "differ"):
            self.run_transaction()
        self.assert_no_write()
        self.assertEqual(list((self.root / "backups").glob("*.bin")), [])
        self.assertEqual(list((self.root / "backups").glob("*.partial")), [])
        self.assertEqual(list((self.root / "backups").glob(".*.partial")), [])

    def test_short_flash_read_aborts(self):
        self.backend.short_read = True
        with self.assertRaisesRegex(f.SafetyError, "Short flash"):
            self.run_transaction()
        self.assert_no_write()

    def test_disk_full_does_not_skip_backup(self):
        with patch.object(f.shutil, "disk_usage", return_value=Mock(free=1000)):
            with self.assertRaisesRegex(f.SafetyError, "disk space"):
                self.run_transaction()
        self.assert_no_write()

    def test_disk_write_error_aborts(self):
        actual_fdopen = os.fdopen
        def fail_write(fd, mode):
            if mode == "wb":
                os.close(fd)
                raise OSError("Disk full")
            return actual_fdopen(fd, mode)
        with patch.object(f.os, "fdopen", side_effect=fail_write):
            with self.assertRaises(OSError):
                self.run_transaction()
        self.assertIn("connect", self.backend.calls)
        self.assert_no_write()

    def test_cancellation_before_connect(self):
        self.gate.cancel = True
        with self.assertRaisesRegex(f.SafetyError, "Cancelled"):
            self.run_transaction()
        self.assertEqual(self.backend.calls, ["close"])
        self.assert_no_write()

    def test_cancel_after_backup_never_erases(self):
        self.gate.authorization_error = "Cancelled"
        with self.assertRaisesRegex(f.SafetyError, "Cancelled"):
            self.run_transaction()
        self.assertNotIn("write", self.backend.calls)
        self.assertIn("backup", [e["type"] for e in self.events])
        self.assertEqual(self.backend.calls[-2:], ["reset", "close"])

    def test_write_failure_or_corrupt_readback_stays_in_bootloader(self):
        for field in ("fail_write", "corrupt_write"):
            with self.subTest(field=field):
                self.backend = FakeBackend()
                setattr(self.backend, field, True)
                self.request.update(backup=False, skipBackupConfirmed=True)
                with self.assertRaises((OSError, f.SafetyError)):
                    self.run_transaction()
                self.assertNotIn("reset", self.backend.calls)
                journal = json.loads((self.root / "backups/transaction.json").read_text())
                self.assertEqual(journal["state"], "failed")
                self.assertNotIn("complete", [e["type"] for e in self.events])

    def test_durable_journal_exists_before_first_write(self):
        self.request.update(backup=False, skipBackupConfirmed=True)
        original_write = self.backend.write
        def verify_journal(data):
            journal_path = self.root / "backups/transaction.json"
            self.assertEqual(json.loads(journal_path.read_text())["state"], "writing")
            self.assertEqual(stat.S_IMODE(journal_path.stat().st_mode), 0o600)
            original_write(data)
        self.backend.write = verify_journal
        self.run_transaction()

    def test_reset_failure_is_not_success(self):
        self.backend.fail_reset = True
        self.request.update(backup=False, skipBackupConfirmed=True)
        with self.assertRaisesRegex(OSError, "Reset failed"):
            self.run_transaction()
        self.assertNotIn("complete", [e["type"] for e in self.events])
        self.assertEqual(json.loads((self.root / "backups/transaction.json").read_text())["state"], "failed")

    def test_prior_original_is_never_overwritten_and_later_backup_is_snapshot(self):
        original_app_sha = f.digest(FLASH[f.ORIGINAL_OFFSET:f.ORIGINAL_OFFSET + f.ORIGINAL_LENGTH])
        with patch.object(f, "ORIGINAL_SHA256", original_app_sha):
            self.run_transaction()
        original_path = self.root / f"backups/original-{MAC.replace(':', '')}.json"
        original_record = original_path.read_bytes()
        first_backup = next(e for e in self.events if e["type"] == "backup")
        self.events.clear()
        self.backend.flash = FLASH
        with patch.object(f, "ORIGINAL_SHA256", original_app_sha):
            self.run_transaction()
        second_backup = next(e for e in self.events if e["type"] == "backup")
        self.assertNotEqual(first_backup["backupPath"], second_backup["backupPath"])
        self.assertEqual(original_path.read_bytes(), original_record)
        self.assertEqual(json.loads(Path(second_backup["metadataPath"]).read_text())["role"], "snapshot")
        self.assertEqual(Path(first_backup["backupPath"]).read_bytes(), FLASH)
        originals = [p for p in (self.root / "backups").glob("*.json")
                     if json.loads(p.read_bytes()).get("role") == "original"]
        self.assertEqual(originals, [original_path])

    def test_custom_firmware_never_creates_original_record(self):
        self.run_transaction()
        self.assertEqual(list((self.root / "backups").glob("original-*.json")), [])

    def metadata(self):
        return {"formatVersion": 1, "mac": MAC, "chip": "esp32s3",
                "flashSize": f.FLASH_SIZE, "sha256": f.digest(IMAGE), "imagePath": str(self.image),
                "verified": True, "role": "snapshot", "firmware": "unknown", "createdAt": f.utc_now()}

    def restore(self, metadata=None):
        path = self.root / "restored.json"
        path.write_text(json.dumps(metadata or self.metadata()))
        self.request.update(operation="restore", restoreMetadataPath=str(path))
        return path

    def test_restore_with_verified_imported_metadata_and_default_safety_backup(self):
        self.restore()
        self.run_transaction()
        self.assertEqual(self.backend.flash, IMAGE)
        self.assertIn("backup", [e["type"] for e in self.events])

    def test_restore_normalizes_uppercase_request_metadata_and_write_authorization(self):
        metadata = self.metadata()
        metadata["mac"] = MAC.upper()
        self.restore(metadata)
        self.request["expectedMAC"] = MAC.upper()
        read_fd, write_fd = os.pipe()
        gate = f.WriteGate(read_fd, timeout=1)
        def emit(kind, **values):
            self.emit(kind, **values)
            if kind == "readyToWrite":
                command = {"command": "authorizeWrite", "mac": MAC.upper()}
                os.write(write_fd, json.dumps(command).encode() + b"\n")
        try:
            f.transaction(self.request, self.backend, gate, emit)
        finally:
            os.close(read_fd)
            os.close(write_fd)
        self.assertIn("backup", [e["type"] for e in self.events])
        self.assertEqual(self.backend.flash, IMAGE)
        self.assertEqual(self.events[-1]["type"], "complete")
        self.assertEqual(self.backend.calls[-2:], ["reset", "close"])

    def test_parent_imported_original_provenance_is_accepted_for_restore(self):
        metadata = self.metadata()
        metadata.update(role="original", firmware="stock (user-confirmed imported original)")
        self.restore(metadata)
        self.run_transaction()
        self.assertEqual(self.backend.flash, IMAGE)

    def test_prior_imported_original_prevents_new_original_and_is_not_rewritten(self):
        directory = self.root / "backups"
        f.protected_directory(directory)
        metadata = self.metadata()
        metadata.update(role="original", firmware="imported original")
        path = directory / "imported-original.json"
        path.write_text(json.dumps(metadata))
        original_bytes = path.read_bytes()
        reference = f.digest(FLASH[f.ORIGINAL_OFFSET:f.ORIGINAL_OFFSET + f.ORIGINAL_LENGTH])
        with patch.object(f, "ORIGINAL_SHA256", reference):
            self.run_transaction()
        backup = next(e for e in self.events if e["type"] == "backup")
        record = json.loads(Path(backup["metadataPath"]).read_text())
        self.assertEqual(record["role"], "snapshot")
        self.assertEqual(record["firmware"], "stock")
        self.assertEqual(path.read_bytes(), original_bytes)
        self.assertEqual(list(directory.glob("original-*.json")), [])

    def test_actual_prewrite_cancel_records_cancelled_and_resets(self):
        self.request.update(backup=False, skipBackupConfirmed=True)
        self.gate.authorize = Mock(side_effect=f.Cancelled("Cancelled"))
        with self.assertRaises(f.Cancelled):
            self.run_transaction()
        self.assertEqual(json.loads((self.root / "backups/transaction.json").read_text())["state"], "cancelled")
        self.assertNotIn("write", self.backend.calls)
        self.assertEqual(self.backend.calls[-2:], ["reset", "close"])

    def test_cancel_during_inspection_resets_without_write(self):
        self.request["operation"] = "inspect"
        def cancel_after_prepare():
            raise f.Cancelled("Cancelled")
        self.backend.prepare = cancel_after_prepare
        with self.assertRaises(f.Cancelled):
            self.run_transaction()
        self.assertNotIn("write", self.backend.calls)
        self.assertEqual(self.backend.calls[-2:], ["reset", "close"])

    def test_short_disk_write_is_not_a_valid_backup(self):
        protected = self.root / "backups"
        f.protected_directory(protected)
        actual_fdopen = os.fdopen
        class ShortWriter:
            def __init__(self, stream):
                self.stream = stream
            def __enter__(self):
                self.stream.__enter__()
                return self
            def __exit__(self, *args):
                return self.stream.__exit__(*args)
            def write(self, data):
                self.stream.write(data[:-1])
                return len(data) - 1
        def wrapped(fd, mode):
            return ShortWriter(actual_fdopen(fd, mode))
        with patch.object(f.os, "fdopen", side_effect=wrapped):
            with self.assertRaisesRegex(f.SafetyError, "Short disk write"):
                f.make_backup(protected, self.backend, self.backend.device, "unknown", self.gate, self.emit)
        self.assertEqual(list(protected.glob("*.bin")), [])
        self.assertEqual(list(protected.glob(".*.partial")), [])

    def test_restore_metadata_wrong_mac_hash_path_verification_size_chip_role(self):
        cases = [("mac", "11:22:33:44:55:66"), ("sha256", "0" * 64),
                 ("imagePath", str(self.root / "other.bin")), ("verified", False),
                 ("flashSize", 0), ("chip", "esp32"), ("role", "stock"), ("formatVersion", True)]
        for key, value in cases:
            with self.subTest(key=key):
                metadata = self.metadata()
                metadata[key] = value
                self.restore(metadata)
                with self.assertRaises((OSError, f.SafetyError)):
                    self.run_transaction()
                self.assertEqual(self.backend.calls, [])

    def test_temporary_files_cannot_be_restored(self):
        path = self.root / ".backup.partial"
        path.write_bytes(IMAGE)
        metadata = self.metadata()
        metadata["imagePath"] = str(path)
        self.restore(metadata)
        self.request["imagePath"] = str(path)
        with self.assertRaisesRegex(f.SafetyError, "Temporary"):
            self.run_transaction()
        self.assertEqual(self.backend.calls, [])

    def test_wrong_size_corrupt_or_unbundled_image_never_connects(self):
        for data, sha in [(IMAGE[:-1], f.digest(IMAGE[:-1])), (IMAGE, "0" * 64),
                          (FLASH, f.digest(FLASH))]:
            with self.subTest(length=len(data), sha=sha):
                self.image.write_bytes(data)
                self.request["imageSHA256"] = sha
                with self.assertRaises(f.SafetyError):
                    self.run_transaction()
                self.assertEqual(self.backend.calls, [])

    def test_symlink_assets_and_backup_directory_are_rejected(self):
        link = self.root / "link.bin"
        link.symlink_to(self.image)
        self.request["imagePath"] = str(link)
        with self.assertRaises(OSError):
            self.run_transaction()
        self.request["imagePath"] = str(self.image)
        (self.root / "real").mkdir()
        (self.root / "backups").symlink_to(self.root / "real")
        with self.assertRaises(f.SafetyError):
            self.run_transaction()
        self.assertEqual(self.backend.calls, [])

    def test_invalid_operation_port_and_boolean_rejected(self):
        for key, value in [("operation", "erase"), ("port", "/dev/tty.fake"), ("port", "rfc2217://host"),
                           ("port", "/dev/cu.a/other"), ("backup", 1)]:
            request = dict(self.request, **{key: value})
            with self.subTest(key=key, value=value), self.assertRaises(f.SafetyError):
                f.transaction(request, self.backend, self.gate, self.emit)

    def test_fingerprint_uses_application_region(self):
        self.backend.flash = b"\xff" * f.ORIGINAL_OFFSET + IMAGE[f.ORIGINAL_OFFSET:]
        self.assertEqual(f.fingerprint(self.backend), "micmatrix")
        self.backend.flash = FLASH
        self.assertEqual(f.fingerprint(self.backend), "unrecognized")
        reference = f.digest(FLASH[f.ORIGINAL_OFFSET:f.ORIGINAL_OFFSET + f.ORIGINAL_LENGTH])
        with patch.object(f, "ORIGINAL_SHA256", reference):
            self.assertEqual(f.fingerprint(self.backend), "stock")


class WriteGateTests(unittest.TestCase):
    def setUp(self):
        self.read, self.write = os.pipe()
        self.gate = f.WriteGate(self.read, timeout=0.01)

    def tearDown(self):
        os.close(self.read)
        if self.write is not None:
            os.close(self.write)

    def send(self, value):
        os.write(self.write, json.dumps(value).encode() + b"\n")

    def test_correct_authorization(self):
        self.send({"command": "authorizeWrite", "mac": MAC})
        self.gate.authorize(MAC)

    def test_equivalent_mac_case_is_accepted_in_both_directions(self):
        for expected, supplied in [(MAC, MAC.upper()), (MAC.upper(), MAC),
                                   (MAC.upper(), "aA:Bb:cC:Dd:eE:Ff")]:
            with self.subTest(expected=expected, supplied=supplied):
                self.send({"command": "authorizeWrite", "mac": supplied})
                self.gate.authorize(expected)

    def test_early_authorization_is_stale(self):
        self.send({"command": "authorizeWrite", "mac": MAC})
        with self.assertRaisesRegex(f.SafetyError, "Stale"):
            self.gate.check_cancel()

    def test_cancel(self):
        self.send({"command": "cancel"})
        with self.assertRaisesRegex(f.SafetyError, "Cancelled"):
            self.gate.authorize(MAC)

    def test_wrong_mac(self):
        self.send({"command": "authorizeWrite", "mac": "00:11:22:33:44:55"})
        with self.assertRaisesRegex(f.SafetyError, "MAC"):
            self.gate.authorize(MAC)

    def test_normalization_does_not_accept_wrong_mac_invalid_format_or_extra_fields(self):
        for command in [
            {"command": "authorizeWrite", "mac": "AA:BB:CC:DD:EE:00"},
            {"command": "authorizeWrite", "mac": "AABBCCDDEEFF"},
            {"command": "authorizeWrite"},
            {"command": "authorizeWrite", "mac": MAC.upper(), "force": True},
        ]:
            with self.subTest(command=command):
                self.send(command)
                with self.assertRaises(f.SafetyError):
                    self.gate.authorize(MAC)

    def test_timeout(self):
        with self.assertRaisesRegex(f.SafetyError, "timed out"):
            self.gate.authorize(MAC)

    def test_eof(self):
        os.close(self.write)
        self.write = None
        with self.assertRaisesRegex(f.SafetyError, "closed"):
            self.gate.authorize(MAC)

    def test_oversized_and_malformed_commands(self):
        os.write(self.write, b"x" * 1025)
        with self.assertRaisesRegex(f.SafetyError, "1024"):
            self.gate.authorize(MAC)

    def test_multiple_or_cancel_queued_commands(self):
        self.send({"command": "authorizeWrite", "mac": MAC})
        self.send({"command": "cancel"})
        with self.assertRaisesRegex(f.SafetyError, "Additional"):
            self.gate.authorize(MAC)


class FirmwareSignatureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from esptool.bin_image import LoadFirmwareImage
        cls.load_image = staticmethod(LoadFirmwareImage)
        cls.root = TOOLS.parents[1]
        references = json.loads((TOOLS / "fingerprints.json").read_bytes())
        merged = (cls.root / "Resources/Firmware/micmatrix.bin").read_bytes()
        cls.current = merged[f.ORIGINAL_OFFSET:f.ORIGINAL_OFFSET + references["micmatrixLength"]]

    def variant(self, change=None):
        image = self.load_image("esp32s3", self.current)
        segment = next(s for s in image.segments if all(marker in s.data for marker in f.V4_MARKERS))
        data = bytearray(segment.data)
        data[80] = ord("0") if data[80] != ord("0") else ord("1")
        segment.data = bytes(data)
        if change:
            change(image, segment)
        for index, segment in enumerate(image.segments):
            segment.name = f"fixture-{index}"
        return image.save(None)

    def classify(self, app, extra=b""):
        backend = self.application_backend(app, extra)
        return f.fingerprint(backend)

    def partition_table(self, size=0x140000, kind=0):
        table = (
            struct.pack("<HBBII16sI", 0x50aa, 1, 2, 0x9000, 0x7000, b"nvs", 0)
            + struct.pack("<HBBII16sI", 0x50aa, kind, 0, f.ORIGINAL_OFFSET, size, b"factory", 0)
            + struct.pack("<HBBII16sI", 0x50aa, 1, 0x82, f.ORIGINAL_OFFSET + size,
                          f.FLASH_SIZE - f.ORIGINAL_OFFSET - size, b"vfs", 0)
        )
        return (table + b"\xeb\xeb" + b"\xff" * 14 + hashlib.md5(table).digest()).ljust(
            f.PARTITION_LENGTH, b"\xff")

    def application_backend(self, app, extra=b"", size=0x140000, kind=0):
        backend = FakeBackend()
        flash = bytearray(b"\xff" * f.FLASH_SIZE)
        flash[f.ORIGINAL_OFFSET:f.ORIGINAL_OFFSET + len(app) + len(extra)] = app + extra
        flash[f.PARTITION_OFFSET:f.PARTITION_OFFSET + f.PARTITION_LENGTH] = self.partition_table(size, kind)
        backend.flash = bytes(flash)
        return backend

    def micropython_markers(self):
        return b"\0MicroPython v1.26.1 on 2025-09-11\0" + b"".join(f.MICROPYTHON_MARKERS)

    def micropython_variant(self, padding=0):
        def change(image, segment):
            for marker in f.V4_MARKERS:
                segment.data = segment.data.replace(marker, b"x" * len(marker))
            segment.data += b"\x7f" * padding + self.micropython_markers()
        return self.variant(change)

    def test_older_valid_v4_build_is_recognized_with_explicit_unknown_build(self):
        app = self.variant()
        self.assertNotEqual(f.digest(app), f.digest(self.current))
        self.assertTrue(f.has_micmatrix_v4_signature(app))
        self.assertEqual(self.classify(app), "micmatrix (protocol 4; build unknown)")
        self.assertEqual(self.classify(self.current), "micmatrix")

    def test_corrupt_payload_or_digest_is_not_recognized(self):
        app = bytearray(self.variant())
        app[-1] ^= 1
        self.assertFalse(f.has_micmatrix_v4_signature(bytes(app)))
        self.assertEqual(self.classify(bytes(app)), "unrecognized")
        self.assertFalse(f.has_micmatrix_v4_signature(self.variant()[:40]))

    def test_checksum_is_validated_even_if_appended_digest_matches(self):
        app = bytearray(self.variant())
        image = self.load_image("esp32s3", bytes(app))
        app[image.data_length - 1] ^= 1
        app[image.data_length:image.data_length + 32] = hashlib.sha256(app[:image.data_length]).digest()
        self.assertFalse(f.has_micmatrix_v4_signature(bytes(app)))

    def test_missing_protocol_marker_remains_unrecognized_not_stock_or_alternate(self):
        def change(image, segment):
            segment.data = segment.data.replace(b"MATRIX 4 8 8 25 PRESET1", b"MATRIX 3 8 8 25 PRESET1")
        app = self.variant(change)
        self.assertFalse(f.has_micmatrix_v4_signature(app))
        self.assertEqual(self.classify(app), "unrecognized")

    def test_markers_in_mutable_ram_or_trailing_flash_do_not_identify_runtime(self):
        def ram_only(image, segment):
            from esptool.bin_image import ImageSegment
            for marker in f.V4_MARKERS:
                segment.data = segment.data.replace(marker, b"x" * len(marker))
            image.segments.append(ImageSegment(0x3fc90000, b"".join(f.V4_MARKERS)))
        self.assertEqual(self.classify(self.variant(ram_only)), "unrecognized")
        def remove_marker(image, segment):
            segment.data = segment.data.replace(f.V4_MARKERS[0], b"x" * len(f.V4_MARKERS[0]))
        self.assertEqual(self.classify(self.variant(remove_marker), b"".join(f.V4_MARKERS)), "unrecognized")

    def test_wrong_chip_header_or_free_floating_strings_do_not_identify_runtime(self):
        app = bytearray(self.variant())
        app[12:14] = b"\x00\x00"
        self.assertFalse(f.has_micmatrix_v4_signature(bytes(app)))
        self.assertFalse(f.has_micmatrix_v4_signature(b"".join(f.V4_MARKERS)))

    def test_micropython_requires_valid_application_and_all_runtime_markers(self):
        app = self.micropython_variant()
        self.assertEqual(self.classify(app), "MicroPython")
        for marker in [f.MICROPYTHON_MARKERS[0], b"MicroPython v1.26.1 on 2025-09-11\0"]:
            def remove(image, segment):
                for existing in f.V4_MARKERS:
                    segment.data = segment.data.replace(existing, b"x" * len(existing))
                segment.data += self.micropython_markers().replace(marker, b"x" * len(marker))
            self.assertEqual(self.classify(self.variant(remove)), "unrecognized")
        corrupt = bytearray(app)
        corrupt[-1] ^= 1
        self.assertEqual(self.classify(bytes(corrupt)), "unrecognized")

    def test_micropython_in_nvs_and_filesystem_data_partitions_is_not_runtime_evidence(self):
        def remove(image, segment):
            segment.data = segment.data.replace(f.V4_MARKERS[0], b"x" * len(f.V4_MARKERS[0]))
        backend = self.application_backend(self.variant(remove))
        flash = bytearray(backend.flash)
        markers = self.micropython_markers()
        for offset in (0x9000, f.ORIGINAL_OFFSET + 0x140000):
            flash[offset:offset + len(markers)] = markers
        backend.flash = bytes(flash)
        self.assertEqual(f.fingerprint(backend), "unrecognized")
        data_image = self.application_backend(self.micropython_variant(), kind=1)
        self.assertEqual(f.fingerprint(data_image), "unrecognized")

    def test_micropython_strings_in_mutable_ram_and_trailing_flash_are_ignored(self):
        def ram_only(image, segment):
            from esptool.bin_image import ImageSegment
            for marker in f.V4_MARKERS:
                segment.data = segment.data.replace(marker, b"x" * len(marker))
            image.segments.append(ImageSegment(0x3fc90000, self.micropython_markers()))
        app = self.variant(ram_only)
        self.assertEqual(self.classify(app, self.micropython_markers()), "unrecognized")

    def test_large_micropython_app_is_completed_only_inside_validated_application_partition(self):
        app = self.micropython_variant(padding=f.ORIGINAL_LENGTH)
        self.assertGreater(len(app), f.ORIGINAL_LENGTH)
        backend = self.application_backend(app, size=0x300000)
        self.assertEqual(f.fingerprint(backend), "MicroPython")
        reads = [call for call in backend.calls if isinstance(call, tuple)]
        for _, offset, length in reads:
            if offset != f.PARTITION_OFFSET:
                self.assertGreaterEqual(offset, f.ORIGINAL_OFFSET)
                self.assertLessEqual(offset + length, f.ORIGINAL_OFFSET + 0x300000)
        self.assertTrue(any(offset >= f.ORIGINAL_OFFSET + f.ORIGINAL_LENGTH for _, offset, _ in reads))

    def test_bad_partition_integrity_or_image_exceeding_app_boundary_is_unrecognized(self):
        app = self.micropython_variant()
        backend = self.application_backend(app)
        flash = bytearray(backend.flash)
        flash[f.PARTITION_OFFSET + 16] ^= 1
        backend.flash = bytes(flash)
        self.assertEqual(f.fingerprint(backend), "unrecognized")
        backend = self.application_backend(self.micropython_variant(padding=f.ORIGINAL_LENGTH))
        self.assertEqual(f.fingerprint(backend), "unrecognized")

    def test_conflicting_runtime_signatures_are_not_a_positive_alternate(self):
        def add(image, segment):
            segment.data += self.micropython_markers()
        self.assertEqual(self.classify(self.variant(add)), "unrecognized")


class AdapterTests(unittest.TestCase):
    def test_stage_timeout_is_bounded_and_restores_handler(self):
        import signal
        import time
        before = signal.getsignal(signal.SIGALRM)
        with self.assertRaisesRegex(f.SafetyError, "test timed out"):
            with f.stage_timeout("test", 0.01):
                time.sleep(0.1)
        self.assertEqual(signal.getsignal(signal.SIGALRM), before)

    def test_esptool_adapter_disables_reconnect_preserves_headers_no_force(self):
        backend = f.EspBackend()
        backend.esp = Mock(IS_STUB=True)
        original = backend.esp
        backend.cmds = Mock()
        backend.cmds.run_stub.return_value = original
        backend.prepare()
        self.assertEqual(backend.esp.WRITE_FLASH_ATTEMPTS, 1)
        backend.write(IMAGE)
        args, kwargs = backend.cmds.write_flash.call_args
        self.assertIs(args[0], original)
        self.assertEqual(args[1], [(0, IMAGE)])
        self.assertEqual((kwargs["flash_mode"], kwargs["flash_freq"], kwargs["flash_size"]), ("keep",) * 3)
        self.assertFalse(kwargs["force"])
        self.assertFalse(kwargs["encrypt"])
        self.assertTrue(kwargs["erase_all"])

    def esp(self):
        esp = Mock(CHIP_NAME="ESP32-S3", secure_download_mode=False)
        esp.get_secure_boot_enabled.return_value = False
        esp.get_flash_encryption_enabled.return_value = False
        esp.read_mac.return_value = (170, 187, 204, 221, 238, 255)
        esp.get_security_info.return_value = {
            "flash_crypt_cnt": 0, "parsed_flags": {
                "SECURE_BOOT_EN": False, "SECURE_DOWNLOAD_ENABLE": False,
                "DIS_DOWNLOAD_DCACHE": False, "DIS_DOWNLOAD_ICACHE": False}}
        return esp

    def test_reads_actual_mac_and_actual_flash_size(self):
        backend = f.EspBackend()
        backend.esp = self.esp()
        backend.cmds = Mock()
        backend.cmds.detect_flash_size.return_value = "4MB"
        self.assertEqual(backend.identify(), {
            "chip": "esp32s3", "mac": MAC, "flashSize": f.FLASH_SIZE, "secured": False})
        backend.esp.read_mac.assert_called_once_with()
        backend.cmds.detect_flash_size.assert_called_once_with(backend.esp)

    def test_rejects_security_and_restricted_download_before_read_or_write(self):
        backend = f.EspBackend()
        backend.cmds = Mock()
        for field in ("SECURE_BOOT_EN", "SECURE_DOWNLOAD_ENABLE", "DIS_DOWNLOAD_DCACHE", "DIS_DOWNLOAD_ICACHE",
                      "flash_crypt_cnt", "secure_boot", "flash_encryption", "secure_download_mode"):
            with self.subTest(field=field):
                esp = self.esp()
                if field in esp.get_security_info.return_value["parsed_flags"]:
                    esp.get_security_info.return_value["parsed_flags"][field] = True
                elif field == "flash_crypt_cnt":
                    esp.get_security_info.return_value["flash_crypt_cnt"] = 1
                elif field == "secure_boot":
                    esp.get_secure_boot_enabled.return_value = True
                elif field == "flash_encryption":
                    esp.get_flash_encryption_enabled.return_value = True
                else:
                    esp.secure_download_mode = True
                backend.esp = esp
                with self.assertRaises(f.SafetyError):
                    backend.identify()
                esp.read_mac.assert_not_called()
        backend.cmds.attach_flash.assert_not_called()

    def test_wrong_chip_rejected_before_security_commands(self):
        backend = f.EspBackend()
        backend.esp = Mock(CHIP_NAME="ESP32")
        with self.assertRaisesRegex(f.SafetyError, "Only ESP32-S3"):
            backend.identify()
        backend.esp.get_security_info.assert_not_called()

    def test_chatter_is_bounded(self):
        stream = io.StringIO()
        log = f.BoundedLog(stream, 20)
        log.write("x" * 30)
        log.write("y" * 30)
        self.assertEqual(stream.getvalue(), "x" * 20)


if __name__ == "__main__":
    unittest.main()
