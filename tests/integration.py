#!/usr/bin/env python3
"""Real Pulse + DLNA integration test; run against compose.test.yaml only.

No third-party Python packages, external accounts, hardware, or published ports.
The host wrapper streams this file to an explicitly verified null-output container.
"""
import argparse
import array
import contextlib
import http.server
import json
import math
import os
from pathlib import Path
import select
import shlex
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import wave
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

SERVER = "unix:/run/lan-audio/pulse.sock"
RATE = 48000
FREQUENCIES = {"airplay": 440, "dlna": 660, "spotify": 880, "miplay": 1100}


def command(*args):
    return subprocess.check_output(args, text=True, timeout=15)


def pulse(kind):
    return json.loads(command("pactl", "--server=" + SERVER, "--format=json", "list", kind))


def status():
    return json.loads(Path("/run/lan-audio/status.json").read_text())


def eventually(check, description, timeout=12):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (AssertionError, OSError, ValueError, subprocess.SubprocessError) as exc:
            last = str(exc)
        time.sleep(0.15)
    raise AssertionError(f"Timed out: {description}; last={last}; status={status()}")


def route(owner):
    # PulseAudio 17 JSON modules omit their indexes; the short format retains them.
    rows = command("pactl", "--server=" + SERVER, "list", "short", "modules").splitlines()
    modules = []
    for row in rows:
        columns = row.split("\t")
        if columns[1] == "module-loopback":
            modules.append({"index": int(columns[0]), "argument": columns[2]})
    assert len(modules) == (0 if owner is None else 1), modules
    current = status()
    assert current["owner"] == owner, current
    if owner is not None:
        arguments = dict(arg.split("=", 1) for arg in shlex.split(modules[0]["argument"]) if "=" in arg)
        assert arguments["source"] == owner + "_bus.monitor", arguments
        assert arguments["sink"] == "output", arguments
        assert int(current["route_module"]) == int(modules[0]["index"]), current
    else:
        assert current["route_module"] is None, current
    output = next(s for s in pulse("sinks") if s["name"] == "output")
    assert output["state"] == ("SUSPENDED" if owner is None else "RUNNING"), output["state"]
    assert output["mute"] == (owner is None), output["mute"]
    streams = [s for s in pulse("sink-inputs") if int(s["sink"]) == int(output["index"])]
    assert len(streams) == (0 if owner is None else 1), streams
    if owner is not None:
        assert int(streams[0]["owner_module"]) == int(modules[0]["index"]), streams
    return True


