"""Loopback regressions for receiver-wide MiPlay volume (no audio hardware)."""
import asyncio
import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "app"))

HAS_PROTOCOL_DEPS = bool((importlib.util.find_spec("Crypto") or importlib.util.find_spec("Cryptodome"))
                         and importlib.util.find_spec("zeroconf"))
if HAS_PROTOCOL_DEPS:
    from vendor.castfabric_miplay.control import ControlPhase, LegacyReceiverSession
    from vendor.castfabric_miplay.protocol import (
        Command, CommandFrame, CommandFrameBuffer, decode_scalar, encode_command,
        legacy_challenge_response,
    )
    from vendor.castfabric_miplay.receiver import MiPlayReceiver
    from vendor.castfabric_miplay.simulator import _CommandChannel


@unittest.skipUnless(HAS_PROTOCOL_DEPS, "install zeroconf and pycryptodome for protocol tests")
class VolumeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.applied = []
        self.sink_factory = Mock()

        async def setter(volume):
            self.applied.append(volume)
            return True

        self.receiver = MiPlayReceiver(
            host="127.0.0.1", port=0, advertise=False,
            sink_factory=self.sink_factory, volume_setter=setter,
            initial_volume=100, handshake_timeout=0.2, control_idle_timeout=0.4)
        await self.receiver.start()
        self.addAsyncCleanup(self.receiver.stop)
        self.media_entries = asyncio.Queue()

        async def controlled_wfd(request, session, write_control, report, playback_state):
            # Keep a real control connection active without RTSP, decoding or PCM.
            await self.media_entries.put(session)
            await asyncio.Future()

        self.media_patch = patch.object(self.receiver, "_run_wfd", side_effect=controlled_wfd)
        self.media_patch.start()
        self.addCleanup(self.media_patch.stop)

    async def connect(self, *, authenticate=True):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.receiver.port)

        async def close():
            writer.close()
            try:
                await writer.wait_closed()
            except ConnectionError:
                pass

        self.addAsyncCleanup(close)
        channel = _CommandChannel(reader, writer)
        challenge = await asyncio.wait_for(channel.read(), 1)
        if authenticate:
            await channel.send(
                encode_command(Command.SOURCE_VERSION, 0, b"1.0.1123012\0"),
                encode_command(Command.LEGACY_CHALLENGE_ACK, challenge.sequence,
                               legacy_challenge_response(challenge.payload)))
            self.assertEqual((await asyncio.wait_for(channel.read(), 1)).command,
                             Command.SOURCE_VERSION_ACK)
            await self.exchange(channel, Command.HEARTBEAT, Command.HEARTBEAT_ACK)
        return channel

    async def exchange(self, channel, command, ack, payload=b"", sequence=20):
        await channel.send(encode_command(command, sequence, payload))
        async with asyncio.timeout(1):
            reply = await channel.read()
            while reply.command == Command.NOTIFY:
                reply = await channel.read()
        self.assertEqual((reply.command, reply.sequence), (ack, sequence))
        return reply

    async def volume(self, channel):
        reply = await self.exchange(channel, Command.GET_VOLUME, Command.GET_VOLUME_ACK)
        return decode_scalar(reply.payload)

    async def set_volume(self, channel, value):
        await self.exchange(channel, Command.SET_VOLUME, Command.SET_VOLUME_ACK,
                            value.to_bytes(4, "big"))

    async def wait_applied(self, expected):
        async with asyncio.timeout(1):
            while not self.applied or self.applied[-1] != expected:
                await asyncio.sleep(0.005)

    async def open_media(self, channel):
        await channel.send(
            encode_command(Command.SET_PLAY_SOURCE, 40, b"{}"),
            encode_command(Command.OPEN, 41, b"wfd://127.0.0.1:12345?mirrorMode=1\0"))
        return await asyncio.wait_for(self.media_entries.get(), 1)

    async def close_media(self, channel):
        await channel.send(encode_command(Command.CLOSE, 42))
        self.assertEqual(await asyncio.wait_for(channel.reader.read(1), 1), b"")
        async with asyncio.timeout(1):
            while self.receiver.diagnostics()["active_session"]:
                await asyncio.sleep(0.005)

    async def test_two_long_lived_probes_and_new_connection_share_active_volume(self):
        source, first, second = await self.connect(), await self.connect(), await self.connect()
        await self.open_media(source)
        await self.wait_applied(100)
        await self.set_volume(source, 37)
        await self.wait_applied(37)
        for sequence in range(6):
            for probe in (first, second):
                self.assertEqual(await self.volume(probe), 37)
                await self.exchange(probe, Command.HEARTBEAT, Command.HEARTBEAT_ACK,
                                    sequence=sequence)
            await asyncio.sleep(0.09)
        self.assertEqual(await self.volume(await self.connect()), 37)
        self.assertEqual(self.applied, [100, 37])
        self.sink_factory.assert_not_called()

    async def test_probe_set_changes_active_volume_and_repeated_same_set_is_applied(self):
        source, probe = await self.connect(), await self.connect()
        await self.open_media(source)
        await self.wait_applied(100)
        await self.set_volume(probe, 46)
        await self.wait_applied(46)
        self.assertEqual(await self.volume(source), 46)
        count = len(self.applied)
        await self.set_volume(probe, 46)
        async with asyncio.timeout(1):
            while len(self.applied) == count:
                await asyncio.sleep(0.005)
        self.assertEqual(self.applied, [100, 46, 46])
        self.assertEqual(await self.volume(await self.connect()), 46)

    async def test_mute_survives_close_and_new_open_including_preexisting_connection(self):
        source, old_probe = await self.connect(), await self.connect()
        await self.open_media(source)
        await self.wait_applied(100)
        await self.set_volume(source, 0)
        await self.wait_applied(0)
        await self.close_media(source)
        self.assertEqual(await self.volume(await self.connect()), 0)
        # This connection was created at 100; OPEN must not restore that snapshot.
        await self.open_media(old_probe)
        self.assertEqual(await self.volume(old_probe), 0)
        await self.close_media(old_probe)
        fresh = await self.connect()
        await self.open_media(fresh)
        self.assertEqual(await self.volume(fresh), 0)
        self.assertTrue(all(value == 0 for value in self.applied[1:]))

    async def test_set_without_open_updates_device_and_next_open(self):
        old_connection, probe = await self.connect(), await self.connect()
        await self.set_volume(probe, 28)
        await self.wait_applied(28)
        self.assertFalse(self.receiver.diagnostics()["active_session"])
        await self.open_media(old_connection)
        self.assertEqual(await self.volume(old_connection), 28)
        self.assertTrue(all(value == 28 for value in self.applied))

    async def test_open_lifecycle_wait_cannot_restore_volume_before_concurrent_set(self):
        source, probe = await self.connect(), await self.connect()
        entered, release = asyncio.Event(), asyncio.Event()

        async def lifecycle(event, details=None):
            if event == "session_started":
                entered.set()
                await release.wait()

        with patch.object(self.receiver, "_emit_lifecycle", side_effect=lifecycle):
            opening = asyncio.create_task(self.open_media(source))
            try:
                await asyncio.wait_for(entered.wait(), 1)
                await self.set_volume(probe, 19)
                await self.wait_applied(19)
                release.set()
                await opening
                self.assertEqual(await self.volume(source), 19)
                self.assertTrue(all(value == 19 for value in self.applied))
            finally:
                release.set()
                if not opening.done():
                    opening.cancel()
                await asyncio.gather(opening, return_exceptions=True)

    async def test_shared_value_and_sink_are_updated_before_set_ack_drain(self):
        source, probe = await self.connect(), await self.connect()
        peer = source.writer.get_extra_info("sockname")
        entered, release = asyncio.Event(), asyncio.Event()
        original_drain = asyncio.StreamWriter.drain

        async def blocked_drain(writer):
            if writer.get_extra_info("peername") == peer:
                entered.set()
                await release.wait()
            await original_drain(writer)

        with patch.object(asyncio.StreamWriter, "drain", blocked_drain):
            try:
                await source.send(encode_command(Command.SET_VOLUME, 77, (23).to_bytes(4, "big")))
                await asyncio.wait_for(entered.wait(), 1)
                self.assertEqual(await self.volume(probe), 23)
                await self.wait_applied(23)
            finally:
                release.set()

    async def test_invalid_or_unauthenticated_set_does_not_change_device(self):
        probe = await self.connect()
        await self.set_volume(probe, 32)
        await self.wait_applied(32)
        for payload, authenticate in (((101).to_bytes(4, "big"), True), (b"\xff" * 4, True),
                                      (b"\x00", True), ((70).to_bytes(4, "big"), False)):
            with self.subTest(payload=payload, authenticate=authenticate):
                rejected = await self.connect(authenticate=authenticate)
                await rejected.send(encode_command(Command.SET_VOLUME, 60, payload))
                self.assertEqual(await asyncio.wait_for(rejected.reader.read(1), 1), b"")
                self.assertEqual(await self.volume(probe), 32)
        self.assertEqual(self.applied, [32])

    async def test_maximum_is_independent_of_initial_and_clamps_reported_and_sink_volume(self):
        await self.receiver.stop()
        self.receiver = MiPlayReceiver(
            host="127.0.0.1", port=0, advertise=False, initial_volume=25, max_volume=70,
            volume_setter=lambda value: self.applied.append(value), sink_factory=self.sink_factory)
        await self.receiver.start()
        self.addAsyncCleanup(self.receiver.stop)
        source, probe = await self.connect(), await self.connect()
        self.assertEqual(await self.volume(source), 25)
        await self.set_volume(source, 60)
        await self.wait_applied(60)
        await self.set_volume(source, 90)
        await self.wait_applied(70)
        self.assertEqual(await self.volume(source), 70)
        self.assertEqual(await self.volume(probe), 70)
        self.assertEqual(await self.volume(await self.connect()), 70)
        self.assertEqual(self.applied, [60, 70])

    async def test_busy_volume_worker_coalesces_to_latest_value_including_zero(self):
        entered, release = asyncio.Event(), asyncio.Event()

        async def slow_setter(value):
            self.applied.append(value)
            if len(self.applied) == 1:
                entered.set()
                await release.wait()

        self.receiver.volume_setter = slow_setter
        probe = await self.connect()
        try:
            await self.set_volume(probe, 40)
            await asyncio.wait_for(entered.wait(), 1)
            for value in (39, 36, 31, 0):
                await self.set_volume(probe, value)
            self.assertEqual(await self.volume(probe), 0)
            release.set()
            await self.wait_applied(0)
            self.assertEqual(self.applied, [40, 0])
        finally:
            release.set()


