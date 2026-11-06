#!/usr/bin/env python3
"""Small MIT-licensed VBAN PCM receiver; no third-party receiver code.

Wire layout: VB-Audio's public AUDIO PCM protocol, revision 13, pages 6-11:
https://vb-audio.com/Voicemeeter/VBANProtocol_Specifications.pdf
Only 48000 Hz, stereo signed little-endian 16-bit PCM is accepted.
"""
from __future__ import annotations

import argparse
from collections import Counter, deque
from dataclasses import dataclass
import ipaddress
import json
import logging
import os
from pathlib import Path
import select
import signal
import socket
import struct
import subprocess
import time
import uuid

LOG = logging.getLogger("vban")
HEADER = struct.Struct("<4sBBBB16sI")
RATE = 48000
FRAME_BYTES = 4
BYTE_RATE = RATE * FRAME_BYTES
MAX_QUEUE_SECONDS = 0.5


class ReceiverError(RuntimeError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


def stream_bytes(name: str) -> bytes:
    raw = name.encode("utf-8")
    if not raw or len(raw) > 16 or b"\0" in raw:
        raise ValueError("stream name must contain 1-16 UTF-8 bytes without NUL")
    return raw


@dataclass(frozen=True)
class Packet:
    sequence: int
    pcm: bytes


def parse_packet(data: bytes, expected_name: bytes) -> Packet:
    if len(data) < HEADER.size:
        raise ValueError("short header")
    magic, sample_rate, samples, channels, encoding, name, sequence = HEADER.unpack_from(data)
    # Equality also rejects other subprotocols, codecs and reserved flag bits.
    if magic != b"VBAN" or sample_rate != 3 or channels != 1 or encoding != 1:
        raise ValueError("unsupported header")
    if name.split(b"\0", 1)[0] != expected_name:
        raise ValueError("unmatched stream")
    if len(data) != HEADER.size + (samples + 1) * FRAME_BYTES:
        raise ValueError("invalid PCM length")
    return Packet(sequence, data[HEADER.size:])


class Stream:
    """Deterministic input/queue state, using monotonic seconds throughout."""

    def __init__(self, source_ip: str, name: str, idle_ms: int = 500):
        self.source_ip = str(ipaddress.IPv4Address(source_ip))
        self.name = stream_bytes(name)
        self.idle_seconds = idle_ms / 1000
        self.sequence = None
        self.last_valid = None
        self.last_nonzero = None
        self.active = False
        self.generation = ""
        self.started_at = 0.0
        self.playback_started = False
        self.queue = deque()
        self.queued_bytes = 0
        self.statistics = Counter()
        self.error_code = None

    def clear_queue(self):
        self.queue.clear()
        self.queued_bytes = 0

    def stop(self):
        self.active = False
        self.clear_queue()

    def ending(self, now: float) -> bool:
        return self.active and (
            now - self.last_valid >= self.idle_seconds
            or now - self.last_nonzero >= self.idle_seconds)

    def _append(self, pcm: bytes, now: float):
        self.queue.append((now, pcm))
        self.queued_bytes += len(pcm)
        self.trim(now)

    def trim(self, now: float):
        while self.queue and (self.queued_bytes > BYTE_RATE * MAX_QUEUE_SECONDS
                              or (self.playback_started
                                  and now - self.queue[0][0] > MAX_QUEUE_SECONDS)):
            _, discarded = self.queue.popleft()
            self.queued_bytes -= len(discarded)
            self.statistics["queue_dropped_bytes"] += len(discarded)

    def consume(self, count: int):
        stamp, pcm = self.queue.popleft()
        self.queued_bytes -= count
        if count < len(pcm):
            self.queue.appendleft((stamp, pcm[count:]))

    def receive(self, data: bytes, source_ip: str, now: float) -> bool:
        if source_ip != self.source_ip:
            self.statistics["wrong_source"] += 1
            return False
        try:
            packet = parse_packet(data, self.name)
        except ValueError:
            self.statistics["invalid_packets"] += 1
            return False
        # A timed-out sender may restart its counter at zero. Rejected traffic
        # never advances this deadline or keeps the route awake.
        if self.last_valid is not None and now - self.last_valid >= self.idle_seconds:
            self.sequence = None
        gap = 0
        if self.sequence is not None:
            delta = (packet.sequence - self.sequence) & 0xFFFFFFFF
            if delta == 0:
                self.statistics["duplicates"] += 1
                return False
            if delta >= 0x80000000:
                self.statistics["out_of_order"] += 1
                return False
            gap = delta - 1
        self.sequence = packet.sequence
        self.last_valid = now
        self.statistics["accepted_packets"] += 1
        nonzero = any(packet.pcm)
        if nonzero:
            self.last_nonzero = now
            if not self.active:
                self.active = True
                self.generation = str(uuid.uuid4())
                self.started_at = now
                self.playback_started = False
                self.statistics["sessions"] += 1
        if not self.active or self.ending(now):
            return True
        if gap:
            self.statistics["missing_packets"] += gap
            missing_bytes = gap * len(packet.pcm)
            # Conceal at most 20 ms; never allocate from an untrusted counter.
            if missing_bytes <= BYTE_RATE // 50:
                self._append(bytes(missing_bytes), now)
            else:
                self.statistics["discontinuities"] += 1
                self.clear_queue()
        self._append(packet.pcm, now)
        return True


class PulsePlayer:
    def __init__(self, sink: str, latency_ms: int):
        self.process = subprocess.Popen(
            ["pacat", "--playback", "--raw", "--format=s16le", "--rate=48000",
             "--channels=2", f"--device={sink}", f"--latency-msec={latency_ms}",
             "--client-name=LAN Audio Bridge VBAN", "--stream-name=Windows desktop"],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, bufsize=0)
        try:
            os.set_blocking(self.process.stdin.fileno(), False)
            # Linux pipe capacity is otherwise another large, hidden PCM queue.
            import fcntl
            fcntl.fcntl(self.process.stdin.fileno(), fcntl.F_SETPIPE_SZ, 4096)
        except Exception:
            self.close()
            raise

    def check(self):
        code = self.process.poll()
        if code is not None:
            raise ReceiverError("player_exit", f"pacat exited unexpectedly ({code})")

    def write(self, pcm: bytes) -> int:
        self.check()
        try:
            count = os.write(self.process.stdin.fileno(), pcm)
        except BlockingIOError:
            return 0
        if count <= 0 or count % FRAME_BYTES:
            raise ReceiverError("player_write", "pacat pipe returned an incomplete PCM frame")
        return count

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=0.5)
        if self.process.stdin:
            self.process.stdin.close()


