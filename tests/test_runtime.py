"""Standard-library tests for arbitration, supervisor failures and safe config."""
import itertools
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
from runtime import (BridgeError, Child, Config, Coordinator, Pulse, Runtime, SOURCES,
                     Snapshot, Supervisor, atomic_write, avahi_config, child_environment,
                     owns_udp_ports, persistent_machine_id, persistent_uuid, pulse_config, receiver_commands, shairport_config)
from healthcheck import healthy
import healthcheck
from runtime import avahi_available


def snapshot(active=None, corked=None):
    active, corked = active or {}, corked or {}
    return Snapshot({s: set(active.get(s, ())) | set(corked.get(s, ())) for s in SOURCES},
                    {s: set(active.get(s, ())) for s in SOURCES})


class FakePulse:
    def __init__(self):
        self.events = []
        self.route_module = None

    def clear(self):
        self.events.append(("clear",))
        self.route_module = None

    def route(self, source):
        if self.route_module is not None:
            raise AssertionError("overlapping output routes")
        self.events.append(("route", source))
        self.route_module = 42


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.pulse = FakePulse()
        self.stops = []
        self.coordinator = Coordinator(self.pulse, self.stops.append)

    def test_startup_and_corked_streams_stay_silent(self):
        self.coordinator.step(snapshot(corked={"airplay": {1}, "dlna": {2}}))
        self.assertIsNone(self.coordinator.owner)
        self.assertEqual(self.pulse.events, [])

    def test_all_six_cross_protocol_transitions_unload_first(self):
        for first, second in itertools.permutations(SOURCES, 2):
            with self.subTest(first=first, second=second):
                pulse, stops = FakePulse(), []
                coordinator = Coordinator(pulse, stops.append)
                coordinator.step(snapshot({first: {1}}))
                coordinator.step(snapshot({first: {1}, second: {2}}))
                self.assertEqual(coordinator.owner, second)
                self.assertEqual(stops, [first])
                self.assertEqual(pulse.events[-2:], [("clear",), ("route", second)])

    def test_late_old_disappearance_cannot_release_new_owner(self):
        self.coordinator.step(snapshot({"airplay": {1}}))
        self.coordinator.step(snapshot({"airplay": {1}, "spotify": {2}}))
        self.coordinator.step(snapshot({"spotify": {2}}))
        self.assertEqual(self.coordinator.owner, "spotify")

    def test_no_fallback_to_preempted_stream_when_owner_stops(self):
        self.coordinator.step(snapshot({"airplay": {1}}))
        self.coordinator.step(snapshot({"airplay": {1}, "spotify": {2}}))
        self.coordinator.step(snapshot({"airplay": {1}}))
        self.assertIsNone(self.coordinator.owner)
        self.coordinator.step(snapshot({"airplay": {1}}))
        self.assertIsNone(self.coordinator.owner)

    def test_preempted_stream_cork_resume_cannot_reclaim(self):
        self.coordinator.step(snapshot({"airplay": {1}}))
        self.coordinator.step(snapshot({"airplay": {1}, "dlna": {2}}))
        self.coordinator.step(snapshot({"dlna": {2}}, {"airplay": {1}}))
        self.coordinator.step(snapshot({"airplay": {1}, "dlna": {2}}))
        self.assertEqual(self.coordinator.owner, "dlna")

    def test_same_tick_has_deterministic_priority_and_stops_both_losers(self):
        self.coordinator.step(snapshot({"spotify": {3}, "dlna": {2}, "airplay": {1}}))
        self.assertEqual(self.coordinator.owner, "airplay")
        self.assertEqual(self.stops, ["dlna", "spotify"])

    def test_new_owner_track_does_not_leave_simultaneous_loser_playing(self):
        self.coordinator.step(snapshot({"airplay": {1}}))
        self.coordinator.step(snapshot({"airplay": {2}, "spotify": {3}}))
        self.assertEqual(self.coordinator.owner, "airplay")
        self.assertEqual(self.stops, ["spotify"])

    def test_old_process_new_stream_during_stopping_is_suppressed(self):
        self.coordinator.step(snapshot({"airplay": {1}}))
        self.coordinator.step(snapshot({"airplay": {1}, "dlna": {2}}))
        self.coordinator.step(snapshot({"airplay": {3}, "dlna": {2}}), {"airplay"})
        self.coordinator.step(snapshot({"airplay": {3}, "dlna": {2}}))
        self.assertEqual(self.coordinator.owner, "dlna")

    def test_fresh_stream_after_receiver_restart_can_take_over(self):
        self.coordinator.step(snapshot({"airplay": {1}}))
        self.coordinator.step(snapshot({"airplay": {1}, "dlna": {2}}))
        self.coordinator.step(snapshot({"dlna": {2}}))
        self.coordinator.step(snapshot({"airplay": {3}, "dlna": {2}}))
        self.assertEqual(self.coordinator.owner, "airplay")

    def test_owner_cork_uncork_reacquires_without_process_restart(self):
        self.coordinator.step(snapshot({"dlna": {1}}))
        self.coordinator.step(snapshot(corked={"dlna": {1}}))
        self.assertIsNone(self.coordinator.owner)
        self.coordinator.step(snapshot({"dlna": {1}}))
        self.assertEqual(self.coordinator.owner, "dlna")
        self.assertEqual(self.stops, [])

    def test_receiver_crash_releases_output(self):
        self.coordinator.step(snapshot({"spotify": {1}}))
        self.coordinator.step(snapshot({"spotify": {1}}), {"spotify"})
        self.assertIsNone(self.coordinator.owner)
        self.assertEqual(self.pulse.events[-1], ("clear",))

    def test_disabled_protocol_cannot_acquire(self):
        coordinator = Coordinator(self.pulse, self.stops.append, ("dlna",))
        coordinator.step(snapshot({"airplay": {1}, "dlna": {2}}))
        self.assertEqual(coordinator.owner, "dlna")

    def test_failed_route_never_sets_new_owner(self):
        self.coordinator.step(snapshot({"airplay": {1}}))
        with patch.object(self.pulse, "route", side_effect=BridgeError("failed")):
            with self.assertRaises(BridgeError):
                self.coordinator.step(snapshot({"dlna": {2}}))
        self.assertIsNone(self.coordinator.owner)
        self.assertIsNone(self.pulse.route_module)


