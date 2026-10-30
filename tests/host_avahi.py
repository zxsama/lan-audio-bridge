#!/usr/bin/env python3
"""Reproduce exclusive host Avahi in disposable, isolated Docker namespaces.

Run under a Linux/WSL Docker client: python3 tests/host_avahi.py [--image IMAGE].
Never uses host networking, host D-Bus, sound hardware, accounts or published ports.
Only the private fixture bus is exposed to the proxy sidecar. All resources use a
unique test prefix and are removed on success or failure.
"""
import argparse
import json
from pathlib import Path
import subprocess
import time
import uuid


HOST_SOURCE = r'''
import json, os, socket, struct, subprocess, time
from pathlib import Path

BUS = "unix:path=/host-bus/system_bus_socket"
os.environ["DBUS_SYSTEM_BUS_ADDRESS"] = BUS
Path("/run/lan-audio").mkdir(parents=True, exist_ok=True)
Path("/run/lan-audio/machine-id").write_text("4b9a89163efb419994e7fdf784735b1b\n")
Path("/run/avahi-daemon").mkdir(exist_ok=True)
Path("/run/avahi.conf").write_text("""[server]
host-name=isolated-avahi-host
use-ipv4=yes
use-ipv6=no
allow-interfaces=eth0
disallow-other-stacks=yes
enable-dbus=yes
[publish]
publish-addresses=yes
publish-workstation=no
""")
Path("/run/fixture-bus.conf").write_text("""<busconfig>
<include>/usr/share/dbus-1/system.conf</include>
<policy user="root"><allow own="org.example.Unrelated"/></policy>
<policy context="default"><allow send_destination="org.example.Unrelated"/></policy>
</busconfig>""")
dbus = subprocess.Popen(["dbus-daemon", "--config-file=/run/fixture-bus.conf", "--nofork", "--nopidfile", "--address=" + BUS])
for _ in range(100):
    if Path("/host-bus/system_bus_socket").is_socket(): break
    assert dbus.poll() is None, "Fixture bus exited"
    time.sleep(.1)
else: raise RuntimeError("Fixture bus did not start")

# A real, unrelated service proves filtering hides an existing destination.
# This tiny fixture speaks only D-Bus auth, Hello/RequestName and Peer.Ping.
def pad(data, alignment):
    return data + b"\0" * (-len(data) % alignment)
def string(value):
    data = value.encode()
    return struct.pack("<I", len(data)) + data + b"\0"
def field(code, signature, value):
    encoded = struct.pack("<I", value) if signature == "u" else string(value)
    return bytes([code, 1]) + signature.encode() + b"\0" + encoded
def message(kind, serial, fields, body=b""):
    header = b""
    for item in fields: header = pad(header, 8) + item
    return pad(struct.pack("<BBBBIII", 108, kind, 0, 1, len(body), serial, len(header)) + header, 8) + body
connection = socket.socket(socket.AF_UNIX)
connection.connect("/host-bus/system_bus_socket")
connection.sendall(b"\0AUTH EXTERNAL 30\r\n")
auth = b""
while not auth.endswith(b"\r\n"): auth += connection.recv(1)
assert auth.startswith(b"OK "), "Fixture bus authentication failed"
connection.sendall(b"BEGIN\r\n")
def exact(length):
    result = b""
    while len(result) < length:
        part = connection.recv(length - len(result))
        if not part: raise RuntimeError("Fixture bus closed")
        result += part
    return result
def receive():
    fixed = exact(16)
    assert fixed[0] == 108
    _, kind, _, _, size, serial, header_size = struct.unpack("<BBBBIII", fixed)
    header = exact((header_size + 7) // 8 * 8)
    body = exact(size)
    fields, offset = {}, 0
    while offset < header_size:
        offset = (offset + 7) // 8 * 8
        code, signature = header[offset], chr(header[offset + 2])
        offset += 4
        if signature in ("s", "o"):
            length = struct.unpack_from("<I", header, offset)[0]
            fields[code] = header[offset + 4:offset + 4 + length].decode()
            offset += 5 + length
        elif signature == "u":
            fields[code] = struct.unpack_from("<I", header, offset)[0]
            offset += 4
        elif signature == "g":
            length = header[offset]
            fields[code] = header[offset + 1:offset + 1 + length].decode()
            offset += 2 + length
        else: raise RuntimeError("Unexpected fixture field")
    return kind, serial, fields, body
def call(serial, member, body=b"", signature=None):
    fields = [field(1, "o", "/org/freedesktop/DBus"), field(2, "s", "org.freedesktop.DBus"),
              field(3, "s", member), field(6, "s", "org.freedesktop.DBus")]
    if signature:
        fields.append(bytes([8, 1, 103, 0, len(signature)]) + signature.encode() + b"\0")
    connection.sendall(message(1, serial, fields, body))
    while True:
        kind, _, reply_fields, reply_body = receive()
        if reply_fields.get(5) == serial:
            assert kind == 2, "Fixture method failed"
            return reply_body
call(1, "Hello")
assert struct.unpack("<I", call(2, "RequestName", pad(string("org.example.Unrelated"), 4) + struct.pack("<I", 0), "su"))[0] == 1
avahi_command = ["avahi-daemon", "--no-drop-root", "--no-chroot", "--no-rlimits", "--file=/run/avahi.conf"]
avahi = subprocess.Popen(avahi_command)
def identity(process):
    return {"pid": process.pid, "start": Path("/proc/%s/stat" % process.pid).read_text().split()[21]}
Path("/run/fixture.json").write_text(json.dumps({"dbus": identity(dbus), "avahi": identity(avahi)}))
connection.settimeout(.5)
serial = 100
while True:
    if Path("/run/stop-avahi").exists():
        Path("/run/stop-avahi").unlink()
        avahi.terminate()
        avahi.wait(timeout=5)
        avahi = None
    if Path("/run/start-avahi").exists():
        Path("/run/start-avahi").unlink()
        assert avahi is None
        avahi = subprocess.Popen(avahi_command)
        Path("/run/fixture.json").write_text(json.dumps({"dbus": identity(dbus), "avahi": identity(avahi)}))
    assert dbus.poll() is None and (avahi is None or avahi.poll() is None), "Fixture daemon stopped"
    try: kind, request_serial, fields, body = receive()
    except socket.timeout: continue
    if kind == 1:
        assert fields.get(2) == "org.freedesktop.DBus.Peer" and fields.get(3) == "Ping"
        serial += 1
        connection.sendall(message(2, serial, [field(5, "u", request_serial), field(6, "s", fields[7])]))
'''


