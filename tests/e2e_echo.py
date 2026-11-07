#!/usr/bin/env python3
"""Echo marker onsets seen on the Pulse output monitor back to a Windows probe.

Runs inside the receiver container. The Windows side sends a token, then plays
markers through the real sender. Each onset (first |sample| above threshold
after a quiet gap) is reported immediately over the same UDP flow, so the
Windows QPC clock measures submit -> receiver output -> echo. The result
includes the 2 ms recording request and the return hop; it excludes the real
DAC. Only counts and timings are reported; PCM is never stored.
"""
import argparse
import array
import json
import os
import select
import socket
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--port", type=int, default=6990)
parser.add_argument("--token", required=True)
parser.add_argument("--seconds", type=float, default=60)
parser.add_argument("--threshold", type=int, default=1200)
parser.add_argument("--quiet-ms", type=float, default=150)
parser.add_argument("--server", default="unix:/run/lan-audio/pulse.sock")
args = parser.parse_args()

udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.bind(("0.0.0.0", args.port))
udp.settimeout(30)
while True:
    message, peer = udp.recvfrom(256)
    if message.decode(errors="replace") == args.token:
        break
recorder = subprocess.Popen(
    ["parec", f"--server={args.server}", "--device=output.monitor", "--raw", "--format=s16le",
     "--rate=48000", "--channels=2", "--latency-msec=2", "--process-time-msec=1"],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
os.set_blocking(recorder.stdout.fileno(), False)
time.sleep(0.3)
udp.sendto(b"ready", peer)
events = 0
peak = 0
quiet_frames = int(args.quiet_ms * 48)
silent_run = quiet_frames
pending = b""
end = time.monotonic() + args.seconds
try:
    while time.monotonic() < end:
        if not select.select([recorder.stdout], [], [], 0.05)[0]:
            continue
        data = os.read(recorder.stdout.fileno(), 4096)
        if not data:
            raise RuntimeError("recorder closed")
        data = pending + data
        usable = len(data) // 4 * 4
        pending = data[usable:]
        values = array.array("h", data[:usable])
        if values:
            peak = max(peak, max(values), -min(values))
        for i in range(0, len(values), 2):
            if abs(values[i]) > args.threshold:
                if silent_run >= quiet_frames:
                    udp.sendto(json.dumps({"event": events}).encode(), peer)
                    events += 1
                silent_run = 0
            else:
                silent_run += 1
finally:
    recorder.terminate()
    recorder.wait(timeout=5)
status = {}
try:
    with open("/run/lan-audio/status.json") as f:
        status = json.load(f)
except OSError:
    pass
udp.sendto(json.dumps({"done": events, "peak": peak, "receiver": status}).encode()[:60000], peer)
print(json.dumps({"events": events, "peak": peak}))