class ConfigurationTests(unittest.TestCase):
    def test_discovery_mode_is_explicit_and_validated(self):
        self.assertEqual(Config.from_env({"AUDIO_MODE": "null"}).avahi_mode, "internal")
        self.assertEqual(Config.from_env({"AUDIO_MODE": "null", "AVAHI_MODE": "external"}).avahi_mode, "external")
        for mode in ("auto", "", "external\n"):
            with self.subTest(mode=mode), self.assertRaises(BridgeError):
                Config.from_env({"AUDIO_MODE": "null", "AVAHI_MODE": mode})

    def test_defaults_require_hardware_device(self):
        with self.assertRaises(BridgeError):
            Config.from_env({})
        self.assertEqual(Config.from_env({"AUDIO_DEVICE": "hw:CARD=USB,DEV=0"}).output_volume, 70)

    def test_null_mode_and_independent_enable_switches(self):
        config = Config.from_env({"AUDIO_MODE": "null", "ENABLE_SPOTIFY": "false", "ENABLE_AIRPLAY": "false"})
        self.assertEqual(config.enabled, ("dlna",))
        self.assertEqual(list(receiver_commands(config, "test")), ["dlna"])

    def test_configuration_injection_and_unstable_devices_rejected(self):
        invalid = {"DEVICE_NAME": ['x"; password="x', "x\ny", "${HOME}", "x" * 51],
                   "AUDIO_DEVICE": ["hw:0,0", "hw:CARD=0,DEV=0", "hw:CARD=USB,DEV=0 sink_name=other"],
                   "SAMPLE_RATE": ["48000\nload-module", "12345", "9" * 5000], "OUTPUT_VOLUME": ["101", "-1"],
                   "NETWORK_INTERFACE": ["eth0\n[reflector]", "../etc", "a" * 16],
                   "ENABLE_DLNA": ["maybe", "1"], "DLNA_PORT": ["4000", "65536"]}
        for key, values in invalid.items():
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(BridgeError):
                    Config.from_env({"AUDIO_MODE": "null", key: value})

    def test_duplicate_enabled_ports_are_rejected(self):
        with self.assertRaises(BridgeError):
            Config.from_env({"AUDIO_MODE": "null", "SPOTIFY_PORT": "7000"})

    def test_generated_configuration_has_no_automatic_hardware_routing(self):
        text = pulse_config(Config(audio_mode="null"))
        self.assertEqual(text.count("load-module module-null-sink"), 5)
        self.assertIn("set-default-sink discard", text)
        self.assertIn("set-sink-mute output yes", text)
        for forbidden in ("rescue-streams", "switch-on-connect", "module-loopback", "module-udev"):
            self.assertNotIn(forbidden, text)

    def test_hardware_output_uses_only_explicit_alsa_device(self):
        text = pulse_config(Config(audio_device="hw:CARD=USB,DEV=0"))
        self.assertEqual(text.count("module-alsa-sink"), 1)
        self.assertIn("device=hw:CARD=USB,DEV=0", text)

    def test_airplay2_configuration_and_real_pulse_backend_name(self):
        text = shairport_config(Config(interface="eth0"), "192.0.2.1")
        self.assertIn('service_type = "airplay2"', text)
        self.assertIn('output_backend = "pulseaudio"', text)
        self.assertIn('sink = "airplay_bus"', text)
        self.assertIn('address = "192.0.2.1"', text)
        self.assertNotIn("run_this", text)
        self.assertIn("allow-interfaces=eth0", avahi_config(Config(interface="eth0")))

    def test_interface_argument_types_differ_between_receivers(self):
        commands = receiver_commands(Config(interface="eth0"), "uuid", "192.0.2.1")
        self.assertEqual(commands["dlna"][-2:], ["--interface-name", "eth0"])
        self.assertEqual(commands["spotify"][-2:], ["--zeroconf-interface", "192.0.2.1"])

    def test_secret_environment_not_forwarded(self):
        with patch.dict("os.environ", {"LIBRESPOT_ACCESS_TOKEN": "private", "RUST_LOG": "trace"}):
            env = child_environment("spotify")
        self.assertNotIn("LIBRESPOT_ACCESS_TOKEN", env)
        self.assertNotIn("RUST_LOG", env)
        self.assertEqual(env["PULSE_SINK"], "spotify_bus")

    def test_identity_is_stable_and_invalid_existing_file_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            first = persistent_uuid(path)
            self.assertEqual(persistent_uuid(path), first)
            (path / "dlna.uuid").write_text("invalid", encoding="ascii")
            with self.assertRaises(BridgeError):
                persistent_uuid(path)
            self.assertEqual((path / "dlna.uuid").read_text(), "invalid")

    def test_atomic_status_replacement_has_no_temporary_remnant(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.json"
            atomic_write(path, '{"owner":null}')
            atomic_write(path, '{"owner":"dlna"}')
            self.assertEqual(json.loads(path.read_text())["owner"], "dlna")
            self.assertFalse(path.with_suffix(".json.tmp").exists())

    def test_machine_identity_is_persistent_and_unique_per_data_directory(self):
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            identity = persistent_machine_id(Path(first))
            self.assertEqual(len(identity), 32)
            self.assertEqual(persistent_machine_id(Path(first)), identity)
            self.assertNotEqual(persistent_machine_id(Path(second)), identity)


class PulseTests(unittest.TestCase):
    def test_routing_argv_and_mute_unload_load_unmute_order(self):
        commands = []
        def run(argv, **kwargs):
            self.assertFalse(kwargs.get("shell", False))
            commands.append(argv[2:])
            return subprocess.CompletedProcess(argv, 0, "17\n" if "load-module" in argv else "")
        pulse = Pulse(run)
        pulse.route_module = 12
        pulse.clear()
        pulse.route("spotify")
        self.assertEqual(commands[0], ["set-sink-mute", "output", "1"])
        self.assertEqual(commands[1], ["unload-module", "12"])
        self.assertEqual(commands[2][0:2], ["load-module", "module-loopback"])
        self.assertIn("source=spotify_bus.monitor", commands[2])
        self.assertEqual(commands[3], ["set-sink-mute", "output", "0"])

    def test_unload_failure_does_not_load_new_route(self):
        calls = []
        def run(argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, int("unload-module" in argv), "")
        pulse = Pulse(run)
        pulse.route_module = 8
        with self.assertRaises(BridgeError):
            pulse.clear()
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][-3:], ["set-sink-mute", "output", "1"])

    def test_failed_unmute_attempts_to_clear_output(self):
        calls = []
        def run(argv, **kwargs):
            calls.append(argv[2:])
            fail = argv[-3:] == ["set-sink-mute", "output", "0"]
            return subprocess.CompletedProcess(argv, int(fail), "7" if "load-module" in argv else "")
        pulse = Pulse(run)
        with self.assertRaises(BridgeError):
            pulse.route("dlna")
        self.assertEqual(calls[-2:], [["set-sink-mute", "output", "1"], ["unload-module", "7"]])
        self.assertIsNone(pulse.route_module)

    def test_pactl_output_and_metadata_are_not_exposed_on_failure(self):
        pulse = Pulse(lambda argv, **kwargs: subprocess.CompletedProcess(argv, 1, "private", "private"))
        with self.assertRaises(BridgeError) as caught:
            pulse.command("info")
        self.assertNotIn("private", str(caught.exception))

    def inventory(self, inputs):
        sinks = [{"index": i, "name": name} for i, name in enumerate(
            ["airplay_bus", "dlna_bus", "spotify_bus", "discard", "output"])]
        pulse = Pulse()
        pulse.listing = lambda kind: sinks if kind == "sinks" else inputs
        return pulse

    def test_stream_inventory_distinguishes_corked(self):
        result = self.inventory([{"index": 9, "sink": 0, "corked": False},
                                 {"index": 10, "sink": 1, "corked": True}]).snapshot()
        self.assertEqual(result.active_ids["airplay"], {9})
        self.assertEqual(result.active_ids["dlna"], set())
        self.assertEqual(result.all_ids["dlna"], {10})

    def test_missing_corked_field_is_fatal_not_assumed_active(self):
        with self.assertRaises(BridgeError):
            self.inventory([{"index": 9, "sink": 0}]).snapshot()

    def test_direct_output_client_without_module_is_rejected(self):
        with self.assertRaises(BridgeError):
            self.inventory([{"index": 9, "sink": 4, "owner_module": None}]).snapshot()

    def test_only_current_loopback_can_write_output(self):
        for module in (4, "4"):
            with self.subTest(module=module):
                pulse = self.inventory([{"index": 9, "sink": 4, "owner_module": module}])
                pulse.route_module = 4
                self.assertEqual(pulse.snapshot().active_ids["airplay"], set())

    def test_foreign_or_malformed_output_owner_modules_are_rejected(self):
        for module in (5, "5", None, "bad", True, 4.0, ""):
            with self.subTest(module=module):
                pulse = self.inventory([{"index": 9, "sink": 4, "owner_module": module}])
                pulse.route_module = 4
                with self.assertRaises(BridgeError):
                    pulse.snapshot()