@unittest.skipUnless(HAS_PROTOCOL_DEPS, "install zeroconf and pycryptodome for protocol tests")
class WrappedVolumeTests(unittest.TestCase):
    def test_wrapped_same_value_set_has_explicit_intent_and_get_uses_shared_provider(self):
        """Test decoded modern dispatch; this does not validate cryptography."""
        current = [38]
        session = LegacyReceiverSession(challenge=b"123456789012", volume=38,
                                        volume_provider=lambda: current[0])
        session.authenticated = True
        session.phase = ControlPhase.READY
        session.safety = Mock()
        session.safety.wrap_writes.side_effect = lambda writes: writes
        for value in (38, 38, 0, 0):
            session.safety.process.return_value.plaintext = CommandFrame(
                Command.SET_VOLUME, 81, value.to_bytes(4, "big"))
            result = session.process(CommandFrame(Command.NOTIFY, 81, b"envelope"))
            self.assertTrue(result.accepted)
            self.assertEqual(result.volume_request, value)
            reply = CommandFrameBuffer().feed(result.writes[0])[0]
            self.assertEqual(reply.command, Command.SET_VOLUME_ACK)
        for value in (72, 0, 21):
            current[0] = value
            session.safety.process.return_value.plaintext = CommandFrame(Command.GET_VOLUME, 82, b"")
            result = session.process(CommandFrame(Command.NOTIFY, 82, b"envelope"))
            self.assertTrue(result.accepted)
            self.assertIsNone(result.volume_request)
            reply = CommandFrameBuffer().feed(result.writes[0])[0]
            self.assertEqual(reply.command, Command.GET_VOLUME_ACK)
            self.assertEqual(decode_scalar(reply.payload), value)
        self.assertEqual(session.safety.wrap_writes.call_count, 7)


if __name__ == "__main__":
    unittest.main()
