#!/usr/bin/env python3
"""Check shared MiPlay volume against a running isolated null-mode bridge.

Run inside the compose.test.yaml container, optionally through python3 stdin.
Only authentication, heartbeat and volume commands are sent; no media is opened.
"""
import argparse
import asyncio
from collections import deque
import contextlib
import json
import os
from pathlib import Path
import socket
import sys
import time

APP = Path('/app') if Path('/app/miplay_receiver.py').is_file() else Path(__file__).resolve().parents[1] / 'app'
sys.path.insert(0, str(APP))
from vendor.castfabric_miplay.protocol import (
    Command, CommandFrameBuffer, encode_command, legacy_challenge_response,
)

STATUS = Path('/run/lan-audio/status.json')
PULSE_SERVER = 'unix:/run/lan-audio/pulse.sock'


async def pulse_list(options, kind, *, short=False):
    arguments = ['list', 'short', kind] if short else ['--format=json', 'list', kind]
    process = await asyncio.create_subprocess_exec(
        'pactl', '--server=' + options.pulse_server, *arguments,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        output, _ = await asyncio.wait_for(process.communicate(), 3)
        if process.returncode:
            raise RuntimeError('Pulse inspection failed')
        if not short:
            return json.loads(output)
        modules = []
        for line in output.decode().splitlines():
            fields = line.split('\t')
            if len(fields) < 3 or not fields[0].isdigit():
                raise RuntimeError('unexpected Pulse module inventory')
            modules.append({'index': fields[0], 'name': fields[1]})
        return modules
    finally:
        if process.returncode is None:
            with contextlib.suppress(ProcessLookupError):
                process.kill()
            await process.wait()


def require_idle_runtime():
    state = json.loads(STATUS.read_text())
    age = time.time() - state['heartbeat_unix']
    if (state.get('state') != 'idle' or state.get('owner') is not None
            or state.get('route_module') is not None or not -2 <= age <= 5
            or state.get('children', {}).get('miplay', {}).get('state') != 'running'):
        raise RuntimeError('bridge must remain healthy and idle during the test')
    for path in Path('/proc').glob('[0-9]*/comm'):
        try:
            if path.read_text().strip() in {'pacat', 'parec', 'ffmpeg'}:
                raise RuntimeError('unexpected audio process during control-only test')
        except FileNotFoundError:
            pass


def raw_volume(sink):
    values = {name: channel['value'] for name, channel in sink['volume'].items()}
    if not values or any(not isinstance(value, int) for value in values.values()):
        raise RuntimeError('invalid Pulse channel volume')
    return values


async def snapshot(options, baseline=None):
    require_idle_runtime()
    sinks, modules, inputs, outputs = await asyncio.gather(
        pulse_list(options, 'sinks'), pulse_list(options, 'modules', short=True),
        pulse_list(options, 'sink-inputs'), pulse_list(options, 'source-outputs'),
    )
    if inputs or outputs or any(module['name'] == 'module-loopback' for module in modules):
        raise RuntimeError('control-only test unexpectedly created an audio stream or route')
    by_name = {sink['name']: sink for sink in sinks}
    if 'output' not in by_name or 'miplay_bus' not in by_name:
        raise RuntimeError('required bridge sinks are unavailable')
    output = by_name['output']
    if not any(str(module['index']) == str(output['owner_module'])
               and module['name'] == 'module-null-sink' for module in modules):
        raise RuntimeError('bridge output must be backed by module-null-sink')
    if output.get('state') != 'SUSPENDED':
        raise RuntimeError('idle output must remain suspended')
    output_volume = raw_volume(output)
    if baseline is not None and output_volume != baseline:
        raise RuntimeError('MiPlay control changed output bus volume')
    require_idle_runtime()
    return output_volume, raw_volume(by_name['miplay_bus'])


async def require_local_null_test(options):
    if (not Path('/.dockerenv').exists() or Path('/dev/snd').exists()
            or os.getenv('AUDIO_MODE') != 'null'):
        raise RuntimeError('check requires an isolated null-mode container without audio devices')
    if options.pulse_server != PULSE_SERVER or options.target != options.source_address:
        raise RuntimeError('check is restricted to the local bridge and Pulse server')
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind((options.source_address, 0))
    return await snapshot(options)


class Control:
    def __init__(self, reader, writer):
        self.reader, self.writer = reader, writer
        self.decoder = CommandFrameBuffer()
        self.pending = deque()
        self.sequence = 1

    @classmethod
    async def connect(cls, options):
        reader, writer = await asyncio.wait_for(asyncio.open_connection(
            options.target, options.port, local_addr=(options.source_address, 0)), 3)
        connection = cls(reader, writer)
        try:
            challenge = await connection.read()
            if challenge.command != Command.LEGACY_CHALLENGE:
                raise RuntimeError('unexpected MiPlay greeting')
            await connection.request(Command.SOURCE_VERSION, Command.SOURCE_VERSION_ACK,
                                     b'1.0.1123012\0')
            writer.write(encode_command(Command.LEGACY_CHALLENGE_ACK, challenge.sequence,
                                        legacy_challenge_response(challenge.payload)))
            await asyncio.wait_for(writer.drain(), 3)
            await connection.heartbeat()
            return connection
        except BaseException:
            await connection.close()
            raise

    async def read(self):
        async with asyncio.timeout(3):
            while not self.pending:
                data = await self.reader.read(16384)
                if not data:
                    raise RuntimeError('MiPlay control connection closed')
                self.pending.extend(self.decoder.feed(data))
            return self.pending.popleft()

    async def request(self, command, acknowledgement, payload=b''):
        sequence = self.sequence
        self.sequence += 1
        self.writer.write(encode_command(command, sequence, payload))
        await asyncio.wait_for(self.writer.drain(), 3)
        reply = await self.read()
        if reply.command != acknowledgement or reply.sequence != sequence:
            raise RuntimeError('unexpected MiPlay acknowledgement')
        return reply.payload

    async def heartbeat(self):
        if await self.request(Command.HEARTBEAT, Command.HEARTBEAT_ACK):
            raise RuntimeError('unexpected heartbeat payload')

    async def get_volume(self):
        payload = await self.request(Command.GET_VOLUME, Command.GET_VOLUME_ACK)
        if len(payload) != 5 or payload[0] != 0:
            raise RuntimeError('unexpected volume response')
        return int.from_bytes(payload[1:], 'big')

    async def set_volume(self, value):
        if await self.request(Command.SET_VOLUME, Command.SET_VOLUME_ACK,
                              value.to_bytes(4, 'big')):
            raise RuntimeError('unexpected volume acknowledgement payload')

    async def close(self):
        self.writer.close()
        with contextlib.suppress(ConnectionError, asyncio.TimeoutError):
            await asyncio.wait_for(self.writer.wait_closed(), 3)


async def check(options):
    baseline, _ = await require_local_null_test(options)
    connections = []
    probe_count = 0
    poll_count = 0

    async def assert_volumes(expected):
        values = await asyncio.gather(*(connection.get_volume() for connection in connections))
        if values != [expected] * len(connections):
            raise RuntimeError('MiPlay connections disagree with the requested volume')

    async def assert_applied(expected):
        raw = round(expected * 65536 / 100)
        async with asyncio.timeout(5):
            while True:
                _, actual = await snapshot(options, baseline)
                if all(abs(value - raw) <= 1 for value in actual.values()):
                    return
                await asyncio.sleep(0.1)

    try:
        connections.append(await Control.connect(options))
        connections.append(await Control.connect(options))
        await connections[0].set_volume(35)
        connections.append(await Control.connect(options))
        await assert_volumes(35)
        await assert_applied(35)
        started = asyncio.get_running_loop().time()
        deadline = started + options.duration
        next_probe = started
        while asyncio.get_running_loop().time() < deadline:
            await asyncio.gather(*(connection.heartbeat() for connection in connections))
            await assert_volumes(35)
            _, actual = await snapshot(options, baseline)
            if any(abs(value - round(35 * 65536 / 100)) > 1 for value in actual.values()):
                raise RuntimeError('MiPlay input volume changed during the stability window')
            poll_count += 1
            if asyncio.get_running_loop().time() >= next_probe:
                probe = await Control.connect(options)
                try:
                    if await probe.get_volume() != 35:
                        raise RuntimeError('new MiPlay connection lost the current volume')
                    probe_count += 1
                finally:
                    await probe.close()
                next_probe = asyncio.get_running_loop().time() + 3
            await asyncio.sleep(min(1, max(0, deadline - asyncio.get_running_loop().time())))
        elapsed = asyncio.get_running_loop().time() - started
        for value in (0, 42, 100):
            await connections[1].set_volume(value)
            await assert_volumes(value)
            await assert_applied(value)
    finally:
        await asyncio.gather(*(connection.close() for connection in connections))
    await snapshot(options, baseline)
    return {'ok': True, 'stable_volume': 35, 'stable_seconds': round(elapsed, 2),
            'poll_checks': poll_count, 'new_connection_checks': probe_count,
            'verified_volumes': [35, 0, 42, 100], 'persistent_connections': 3,
            'output_raw_volume': baseline, 'output_volume_unchanged': True,
            'output_state': 'SUSPENDED', 'audio_streams_created': 0, 'ended_idle': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', required=True)
    parser.add_argument('--source-address', required=True)
    parser.add_argument('--port', type=int, default=8899)
    parser.add_argument('--duration', type=float, default=20)
    parser.add_argument('--pulse-server', default=PULSE_SERVER)
    options = parser.parse_args()
    if not 20 <= options.duration <= 60 or not 1 <= options.port <= 65535:
        parser.error('duration must be 20..60 seconds and port must be 1..65535')
    try:
        result = asyncio.run(check(options))
    except Exception as exc:
        print(json.dumps({'ok': False, 'error_type': type(exc).__name__}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
