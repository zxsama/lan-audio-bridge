#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only receiver monitor: prints the desktop receiver state whenever it changes.

Requires DIAGNOSTICS_STATUS=true, which makes the app copy status.json to
DATA_DIR/diagnostics/status.json once per second.

Usage: python3 receiver_status.py --status /path/to/data/diagnostics/status.json --seconds 60
"""
import argparse
import datetime
import json
import time

parser = argparse.ArgumentParser()
parser.add_argument("--status", required=True)
parser.add_argument("--seconds", type=float, default=60)
args = parser.parse_args()
keys = ("state", "sessions", "underflow", "server_overflow", "overflow", "missing", "awake")
print("time state sessions underflow server_overflow ring_overflow missing awake | queued_ms total_ms sink_ms ppm rate")
end, last = time.monotonic() + args.seconds, None
while time.monotonic() < end:
    try:
        status = json.load(open(args.status))
        r = status["desktop"]["receiver"]
    except (OSError, ValueError, KeyError):
        time.sleep(0.5)
        continue
    key = tuple(r.get(k) for k in keys)
    if key != last:
        print(datetime.datetime.now().strftime("%H:%M:%S"), *key, "|", round(r.get("queued_ms", 0), 1),
              round(r.get("latency_us", 0) / 1000, 1), round(r.get("sink_usec", 0) / 1000, 1), r.get("ppm"), r.get("rate"), flush=True)
        last = key
    time.sleep(0.5)
