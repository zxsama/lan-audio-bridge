#!/usr/bin/env python3
"""Exercise process failure and restart in the isolated null-output test app."""
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
COMPOSE = ["docker", "compose", "-f", str(ROOT / "compose.test.yaml")]


def command(*args, timeout=20):
    return subprocess.check_output(args, text=True, timeout=timeout).strip()


def eventually(check, description, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if check():
                return
        except (subprocess.SubprocessError, KeyError, ValueError, AssertionError):
            pass
        time.sleep(0.25)
    raise AssertionError("Timed out: " + description)


def main():
    container = command(*COMPOSE, "ps", "-q", "audio")
    assert container and "\n" not in container, "Start the isolated test Compose first"

    def inspect():
        return json.loads(command("docker", "inspect", container))[0]

    info = inspect()
    env = dict(item.split("=", 1) for item in info["Config"]["Env"])
    assert env.get("AUDIO_MODE") == "null", "Refusing hardware test"
    assert info["HostConfig"]["NetworkMode"] != "host", "Refusing host-network test"
    assert not info["HostConfig"].get("Devices"), "Refusing mapped device test"
    assert info["HostConfig"]["RestartPolicy"]["Name"] == "no", "Expected isolated restart policy"
    assert info["Config"]["Labels"].get("com.docker.compose.project") == "lan-audio-bridge-test"
    assert info["State"]["Running"]

    def execute(*args):
        return command("docker", "exec", container, *args)

    def status():
        return json.loads(execute("cat", "/run/lan-audio/status.json"))

    def healthy():
        return inspect()["State"].get("Health", {}).get("Status") == "healthy"

    def kill_child(name):
        pid = status()["children"][name]["pid"]
        assert type(pid) is int and pid > 1
        execute("python3", "-c", "import os,signal,sys; os.kill(int(sys.argv[1]), signal.SIGKILL)", str(pid))
        return pid

    def idle():
        current = status()
        assert current["owner"] is None and current["state"] == "idle", current
        modules = json.loads(execute("pactl", "--server=unix:/run/lan-audio/pulse.sock", "--format=json", "list", "modules"))
        assert not any(m["name"] == "module-loopback" for m in modules)
        return True

    eventually(healthy, "initial health")
    identity = execute("cat", "/data/dlna.uuid")
    machine_id = execute("cat", "/data/dbus-machine-id")
    for name in ("airplay", "dlna", "spotify"):
        before = status()["children"][name]["restarts"]
        old_pid = kill_child(name)

        def restarted():
            child = status()["children"][name]
            return child["state"] == "running" and child["pid"] != old_pid and child["restarts"] > before

        eventually(restarted, name + " supervised restart")
        eventually(healthy, name + " health restored")
        eventually(idle, name + " no stale route")
        print("PASS receiver crash/restart: " + name, flush=True)

    # Core failure must terminate the whole app, not leave a misleading live container.
    kill_child("pulse")
    eventually(lambda: not inspect()["State"]["Running"], "core failure terminates app")
    assert inspect()["State"]["ExitCode"] != 0
    print("PASS PulseAudio failure terminates app with nonzero exit", flush=True)

    subprocess.run([*COMPOSE, "up", "-d", "--wait", "--wait-timeout", "90"], check=True, timeout=110)
    assert execute("cat", "/data/dlna.uuid") == identity
    assert execute("cat", "/data/dbus-machine-id") == machine_id
    eventually(idle, "fresh startup stays silent")
    print("PASS restart retains identities and starts silent", flush=True)

    subprocess.run([*COMPOSE, "stop", "-t", "15", "audio"], check=True, timeout=25)
    assert inspect()["State"]["ExitCode"] == 0
    subprocess.run([*COMPOSE, "up", "-d", "--wait", "--wait-timeout", "90"], check=True, timeout=110)
    eventually(idle, "graceful stop/start")
    print("PASS SIGTERM shutdown and clean restart", flush=True)


if __name__ == "__main__":
    main()
