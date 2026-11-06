#!/usr/bin/env python3
"""Real VBAN/Pulse mixing checks, inside a dedicated AUDIO_MODE=null container.

Mount the repository at /workspace and run:
  python3 /workspace/tests/desktop_audio.py --inside
Required configuration: ENABLE_DESKTOP=true, VBAN_SOURCE_IP=127.0.0.1,
VBAN_STREAM_NAME=Windows, VBAN_PORT=6980, DESKTOP_BUFFER_MS=50,
DESKTOP_VOLUME=100, DESKTOP_IDLE_MS=500; all four phone sources enabled.
No external device, driver, network service, or third-party Python dependency.
"""
import argparse
import array
import math
import os
from pathlib import Path
import select
import shlex
import socket
import struct
import subprocess
import sys
import threading
import time

from integration import (FREQUENCIES, RATE, SERVER, Tone, amplitude, capture,
                         command, eventually, pulse, status)

DESKTOP_HZ = 1300


class VBANTone:
    """Paced real UDP packets; fault mode drops, duplicates and reorders packets."""

    def __init__(self, frequency=DESKTOP_HZ, level=10000, stream="Windows", source="127.0.0.1"):
        self.level = level
        self.faults = False
        self.sent = 0
        self.first_sent = None
        self.error = None
        self.done = threading.Event()
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind((source, 0))
        self.frequency = frequency
        self.stream = stream.encode("ascii").ljust(16, b"\0")
        self.thread = threading.Thread(target=self.feed, daemon=True)
        self.thread.start()

    def feed(self):
        # VBAN rate index 3 = 48 kHz, 128 frames, stereo, signed 16-bit PCM.
        frames = 128
        sequence = 0
        held = None
        deadline = time.monotonic()
        try:
            while not self.done.is_set():
                level = self.level
                samples = [int(level * math.sin(2 * math.pi * self.frequency *
                           (sequence * frames + i) / RATE)) for i in range(frames)]
                packet = (struct.pack("<4sBBBB16sI", b"VBAN", 3, frames - 1, 1, 1,
                                      self.stream, sequence & 0xffffffff) +
                          b"".join(struct.pack("<hh", x, x) for x in samples))
                if self.first_sent is None:
                    self.first_sent = time.monotonic()
                if not self.faults or sequence % 29 != 0:
                    if self.faults and sequence % 37 == 0:
                        held = packet
                    else:
                        self.sock.sendto(packet, ("127.0.0.1", 6980))
                        if held is not None:
                            self.sock.sendto(held, ("127.0.0.1", 6980))
                            held = None
                        if self.faults and sequence % 41 == 0:
                            self.sock.sendto(packet, ("127.0.0.1", 6980))
                sequence += 1
                self.sent = sequence
                deadline += frames / RATE
                self.done.wait(max(0, deadline - time.monotonic()))
        except OSError as exc:
            self.error = exc

    def close(self):
        self.done.set()
        self.thread.join(timeout=3)
        self.sock.close()
        assert not self.thread.is_alive(), "VBAN sender failed to stop"
        assert self.error is None, self.error


