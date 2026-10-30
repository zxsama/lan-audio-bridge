#!/usr/bin/env python3
"""Real RAOP/AirPlay 1 sender test against the isolated null-output receiver.

Creates a temporary sender container; dependencies stay inside that container.
AirPlay 2, phone senders, physical output and Spotify remain separate gates.
"""
import argparse
import asyncio
import contextlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import uuid
import wave


def command(*args, timeout=20):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


async def send(address):
    import pyatv
    from ipaddress import IPv4Address
    from pyatv.conf import AppleTV, ManualService
    from pyatv.const import Protocol
    from pyatv.settings import AirPlayVersion
    from pyatv.storage.memory_storage import MemoryStorage

    # Public manual configuration selects classic RAOP without inheriting AP2
    # transient authentication from discovery. No receiver setting is changed.
    device = AppleTV(IPv4Address(address), "isolated RAOP test")
    device.add_service(ManualService("isolated-test", Protocol.RAOP, 7000, {}))
    storage = MemoryStorage()
    settings = await storage.get_settings(device)
    settings.protocols.raop.protocol_version = AirPlayVersion.V1
    with tempfile.TemporaryDirectory() as directory:
        audio = str(Path(directory) / "tone.wav")
        with wave.open(audio, "wb") as output:
            output.setparams((2, 2, 44100, 0, "NONE", "not compressed"))
            block = b"".join(struct.pack("<hh", *([int(10000 * math.sin(
                2 * math.pi * 440 * i / 44100))] * 2)) for i in range(44100))
            for _ in range(12):
                output.writeframes(block)
        atv = await pyatv.connect(device, asyncio.get_running_loop(),
                                  protocol=Protocol.RAOP, storage=storage)
        try:
            await atv.audio.set_volume(100)
            print("Sending 12 seconds of 440 Hz stereo WAV over RAOP/AirPlay 1", flush=True)
            await asyncio.wait_for(atv.stream.stream_file(audio), 35)
        finally:
            await asyncio.gather(*atv.close())
    print("RAOP sender completed", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", default="lan-audio-bridge-test-audio-1")
    parser.add_argument("--sender", help="Reuse a disposable sender with /tmp/sender-env; not removed")
    parser.add_argument("--inside-sender", metavar="IP", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.inside_sender:
        asyncio.run(send(args.inside_sender))
        return

    receiver = json.loads(command("docker", "inspect", args.container))[0]
    env = dict(item.split("=", 1) for item in receiver["Config"]["Env"])
    assert receiver["Config"]["Labels"].get("com.docker.compose.project") == "lan-audio-bridge-test"
    assert env.get("AUDIO_MODE") == "null" and env.get("AIRPLAY_PORT") == "7000"
    assert receiver["HostConfig"]["NetworkMode"] != "host"
    assert not receiver["HostConfig"].get("Devices")
    assert receiver["State"]["Running"]
    network = "lan-audio-bridge-test_default"
    address = receiver["NetworkSettings"]["Networks"][network]["IPAddress"]
    sender = args.sender or "lan-audio-bridge-test-raop-" + uuid.uuid4().hex[:8]
    process = None
    try:
        if not args.sender:
            command("docker", "run", "-d", "--name", sender, "--network", network,
                    "--entrypoint", "sleep", receiver["Image"], "900")
            install = ("apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "
                       "python3-venv >/tmp/apt.log && python3 -m venv /tmp/sender-env && "
                       "/tmp/sender-env/bin/pip install --disable-pip-version-check "
                       "pyatv==0.18.0 srptools==1.0.1 >/tmp/pip.log")
            subprocess.run(["docker", "exec", sender, "sh", "-c", install], check=True, timeout=600)
        sender_info = json.loads(command("docker", "inspect", sender))[0]
        assert network in sender_info["NetworkSettings"]["Networks"]
        assert sender_info["Id"] != receiver["Id"]
        versions = command("docker", "exec", sender, "/tmp/sender-env/bin/python", "-c",
                           "from importlib.metadata import version; "
                           "print(version('pyatv') + '/' + version('srptools'))")
        assert versions == "0.18.0/1.0.1", versions
        print("Sender versions: pyatv/srptools=" + versions, flush=True)

        # Reuse the existing spectral and single-route assertions read-only.
        helper = (Path(__file__).with_name("integration.py").read_text()
                  .replace('if __name__ == "__main__":', 'if False:'))
        def observe(suffix, timeout):
            subprocess.run(["docker", "exec", "-i", args.container, "python3", "-u", "-"],
                           input=(helper + "\n" + suffix).encode(), check=True, timeout=timeout)

        observe("route(None)\nassert all(s['corked'] for s in pulse('sink-inputs'))\n", 15)
        process = subprocess.Popen(["docker", "exec", "-i", sender,
                                    "/tmp/sender-env/bin/python", "-u", "-",
                                    "--inside-sender", address], stdin=subprocess.PIPE)
        process.stdin.write(Path(__file__).read_bytes())
        process.stdin.close()
        observe("eventually(lambda: route('airplay'), 'real RAOP route', timeout=18)\n"
                "time.sleep(3)\nassert_audio(440, (660, 880))\n", 30)
        assert process.wait(timeout=40) == 0, "Sender failed"
        observe("eventually(lambda: route(None), 'RAOP end releases output', timeout=15)\n", 20)
        print("PASS: independent RAOP/AirPlay 1 sender -> Shairport -> sole airplay route -> "
              "output.monitor 440 Hz; idle after completion. AirPlay 2 is not covered.", flush=True)
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            with contextlib.suppress(subprocess.TimeoutExpired):
                process.wait(timeout=5)
        if not args.sender:
            subprocess.run(["docker", "rm", "-f", sender], stdout=subprocess.DEVNULL,
                           check=False, timeout=20)


if __name__ == "__main__":
    main()
