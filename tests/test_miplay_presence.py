"""Bounded loopback regressions for authenticated MiPlay control presence."""
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
        Command, CommandFrame, CommandFrameBuffer, decode_scalar,
        encode_command, legacy_challenge_response,
    )
    from vendor.castfabric_miplay.receiver import MiPlayReceiver
    from vendor.castfabric_miplay.simulator import _CommandChannel


@unittest.skipUnless(HAS_PROTOCOL_DEPS, "install zeroconf and pycryptodome for protocol tests")
class PresenceTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.sink_factory = Mock()
        receiver = MiPlayReceiver(host="127.0.0.1", port=0, advertise=False,
                                  sink_factory=self.sink_factory, handshake_timeout=0.15,
                                  control_idle_timeout=0.4)
        await receiver.start()
        self.addAsyncCleanup(receiver.stop)
        self.receiver = receiver

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
        if not authenticate:
            return channel
        await channel.send(
            encode_command(Command.SOURCE_VERSION, 0, b"1.0.1123012\0"),
            encode_command(Command.LEGACY_CHALLENGE_ACK, challenge.sequence,
                           legacy_challenge_response(challenge.payload)))
        self.assertEqual((await asyncio.wait_for(channel.read(), 1)).command,
                         Command.SOURCE_VERSION_ACK)
        # Establish a complete authenticated round trip before starting timers.
        await self.exchange(channel, Command.HEARTBEAT, Command.HEARTBEAT_ACK)
        return channel

    async def exchange(self, channel, command, acknowledgement, sequence=20):
        await channel.send(encode_command(command, sequence))
        async with asyncio.timeout(1):
            frame = await channel.read()
            while frame.command == Command.NOTIFY:
                frame = await channel.read()
        self.assertEqual(frame.command, acknowledgement)
        self.assertEqual(frame.sequence, sequence)
        return frame

    async def state(self, channel):
        frame = await self.exchange(channel, Command.GET_STATE, Command.GET_STATE_ACK)
        return decode_scalar(frame.payload)

    async def test_authenticated_heartbeat_survives_original_handshake_deadline(self):
        channel = await self.connect()
        for sequence in range(1, 11):
            await asyncio.sleep(0.06)
            await self.exchange(channel, Command.HEARTBEAT, Command.HEARTBEAT_ACK, sequence)
        self.sink_factory.assert_not_called()
        self.assertFalse(self.receiver.diagnostics()["active_session"])

    async def test_authenticated_queries_refresh_presence_without_creating_pcm(self):
        channel = await self.connect()
        for _ in range(6):
            await asyncio.sleep(0.1)
            self.assertEqual(await self.state(channel), 0)
        self.sink_factory.assert_not_called()
        self.assertFalse(self.receiver.diagnostics()["active_session"])

    async def test_authenticated_silent_control_expires_at_idle_deadline(self):
        channel = await self.connect()
        started = asyncio.get_running_loop().time()
        self.assertEqual(await asyncio.wait_for(channel.reader.read(1), 0.7), b"")
        self.assertGreater(asyncio.get_running_loop().time() - started, 0.25)
        self.sink_factory.assert_not_called()

    async def test_unauthenticated_control_keeps_short_handshake_deadline(self):
        channel = await self.connect(authenticate=False)
        self.assertEqual(await asyncio.wait_for(channel.reader.read(1), 0.3), b"")
        self.sink_factory.assert_not_called()

    async def test_partial_byte_drip_does_not_refresh_authenticated_idle_deadline(self):
        channel = await self.connect()
        frame = encode_command(Command.HEARTBEAT, 30)
        for byte in frame[:3]:
            await asyncio.sleep(0.1)
            channel.writer.write(bytes([byte]))
            await channel.writer.drain()
        # A byte-based timer would now last until ~0.7s; the original 0.4s
        # deadline must still close this incomplete frame before 0.55s.
        self.assertEqual(await asyncio.wait_for(channel.reader.read(1), 0.25), b"")
        self.sink_factory.assert_not_called()

    async def test_complete_fragmented_frame_refreshes_authenticated_idle_deadline(self):
        channel = await self.connect()
        frame = encode_command(Command.GET_STATE, 31)
        await asyncio.sleep(0.1)
        channel.writer.write(frame[:2])
        await channel.writer.drain()
        await asyncio.sleep(0.1)
        channel.writer.write(frame[2:6])
        await channel.writer.drain()
        await asyncio.sleep(0.1)
        channel.writer.write(frame[6:])
        await channel.writer.drain()
        reply = await asyncio.wait_for(channel.read(), 0.2)
        self.assertEqual((reply.command, reply.sequence), (Command.GET_STATE_ACK, 31))
        self.assertEqual(decode_scalar(reply.payload), 0)
        await asyncio.sleep(0.2)
        await self.exchange(channel, Command.HEARTBEAT, Command.HEARTBEAT_ACK)
        self.sink_factory.assert_not_called()

    async def test_invalid_complete_frame_closes_instead_of_extending_presence(self):
        channel = await self.connect()
        await channel.send(encode_command(Command.HEARTBEAT, 32, b"invalid"))
        self.assertEqual(await asyncio.wait_for(channel.reader.read(1), 0.2), b"")

    async def test_playback_states_and_independent_probe_follow_active_session(self):
        """Real control sockets, deterministic media-start seam (no decoder/PCM)."""
        source = await self.connect()
        probe = await self.connect()
        self.assertEqual(await self.state(source), 0)
        self.assertEqual(await self.state(probe), 0)
        entered_wfd = asyncio.Event()
        begin_media = asyncio.Event()
        media_started = asyncio.Event()

        async def controlled_wfd(request, session, write_control, report, playback_state):
            entered_wfd.set()
            await begin_media.wait()
            await write_control(session.media_started())
            media_started.set()
            await asyncio.Future()

        with patch.object(self.receiver, "_run_wfd", side_effect=controlled_wfd):
            await source.send(
                encode_command(Command.SET_PLAY_SOURCE, 40, b"{}"),
                encode_command(Command.OPEN, 41, b"wfd://127.0.0.1:12345?mirrorMode=1\0"))
            await asyncio.wait_for(entered_wfd.wait(), 1)
            self.assertEqual(await self.state(source), 0)
            self.assertEqual(await self.state(probe), 0)
            begin_media.set()
            await asyncio.wait_for(media_started.wait(), 1)
            self.assertEqual(await self.state(source), 2)
            self.assertEqual(await self.state(probe), 2)
            await self.exchange(source, Command.PAUSE, Command.PAUSE_ACK)
            self.assertEqual(await self.state(source), 3)
            self.assertEqual(await self.state(probe), 3)
            # Source stays silent beyond control_idle_timeout while its WFD
            # task is active; only the independent probe emits query traffic.
            for _ in range(5):
                await asyncio.sleep(0.1)
                self.assertEqual(await self.state(probe), 3)
            await self.exchange(source, Command.RESUME, Command.RESUME_ACK)
            self.assertEqual(await self.state(source), 2)
            self.assertEqual(await self.state(probe), 2)
            await source.send(encode_command(Command.CLOSE, 42))
            self.assertEqual(await asyncio.wait_for(source.reader.read(1), 0.3), b"")
            # wait_for_idle also waits for probe connections; this probe must
            # remain connected to observe the active session's cleanup.
            async with asyncio.timeout(0.3):
                while self.receiver.diagnostics()["active_session"]:
                    await asyncio.sleep(0.005)
            self.assertEqual(await self.state(probe), 0)
            self.assertEqual(self.receiver.playback_state(), 0)
            self.assertFalse(self.receiver.diagnostics()["active_session"])
        self.sink_factory.assert_not_called()

    async def test_wrapped_probe_query_uses_shared_state_and_response_wrapping(self):
        """Isolate decoded modern dispatch; this is not a cryptographic test."""
        shared_state = [0]
        session = LegacyReceiverSession(
            challenge=b"123456789012", playback_state_provider=lambda: shared_state[0])
        session.authenticated = True
        session.phase = ControlPhase.READY
        session.safety = Mock()
        session.safety.process.return_value.plaintext = CommandFrame(Command.GET_STATE, 50, b"")
        session.safety.wrap_writes.side_effect = lambda writes: writes
        for value in (0, 2, 3, 2, 0):
            shared_state[0] = value
            result = session.process(CommandFrame(Command.GET_STATE, 50, b"envelope"))
            self.assertTrue(result.accepted)
            decoded = CommandFrameBuffer().feed(result.writes[0])[0]
            self.assertEqual(decoded.command, Command.GET_STATE_ACK)
            self.assertEqual(decode_scalar(decoded.payload), value)
            self.assertEqual(session.local_playback_state(), 0)
        self.assertEqual(session.safety.wrap_writes.call_count, 5)


if __name__ == "__main__":
    unittest.main()
