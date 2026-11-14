# SPDX-License-Identifier: GPL-2.0-or-later
"""Restricted, transactional MicMatrix firmware helper. No CLI pass-through."""
from __future__ import annotations

import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import stat
import struct
import sys
import time
import uuid

FLASH_SIZE = 4194304
BLOCK_SIZE = 65536
PARTITION_OFFSET = 0x8000
PARTITION_LENGTH = 0xc00
ORIGINAL_SHA256 = "423eb8c0ba178b11f5d167d53d7fbf1a802bb66e3e1d1dc59e398e05536945e5"
ORIGINAL_OFFSET = 0x10000
ORIGINAL_LENGTH = 1251504
AUTHORIZATION_TIMEOUT = 180
ROOT = Path(__file__).resolve().parent
V4_MARKERS = (
    b"MATRIX 4 8 8 25 PRESET1\0",
    b"ERR imu-unavailable\0",
    b"ERR line-too-long\0",
    b"ERR inactive\0",
    b"ORIENT %u %d %d %d %u\n\0",
)
MICROPYTHON_MARKERS = (
    b"raw REPL; CTRL-B to exit\r\n\0",
    b'Type "help()" for more information.\r\n\0',
)
MICROPYTHON_BANNER = re.compile(
    rb"(?:^|\x00)MicroPython v[0-9]+\.[0-9]+(?:\.[0-9]+)?"
    rb"(?:[-+][A-Za-z0-9.-]+)? on [0-9]{4}-[0-9]{2}-[0-9]{2}\x00"
)


class SafetyError(Exception):
    pass


class Cancelled(SafetyError):
    pass


