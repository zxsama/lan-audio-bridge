#!/usr/bin/env python3
"""Single-process supervisor and fail-closed PulseAudio source arbitration.

Receivers never own the sound card. A single loopback is the only path from
their private buses to output. Only uncorked sink-input edges request ownership.
"""
from __future__ import annotations

import dataclasses
import json
import logging
import os
from pathlib import Path
import re
import signal
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
import uuid
from typing import Callable, Mapping

LOG = logging.getLogger("lan-audio")
SOURCES = ("airplay", "dlna", "spotify")  # First wins simultaneous activation.
RUN_DIR = Path("/run/lan-audio")
DATA_DIR = Path("/data")
PULSE_SERVER = "unix:/run/lan-audio/pulse.sock"
STATUS_PATH = RUN_DIR / "status.json"
POLL_SECONDS = 0.2


class BridgeError(RuntimeError):
    """Operational errors contain only safe, predetermined descriptions."""


@dataclasses.dataclass(frozen=True)
class Config:
    device_name: str = "NAS Audio"
    audio_mode: str = "alsa"
    audio_device: str = ""
    sample_rate: int = 48000
    output_volume: int = 70
    enabled: tuple[str, ...] = SOURCES
    interface: str = ""
    airplay_port: int = 7000
    dlna_port: int = 49494
    spotify_port: int = 24879
    avahi_mode: str = "internal"

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> Config:
        def number(key: str, default: int, lo: int, hi: int) -> int:
            value = env.get(key, str(default))
            if not re.fullmatch(r"[0-9]{1,6}", value) or not lo <= int(value) <= hi:
                raise BridgeError(f"{key} must be an integer in {lo}..{hi}")
            return int(value)

        enabled = []
        for source in SOURCES:
            key = "ENABLE_" + source.upper()
            value = env.get(key, "true").lower()
            if value not in ("true", "false"):
                raise BridgeError(f"{key} must be true or false")
            if value == "true":
                enabled.append(source)
        name = env.get("DEVICE_NAME", "NAS Audio")
        if (not name.strip() or len(name.encode("utf-8")) > 50
                or not re.fullmatch(r"[\w .()\-]+", name)):
            raise BridgeError("DEVICE_NAME must use letters, numbers, spaces, . _ - ( ); maximum 50 UTF-8 bytes")
        mode = env.get("AUDIO_MODE", "alsa")
        if mode not in ("alsa", "null"):
            raise BridgeError("AUDIO_MODE must be alsa or null")
        avahi_mode = env.get("AVAHI_MODE", "internal")
        if avahi_mode not in ("internal", "external"):
            raise BridgeError("AVAHI_MODE must be internal or external")
        device = env.get("AUDIO_DEVICE", "")
        if device or mode == "alsa":
            match = re.fullmatch(r"(?:plug)?hw:CARD=([A-Za-z0-9_-]{1,31}),DEV=([0-9]{1,3})(?:,SUBDEV=[0-9]{1,3})?", device)
            if not match or match[1].isdigit():
                raise BridgeError("AUDIO_DEVICE must use a stable named card: hw:CARD=NAME,DEV=N")
        interface = env.get("NETWORK_INTERFACE", "")
        if interface and not re.fullmatch(r"[A-Za-z0-9_.:-]{1,15}", interface):
            raise BridgeError("NETWORK_INTERFACE must be a Linux interface name")
        rate = number("SAMPLE_RATE", 48000, 8000, 192000)
        if rate not in (44100, 48000, 88200, 96000, 176400, 192000):
            raise BridgeError("SAMPLE_RATE must be 44100, 48000, 88200, 96000, 176400 or 192000")
        ports = {
            "airplay": number("AIRPLAY_PORT", 7000, 1024, 65535),
            "dlna": number("DLNA_PORT", 49494, 49152, 65535),
            "spotify": number("SPOTIFY_PORT", 24879, 1024, 65535),
        }
        if len({ports[source] for source in enabled}) != len(enabled):
            raise BridgeError("Enabled receiver ports must be distinct")
        return cls(name, mode, device, rate, number("OUTPUT_VOLUME", 70, 0, 100),
                   tuple(enabled), interface, ports["airplay"], ports["dlna"], ports["spotify"], avahi_mode)


