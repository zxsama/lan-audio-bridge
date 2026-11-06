"""Offline VBAN protocol, lifecycle and bounded playback tests."""
from pathlib import Path
import json
import struct
import sys
import tempfile
import unittest
import uuid
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))
from vban_receiver import (BYTE_RATE, HEADER, Packet, Playback, PulsePlayer,
                           Stream, arguments, parse_packet, publish, route_ready,
                           stream_bytes)

SOURCE = "192.0.2.10"


def packet(sequence=0, samples=240, value=1, name="Windows", **fields):
    return HEADER.pack(fields.get("magic", b"VBAN"), fields.get("rate", 3),
                       samples - 1, fields.get("channels", 1), fields.get("encoding", 1),
                       name.encode().ljust(16, b"\0"), sequence) + struct.pack("<hh", value, value) * samples


class ProtocolTests(unittest.TestCase):
    def test_wire_header_and_little_endian_sequence(self):
        self.assertEqual(HEADER.size, 28)
        data = packet(0x78563412, samples=256, value=-32768)
        self.assertEqual(data[24:28], b"\x12\x34\x56\x78")
        decoded = parse_packet(data, b"Windows")
        self.assertEqual(decoded, Packet(0x78563412, b"\0\x80\0\x80" * 256))
        self.assertEqual(len(parse_packet(packet(samples=1), b"Windows").pcm), 4)

    def test_rejects_wrong_protocol_codec_reserved_bits_and_format(self):
        for fields in ({"magic": b"XXXX"}, {"rate": 0x23}, {"rate": 16},
                       {"rate": 31}, {"channels": 0}, {"channels": 255},
                       {"encoding": 2}, {"encoding": 0x11}, {"encoding": 0x09}):
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                parse_packet(packet(**fields), b"Windows")

    def test_exact_length_and_stream_required(self):
        valid = packet()
        for data in (b"", valid[:27], valid[:-1], valid + b"\0", packet(name="Other")):
            with self.subTest(length=len(data)), self.assertRaises(ValueError):
                parse_packet(data, b"Windows")

    def test_utf8_name_length_and_full_16_byte_name(self):
        for name in ("", "a" * 17, "声" * 6, "A\0B"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                stream_bytes(name)
        name = "a" * 16
        self.assertEqual(parse_packet(packet(name=name), stream_bytes(name)).sequence, 0)
        self.assertEqual(parse_packet(packet(name="电脑"), stream_bytes("电脑")).sequence, 0)

    def test_cli_requires_valid_source_and_bounds(self):
        for options in ([], ["--source-ip", "0.0.0.0"], ["--source-ip", "224.1.1.1"],
                        ["--source-ip", "::1"], ["--source-ip", SOURCE, "--latency-ms", "0"],
                        ["--source-ip", SOURCE, "--port", "65536"]):
            with self.subTest(options=options), patch("sys.stderr"), self.assertRaises(SystemExit):
                arguments(options)
        parsed = arguments(["--source-ip", SOURCE])
        self.assertEqual((parsed.port, parsed.latency_ms, parsed.idle_ms), (6980, 30, 500))
        self.assertEqual(arguments(["--source-ip", SOURCE, "--idle-ms", "5000"]).idle_ms, 5000)


class StreamTests(unittest.TestCase):
    def setUp(self):
        self.stream = Stream(SOURCE, "Windows")

    def receive(self, sequence=0, now=0, **kwargs):
        return self.stream.receive(packet(sequence, **kwargs), SOURCE, now)

    def test_startup_silence_never_requests_route(self):
        for sequence in range(1000):
            self.receive(sequence, sequence / 200, value=0)
        self.assertFalse(self.stream.active)
        self.assertEqual(self.stream.queued_bytes, 0)
        self.receive(1000, 5, value=1)  # Lowest nonzero value must not be gated.
        self.assertTrue(self.stream.active)

    def test_duplicates_out_of_order_and_uint32_wrap(self):
        self.receive(0xFFFFFFFE)
        self.receive(0xFFFFFFFF, .005)
        self.receive(0, .01)
        self.assertFalse(self.receive(0, .2))
        self.assertFalse(self.receive(0xFFFFFFFF, .3))
        self.assertEqual(self.stream.last_valid, .01)
        self.assertEqual(self.stream.statistics["duplicates"], 1)
        self.assertEqual(self.stream.statistics["out_of_order"], 1)
        self.assertEqual(self.stream.statistics["missing_packets"], 0)

    def test_invalid_and_wrong_source_do_not_extend_active_session(self):
        self.receive()
        self.stream.receive(packet(1), "192.0.2.11", .4)
        self.stream.receive(b"VBAN", SOURCE, .4)
        self.stream.receive(packet(1, name="Other"), SOURCE, .4)
        self.assertEqual(self.stream.last_valid, 0)
        self.assertTrue(self.stream.ending(.501))

    def test_zero_silence_expires_even_while_valid_packets_continue(self):
        self.receive()
        for sequence in range(1, 103):
            self.receive(sequence, sequence / 200, value=0)
        self.assertTrue(self.stream.ending(.51))
        self.assertEqual(self.stream.last_nonzero, 0)

    def test_counter_restart_and_new_generation_after_idle(self):
        self.receive(100)
        first = self.stream.generation
        self.stream.stop()
        self.assertTrue(self.receive(0, .6))
        self.assertNotEqual(self.stream.generation, first)
        self.assertEqual(self.stream.sequence, 0)

    def test_small_gaps_concealed_large_gaps_do_not_allocate_unbounded(self):
        self.receive(0)
        self.receive(2, .01)
        self.assertEqual(self.stream.queue[1][1], bytes(960))
        self.receive(0x70000000, .02)
        self.assertEqual(self.stream.queued_bytes, 960)
        self.assertEqual(self.stream.statistics["discontinuities"], 1)

    def test_queue_has_byte_and_wall_clock_bounds_under_flood(self):
        self.stream.playback_started = True
        for sequence in range(1000):
            self.receive(sequence, .01)
            self.stream.playback_started = True
        self.assertLessEqual(self.stream.queued_bytes, BYTE_RATE / 2)
        self.assertGreater(self.stream.statistics["queue_dropped_bytes"], 0)
        self.stream.trim(.511)
        self.assertEqual(self.stream.queued_bytes, 0)


class FakePlayer:
    def __init__(self, sink="", latency=0):
        self.writes = []
        self.closed = False
        self.blocked = False
        self.failed = False

    def check(self):
        if self.failed:
            raise RuntimeError("player exited")

    def write(self, pcm):
        if self.blocked:
            return 0
        self.writes.append(pcm)
        return len(pcm)

    def close(self):
        self.closed = True


class PlaybackTests(unittest.TestCase):
    def setUp(self):
        self.stream = Stream(SOURCE, "Windows")
        self.player = FakePlayer()
        self.ready = False
        self.factory = Mock(return_value=self.player)
        self.playback = Playback(self.stream, "desktop_bus", 30, Path("status.json"),
                                 self.factory, lambda path, generation: self.ready)

    def receive(self, sequence=0, now=0, **kwargs):
        self.stream.receive(packet(sequence, **kwargs), SOURCE, now)

    def test_notification_preserved_until_route_ack(self):
        self.receive(value=123)
        self.playback.tick(.03)
        self.playback.tick(.15)
        self.factory.assert_not_called()
        self.ready = True
        self.playback.tick(.2)
        self.assertEqual(b"".join(self.player.writes), packet(value=123)[28:])
        self.playback.tick(.501)
        self.assertFalse(self.stream.active)
        self.assertTrue(self.player.closed)

    def test_cold_route_preserves_onset_for_full_ack_deadline(self):
        self.receive(value=123)
        self.playback.tick(.51)
        self.assertEqual(self.stream.queued_bytes, 960)
        self.ready = True
        self.playback.tick(.6)
        self.assertEqual(b"".join(self.player.writes), packet(value=123)[28:])
        self.playback.tick(.61)
        self.assertTrue(self.stream.active)
        self.playback.tick(.74)
        self.assertFalse(self.stream.active)

    def test_long_route_tail_drains_and_new_audio_resumes_without_new_session(self):
        self.stream.idle_seconds = .2
        self.playback.drain_seconds = .58  # 500ms loopback + 30ms client + 50ms margin.
        self.ready = True
        self.receive()
        self.playback.tick(.02)
        generation = self.stream.generation
        self.playback.tick(.21)
        self.assertTrue(self.stream.active)
        count = len(self.player.writes)
        self.playback.tick(.3)
        self.assertEqual(len(self.player.writes), count)  # No zero fill while draining.
        self.receive(1, .31)
        self.playback.tick(.31)
        self.assertEqual(self.stream.generation, generation)
        self.playback.tick(.52)
        self.assertTrue(self.stream.active)
        self.playback.tick(.9)
        self.assertFalse(self.stream.active)

    def test_initial_latency_and_no_early_burst(self):
        self.ready = True
        self.receive(0)
        self.receive(1, .005)
        self.playback.tick(.01)
        self.factory.assert_not_called()
        self.playback.tick(.03)
        self.playback.tick(.031)
        self.assertEqual(len(self.player.writes), 1)
        self.playback.tick(.0351)
        self.assertEqual(len(self.player.writes), 2)

    def test_one_sample_packets_follow_realtime_not_one_packet_per_tick(self):
        self.ready = True
        for sequence in range(240):
            self.receive(sequence, 0, samples=1)
        self.playback.tick(.02)
        self.playback.tick(.021)
        self.assertGreaterEqual(self.stream.statistics["played_bytes"], 48 * 4)
        self.assertLessEqual(self.stream.statistics["played_bytes"], 50 * 4)

    def test_underflow_padding_flushes_short_notification_without_extending_idle(self):
        self.ready = True
        self.receive(samples=1, value=1)
        self.playback.tick(.02)
        for index in range(1, 50):
            self.playback.tick(.02 + index / 1000)
        played = b"".join(self.player.writes)
        self.assertEqual(played[:4], b"\x01\0\x01\0")
        self.assertFalse(any(played[4:]))
        self.assertGreater(len(played), BYTE_RATE * .03)
        self.assertEqual(self.stream.last_nonzero, 0)
        self.assertEqual(self.stream.last_valid, 0)
        self.playback.tick(.501)
        self.assertFalse(self.stream.active)

    def test_missing_route_times_out_during_continuous_input(self):
        for sequence in range(401):
            now = sequence / 200
            self.receive(sequence, now)
            self.playback.tick(now)
        self.receive(401, 2.005)
        with self.assertRaisesRegex(RuntimeError, "acknowledgement timed out"):
            self.playback.tick(2.005)
        self.factory.assert_not_called()

    def test_route_loss_and_player_failure_propagate_for_restart(self):
        self.receive()
        self.ready = True
        self.playback.tick(.03)
        self.ready = False
        with self.assertRaisesRegex(RuntimeError, "acknowledgement was lost"):
            self.playback.tick(.04)
        self.playback.close()
        self.assertTrue(self.player.closed)

    def test_child_exit_detected_even_when_queue_empty(self):
        self.receive()
        self.ready = True
        self.playback.tick(.03)
        self.player.failed = True
        with self.assertRaisesRegex(RuntimeError, "player exited"):
            self.playback.tick(.04)

    def test_blocked_pipe_does_not_block_input_or_grow_queue(self):
        self.ready = True
        self.player.blocked = True
        self.receive()
        self.playback.tick(.03)
        for sequence in range(1, 106):
            self.receive(sequence, sequence / 200)
            self.playback.tick(sequence / 200)
        self.receive(106, .53)
        with self.assertRaisesRegex(RuntimeError, "remained blocked"):
            self.playback.tick(.531)
        self.assertLessEqual(self.stream.queued_bytes, BYTE_RATE / 2)

    def test_silent_idle_stops_and_recovers_to_new_handshake(self):
        self.ready = True
        self.receive()
        self.playback.tick(.03)
        for sequence in range(1, 104):
            now = sequence / 200 + .03
            self.receive(sequence, now, value=0)
            self.playback.tick(now)
        self.assertFalse(self.stream.active)
        self.assertTrue(self.player.closed)
        generation = self.stream.generation
        self.ready = False
        self.receive(104, .56, value=-1)
        self.playback.tick(.60)
        self.assertTrue(self.stream.active)
        self.assertNotEqual(generation, self.stream.generation)
        self.assertEqual(self.factory.call_count, 1)


class ClockedPlayer(FakePlayer):
    """Finite downstream storage and a consumer clock, without wall-clock sleeps.

    This models backpressure and sample conservation, not Pulse's exact buffer
    implementation or its hardware latency.
    """

    def __init__(self):
        super().__init__()
        self.capacity = BYTE_RATE * 60 // 1000
        self.prebuffer = BYTE_RATE * 40 // 1000
        self.pending = 0
        self.started = False
        self.now = 0.0
        self.fraction = 0.0
        self.underrun_bytes = 0

    def advance(self, now):
        if self.started:
            available = (now - self.now) * BYTE_RATE + self.fraction
            consumed = int(available / 4) * 4
            self.fraction = available - consumed
            self.underrun_bytes += max(0, consumed - self.pending)
            self.pending = max(0, self.pending - consumed)
        self.now = now

    def write(self, pcm):
        if self.pending + len(pcm) > self.capacity:
            return 0
        self.pending += len(pcm)
        self.started |= self.pending >= self.prebuffer
        return super().write(pcm)


class PlaybackClockTests(unittest.TestCase):
    def simulate(self, stall_ms=0, sender_ppm=0, seconds=60):
        stream = Stream(SOURCE, "Windows")
        player = ClockedPlayer()
        playback = Playback(stream, "desktop_bus", 30, Path("unused"),
                            lambda *args: player, lambda *args: True)
        interval = .005 / (1 + sender_ppm / 1_000_000)
        sequence = 0
        expected = bytearray()
        high_water = 0
        settled = []
        for milliseconds in range(seconds * 1000):
            now = milliseconds / 1000
            player.advance(now)
            if stall_ms and milliseconds >= 1000 and 0 < milliseconds % 1000 <= stall_ms:
                continue
            while sequence * interval <= now:
                data = packet(sequence, value=sequence % 32766 + 1)
                expected.extend(data[HEADER.size:])
                stream.receive(data, SOURCE, now)
                sequence += 1
            playback.tick(now)
            high_water = max(high_water, stream.queued_bytes)
            if milliseconds >= 1000 and milliseconds % 1000 == 100:
                settled.append(stream.queued_bytes)
        return stream, player, expected, high_water, settled

    def test_repeated_scheduler_stalls_recover_without_dropping_or_zero_fill(self):
        stream, player, expected, high_water, settled = self.simulate(stall_ms=30)
        # The old now-10ms deadline ratcheted to ~490ms within 30 seconds.
        self.assertLessEqual(high_water, BYTE_RATE * .060)
        self.assertTrue(settled)
        self.assertLessEqual(max(settled), BYTE_RATE * .025)
        self.assertEqual(stream.statistics["queue_dropped_bytes"], 0)
        self.assertEqual(stream.statistics["underrun_fill_bytes"], 0)
        self.assertEqual(player.underrun_bytes, 0)
        played = b"".join(player.writes)
        remaining = b"".join(pcm for _, pcm in stream.queue)
        self.assertEqual(played + remaining, expected)

    def test_clock_offsets_remain_observable_instead_of_hidden_by_silence(self):
        # This is deliberately a finite 20-second skew check. Keeping the PCM
        # unchanged cannot solve arbitrary long-term independent clock drift;
        # +/-500ppm must appear as +/-10ms of queue change, not silent padding.
        queues = {}
        for ppm in (-500, 0, 500):
            with self.subTest(sender_ppm=ppm):
                stream, player, expected, _, _ = self.simulate(sender_ppm=ppm, seconds=20)
                queues[ppm] = stream.queued_bytes
                self.assertEqual(stream.statistics["queue_dropped_bytes"], 0)
                self.assertEqual(stream.statistics["underrun_fill_bytes"], 0)
                self.assertEqual(player.underrun_bytes, 0)
                played = b"".join(player.writes)
                remaining = b"".join(pcm for _, pcm in stream.queue)
                self.assertEqual(played + remaining, expected)
        for ppm in (-500, 500):
            self.assertAlmostEqual((queues[ppm] - queues[0]) / BYTE_RATE,
                                   ppm / 1_000_000 * 20, delta=.0051)

    def test_catchup_budget_limits_work_without_discarding_sample_deadline(self):
        stream = Stream(SOURCE, "Windows")
        player = FakePlayer()
        playback = Playback(stream, "desktop_bus", 30, Path("unused"),
                            lambda *args: player, lambda *args: True)
        for sequence in range(20):
            stream.receive(packet(sequence), SOURCE, sequence * .005)
        playback.tick(.1)
        first = stream.statistics["played_bytes"]
        playback.tick(.15)
        self.assertLessEqual(stream.statistics["played_bytes"] - first, BYTE_RATE // 100)
        self.assertLess(playback.next_write, .15)
        # There is real PCM debt; successive ticks may catch it up, preserving
        # the byte order rather than silently rebasing the sample clock.
        for index in range(1, 51):
            playback.tick(.15 + index * .001)
        self.assertEqual(stream.queued_bytes, 0)
        self.assertEqual(stream.statistics["queue_dropped_bytes"], 0)

    def test_empty_queue_does_not_turn_stale_deadline_into_silence_burst(self):
        stream = Stream(SOURCE, "Windows")
        player = FakePlayer()
        playback = Playback(stream, "desktop_bus", 30, Path("unused"),
                            lambda *args: player, lambda *args: True)
        stream.receive(packet(), SOURCE, 0)
        playback.tick(.02)
        before = stream.statistics["underrun_fill_bytes"]
        playback.tick(.2)
        self.assertEqual(stream.statistics["underrun_fill_bytes"] - before, BYTE_RATE // 200)
        self.assertAlmostEqual(playback.next_write, .205)


class StateTests(unittest.TestCase):
    def test_atomic_state_and_exact_generation_ack(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "desktop.json"
            stream = Stream(SOURCE, "Windows")
            stream.receive(packet(), SOURCE, 1)
            publish(path, stream)
            state = json.loads(path.read_text())
            self.assertTrue(state["active"])
            self.assertEqual(state["generation"], str(uuid.UUID(state["generation"])))
            self.assertGreater(state["receiver_pid"], 0)
            self.assertGreater(state["updated_at"], 0)
            self.assertFalse(path.with_suffix(".json.tmp").exists())
            for desktop, expected in (({}, False),
                    ({"active": True, "generation": "old", "route_module": 4}, False),
                    ({"active": True, "generation": stream.generation, "route_module": None}, False),
                    ({"active": True, "generation": stream.generation, "route_module": 0}, True),
                    ({"active": False, "generation": stream.generation, "route_module": 4}, False)):
                desktop["enabled"] = True
                path.write_text(json.dumps({"desktop": desktop, "heartbeat_unix": 100, "state": "playing"}))
                self.assertEqual(route_ready(path, stream.generation, now=101), expected)
            path.write_text("{")
            self.assertFalse(route_ready(path, stream.generation))

    def test_route_ack_rejects_stale_disabled_invalid_module_and_stopping_runtime(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.json"
            base = {"desktop": {"enabled": True, "active": True, "generation": "test",
                                "route_module": 1}, "heartbeat_unix": 100, "state": "playing"}
            for age in (-1, 2.01):
                path.write_text(json.dumps(base))
                self.assertFalse(route_ready(path, "test", now=100 + age))
            for field, value in (("enabled", False), ("route_module", -1),
                                 ("route_module", True), ("route_module", "1")):
                state = dict(base, desktop=dict(base["desktop"], **{field: value}))
                path.write_text(json.dumps(state))
                self.assertFalse(route_ready(path, "test", now=101))
            for state in ("idle", "starting", "stopping", "stopped", "failed"):
                path.write_text(json.dumps(dict(base, state=state)))
                self.assertFalse(route_ready(path, "test", now=101))

    def test_route_ack_uses_monotonic_time_across_clock_corrections(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.json"
            state = {"desktop": {"enabled": True, "active": True, "generation": "test",
                                  "route_module": 1}, "state": "playing",
                     "heartbeat_unix": 1000, "heartbeat_monotonic": 50}
            path.write_text(json.dumps(state))
            with patch("vban_receiver.time.monotonic", return_value=50.1):
                self.assertTrue(route_ready(path, "test", now=0))
                self.assertTrue(route_ready(path, "test", now=10000))
            for monotonic in (49.9, 52.01):
                with patch("vban_receiver.time.monotonic", return_value=monotonic):
                    self.assertFalse(route_ready(path, "test", now=1000))

    def test_pipe_backpressure_and_signal_child_cleanup(self):
        player = PulsePlayer.__new__(PulsePlayer)
        player.process = Mock()
        player.process.poll.return_value = None
        player.process.stdin.fileno.return_value = 42
        with patch("vban_receiver.os.write", side_effect=BlockingIOError):
            self.assertEqual(player.write(bytes(960)), 0)
        player.close()
        player.process.terminate.assert_called_once()
        player.process.wait.assert_called_once_with(timeout=.5)
        player.process.stdin.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