class Process:
    counter = 100
    def __init__(self):
        Process.counter += 1
        self.pid = Process.counter
        self.returncode = None
    def poll(self):
        return self.returncode


class SupervisorTests(unittest.TestCase):
    def setUp(self):
        # The deployed runtime is Linux; keep its injected process model testable
        # on a Windows development host without exercising Windows process APIs.
        self.signal_patch = patch.object(signal, "SIGKILL", 9, create=True)
        self.signal_patch.start()
        self.addCleanup(self.signal_patch.stop)
        self.signals = []
        self.supervisor = Supervisor(lambda *args, **kwargs: Process(), lambda pid, sig: self.signals.append((pid, sig)))
        self.supervisor.add("dlna", ["gmediarender"])

    def test_preemption_is_nonblocking_and_restarts_after_exit(self):
        self.supervisor.tick(0)
        child = self.supervisor.children["dlna"]
        old_pid = child.process.pid
        self.supervisor.preempt("dlna")
        self.assertEqual(child.state, "stopping")
        self.assertEqual(self.signals, [(old_pid, signal.SIGTERM)])
        child.process.returncode = -15
        self.supervisor.tick(1)
        self.assertEqual(child.state, "backoff")
        self.supervisor.tick(1.4)
        self.assertEqual(child.state, "running")
        self.assertNotEqual(child.process.pid, old_pid)
        self.assertEqual(child.restarts, 1)

    def test_slow_receiver_is_force_stopped_after_deadline(self):
        self.supervisor.tick(0)
        child = self.supervisor.children["dlna"]
        self.supervisor.preempt("dlna")
        self.supervisor.tick(child.deadline + 0.1)
        self.assertEqual(self.signals[-1][1], signal.SIGKILL)

    def test_core_exit_is_fatal(self):
        self.supervisor.add("pulse", ["pulseaudio"], core=True)
        self.supervisor.tick(0)
        self.supervisor.children["pulse"].process.returncode = 1
        with self.assertRaises(BridgeError):
            self.supervisor.tick(1)

    def test_crash_backoff_is_bounded_and_stable_run_resets_it(self):
        child = self.supervisor.children["dlna"]
        delays = []
        for i in range(10):
            self.supervisor.schedule_failure(child, i * 100)
            delays.append(child.next_start - i * 100)
        self.assertEqual(delays[:4], [1, 2, 4, 8])
        self.assertEqual(max(delays), 30)
        self.supervisor.start(child, 1000)
        self.supervisor.tick(1061)
        self.assertEqual(child.failures, 0)

    def test_failed_spawn_schedules_receiver_backoff(self):
        self.supervisor.popen = lambda *args, **kwargs: (_ for _ in ()).throw(FileNotFoundError())
        self.supervisor.tick(0)
        self.assertEqual(self.supervisor.children["dlna"].state, "backoff")

    def test_status_does_not_include_command_environment_or_cache(self):
        text = json.dumps(self.supervisor.statuses())
        self.assertNotIn("argv", text)
        self.assertNotIn("cache", text)
        self.assertNotIn("environment", text)

    def test_failed_single_instance_lock_does_not_touch_other_runtime(self):
        runtime = Runtime(Config(audio_mode="null"))
        with patch.object(runtime, "prepare", side_effect=BridgeError("locked")), \
             patch.object(runtime.pulse, "clear") as clear, patch("signal.signal"):
            self.assertEqual(runtime.run(), 1)
            clear.assert_not_called()