def atomic_write(path: Path, text: str, mode: int = 0o600) -> None:
    temporary = path.with_name(path.name + ".tmp")
    # Do not follow an unexpected symlink in a persistent directory.
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), mode)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def persistent_uuid(directory: Path) -> str:
    path = directory / "dlna.uuid"
    if path.exists():
        if path.is_symlink():
            raise BridgeError("DLNA identity file must not be a symlink")
        try:
            return str(uuid.UUID(path.read_text(encoding="ascii").strip()))
        except (ValueError, UnicodeError):
            raise BridgeError("DLNA identity file is invalid; preserve or repair /data/dlna.uuid") from None
    value = str(uuid.uuid4())
    atomic_write(path, value + "\n")
    return value


def persistent_machine_id(directory: Path) -> str:
    path = directory / "dbus-machine-id"
    if path.exists():
        if path.is_symlink():
            raise BridgeError("D-Bus identity file must not be a symlink")
        try:
            value = path.read_text(encoding="ascii").strip()
        except UnicodeError:
            raise BridgeError("D-Bus identity file is invalid") from None
        if not re.fullmatch(r"[0-9a-f]{32}", value) or value == "0" * 32:
            raise BridgeError("D-Bus identity file is invalid")
        return value
    value = uuid.uuid4().hex
    atomic_write(path, value + "\n")
    return value


def interface_ipv4(name: str) -> str:
    """librespot 0.8 accepts an IP, whereas gmrender accepts an interface name."""
    import fcntl
    try:
        socket.if_nametoindex(name)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            result = fcntl.ioctl(sock.fileno(), 0x8915, struct.pack("256s", name.encode("ascii")))
        return socket.inet_ntoa(result[20:24])
    except OSError:
        raise BridgeError("NETWORK_INTERFACE must exist and have an IPv4 address") from None


def owns_udp_ports(pid: int, required: set[int]) -> bool:
    """Check this process's actual socket inodes, including in host networking.

    nqptp 1.2.9 creates shared memory lazily after Shairport's first message, so
    shared-memory existence cannot be used to start Shairport in dependency order.
    """
    try:
        sockets = set()
        for entry in (Path("/proc") / str(pid) / "fd").iterdir():
            try:
                target = os.readlink(entry)
            except FileNotFoundError:
                continue
            match = re.fullmatch(r"socket:\[([0-9]+)\]", target)
            if match:
                sockets.add(match[1])
        found = set()
        for family in ("udp", "udp6"):
            table = Path("/proc") / str(pid) / "net" / family
            if not table.exists():
                continue
            for row in table.read_text(encoding="ascii").splitlines()[1:]:
                fields = row.split()
                if len(fields) >= 10 and fields[9] in sockets:
                    found.add(int(fields[1].rsplit(":", 1)[1], 16))
        return required.issubset(found)
    except (OSError, ValueError):
        return False


def pulse_config(config: Config) -> str:
    lines = [".fail", "load-module module-native-protocol-unix socket=/run/lan-audio/pulse.sock auth-anonymous=1 auth-cookie-enabled=0"]
    for sink in (*[source + "_bus" for source in SOURCES], "discard"):
        lines.append(f"load-module module-null-sink sink_name={sink} rate={config.sample_rate} channels=2")
    if config.audio_mode == "null":
        lines.append(f"load-module module-null-sink sink_name=output rate={config.sample_rate} channels=2")
    else:
        lines.append(f"load-module module-alsa-sink sink_name=output device={config.audio_device} rate={config.sample_rate} channels=2")
    lines += ["set-default-sink discard", "set-default-source discard.monitor", "set-sink-mute output yes",
              # Pulse CLI uses integer software volume (65536 = 100%).
              f"set-sink-volume output {round(config.output_volume * 65536 / 100)}"]
    return "\n".join(lines) + "\n"


def shairport_config(config: Config, address: str = "") -> str:
    lines = ["general = {", f"  name = {json.dumps(config.device_name, ensure_ascii=False)};",
             '  output_backend = "pulseaudio";', '  mdns_backend = "avahi";',
             '  service_type = "airplay2";', f"  port = {config.airplay_port};"]
    if config.interface:
        lines += [f'  interface = "{config.interface}";', f'  address = "{address}";']
    lines += ["};", "pulseaudio = {", f'  server = "{PULSE_SERVER}";', '  sink = "airplay_bus";',
              '  output_channels = 2;', f"  output_rate = {config.sample_rate};", "};",
              'sessioncontrol = { allow_session_interruption = "yes"; };',
              'diagnostics = { log_verbosity = 0; };']
    return "\n".join(lines) + "\n"


