"""Offline adapter tests; protocol/AAC tests use only loopback and local ffmpeg."""
import asyncio
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import shutil
import struct
import sys
import unittest
import uuid
from unittest.mock import AsyncMock, Mock, patch

APP = Path(__file__).resolve().parents[1] / "app"
sys.path.insert(0, str(APP))
from miplay_receiver import (AvahiPublisher, PulsePcmSink, PulseVolume, arguments,
                             choose_address, stop_process)

HAS_PROTOCOL_DEPS = bool((importlib.util.find_spec("Crypto") or importlib.util.find_spec("Cryptodome"))
                         and importlib.util.find_spec("zeroconf"))


class ConfigTests(unittest.TestCase):
    def test_sender_parses_pulse_module_ids_from_short_inventory(self):
        from miplay_sender import parse_short_modules
        modules = parse_short_modules(
            b"7\tmodule-null-sink\tsink_name=output rate=48000 channels=2\t0\t\n"
            b"8\tmodule-loopback\tsource=miplay_bus.monitor sink=output\t0\t\n")
        self.assertEqual(modules[0]["index"], 7)
        self.assertEqual(modules[0]["name"], "module-null-sink")
        self.assertIn("source=miplay_bus.monitor", modules[1]["argument"])

    def test_sender_tone_evidence_rejects_short_and_wrong_frequency(self):
        from miplay_sender import tone_evidence

        def pcm(frequency, seconds):
            samples = [round(2000 * math.sin(2 * math.pi * frequency * index / 48000))
                       for index in range(round(48000 * seconds))]
            return b"".join(struct.pack("<hh", value, value) for value in samples)

        self.assertGreaterEqual(tone_evidence(pcm(997, 1.2))["stable_tone_seconds"], 1)
        self.assertEqual(tone_evidence(pcm(440, 1.2))["stable_tone_seconds"], 0)
        self.assertLess(tone_evidence(pcm(997, 0.1))["stable_tone_seconds"], 1)

    def test_stable_uuid_and_port(self):
        options = arguments(["--name", "Living room", "--identity",
                             "feec3512-d65a-4e21-b667-3b7b4f6e90dc", "--port", "8998"])
        self.assertIsInstance(options.identity, uuid.UUID)
        self.assertEqual(options.port, 8998)
        self.assertEqual(options.sink, "miplay_bus")

    def test_rejects_invalid_audio_and_addresses(self):
        for address in ("0.0.0.0", "127.0.0.1", "224.0.0.1", "::1"):
            with self.assertRaises(ValueError):
                choose_address(address, "")
        with self.assertRaises(ValueError):
            PulsePcmSink("output --bad")
        with self.assertRaises(ValueError):
            PulsePcmSink(max_volume=101)

    def test_pinned_vendor_hashes(self):
        root = APP / "vendor" / "castfabric_miplay"
        lock = json.loads((root / "SOURCE.json").read_text(encoding="utf-8"))
        self.assertEqual(lock["commit"], "5b7733ee9185a85843606de6fe94867f7d5a42cf")
        for name, record in lock["files"].items():
            self.assertEqual(hashlib.sha256((root / name).read_bytes()).hexdigest(),
                             record["sha256"], name)


