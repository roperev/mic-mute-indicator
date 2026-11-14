# SPDX-License-Identifier: GPL-2.0-or-later
"""Exercise the actual frozen helper, never with a usable board request."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

root = Path(__file__).resolve().parents[3]
executable = Path(sys.argv[1]).resolve()
work = root / "build/firmware-frozen-tests" / uuid.uuid4().hex
work.mkdir(parents=True)
try:
    environment = dict(os.environ, PATH="/usr/bin:/bin", PYTHONHOME="/nonexistent",
                       PYTHONPATH="/nonexistent", TMPDIR=str(work))
    result = subprocess.run([str(executable), "--version"], env=environment, capture_output=True, timeout=30)
    assert result.returncode == 0, result.stderr.decode()
    assert json.loads(result.stdout)["type"] == "complete", result.stdout
    for request in [
        {"operation": "erase", "port": "/dev/cu.NEVER-OPEN-THIS", "backupDirectory": str(work)},
        {"operation": "install", "port": "/dev/cu.NEVER-OPEN-THIS", "backupDirectory": str(work)},
        {"operation": "inspect", "port": "rfc2217://NEVER-CONNECT", "backupDirectory": str(work)},
    ]:
        path = work / "request.json"
        path.write_text(json.dumps(request))
        result = subprocess.run([str(executable), "--request", str(path)], env=environment,
                                capture_output=True, timeout=30)
        assert result.returncode == 1, result
        events = [json.loads(line) for line in result.stdout.splitlines()]
        assert len(events) == 1 and events[0]["type"] == "error", events
    print("Frozen arm64 helper: embedded esptool/stub and 3 fail-closed requests passed; no board access.")
finally:
    shutil.rmtree(work)
