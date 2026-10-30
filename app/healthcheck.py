#!/usr/bin/env python3
"""Read-only container liveness check; never includes account or media details."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from runtime import avahi_available


def healthy(status: dict, now: float, alive=None) -> bool:
    alive = alive or (lambda pid: os.kill(pid, 0))
    try:
        age = now - status["heartbeat_unix"]
        if not 0 <= age <= 10 or status["state"] not in ("idle", "playing"):
            return False
        if type(status["pid"]) is not int or status["pid"] <= 0:
            return False
        alive(status["pid"])
        children = status["children"]
        mode = status.get("avahi_mode", "internal")
        if mode not in ("internal", "external"):
            return False
        required = {"pulse", *status["enabled"]}
        if mode == "internal":
            required.update(("dbus", "avahi"))
        if "airplay" in status["enabled"]:
            required.add("nqptp")
        for name in required:
            child = children[name]
            if child["state"] != "running" or type(child["pid"]) is not int or child["pid"] <= 0:
                return False
            alive(child["pid"])
        if status["state"] == "idle":
            return status["owner"] is None and status["route_module"] is None
        return status["owner"] in status["enabled"] and type(status["route_module"]) is int
    except (KeyError, TypeError, OSError, ValueError):
        return False


def main() -> int:
    try:
        status = json.loads(Path("/run/lan-audio/status.json").read_text(encoding="utf-8"))
        if not healthy(status, time.time()):
            return 1
        if status.get("avahi_mode") == "external" and not avahi_available():
            return 1
        # A recently updated status alone cannot prove the Pulse server responds.
        result = subprocess.run(["pactl", "--server=unix:/run/lan-audio/pulse.sock", "info"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
        return 0 if result.returncode == 0 else 1
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 1


if __name__ == "__main__":
    sys.exit(main())
