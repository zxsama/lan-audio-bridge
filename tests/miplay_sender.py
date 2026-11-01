#!/usr/bin/env python3
"""Local-container MiPlay -> running bridge -> Pulse monitor integration check.

Start runtime separately; this script never starts a receiver or calls its sink.
Use --target/--source-address on the same local test network. It generates a
short AAC tone, performs MiPlay control and WFD RTSP exchanges over TCP, and
requires non-silent PCM on the selected Pulse monitor before reporting success.
"""
import argparse
import asyncio
import dataclasses
import json
import math
import os
from pathlib import Path
import socket
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
from miplay_receiver import stop_process
from vendor.castfabric_miplay.simulator import MiPlaySourceSimulator


STATUS = Path("/run/lan-audio/status.json")


def parse_short_modules(output):
    modules = []
    for line in output.decode().splitlines():
        fields = line.split("\t")
        if len(fields) < 3 or not fields[0].isdigit():
            raise RuntimeError("unexpected Pulse module inventory")
        modules.append({"index": int(fields[0]), "name": fields[1], "argument": fields[2]})
    return modules


async def pulse_list(options, kind, *, short=False):
    arguments = ["list", "short", kind] if short else ["--format=json", "list", kind]
    process = await asyncio.create_subprocess_exec(
        "pactl", "--server=" + options.pulse_server, *arguments,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        output, _ = await asyncio.wait_for(process.communicate(), 3)
        if process.returncode:
            raise RuntimeError("Pulse inspection failed")
        return parse_short_modules(output) if short else json.loads(output)
    finally:
        await stop_process(process)


def playback_processes():
    found = []
    for path in Path("/proc").glob("[0-9]*/comm"):
        try:
            if path.read_text().strip() in {"pacat", "ffmpeg"}:
                found.append(int(path.parent.name))
        except FileNotFoundError:
            pass
    return found


async def require_local_null_test(options):
    if not Path("/.dockerenv").exists() or Path("/dev/snd").exists() or os.getenv("AUDIO_MODE") != "null":
        raise RuntimeError("sender check requires an isolated null-mode container without /dev/snd")
    if options.pulse_server != "unix:/run/lan-audio/pulse.sock" or options.monitor != "output.monitor":
        raise RuntimeError("sender check is restricted to the local bridge output monitor")
    if options.target != options.source_address:
        raise RuntimeError("sender and receiver must use the same local test address")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind((options.source_address, 0))
    # Pulse 17 JSON module listings omit their numeric IDs; the short listing
    # retains them and lets us verify the output sink's actual owner module.
    modules = await pulse_list(options, "modules", short=True)
    sinks = await pulse_list(options, "sinks")
    output = next((sink for sink in sinks if sink["name"] == "output"), None)
    if output is None or not any(str(module["index"]) == str(output["owner_module"])
                                 and module["name"] == "module-null-sink" for module in modules):
        raise RuntimeError("bridge output must be backed by module-null-sink")
    if json.loads(STATUS.read_text())["owner"] is not None or any(
            module["name"] == "module-loopback" for module in modules) or playback_processes():
        raise RuntimeError("bridge must be idle before the test")


def tone_evidence(pcm):
    """Require ten consecutive 100 ms windows dominated by the 997 Hz tone."""
    stereo = struct.unpack("<" + "h" * (len(pcm) // 2), pcm[:len(pcm) & ~1])
    mono = stereo[::2]
    window = 4800
    sine = [math.sin(2 * math.pi * 997 * index / 48000) for index in range(window)]
    cosine = [math.cos(2 * math.pi * 997 * index / 48000) for index in range(window)]
    run = longest = 0
    for offset in range(0, len(mono) - window + 1, window):
        chunk = mono[offset:offset + window]
        energy = sum(value * value for value in chunk)
        s = sum(value * basis for value, basis in zip(chunk, sine))
        c = sum(value * basis for value, basis in zip(chunk, cosine))
        purity = 2 * (s * s + c * c) / (window * energy) if energy else 0
        if energy / window > 100 ** 2 and purity > 0.85:
            run += 1
            longest = max(run, longest)
        else:
            run = 0
    return {"pcm_peak": max((abs(value) for value in stereo), default=0),
            "stable_tone_seconds": longest / 10,
            "active_samples": sum(abs(value) > 100 for value in stereo)}


async def check(options):
    await require_local_null_test(options)
    recorder = await asyncio.create_subprocess_exec(
        "parec", "--raw", "--format=s16le", "--rate=48000", "--channels=2",
        "--latency-msec=100", "--device=" + options.monitor,
        "--server=" + options.pulse_server,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
    )
    capture = bytearray()

    async def collect():
        while True:
            block = await recorder.stdout.read(16384)
            if not block:
                return
            capture.extend(block)
            if len(capture) > 48000 * 4 * 20:
                raise RuntimeError("monitor capture exceeded 20 seconds")

    reader = asyncio.create_task(collect())
    route_checks = 0
    stop_watcher = asyncio.Event()

    async def watch_route():
        nonlocal route_checks
        while not stop_watcher.is_set():
            state = json.loads(STATUS.read_text())
            if state["owner"] == "miplay":
                modules = await pulse_list(options, "modules")
                routes = [module for module in modules if module["name"] == "module-loopback"]
                if len(routes) != 1 or "source=miplay_bus.monitor" not in routes[0]["argument"]:
                    # Status and Pulse are separate snapshots. Retry a possible
                    # boundary race only when ownership has already changed.
                    if json.loads(STATUS.read_text())["owner"] == "miplay":
                        raise RuntimeError("MiPlay owner has an incorrect output route")
                else:
                    route_checks += 1
            elif state["owner"] is not None:
                raise RuntimeError("another source acquired output during the test")
            await asyncio.sleep(0.1)

    watcher = asyncio.create_task(watch_route())
    try:
        # Suspended output need not emit silent samples. Recording its monitor
        # must not wake it or create a playback route before the sender starts.
        await asyncio.sleep(0.3)
        output = next(sink for sink in await pulse_list(options, "sinks")
                      if sink["name"] == "output")
        if output["state"] != "SUSPENDED" or not output["mute"]:
            raise RuntimeError("output is not suspended before playback")
        if recorder.returncode is not None:
            raise RuntimeError("Pulse monitor recorder exited early")
        baseline = struct.unpack("<" + "h" * (len(capture) // 2), capture[:len(capture) & ~1])
        baseline_peak = max((abs(value) for value in baseline), default=0)
        if baseline_peak > 5:
            raise RuntimeError("output monitor is not silent before playback")
        result = await asyncio.wait_for(MiPlaySourceSimulator(
            target_host=options.target, target_port=options.port,
            source_host=options.source_address, duration=options.duration,
            tone_frequency=997, volume=75, paced=True,
        ).run(), timeout=20)
        async with asyncio.timeout(10):
            while json.loads(STATUS.read_text())["owner"] is not None or playback_processes():
                await asyncio.sleep(0.1)
        modules = await pulse_list(options, "modules")
        if any(module["name"] == "module-loopback" for module in modules):
            raise RuntimeError("output route remained after the MiPlay session")
        output = next(sink for sink in await pulse_list(options, "sinks")
                      if sink["name"] == "output")
        if output["state"] != "SUSPENDED" or not output["mute"]:
            raise RuntimeError("output did not suspend after the MiPlay session")
        await asyncio.sleep(0.3)
        if recorder.returncode is not None:
            raise RuntimeError("Pulse monitor recorder exited early")
    finally:
        stop_watcher.set()
        if recorder.returncode is None:
            recorder.terminate()
        await stop_process(recorder)
        await reader
        await watcher
    evidence = tone_evidence(capture)
    if not result.control_opened or not result.rtsp_ready or result.media_frames < 1:
        raise RuntimeError("MiPlay protocol path incomplete")
    if evidence["pcm_peak"] < 500 or evidence["stable_tone_seconds"] < 1 or route_checks < 3:
        raise RuntimeError("MiPlay did not produce a stable 997 Hz tone with verified output ownership")
    return {**dataclasses.asdict(result), **evidence, "baseline_peak": baseline_peak,
            "route_checks": route_checks, "ended_idle": True,
            "playback_processes_after": [], "captured_bytes": len(capture)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", required=True)
    parser.add_argument("--source-address", required=True)
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--duration", type=float, default=4)
    parser.add_argument("--monitor", default="output.monitor")
    parser.add_argument("--pulse-server", default="unix:/run/lan-audio/pulse.sock")
    options = parser.parse_args()
    if not 2 <= options.duration <= 5:
        parser.error("duration must be between 2 and 5 seconds")
    print(json.dumps(asyncio.run(check(options)), sort_keys=True))


if __name__ == "__main__":
    main()