class Monitor:
    """Continuous recording avoids hiding transition gaps behind recorder startup."""

    def __init__(self):
        self.process = subprocess.Popen(
            ["parec", "--server=" + SERVER, "--device=output.monitor", "--raw",
             "--format=s16le", "--rate=48000", "--channels=2", "--latency-msec=20"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.raw = bytearray()
        self.observations = []
        self.done = threading.Event()
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        while not self.done.is_set():
            if select.select([self.process.stdout], [], [], 0.05)[0]:
                chunk = os.read(self.process.stdout.fileno(), 8192)
                if not chunk:
                    return
                self.observations.append((time.monotonic(), len(self.raw), chunk))
                self.raw.extend(chunk)

    def samples(self, start=0):
        raw = bytes(self.raw[start:])
        values = array.array("h", raw[:len(raw) // 4 * 4])
        if sys.byteorder != "little":
            values.byteswap()
        return list(values[::2])

    def close(self):
        self.done.set()
        self.thread.join(timeout=2)
        self.process.terminate()
        self.process.wait(timeout=3)
        self.process.stdout.close()


def routes(owner, desktop):
    current = status()
    assert current["owner"] == owner, current
    assert current["desktop"]["enabled"], current
    assert current["desktop"]["active"] == desktop, current
    modules = {}
    for row in command("pactl", "--server=" + SERVER, "list", "short", "modules").splitlines():
        cols = row.split("\t")
        if cols[1] == "module-loopback":
            args = dict(arg.split("=", 1) for arg in shlex.split(cols[2]) if "=" in arg)
            modules[int(cols[0])] = args
    expected = {}
    if owner:
        expected[int(current["route_module"])] = owner + "_bus.monitor"
    else:
        assert current["route_module"] is None, current
    if desktop:
        expected[int(current["desktop"]["route_module"])] = "desktop_bus.monitor"
    else:
        assert current["desktop"]["route_module"] is None, current
    assert set(modules) == set(expected), (modules, expected)
    for identifier, source in expected.items():
        assert modules[identifier]["source"] == source, modules
        # The module's creation arguments retain sink=discard after its actual
        # sink-input is moved to output. Check the live destination below.
    output = next(s for s in pulse("sinks") if s["name"] == "output")
    active = owner is not None or desktop
    assert output["state"] == ("RUNNING" if active else "SUSPENDED"), output["state"]
    assert output["mute"] == (not active), output["mute"]
    inputs = [s for s in pulse("sink-inputs") if int(s["sink"]) == int(output["index"])]
    assert {int(s["owner_module"]) for s in inputs} == set(expected), inputs
    assert len(inputs) == len(expected), inputs
    return True


def audio(expected, absent=()):
    samples = capture()
    measured = {f: amplitude(samples, f) for f in set(expected) | set(absent)}
    for frequency, target in expected.items():
        assert target * 0.72 < measured[frequency] < target * 1.28, (expected, measured)
    for frequency in absent:
        assert measured[frequency] < 180, (absent, measured)
    assert max(map(abs, samples)) < 32767, "Clipped PCM"
    print("  PCM amplitudes:", {f: round(v, 1) for f, v in measured.items()}, flush=True)
    return measured


def phone_pids():
    return {s: c.get("pid") for s, c in status().get("children", {}).items()
            if s in FREQUENCIES}


def receiver_pid():
    import json
    return json.loads(Path("/run/lan-audio/desktop.json").read_text())["receiver_pid"]


class FullScalePhone(Tone):
    """Nearly full-scale signal exercises mix peak headroom."""

    def __init__(self):
        self.done = threading.Event()
        self.process = subprocess.Popen(
            ["pacat", "--server=" + SERVER, "--playback", "--raw", "--format=s16le",
             "--rate=48000", "--channels=2", "--latency-msec=60", "--device=airplay_bus"],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        block = b"".join(struct.pack("<hh", *([int(32760 * math.sin(
            2 * math.pi * 1370 * i / RATE))] * 2)) for i in range(RATE // 10))

        def feed():
            try:
                while not self.done.is_set():
                    self.process.stdin.write(block)
                    self.process.stdin.flush()
            except (BrokenPipeError, OSError):
                pass

        self.thread = threading.Thread(target=feed, daemon=True)
        self.thread.start()


def continuity(samples):
    # Every 50 ms window must contain desktop energy, including phone handoffs.
    size = RATE // 20
    windows = [samples[i:i + size] for i in range(0, len(samples) - size + 1, size)]
    assert windows, "No transition recording"
    rms = [math.sqrt(sum(x * x for x in window) / len(window)) for window in windows]
    assert min(rms) > 400, f"Full output gap: minimum 50 ms RMS={min(rms):.1f}"
    print(f"  Continuous desktop: {len(windows)} windows, min RMS={min(rms):.1f}", flush=True)


def test_all():
    assert os.environ.get("AUDIO_MODE") == "null", "Dedicated null-output container required"
    assert os.environ.get("ENABLE_DESKTOP", "").lower() == "true"
    assert os.environ.get("VBAN_SOURCE_IP") == "127.0.0.1"
    eventually(lambda: routes(None, False), "initial idle")
    baseline_pids = phone_pids()
    baseline_receiver = receiver_pid()
    desktop = None
    phones = {}
    monitor = None
    try:
        print("Reject mismatched sender/stream and ignore all-zero VBAN", flush=True)
        for kwargs in ({"stream": "WrongStream"}, {"source": "127.0.0.2"}, {"level": 0}):
            sender = VBANTone(**kwargs)
            try:
                for _ in range(6):
                    time.sleep(0.2)
                    assert routes(None, False)
            finally:
                sender.close()
        assert phone_pids() == baseline_pids

        print("Desktop alone; full solo gain", flush=True)
        desktop = VBANTone()
        eventually(lambda: routes(None, True), "desktop wake")
        audio({DESKTOP_HZ: 10000}, FREQUENCIES.values())
        assert phone_pids() == baseline_pids, "Desktop restarted phone receivers"
        desktop_route = status()["desktop"]["route_module"]
        generation = status()["desktop"]["generation"]

        print("All twelve directed phone takeovers with continuous desktop PCM", flush=True)
        monitor = Monitor()
        time.sleep(0.7)
        start = len(monitor.raw) // 4 * 4
        sequence = ("airplay", "dlna", "airplay", "spotify", "dlna", "spotify", "miplay",
                    "dlna", "miplay", "spotify", "airplay", "miplay", "airplay")
        for source in sequence:
            if source in phones:
                phones.pop(source).close()
                time.sleep(0.4)
            phones[source] = Tone(source)
            eventually(lambda: routes(source, True), source + " mixed takeover")
            assert status()["desktop"]["route_module"] == desktop_route
            assert status()["desktop"]["generation"] == generation
            # Phone null buses retain their historical 2 s idle scheduling;
            # DLNA also retains its larger buffering policy. This is a steady
            # spectrum check, not a phone wake-latency assertion. Continuous
            # recording still covers this entire settling interval.
            buffer_key = "dlna_ms" if source == "dlna" else "output_ms"
            time.sleep(max(2.2, status()["buffers"][buffer_key] / 1000 + 0.3))
            audio({DESKTOP_HZ: 5000, FREQUENCIES[source]: 5000},
                  [f for s, f in FREQUENCIES.items() if s != source])
        continuity(monitor.samples(start))
        monitor.close()
        monitor = None

        print("Phone volume isolation and independent stopping", flush=True)
        before = audio({DESKTOP_HZ: 5000, FREQUENCIES["airplay"]: 5000})
        command("pactl", "--server=" + SERVER, "set-sink-volume", "airplay_bus", "50%")
        try:
            time.sleep(0.3)
            # Pulse percent is cubic: 50% is linear amplitude 0.125.
            after = audio({DESKTOP_HZ: 5000, FREQUENCIES["airplay"]: 625})
            assert abs(after[DESKTOP_HZ] / before[DESKTOP_HZ] - 1) < 0.08
        finally:
            command("pactl", "--server=" + SERVER, "set-sink-volume", "airplay_bus", "100%")
        for source in ("dlna", "spotify", "miplay", "airplay"):
            phones.pop(source).close()
        eventually(lambda: routes(None, True), "phone stopped; desktop remains")
        audio({DESKTOP_HZ: 10000}, FREQUENCIES.values())
        phones["miplay"] = Tone("miplay")
        eventually(lambda: routes("miplay", True), "both active")
        phone_route = status()["route_module"]
        desktop.level = 0
        eventually(lambda: routes("miplay", False), "zero VBAN idle while phone remains")
        assert status()["route_module"] == phone_route
        audio({FREQUENCIES["miplay"]: 10000}, [DESKTOP_HZ])
        desktop.level = 10000
        eventually(lambda: routes("miplay", True), "desktop wakes beside phone")
        audio({DESKTOP_HZ: 5000, FREQUENCIES["miplay"]: 5000})
        desktop.close()
        desktop = None
        eventually(lambda: routes("miplay", False), "desktop stopped; phone remains")
        assert status()["route_module"] == phone_route
        audio({FREQUENCIES["miplay"]: 10000}, [DESKTOP_HZ])
        phones.pop("miplay").close()
        eventually(lambda: routes(None, False), "both stopped and output suspended")

        print("Zero-packet idle, short notification wake, and software observation delay", flush=True)
        idle_pids = phone_pids()
        desktop = VBANTone(level=0)
        time.sleep(1)
        assert routes(None, False)
        monitor = Monitor()
        time.sleep(0.4)
        marker_time = time.monotonic()
        desktop.level = 10000
        time.sleep(0.01)
        desktop.level = 0
        time.sleep(1.2)
        samples = monitor.samples()
        assert max(map(abs, samples), default=0) > 2000, "Brief notification was lost"
        observed = None
        for timestamp, _, raw in monitor.observations:
            values = array.array("h", raw[:len(raw) // 2 * 2])
            if sys.byteorder != "little":
                values.byteswap()
            if timestamp >= marker_time and max(map(abs, values), default=0) > 2000:
                observed = timestamp - marker_time
                break
        assert observed is not None and observed < 1.0, observed
        print(f"  Software observation delay={observed * 1000:.1f} ms "
              "(includes parec/pipe/read buffering; not hardware or end-to-end latency)", flush=True)
        monitor.close()
        monitor = None
        eventually(lambda: routes(None, False), "zero packets return to suspend")
        desktop.close()
        desktop = None
        assert phone_pids() == idle_pids, "Desktop wake/idle restarted phone receivers"

        print("Full-scale two-source headroom", flush=True)
        desktop = VBANTone(level=32760)
        phones["airplay"] = FullScalePhone()
        eventually(lambda: routes("airplay", True), "full-scale mix")
        time.sleep(2.2)  # Existing phone bus cold scheduling, as above.
        # Distinct frequencies repeatedly approach constructive peak alignment.
        values = capture()
        levels = {f: amplitude(values, f) for f in (DESKTOP_HZ, 1370)}
        assert all(value > 13000 for value in levels.values()), levels
        peak = max(map(abs, values))
        assert 26000 < peak < 32767, ("full-scale headroom", peak)
        print(f"  Full-scale mix peak={peak}/32767", flush=True)
        phones.pop("airplay").close()
        desktop.close()
        desktop = None
        eventually(lambda: routes(None, False), "full-scale cleanup")
        idle_pids = phone_pids()

        print("Packet loss/reorder recovery and repeated desktop lifecycle leak checks", flush=True)
        for iteration in range(3):
            desktop = VBANTone()
            eventually(lambda: routes(None, True), "cycle wake")
            if iteration == 0:
                desktop.faults = True
                time.sleep(2)
                assert routes(None, True)
                desktop.faults = False
                time.sleep(0.6)
                audio({DESKTOP_HZ: 10000})
            desktop.close()
            desktop = None
            eventually(lambda: routes(None, False), "cycle idle")
            assert receiver_pid() == baseline_receiver, "Desktop receiver restarted"
            assert phone_pids() == idle_pids, "Desktop cycle restarted phone receiver"
        assert not pulse("sink-inputs"), "Idle playback stream leak"
        print("PASS: real VBAN PCM, mixing, 12 handoffs, gain isolation, idle/wake, recovery", flush=True)
    finally:
        if monitor:
            monitor.close()
        if desktop:
            desktop.close()
        for phone in phones.values():
            phone.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inside", action="store_true", required=True)
    parser.parse_args()
    test_all()
