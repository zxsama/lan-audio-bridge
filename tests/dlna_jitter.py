#!/usr/bin/env python3
"""Local null-output DLNA jitter regression (no hardware or remote services).

Start compose.test.yaml separately, then run:
  python3 tests/dlna_jitter.py --label baseline --format wav
  python3 tests/dlna_jitter.py --label buffered --format flac
Compare separate containers/images or DLNA_BUFFER_MS=0 versus 1000, keeping
OUTPUT_BUFFER_MS identical. This script never changes receiver configuration.
FLAC requires ffmpeg in the test container; all Python code uses the stdlib.
Results are one JSON object; baseline gaps intentionally produce a failure exit.
This controlled impairment does not establish the cause of real app dropouts.
"""
import argparse
import array
import contextlib
import http.server
import io
import json
import math
import os
from pathlib import Path
import select
import shlex
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import urllib.request
import wave
import xml.etree.ElementTree as ET
from xml.sax.saxutils import escape

SERVER = "unix:/run/lan-audio/pulse.sock"
RATE = 48000
DURATION = 60
WINDOW_BYTES = RATE * 4 // 20  # 50 ms, stereo s16le


def command(*args, timeout=5):
    return subprocess.check_output(args, text=True, timeout=timeout, stderr=subprocess.DEVNULL)


def eventually(check, description, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.1)
    raise AssertionError(description)


def status():
    return json.loads(Path("/run/lan-audio/status.json").read_text())


def route_snapshot():
    current = status()
    rows = command("pactl", "--server=" + SERVER, "list", "short", "modules").splitlines()
    routes = [row.split("\t") for row in rows if "\tmodule-loopback\t" in row]
    valid = len(routes) == (0 if current["owner"] is None else 1)
    if routes:
        arguments = dict(item.split("=", 1) for item in shlex.split(routes[0][2]) if "=" in item)
        valid = valid and arguments.get("source") == "dlna_bus.monitor" and arguments.get("sink") == "output"
        valid = valid and str(current.get("route_module")) == routes[0][0]
    else:
        valid = valid and current.get("route_module") is None
    sinks = json.loads(command("pactl", "--server=" + SERVER, "--format=json", "list", "sinks"))
    output = next(item["index"] for item in sinks if item["name"] == "output")
    streams = json.loads(command("pactl", "--server=" + SERVER, "--format=json", "list", "sink-inputs"))
    streams = [item for item in streams if int(item["sink"]) == int(output)]
    valid = valid and len(streams) == len(routes)
    if streams and routes:
        valid = valid and str(streams[0]["owner_module"]) == routes[0][0]
    return {"owner": current["owner"], "module": current.get("route_module"), "single_route": bool(valid)}


class Transport:
    def __init__(self):
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        ip = socket.gethostbyname(socket.gethostname())
        base = "http://" + ip + ":" + os.environ.get("DLNA_PORT", "49494")
        with self.opener.open(base + "/description.xml", timeout=5) as response:
            root = ET.fromstring(response.read())
        for service in root.findall(".//{*}service"):
            kind = service.findtext("{*}serviceType", "")
            if ":AVTransport:" in kind:
                self.kind = kind
                self.url = urllib.parse.urljoin(base, service.findtext("{*}controlURL"))
                return
        raise AssertionError("AVTransport service missing")

    def soap(self, action, **arguments):
        arguments = {"InstanceID": 0, **arguments}
        payload = "".join(f"<{key}>{escape(str(value))}</{key}>" for key, value in arguments.items())
        body = (f'<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
                f'<u:{action} xmlns:u="{self.kind}">{payload}</u:{action}></s:Body></s:Envelope>')
        request = urllib.request.Request(self.url, data=body.encode(), headers={
            "Content-Type": 'text/xml; charset="utf-8"', "SOAPAction": f'"{self.kind}#{action}"'})
        with self.opener.open(request, timeout=5) as response:
            root = ET.fromstring(response.read())
        assert root.find(".//{*}Fault") is None, "SOAP fault: " + action
        return {item.tag.split("}")[-1]: item.text for item in root.iter()}


