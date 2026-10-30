"""Observe idle MiPlay presence from an independent isolated Docker container.

Start compose.test.yaml separately, then run: python tests/miplay_presence.py
No OPEN command or media is sent. This does not validate a phone's discovery UI.
"""
import argparse
import asyncio
from concurrent.futures import ThreadPoolExecutor
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid


NETWORK = "lan-audio-bridge-test_default"
PROJECT = "lan-audio-bridge-test"


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(*arguments):
    return subprocess.check_output(arguments, text=True, timeout=20).strip()


def snapshot():
    """Read target process/Pulse state; never initialize an audio stream."""
    playback = []
    receivers = []
    for path in Path("/proc").glob("[0-9]*/comm"):
        try:
            name = path.read_text().strip()
            arguments = (path.parent / "cmdline").read_bytes().split(b"\0")
            if name in {"pacat", "ffmpeg"}:
                playback.append(int(path.parent.name))
            if any(value.endswith(b"/miplay_receiver.py") for value in arguments):
                receivers.append(int(path.parent.name))
        except FileNotFoundError:
            continue
    inputs = json.loads(command("pactl", "--server=unix:/run/lan-audio/pulse.sock",
                                "--format=json", "list", "sink-inputs"))
    outputs = [entry["index"] for entry in inputs
               if entry.get("properties", {}).get("application.name") == "lan-audio-miplay"
               or entry.get("properties", {}).get("media.name") == "MiPlay PCM"]
    return {"receiver_pids": sorted(receivers), "playback_pids": sorted(playback),
            "miplay_sink_inputs": outputs}


async def observe(options):
    # The observer runs the image's own pinned protocol code, from /app.
    sys.path.insert(0, "/app")
    from vendor.castfabric_miplay.mdns import scan_miplay
    from vendor.castfabric_miplay.protocol import (
        Command, decode_scalar, encode_command, legacy_challenge_response,
    )
    from vendor.castfabric_miplay.simulator import _CommandChannel

    async def discover():
        # Each scan creates a fresh Zeroconf instance: a previous cached result
        # must not hide a receiver that has stopped answering discovery queries.
        devices = await asyncio.to_thread(scan_miplay, 3)
        matches = [device for device in devices
                   if device.address == options.target_ip
                   and device.friendly_name == options.device_name]
        require(len(matches) == 1, "Expected one freshly resolved target MiPlay service")
        device = matches[0]
        require(device.supports_audio and device.control_port == options.target_port,
                "MiPlay advertisement no longer matches the control endpoint")
        return device

    async def close(writer):
        writer.close()
        try:
            await asyncio.wait_for(writer.wait_closed(), 2)
        except (ConnectionError, asyncio.TimeoutError):
            pass

    async def exchange(channel, request, response, sequence):
        async with asyncio.timeout(5):
            await channel.send(encode_command(request, sequence))
            frame = await channel.read()
            while frame.command == Command.NOTIFY:
                frame = await channel.read()
        require(frame.command == response and frame.sequence == sequence,
                f"Unexpected MiPlay reply to {request.name}")
        return frame

    first = await discover()
    reader, writer = await asyncio.wait_for(
        asyncio.open_connection(first.address, first.control_port), 5)
    channel = _CommandChannel(reader, writer)
    try:
        challenge = await asyncio.wait_for(channel.read(), 5)
        require(challenge.command == Command.LEGACY_CHALLENGE, "Expected legacy challenge")
        await asyncio.wait_for(channel.send(
            encode_command(Command.SOURCE_VERSION, 0, b"1.0.1123012\0"),
            encode_command(Command.LEGACY_CHALLENGE_ACK, challenge.sequence,
                           legacy_challenge_response(challenge.payload))), 5)
        version = await asyncio.wait_for(channel.read(), 5)
        require(version.command == Command.SOURCE_VERSION_ACK, "Legacy version exchange failed")
        await exchange(channel, Command.HEARTBEAT, Command.HEARTBEAT_ACK, 1)
        started = time.monotonic()
        next_discovery = started
        samples = []
        discoveries = 1
        sequence = 2
        while True:
            await exchange(channel, Command.HEARTBEAT, Command.HEARTBEAT_ACK, sequence)
            sequence += 1
            state = await exchange(channel, Command.GET_STATE, Command.GET_STATE_ACK, sequence)
            sequence += 1
            require(decode_scalar(state.payload) == 0, "Idle MiPlay state is not 0")
            samples.append(round(time.monotonic() - started, 3))
            if time.monotonic() >= next_discovery:
                device = await discover()
                require(device.instance_name == first.instance_name
                        and device.device_id == first.device_id,
                        "MiPlay discovery identity changed")
                probe_reader, probe_writer = await asyncio.wait_for(
                    asyncio.open_connection(device.address, device.control_port), 5)
                try:
                    probe = await asyncio.wait_for(_CommandChannel(probe_reader, probe_writer).read(), 5)
                    require(probe.command == Command.LEGACY_CHALLENGE,
                            "New control connection did not receive a challenge")
                finally:
                    await close(probe_writer)
                discoveries += 1
                next_discovery = time.monotonic() + 2
            if samples[-1] >= options.duration:
                break
            await asyncio.sleep(min(1, max(0, options.duration - (time.monotonic() - started))))
        return {"authenticated_seconds": samples[-1], "idle_state": 0,
                "control_samples": len(samples), "fresh_mdns_resolutions": discoveries,
                "service": first.instance_name, "open_commands_sent": 0}
    finally:
        await close(writer)