def avahi_config(config: Config) -> str:
    lines = ["[server]", "use-ipv4=yes", "use-ipv6=no"]
    if config.interface:
        lines.append("allow-interfaces=" + config.interface)
    lines += ["[wide-area]", "enable-wide-area=no", "[publish]", "publish-addresses=yes",
              "publish-hinfo=no", "publish-workstation=no", "[reflector]", "enable-reflector=no"]
    return "\n".join(lines) + "\n"


def avahi_available(address: str = "unix:path=/run/dbus/system_bus_socket") -> bool:
    """Probe the configured bus without logging identities or D-Bus responses."""
    try:
        result = subprocess.run(
            ["dbus-send", "--bus=" + address, "--print-reply", "--reply-timeout=1500",
             "--dest=org.freedesktop.Avahi", "/", "org.freedesktop.Avahi.Server.GetVersionString"],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
        return result.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def receiver_commands(config: Config, identity: str, address: str = "") -> dict[str, list[str]]:
    commands = {
        "airplay": ["shairport-sync", "--configfile=/run/lan-audio/shairport.conf"],
        "dlna": ["gmediarender", "--friendly-name", config.device_name, "--uuid", identity,
                 "--port", str(config.dlna_port), "--gstout-audiosink", "pulsesink",
                 "--gstout-audiodevice", "dlna_bus"],
        "spotify": ["librespot", "--name", config.device_name, "--backend", "pulseaudio",
                    "--device", "spotify_bus", "--zeroconf-port", str(config.spotify_port),
                    "--cache", "/data/spotify", "--disable-audio-cache", "--initial-volume", "100", "--quiet"],
    }
    if config.interface:
        commands["dlna"] += ["--interface-name", config.interface]
        commands["spotify"] += ["--zeroconf-interface", address]
    return {name: commands[name] for name in config.enabled}


def child_environment(source: str | None = None) -> dict[str, str]:
    # In particular, do not pass LIBRESPOT_* overrides, tokens or verbose log flags.
    env = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
           "LANG": "C.UTF-8", "HOME": "/run/lan-audio", "PULSE_SERVER": PULSE_SERVER,
           "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=/run/dbus/system_bus_socket"}
    if source:
        env["PULSE_SINK"] = source + "_bus"
    return env


@dataclasses.dataclass(frozen=True)
class ProcessContext:
    env: dict[str, str]
    user: int
    group: int
    extra_groups: tuple[int, ...]


def pulse_context(uid: int, gid: int, audio_mode: str,
                  device_dir: Path = Path("/dev/snd")) -> ProcessContext:
    if uid == 0:
        raise BridgeError("PulseAudio requires a dedicated non-root user")
    groups = {gid}
    if audio_mode == "alsa":
        # Docker passes host device ownership through; its audio GID can differ
        # from the image's audio group. Grant only the passed sound device groups.
        for device in device_dir.iterdir():
            info = device.stat()
            if stat.S_ISCHR(info.st_mode):
                groups.add(info.st_gid)
    env = {"PATH": child_environment()["PATH"], "LANG": "C.UTF-8",
           "HOME": "/run/pulse/home", "XDG_RUNTIME_DIR": "/run/pulse/runtime"}
    # dbus-run-session supplies a private session bus. Neither the discovery
    # proxy nor receiver-specific Pulse client settings belong to this server.
    return ProcessContext(env, uid, gid, tuple(sorted(groups)))


@dataclasses.dataclass
class Snapshot:
    all_ids: dict[str, set[int]]
    active_ids: dict[str, set[int]]