class AdapterTests(unittest.IsolatedAsyncioTestCase):
    async def test_idle_sink_does_not_claim_pulse_until_pcm(self):
        process = Mock(returncode=None)
        process.stdin.drain = AsyncMock()
        process.wait = AsyncMock(return_value=0)
        with patch("miplay_receiver.asyncio.create_subprocess_exec", AsyncMock(return_value=process)) as spawn:
            sink = PulsePcmSink()
            await sink.start(48000, 2, 2)
            spawn.assert_not_awaited()
            await sink.write(b"\x01\x00" * 200)
            command = spawn.call_args.args
            self.assertIn("--device=miplay_bus", command)
            self.assertIn("--latency-msec=200", command)
            self.assertIn("--volume=65536", command)
            await sink.stop()
            self.assertFalse(sink.started)

    async def test_volume_clamps_only_input_bus(self):
        process = Mock(returncode=0, stdin=None)
        process.wait = AsyncMock(return_value=0)
        with patch("miplay_receiver.asyncio.create_subprocess_exec", AsyncMock(return_value=process)) as spawn:
            volume = PulseVolume("miplay_bus", 70)
            await volume.set(120)
            self.assertEqual(spawn.call_args.args[-3:], ("set-sink-volume", "miplay_bus", "45875"))
            await volume.set(-9)
            self.assertEqual(spawn.call_args.args[-1], "0")

    async def test_failed_volume_command_keeps_last_applied_value(self):
        process = Mock(returncode=1, stdin=None)
        process.wait = AsyncMock(return_value=1)
        volume = PulseVolume("miplay_bus", 100)
        volume.value = 35
        with patch("miplay_receiver.asyncio.create_subprocess_exec", AsyncMock(return_value=process)):
            with self.assertRaises(RuntimeError):
                await volume.set(90)
        self.assertEqual(volume.value, 35)

    async def test_stalled_child_is_reaped(self):
        process = Mock(stdin=None)
        process.wait = AsyncMock(side_effect=[asyncio.TimeoutError(), asyncio.TimeoutError(), 0])
        await stop_process(process, 0.01)
        process.terminate.assert_called_once()
        process.kill.assert_called_once()
        self.assertEqual(process.wait.await_count, 3)

    async def test_avahi_failure_frees_registration(self):
        publisher = AvahiPublisher(None)
        publisher.group = Mock()
        publisher.group.GetState.return_value = 3
        group = publisher.group
        with patch.object(publisher, "_register"):
            with self.assertRaisesRegex(RuntimeError, "registration failed"):
                await publisher.start()
        group.Free.assert_called_once()

    async def test_wrong_pcm_format_is_rejected(self):
        with self.assertRaises(ValueError):
            await PulsePcmSink().start(44100, 2, 2)


