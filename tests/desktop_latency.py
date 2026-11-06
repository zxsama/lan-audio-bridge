#!/usr/bin/env python3
"""Measure UDP submission to monitor observation in the isolated desktop test.

This includes recording/client queues and is not hardware end-to-end latency.
Run inside compose.desktop-test.yaml after desktop_audio.py has completed.
"""
import argparse
import array
import json
import math
import os
import select
import socket
import statistics
import struct
import subprocess
import threading
import time

from integration import SERVER, Tone, eventually, status


def measure(mixed=False, count=10):
    phone = Tone("dlna") if mixed else None
    recorder = subprocess.Popen(
        ["parec", "--server=" + SERVER, "--device=output.monitor", "--raw",
         "--format=s16le", "--rate=48000", "--channels=2", "--latency-msec=10",
         "--process-time-msec=5"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    done = threading.Event()
    received = []

    def record():
        last_detection = -10.0
        while not done.is_set():
            if not select.select([recorder.stdout], [], [], 0.05)[0]:
                continue
            raw = os.read(recorder.stdout.fileno(), 1920)
            if not raw:
                return
            observed = time.monotonic()
            values = array.array("h", raw[:len(raw) // 2 * 2])
            if values and max(values) > 12000 and observed - last_detection > 0.5:
                received.append(observed)
                last_detection = observed

    reader = threading.Thread(target=record, daemon=True)
    reader.start()
    submitted = []
    header = struct.Struct("<4sBBBB16sI")
    baseline = b"".join(struct.pack("<hh", *([int(2500 * math.sin(2 * math.pi * 1000 * i / 48000))] * 2))
                        for i in range(240))
    marker = struct.pack("<hh", 32000, 32000) * 240
    start = time.monotonic()
    # A marker at t=0 tests cold start, then steady-state markers every second.
    positions = [0] + [600 + i * 200 for i in range(count - 1)]
    stops = positions[-1] + 200
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
            for block in range(stops):
                delay = start + block * 0.005 - time.monotonic()
                if delay > 0:
                    time.sleep(delay)
                is_marker = block in positions or block - 1 in positions
                packet = header.pack(b"VBAN", 3, 239, 1, 1, b"Windows", block)
                if block in positions:
                    submitted.append(time.monotonic())
                sender.sendto(packet + (marker if is_marker else baseline), ("127.0.0.1", 6980))
        eventually(lambda: len(received) >= count, "marker observation", timeout=5)
    finally:
        done.set()
        recorder.terminate()
        recorder.wait(timeout=3)
        reader.join(timeout=1)
        recorder.stdout.close()
        if phone:
            phone.close()
        eventually(lambda: status()["state"] == "idle", "idle after latency probe", timeout=8)
    assert len(submitted) == len(received) == count, (len(submitted), len(received), count)
    delays = [(b - a) * 1000 for a, b in zip(submitted, received)]
    assert min(delays) >= 0, delays
    steady = sorted(delays[1:])
    return {"mode": "mixed_with_dlna_bus" if mixed else "desktop_only",
            "cold_start_ms": round(delays[0], 3), "steady_samples": len(steady),
            "steady_median_ms": round(statistics.median(steady), 3),
            "steady_p95_ms": round(steady[math.ceil(len(steady) * 0.95) - 1], 3),
            "steady_min_ms": round(steady[0], 3), "steady_max_ms": round(steady[-1], 3),
            "observations_ms": [round(v, 3) for v in delays]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--markers", type=int, default=10)
    args = parser.parse_args()
    if not 3 <= args.markers <= 120:
        parser.error("markers must be in 3..120")
    assert status().get("desktop", {}).get("enabled"), "Use the isolated desktop test container"
    assert status()["state"] == "idle", "Another test or source is active"
    results = [measure(False, args.markers), measure(True, args.markers)]
    print(json.dumps({"ok": True, "measurement": "same-container UDP submission to output.monitor observation",
                      "includes": "receiver, PCM client, loopback, recording buffer and process scheduling",
                      "excludes": "Windows virtual driver, physical LAN, NAS hardware and speaker",
                      "results": results}, ensure_ascii=False))