class Pulse:
    def __init__(self, runner: Callable = subprocess.run):
        self.runner = runner
        self.route_module: int | None = None

    def command(self, *arguments: str) -> str:
        try:
            result = self.runner(["pactl", "--server=" + PULSE_SERVER, *arguments],
                                 capture_output=True, text=True, timeout=2, check=False,
                                 env=child_environment())
        except (OSError, subprocess.TimeoutExpired):
            raise BridgeError("PulseAudio control command unavailable or timed out") from None
        if result.returncode:
            # Never echo server output: properties can contain media URLs and metadata.
            raise BridgeError("PulseAudio control command failed")
        return result.stdout.strip()

    def listing(self, kind: str) -> list[dict]:
        try:
            value = json.loads(self.command("--format=json", "list", kind))
            if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
                raise ValueError()
            return value
        except (ValueError, TypeError):
            raise BridgeError("PulseAudio returned an invalid JSON inventory") from None

    def snapshot(self) -> Snapshot:
        try:
            sinks = {int(sink["index"]): sink["name"] for sink in self.listing("sinks")}
            required = {"output", "discard", *(source + "_bus" for source in SOURCES)}
            if not required.issubset(sinks.values()):
                raise BridgeError("Required PulseAudio sink disappeared")
            result = Snapshot({s: set() for s in SOURCES}, {s: set() for s in SOURCES})
            for stream in self.listing("sink-inputs"):
                sink = sinks.get(int(stream["sink"]))
                if sink == "output":
                    # PulseAudio 17 encodes owner_module as a decimal string even
                    # though index and sink are JSON numbers. Accept either exact
                    # integer representation, never null, bool, float or garbage.
                    module = stream.get("owner_module")
                    valid_module = (type(module) is int or
                                    (isinstance(module, str) and re.fullmatch(r"[0-9]{1,10}", module)))
                    if self.route_module is None or not valid_module or int(module) != self.route_module:
                        raise BridgeError("Unexpected direct output stream")
                if sink not in (source + "_bus" for source in SOURCES):
                    continue
                source = sink.removesuffix("_bus")
                index = int(stream["index"])
                corked = stream["corked"]
                if type(corked) is not bool:
                    raise ValueError()
                result.all_ids[source].add(index)
                if not corked:
                    result.active_ids[source].add(index)
            return result
        except (KeyError, TypeError, ValueError):
            raise BridgeError("PulseAudio stream inventory is incomplete") from None

    def clear(self) -> None:
        # Muting first also closes the route if unload fails. The caller exits on error.
        self.command("set-sink-mute", "output", "1")
        if self.route_module is not None:
            self.command("unload-module", str(self.route_module))
            self.route_module = None

    def route(self, source: str) -> None:
        if source not in SOURCES or self.route_module is not None:
            raise BridgeError("Invalid routing transition")
        try:
            module = self.command("load-module", "module-loopback", f"source={source}_bus.monitor",
                                  "sink=output", "latency_msec=100", "source_dont_move=true",
                                  "sink_dont_move=true", "channels=2", "remix=no")
            if not re.fullmatch(r"[0-9]+", module):
                raise BridgeError("PulseAudio did not return a routing module identifier")
            self.route_module = int(module)
            self.command("set-sink-mute", "output", "0")
        except BridgeError:
            try:
                self.clear()
            except BridgeError:
                pass
            raise


class Coordinator:
    def __init__(self, pulse: Pulse, preempt: Callable[[str], None], enabled: tuple[str, ...] = SOURCES):
        self.pulse = pulse
        self.preempt = preempt
        self.enabled = enabled
        self.owner: str | None = None
        self.previous = {source: set() for source in SOURCES}
        self.suppressed = {source: set() for source in SOURCES}

    def step(self, snapshot: Snapshot, blocked: set[str] | None = None) -> None:
        blocked = blocked or set()
        eligible = {}
        for source in SOURCES:
            self.suppressed[source].intersection_update(snapshot.all_ids[source])
            if source in blocked or source not in self.enabled:
                self.suppressed[source].update(snapshot.all_ids[source])
            eligible[source] = snapshot.active_ids[source] - self.suppressed[source]
        newcomers = [source for source in SOURCES if eligible[source] - self.previous[source]]
        winner = newcomers[0] if newcomers else self.owner
        if winner is not None and not eligible[winner]:
            winner = None
        if winner != self.owner:
            self.pulse.clear()
            old_owner = self.owner
            self.owner = None
            if winner is not None:
                # Suppress all currently losing streams, including simultaneous arrivals.
                # Retain their ids even when corked, until the actual stream disappears.
                for source in SOURCES:
                    if source != winner and snapshot.active_ids[source]:
                        self.suppressed[source].update(snapshot.all_ids[source])
                        eligible[source].clear()
                        if source in self.enabled and source not in blocked:
                            self.preempt(source)
                self.pulse.route(winner)
                self.owner = winner
            LOG.info("source transition %s -> %s", old_owner or "idle", self.owner or "idle")
        # A simultaneous newcomer can lose even if the highest-priority winner was
        # already owner. Stop it as well; it must not advance and reclaim next track.
        for source in newcomers:
            if winner is not None and source != winner and eligible[source]:
                self.suppressed[source].update(snapshot.all_ids[source])
                eligible[source].clear()
                self.preempt(source)
        self.previous = eligible