@unittest.skipUnless(HAS_PROTOCOL_DEPS, "install zeroconf and pycryptodome for protocol tests")
class ProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def test_idle_playing_paused_and_resumed_states_are_distinct(self):
        from vendor.castfabric_miplay.control import ControlPhase, LegacyReceiverSession
        from vendor.castfabric_miplay.protocol import Command, CommandFrame, CommandFrameBuffer, decode_scalar
        session = LegacyReceiverSession(challenge=b"123456789012")
        session.authenticated = True
        session.phase = ControlPhase.OPENED
        def state():
            result = session.process(CommandFrame(Command.GET_STATE, 8, b""))
            return decode_scalar(CommandFrameBuffer().feed(result.writes[0])[0].payload)
        self.assertEqual(state(), 0)
        session.media_started()
        self.assertEqual(state(), 2)
        session.process(CommandFrame(Command.PAUSE, 9, b""))
        self.assertEqual(state(), 3)
        session.process(CommandFrame(Command.RESUME, 10, b""))
        self.assertEqual(state(), 2)

    async def test_wrapped_pause_exposes_the_decoded_business_action(self):
        from vendor.castfabric_miplay.control import ControlPhase, LegacyReceiverSession
        from vendor.castfabric_miplay.protocol import Command, CommandFrame
        session = LegacyReceiverSession(challenge=b"123456789012")
        session.authenticated = True
        session.phase = ControlPhase.OPENED
        session.safety = Mock()
        session.safety.process.return_value.plaintext = CommandFrame(Command.PAUSE, 7, b"")
        session.safety.wrap_writes.side_effect = lambda writes: writes
        result = session.process(CommandFrame(Command.GET_STATE, 7, b"wrapped"))
        self.assertTrue(result.accepted)
        self.assertEqual(result.playback_action, "pause")

    async def _open_idle_source(self, receiver):
        """Real TCP control + WFD handshake, deliberately keep media TCP open."""
        from vendor.castfabric_miplay.protocol import Command, encode_command, legacy_challenge_response
        from vendor.castfabric_miplay.simulator import MiPlaySourceSimulator, _CommandChannel, _RtspChannel
        reverse = asyncio.Queue()
        server = await asyncio.start_server(lambda r, w: reverse.put_nowait((r, w)), "127.0.0.1", 0)
        reader, writer = await asyncio.open_connection("127.0.0.1", receiver.port)
        channel = _CommandChannel(reader, writer)
        challenge = await channel.read()
        await channel.send(
            encode_command(Command.SOURCE_VERSION, 0, b"1.0.1123012\0"),
            encode_command(Command.LEGACY_CHALLENGE_ACK, challenge.sequence,
                           legacy_challenge_response(challenge.payload)),
            encode_command(Command.SET_PLAY_SOURCE, 1, b"{}"),
            encode_command(Command.OPEN, 2,
                           f"wfd://127.0.0.1:{server.sockets[0].getsockname()[1]}?mirrorMode=1\0".encode()),
        )
        self.assertEqual((await channel.read()).command, Command.SOURCE_VERSION_ACK)
        sockets = [await asyncio.wait_for(reverse.get(), 3) for _ in range(3)]
        await MiPlaySourceSimulator(target_host="127.0.0.1", target_port=receiver.port)._run_rtsp(
            _RtspChannel(*sockets[0]))
        return server, channel, sockets

    async def _check_stalled_session_cleanup(self, reason):
        from vendor.castfabric_miplay.media import FfmpegMpegTsDecoder, RecordingPcmSink
        from vendor.castfabric_miplay.receiver import MiPlayReceiver
        from vendor.castfabric_miplay.protocol import Command, encode_command
        from vendor.castfabric_miplay.simulator import MiPlaySourceSimulator
        sinks, decoders = [], []

        def sink_factory():
            sink = RecordingPcmSink()
            if reason == "sink" and not sinks:
                sink.write = AsyncMock(side_effect=RuntimeError("output unavailable"))
            sinks.append(sink)
            return sink

        def decoder_factory(*args):
            decoder = FfmpegMpegTsDecoder(*args)
            decoders.append(decoder)
            return decoder

        receiver = MiPlayReceiver(host="127.0.0.1", port=0, advertise=False,
                                  sink_factory=sink_factory,
                                  media_idle_timeout=0.15 if reason == "idle" else 30)
        await receiver.start()
        server = channel = None
        sockets = []
        try:
            with patch("vendor.castfabric_miplay.receiver.FfmpegMpegTsDecoder", side_effect=decoder_factory):
                server, channel, sockets = await self._open_idle_source(receiver)
                for _ in range(100):
                    if decoders and decoders[0].process is not None:
                        break
                    await asyncio.sleep(0.01)
                self.assertTrue(receiver.diagnostics()["active_session"])
                if reason == "close":
                    await channel.send(encode_command(Command.CLOSE, 3))
                elif reason == "eof":
                    channel.writer.close()
                    await channel.writer.wait_closed()
                elif reason == "rtsp":
                    sockets[0][1].close()
                    await sockets[0][1].wait_closed()
                elif reason == "decoder":
                    decoders[0].process.kill()
                elif reason == "sink":
                    from vendor.castfabric_miplay.media import encode_media_frame, encode_rtp_mpegts
                    stream = await MiPlaySourceSimulator(target_host="127.0.0.1", target_port=1,
                                                         duration=1)._generate_transport_stream()
                    for offset in range(0, len(stream), 1316):
                        sockets[2][1].write(encode_media_frame(encode_rtp_mpegts(
                            offset // 1316, 0, 1, stream[offset:offset + 1316])))
                    await sockets[2][1].drain()
                # The media sender has NOT closed its socket in any case.
                await asyncio.wait_for(receiver.wait_for_idle(), 7)
                self.assertFalse(receiver.diagnostics()["active_session"])
                self.assertFalse(sinks[0].started)
                self.assertIsNotNone(decoders[0].process.returncode)
                self.assertEqual(await asyncio.wait_for(sockets[2][0].read(1), 1), b"")
                # A fresh sender can acquire the same receiver and decode audio.
                receiver.media_idle_timeout = 30
                result = await asyncio.wait_for(MiPlaySourceSimulator(
                    target_host="127.0.0.1", target_port=receiver.port, duration=0.1).run(), 10)
                await asyncio.wait_for(receiver.wait_for_idle(), 7)
                self.assertTrue(result.rtsp_ready)
                self.assertGreater(sum(len(chunk) for chunk in sinks[-1].chunks), 1000)
        finally:
            if channel:
                channel.writer.close()
                await channel.writer.wait_closed()
            for _, writer in sockets:
                writer.close()
                await writer.wait_closed()
            if server:
                server.close()
                await server.wait_closed()
            await receiver.stop()

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg required")
    async def test_close_releases_open_media_and_allows_new_sender(self):
        await self._check_stalled_session_cleanup("close")

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg required")
    async def test_control_eof_releases_open_media_and_allows_new_sender(self):
        await self._check_stalled_session_cleanup("eof")

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg required")
    async def test_rtsp_eof_releases_open_media_and_allows_new_sender(self):
        await self._check_stalled_session_cleanup("rtsp")

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg required")
    async def test_media_idle_timeout_releases_and_allows_new_sender(self):
        await self._check_stalled_session_cleanup("idle")

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg required")
    async def test_decoder_exit_releases_idle_media_and_allows_new_sender(self):
        await self._check_stalled_session_cleanup("decoder")

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg required")
    async def test_pcm_failure_releases_idle_media_and_allows_new_sender(self):
        await self._check_stalled_session_cleanup("sink")

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg required")
    async def test_pause_discards_media_resume_reopens_sink(self):
        from vendor.castfabric_miplay.media import RecordingPcmSink, encode_media_frame, encode_rtp_mpegts
        from vendor.castfabric_miplay.receiver import MiPlayReceiver
        from vendor.castfabric_miplay.protocol import Command, encode_command
        from vendor.castfabric_miplay.simulator import MiPlaySourceSimulator
        sink = RecordingPcmSink()
        receiver = MiPlayReceiver(host="127.0.0.1", port=0, advertise=False,
                                  sink_factory=lambda: sink, media_idle_timeout=0.2)
        await receiver.start()
        server = channel = None
        sockets = []

        async def wait_until(predicate):
            async with asyncio.timeout(4):
                while not predicate():
                    await asyncio.sleep(0.01)

        try:
            server, channel, sockets = await self._open_idle_source(receiver)
            stream = await MiPlaySourceSimulator(target_host="127.0.0.1", target_port=1,
                                                 duration=1)._generate_transport_stream()

            async def send_media():
                for offset in range(0, len(stream), 1316):
                    sockets[2][1].write(encode_media_frame(encode_rtp_mpegts(
                        (offset // 1316) & 65535, 0, 1, stream[offset:offset + 1316])))
                await sockets[2][1].drain()

            # Pause is a real socket command; receive its ACK and wait for the
            # input to close. Keep all transport connections open past idle limit.
            await channel.send(encode_command(Command.PAUSE, 3))
            self.assertEqual((await channel.read()).command, Command.PAUSE_ACK)
            await wait_until(lambda: not sink.started)
            await send_media()
            await asyncio.sleep(0.4)
            self.assertTrue(receiver.diagnostics()["active_session"])
            self.assertEqual(sink.chunks, [])
            await channel.send(encode_command(Command.RESUME, 4))
            response = await channel.read()
            while response.command == Command.NOTIFY:
                response = await channel.read()
            self.assertEqual(response.command, Command.RESUME_ACK)
            await wait_until(lambda: sink.started)
            await send_media()
            await wait_until(lambda: bool(sink.chunks))
            await channel.send(encode_command(Command.CLOSE, 5))
            await asyncio.wait_for(receiver.wait_for_idle(), 7)
            self.assertFalse(sink.started)
        finally:
            if channel:
                channel.writer.close()
                await channel.writer.wait_closed()
            for _, writer in sockets:
                writer.close()
                await writer.wait_closed()
            if server:
                server.close()
                await server.wait_closed()
            await receiver.stop()

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg required")
    async def test_new_session_preserves_device_volume_after_previous_zero(self):
        from vendor.castfabric_miplay.media import RecordingPcmSink
        from vendor.castfabric_miplay.receiver import MiPlayReceiver
        from vendor.castfabric_miplay.simulator import MiPlaySourceSimulator
        volumes = []

        async def set_volume(value):
            volumes.append(value)

        receiver = MiPlayReceiver(host="127.0.0.1", port=0, advertise=False,
                                  sink_factory=RecordingPcmSink, volume_setter=set_volume,
                                  initial_volume=70)
        await receiver.start()
        try:
            for volume in (0, None):
                await asyncio.wait_for(MiPlaySourceSimulator(
                    target_host="127.0.0.1", target_port=receiver.port,
                    duration=0.1, volume=volume).run(), 10)
                await asyncio.wait_for(receiver.wait_for_idle(), 7)
            self.assertTrue(volumes)
            self.assertTrue(all(volume == 0 for volume in volumes))
            self.assertEqual(receiver.current_volume, 0)
        finally:
            await receiver.stop()

    async def test_service_uses_stable_identity_and_configured_control_port(self):
        from vendor.castfabric_miplay.mdns import MiPlayIdentity, decode_app_data
        device_id = uuid.UUID("feec3512-d65a-4e21-b667-3b7b4f6e90dc")
        identity = MiPlayIdentity(address="192.0.2.10", device_id=device_id, control_port=9991)
        with patch("vendor.castfabric_miplay.mdns.Zeroconf", side_effect=AssertionError("must use Avahi")):
            info = identity.service_info()
        payload = decode_app_data(info.properties[b"appsData"].decode())
        self.assertEqual(struct.unpack_from(">H", payload, 2)[0], 9991)
        self.assertEqual(json.loads(payload[25:])["mico"]["device_id"], str(device_id))
        self.assertEqual(info.port, 56666)

    async def test_avahi_uses_proxy_and_explicit_interface(self):
        from vendor.castfabric_miplay.mdns import MiPlayIdentity
        identity = MiPlayIdentity(address="192.0.2.10", instance="bridge-test")
        fake_dbus = Mock()
        group = Mock()
        fake_dbus.Interface.side_effect = [Mock(), group]
        fake_dbus.Array.side_effect = lambda value, **kwargs: value
        fake_dbus.ByteArray.side_effect = lambda value: value
        fake_dbus.UInt32.side_effect = int
        fake_dbus.UInt16.side_effect = int
        publisher = AvahiPublisher(identity, "lan0")
        with patch.dict(sys.modules, {"dbus": fake_dbus}), patch.dict(
                "os.environ", {"DBUS_SYSTEM_BUS_ADDRESS": "unix:path=/proxy/bus"}), patch(
                "miplay_receiver.socket.if_nametoindex", return_value=7):
            publisher._register()
        fake_dbus.bus.BusConnection.assert_called_once_with("unix:path=/proxy/bus")
        args = group.AddService.call_args.args
        self.assertEqual(args[:4], (7, 0, 0, "bridge-test"))
        self.assertEqual(args[4], "_mi-connect._udp")
        self.assertIn(b"name=CastFabric", args[8])
        group.AddAddress.assert_called_once()
        self.assertEqual(group.AddAddress.call_args.args[4], "192.0.2.10")
        await publisher.stop()

    async def test_idle_probe_expires_without_creating_audio(self):
        from vendor.castfabric_miplay.receiver import MiPlayReceiver
        sink_factory = Mock()
        receiver = MiPlayReceiver(host="127.0.0.1", port=0, advertise=False,
                                  sink_factory=sink_factory, handshake_timeout=0.05)
        await receiver.start()
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", receiver.port)
            await reader.read(1024)
            await asyncio.wait_for(receiver.wait_for_idle(), 1)
            sink_factory.assert_not_called()
            self.assertFalse(receiver.diagnostics()["active_session"])
            writer.close()
            await writer.wait_closed()
        finally:
            await receiver.stop()

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg is required for AAC end-to-end check")
    async def test_decoder_reaps_process_when_pcm_output_fails(self):
        from vendor.castfabric_miplay.media import FfmpegMpegTsDecoder
        from vendor.castfabric_miplay.simulator import MiPlaySourceSimulator
        sink = Mock()
        sink.start = AsyncMock()
        sink.stop = AsyncMock()
        sink.write = AsyncMock(side_effect=RuntimeError("output unavailable"))
        decoder = FfmpegMpegTsDecoder(sink)
        stream = await MiPlaySourceSimulator(target_host="127.0.0.1", target_port=1,
                                             duration=0.1)._generate_transport_stream()
        await decoder.start()
        await decoder.write(stream)
        with self.assertRaisesRegex(RuntimeError, "output unavailable"):
            await asyncio.wait_for(decoder.stop(), 8)
        sink.stop.assert_awaited_once()
        self.assertIsNotNone(decoder.process.returncode)

    @unittest.skipUnless(shutil.which("ffmpeg"), "ffmpeg is required for AAC end-to-end check")
    async def test_real_control_rtsp_and_aac_decode(self):
        from vendor.castfabric_miplay.media import RecordingPcmSink
        from vendor.castfabric_miplay.receiver import MiPlayReceiver
        from vendor.castfabric_miplay.simulator import MiPlaySourceSimulator
        sink = RecordingPcmSink()
        volumes = []

        async def volume(value):
            volumes.append(value)

        receiver = MiPlayReceiver(host="127.0.0.1", port=0, advertise=False,
                                  sink_factory=lambda: sink, volume_setter=volume)
        await receiver.start()
        try:
            result = await asyncio.wait_for(MiPlaySourceSimulator(
                target_host="127.0.0.1", target_port=receiver.port,
                duration=0.35, volume=43).run(), 15)
            await asyncio.wait_for(receiver.wait_for_idle(), 8)
            self.assertTrue(result.control_opened and result.rtsp_ready)
            self.assertGreater(result.media_frames, 0)
            pcm = b"".join(sink.chunks)
            samples = struct.unpack("<" + "h" * (len(pcm) // 2), pcm)
            self.assertGreater(len(pcm), 38400)
            self.assertGreater(max(abs(sample) for sample in samples), 500)
            self.assertTrue(volumes)
            self.assertTrue(all(volume == 43 for volume in volumes))
            self.assertFalse(sink.started)
            self.assertTrue(receiver.diagnostics()["last_session"]["authenticated"])
        finally:
            await receiver.stop()


if __name__ == "__main__":
    unittest.main()