class Tone:
    def __init__(self, source):
        self.done = threading.Event()
        self.process = subprocess.Popen(
            ["pacat", "--server=" + SERVER, "--playback", "--raw", "--format=s16le",
             "--rate=48000", "--channels=2", "--latency-msec=60", "--device=" + source + "_bus"],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        frequency = FREQUENCIES[source]
        # Integral cycles per block, so repeating this block has no discontinuities.
        block = b"".join(struct.pack("<hh", *([int(10000 * math.sin(2 * math.pi * frequency * i / RATE))] * 2))
                         for i in range(RATE // 10))

        def feed():
            try:
                while not self.done.is_set():
                    self.process.stdin.write(block)
                    self.process.stdin.flush()
            except (BrokenPipeError, OSError):
                pass

        self.thread = threading.Thread(target=feed, daemon=True)
        self.thread.start()

    def close(self):
        self.done.set()
        self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
        self.thread.join(timeout=3)
        with contextlib.suppress(BrokenPipeError, OSError):
            self.process.stdin.close()


def capture():
    recorder = subprocess.Popen(
        ["parec", "--server=" + SERVER, "--device=output.monitor", "--raw", "--format=s16le",
         "--rate=48000", "--channels=2", "--latency-msec=30"], stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL)
    raw = bytearray()
    deadline = time.monotonic() + 6
    wanted = RATE * 4  # one second, stereo s16le
    try:
        while len(raw) < wanted and time.monotonic() < deadline:
            if select.select([recorder.stdout], [], [], 0.25)[0]:
                chunk = os.read(recorder.stdout.fileno(), min(65536, wanted - len(raw)))
                if not chunk:
                    break
                raw.extend(chunk)
    finally:
        recorder.terminate()
        recorder.wait(timeout=3)
        recorder.stdout.close()
    assert len(raw) == wanted, f"Short monitor recording: {len(raw)}/{wanted}"
    samples = array.array("h", raw)
    if sys.byteorder != "little":
        samples.byteswap()
    # Discard initial half second of monitor startup latency and verify both
    # channels carry the same generated stereo signal before spectral checks.
    steady = samples[RATE:]
    left, right = list(steady[::2]), list(steady[1::2])
    assert max((abs(a - b) for a, b in zip(left, right)), default=0) <= 2, "Stereo channels differ"
    return left


def amplitude(samples, frequency):
    n = len(samples)
    real = sum(v * math.cos(2 * math.pi * frequency * i / RATE) for i, v in enumerate(samples))
    imag = sum(v * math.sin(2 * math.pi * frequency * i / RATE) for i, v in enumerate(samples))
    return 2 * math.hypot(real, imag) / n


def assert_audio(frequency, others=()):
    samples = capture()
    wanted = amplitude(samples, frequency)
    unwanted = {f: amplitude(samples, f) for f in others}
    assert wanted > 1000, (frequency, wanted, unwanted)
    assert all(value < wanted * 0.03 for value in unwanted.values()), (frequency, wanted, unwanted)
    print(f"  output.monitor {frequency} Hz={wanted:.1f}; other tones={unwanted}", flush=True)


def test_arbitration():
    print("Pulse: all twelve directed takeovers, sole route, recorded audio, no stale fallback", flush=True)
    eventually(lambda: route(None), "startup has no output route")
    tones = {}
    old_owner = None
    try:
        for source in ("airplay", "dlna", "airplay", "spotify", "dlna", "spotify", "miplay",
                       "dlna", "miplay", "spotify", "airplay", "miplay", "airplay"):
            if source in tones:
                tones.pop(source).close()
                time.sleep(0.4)
            before = status().get("children", {}).get(old_owner, {}).get("pid")
            tones[source] = Tone(source)
            eventually(lambda: route(source), source + " takeover")
            # Keep old injected streams alive to expose any accidental mixing.
            time.sleep(0.5)
            assert_audio(FREQUENCIES[source], [f for s, f in FREQUENCIES.items() if s != source])
            if before:
                eventually(lambda: status()["children"][old_owner]["pid"] not in (before, None),
                           "losing receiver restarted")
            old_owner = source
        for source in ("dlna", "spotify", "miplay"):
            tones.pop(source).close()
        time.sleep(0.5)
        assert route("airplay"), "Late old-stream end must not release current owner"
        tones.pop("airplay").close()
        eventually(lambda: route(None), "owner end releases output without fallback")
        # An idle device must be suspended, not continuously producing silent PCM.
        time.sleep(0.5)
        assert route(None), "Idle output must remain suspended"
    finally:
        for tone in tones.values():
            tone.close()
    eventually(lambda: route(None), "arbitration cleanup")


class MediaHandler(http.server.BaseHTTPRequestHandler):
    audio = b""

    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.send_media(False)

    def do_GET(self):
        self.send_media(True)

    def send_media(self, body):
        if self.path != "/tone.wav":
            self.send_error(404)
            return
        start, end = 0, len(self.audio) - 1
        value = self.headers.get("Range")
        if value:
            unit, bounds = value.split("=", 1)
            assert unit == "bytes"
            first, last = bounds.split("-", 1)
            start = int(first) if first else 0
            end = min(int(last), end) if last else end
        if start > end:
            self.send_error(416)
            return
        self.send_response(206 if value else 200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if value:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(self.audio)}")
        self.end_headers()
        if body:
            try:
                self.wfile.write(self.audio[start:end + 1])
            except (BrokenPipeError, ConnectionResetError):
                pass


def make_wav():
    import io
    data = io.BytesIO()
    block = b"".join(struct.pack("<hh", *([int(10000 * math.sin(2 * math.pi * 520 * i / RATE))] * 2))
                     for i in range(RATE))
    with wave.open(data, "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        for _ in range(30):
            wav.writeframes(block)
    return data.getvalue()


def test_dlna():
    print("DLNA: device description -> SetURI -> Play -> Pause -> Seek -> Play -> Stop", flush=True)
    ip = socket.gethostbyname(socket.gethostname())
    base = "http://" + ip + ":" + os.environ.get("DLNA_PORT", "49494")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def discover():
        with opener.open(base + "/description.xml", timeout=3) as response:
            root = ET.fromstring(response.read())
        for service in root.findall(".//{*}service"):
            kind = service.findtext("{*}serviceType")
            if kind and ":AVTransport:" in kind:
                return kind, urllib.parse.urljoin(base, service.findtext("{*}controlURL"))
        raise AssertionError("AVTransport service missing")

    service_type, control_url = eventually(discover, "DLNA description")

    def soap(action, **arguments):
        payload = ''.join(f"<{key}>{escape(str(value))}</{key}>" for key, value in arguments.items())
        body = (f'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
                f's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
                f'<u:{action} xmlns:u="{service_type}">{payload}</u:{action}></s:Body></s:Envelope>')
        request = urllib.request.Request(control_url, data=body.encode(), headers={
            "Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": f'"{service_type}#{action}"'})
        try:
            with opener.open(request, timeout=8) as response:
                tree = ET.fromstring(response.read())
        except urllib.error.HTTPError as error:
            raise AssertionError(f"SOAP {action}: {error.code} {error.read().decode()}") from error
        assert tree.find(".//{*}Fault") is None, ET.tostring(tree)
        return {element.tag.split("}")[-1]: element.text for element in tree.iter()}

    MediaHandler.audio = make_wav()
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), MediaHandler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            media = f"http://127.0.0.1:{server.server_port}/tone.wav"
            soap("SetAVTransportURI", InstanceID=0, CurrentURI=media, CurrentURIMetaData="")
            soap("Play", InstanceID=0, Speed=1)
            eventually(lambda: route("dlna"), "DLNA real playback owner")
            eventually(lambda: soap("GetTransportInfo", InstanceID=0).get("CurrentTransportState") == "PLAYING",
                       "DLNA playing state")
            time.sleep(0.5)
            assert_audio(520, FREQUENCIES.values())
            soap("Pause", InstanceID=0)
            eventually(lambda: soap("GetTransportInfo", InstanceID=0).get("CurrentTransportState") == "PAUSED_PLAYBACK",
                       "DLNA paused state")
            eventually(lambda: route(None), "DLNA pause releases audio")
            soap("Seek", InstanceID=0, Unit="REL_TIME", Target="00:00:10")
            soap("Play", InstanceID=0, Speed=1)
            eventually(lambda: route("dlna"), "DLNA resume owner")

            def seek_position():
                position = soap("GetPositionInfo", InstanceID=0).get("RelTime", "0:0:0")
                hours, minutes, seconds = map(int, position.split(":"))
                elapsed = hours * 3600 + minutes * 60 + seconds
                return 9 <= elapsed < 20

            eventually(seek_position, "DLNA Seek changed real position")
            assert_audio(520, FREQUENCIES.values())
            soap("Stop", InstanceID=0)
            eventually(lambda: route(None), "DLNA stop releases output")
            assert soap("GetTransportInfo", InstanceID=0)["CurrentTransportState"] == "STOPPED"
        finally:
            with contextlib.suppress(Exception):
                soap("Stop", InstanceID=0)
            server.shutdown()
            thread.join(timeout=3)


def test_output_gain():
    """Measure output gain on a real Pulse monitor with a fixed PCM source."""
    output = next(s for s in pulse("sinks") if s["name"] == "output")
    assert all(v["value"] == 65536 for v in output["volume"].values()), output["volume"]
    tone = Tone("dlna")
    try:
        eventually(lambda: route("dlna"), "gain measurement playback")
        time.sleep(0.5)
        unity = amplitude(capture(), FREQUENCIES["dlna"])
        command("pactl", "--server=" + SERVER, "set-sink-volume", "output", "45875")
        time.sleep(0.5)
        attenuated = amplitude(capture(), FREQUENCIES["dlna"])
        command("pactl", "--server=" + SERVER, "set-sink-volume", "output", "65536")
        time.sleep(0.5)
        restored = amplitude(capture(), FREQUENCIES["dlna"])
        assert 9000 < unity < 11000, unity
        assert 2.7 < unity / attenuated < 3.1, (unity, attenuated)
        assert 0.95 < restored / unity < 1.05, (unity, restored)
        print(json.dumps({"output_gain": {"percent_100_amplitude": round(unity, 2),
                                        "percent_70_amplitude": round(attenuated, 2),
                                        "ratio": round(unity / attenuated, 3)}}), flush=True)
    finally:
        command("pactl", "--server=" + SERVER, "set-sink-volume", "output", "65536")
        tone.close()
    eventually(lambda: route(None), "gain measurement cleanup suspends output")


def inside():
    assert os.environ.get("AUDIO_MODE") == "null", "Refusing tests against hardware output"
    assert not Path("/dev/snd").exists(), "Refusing a container with sound devices"
    assert all(os.environ.get("ENABLE_" + source.upper(), "").lower() == "true" for source in FREQUENCIES)
    test_arbitration()
    test_output_gain()
    test_dlna()
    print("PASS: real Pulse routing/audio + DLNA SOAP. Phone/account/hardware tests remain separate.", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--container", help="Optional explicit null-mode test container ID")
    args = parser.parse_args()
    if args.inside:
        inside()
        return
    root = Path(__file__).resolve().parents[1]
    container = args.container or command("docker", "compose", "-f", str(root / "compose.test.yaml"), "ps", "-q", "audio").strip()
    assert container and "\n" not in container, "Start exactly one compose.test.yaml audio service first"
    info = json.loads(command("docker", "inspect", container))[0]
    environment = dict(item.split("=", 1) for item in info["Config"]["Env"])
    assert environment.get("AUDIO_MODE") == "null", "Refusing tests against hardware output"
    assert info["HostConfig"]["NetworkMode"] != "host", "Refusing host-network production container"
    assert not info["HostConfig"].get("Devices"), "Refusing a container with mapped devices"
    assert info["State"]["Running"], "Test container is not running"
    # Streaming avoids Docker archive-copy behavior with a tmpfs target directory.
    subprocess.run(["docker", "exec", "-i", container, "python3", "-u", "-", "--inside"],
                   input=Path(__file__).read_bytes(), check=True, timeout=180)


if __name__ == "__main__":
    main()
