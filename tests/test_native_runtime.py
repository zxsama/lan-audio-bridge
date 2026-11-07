"""Direct desktop routing must preserve phone isolation and fail closed."""
import json
import math
from pathlib import Path
import subprocess
import sys
import socket
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
from runtime import BridgeError, Config, NativePulse, SOURCES, pulse_config, receiver_commands
from native_control import NativeControlError, remove_stale_socket
from healthcheck import healthy


def receiver(pid=123, active=False, index=100):
    return {"ok": True, "pid": pid, "active": active, "sink_input": index, "phone": None,
            "state": "playing" if active else "idle"}


class NativeConfigTests(unittest.TestCase):
    def test_opt_in_has_no_desktop_null_or_loopback_handshake(self):
        config = Config.from_env({"AUDIO_MODE": "null", "ENABLE_DESKTOP": "true",
                                  "VBAN_SOURCE_IP": "192.0.2.10", "DESKTOP_BACKEND": "native"})
        command = receiver_commands(config, "test")["desktop"]
        self.assertEqual(command[0], "vban-pulse")
        self.assertIn("--managed", command)
        self.assertNotIn("--runtime-status", command)
        self.assertNotIn("desktop_bus", pulse_config(config))
        self.assertEqual(config.desktop_native_latency_ms, 16)
        self.assertEqual(config.desktop_native_jitter_ms, 8)
        # Defaults keep the immediate idle suspend and normal priority.
        self.assertEqual(command[command.index("--suspend-delay-ms") + 1], "0")
        self.assertNotIn("--realtime", command)

    def test_idle_suspend_delay_and_realtime_reach_the_receiver(self):
        config = Config.from_env({"AUDIO_MODE": "null", "ENABLE_DESKTOP": "true", "VBAN_SOURCE_IP": "192.0.2.10",
                                  "DESKTOP_BACKEND": "native", "OUTPUT_IDLE_SUSPEND_MS": "60000",
                                  "PULSE_REALTIME": "true"})
        command = receiver_commands(config, "test")["desktop"]
        self.assertEqual(command[command.index("--suspend-delay-ms") + 1], "60000")
        self.assertIn("--realtime", command)
        for value in ("-1", "600001", "1e3"):
            with self.subTest(value=value), self.assertRaises(BridgeError):
                Config.from_env({"AUDIO_MODE": "null", "OUTPUT_IDLE_SUSPEND_MS": value})

    def test_default_retains_existing_receiver(self):
        config = Config(desktop_enabled=True)
        self.assertEqual(receiver_commands(config, "test")["desktop"][0], "python3")
        self.assertIn("desktop_bus", pulse_config(config))

    def test_invalid_backend_and_limits_are_rejected(self):
        for key, value in (("DESKTOP_BACKEND", "unknown"), ("DESKTOP_NATIVE_LATENCY_MS", "0"),
                           ("DESKTOP_NATIVE_LATENCY_MS", "31"), ("DESKTOP_NATIVE_JITTER_MS", "0"),
                           ("DESKTOP_NATIVE_JITTER_MS", "21")):
            with self.subTest(key=key, value=value), self.assertRaises(BridgeError):
                Config.from_env({"AUDIO_MODE": "null", key: value})

    def test_tone_measurement_tracks_bounded_clock_offset_without_hiding_wrong_gain(self):
        from desktop_audio import clock_corrected_amplitude
        samples = [5000 * math.sin(2 * math.pi * 1300 * 0.998 * n / 48000)
                   + 3000 * math.sin(2 * math.pi * 660 * n / 48000) for n in range(24000)]
        self.assertAlmostEqual(clock_corrected_amplitude(samples, 1300), 5000, delta=100)
        self.assertAlmostEqual(clock_corrected_amplitude(samples, 660), 3000, delta=100)
        self.assertLess(clock_corrected_amplitude(samples, 1100), 100)


class NativeRoutingTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.failure = Mock()
        self.streams = [{"index": 100, "sink": 0, "owner_module": None, "corked": True,
                         "properties": {"application.name": "lan-audio-bridge-desktop-native",
                                        "application.process.id": "123"}},
                        {"index": 99, "sink": 1, "owner_module": "42", "corked": False}]
        self.pulse = NativePulse(runner=self.run_command, desktop_enabled=True, on_native_failure=self.failure)

    def run_command(self, args, **kwargs):
        command = args[2:]
        self.events.append(command)
        result = ""
        if command[:2] == ["--format=json", "list"]:
            if command[2] == "sink-inputs":
                result = json.dumps(self.streams)
            else:
                result = json.dumps([{"index": i, "name": name} for i, name in
                                     enumerate(["output", "discard", *(s + "_bus" for s in SOURCES)])])
        elif command[0] == "load-module":
            result = "42"
        return subprocess.CompletedProcess(args, 0, result, "")

    def respond(self, path, command, timeout=2.0):
        self.events.append(["native", command])
        value = receiver(active=True)
        if command.startswith("PHONE ") and command != "PHONE -1":
            value["phone"] = int(command[6:])
        if command == "HOLD":
            value["phone_pending"] = True
        return value

    def ready(self):
        with patch("native_desktop.request", side_effect=self.respond):
            self.pulse.refresh_native(123)

    def test_first_registration_precedes_audio_enable(self):
        self.ready()
        native = [event for event in self.events if event[0] == "native"]
        self.assertEqual(native, [["native", "STATUS"], ["native", "GAIN 1.0"], ["native", "PHONE -1"]])
        self.assertTrue(self.pulse.desktop_active)

    def test_phone_gain_ack_precedes_move_to_output(self):
        self.ready()
        self.events.clear()
        with patch("native_desktop.request", side_effect=self.respond):
            self.pulse.route("dlna")
        self.assertLess(self.events.index(["native", "PHONE 99"]),
                        self.events.index(["move-sink-input", "99", "output"]))
        self.assertTrue(any("sink=discard" in event for event in self.events))

    def test_phone_stop_does_not_suspend_playing_desktop(self):
        self.ready()
        self.pulse.route_module = 42
        self.events.clear()
        with patch("native_desktop.request", side_effect=self.respond):
            self.pulse.clear()
        self.assertIn(["unload-module", "42"], self.events)
        self.assertIn(["native", "PHONE -1"], self.events)
        self.assertNotIn(["suspend-sink", "output", "1"], self.events)

    def test_phone_takeover_reserves_headroom_before_unloading_old_route(self):
        self.ready()
        self.pulse.route_module = 42
        self.pulse.defer_gain_refresh = True
        self.events.clear()
        with patch("native_desktop.request", side_effect=self.respond):
            self.pulse.clear()
        self.assertLess(self.events.index(["native", "HOLD"]),
                        self.events.index(["unload-module", "42"]))
        self.assertNotIn(["native", "PHONE -1"], self.events)
        self.assertNotIn(["suspend-sink", "output", "1"], self.events)

    def test_unknown_direct_output_input_is_rejected(self):
        self.ready()
        self.pulse.snapshot()
        for change in ({"index": 101}, {"properties": {"application.name": "other",
                                                       "application.process.id": "123"}},
                       {"properties": {"application.name": "lan-audio-bridge-desktop-native",
                                        "application.process.id": "124"}}):
            previous = self.streams[0]
            self.streams[0] = {**previous, **change}
            with self.assertRaises(BridgeError):
                self.pulse.snapshot()
            self.streams[0] = previous

    def test_stalled_receiver_is_muted_without_stopping_phone(self):
        self.ready()
        self.pulse.route_module = 42
        self.events.clear()
        with patch("native_desktop.request", side_effect=NativeControlError("unavailable")):
            self.pulse.refresh_native(123)
        self.failure.assert_called_once()
        self.assertIn(["set-sink-input-mute", "100", "1"], self.events)
        self.assertIn(["set-sink-input-volume", "99", "65536"], self.events)
        self.assertNotIn(["unload-module", "42"], self.events)
        self.assertNotIn(["suspend-sink", "output", "1"], self.events)

    def test_new_receiver_synchronizes_existing_phone(self):
        self.pulse.route_module = 42
        self.ready()
        self.assertIn(["native", "PHONE 99"], self.events)

    def test_wrong_identity_never_becomes_ready(self):
        with patch("native_desktop.request", return_value=receiver(pid=124)):
            self.pulse.refresh_native(123)
        self.assertFalse(self.pulse.native_ready)
        self.assertFalse(self.pulse.desktop_active)

    def test_receiver_can_exit_between_listing_and_mute(self):
        self.ready()
        self.pulse.route_module = 42
        ordinary = self.pulse.command
        def disappear(*args):
            if args == ("set-sink-input-mute", "100", "1"):
                self.streams[:] = [s for s in self.streams if s["index"] != 100]
                raise BridgeError("PulseAudio control command failed")
            return ordinary(*args)
        with patch.object(self.pulse, "command", side_effect=disappear), \
                patch("native_desktop.request", side_effect=NativeControlError("unavailable")):
            self.pulse.refresh_native(123)
        self.failure.assert_called_once()
        self.assertIn(["set-sink-input-volume", "99", "65536"], self.events)

    def test_dead_process_stream_is_allowed_only_until_pulse_removes_it(self):
        self.ready()
        self.pulse.refresh_native(None)
        self.pulse.snapshot()
        self.assertEqual(self.pulse.retiring_native, {("123", 100)})
        self.streams[:] = [s for s in self.streams if s["index"] != 100]
        self.pulse.refresh_native(None)
        self.assertEqual(self.pulse.retiring_native, set())
        self.assertFalse(self.pulse._allowed_output_stream({"index": 100, "owner_module": None,
            "properties": {"application.name": "lan-audio-bridge-desktop-native", "application.process.id": "123"}}))

    def test_retiring_cleanup_never_mutes_new_receiver(self):
        self.ready()
        self.streams.append({"index": 101, "sink": 0, "owner_module": None, "corked": True,
                             "properties": {"application.name": "lan-audio-bridge-desktop-native",
                                            "application.process.id": "124"}})
        self.events.clear()
        with patch("native_desktop.request", return_value=receiver(pid=124, index=101)):
            self.pulse.refresh_native(124)
            self.pulse.refresh_native(124)
        self.assertTrue(self.pulse.native_ready)
        self.assertIn(["set-sink-input-mute", "100", "1"], self.events)
        self.assertNotIn(["set-sink-input-mute", "101", "1"], self.events)
        self.pulse.snapshot()


