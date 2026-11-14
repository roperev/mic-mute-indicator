#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Package only allowlisted corresponding source and upstream license notices."""
import hashlib
import importlib.metadata
import json
from pathlib import Path
import re
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "Resources/Firmware"
CACHE = ROOT / "build/firmware-source-downloads"
LICENSES = RESOURCES / "licenses"
ARDUINO = Path.home() / "Library/Arduino15"
CORE = ARDUINO / "packages/esp32/hardware/esp32/3.3.12"
INTERNAL = ARDUINO / "internal"


def fetch(url, name, sha256=None):
    path = CACHE / name
    if not path.exists():
        with urllib.request.urlopen(url, timeout=120) as response:
            path.write_bytes(response.read())
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if sha256 is not None and actual != sha256:
        raise RuntimeError(f"Source checksum mismatch: {name}")
    return path, {"file": name, "url": url, "sha256": actual}


def normalized(info):
    info.uid = info.gid = info.mtime = 0
    info.uname = info.gname = ""
    if info.isfile():
        info.mode = 0o644
    if info.issym() or info.islnk():
        return None
    return info


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    LICENSES.mkdir(parents=True, exist_ok=True)
    records, archives = [], []
    requirements = ROOT / "tools/firmware/requirements.txt"
    for requirement in requirements.read_text().splitlines():
        if not requirement or requirement.startswith("#"):
            continue
        name, version = requirement.split("==")
        installed = importlib.metadata.distribution(name)
        if installed.version != version:
            raise RuntimeError(f"Installed source version differs from pin: {name}")
        with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{version}/json", timeout=60) as response:
            metadata = json.load(response)
        source = next(url for url in metadata["urls"] if url["packagetype"] == "sdist")
        archive, record = fetch(source["url"], source["filename"], source["digests"]["sha256"])
        record.update(package=name, version=version)
        records.append(record)
        archives.append(archive)
        notice_dir = LICENSES / name
        notice_dir.mkdir(exist_ok=True)
        for file in installed.files or []:
            if (re.search(r"(?:license|copying|copyright|notice)", str(file), re.I)
                    and Path(file).suffix not in (".py", ".pyc")
                    and "__pycache__" not in Path(file).parts):
                path = Path(installed.locate_file(file))
                if path.is_file():
                    # Preserve every upstream notice without importing installed executable code.
                    (notice_dir / str(file).replace("/", "__")).write_bytes(path.read_bytes())
    for repository, version in (("esp-flasher-stub", "v1.0.0"), ("esptool-legacy-flasher-stub", "v1.11.1")):
        archive, record = fetch(f"https://codeload.github.com/espressif/{repository}/tar.gz/refs/tags/{version}",
                                f"{repository}-{version}.tar.gz")
        record.update(package=repository, version=version)
        records.append(record)
        archives.append(archive)
    esptool_dir = Path(importlib.metadata.distribution("esptool").locate_file("esptool"))
    for version in ("1", "2"):
        stub_dir = esptool_dir / "targets/stub_flasher" / version
        for path in stub_dir.iterdir():
            if path.name.startswith("LICENSE") or path.name == "README.md":
                (LICENSES / f"esptool-stub-{version}-{path.name}.txt").write_bytes(path.read_bytes())
    # CPython and native runtime libraries are included, not merely links to sources.
    for package in ("python@3.13", "openssl@3", "xz", "mpdecimal"):
        if package == "python@3.13":
            receipt = next(parent / ".brew/python@3.13.rb"
                           for parent in Path(sys.base_prefix).resolve().parents
                           if (parent / ".brew/python@3.13.rb").exists())
        else:
            receipt = Path(f"/opt/homebrew/opt/{package}").resolve() / f".brew/{package}.rb"
        formula_source = receipt.read_bytes()
        text = formula_source.decode()
        url = re.search(r'^\s*url "([^"]+)"', text, re.M)[1]
        checksum = re.search(r'^\s*sha256 "([a-f0-9]+)"', text, re.M)[1]
        name = url.rsplit("/", 1)[-1]
        archive, record = fetch(url, name, checksum)
        record.update(package=package, version=receipt.parent.parent.name)
        records.append(record)
        archives.append(archive)
        (CACHE / f"{package.replace('@', '-')}-formula.rb").write_bytes(formula_source)
        with tarfile.open(archive) as source:
            for member in source:
                basename = Path(member.name).name
                if (member.isfile() and member.name.count("/") == 1
                        and re.fullmatch(r"(?:LICENSE|LICENCE|COPYING|NOTICE|COPYRIGHT)(?:[._-].*)?", basename, re.I)):
                    (LICENSES / f"{package}-{basename}.txt").write_bytes(source.extractfile(member).read())
        if package == "python@3.13":
            if record["version"] != sys.version.split()[0]:
                raise RuntimeError("CPython source version does not match the frozen runtime.")
            with tarfile.open(archive) as source:
                member = next(m for m in source if m.name.endswith("/LICENSE") and m.name.count("/") == 1)
                (LICENSES / "CPython-LICENSE.txt").write_bytes(source.extractfile(member).read())
    # License texts not shipped at the root of Arduino's Board Manager source package.
    for name, url in {
        "Arduino-LGPL-2.1.txt": "https://raw.githubusercontent.com/espressif/arduino-esp32/3.3.12/LICENSE.md",
        "GPL-3.0.txt": "https://raw.githubusercontent.com/spdx/license-list-data/main/text/GPL-3.0-only.txt",
        "ESP-IDF-Apache-2.0.txt": "https://raw.githubusercontent.com/espressif/esp-idf/v5.5.5/LICENSE",
    }.items():
        # Arduino's LGPL text is named differently in some package releases.
        try:
            path, record = fetch(url, name)
        except urllib.error.HTTPError:
            if name == "GPL-3.0.txt":
                path, record = fetch("https://www.gnu.org/licenses/gpl-3.0.txt", name)
            else:
                raise
        (LICENSES / name).write_bytes(path.read_bytes())
        records.append(record)
    sensor = next(INTERNAL.glob("SensorLib_0.5.1_*/SensorLib"))
    neopixel = next(INTERNAL.glob("Adafruit_NeoPixel_1.15.5_*/Adafruit NeoPixel"))
    (LICENSES / "SensorLib-MIT.txt").write_bytes((sensor / "LICENSE").read_bytes())
    (LICENSES / "SensorLib-THIRD-PARTY-NOTICES.txt").write_bytes((sensor / "THIRD_PARTY_NOTICES.md").read_bytes())
    (LICENSES / "NeoPixel-LGPL-3.0.txt").write_bytes((neopixel / "COPYING").read_bytes())
    (RESOURCES / "SOURCE-NOTICES.txt").write_text(
        "MicMatrixFlasher helper: GPL-2.0-or-later; esptool 5.3.1: GPL-2.0-or-later.\n"
        "The Swift application communicates with the helper as a separate process.\n"
        "Distribute CorrespondingSource.tar.gz, NativeRuntimeSource.tar.gz and notices with binaries.\n"
        "The archive includes the exact helper source/build scripts, dependency source\n"
        "distributions (including PyInstaller and bootloader source), CPython, OpenSSL,\n"
        "xz, mpdecimal, Homebrew runtime formulae, sketch source and pinned firmware library sources.\n"
        "PyInstaller: GPL-2.0-or-later with its bootloader distribution exception.\n"
        "CPython: PSF-2.0 and notices in CPython-LICENSE.txt.\n"
        "See licenses/ for each dependency's preserved copyright/license texts.\n"
        "Arduino ESP32 core 3.3.12: LGPL-2.1-or-later; corresponding core source included.\n"
        "Adafruit NeoPixel 1.15.5: LGPL-3.0-or-later; full library source included.\n"
        "SensorLib 0.5.1: MIT; included third-party notices apply to respective files.\n"
        "ESP-IDF 5.5.5: Apache-2.0 with component-specific notices in upstream source:\n"
        "https://github.com/espressif/esp-idf/tree/v5.5.5\n"
        "Toolchain/runtime newlib components carry their permissive upstream notices:\n"
        "https://github.com/espressif/newlib-esp32\n"
        "Source rebuilding is described in tools/firmware/NOTES.txt in the archive.\n"
        "No original-device image, personal backup, credential or user data is included.\n"
        "Source digests and URLs: licenses/source-index.json.\n"
    )
    (LICENSES / "source-index.json").write_text(json.dumps(records, indent=2) + "\n")
    native_archives = [path for path in archives if path.name.startswith(("openssl-", "xz-", "mpdecimal-"))]
    with tarfile.open(RESOURCES / "NativeRuntimeSource.tar.gz", "w:gz", compresslevel=9) as tar:
        for path in native_archives:
            tar.add(path, arcname=f"upstream/{path.name}", filter=normalized)
        for path in sorted(CACHE.glob("*-formula.rb")):
            tar.add(path, arcname=f"runtime-formulae/{path.name}", filter=normalized)
    archive_path = RESOURCES / "CorrespondingSource.tar.gz"
    with tarfile.open(archive_path, "w:gz", compresslevel=9) as tar:
        for path in sorted(archives):
            if path not in native_archives:
                tar.add(path, arcname=f"upstream/{path.name}", filter=normalized)
        for path in sorted(CACHE.glob("*-formula.rb")):
            tar.add(path, arcname=f"runtime-formulae/{path.name}", filter=normalized)
        for path in sorted((ROOT / "tools/firmware").rglob("*")):
            if path.is_file() and "__pycache__" not in path.parts:
                tar.add(path, arcname=str(path.relative_to(ROOT)), filter=normalized)
        for path in sorted((ROOT / "firmware/MicMatrix").iterdir()):
            if path.is_file() and path.suffix in (".h", ".ino", ".yaml"):
                tar.add(path, arcname=str(path.relative_to(ROOT)), filter=normalized)
        for item in ["cores", "variants/esp32s3", "libraries/Wire", "tools/partitions",
                     "boards.txt", "platform.txt", "package.json", "idf_component.yml"]:
            tar.add(CORE / item, arcname=f"firmware-dependencies/arduino-esp32-3.3.12/{item}", filter=normalized)
        for item in ["src", "library.properties", "LICENSE", "THIRD_PARTY_NOTICES.md"]:
            tar.add(sensor / item, arcname=f"firmware-dependencies/SensorLib-0.5.1/{item}", filter=normalized)
        for path in sorted(neopixel.iterdir()):
            if path.is_file():
                tar.add(path, arcname=f"firmware-dependencies/Adafruit_NeoPixel-1.15.5/{path.name}", filter=normalized)
        tar.add(LICENSES, arcname="licenses", filter=normalized)
        tar.add(RESOURCES / "SOURCE-NOTICES.txt", arcname="SOURCE-NOTICES.txt", filter=normalized)
    print(f"Packaged corresponding source: {archive_path} ({archive_path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
