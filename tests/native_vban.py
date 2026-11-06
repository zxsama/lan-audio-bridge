#!/usr/bin/env python3
"""Isolated native receiver/Pulse PCM exercise; run only in a disposable container.

Starts its own Pulse server and native child, never contacts a host audio server.
Usage: python3 tests/native_vban.py --binary /tmp/vban-pulse --output /tmp/result
"""
import argparse
import array
import json
import math
import os
from pathlib import Path
import select
import socket
import statistics
import struct
import subprocess
import tempfile
import threading
import time

RATE = 48000
FRAMES = 128
HEADER = struct.Struct("<4sBBBB16sI")


def wait_for(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(.02)
    raise AssertionError("condition timed out")


class Control:
    def __init__(self, path, directory):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.sock.bind(str(directory / "test-client.sock"))
        self.sock.settimeout(2)
        self.path = path

    def command(self, text="STATUS"):
        self.sock.sendto(text.encode(), str(self.path))
        value = json.loads(self.sock.recv(4096))
        assert value.get("ok"), value
        return value


class Monitor:
    def __init__(self, env, logfile, record_ms=2):
        self.process = subprocess.Popen(
            ["parec", "--device=output.monitor", "--raw", "--format=s16le", "--rate=48000",
             "--channels=2", f"--latency-msec={record_ms}", "--process-time-msec=1"],
            stdout=subprocess.PIPE, stderr=logfile, env=env)
        self.raw = bytearray()
        self.detected = []
        self.clock_points = []
        self.done = threading.Event()
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()

    def read(self):
        last = 0
        while not self.done.is_set():
            if not select.select([self.process.stdout], [], [], .05)[0]:
                continue
            data = os.read(self.process.stdout.fileno(), 768)
            if not data:
                return
            observed = time.monotonic()
            self.raw.extend(data)
            self.clock_points.append((observed, len(self.raw) // 4))
            values = array.array("h", data)
            if values and max(values) > 12000 and observed - last > .5:
                self.detected.append(observed)
                last = observed

    def samples(self, begin=0, end=None):
        data = self.raw[begin:end]
        return array.array("h", data[:len(data) // 4 * 4])[::2]

    def close(self):
        self.done.set()
        self.process.terminate()
        self.process.wait(timeout=3)
        self.thread.join(timeout=1)
        self.process.stdout.close()


def pcm(sequence, level=4000, frequency=1000):
    return b"".join(struct.pack("<hh", *([round(level * math.sin(
        2 * math.pi * frequency * (sequence * FRAMES + i) / RATE))] * 2)) for i in range(FRAMES))


def send(seconds, faults=False, marker_times=(), level=4000, drift_ppm=0, telemetry=None):
    observations = []
    held = None
    marker_blocks = {round(t * RATE / FRAMES) for t in marker_times}
    last_sent = None
    max_interval = max_lateness = 0
    packets = math.ceil(seconds * RATE / FRAMES * (1 + drift_ppm / 1e6))
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
        start = time.monotonic()
        for sequence in range(packets):
            deadline = start + sequence * FRAMES / RATE / (1 + drift_ppm / 1e6)
            delay = deadline - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            marker = sequence in marker_blocks or sequence - 1 in marker_blocks
            data = struct.pack("<hh", 32000, 32000) * FRAMES if marker else pcm(sequence, level)
            packet = HEADER.pack(b"VBAN", 3, FRAMES - 1, 1, 1, b"Windows", sequence) + data
            if sequence in marker_blocks:
                observations.append(time.monotonic())
            now = time.monotonic()
            max_lateness = max(max_lateness, now - deadline)
            if last_sent is not None:
                max_interval = max(max_interval, now - last_sent)
            last_sent = now
            if faults and sequence % 97 == 0:
                continue
            if faults and sequence % 89 == 0:
                held = packet
                continue
            sender.sendto(packet, ("127.0.0.1", 16980))
            if held:
                sender.sendto(held, ("127.0.0.1", 16980))
                held = None
            if faults and sequence % 83 == 0:
                sender.sendto(packet, ("127.0.0.1", 16980))
    if telemetry is not None:
        telemetry.update(max_send_interval_ms=max_interval * 1000, max_deadline_lateness_ms=max_lateness * 1000,
                         packets=packets, scheduled_wall_seconds=packets * FRAMES / RATE / (1 + drift_ppm / 1e6))
    return observations


def amplitude(values, frequency):
    if not values:
        return 0
    return 2 * abs(sum(value * complex(math.cos(2 * math.pi * frequency * i / RATE),
                                     math.sin(2 * math.pi * frequency * i / RATE))
                       for i, value in enumerate(values))) / len(values)


def longest_silence(values):
    longest = current = 0
    for value in values:
        current = current + 1 if abs(value) < 8 else 0
        longest = max(longest, current)
    return longest * 1000 / RATE


def window_amplitude(values, frequency):
    # Packet faults may shift phase. Analyze 100 ms windows rather than letting
    # opposite phases cancel over the whole multi-second exercise.
    windows = [amplitude(values[i:i + 4800], frequency) for i in range(0, len(values) - 4799, 4800)]
    return statistics.mean(windows) if windows else 0


def monitor_clock(points):
    if len(points) < 3:
        return None
    first, last = points[0][0] + 1, points[-1][0] - 1
    points = [(t - first, frames) for t, frames in points if first <= t <= last]
    if len(points) < 3:
        return None
    mt = statistics.mean(t for t, _ in points)
    mf = statistics.mean(frames for _, frames in points)
    rate = sum((t - mt) * (frames - mf) for t, frames in points) / sum((t - mt) ** 2 for t, _ in points)
    return {"frames_per_second": rate, "effective_ppm": (rate / RATE - 1) * 1e6,
            "fitted_seconds": points[-1][0] - points[0][0], "points": len(points)}


def latency(submitted, received):
    assert len(submitted) == len(received), (len(submitted), len(received))
    values = [(b - a) * 1000 for a, b in zip(submitted, received)]
    assert min(values) >= 0, values
    steady = sorted(values[1:])
    return {"cold_ms": values[0], "median_ms": statistics.median(steady),
            "p95_ms": steady[math.ceil(.95 * len(steady)) - 1],
            "max_ms": max(steady), "all_ms": values}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=int, default=30)
    parser.add_argument("--latency-ms", type=int, default=8)
    parser.add_argument("--jitter-ms", type=int, default=4)
    parser.add_argument("--drift-ppm", type=int, default=0)
    parser.add_argument("--require-stable", action="store_true")
    parser.add_argument("--record-ms", type=int, default=2)
    parser.add_argument("--resample-method", default="speex-float-5")
    parser.add_argument("--sink-floor-ms", type=int, default=0,
                        help="Test-only fixed null-sink scheduling latency, injected into this private Pulse process")
    parser.add_argument("--max-observed-latency-ms", type=float, default=20,
                        help="Explicit monitor observation gate; hardware-floor fixtures may need a larger bound")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="native-vban-") as temporary:
        directory = Path(temporary)
        env = dict(os.environ, PULSE_SERVER="unix:" + str(directory / "pulse.sock"))
        pulse_env = env.copy()
        if args.sink_floor_ms:
            assert 0 < args.sink_floor_ms <= 30, "Fixture floor must fit the receiver's 40 ms client queue cap"
            # Only this private Pulse process loads the shim. It changes the
            # actual null sink latency range used by negotiation and scheduling,
            # not the reported client timing or receiver configuration.
            shim = args.output / "null-sink-floor.c"
            shim.write_text('''#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
void pa_sink_set_latency_range(void *sink, uint64_t minimum, uint64_t maximum) {
    (void) minimum; (void) maximum;
    void (*real_set)(void *, uint64_t, uint64_t) = dlsym(RTLD_NEXT, "pa_sink_set_latency_range");
    if (!real_set) abort();
    uint64_t floor = strtoull(getenv("NATIVE_TEST_SINK_FLOOR_US"), NULL, 10);
    real_set(sink, floor, floor);
}
''')
            library = args.output / "null-sink-floor.so"
            subprocess.check_call(["gcc", "-shared", "-fPIC", "-O2", "-Wall", "-Wextra", "-Werror",
                                   str(shim), "-o", str(library), "-ldl"])
            pulse_env.update(LD_PRELOAD=str(library), NATIVE_TEST_SINK_FLOOR_US=str(args.sink_floor_ms * 1000))
        config = directory / "pulse.pa"
        config.write_text(f"load-module module-native-protocol-unix socket={directory}/pulse.sock auth-anonymous=true\n"
                          "load-module module-null-sink sink_name=output rate=48000 channels=2 format=s16le norewinds=true\n"
                          "load-module module-null-sink sink_name=discard rate=48000 channels=2 format=s16le norewinds=true\n"
                          "set-default-sink output\n")
        logs = [open(args.output / name, "w") for name in ("pulse.log", "receiver.jsonl", "receiver.stderr", "monitor.stderr")]
        pulse = subprocess.Popen(["pulseaudio", "-n", "--file=" + str(config), "--daemonize=no", "--exit-idle-time=-1",
                                  "--log-level=notice", "--use-pid-file=no", "--resample-method=" + args.resample_method],
                                  stdout=logs[0], stderr=logs[0], env=pulse_env)
        receiver = monitor = phone = None
        try:
            wait_for(lambda: (directory / "pulse.sock").exists())
            receiver = subprocess.Popen([str(args.binary), "--source-ip", "127.0.0.1", "--port", "16980",
                "--control", str(directory / "control.sock"), "--stream-name", "Windows", "--managed",
                "--latency-ms", str(args.latency_ms), "--jitter-ms", str(args.jitter_ms)],
                stdout=logs[1], stderr=logs[2], env=env)
            wait_for(lambda: (directory / "control.sock").exists())
            control = Control(directory / "control.sock", directory)
            ready = wait_for(lambda: (s if (s := control.command())["sink_input"] != 4294967295 else None))
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as bad:
                for rate, channels, encoding, name in ((4, 1, 1, b"Windows"), (3, 2, 1, b"Windows"),
                        (3, 1, 129, b"Windows"), (3, 1, 1, b"Other")):
                    bad.sendto(HEADER.pack(b"VBAN", rate, FRAMES - 1, channels, encoding, name, 0) + pcm(0),
                               ("127.0.0.1", 16980))
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as wrong_source:
                wrong_source.bind(("127.0.0.2", 0))
                wrong_source.sendto(HEADER.pack(b"VBAN", 3, FRAMES - 1, 1, 1, b"Windows", 0) + pcm(0),
                                    ("127.0.0.1", 16980))
            rejected = wait_for(lambda: (s if (s := control.command())["invalid"] == 4 and s["wrong_source"] == 1 else None))
            assert not rejected["active"] and rejected["accepted"] == 0
            send(.016)
            held = control.command()
            assert held["active"] and held["state"] == "priming" and held["written_bytes"] == 0, held
            assert control.command("PHONE -1")["phone"] is None
            wait_for(lambda: not control.command()["active"])
            solo_session = control.command()["sessions"] + 1
            solo_accepted_begin = control.command()["accepted"]
            monitor = Monitor(env, logs[3], args.record_ms)
            time.sleep(.2)
            marker_times = [0] + list(range(2, args.seconds))
            sender_timing = {}
            submitted = send(args.seconds, marker_times=marker_times, drift_ppm=args.drift_ppm, telemetry=sender_timing)
            wait_for(lambda: len(monitor.detected) >= len(submitted))
            running = control.command()
            if running.get("rate_pending"):
                running = wait_for(lambda: (s if not (s := control.command()).get("rate_pending") else None))
            assert running["rate_ack"] > 0 and running["server_rate"] == running["rate"], running
            assert running["target_negotiated"], running
            expected_target = running["tlength"] * 1e6 / (running["rate"] * 4) + running["configured_sink_us"]
            assert abs(running["effective_target_us"] - expected_target) < 2, (running, expected_target)
            if args.sink_floor_ms:
                assert running["configured_sink_us"] == args.sink_floor_ms * 1000, running
                # Query the daemon independently: the sink's scheduler itself
                # must use the fixture floor, not just the stream's request.
                sinks = json.loads(subprocess.check_output(["pactl", "-f", "json", "list", "sinks"], env=env))
                output_sink = next(row for row in sinks if row["name"] == "output")
                (args.output / "floor-sink.json").write_text(json.dumps(output_sink, indent=2) + "\n")
                assert output_sink["latency"]["configured"] == args.sink_floor_ms * 1000, output_sink
            solo_clock = monitor_clock(list(monitor.clock_points))
            solo = latency(submitted, monitor.detected)
            (args.output / "latency-solo.json").write_text(json.dumps(solo, indent=2) + "\n")
            solo_raw_end = len(monitor.raw)
            wait_for(lambda: not control.command()["active"])
            idle = control.command()
            time.sleep(.1)
            assert control.command()["written_bytes"] == idle["written_bytes"], "Idle PCM writes"
            assert idle["state"] == "idle", idle
            # A live phone lane is staged at discard, then registered before moving to output.
            phone = subprocess.Popen(["pacat", "--playback", "--raw", "--format=s16le", "--rate=48000",
                "--channels=2", "--latency-msec=10", "--device=discard", "--client-name=native-vban-test-phone"],
                stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=logs[3], env=env)
            phone_done = threading.Event()
            def feed_phone():
                try:
                    while not phone_done.is_set():
                        phone.stdin.write(pcm(0, 3000, 1500) * 30)
                        phone.stdin.flush()
                except (BrokenPipeError, ValueError):
                    pass
            thread = threading.Thread(target=feed_phone, daemon=True)
            thread.start()
            def inputs():
                return json.loads(subprocess.check_output(["pactl", "-f", "json", "list", "sink-inputs"], env=env))
            phone_id = wait_for(lambda: next((row["index"] for row in inputs()
                if row["properties"].get("application.name") == "native-vban-test-phone"), None))
            assert control.command(f"PHONE {phone_id}")["phone"] == phone_id
            subprocess.check_call(["pactl", "move-sink-input", str(phone_id), "output"], env=env)
            time.sleep(.2)
            marker_begin = len(monitor.detected)
            submitted = send(7, marker_times=[0, 2, 3, 4, 5, 6])
            wait_for(lambda: len(monitor.detected) >= marker_begin + len(submitted))
            mixed_running = control.command()
            hold = control.command("HOLD")
            assert hold["phone"] is None and hold["phone_pending"] and hold["active"], hold
            assert control.command(f"PHONE {phone_id}")["phone_pending"] is False
            mixed = latency(submitted, monitor.detected[marker_begin:])
            (args.output / "latency-mixed.json").write_text(json.dumps(mixed, indent=2) + "\n")
            wait_for(lambda: not control.command()["active"])
            phone_only = control.command()
            assert phone_only["phone"] == phone_id
            # Same packet stream supports drops, duplicates and adjacent swaps.
            begin = len(monitor.raw)
            send(5, faults=True)
            fault_status = control.command()
            fault_values = monitor.samples(begin + RATE * 4, len(monitor.raw) - RATE * 4)
            assert fault_status["missing"] > 0 and fault_status["duplicate"] + fault_status["late"] > 0, fault_status
            assert window_amplitude(fault_values, 1000) > 1500, "Desktop tone lost under packet faults"
            # Independent desktop gain leaves phone tone intact.
            wait_for(lambda: not control.command()["active"])
            assert control.command("GAIN 0.25")["gain"] == .25
            begin = len(monitor.raw)
            send(2)
            gain_values = monitor.samples(begin + RATE * 4, len(monitor.raw) - RATE * 2)
            desktop_amp = window_amplitude(gain_values, 1000)
            phone_amp = window_amplitude(gain_values, 1500)
            assert 350 < desktop_amp < 650, desktop_amp
            assert 1200 < phone_amp < 1800, phone_amp
            wait_for(lambda: not control.command()["active"])
            phone_done.set(); phone.terminate(); phone.wait(timeout=3); thread.join(timeout=1)
            try:
                phone.stdin.close()
            except BrokenPipeError:
                pass
            control.command("PHONE -1")
            final = control.command()
            logs[1].flush()
            events = [json.loads(line) for line in (args.output / "receiver.jsonl").read_text().splitlines()]
            solo_media_underflows = [row for row in events if row.get("event") == "underflow"
                and row["sessions"] == solo_session and row["accepted"] < solo_accepted_begin + sender_timing["packets"]]
            result = {"ok": True, "measurement": "same-container UDP send to output.monitor read; includes monitor buffering",
                "excludes": "Windows capture, physical LAN, ALSA DAC and speaker", "solo_seconds": args.seconds,
                "configured_latency_ms": args.latency_ms, "configured_jitter_ms": args.jitter_ms,
                "sender_drift_ppm": args.drift_ppm,
                "sender_timing": sender_timing,
                "monitor_clock": solo_clock, "record_ms": args.record_ms,
                "resample_method": args.resample_method,
                "fixture_sink_floor_ms": args.sink_floor_ms,
                "max_observed_latency_ms": args.max_observed_latency_ms,
                "protocol_rejections": rejected, "managed_hold": held,
                "solo_media_underflows": solo_media_underflows,
                "ready": ready, "solo": solo, "solo_running": running, "mixed": mixed,
                "mixed_running": mixed_running, "phone_only": phone_only, "idle": idle,
                "fault_status": fault_status, "fault_max_silence_ms": longest_silence(fault_values),
                "solo_max_silence_ms": longest_silence(monitor.samples(RATE * 4, solo_raw_end - RATE * 4)),
                "desktop_gain_amplitude": desktop_amp, "phone_amplitude": phone_amp, "final": final}
            result["latency_passed"] = (solo["p95_ms"] < args.max_observed_latency_ms
                                        and mixed["p95_ms"] < args.max_observed_latency_ms)
            result["steady_passed"] = not solo_media_underflows and result["solo_max_silence_ms"] < .5
            result["ok"] = result["latency_passed"] and (result["steady_passed"] or not args.require_stable)
            (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result), flush=True)
            assert result["ok"], result
        finally:
            if monitor: monitor.close()
            for child in (phone, receiver, pulse):
                if child and child.poll() is None:
                    child.terminate()
                    child.wait(timeout=5)
            for log in logs: log.close()


if __name__ == "__main__":
    main()