class HealthTests(unittest.TestCase):
    def status(self):
        return {"pid": 1, "heartbeat_unix": 100, "state": "idle", "owner": None,
                "route_module": None, "enabled": ["dlna"], "children": {
                    name: {"state": "running", "pid": i + 2}
                    for i, name in enumerate(("dbus", "avahi", "pulse", "dlna"))}}

    def test_idle_is_healthy_without_output_route(self):
        self.assertTrue(healthy(self.status(), 101, lambda pid: None))

    def test_external_discovery_does_not_require_private_daemons(self):
        status = self.status()
        status["avahi_mode"] = "external"
        del status["children"]["dbus"]
        del status["children"]["avahi"]
        self.assertTrue(healthy(status, 101, lambda pid: None))
        for mode in ("internal", "unknown"):
            status["avahi_mode"] = mode
            self.assertFalse(healthy(status, 101, lambda pid: None))

    def test_external_health_requires_responsive_host_discovery(self):
        status = self.status()
        status["avahi_mode"] = "external"
        with patch.object(Path, "read_text", return_value=json.dumps(status)), \
             patch.object(healthcheck, "healthy", return_value=True), \
             patch.object(healthcheck, "avahi_available", return_value=False), \
             patch.object(healthcheck.subprocess, "run") as pulse_probe:
            self.assertEqual(healthcheck.main(), 1)
            pulse_probe.assert_not_called()

    def test_stale_or_future_heartbeat_fails(self):
        for now in (99, 111):
            self.assertFalse(healthy(self.status(), now, lambda pid: None))

    def test_dead_or_restarting_receiver_fails(self):
        status = self.status()
        status["children"]["dlna"]["state"] = "backoff"
        self.assertFalse(healthy(status, 101, lambda pid: None))
        self.assertFalse(healthy(self.status(), 101, lambda pid: (_ for _ in ()).throw(ProcessLookupError())))

    def test_playing_requires_matching_enabled_owner_and_route(self):
        status = self.status()
        status.update(state="playing", owner="dlna", route_module=7)
        self.assertTrue(healthy(status, 101, lambda pid: None))
        status["route_module"] = None
        self.assertFalse(healthy(status, 101, lambda pid: None))


