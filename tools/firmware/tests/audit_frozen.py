# SPDX-License-Identifier: GPL-2.0-or-later
"""Check all embedded Mach-O load commands, not only the outer bootloader."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid

from PyInstaller.archive.readers import CArchiveReader

ROOT = Path(__file__).resolve().parents[3]
SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")
LOAD_COMMANDS = {
    "LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_LOAD_UPWARD_DYLIB",
}


def load_commands(binary):
    output = subprocess.check_output(["otool", "-l", str(binary)], text=True)
    dependencies, rpaths = [], []
    for block in re.split(r"\nLoad command \d+\n", output):
        command = re.search(r"^\s*cmd (LC_\w+)$", block, re.M)
        if command is None:
            continue
        if command[1] in LOAD_COMMANDS:
            dependencies.append(re.search(r"^\s*name (.+) \(offset \d+\)$", block, re.M)[1])
        elif command[1] == "LC_RPATH":
            rpaths.append(re.search(r"^\s*path (.+) \(offset \d+\)$", block, re.M)[1])
    return dependencies, rpaths


def expand(path, binary, work):
    if path == "@loader_path" or path.startswith("@loader_path/"):
        return binary.parent / path.removeprefix("@loader_path").lstrip("/")
    if path == "@executable_path" or path.startswith("@executable_path/"):
        return work / path.removeprefix("@executable_path").lstrip("/")
    if path.startswith(SYSTEM_PREFIXES):
        return Path(path)
    raise AssertionError(f"Unresolved/developer runtime path: {binary}: {path}")


def main(executable):
    work = ROOT / "build/firmware-dependency-audit" / uuid.uuid4().hex
    work.mkdir(parents=True)
    try:
        reader = CArchiveReader(str(executable))
        binaries = [executable]
        for name, entry in reader.toc.items():
            if entry[-1] not in ("b", "x", "n"):
                continue
            path = work / name
            assert not Path(name).is_absolute() and ".." not in Path(name).parts
            path.parent.mkdir(parents=True, exist_ok=True)
            data = reader.extract(name)
            if entry[-1] == "n":
                target = data.rstrip(b"\0").decode()
                assert not Path(target).is_absolute()
                assert (path.parent / target).resolve().is_relative_to(work)
                path.symlink_to(target)
            else:
                path.write_bytes(data)
                if entry[-1] == "b":
                    binaries.append(path)
        parsed = {binary: load_commands(binary) for binary in binaries}
        python = work / "Python.framework/Versions/3.13/Python"
        parents = [*parsed[executable][1], *parsed[python][1]]
        for binary, (dependencies, rpaths) in parsed.items():
            assert subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip() == "arm64"
            for path in rpaths:
                expand(path, binary, work)
            for dependency in dependencies:
                if dependency.startswith(SYSTEM_PREFIXES):
                    continue
                if dependency.startswith("@rpath/"):
                    candidates = [expand(path, binary, work) / dependency.removeprefix("@rpath/")
                                  for path in [*rpaths, *parents]]
                else:
                    candidates = [expand(dependency, binary, work)]
                assert any(path.resolve().is_relative_to(work) and path.is_file()
                           for path in candidates), f"Unresolved embedded dependency: {binary}: {dependency}"
        print(f"Frozen dependency closure: {len(binaries)} arm64 Mach-O files; "
              "all non-system dependencies resolve inside the bundle; no developer load paths.")
    finally:
        shutil.rmtree(work)


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve())