def route_ready(path: Path, generation: str, now=None) -> bool:
    try:
        status = json.loads(path.read_text(encoding="utf-8"))
        desktop = status["desktop"]
        module = desktop.get("route_module")
        age = (time.time() if now is None else now) - status["heartbeat_unix"]
        return (0 <= age <= 2 and status.get("state") == "playing"
                and desktop.get("enabled") is True and desktop.get("active") is True
                and desktop.get("generation") == generation
                and type(module) is int and module >= 0)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return False


def publish(path: Path, stream: Stream):
    state = {"schema": 1, "enabled": True, "active": stream.active,
             "generation": stream.generation, "updated_at": time.time(),
             "receiver_pid": os.getpid(), "statistics": dict(stream.statistics),
             "error_code": stream.error_code,
             "queued_ms": round(stream.queued_bytes / BYTE_RATE * 1000, 2)}
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(state) + "\n", encoding="utf-8")
    temporary.replace(path)


class Playback:
    """Nonblocking PCM pump with a route handshake and bounded catch-up."""

    def __init__(self, stream: Stream, sink: str, latency_ms: int, runtime_status: Path,
                 player_factory=PulsePlayer, ready_check=route_ready, buffer_ms=20,
                 route_latency_ms=50):
        self.stream = stream
        self.sink = sink
        self.latency_ms = latency_ms
        self.buffer_ms = buffer_ms
        self.drain_seconds = (latency_ms + route_latency_ms + 50) / 1000
        self.last_nonzero_write = None
        self.runtime_status = runtime_status
        self.player_factory = player_factory
        self.ready_check = ready_check
        self.player = None
        self.next_write = 0.0
        self.blocked_since = None

    def close(self):
        if self.player:
            try:
                self.player.close()
            finally:
                self.player = None

    def tick(self, now: float):
        stream = self.stream
        stream.trim(now)
        if not stream.active:
            self.close()
            return
        ready = self.ready_check(self.runtime_status, stream.generation)
        if self.player and not ready:
            raise ReceiverError("route_lost", "desktop route acknowledgement was lost")
        if stream.ending(now) and not stream.queue:
            # Route/client buffers may outlast the input idle timeout. Preserve
            # the last audible tail without producing new silence indefinitely.
            if self.last_nonzero_write is None or now >= self.last_nonzero_write + self.drain_seconds:
                self.close()
                stream.stop()
                return
        if not self.player:
            if now - stream.started_at > 2:
                raise ReceiverError("route_timeout", "desktop route acknowledgement timed out")
            if not ready:
                return
            if now - stream.started_at < self.buffer_ms / 1000:
                return
            self.player = self.player_factory(self.sink, self.latency_ms)
            stream.playback_started = True
            # Startup retains a short notification for the full ACK deadline,
            # still byte-bounded; its realtime age begins when playback starts.
            stream.queue = deque((now, pcm) for _, pcm in stream.queue)
            self.next_write = now
            self.blocked_since = None
            self.last_nonzero_write = None
        self.player.check()
        # A bounded batch also handles legal packets carrying only one sample.
        # Each <=1024-byte write is atomic on Linux; catch-up is capped at 10 ms.
        for _ in range(64):
            if now < self.next_write:
                return
            filling = not stream.queue
            if filling and stream.ending(now):
                return
            # Keep a short notification flowing through Pulse's prebuffer even
            # when its sender sends no more packets. This does not refresh the
            # packet/nonzero timers and cannot wake an idle route.
            pcm = bytes(960) if filling else stream.queue[0][1][:1024]
            written = self.player.write(pcm)
            if not written:
                stream.statistics["backpressure"] += 1
                if self.blocked_since is None:
                    self.blocked_since = now
                elif now - self.blocked_since >= MAX_QUEUE_SECONDS:
                    raise ReceiverError("player_backpressure", "pacat pipe remained blocked")
                return
            self.blocked_since = None
            if filling:
                stream.statistics["underrun_fill_bytes"] += written
            else:
                if any(pcm[:written]):
                    self.last_nonzero_write = now
                stream.consume(written)
            stream.statistics["played_bytes"] += written
            self.next_write = max(self.next_write, now - 0.01) + written / BYTE_RATE


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=6980)
    parser.add_argument("--source-ip", required=True)
    parser.add_argument("--stream-name", default="Windows")
    parser.add_argument("--sink", default="desktop_bus")
    parser.add_argument("--latency-ms", type=int, default=30)
    parser.add_argument("--buffer-ms", type=int, default=20,
                        help="initial receiver jitter buffer, independent of loopback latency")
    parser.add_argument("--route-latency-ms", type=int, default=50,
                        help="desktop loopback target used to preserve the final audio tail")
    parser.add_argument("--idle-ms", type=int, default=500)
    parser.add_argument("--state-path", type=Path, default=Path("/run/lan-audio/desktop.json"))
    parser.add_argument("--runtime-status", type=Path, default=Path("/run/lan-audio/status.json"))
    args = parser.parse_args(argv)
    try:
        args.bind = str(ipaddress.IPv4Address(args.bind))
        source = ipaddress.IPv4Address(args.source_ip)
        if source.is_unspecified or source.is_multicast or int(source) == 0xFFFFFFFF:
            raise ValueError("source-ip must be a unicast IPv4 address")
        args.source_ip = str(source)
        stream_bytes(args.stream_name)
        if not 1 <= args.port <= 65535:
            raise ValueError("port must be 1-65535")
        if not 5 <= args.latency_ms <= 200:
            raise ValueError("latency-ms must be 5-200")
        if not 5 <= args.buffer_ms <= 200:
            raise ValueError("buffer-ms must be 5-200")
        if not 20 <= args.route_latency_ms <= 500:
            raise ValueError("route-latency-ms must be 20-500")
        if not 200 <= args.idle_ms <= 5000:
            raise ValueError("idle-ms must be 200-5000")
    except ValueError as error:
        parser.error(str(error))
    return args