class ReadinessTests(unittest.TestCase):
    def test_external_start_never_launches_a_second_mdns_stack(self):
        runtime = Runtime(Config(audio_mode="null", avahi_mode="external", enabled=()))
        runtime.commands = {}
        with patch.object(runtime.supervisor, "add") as add, \
             patch.object(runtime, "wait_ready") as wait, \
             patch.object(runtime.pulse, "clear"):
            runtime.start()
        self.assertEqual([call.args[0] for call in add.call_args_list], ["pulse"])
        self.assertIs(wait.call_args_list[0].args[0], avahi_available)

    def test_external_discovery_failure_exits_instead_of_false_healthy(self):
        runtime = Runtime(Config(audio_mode="null", avahi_mode="external"))
        with patch("runtime.avahi_available", return_value=True) as probe:
            runtime.check_discovery(10)
            runtime.check_discovery(11)
            self.assertEqual(probe.call_count, 1)
        with patch("runtime.avahi_available", return_value=False), self.assertRaisesRegex(BridgeError, "External Avahi"):
            runtime.check_discovery(15)

    def test_internal_discovery_uses_its_supervised_processes(self):
        runtime = Runtime(Config(audio_mode="null"))
        with patch("runtime.avahi_available") as probe:
            runtime.check_discovery(10)
            probe.assert_not_called()

    def test_discovery_probe_handles_unavailable_bus_without_exposing_reply(self):
        for result in (FileNotFoundError(), subprocess.TimeoutExpired("dbus-send", 2)):
            with self.subTest(error=type(result).__name__), patch("runtime.subprocess.run", side_effect=result):
                self.assertFalse(avahi_available())
        with patch("runtime.subprocess.run", return_value=subprocess.CompletedProcess([], 1)):
            self.assertFalse(avahi_available())

    def test_nqptp_readiness_requires_its_own_socket_inodes(self):
        table = "header\n" + "\n".join(
            f"0: 00000000:{port:04X} 00000000:0000 07 0 0 0 0 0 {inode}"
            for port, inode in ((319, 42), (320, 43), (9000, 44), (9001, 99)))
        with patch.object(Path, "iterdir", return_value=[Path("1"), Path("2"), Path("3")]), \
             patch("runtime.os.readlink", side_effect=["socket:[42]", "socket:[43]", "socket:[44]"]), \
             patch.object(Path, "exists", return_value=True), patch.object(Path, "read_text", return_value=table):
            self.assertTrue(owns_udp_ports(123, {319, 320, 9000}))
        with patch.object(Path, "iterdir", return_value=[Path("1")]), \
             patch("runtime.os.readlink", return_value="socket:[42]"), \
             patch.object(Path, "exists", return_value=True), patch.object(Path, "read_text", return_value=table):
            self.assertFalse(owns_udp_ports(123, {319, 320, 9000}))


if __name__ == "__main__":
    unittest.main()
