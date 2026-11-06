# Native VBAN receiver

`vban_pulse.c` is an optional Linux receiver for 48 kHz, two-channel, signed
16-bit little-endian VBAN PCM. It writes directly to a PulseAudio sink through
libpulse's asynchronous API. UDP, PulseAudio, the local control socket and
timeouts share one event loop. There is no PCM pipe, subprocess player or
desktop null-sink/loopback in this path.

Build with a C11 compiler and the PulseAudio development headers:

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror native/vban_pulse.c \
  -o vban-pulse $(pkg-config --cflags --libs libpulse) -lm
```

Example against an existing, explicitly selected server and output:

```sh
./vban-pulse --server unix:/run/lan-audio/pulse.sock \
  --source-ip 192.0.2.10 --port 6980 --stream-name Windows \
  --sink output --latency-ms 16 --jitter-ms 8 --idle-ms 500 \
  --gain 1 --control /run/lan-audio/desktop-control.sock --managed
```

The `--source-ip` argument is mandatory. The stream name must occupy 1–16 bytes.
Only the configured IPv4 source, stream name, PCM format and exact packet length
are accepted. Datagram payloads are limited by VBAN to 256 audio frames. The
receiver uses a fixed 64-slot packet ring, with a separate 40 ms byte limit;
duplicate/late packets never keep playback awake. A small reorder window allows
adjacent swaps; bounded missing packets are concealed, while large discontinuities
discard stale queued PCM. Sequence wraparound and a sender counter reset after
the idle timeout are supported.

The requested playback attributes are `tlength=--latency-ms`, `minreq=2 ms`,
`prebuf=0`, `maxlength=40 ms`, with `ADJUST_LATENCY`, `VARIABLE_RATE` and a
pre-created corked stream. PulseAudio may negotiate different values; the JSON
status reports the actual byte counts. Startup fills this single negotiated
queue once, including a larger client queue required by a hardware latency floor.
Short notifications can start without waiting for another packet.
The clock controller observes total application/Pulse backlog, smooths it, and
limits rate correction to ±2000 ppm with a 200 ppm/second slew limit.
Its total backlog target is the returned client `tlength` duration plus
`configured_sink_usec`, updated when Pulse changes the negotiated attributes.
Before valid timing information arrives it uses the requested total budget.
`effective_target_us`, `configured_sink_us` and `target_negotiated` expose that
decision. No additional jitter duration is added to the negotiated total.
Pulse may therefore require more than the requested latency on a physical device.
This follows PulseAudio 17's [ADJUST_LATENCY negotiation](https://github.com/pulseaudio/pulseaudio/blob/v17.0/src/pulsecore/protocol-native.c#L776)
and the [configured sink timing field](https://github.com/pulseaudio/pulseaudio/blob/v17.0/src/pulse/def.h#L675).
Its latency field is a timing-index estimate, not a physical output measurement.
Each rate update requires both a successful Pulse ACK and a matching server-side
sink-input sample rate. Status exposes `rate_ack`, `server_rate`, `rate_pending`
and the selected resampler. The integral can cover clock error without requiring
the queue to remain near empty to supply a persistent proportional error.

After input or nonzero PCM has been absent for `--idle-ms`, the receiver drains,
corks and flushes its stream. It does not synthesize an indefinite silence stream.
When no phone route or route replacement is registered, it mutes and suspends
the selected output. Therefore standalone mode assumes ownership of that output;
use `--managed` when a supervisor also manages phone audio. Managed startup holds
desktop audio corked until the first successful `PHONE` command, and does not
change the existing output's state before that handshake.

## Local control protocol

The optional control endpoint is an `AF_UNIX/SOCK_DGRAM` socket with mode `0600`.
The caller binds its own temporary pathname socket and sends one ASCII command
per datagram. Replies are JSON. `ok: true`, `pid`, `sink_input`, `active`, `state`,
`phone` and `phone_pending` identify the state; `sink_input=4294967295` means the
Pulse stream is not ready. Errors have `ok: false`. `GAIN`, `PHONE` and `HOLD`
acknowledge only after PulseAudio has applied the coordinated changes.

| Command | Effect |
| --- | --- |
| `STATUS` | Read current state and counters. |
| `GAIN 0.5` | Set the desktop's linear base gain in the range 0–1. |
| `PHONE 42` | Register that exact phone sink-input; clear a replacement hold. |
| `PHONE -1` | Remove the phone reference and clear a replacement hold. |
| `HOLD` | Keep output awake and preserve mixed desktop gain during replacement. |
| `SUBSCRIBE` | Read current status and receive later JSON events on this socket. |

When both desktop and phone are active, each uses linear gain 0.5, with desktop
base gain additionally applied. Phone receiver volume remains on its own bus.
The receiver changes only its own sink-input and the explicitly registered phone
sink-input. It never searches for arbitrary phone streams. A missing registered
phone input is cleared safely; the supervisor must verify the acknowledged ID.

For a new phone route: create the loopback on `discard`, send `PHONE <index>`,
check the ACK, then move that input to `output`. For final phone stop: unload
the phone route, then send `PHONE -1`. During replacement: send `HOLD`, unload
the old route, create its successor on `discard`, send `PHONE <new-index>`, then
move it to `output`. Internally a held old input remains known until removal so
a simultaneous first desktop packet cannot bypass the phone gain adjustment.
An aborted replacement must finish with `PHONE -1`.

The supervisor validates the receiver PID and the exact Pulse property
`application.name=lan-audio-bridge-desktop-native`. After a receiver restart it
reapplies `GAIN` and the current `PHONE` registration before enabling desktop
playback. On receiver failure it restores the continuing phone lane's gain.

## Isolated PCM verification

`tests/native_vban.py` starts a private Pulse server and native receiver in a
disposable container. It exercises sustained PCM, cold start, mixed playback,
packet loss/duplicates/reordering, idle/cork reuse, `HOLD`, and independent gain.
It reports UDP submission to `output.monitor` observation with a 2 ms recording
buffer. It also reports media-period underflow events separately from the expected
underflow after the sender stops, and analyzes silent sample runs.

```sh
python3 tests/native_vban.py --binary /tmp/vban-pulse \
  --output /tmp/native-results --seconds 120 --latency-ms 16 --jitter-ms 8 --require-stable