@dataclasses.dataclass
class Child:
    name: str
    argv: list[str]
    core: bool = False
    process: subprocess.Popen | None = None
    state: str = "pending"
    restarts: int = 0
    failures: int = 0
    exit_code: int | None = None
    started_at: float = 0
    next_start: float = 0
    deadline: float = 0
    context: ProcessContext | None = None


class Supervisor:
    def __init__(self, popen: Callable = subprocess.Popen, killpg: Callable | None = None):
        self.children: dict[str, Child] = {}
        self.popen = popen
        self.killpg = killpg or getattr(os, "killpg", None)
        self.shutting_down = False

    def add(self, name: str, argv: list[str], core: bool = False,
            context: ProcessContext | None = None) -> None:
        self.children[name] = Child(name, argv, core, context=context)

    def start(self, child: Child, now: float) -> None:
        try:
            context = child.context
            credentials = ({"user": context.user, "group": context.group,
                            "extra_groups": context.extra_groups} if context else {})
            child.process = self.popen(child.argv,
                                       env=context.env if context else child_environment(None if child.core else child.name),
                                       stdin=subprocess.DEVNULL,
                                       # Receiver diagnostics can contain account ids, signed URLs
                                       # or metadata. Only safe lifecycle events are logged here.
                                       stdout=None if child.core else subprocess.DEVNULL,
                                       stderr=None if child.core else subprocess.DEVNULL,
                                       start_new_session=True, **credentials)
            child.state = "running"
            child.started_at = now
            LOG.info("%s started", child.name)
        except OSError:
            child.process = None
            if child.core:
                raise BridgeError(f"Core service {child.name} could not start") from None
            self.schedule_failure(child, now)

    def schedule_failure(self, child: Child, now: float) -> None:
        child.failures = min(child.failures + 1, 6)
        delay = min(30, 2 ** (child.failures - 1))
        child.next_start = now + delay
        child.state = "backoff"
        LOG.warning("%s unavailable; retry in %s seconds (exit %s)", child.name, delay, child.exit_code)

    def signal_child(self, child: Child, signum: int) -> None:
        if child.process is not None:
            try:
                self.killpg(child.process.pid, signum)
            except ProcessLookupError:
                pass

    def preempt(self, source: str) -> None:
        child = self.children[source]
        if child.state != "running":
            return
        child.state = "stopping"
        child.deadline = time.monotonic() + 2
        self.signal_child(child, signal.SIGTERM)
        LOG.info("%s preempted; receiver restart scheduled", source)

    def tick(self, now: float) -> None:
        for child in self.children.values():
            if child.process is not None:
                exit_code = child.process.poll()
                if exit_code is not None:
                    child.exit_code = exit_code
                    # Also clean descendants that survived their group leader.
                    self.signal_child(child, signal.SIGKILL)
                    child.process = None
                    if self.shutting_down:
                        child.state = "stopped"
                    elif child.core:
                        raise BridgeError(f"Core service {child.name} exited")
                    elif child.state == "stopping":
                        child.state = "backoff"
                        child.next_start = now + 0.3
                    else:
                        self.schedule_failure(child, now)
                elif child.state == "stopping" and now >= child.deadline:
                    self.signal_child(child, signal.SIGKILL)
                    child.deadline = now + 1
                elif child.state == "running" and now - child.started_at >= 60:
                    child.failures = 0
            if not self.shutting_down and child.process is None and child.state in ("pending", "backoff") and now >= child.next_start:
                if child.state == "backoff":
                    child.restarts += 1
                self.start(child, now)

    def blocked_sources(self) -> set[str]:
        return {source for source in SOURCES if source not in self.children or self.children[source].state != "running"}

    def statuses(self) -> dict:
        return {name: {"state": c.state, "pid": c.process.pid if c.process else None,
                       "restarts": c.restarts, "exit_code": c.exit_code}
                for name, c in self.children.items()}

    def shutdown(self) -> None:
        self.shutting_down = True
        for child in reversed(list(self.children.values())):
            if child.process:
                child.state = "stopping"
                child.deadline = time.monotonic() + 3
                self.signal_child(child, signal.SIGTERM)
        until = time.monotonic() + 5
        while any(c.process for c in self.children.values()) and time.monotonic() < until:
            self.tick(time.monotonic())
            time.sleep(0.05)
        for child in self.children.values():
            if child.process:
                self.signal_child(child, signal.SIGKILL)
                try:
                    child.process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
                child.process = None
            child.state = "stopped"


