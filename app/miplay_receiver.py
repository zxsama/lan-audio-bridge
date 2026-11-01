#!/usr/bin/env python3
"""MiPlay/WFD AAC receiver -> bounded PCM stream -> the miplay Pulse bus.

The MIT protocol implementation is pinned under vendor/castfabric_miplay.
Discovery uses the existing Avahi D-Bus service, never a second mDNS socket.
Only the upstream mDNS/TCP discovery path is implemented; no CoAP responder
or legacy UDP 5355 discovery is claimed.
"""
from __future__ import annotations

import argparse
import asyncio
import contextlib
import ipaddress
import logging
import os
import re
import signal
import socket
import uuid

LOG = logging.getLogger("miplay")
PULSE_SERVER = "unix:/run/lan-audio/pulse.sock"


async def stop_process(process, timeout: float = 2.0) -> None:
    """Reap a child even if its output endpoint is no longer responding."""
    if process is None:
        return
    if process.stdin is not None:
        with contextlib.suppress(BrokenPipeError, ConnectionResetError):
            process.stdin.close()
    try:
        await asyncio.wait_for(process.wait(), timeout)
    except asyncio.TimeoutError:
        with contextlib.suppress(ProcessLookupError):
            process.terminate()
        try:
            await asyncio.wait_for(process.wait(), timeout)
        except asyncio.TimeoutError:
            with contextlib.suppress(ProcessLookupError):
                process.kill()
            await process.wait()


class PulsePcmSink:
    """Open Pulse only on actual PCM, keeping idle handshakes inaudible/inactive."""

    def __init__(self, sink: str = "miplay_bus", max_volume: int = 100):
        if not re.fullmatch(r"[A-Za-z0-9_]+", sink):
            raise ValueError("invalid Pulse sink")
        if not 0 <= max_volume <= 100:
            raise ValueError("volume limit must be 0..100")
        self.sink = sink
        self.max_volume = max_volume
        self.volume = max_volume
        self.process = None
        self.started = False

    async def start(self, sample_rate: int, channels: int, sample_width: int) -> None:
        if (sample_rate, channels, sample_width) != (48000, 2, 2):
            raise ValueError("MiPlay output must be 48 kHz stereo s16le")
        self.started = True

    async def write(self, data: bytes) -> None:
        if not self.started:
            raise RuntimeError("PCM sink is not started")
        if not data:
            return
        if self.process is None:
            self.process = await asyncio.create_subprocess_exec(
                "pacat", "--playback", "--raw", "--format=s16le", "--rate=48000",
                "--channels=2", "--latency-msec=200", "--process-time-msec=20",
                "--client-name=lan-audio-miplay", "--stream-name=MiPlay PCM",
                "--device=" + self.sink,
                "--server=" + os.environ.get("PULSE_SERVER", PULSE_SERVER),
                "--volume=" + str(round(self.volume * 65536 / 100)),
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL,
                stderr=asyncio.subprocess.DEVNULL,
            )
        if self.process.returncode is not None:
            raise RuntimeError("Pulse playback process exited")
        self.process.stdin.write(data)
        await asyncio.wait_for(self.process.stdin.drain(), timeout=3)

    async def stop(self) -> None:
        self.started = False
        process, self.process = self.process, None
        await stop_process(process)