@contextlib.contextmanager
def stage_timeout(message, seconds):
    def expired(signum, frame):
        raise SafetyError(f"{message} timed out.")
    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def mac_address(value):
    if not isinstance(value, str) or not re.fullmatch(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", value):
        raise SafetyError("Invalid MAC address.")
    return value.lower()


def absolute_path(value, label):
    if not isinstance(value, str) or not os.path.isabs(value) or "\0" in value:
        raise SafetyError(f"{label} must be an absolute path.")
    return Path(value)


def regular_bytes(path, maximum):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise SafetyError("Expected a bounded, regular file.")
        data = stream.read(maximum + 1)
        if len(data) != info.st_size or len(data) > maximum:
            raise SafetyError("File size changed or a short read occurred.")
        return data


def json_file(path):
    try:
        result = json.loads(regular_bytes(path, 65536))
    except (ValueError, UnicodeError) as error:
        raise SafetyError("Invalid JSON file.") from error
    if not isinstance(result, dict):
        raise SafetyError("JSON must contain an object.")
    return result


def sha256_field(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", value):
        raise SafetyError("Invalid SHA-256.")
    return value.lower()


def read_image(path, sha256):
    if path.name.startswith(".") or path.suffix.lower() in (".tmp", ".partial"):
        raise SafetyError("Temporary files cannot be flashed or restored.")
    data = regular_bytes(path, FLASH_SIZE)
    if len(data) != FLASH_SIZE:
        raise SafetyError("Image must be exactly 4 MiB (4194304 bytes).")
    if digest(data) != sha256_field(sha256):
        raise SafetyError("Image SHA-256 does not match.")
    return data


def validate_request(request):
    if request.get("operation") not in ("inspect", "install", "restore"):
        raise SafetyError("Only inspect, install, and restore are supported.")
    if not isinstance(request.get("port"), str) or not re.fullmatch(r"/dev/cu\.[^\s/]+", request["port"]):
        raise SafetyError("Select one exact /dev/cu.* serial port.")
    result = dict(request)
    result["backupDirectory"] = absolute_path(request.get("backupDirectory"), "backupDirectory")
    if request.get("expectedMAC") is not None:
        result["expectedMAC"] = mac_address(request["expectedMAC"])
    elif request["operation"] != "inspect":
        raise SafetyError("expectedMAC is required before installation or restoration.")
    backup = request.get("backup", True)
    if type(backup) is not bool:
        raise SafetyError("backup must be a boolean.")
    result["backup"] = backup
    if not backup and request.get("skipBackupConfirmed") is not True:
        raise SafetyError("Skipping a backup requires explicit confirmation.")
    if request.get("knownOriginalImageSHA256") is not None:
        if sha256_field(request["knownOriginalImageSHA256"]) != ORIGINAL_SHA256:
            raise SafetyError("Unrecognized original-firmware reference.")
    if request["operation"] != "inspect":
        result["imagePath"] = absolute_path(request.get("imagePath"), "imagePath")
        result["imageSHA256"] = sha256_field(request.get("imageSHA256"))
        result["image"] = read_image(result["imagePath"], result["imageSHA256"])
        if request["operation"] == "install":
            reference = json_file(ROOT / "fingerprints.json")
            if result["imageSHA256"] != reference["micmatrixImageSHA256"]:
                raise SafetyError("Install only accepts this helper's bundled MicMatrix image.")
    if request["operation"] == "restore":
        result["restoreMetadataPath"] = absolute_path(request.get("restoreMetadataPath"), "restoreMetadataPath")
        validate_metadata(result["restoreMetadataPath"], result["expectedMAC"],
                          result["imagePath"], result["imageSHA256"])
    return result


def validate_metadata(path, expected_mac, image_path=None, sha256=None):
    if path.name.startswith(".") or path.suffix != ".json":
        raise SafetyError("Restore requires a finalized metadata JSON file.")
    metadata = json_file(path)
    if (type(metadata.get("formatVersion")) is not int or metadata["formatVersion"] != 1
            or metadata.get("verified") is not True
            or metadata.get("chip") != "esp32s3"
            or type(metadata.get("flashSize")) is not int or metadata["flashSize"] != FLASH_SIZE
            or metadata.get("role") not in ("original", "snapshot")
            or not isinstance(metadata.get("firmware"), str) or not 1 <= len(metadata["firmware"]) <= 256
            or not isinstance(metadata.get("createdAt"), str)):
        raise SafetyError("Backup metadata is not a verified 4 MiB ESP32-S3 record.")
    if mac_address(metadata.get("mac")) != expected_mac:
        raise SafetyError("Backup belongs to a different device.")
    recorded_path = absolute_path(metadata.get("imagePath"), "metadata.imagePath")
    recorded_sha = sha256_field(metadata.get("sha256"))
    if image_path is not None and recorded_path != image_path:
        raise SafetyError("Restore image does not match its metadata path.")
    if sha256 is not None and recorded_sha != sha256:
        raise SafetyError("Restore hash does not match its metadata.")
    read_image(recorded_path, recorded_sha)
    return metadata


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def protected_directory(path):
    path.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise SafetyError("Backup directory must be a real directory owned by this user.")
    os.chmod(path, 0o700)


def exclusive_write(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            if stream.write(data) != len(data):
                raise SafetyError("Short disk write.")
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        path.unlink(missing_ok=True)
        raise


def write_json(path, value, replace=False):
    data = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()
    if not replace:
        exclusive_write(path, data)
        sync_directory(path.parent)
        return
    temporary = path.parent / f".journal-{uuid.uuid4().hex}.tmp"
    try:
        exclusive_write(temporary, data)
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


class WriteGate:
    """Unbuffered, bounded input: early/stale authorizations never authorize erasure."""
    def __init__(self, fd=0, timeout=AUTHORIZATION_TIMEOUT):
        self.fd = fd
        self.timeout = timeout
        self.closed = False

    def pending(self):
        return bool(select.select([self.fd], [], [], 0)[0])

    def check_cancel(self):
        if self.pending():
            command = self.read_command(1)
            if command.get("command") == "cancel":
                raise Cancelled("Cancelled before writing.")
            raise SafetyError("Stale input: authorization must follow readyToWrite.")

    def read_command(self, timeout):
        deadline = time.monotonic() + timeout
        data = bytearray()
        while len(data) <= 1024:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.fd], [], [], remaining)[0]:
                raise SafetyError("Write confirmation timed out; nothing was erased.")
            byte = os.read(self.fd, 1)
            if not byte:
                self.closed = True
                raise SafetyError("Input closed before write authorization.")
            if byte == b"\n":
                try:
                    value = json.loads(data)
                except (ValueError, UnicodeError) as error:
                    raise SafetyError("Invalid write confirmation.") from error
                if not isinstance(value, dict):
                    raise SafetyError("Invalid write confirmation.")
                return value
            data.extend(byte)
        raise SafetyError("Write confirmation exceeds 1024 bytes.")

    def authorize(self, mac):
        command = self.read_command(self.timeout)
        if command.get("command") == "cancel":
            raise Cancelled("Cancelled before writing.")
        if (set(command) != {"command", "mac"} or command.get("command") != "authorizeWrite"
                or mac_address(command.get("mac")) != mac_address(mac)):
            raise SafetyError("Write confirmation did not match the expected MAC.")
        if self.pending():
            raise SafetyError("Additional or stale input received before writing.")


class BoundedLog:
    def __init__(self, target, limit=65536):
        self.target, self.remaining = target, limit

    def write(self, text):
        if self.remaining:
            clean = str(text).replace("\x1b", "")
            clean = clean[:self.remaining]
            self.remaining -= len(clean)
            self.target.write(clean)
            self.target.flush()
        return len(text)

    def flush(self):
        self.target.flush()

    def isatty(self):
        return False


class EspBackend:
    """esptool 5.3.1 API adapter; exactly one serial connection, never auto-reconnect."""
    def __init__(self):
        os.environ["ESPTOOL_CFGFILE"] = str(ROOT / "esptool.cfg")
        from esptool import cmds, __version__
        from esptool.util import flash_size_bytes
        if __version__ != "5.3.1":
            raise SafetyError("This helper requires its pinned esptool 5.3.1.")
        self.cmds, self.flash_size_bytes = cmds, flash_size_bytes
        self.esp = None

    def connect(self, port):
        self.esp = self.cmds.detect_chip(port=port, baud=115200, connect_attempts=3)

    def identify(self):
        esp = self.esp
        if esp.CHIP_NAME != "ESP32-S3":
            raise SafetyError(f"Unsupported chip: {esp.CHIP_NAME}. Only ESP32-S3 is supported.")
        info = esp.get_security_info()
        flags = info["parsed_flags"]
        secured = (esp.secure_download_mode or flags["SECURE_BOOT_EN"]
                   or flags["SECURE_DOWNLOAD_ENABLE"]
                   or flags["DIS_DOWNLOAD_DCACHE"] or flags["DIS_DOWNLOAD_ICACHE"]
                   or (int(info["flash_crypt_cnt"]).bit_count() & 1) != 0)
        if secured:
            raise SafetyError("Secured or restricted-download devices are not supported.")
        if esp.get_secure_boot_enabled() or esp.get_flash_encryption_enabled():
            raise SafetyError("Secure Boot or flash encryption is enabled.")
        raw_mac = esp.read_mac()
        if raw_mac is None or len(raw_mac) != 6:
            raise SafetyError("Unable to read the hardware MAC.")
        mac = mac_address(":".join(f"{byte:02x}" for byte in raw_mac))
        self.cmds.attach_flash(esp)
        size = self.cmds.detect_flash_size(esp)
        if size is None:
            raise SafetyError("Unable to determine actual flash size.")
        return {"chip": "esp32s3", "mac": mac, "flashSize": self.flash_size_bytes(size), "secured": False}

    def prepare(self):
        self.esp = self.cmds.run_stub(self.esp)
        if not self.esp.IS_STUB:
            raise SafetyError("A working flasher stub is required.")
        self.esp.WRITE_FLASH_ATTEMPTS = 1
        self.cmds.attach_flash(self.esp)
        self.esp.flash_set_parameters(FLASH_SIZE)

    def read(self, offset, length):
        return self.esp.read_flash(offset, length)

    def write(self, data):
        self.cmds.write_flash(self.esp, [(0, data)], flash_mode="keep", flash_freq="keep",
                              flash_size="keep", erase_all=True, no_progress=True,
                              force=False, encrypt=False, ignore_flash_enc_efuse=False)

    def reset(self):
        self.esp.hard_reset()

    def close(self):
        if self.esp is not None:
            self.esp._port.close()


def validated_application_drom(data):
    if (len(data) < 24 or data[0] != 0xe9 or not 1 <= data[1] <= 16
            or data[12:14] != b"\x09\x00" or data[23] != 1):
        return ()
    from esptool.bin_image import LoadFirmwareImage
    from esptool.targets.esp32s3 import ESP32S3ROM
    from esptool.util import FatalError
    try:
        image = LoadFirmwareImage("esp32s3", data)
        # esptool's structural verify() does not validate these integrity fields.
        if (image.checksum != image.calculate_checksum()
                or len(image.stored_digest) != 32 or image.stored_digest != image.calc_digest):
            return ()
        return tuple(
            segment.data for segment in image.segments
            if ESP32S3ROM.DROM_MAP_START <= segment.addr
            and segment.addr + len(segment.data) <= ESP32S3ROM.DROM_MAP_END
        )
    except (FatalError, ValueError, TypeError, IndexError, struct.error):
        return ()


def has_micmatrix_v4_signature(data):
    return any(all(marker in segment for marker in V4_MARKERS)
               for segment in validated_application_drom(data))


def classify_application(data):
    segments = validated_application_drom(data)
    matrix = any(all(marker in segment for marker in V4_MARKERS) for segment in segments)
    micropython = any(MICROPYTHON_BANNER.search(segment)
                      and all(marker in segment for marker in MICROPYTHON_MARKERS)
                      for segment in segments)
    if matrix and not micropython:
        return "micmatrix (protocol 4; build unknown)"
    if micropython and not matrix:
        return "MicroPython"
    return "unrecognized"


def application_partition_size(backend, gate):
    if gate:
        gate.check_cancel()
    table = backend.read(PARTITION_OFFSET, PARTITION_LENGTH)
    if len(table) != PARTITION_LENGTH:
        raise SafetyError("Short flash read during partition validation.")
    partitions = []
    application_sizes = []
    for position in range(0, PARTITION_LENGTH, 32):
        entry = table[position:position + 32]
        if entry[:16] == b"\xeb\xeb" + b"\xff" * 14:
            if entry[16:] != hashlib.md5(table[:position]).digest():
                return None
            extents = sorted(partitions)
            if any(start < previous_end for (_, previous_end), (start, _) in zip(extents, extents[1:])):
                return None
            return application_sizes[0] if len(application_sizes) == 1 else None
        magic, kind, _, offset, size, _, flags = struct.unpack("<HBBII16sI", entry)
        if magic != 0x50aa or offset < 0x9000 or size == 0 or offset + size > FLASH_SIZE:
            return None
        partitions.append((offset, offset + size))
        if kind == 0 and offset == ORIGINAL_OFFSET and flags == 0:
            application_sizes.append(size)
    return None


def read_complete_application(backend, initial, gate):
    if (len(initial) < 24 or initial[0] != 0xe9 or not 1 <= initial[1] <= 16
            or initial[12:14] != b"\x09\x00" or initial[23] != 1):
        return None
    limit = application_partition_size(backend, gate)
    if limit is None:
        return None
    position = 24
    for _ in range(initial[1]):
        if position + 8 > limit:
            return None
        header = initial[position:position + 8]
        if len(header) != 8:
            if gate:
                gate.check_cancel()
            header = backend.read(ORIGINAL_OFFSET + position, 8)
            if len(header) != 8:
                raise SafetyError("Short application segment-header read.")
        _, length = struct.unpack("<II", header)
        position += 8 + length
        if position > limit:
            return None
    # ESP images end with a checksum at the next 16-byte boundary and a SHA256.
    total = ((position + 16) // 16) * 16 + 32
    if total > limit:
        return None
    application = bytearray(initial[:total])
    while len(application) < total:
        if gate:
            gate.check_cancel()
        length = min(BLOCK_SIZE, total - len(application))
        block = backend.read(ORIGINAL_OFFSET + len(application), length)
        if len(block) != length:
            raise SafetyError("Short flash read while completing the application image.")
        application.extend(block)
    return bytes(application)


def fingerprint(backend, gate=None):
    parts = []
    for offset in range(0, ORIGINAL_LENGTH, BLOCK_SIZE):
        if gate:
            gate.check_cancel()
        length = min(BLOCK_SIZE, ORIGINAL_LENGTH - offset)
        data = backend.read(ORIGINAL_OFFSET + offset, length)
        if len(data) != length:
            raise SafetyError("Short flash read during firmware identification.")
        parts.append(data)
    data = b"".join(parts)
    if digest(data) == ORIGINAL_SHA256:
        return "stock"
    reference = json_file(ROOT / "fingerprints.json")
    size = reference["micmatrixLength"]
    if type(size) is not int or size <= 0 or size > ORIGINAL_LENGTH:
        raise SafetyError("Invalid bundled firmware fingerprint.")
    if digest(data[:size]) == reference["micmatrixSHA256"]:
        return "micmatrix"
    application = read_complete_application(backend, data, gate)
    return classify_application(application) if application is not None else "unrecognized"


def verified_flash_compare(backend, image, gate, emit, start, end, message):
    for offset in range(0, FLASH_SIZE, BLOCK_SIZE):
        if gate:
            gate.check_cancel()
        expected = image[offset:offset + BLOCK_SIZE]
        actual = backend.read(offset, len(expected))
        if actual != expected:
            raise SafetyError(f"{message}: flash bytes differ at offset 0x{offset:x}.")
        emit("progress", message=message, progress=start + (end - start) * (offset + len(expected)) / FLASH_SIZE)


def has_original_record(directory, mac):
    canonical = directory / f"original-{mac.replace(':', '')}.json"
    if canonical.exists():
        validate_metadata(canonical, mac)
        return True
    for path in sorted(directory.glob("*.json")):
        if path.name == "transaction.json":
            continue
        record = json_file(path)
        if record.get("role") == "original" and record.get("mac", "").lower() == mac:
            validate_metadata(path, mac)
            return True
    return False


def make_backup(directory, backend, device, firmware, gate, emit):
    # Reserve room for the image, its metadata/journal, and filesystem bookkeeping.
    if shutil.disk_usage(directory).free < FLASH_SIZE + 1048576:
        raise SafetyError("Insufficient disk space for a verified backup.")
    token = uuid.uuid4().hex
    temporary = directory / f".backup-{token}.partial"
    final = directory / f"backup-{device['mac'].replace(':', '')}-{token}.bin"
    metadata_path = final.with_suffix(".json")
    hasher = hashlib.sha256()
    try:
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream, stage_timeout("Backup read", 600):
            for offset in range(0, FLASH_SIZE, BLOCK_SIZE):
                gate.check_cancel()
                data = backend.read(offset, min(BLOCK_SIZE, FLASH_SIZE - offset))
                if len(data) != min(BLOCK_SIZE, FLASH_SIZE - offset):
                    raise SafetyError("Short flash read; backup was not saved.")
                if stream.write(data) != len(data):
                    raise SafetyError("Short disk write; backup was not saved.")
                hasher.update(data)
                emit("progress", message="Reading safety backup", progress=0.1 + 0.3 * (offset + len(data)) / FLASH_SIZE)
            stream.flush()
            os.fsync(stream.fileno())
        saved = read_image_bytes(temporary, hasher.hexdigest())
        with stage_timeout("Independent backup verification", 600):
            verified_flash_compare(backend, saved, gate, emit, 0.4, 0.65, "Verifying safety backup")
        original_record = directory / f"original-{device['mac'].replace(':', '')}.json"
        role = "snapshot"
        if not has_original_record(directory, device["mac"]) and firmware == "stock":
            role = "original"
        metadata = {
            "formatVersion": 1, **device, "sha256": hasher.hexdigest(),
            "imagePath": str(final), "verified": True, "role": role,
            "firmware": firmware, "createdAt": utc_now(),
        }
        metadata.pop("secured")
        if role == "original":
            metadata_path = original_record
        # link() atomically finalizes without ever replacing a prior image.
        os.link(temporary, final)
        temporary.unlink()
        sync_directory(directory)
        write_json(metadata_path, metadata)
        emit("backup", message="Full flash backup independently verified", mac=device["mac"],
             backupPath=str(final), metadataPath=str(metadata_path), sha256=metadata["sha256"])
        return metadata_path
    finally:
        temporary.unlink(missing_ok=True)


def read_image_bytes(path, sha256):
    """Private temporary backup verification, not a restore input."""
    data = regular_bytes(path, FLASH_SIZE)
    if len(data) != FLASH_SIZE or digest(data) != sha256:
        raise SafetyError("Backup size/hash verification failed.")
    return data


def transaction(request, backend, gate, emit):
    request = validate_request(request)
    operation = request["operation"]
    directory = request["backupDirectory"]
    protected_directory(directory)
    lock_fd = os.open(directory / "transaction.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    connected = False
    writing = False
    reset_done = False
    journal = None
    try:
        lock_info = os.fstat(lock_fd)
        if not stat.S_ISREG(lock_info.st_mode) or lock_info.st_uid != os.getuid():
            raise SafetyError("Transaction lock is not a user-owned regular file.")
        os.fchmod(lock_fd, 0o600)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise SafetyError("Another firmware operation is using this backup directory.") from error
        emit("progress", message="Connecting to the selected device", progress=0)
        gate.check_cancel()
        with stage_timeout("Connection", 45):
            backend.connect(request["port"])
        connected = True
        with stage_timeout("Device identification", 45):
            device = backend.identify()
        if device["chip"] != "esp32s3" or device["flashSize"] != FLASH_SIZE or device["secured"]:
            emit("device", **device, firmware="unrecognized")
            raise SafetyError("Only an unsecured ESP32-S3 with exactly 4 MiB flash is supported.")
        if request.get("expectedMAC") is not None and device["mac"] != request["expectedMAC"]:
            emit("device", **device, firmware="unrecognized")
            raise SafetyError("Hardware MAC does not match the selected device; nothing was written.")
        with stage_timeout("Flasher stub preparation", 45):
            backend.prepare()
        with stage_timeout("Firmware identification", 180):
            firmware = fingerprint(backend, gate)
        emit("device", **device, firmware=firmware)
        if operation == "inspect":
            with stage_timeout("Reset", 30):
                backend.reset()
            reset_done = True
            write_json(directory / "transaction.json",
                       {"formatVersion": 1, "state": "inspected", "operation": operation,
                        **device, "firmware": firmware, "completedAt": utc_now()}, replace=True)
            emit("complete", message="Inspection finished; device reset", mac=device["mac"], firmware=firmware)
            return
        backup_path = None
        if request["backup"]:
            backup_path = make_backup(directory, backend, device, firmware, gate, emit)
        gate.check_cancel()
        emit("readyToWrite", message="Backup complete; awaiting write authorization" if backup_path else
             "Backup explicitly skipped; awaiting write authorization", mac=device["mac"])
        gate.authorize(device["mac"])
        # Revalidate restore records immediately before erasure, retaining the already hashed bytes.
        if operation == "restore":
            validate_metadata(request["restoreMetadataPath"], device["mac"],
                              request["imagePath"], request["imageSHA256"])
        journal = {"formatVersion": 1, "state": "writing", "operation": operation,
                   "mac": device["mac"], "chip": device["chip"], "flashSize": FLASH_SIZE,
                   "imageSHA256": request["imageSHA256"], "imagePath": str(request["imagePath"]),
                   "backupMetadataPath": str(backup_path) if backup_path else None, "createdAt": utc_now()}
        write_json(directory / "transaction.json", journal, replace=True)
        gate.check_cancel()
        writing = True
        emit("progress", message="Erasing and writing the complete 4 MiB image", progress=0.68)
        with stage_timeout("Flash erase/write", 600):
            backend.write(request["image"])
        with stage_timeout("Full flash readback verification", 600):
            verified_flash_compare(backend, request["image"], None, emit, 0.75, 0.98, "Verifying flashed image")
        journal["state"] = "verified"
        write_json(directory / "transaction.json", journal, replace=True)
        with stage_timeout("Reset", 30):
            backend.reset()
        reset_done = True
        journal.update(state="complete", completedAt=utc_now())
        write_json(directory / "transaction.json", journal, replace=True)
        emit("complete", message="Full flash verified and device reset", mac=device["mac"],
             sha256=request["imageSHA256"], progress=1)
    except BaseException as error:
        if not writing and journal is None and isinstance(error, (Cancelled, KeyboardInterrupt)):
            journal = {"formatVersion": 1, "operation": operation,
                       "mac": request.get("expectedMAC"), "createdAt": utc_now()}
        if journal is not None:
            journal.update(state="failed" if writing else "cancelled",
                           message=str(error)[:512], completedAt=utc_now())
            try:
                write_json(directory / "transaction.json", journal, replace=True)
            except OSError:
                pass  # The durable pre-write journal still records an incomplete operation.
        raise
    finally:
        try:
            if connected and not writing and not reset_done:
                with stage_timeout("Cancellation reset", 30):
                    backend.reset()
        finally:
            backend.close()
            os.close(lock_fd)


def main(argv=None):
    parser = argparse.ArgumentParser(description="MicMatrix app firmware helper")
    parser.add_argument("--request")
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args(argv)
    output = sys.stdout
    log = BoundedLog(sys.stderr)

    def emit(kind, **values):
        output.write(json.dumps({"type": kind, **values}, separators=(",", ":")) + "\n")
        output.flush()

    try:
        with contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
            if args.version:
                backend = EspBackend()
                from esptool.loader import StubFlasher
                from esptool.targets.esp32s3 import ESP32S3ROM
                stub = StubFlasher(ESP32S3ROM)
                if not stub.text or not stub.data:
                    raise SafetyError("Missing embedded ESP32-S3 stub.")
                emit("complete", message=f"MicMatrixFlasher 1; esptool 5.3.1; Python {sys.version.split()[0]}; arm64")
                return 0
            path = absolute_path(args.request, "--request")
            request = json_file(path)
            # Validate assets before loading any serial backend.
            validate_request(request)
            transaction(request, EspBackend(), WriteGate(), emit)
        return 0
    except (Exception, KeyboardInterrupt) as error:
        emit("error", message=str(error)[:1024] or type(error).__name__)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
