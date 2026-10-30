# CastFabric MiPlay protocol subset

Source: https://github.com/DjangoAILab/CastFabric/tree/5b7733ee9185a85843606de6fe94867f7d5a42cf/miair/miplay

MIT license retained in LICENSE. SOURCE.json locks the commit, original upstream
SHA256 and delivered SHA256 for every source file. Only these protocol modules
and its offline simulator are included; no product server, account client,
cloud integration or install scripts are imported.

Local changes:

- control.py: propagate decoded pause/resume/close actions; paused GET_STATE uses
  the existing non-playing value (3), rather than reporting playing (2). This
  reuse is an implementation consistency choice, not independent confirmation
  of the complete Xiaomi audio wire-state enumeration.

- receiver.py: forward configured friendly name and initial bounded volume into
  control sessions; detect volume changes through wrapped control commands;
  limit control sessions to 16; require reverse WFD endpoint to match its
  control peer; propagate CLOSE/control EOF, RTSP and decoder termination;
  bound unpaused media inactivity to 30 seconds; shield reaping against racing
  cancellation. A new session restores its announced volume on the input bus.
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
