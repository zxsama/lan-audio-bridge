# Runtime contract

This document describes the container's runtime interface and routing invariants. For setup and validation commands, see [development.md](development.md) and the [README](../README.md).

Target: TrueNAS SCALE, Linux amd64. Single locally built image, three independently enabled receivers (Shairport Sync, gmrender-resurrect, librespot), PulseAudio owns the USB ALSA device. Apple Music and multiroom are out of scope. Do not require a web UI, Docker socket, or privileged mode.

Runtime interface:
- `python3 /app/runtime.py` is the container command; `python3 /app/healthcheck.py` is the Docker health check.
- Environment: `DEVICE_NAME=NAS Audio`, `AUDIO_DEVICE` (required stable ALSA name in hardware mode), `AUDIO_MODE=alsa|null` (null for tests only), `SAMPLE_RATE=48000`, `OUTPUT_VOLUME=70` (percent 0..100), `ENABLE_AIRPLAY=true`, `ENABLE_DLNA=true`, `ENABLE_SPOTIFY=true`, `NETWORK_INTERFACE` optional, `DLNA_PORT=49494`, `AIRPLAY_PORT=7000`, `SPOTIFY_PORT=24879`.
- Persistent directory `/data`, ephemeral runtime directory `/run/lan-audio`, status JSON `/run/lan-audio/status.json`. Never store credentials in logs or status. Stable DLNA UUID persisted under /data.
- Pulse server `unix:/run/lan-audio/pulse.sock`. Sinks `airplay_bus`, `dlna_bus`, `spotify_bus`, `discard`, `output`. Never load rescue-streams / automatic device switching. In null mode output is a null sink. Hardware mode uses module-alsa-sink with AUDIO_DEVICE, not automatic default selection.
- All receivers write only to their bus. Sole output route is one module-loopback from owner bus monitor to output. Unload before load; failures fail closed. No route at startup or idle.
- Coordinator polls actual Pulse sink-inputs (corked vs active) every 0.2s. Newly active source can take over; stop/restart losing receiver so it does not silently advance/reclaim on next track. Same protocol concurrency is delegated to receiver. Late disappearance of old streams must not release new owner. Restarting a receiver briefly reannounces it. Do not promise phone UI pause. No automatic fallback to old source when owner stops.
- Runtime supervisor nonblocking restarts preempted receivers; a dead core dependency (PulseAudio, dbus, avahi, nqptp if used) exits the whole container for restart. Receiver crash restart with bounded backoff. SIGTERM shuts down all children; use process groups.
- Include dbus/avahi for discovery and nqptp for AirPlay 2. Prefer pinned Shairport 5.6.2 and librespot 0.8.0, gmrender from Debian trixie. AirPlay 2 startup requires nqptp UDP319/320 and no conflicting timing service.
- Logs stdout/stderr, bounded via Compose logging. Production host network + /dev/snd mapping. Compose test variant bridge + null output, isolated names/data; do not touch NAS.