def inspect_target(container):
    info = json.loads(command("docker", "inspect", container))[0]
    environment = dict(value.split("=", 1) for value in info["Config"]["Env"])
    host = info["HostConfig"]
    labels = info["Config"].get("Labels", {})
    require(labels.get("com.docker.compose.project") == PROJECT
            and labels.get("com.docker.compose.service") == "audio", "Expected isolated test audio service")
    config_files = labels.get("com.docker.compose.project.config_files", "").replace("\\", "/").split(",")
    require(len(config_files) == 1 and config_files[0].rsplit("/", 1)[-1] == "compose.test.yaml",
            "Only standalone compose.test.yaml is permitted")
    require(environment.get("AUDIO_MODE") == "null"
            and environment.get("ENABLE_MIPLAY") == "true", "Expected enabled MiPlay with null output")
    require(not any(host.get(key) for key in
                    ("Privileged", "Devices", "DeviceRequests", "PortBindings", "PublishAllPorts")),
            "Target must have no devices, bind mounts, privileges, or published ports")
    require(not any(mount.get("Type") == "bind" for mount in info.get("Mounts", [])),
            "Target must have no bind mounts")
    require(info["State"]["Running"], "Target is not running")
    require(set(info["NetworkSettings"]["Networks"]) == {NETWORK}, "Expected isolated test network only")
    require(host.get("NetworkMode") not in {"host", "none"}, "Expected bridge networking")
    return info, environment


def run_host(options):
    # Reject remote Docker endpoints before inspecting or executing anything.
    endpoint = os.environ.get("DOCKER_HOST")
    if not endpoint:
        context = json.loads(command("docker", "context", "inspect"))[0]
        endpoint = context["Endpoints"]["docker"]["Host"]
    require(endpoint.startswith(("npipe://", "unix://")), "Only a local Docker endpoint is permitted")
    root = Path(__file__).resolve().parents[1]
    container = options.container or command("docker", "compose", "-f", str(root / "compose.test.yaml"),
                                              "ps", "-q", "audio")
    require(container and "\n" not in container, "Start exactly one compose.test.yaml audio container")
    initial, environment = inspect_target(container)
    container = initial["Id"]
    network = json.loads(command("docker", "network", "inspect", NETWORK))[0]
    require(network["Driver"] == "bridge"
            and network.get("Labels", {}).get("com.docker.compose.project") == PROJECT,
            "Expected compose test bridge network")
    source = Path(__file__).read_bytes()

    def sample():
        current, _ = inspect_target(container)
        require(current["State"]["Pid"] == initial["State"]["Pid"]
                and current["RestartCount"] == initial["RestartCount"]
                and current["State"]["StartedAt"] == initial["State"]["StartedAt"],
                "Target container restarted during presence observation")
        result = subprocess.run(["docker", "exec", "-i", container, "python3", "-", "--snapshot"],
                                input=source, capture_output=True, check=True, timeout=20)
        state = json.loads(result.stdout)
        require(len(state["receiver_pids"]) == 1, "Expected one MiPlay receiver process")
        require(not state["playback_pids"] and not state["miplay_sink_inputs"],
                f"Idle probe created media output: {state}")
        return state

    baseline = sample()
    observer = "miplay-presence-" + uuid.uuid4().hex[:12]
    arguments = ["docker", "run", "--rm", "-i", "--name", observer,
                 "--network", NETWORK, "--cap-drop=ALL", "--security-opt=no-new-privileges:true",
                 "--read-only", "--user=65534:65534", "--entrypoint=python3", initial["Image"],
                 "-u", "-", "--inside", "--duration", str(options.duration),
                 "--target-ip", initial["NetworkSettings"]["Networks"][NETWORK]["IPAddress"],
                 "--target-port", environment.get("MIPLAY_PORT", "8899"),
                 "--device-name", environment["DEVICE_NAME"]]
    samples = 1
    # The Docker CLI has a hard timeout; explicit named-container removal also
    # handles timeout/interruption, since killing the CLI alone does not do so.
    with ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(subprocess.run, arguments, input=source, capture_output=True,
                                 check=True, timeout=options.duration + 60)
        try:
            while not future.done():
                time.sleep(2)
                state = sample()
                require(state["receiver_pids"] == baseline["receiver_pids"],
                        "MiPlay receiver process restarted")
                samples += 1
            try:
                result = future.result()
            except subprocess.CalledProcessError as error:
                raise RuntimeError(error.stderr.decode(errors="replace")) from error
            state = sample()
            require(state["receiver_pids"] == baseline["receiver_pids"], "MiPlay receiver process restarted")
            report = json.loads(result.stdout)
            report.update({"result": "PASS", "process_samples": samples + 1,
                           "container_pid": initial["State"]["Pid"],
                           "restart_count": initial["RestartCount"],
                           "receiver_pid": baseline["receiver_pids"][0],
                           "media_output_observed": False})
            print(json.dumps(report, ensure_ascii=False), flush=True)
        finally:
            cleanup = subprocess.run(["docker", "rm", "-f", observer], capture_output=True, timeout=20)
            require(cleanup.returncode == 0 or b"No such container" in cleanup.stderr,
                    "Failed to remove the isolated observer container")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", help="Explicit compose.test.yaml audio container ID")
    parser.add_argument("--duration", type=float, default=40, help="Authenticated observation seconds (35..300)")
    parser.add_argument("--inside", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--snapshot", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--target-ip", help=argparse.SUPPRESS)
    parser.add_argument("--target-port", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--device-name", help=argparse.SUPPRESS)
    options = parser.parse_args()
    require(35 <= options.duration <= 300, "Duration must be between 35 and 300 seconds")
    if options.snapshot:
        print(json.dumps(snapshot()))
    elif options.inside:
        ipaddress.IPv4Address(options.target_ip)
        print(json.dumps(asyncio.run(asyncio.wait_for(observe(options), options.duration + 40))))
    else:
        run_host(options)


if __name__ == "__main__":
    main()