class Runtime:
    def __init__(self, config: Config):
        self.config = config
        self.stop = threading.Event()
        self.supervisor = Supervisor()
        self.pulse = Pulse()
        self.coordinator = Coordinator(self.pulse, self.supervisor.preempt, config.enabled)
        self.state = "starting"
        self.lock_file = None
        self.lock_acquired = False
        self.next_avahi_probe = 0.0
        self.pulse_context: ProcessContext | None = None

    def write_status(self) -> None:
        status = {"schema": 1, "pid": os.getpid(), "heartbeat_unix": time.time(), "state": self.state,
                  "owner": self.coordinator.owner, "enabled": list(self.config.enabled),
                  "avahi_mode": self.config.avahi_mode,
                  "route_module": self.pulse.route_module, "children": self.supervisor.statuses()}
        atomic_write(STATUS_PATH, json.dumps(status, separators=(",", ":")) + "\n", 0o644)

    def prepare(self) -> None:
        import fcntl
        import pwd
        os.umask(0o077)
        RUN_DIR.mkdir(parents=True, exist_ok=True)
        self.lock_file = (RUN_DIR / "runtime.lock").open("a")
        try:
            fcntl.flock(self.lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.lock_acquired = True
        except BlockingIOError:
            raise BridgeError("Another bridge supervisor is already running") from None
        pulse_user = pwd.getpwnam("pulse")
        self.pulse_context = pulse_context(pulse_user.pw_uid, pulse_user.pw_gid, self.config.audio_mode)
        os.chown(RUN_DIR, pulse_user.pw_uid, pulse_user.pw_gid)
        os.chmod(RUN_DIR, 0o755)
        directories = [Path("/run/pulse")]
        if self.config.avahi_mode == "internal":
            directories += [Path("/run/dbus"), Path("/run/avahi-daemon")]
        for directory in directories:
            directory.mkdir(parents=True, exist_ok=True)
            os.chmod(directory, 0o755)
        for directory in (Path("/run/pulse/home"), Path("/run/pulse/runtime")):
            directory.mkdir(parents=True, exist_ok=True)
            os.chown(directory, pulse_user.pw_uid, pulse_user.pw_gid)
            os.chmod(directory, 0o700)
        DATA_DIR.mkdir(parents=True, exist_ok=True)
        cache = DATA_DIR / "spotify"
        if cache.is_symlink():
            raise BridgeError("Spotify cache directory must not be a symlink")
        cache.mkdir(mode=0o700, exist_ok=True)
        os.chmod(cache, 0o700)
        identity = persistent_uuid(DATA_DIR)
        atomic_write(RUN_DIR / "machine-id", persistent_machine_id(DATA_DIR) + "\n", 0o644)
        address = interface_ipv4(self.config.interface) if self.config.interface else ""
        # These paths are ephemeral and are only removed after the single-instance lock.
        paths = [RUN_DIR / "pulse.sock", Path("/run/pulse/pid")]
        if self.config.avahi_mode == "internal":
            paths += [Path("/run/dbus/system_bus_socket"), Path("/run/avahi-daemon/pid"),
                      Path("/run/avahi-daemon/socket")]
        for path in paths:
            path.unlink(missing_ok=True)
        atomic_write(RUN_DIR / "pulse.pa", pulse_config(self.config), 0o644)
        atomic_write(RUN_DIR / "shairport.conf", shairport_config(self.config, address), 0o600)
        atomic_write(RUN_DIR / "avahi.conf", avahi_config(self.config), 0o644)
        self.commands = receiver_commands(self.config, identity, address)
        self.write_status()

    def wait_ready(self, probe: Callable[[], bool], timeout: float = 12,
                   failure: str = "Core service readiness timed out") -> None:
        until = time.monotonic() + timeout
        while not self.stop.is_set() and time.monotonic() < until:
            self.supervisor.tick(time.monotonic())
            try:
                if probe():
                    return
            except BridgeError:
                pass
            self.write_status()
            self.stop.wait(0.1)
        if self.stop.is_set():
            raise InterruptedError()
        raise BridgeError(failure)

    def check_discovery(self, now: float) -> None:
        if self.config.avahi_mode == "external" and now >= self.next_avahi_probe:
            self.next_avahi_probe = now + 5
            if not avahi_available():
                raise BridgeError("External Avahi unavailable; check the discovery proxy and host Avahi")

    def start(self) -> None:
        if self.pulse_context is None:
            raise BridgeError("PulseAudio process context has not been prepared")
        if self.config.avahi_mode == "external":
            self.wait_ready(avahi_available, failure="External Avahi unavailable; mount the filtered D-Bus socket and check host Avahi")
            self.next_avahi_probe = time.monotonic() + 5
        else:
            self.supervisor.add("dbus", ["dbus-daemon", "--system", "--nofork", "--nopidfile",
                                         "--address=unix:path=/run/dbus/system_bus_socket"], core=True)
            self.wait_ready(lambda: Path("/run/dbus/system_bus_socket").exists())
            self.supervisor.add("avahi", ["avahi-daemon", "--no-drop-root", "--no-chroot", "--no-rlimits",
                                          "--file=/run/lan-audio/avahi.conf"], core=True)
            self.wait_ready(lambda: Path("/run/avahi-daemon/socket").exists())
        self.supervisor.add("pulse", ["dbus-run-session", "--", "pulseaudio", "--daemonize=no", "--disallow-exit",
                                      "--exit-idle-time=-1", "--use-pid-file=no", "--log-target=stderr",
                                      "--log-level=notice", "--realtime=no", "--high-priority=no",
                                      "--disable-shm=yes", "-n", "--file=/run/lan-audio/pulse.pa"],
                            core=True, context=self.pulse_context)
        self.wait_ready(lambda: bool(self.pulse.snapshot()))
        self.pulse.clear()
        if "airplay" in self.config.enabled:
            # Shared memory is lazily recreated when Shairport first contacts nqptp.
            Path("/dev/shm/nqptp").unlink(missing_ok=True)
            self.supervisor.add("nqptp", ["nqptp"], core=True)
            self.wait_ready(lambda: owns_udp_ports(self.supervisor.children["nqptp"].process.pid,
                                                   {319, 320, 9000}))
        for source, argv in self.commands.items():
            self.supervisor.add(source, argv)
        self.supervisor.tick(time.monotonic())

    def run(self) -> int:
        for signum in (signal.SIGTERM, signal.SIGINT):
            signal.signal(signum, lambda _signum, _frame: self.stop.set())
        failed = False
        try:
            self.prepare()
            self.start()
            while not self.stop.is_set():
                begin = time.monotonic()
                self.supervisor.tick(begin)
                self.check_discovery(begin)
                self.coordinator.step(self.pulse.snapshot(), self.supervisor.blocked_sources())
                self.state = "playing" if self.coordinator.owner else "idle"
                self.write_status()
                self.stop.wait(max(0, POLL_SECONDS - (time.monotonic() - begin)))
        except InterruptedError:
            pass
        except Exception as exc:
            failed = True
            # BridgeError messages are curated; OS errors can carry private paths.
            LOG.error("%s", str(exc) if isinstance(exc, BridgeError) else "Runtime filesystem or process operation failed")
        finally:
            self.state = "failed" if failed else "stopping"
            if self.lock_acquired:
                try:
                    self.pulse.clear()
                except BridgeError:
                    pass
            self.coordinator.owner = None
            self.supervisor.shutdown()
            self.state = "failed" if failed else "stopped"
            if self.lock_acquired:
                try:
                    self.write_status()
                except OSError:
                    pass
            if self.lock_file is not None:
                self.lock_file.close()
        return 1 if failed else 0


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
    try:
        config = Config.from_env(os.environ)
    except BridgeError as exc:
        LOG.error("%s", exc)
        return 2
    return Runtime(config).run()


if __name__ == "__main__":
    raise SystemExit(main())
