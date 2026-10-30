#!/usr/bin/env python3
"""Exercise process failure and restart in the isolated null-output test app."""
import json
from pathlib import Path
import subprocess
import time

from pulse_startup import pulse_process

ROOT = Path(__file__).resolve().parents[1]
COMPOSE = ["docker", "compose", "-f", str(ROOT / "compose.test.yaml")]

# Run the real supervisor in an ordinary docker-exec process, while PID 1 and
# the production receivers remain alive. Container teardown cannot hide a leak.
GROUP_SOURCE = r'''
import dataclasses, json, os, pwd, signal, subprocess, sys, tempfile, time
from pathlib import Path
sys.path.insert(0, '/app')
from runtime import BridgeError, Supervisor, pulse_context

def members(pgid):
    result = []
    for path in Path('/proc').iterdir():
        if not path.name.isdigit(): continue
        try:
            stat = path.joinpath('stat').read_text().rsplit(') ', 1)[1].split()
            if int(stat[2]) != pgid: continue
            argv = path.joinpath('cmdline').read_bytes().split(b'\0')
            result.append((int(path.name), stat[0], argv[0].decode()))
        except (FileNotFoundError, ProcessLookupError): pass
    return result

user = pwd.getpwnam('pulse')
original = json.loads(sys.argv[1])
for failure in ('daemon', 'wrapper', 'shutdown'):
    with tempfile.TemporaryDirectory(prefix='pulse-recovery-', dir='/run/pulse') as directory:
        base = Path(directory)
        os.chown(base, user.pw_uid, user.pw_gid)
        for name in ('home', 'runtime'):
            path = base / name
            path.mkdir(mode=0o700)
            os.chown(path, user.pw_uid, user.pw_gid)
        context = pulse_context(user.pw_uid, user.pw_gid, 'null')
        context = dataclasses.replace(context, env={**context.env, 'HOME': str(base / 'home'),
                                                   'XDG_RUNTIME_DIR': str(base / 'runtime')})
        socket = base / 'native.sock'
        config = base / 'pulse.pa'
        config.write_text('.fail\nload-module module-native-protocol-unix socket=' + str(socket) +
                          ' auth-anonymous=1 auth-cookie-enabled=0\nload-module module-null-sink sink_name=isolated\n')
        argv = ['dbus-run-session', '--', *[('--file=' + str(config)) if arg.startswith('--file=') else arg for arg in original]]
        supervisor = Supervisor()
        supervisor.add('pulse-test', argv, core=True, context=context)
        child = supervisor.children['pulse-test']
        pgid = None
        try:
            supervisor.tick(time.monotonic())
            pgid = child.process.pid
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                supervisor.tick(time.monotonic())
                if socket.is_socket():
                    ready = subprocess.run(['pactl', '--server=unix:' + str(socket), 'info'],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
                    if ready.returncode == 0: break
                time.sleep(.05)
            else: raise AssertionError('Independent Pulse did not start')
            group = members(pgid)
            daemon = [pid for pid, state, command in group if Path(command).name == 'pulseaudio']
            bus = [pid for pid, state, command in group if Path(command).name == 'dbus-daemon']
            assert len(daemon) == len(bus) == 1 and daemon[0] != pgid, group
            if failure == 'shutdown':
                supervisor.shutdown()
            else:
                os.kill(daemon[0] if failure == 'daemon' else pgid, signal.SIGKILL)
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    try: supervisor.tick(time.monotonic())
                    except BridgeError: break
                    time.sleep(.05)
                else: raise AssertionError('Core failure did not propagate: ' + failure)
                assert child.exit_code != 0, child.exit_code
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if not members(pgid): break
                time.sleep(.05)
            else: raise AssertionError('Pulse process group remained: ' + repr(members(pgid)))
            print('PASS real Pulse/session-bus process group cleaned after ' + failure + '; container stayed alive', flush=True)
        finally:
            supervisor.shutdown()
            if pgid:
                try: os.killpg(pgid, signal.SIGKILL)
                except ProcessLookupError: pass
'''


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
    # Each independent Pulse uses its own runtime, configuration and null sink.
    print(command("docker", "exec", container, "python3", "-c", GROUP_SOURCE,
                  json.dumps(pulse_process(container)["argv"]), timeout=50), flush=True)
    assert inspect()["State"]["Running"]
    eventually(healthy, "production receivers remain healthy after process-group tests")
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

    # Killing the wrapper alone cannot prove a nested Pulse failure is observed.
    # Exercise both the real daemon and its session-bus wrapper independently.
    for target in ("daemon", "wrapper"):
        wrapper_pid = status()["children"]["pulse"]["pid"]
        daemon_pid = pulse_process(container)["pid"]
        assert daemon_pid != wrapper_pid, "Expected supervised dbus-run-session wrapper"
        pid = daemon_pid if target == "daemon" else wrapper_pid
        execute("python3", "-c", "import os,signal,sys; os.kill(int(sys.argv[1]), signal.SIGKILL)", str(pid))
        eventually(lambda: not inspect()["State"]["Running"], "Pulse " + target + " failure terminates app")
        assert inspect()["State"]["ExitCode"] != 0
        print("PASS actual Pulse " + target + " failure terminates app with nonzero exit", flush=True)

        subprocess.run([*COMPOSE, "up", "-d", "--wait", "--wait-timeout", "90"], check=True, timeout=110)
        assert execute("cat", "/data/dlna.uuid") == identity
        assert execute("cat", "/data/dbus-machine-id") == machine_id
        eventually(idle, "fresh startup stays silent")
        print("PASS restart retains identities and starts silent after " + target + " failure", flush=True)

    subprocess.run([*COMPOSE, "stop", "-t", "15", "audio"], check=True, timeout=25)
    assert inspect()["State"]["ExitCode"] == 0
    subprocess.run([*COMPOSE, "up", "-d", "--wait", "--wait-timeout", "90"], check=True, timeout=110)
    eventually(idle, "graceful stop/start")
    print("PASS SIGTERM shutdown and clean restart", flush=True)


if __name__ == "__main__":
    main()
