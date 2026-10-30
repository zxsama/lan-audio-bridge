#!/usr/bin/env python3
"""Verify real Pulse processes in an existing isolated null-output container.

Run with a Linux/WSL Docker client. This exercises software startup, private
D-Bus, and dynamic modules; it does not establish physical ALSA playback.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import uuid


PROCESS_SOURCE = r'''
import json
from pathlib import Path
result = []
for path in Path('/proc').iterdir():
    if not path.name.isdigit():
        continue
    try:
        command = path.joinpath('cmdline').read_bytes().split(b'\0')
        if not command[0]:
            continue
        status = dict(line.split(':', 1) for line in path.joinpath('status').read_text().splitlines())
        stat = path.joinpath('stat').read_text().rsplit(') ', 1)[1].split()
        result.append({'pid': int(path.name), 'ppid': int(stat[1]), 'pgid': int(stat[2]),
                       'start': stat[19], 'uid': [int(v) for v in status['Uid'].split()],
                       'gid': [int(v) for v in status['Gid'].split()],
                       'argv': [v.decode() for v in command if v]})
    except (FileNotFoundError, ProcessLookupError):
        pass
print(json.dumps(result))
'''


def command(*args, check=True):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=20)
    if check and result.returncode:
        raise AssertionError(f"Command failed ({result.returncode}): {' '.join(args)}\n{result.stderr[-2000:]}")
    return result


def processes(container):
    return json.loads(command("docker", "exec", container, "python3", "-c", PROCESS_SOURCE).stdout)


def pulse_process(container):
    matches = [p for p in processes(container) if Path(p["argv"][0]).name == "pulseaudio"]
    assert len(matches) == 1, f"Expected exactly one real Pulse daemon: {matches}"
    return matches[0]


def verify_container(container):
    info = json.loads(command("docker", "inspect", container).stdout)[0]
    environment = dict(item.split("=", 1) for item in info["Config"]["Env"])
    assert environment.get("AUDIO_MODE") == "null", "Refusing hardware test"
    assert info["HostConfig"]["NetworkMode"] != "host", "Refusing host-network test"
    assert not info["HostConfig"].get("Devices"), "Refusing mapped device test"
    assert info["State"]["Running"]

    def execute(*args, user=None, check=True):
        options = ["--user=" + str(user)] if user is not None else []
        return command("docker", "exec", *options, container, *args, check=check)

    account = json.loads(execute("python3", "-c", "import json,pwd; p=pwd.getpwnam('pulse'); print(json.dumps([p.pw_uid,p.pw_gid]))").stdout)
    uid, gid = account
    assert uid != 0
    current = processes(container)
    pulse = pulse_process(container)
    assert pulse["uid"] == [uid] * 4 and pulse["gid"] == [gid] * 4, pulse
    assert "--system" not in pulse["argv"], pulse
    status = json.loads(execute("cat", "/run/lan-audio/status.json").stdout)
    wrapper_pid = status["children"]["pulse"]["pid"]
    wrapper = next(p for p in current if p["pid"] == wrapper_pid)
    assert Path(wrapper["argv"][0]).name == "dbus-run-session", wrapper
    assert wrapper["uid"] == [uid] * 4 and wrapper["pgid"] == wrapper_pid
    buses = [p for p in current if Path(p["argv"][0]).name == "dbus-daemon" and p["uid"] == [uid] * 4]
    assert len(buses) == 1, buses
    assert buses[0]["pgid"] == pulse["pgid"] == wrapper_pid, (buses, pulse, wrapper)
    env_source = "import json,sys; from pathlib import Path; print(json.dumps(dict(v.decode().split('=',1) for v in Path('/proc/'+sys.argv[1]+'/environ').read_bytes().split(b'\\0') if v)))"
    pulse_env = json.loads(execute("python3", "-c", env_source, str(pulse["pid"]), user=uid).stdout)
    session_address = pulse_env["DBUS_SESSION_BUS_ADDRESS"]
    assert session_address.startswith("unix:"), session_address
    assert "/run/dbus/system_bus_socket" not in session_address
    assert "DBUS_SYSTEM_BUS_ADDRESS" not in pulse_env
    assert pulse_env["HOME"] == "/run/pulse/home"
    assert pulse_env["XDG_RUNTIME_DIR"] == "/run/pulse/runtime"
    for directory in (pulse_env["HOME"], pulse_env["XDG_RUNTIME_DIR"]):
        result = execute("stat", "--format=%u:%g:%a", directory).stdout.strip()
        assert result == f"{uid}:{gid}:700", (directory, result)
    # Prove the same-user private bus is usable, not merely present in argv/env.
    execute("dbus-send", "--bus=" + session_address, "--print-reply", "--reply-timeout=2000",
            "--dest=org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus.ListNames", user=uid)
    print("PASS: real Pulse daemon runs as pulse with same-user private session bus and private runtime directories", flush=True)

    if status["avahi_mode"] == "external":
        filtered = "/run/dbus/system_bus_socket"
        before = execute("stat", "--format=%u:%g:%a:%i", filtered).stdout.strip()
        owner, group, mode, _inode = before.split(":")
        assert owner == group == "0" and int(mode, 8) & 0o077 == 0, before
        arguments = ("dbus-send", "--bus=unix:path=" + filtered, "--print-reply", "--reply-timeout=2000",
                     "--dest=org.freedesktop.Avahi", "/", "org.freedesktop.Avahi.Server.GetVersionString")
        execute(*arguments)
        denied = execute(*arguments, user=uid, check=False)
        assert denied.returncode != 0 and "Permission denied" in denied.stderr, denied.stderr
        assert execute("stat", "--format=%u:%g:%a:%i", filtered).stdout.strip() == before
        print("PASS: filtered discovery socket remains root-owned with no group/other access; Pulse user cannot access it", flush=True)

    server = "--server=unix:/run/lan-audio/pulse.sock"
    modules = json.loads(execute("pactl", server, "--format=json", "list", "modules").stdout)
    native = [m for m in modules if m["name"] == "module-native-protocol-unix"]
    assert len(native) == 1
    assert "auth-anonymous=1" in native[0]["argument"] and "auth-cookie-enabled=0" in native[0]["argument"], native
    sink_argument = "sink_name=pulse_regression_" + uuid.uuid4().hex[:10]
    module = execute("pactl", server, "load-module", "module-null-sink", sink_argument).stdout.strip()
    assert module.isdigit(), module
    try:
        loaded = json.loads(execute("pactl", server, "--format=json", "list", "modules").stdout)
        assert any(m["argument"] == sink_argument for m in loaded)
    finally:
        execute("pactl", server, "unload-module", module)
    loaded = json.loads(execute("pactl", server, "--format=json", "list", "modules").stdout)
    assert not any(m["argument"] == sink_argument for m in loaded)
    print("PASS: root clients connect without cookies; dynamic module loading and unloading succeeds", flush=True)

    logs = command("docker", "logs", "--since=" + info["State"]["StartedAt"], container)
    patterns = (r"Running in system mode", r"running as root", r"system mode.*disallow",
                r"Failed to (?:open|load).*cookie", r"Unable to contact D-Bus",
                r"Failed to connect to (?:session|system) bus", r"D-Bus.*Permission denied")
    bad = [line for line in (logs.stdout + logs.stderr).splitlines()
           if any(re.search(pattern, line, re.IGNORECASE) for pattern in patterns)]
    assert not bad, "Unexpected startup warnings:\n" + "\n".join(bad)
    print("PASS: startup log has no system-mode, missing-cookie, or D-Bus access warnings", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--container", default="lan-audio-bridge-test-audio-1")
    args = parser.parse_args()
    verify_container(args.container)


if __name__ == "__main__":
    main()