def command(*args, timeout=30, input=None, check=True):
    result = subprocess.run(args, input=input, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout)
    if check and result.returncode:
        raise AssertionError(f"Command failed ({result.returncode}): {' '.join(args)}\n{result.stderr[-3000:]}")
    return result


def eventually(predicate, description, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except (AssertionError, ValueError, KeyError, subprocess.SubprocessError):
            pass
        time.sleep(.4)
    raise AssertionError("Timed out: " + description)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", default="lan-audio-bridge:mdns-fix")
    args = parser.parse_args()
    image = command("docker", "image", "inspect", "--format={{.Id}}", args.image).stdout.strip()
    prefix = "lab-host-avahi-" + uuid.uuid4().hex[:10]
    network, host_bus, proxy_bus = prefix + "-net", prefix + "-hostbus", prefix + "-proxybus"
    containers, volumes = [], []

    def inspect(name):
        return json.loads(command("docker", "inspect", name).stdout)[0]

    def execute(name, *arguments, check=True):
        return command("docker", "exec", name, *arguments, check=check)

    def bus_call(name, address, destination, path, method, *arguments):
        return execute(name, "dbus-send", "--bus=" + address, "--print-reply", "--reply-timeout=2000",
                       "--dest=" + destination, path, method, *arguments, check=False)

    def launch(suffix, options, entrypoint, arguments, source=None):
        name = prefix + "-" + suffix
        containers.append(name)
        if source is not None:
            assert arguments[-1] == "-"
            arguments = [*arguments[:-1], "-c", source]
        command("docker", "run", "-d", "--name", name, "--label", "lan-audio-test=" + prefix,
                "--cap-drop=ALL", "--security-opt=no-new-privileges:true", *options,
                "--entrypoint=" + entrypoint, image, *arguments)
        return name

    def fixture_snapshot(host):
        return execute(host, "python3", "-c", """import json; from pathlib import Path
data=json.loads(Path('/run/fixture.json').read_text())
for item in data.values():
    assert Path('/proc/%s/stat' % item['pid']).read_text().split()[21] == item['start']
print(json.dumps(data, sort_keys=True))""").stdout.strip()

    try:
        command("docker", "network", "create", "--label", "lan-audio-test=" + prefix, network)
        for volume in (host_bus, proxy_bus):
            command("docker", "volume", "create", "--label", "lan-audio-test=" + prefix, volume)
            volumes.append(volume)
        host = launch("host", ["--network=" + network, "--cap-add=SETUID", "--cap-add=SETGID", "--cap-add=CHOWN", "--cap-add=DAC_OVERRIDE",
                               "--tmpfs=/run:mode=755", "--tmpfs=/tmp:mode=1777",
                               "--mount=type=volume,src=" + host_bus + ",dst=/host-bus"],
                      "python3", ["-u", "-"], HOST_SOURCE)
        raw = "unix:path=/host-bus/system_bus_socket"
        filtered = "unix:path=/run/dbus/system_bus_socket"
        avahi_args = ("org.freedesktop.Avahi", "/", "org.freedesktop.Avahi.Server.GetVersionString")
        eventually(lambda: bus_call(host, raw, *avahi_args).returncode == 0, "exclusive fixture Avahi")
        original = fixture_snapshot(host)
        assert bus_call(host, raw, "org.example.Unrelated", "/", "org.freedesktop.DBus.Peer.Ping").returncode == 0
        ip = inspect(host)["NetworkSettings"]["Networks"][network]["IPAddress"]
        common = ["--network=container:" + host, "--init", "--tmpfs=/run:mode=755", "--tmpfs=/tmp:mode=1777",
                  "--tmpfs=/data:mode=755", "--env=AUDIO_MODE=null", "--env=NETWORK_INTERFACE=eth0",
                  "--env=DEVICE_NAME=LAB Host Avahi Test", "--env=ENABLE_AIRPLAY=true", "--env=ENABLE_DLNA=true",
                  "--env=ENABLE_SPOTIFY=true", "--env=AIRPLAY_PORT=7000", "--env=DLNA_PORT=49494",
                  "--env=SPOTIFY_PORT=24879"]
        common += ["--cap-add=" + cap for cap in ("CHOWN", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID", "NET_BIND_SERVICE", "KILL")]
        old = launch("internal", [*common, "--env=AVAHI_MODE=internal"], "python3", ["/app/runtime.py"])
        eventually(lambda: not inspect(old)["State"]["Running"], "internal mode rejects occupied mDNS", timeout=50)
        assert inspect(old)["State"]["ExitCode"] != 0, "Internal mode exited successfully unexpectedly"
        log_result = command("docker", "logs", old)
        logs = log_result.stdout + log_result.stderr
        assert any(text in logs.lower() for text in ("5353", "address already in use", "bind() failed")), "Expected mDNS bind conflict evidence"
        assert fixture_snapshot(host) == original
        print("PASS: internal mode reproduces exclusive UDP 5353 conflict; fixture unchanged", flush=True)

        proxy = launch("proxy", ["--network=none", "--read-only", "--mount=type=volume,src=" + host_bus + ",dst=/run/host-dbus,readonly",
                                 "--mount=type=volume,src=" + proxy_bus + ",dst=/proxy"], "python3",
                       ["/app/avahi_proxy.py"])
        eventually(lambda: execute(proxy, "test", "-S", "/proxy/system_bus_socket", check=False).returncode == 0, "proxy socket")
        audio = launch("external", [*common, "--env=AVAHI_MODE=external",
                                   "--mount=type=volume,src=" + proxy_bus + ",dst=/run/dbus,readonly"], "python3", ["/app/runtime.py"])
        eventually(lambda: execute(audio, "python3", "/app/healthcheck.py", check=False).returncode == 0, "external receiver health", timeout=90)
        status = json.loads(execute(audio, "cat", "/run/lan-audio/status.json").stdout)
        assert status["avahi_mode"] == "external"
        assert not ({"dbus", "avahi"} & status["children"].keys()), "External mode started private discovery daemons"
        audio_info = inspect(audio)
        assert {mount["Name"] for mount in audio_info["Mounts"] if mount["Type"] == "volume"} == {proxy_bus}
        assert all(not mount["RW"] for mount in audio_info["Mounts"] if mount.get("Name") == proxy_bus)
        assert execute(audio, "test", "-e", "/run/host-dbus/system_bus_socket", check=False).returncode != 0
        assert inspect(proxy)["HostConfig"]["NetworkMode"] == "none"
        assert bus_call(audio, filtered, *avahi_args).returncode == 0
        hostname_args = ("org.freedesktop.Avahi", "/", "org.freedesktop.Avahi.Server.GetHostName")
        hostname_before = bus_call(host, raw, *hostname_args)
        assert hostname_before.returncode == 0 and 'string "isolated-avahi-host"' in hostname_before.stdout
        denied = bus_call(audio, filtered, "org.freedesktop.Avahi", "/", "org.freedesktop.Avahi.Server.SetHostName",
                          "string:isolated-avahi-host")
        assert denied.returncode and any(error in denied.stderr for error in ("AccessDenied", "ServiceUnknown")), denied.stderr
        hostname_after = bus_call(host, raw, *hostname_args)
        assert hostname_after.returncode == 0 and 'string "isolated-avahi-host"' in hostname_after.stdout
        denied = bus_call(audio, filtered, "org.example.Unrelated", "/", "org.freedesktop.DBus.Peer.Ping")
        assert denied.returncode and any(error in denied.stderr for error in ("AccessDenied", "ServiceUnknown", "NameHasNoOwner")), denied.stderr
        denied = bus_call(audio, filtered, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.RequestName",
                          "string:org.example.AudioAttempt", "uint32:0")
        assert denied.returncode and any(error in denied.stderr for error in ("AccessDenied", "ServiceUnknown")), denied.stderr
        names = bus_call(audio, filtered, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.ListNames")
        assert names.returncode == 0 and "org.example.Unrelated" not in names.stdout
        print("PASS: external mode healthy; only filtered socket mounted; unrelated service and name ownership denied", flush=True)

        discovery = Path(__file__).with_name("discovery.py").read_text(encoding="utf-8")
        def verify_discovery(stage):
            observer = prefix + "-observer-" + stage
            containers.append(observer)
            result = command("docker", "run", "--rm", "-i", "--name", observer, "--network=" + network,
                             "--cap-drop=ALL", "--security-opt=no-new-privileges:true", "--read-only", "--user=65534:65534",
                             "--entrypoint=python3", image, "-u", "-", "--inside", "--target-ip", ip,
                             "--device-name", "LAB Host Avahi Test", input=discovery, timeout=60)
            print(result.stdout, end="", flush=True)

        def wait_failed_receiver():
            eventually(lambda: not inspect(audio)["State"]["Running"], "discovery loss terminates receiver", timeout=30)
            assert inspect(audio)["State"]["ExitCode"] != 0

        def restart_receiver():
            # Production restart policy performs this; the test uses restart=no
            # so the failure exit can be asserted before explicitly recovering.
            command("docker", "start", audio)
            eventually(lambda: execute(audio, "python3", "/app/healthcheck.py", check=False).returncode == 0,
                       "recovered receiver health", timeout=90)

        verify_discovery("initial")
        assert fixture_snapshot(host) == original
        assert bus_call(host, raw, *avahi_args).returncode == 0
        assert bus_call(host, raw, "org.example.Unrelated", "/", "org.freedesktop.DBus.Peer.Ping").returncode == 0

        command("docker", "stop", "--time=5", proxy)
        assert execute(audio, "python3", "/app/healthcheck.py", check=False).returncode != 0
        wait_failed_receiver()
        assert fixture_snapshot(host) == original
        command("docker", "start", proxy)
        eventually(lambda: execute(proxy, "test", "-S", "/proxy/system_bus_socket", check=False).returncode == 0, "restarted proxy socket")
        restart_receiver()
        verify_discovery("proxy-recovered")
        assert fixture_snapshot(host) == original
        print("PASS: proxy outage fails health/exits receiver; restart restores discovery without changing fixture daemons", flush=True)

        execute(host, "touch", "/run/stop-avahi")
        eventually(lambda: bus_call(host, raw, *avahi_args).returncode != 0, "fixture Avahi stopped")
        assert execute(audio, "python3", "/app/healthcheck.py", check=False).returncode != 0
        wait_failed_receiver()
        execute(host, "touch", "/run/start-avahi")
        eventually(lambda: bus_call(host, raw, *avahi_args).returncode == 0, "fixture Avahi restarted")
        renewed = fixture_snapshot(host)
        assert json.loads(renewed)["dbus"] == json.loads(original)["dbus"]
        assert json.loads(renewed)["avahi"] != json.loads(original)["avahi"]
        restart_receiver()
        verify_discovery("avahi-recovered")
        assert fixture_snapshot(host) == renewed
        print("PASS: fixture Avahi restart fails health/exits receiver; restart registers services again on unchanged fixture bus", flush=True)

        command("docker", "stop", "--time=15", audio)
        assert fixture_snapshot(host) == renewed
        assert bus_call(host, raw, *avahi_args).returncode == 0
        print("PASS: receiver shutdown leaves current fixture D-Bus/Avahi processes unchanged", flush=True)
        print("PASS: isolated shared-network regression; physical NAS/LAN/phone/playback remain separate", flush=True)
    except BaseException:
        for name in containers:
            result = command("docker", "logs", "--tail=35", name, check=False)
            if result.returncode == 0:
                print("Test container log: " + name + "\n" + result.stdout + result.stderr, flush=True)
        raise
    finally:
        for name in reversed(containers):
            command("docker", "rm", "-f", name, check=False)
        for volume in reversed(volumes):
            command("docker", "volume", "rm", volume, check=False)
        command("docker", "network", "rm", network, check=False)


if __name__ == "__main__":
    main()