```

Use `--drift-ppm -200` and `--drift-ppm 200` for the two clock-offset cases.
The fixture defaults to `speex-float-5` and retains the 2 ms recording request.
`monitor_clock` reports recorded frames against monotonic time; `steady_passed`
separates actual media-period underflows from the expected underrun after stop.
The result's top-level `ok` reflects the requested gates before the JSON is saved;
a failed required gate also returns a nonzero process exit status.

`--sink-floor-ms 20 --max-observed-latency-ms 55` exercises a fixed 20 ms sink
scheduling floor. This optional fixture requires `gcc` and injects a test shim
only into its private Pulse process; no system library is replaced. It clamps
the null sink's actual scheduling range and independently checks `pactl`'s
configured sink latency. At a 20 ms floor, Pulse negotiates a 24 ms client queue
and the receiver consequently targets 44 ms total, rather than claiming that
the requested 16 ms can be satisfied. Its explicit 55 ms observation gate is
separate from the normal sub-20 ms software gate.

These measurements exclude Windows capture and its virtual driver, physical LAN,
the ALSA device queue, DAC and speaker. A null-sink monitor may expose audio before
its nominal playback time. Software monitor timings do not establish end-to-end
audio latency. The 8/4 ms experimental setting showed media-period underruns in
local WSL tests and should not be treated as a proven stable hardware setting.
At 16/8 ms with `speex-float-5`, both clock-offset runs lasted at least 120 seconds,
passed the strict gate with zero media-period underruns, and had no silent run
beyond one ordinary sine-wave zero-crossing sample (0.0208 ms):

| Sender clock offset | Solo p95 | Solo maximum | Cold start | Mixed p95 |
| --- | --- | --- | --- | --- |
| -200 ppm | 15.535 ms | 16.258 ms | 8.663 ms | 8.408 ms |
| +200 ppm | 14.859 ms | 15.507 ms | 10.723 ms | 9.721 ms |

These final runs used the negotiated total target (10 ms client queue plus 6 ms
configured sink latency), rather than the earlier client-only target. Their local
null-sink monitor clock measured about +580–595 ppm against monotonic time. An
earlier diagnostic measured +386 ppm; combined with a -200 ppm sender even that
exceeded the old ±500 ppm correction limit, and saturation caused underruns.
The wider actuator limit and integral authority correct that mismatch. The server
confirmed actual stream rates of 47963 and 47982 Hz near the ends of the final
runs. The same exercises verified phone
mixing, independent gain, reordering/loss recovery and idle drain/cork reuse.
The 20 ms fixed-floor fixture also passed a 30-second strict continuity test:
24 ms client queue plus 20 ms configured sink gave a 44 ms target; observed solo
p95 was 41.137 ms, maximum 41.717 ms, and mixed p95 35.191 ms. It had zero
media-period underruns and only the ordinary 0.0208 ms zero-crossing sample.
Its initial run exposed the startup deadline still using the 16 ms request;
waiting for the actually negotiated client fill fixed that floor-specific underrun.

The corresponding local artifacts are `test-results/native-vban/target-negative-120s-q5`,
`target-positive-120s-q5`, and `target-floor20-prefill-30s`. The fixed-floor fixture
does not establish behavior for devices whose required scheduling quantum exceeds
the receiver's 40 ms client queue cap.
This is evidence for that local software setup, not a guarantee for a physical
device or every scheduling load.
