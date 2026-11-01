# CastFabric MiPlay protocol subset

Source: https://github.com/DjangoAILab/CastFabric/tree/5b7733ee9185a85843606de6fe94867f7d5a42cf/miair/miplay

MIT license retained in LICENSE. SOURCE.json locks the commit, original upstream
SHA256 and delivered SHA256 for every source file. Only these protocol modules
and its offline simulator are included; no product server, account client,
cloud integration or install scripts are imported.

Local changes:

- control.py: propagate decoded pause/resume/close actions; distinguish idle=0,
  playing=2 and paused=3. GET_STATE on browse connections reads the active media
  session; media notifications use the same local state calculation. State values
  follow publicly documented receiver observations, not copied implementation code.
- receiver.py: keep the absolute handshake deadline only before authentication.
  After authentication, complete accepted commands renew a separate 120-second
  idle deadline, allowing heartbeat-only device-list connections to stay alive.

- receiver.py: forward configured friendly name and initial bounded volume into
  control sessions; share the current volume across playback and browse connections.
  Accepted SET_VOLUME commands expose explicit actions, including wrapped or repeated
  requests, and commit the bounded device value before awaiting response I/O.
  OPEN reapplies the current value rather than a connection-local initial value;
  limit control sessions to 16; require reverse WFD endpoint to match its
  control peer; propagate CLOSE/control EOF, RTSP and decoder termination;
  bound unpaused media inactivity to 30 seconds; shield reaping against racing
  cancellation. Reconnecting does not reset or unmute the device volume.
- control.py: expose decoded pause/resume actions even inside a type-1 wrapper.
- media.py: bound decoder input drain and shutdown, reap ffmpeg and always stop
  the PCM sink even after a decoder or Pulse failure. Pause closes the Pulse
  input while continuing to decode and discard PCM; resume starts a fresh input
  on subsequent PCM so the coordinator can grant output ownership again.
- safety.py: accept Debian's Cryptodome namespace as well as upstream Crypto.
- simulator.py: optional paced delivery for the isolated local-container test;
  after media EOF keep control alive until the receiver finishes decoder drain
  and closes the session (first-media notification is not drain completion).

The adapter calls MiPlayReceiver with advertise=False. Its Avahi EntryGroup
publisher uses the bridge's existing DBUS_SYSTEM_BUS_ADDRESS and explicit
interface index; it never creates a Zeroconf instance or binds UDP 5353.

Compatibility remains experimental: the included upstream implementation
supports its observed legacy/type-1 control handshake and AAC/WFD stream.
It advertises _mi-connect._udp (SRV 56666 with TCP control port in appsData).
It does not implement MiConnect CoAP on UDP 56666, _lyra-mdns discovery or
legacy broadcast on UDP 5355. Those paths are not established by the upstream
subset and are not advertised as working. Phone/HyperOS interoperability
requires physical-client testing; local sender simulation is not that proof.