def run(args):
    stream = Stream(args.source_ip, args.stream_name, args.idle_ms)
    playback = Playback(stream, args.sink, args.latency_ms, args.runtime_status,
                        buffer_ms=args.buffer_ms, route_latency_ms=args.route_latency_ms)
    args.state_path.parent.mkdir(parents=True, exist_ok=True)
    stopping = False

    def stop_signal(signum, frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop_signal)
    signal.signal(signal.SIGINT, stop_signal)
    last_publish = 0.0
    last_active = None
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
            udp.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 256 * 1024)
            udp.bind((args.bind, args.port))
            udp.setblocking(False)
            LOG.info("listening on %s:%d for configured desktop source", args.bind, args.port)
            while not stopping:
                readable, _, _ = select.select([udp], [], [], 0.001)
                if readable:
                    # Cap each receive batch so floods cannot starve PCM/timers.
                    for _ in range(64):
                        try:
                            data, address = udp.recvfrom(2048)
                        except BlockingIOError:
                            break
                        stream.receive(data, address[0], time.monotonic())
                now = time.monotonic()
                # Advertise intent before asking for the route, not after PCM.
                if stream.active != last_active or now - last_publish >= 0.1:
                    publish(args.state_path, stream)
                    last_active = stream.active
                    last_publish = now
                playback.tick(now)
    except Exception as error:
        stream.error_code = error.code if isinstance(error, ReceiverError) else "receiver_failure"
        raise
    finally:
        try:
            playback.close()
        finally:
            stream.stop()
            publish(args.state_path, stream)


def main():
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        run(arguments())
    except Exception:
        LOG.exception("VBAN receiver stopped")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
