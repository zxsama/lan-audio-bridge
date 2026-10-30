#!/usr/bin/env python3
"""Keep this WSL session alive while the local demo is running; no daemon setup."""

import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import time


PROJECT = "lan-audio-bridge-local"
CONTAINER = PROJECT + "-audio-1"
LOCK = Path("/run/" + PROJECT + ".keepalive.lock")


def main():
    with LOCK.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if "--status" in sys.argv:
                lock.seek(0)
                print("Keepalive active: " + lock.read().strip())
            return 0
        if "--status" in sys.argv:
            print("Keepalive inactive")
            return 1

        lock.seek(0)
        lock.truncate()
        lock.write(str(os.getpid()))
        lock.flush()
        restarting_since = None
        while True:
            try:
                result = subprocess.run(
                    ["docker", "inspect", CONTAINER],
                    capture_output=True, text=True, timeout=10, check=False,
                )
                if result.returncode:
                    return 0
                info = json.loads(result.stdout)[0]
                if info["Config"]["Labels"].get("com.docker.compose.project") != PROJECT:
                    return 1
                state = info["State"]
                if not state["Running"]:
                    return 0
                if state["Restarting"]:
                    restarting_since = restarting_since or time.monotonic()
                    if time.monotonic() - restarting_since > 60:
                        return 1
                else:
                    restarting_since = None
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
                return 1
            time.sleep(2)


if __name__ == "__main__":
    sys.exit(main())