class NativeHealthTests(unittest.TestCase):
    def status(self, active=False):
        return {"pid": 1, "heartbeat_unix": 10, "state": "playing" if active else "idle",
                "owner": None, "enabled": [], "avahi_mode": "external", "route_module": None,
                "children": {"pulse": {"pid": 2, "state": "running"},
                             "desktop": {"pid": 3, "state": "running"}},
                "desktop": {"enabled": True, "active": active, "backend": "native",
                            "ready": True, "sink_input": 100, "route_module": None}}

    def test_corked_native_stream_can_be_idle(self):
        self.assertTrue(healthy(self.status(), 10, lambda pid: None))

    def test_active_native_stream_uses_index_not_loopback_module(self):
        self.assertTrue(healthy(self.status(True), 10, lambda pid: None))

    def test_unready_native_and_invalid_index_are_unhealthy(self):
        for change in ({"ready": False}, {"sink_input": None}, {"sink_input": True},
                       {"sink_input": 0xffffffff}, {"backend": "unknown"}):
            value = self.status()
            value["desktop"].update(change)
            self.assertFalse(healthy(value, 10, lambda pid: None))


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux Unix datagram socket lifecycle")
class NativeSocketTests(unittest.TestCase):
    def test_dead_socket_is_removed_without_removing_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as server:
                server.bind(str(path))
            remove_stale_socket(path)
            self.assertFalse(path.exists())
            self.assertTrue(Path(directory).is_dir())

    def test_live_socket_and_regular_file_are_never_removed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "control.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as server:
                server.bind(str(path))
                with self.assertRaises(OSError):
                    remove_stale_socket(path)
                self.assertTrue(path.exists())
            path.unlink()
            path.write_text("preserve")
            with self.assertRaises(OSError):
                remove_stale_socket(path)
            self.assertEqual(path.read_text(), "preserve")


if __name__ == "__main__":
    unittest.main()