def make_media(kind):
    block = b"".join(struct.pack("<hh", *([int(10000 * math.sin(2 * math.pi * 520 * i / RATE))] * 2))
                     for i in range(RATE))
    data = io.BytesIO()
    with wave.open(data, "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(block * DURATION)
    if kind == "wav":
        return data.getvalue()
    # A seekable output lets ffmpeg finalize STREAMINFO duration for DLNA Seek.
    with tempfile.TemporaryDirectory(prefix="dlna-jitter-") as directory:
        output = Path(directory) / "tone.flac"
        subprocess.run(["ffmpeg", "-v", "error", "-i", "pipe:0", "-c:a", "flac", str(output)],
                       input=data.getvalue(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       check=True, timeout=20)
        return output.read_bytes()


class MediaServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, audio, args):
        super().__init__(("127.0.0.1", 0), MediaHandler)
        self.audio, self.args = audio, args
        self.done = threading.Event()
        self.stalling = threading.Event()
        self.stalls = []
        self.requests = 0
        self.request_events = []


class MediaHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_HEAD(self):
        self.send_media(False)

    def do_GET(self):
        self.send_media(True)

    def send_media(self, body):
        server = self.server
        if self.path != "/tone." + server.args.format:
            self.send_error(404)
            return
        audio = server.audio
        start, end = 0, len(audio) - 1
        value = self.headers.get("Range")
        if value:
            try:
                unit, bounds = value.split("=", 1)
                first, last = bounds.split("-", 1)
                if unit != "bytes" or "," in bounds:
                    raise ValueError()
                if first:
                    start, end = int(first), min(int(last), end) if last else end
                else:
                    start = max(0, len(audio) - int(last))
                if start < 0 or start > end:
                    raise ValueError()
            except ValueError:
                self.send_error(416)
                return
        self.send_response(206 if value else 200)
        self.send_header("Content-Type", "audio/wav" if server.args.format == "wav" else "audio/flac")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if value:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(audio)}")
        self.end_headers()
        if not body:
            return
        server.requests += 1
        request_id = server.requests
        self.connection.settimeout(3)
        # The stationary tone has near-constant encoded bytes/second. A 150ms
        # initial burst accommodates headers/FLAC frames; subsequent
        # sends follow the original clock, catching up after each impairment.
        # This is a bounded burst-delay model, not a general VBR bandwidth model.
        bytes_per_second = len(audio) / DURATION
        server.request_events.append({"request": request_id, "started": time.monotonic(),
                                      "media_offset_seconds": round(start / bytes_per_second, 3)})
        chunk = max(1, int(bytes_per_second * 0.05))
        epoch, sent, next_stall = time.monotonic(), 0, server.args.interval
        try:
            while start <= end and not server.done.is_set():
                media_time = sent / bytes_per_second
                target = epoch + max(0, media_time - 0.15)
                if server.done.wait(max(0, target - time.monotonic())):
                    break
                if media_time >= next_stall:
                    server.stalls.append({"started": time.monotonic(), "request": request_id,
                                          "media_offset_seconds": round(start / bytes_per_second, 3)})
                    server.stalling.set()
                    interrupted = server.done.wait(server.args.stall_ms / 1000)
                    server.stalling.clear()
                    next_stall += server.args.interval
                    if interrupted:
                        break
                payload = audio[start:min(start + chunk, end + 1)]
                self.wfile.write(payload)
                self.wfile.flush()
                start += len(payload)
                sent += len(payload)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass


def terminate(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
    if process.stdout:
        process.stdout.close()


def capture(seconds, warmup=0, inspect_routes=False, impairment=None):
    recorder = subprocess.Popen([
        "parec", "--server=" + SERVER, "--device=output.monitor", "--raw", "--format=s16le",
        "--rate=48000", "--channels=2", "--latency-msec=30"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    raw, snapshots = bytearray(), []
    wanted = int((seconds + warmup) * RATE * 4)
    started, next_poll = time.monotonic(), 0
    first_pcm = None
    try:
        while len(raw) < wanted and time.monotonic() - started < seconds + warmup + 8:
            if select.select([recorder.stdout], [], [], 0.05)[0]:
                chunk = os.read(recorder.stdout.fileno(), min(65536, wanted - len(raw)))
                if not chunk:
                    break
                if first_pcm is None:
                    first_pcm = time.monotonic()
                raw.extend(chunk)
            elapsed = time.monotonic() - started
            if inspect_routes and elapsed >= warmup and elapsed >= next_poll:
                snapshots.append(route_snapshot())
                next_poll = elapsed + 0.2
    finally:
        terminate(recorder)
    finished = time.monotonic()
    assert len(raw) == wanted, "short monitor capture"
    raw = raw[int(warmup * RATE * 4):]
    rms, tone = [], []
    for offset in range(0, len(raw) - WINDOW_BYTES + 1, WINDOW_BYTES):
        samples = array.array("h", raw[offset:offset + WINDOW_BYTES])
        if sys.byteorder != "little":
            samples.byteswap()
        left, right = samples[::2], samples[1::2]
        assert max(abs(a - b) for a, b in zip(left, right)) <= 2, "stereo channel mismatch"
        rms.append(math.sqrt(sum(value * value for value in left) / len(left)))
        real = sum(value * math.cos(2 * math.pi * 520 * i / RATE) for i, value in enumerate(left))
        imag = sum(value * math.sin(2 * math.pi * 520 * i / RATE) for i, value in enumerate(left))
        tone.append(2 * math.hypot(real, imag) / len(left))
    gaps = [i for i, (level, amplitude) in enumerate(zip(rms, tone)) if level < 1000 or amplitude < 1000]
    longest = run = 0
    for i in range(len(rms)):
        run = run + 1 if i in gaps else 0
        longest = max(longest, run)
    result = {"windows": len(rms), "gap_windows": len(gaps), "longest_gap_ms": longest * 50,
            "first_gap_offsets_ms": [i * 50 for i in gaps[:20]], "min_rms": round(min(rms), 1),
            "max_rms": round(max(rms), 1), "route_samples": len(snapshots),
            "non_dlna_samples": sum(row["owner"] != "dlna" for row in snapshots),
            "invalid_route_samples": sum(not row["single_route"] for row in snapshots),
            "route_modules": sorted({str(row["module"]) for row in snapshots}),
            "capture_wall_seconds": round(finished - started, 3),
            "first_pcm_after_ms": round((first_pcm - started) * 1000, 1)}
    if impairment:
        # These are wall-clock diagnostics, not sample-exact alignment: Pulse
        # record latency can offset PCM time from when its first bytes arrive.
        # Preserve warmup events (negative offsets) to expose startup/seek loss
        # instead of silently shifting the analysis window past an impairment.
        result["http_event_time_origin"] = "capture_start_plus_warmup"
        result["http_stalls"] = [
            {"offset_ms": round((event["started"] - started - warmup) * 1000, 1),
             "request": event["request"], "media_offset_seconds": event["media_offset_seconds"]}
            for event in impairment.stalls if started <= event["started"] <= finished]
    return result


def inside(args):
    assert Path("/.dockerenv").exists(), "inside mode requires a Docker container"
    assert os.environ.get("AUDIO_MODE") == "null", "requires null output"
    assert not Path("/dev/snd").exists(), "sound devices are not allowed"
    assert os.environ.get("ENABLE_DLNA", "").lower() == "true", "DLNA must be enabled"
    assert status()["owner"] is None, "requires an idle isolated test receiver"
    result = {"label": args.label, "format": args.format, "stall_ms": args.stall_ms,
              "interval_seconds": args.interval, "window_ms": 50,
              "configuration": {key: os.environ.get(key) for key in ("DLNA_BUFFER_MS", "OUTPUT_BUFFER_MS")}}
    transport = Transport()
    server = MediaServer(make_media(args.format), args)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        transport.soap("SetAVTransportURI", CurrentURI=f"http://127.0.0.1:{server.server_port}/tone.{args.format}",
                       CurrentURIMetaData="")
        transport.soap("Play", Speed=1)
        eventually(lambda: status()["owner"] == "dlna", "play did not acquire output")
        before = time.monotonic()
        result["steady"] = capture(args.seconds, warmup=6, inspect_routes=True, impairment=server)
        result["steady_stalls"] = sum(before + 6 <= event["started"] <= time.monotonic() for event in server.stalls)
        # Pause during an active HTTP delay, then wait past its completion to
        # catch buffering callbacks that incorrectly resume a user pause.
        assert server.stalling.wait(args.interval + 2), "no HTTP stall available for pause"
        transport.soap("Pause")
        eventually(lambda: status()["owner"] is None, "pause did not release output")
        time.sleep(1)
        assert transport.soap("GetTransportInfo")["CurrentTransportState"] == "PAUSED_PLAYBACK", "pause auto-resumed"
        result["paused"] = capture(0.5, warmup=0.5)
        transport.soap("Play", Speed=1)
        eventually(lambda: status()["owner"] == "dlna", "resume remained corked")
        result["resumed"] = capture(2, warmup=2, inspect_routes=True, impairment=server)
        transport.soap("Seek", Unit="REL_TIME", Target="00:00:05")
        eventually(lambda: status()["owner"] == "dlna", "seek remained corked")
        result["seeked"] = capture(2, warmup=3, inspect_routes=True, impairment=server)
        position = transport.soap("GetPositionInfo").get("RelTime", "0:0:0")
        hours, minutes, seconds = map(int, position.split(":"))
        assert 4 <= hours * 3600 + minutes * 60 + seconds <= 15, "seek position mismatch"
        transport.soap("Stop")
        eventually(lambda: status()["owner"] is None, "stop did not release output")
        result["stopped"] = capture(0.5, warmup=0.5)
        result["stopped_route"] = route_snapshot()
        assert transport.soap("GetTransportInfo")["CurrentTransportState"] == "STOPPED", "stop state mismatch"
        steady = result["steady"]
        result["checks"] = {
            "steady_impairment_present": result["steady_stalls"] >= 2,
            "steady_audio_continuous": steady["gap_windows"] == 0,
            "steady_routing_stable": (steady["route_samples"] >= 10 and steady["non_dlna_samples"] == 0
                                      and steady["invalid_route_samples"] == 0 and len(steady["route_modules"]) == 1),
            "resume_audio_continuous": result["resumed"]["gap_windows"] == 0,
            "seek_audio_continuous": result["seeked"]["gap_windows"] == 0,
            "resume_seek_routing_stable": all(result[key]["route_samples"] > 0
                                               and result[key]["non_dlna_samples"] == 0
                                               and result[key]["invalid_route_samples"] == 0
                                               and len(result[key]["route_modules"]) == 1
                                               for key in ("resumed", "seeked")),
            "pause_stop_silent": all(result[key]["max_rms"] < 10 for key in ("paused", "stopped")),
            "stop_route_released": result["stopped_route"]["single_route"],
        }
        result["passed"] = all(result["checks"].values())
    except Exception as error:
        result["passed"] = False
        # Avoid media URI, device description, SOAP body or account data in logs.
        result["error_type"] = type(error).__name__
        if isinstance(error, AssertionError):
            result["check"] = str(error)
    finally:
        server.done.set()
        with contextlib.suppress(Exception):
            transport.soap("Stop")
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
        result["http_requests"] = server.requests
        result["total_stalls"] = len(server.stalls)
        if server.request_events:
            first_request = server.request_events[0]["started"]
            result["http_request_events"] = [
                {"request": event["request"], "media_offset_seconds": event["media_offset_seconds"],
                 "seconds_after_first_request": round(event["started"] - first_request, 3)}
                for event in server.request_events]
    print(json.dumps(result, sort_keys=True), flush=True)
    return 0 if result["passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--container", help="explicit isolated null-output test container")
    parser.add_argument("--format", choices=("wav", "flac"), default="wav")
    parser.add_argument("--label", default="candidate")
    parser.add_argument("--stall-ms", type=int, default=500)
    parser.add_argument("--interval", type=float, default=3)
    parser.add_argument("--seconds", type=int, default=12, help="steady recording duration, excluding 6s warmup")
    args = parser.parse_args()
    if not 100 <= args.stall_ms <= 1500 or not 2 <= args.interval <= 5 or not 10 <= args.seconds <= 20:
        parser.error("bounded ranges: stall 100..1500 ms, interval 2..5 s, recording 10..20 s")
    if args.inside:
        def timed_out(*_):
            raise TimeoutError("bounded test deadline")
        signal.signal(signal.SIGTERM, timed_out)
        signal.signal(signal.SIGALRM, timed_out)
        signal.alarm(110)
        return inside(args)
    # Reject a redirected Docker client before inspecting any container.
    assert os.environ.get("DOCKER_HOST", "unix:///var/run/docker.sock") == "unix:///var/run/docker.sock", "local Docker socket required"
    context = command("docker", "context", "show").strip()
    endpoint = json.loads(command("docker", "context", "inspect", context))[0]["Endpoints"]["docker"]["Host"]
    assert endpoint == "unix:///var/run/docker.sock", "local Docker context required"
    assert command("docker", "info", "--format", "{{.Name}}").strip().lower() == "mizi", "unexpected Docker host"
    root = Path(__file__).resolve().parents[1]
    container = args.container or command("docker", "compose", "-f", str(root / "compose.test.yaml"), "ps", "-q", "audio").strip()
    assert container and "\n" not in container, "start one compose.test.yaml receiver separately"
    info = json.loads(command("docker", "inspect", container))[0]
    environment = dict(item.split("=", 1) for item in info["Config"]["Env"])
    assert environment.get("AUDIO_MODE") == "null", "requires null output"
    assert info["HostConfig"]["NetworkMode"] != "host", "host networking is not allowed"
    assert not info["HostConfig"].get("Devices"), "mapped devices are not allowed"
    assert info["State"]["Running"], "test container must be running"
    forwarded = ["--inside", "--format", args.format, "--label", args.label, "--stall-ms", str(args.stall_ms),
                 "--interval", str(args.interval), "--seconds", str(args.seconds)]
    return subprocess.run(["docker", "exec", "-i", container, "timeout", "--kill-after=5", "120", "python3", "-u", "-", *forwarded],
                          input=Path(__file__).read_bytes(), timeout=130).returncode


if __name__ == "__main__":
    sys.exit(main())