class PulseVolume:
    """Bound phone volume on the dedicated input bus, preserving output gain."""

    def __init__(self, sink: str, maximum: int):
        self.sink, self.maximum = sink, maximum
        self.value = maximum

    async def set(self, requested: int) -> None:
        value = max(0, min(int(requested), self.maximum))
        process = await asyncio.create_subprocess_exec(
            "pactl", "--server=" + os.environ.get("PULSE_SERVER", PULSE_SERVER),
            "set-sink-volume", self.sink, str(round(value * 65536 / 100)),
            stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            await asyncio.wait_for(process.wait(), timeout=3)
            if process.returncode:
                raise RuntimeError("cannot set MiPlay input volume")
            self.value = value
        finally:
            await stop_process(process)


class AvahiPublisher:
    """Use only EntryGroup APIs allowed by the existing filtered D-Bus proxy."""

    def __init__(self, identity, interface: str = ""):
        self.identity, self.interface = identity, interface
        self.bus = self.group = None

    def _register(self) -> None:
        import dbus  # Debian python3-dbus; deliberately optional for offline tests.

        self.bus = dbus.bus.BusConnection(os.environ.get(
            "DBUS_SYSTEM_BUS_ADDRESS", "unix:path=/run/dbus/system_bus_socket"))
        server = dbus.Interface(self.bus.get_object("org.freedesktop.Avahi", "/"),
                                "org.freedesktop.Avahi.Server")
        group_path = server.EntryGroupNew(timeout=3)
        self.group = dbus.Interface(self.bus.get_object("org.freedesktop.Avahi", group_path),
                                   "org.freedesktop.Avahi.EntryGroup")
        info = self.identity.service_info()  # Data construction only; no Zeroconf socket.
        txt = dbus.Array([dbus.ByteArray(key + b"=" + value)
                          for key, value in info.properties.items()], signature="ay")
        interface_index = socket.if_nametoindex(self.interface) if self.interface else -1
        host = self.identity.host.rstrip(".") + ".local"
        # A dedicated name ensures Avahi's SRV target resolves to the selected
        # control address even on a multihomed host; no reverse PTR is needed.
        self.group.AddAddress(interface_index, 0, dbus.UInt32(16), host,
                              self.identity.address, timeout=3)
        self.group.AddService(interface_index, 0, dbus.UInt32(0), self.identity.instance,
                              "_mi-connect._udp", "", host, dbus.UInt16(info.port), txt,
                              timeout=3)
        self.group.Commit(timeout=3)

    async def start(self) -> None:
        try:
            await asyncio.to_thread(self._register)
            for _ in range(40):
                state = int(await asyncio.to_thread(self.group.GetState, timeout=3))
                if state == 2:  # AVAHI_ENTRY_GROUP_ESTABLISHED
                    return
                if state in (3, 4):
                    raise RuntimeError("MiPlay discovery registration failed")
                await asyncio.sleep(0.1)
            raise RuntimeError("MiPlay discovery registration timed out")
        except BaseException:
            await self.stop()
            raise

    async def healthy(self) -> bool:
        return self.group is not None and int(await asyncio.to_thread(
            self.group.GetState, timeout=3)) == 2

    async def stop(self) -> None:
        if self.group is not None:
            with contextlib.suppress(Exception):
                await asyncio.to_thread(self.group.Free, timeout=3)
            self.group = None
        if self.bus is not None:
            self.bus.close()
            self.bus = None


def choose_address(address: str, interface: str) -> str:
    if not address and interface:
        # Reuse the runtime's Linux interface lookup; it performs no network I/O.
        from runtime import interface_ipv4
        address = interface_ipv4(interface)
    if not address:
        # UDP connect selects a route without sending a packet.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect(("192.0.2.1", 9))
            address = probe.getsockname()[0]
    parsed = ipaddress.IPv4Address(address)
    if parsed.is_unspecified or parsed.is_multicast or parsed.is_loopback:
        raise ValueError("MiPlay needs a LAN IPv4 address")
    return str(parsed)


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--identity", required=True, type=uuid.UUID)
    parser.add_argument("--interface", default="")
    parser.add_argument("--address", default="")
    parser.add_argument("--port", type=int, default=8899)
    parser.add_argument("--sink", default="miplay_bus")
    parser.add_argument("--max-volume", type=int, default=100)
    result = parser.parse_args(argv)
    if not 1 <= result.port <= 65535:
        parser.error("port must be 1..65535")
    if not 0 <= result.max_volume <= 100:
        parser.error("max-volume must be 0..100")
    if not result.name or len(result.name.encode("utf-8")) > 200 or any(
            ord(character) < 32 for character in result.name):
        parser.error("name must be 1..200 UTF-8 bytes without control characters")
    PulsePcmSink(result.sink, result.max_volume)  # Validate before publishing.
    return result


async def run(options, stopped: asyncio.Event | None = None) -> None:
    from vendor.castfabric_miplay.mdns import MiPlayIdentity
    from vendor.castfabric_miplay.receiver import MiPlayReceiver

    address = choose_address(options.address, options.interface)
    identity = MiPlayIdentity(address=address, friendly_name=options.name,
                             instance="lan-audio-" + options.identity.hex,
                             host="lan-audio-" + options.identity.hex,
                             device_id=options.identity, control_port=options.port)
    volume = PulseVolume(options.sink, options.max_volume)
    # Apply maximum once on the source bus, not on the physical output.
    await volume.set(options.max_volume)
    sinks: set[PulsePcmSink] = set()

    def sink_factory():
        # Source bus owns gain, so the stream itself stays at unity (no double gain).
        sink = PulsePcmSink(options.sink)
        sinks.add(sink)
        return sink

    receiver = MiPlayReceiver(host=address, port=options.port, identity=identity,
                             advertise=False, sink_factory=sink_factory,
                             volume_setter=volume.set, initial_volume=options.max_volume,
                             max_volume=options.max_volume)
    publisher = AvahiPublisher(identity, options.interface)
    stopped = stopped or asyncio.Event()
    loop = asyncio.get_running_loop()
    for signum in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(signum, stopped.set)
    try:
        await receiver.start()
        await publisher.start()
        LOG.info("MiPlay receiver ready (mDNS/TCP; experimental sender compatibility)")
        while not stopped.is_set():
            try:
                await asyncio.wait_for(stopped.wait(), timeout=2)
            except asyncio.TimeoutError:
                if not await publisher.healthy():
                    raise RuntimeError("MiPlay discovery is unavailable")
            sinks.difference_update(sink for sink in tuple(sinks) if not sink.started)
    finally:
        await publisher.stop()
        await receiver.stop()
        await asyncio.gather(*(sink.stop() for sink in sinks), return_exceptions=True)


def main(argv=None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(name)s: %(message)s")
    try:
        asyncio.run(run(arguments(argv)))
        return 0
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        LOG.error("MiPlay receiver failed (%s)", type(exc).__name__)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
