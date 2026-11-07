#!/usr/bin/env python3
"""Poll the native receiver STATUS and print a compact time series (diagnostics only)."""
import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, "/app")
from native_control import request  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--seconds", type=float, default=30)
parser.add_argument("--interval", type=float, default=0.05)
parser.add_argument("--control", default="/run/lan-audio/desktop-control.sock")
args = parser.parse_args()
keys = ("state", "queued_ms", "latency_us", "ppm", "underflow", "overflow", "missing", "late",
        "discontinuities", "sessions", "tlength", "sink_usec", "effective_target_us")
start = time.monotonic()
samples = []
while time.monotonic() - start < args.seconds:
    try:
        s = request(Path(args.control), "STATUS", 1.0)
        samples.append([round(time.monotonic() - start, 3)] + [s.get(k) for k in keys])
    except Exception as exc:  # noqa: BLE001
        samples.append([round(time.monotonic() - start, 3), "error", str(exc)])
    time.sleep(args.interval)
print(json.dumps({"keys": ["t", *keys], "samples": samples}))
