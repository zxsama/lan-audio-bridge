# Independent RAOP / AirPlay 1 audio validation

`tests/airplay_sender.py` sends a locally generated 440 Hz stereo WAV from a separate Docker container to the existing isolated receiver. It does not inject audio into PulseAudio. The receiver remains the normal AirPlay 2 enabled Shairport Sync 5.6.2 build with its original configuration.

Run in the Linux/WSL repository directory after starting `compose.test.yaml`:

```sh
python3 tests/airplay_sender.py
```

The wrapper validates the Compose project, null output, non-host network and absence of mapped sound devices. It creates a temporary sender on `lan-audio-bridge-test_default`, installs `pyatv==0.18.0` and `srptools==1.0.1` in that container only, and removes it in `finally`. The receiver is not restarted. No account, phone, stored credential or host Python package installation is needed. Initial dependency installation requires Internet access and may take several minutes.

The sender uses the public `ManualService` API and `AirPlayVersion.V1` setting. This selects classic RAOP on the sender; it does not downgrade the receiver. Twelve seconds of generated stereo audio traverse the RAOP network path and Shairport before reaching PulseAudio. The receiver-side assertions reuse `integration.py` to check the sole `airplay_bus.monitor -> output` route, record `output.monitor`, verify the 440 Hz component and reject 660/880 Hz leakage. The test also requires an idle route before playback and after sender completion. `--sender NAME` is an optional development shortcut for a preinstalled disposable sender; that container is caller-owned and is not automatically removed.

## Evidence and boundaries

On 2026-10-29 the unchanged isolated receiver passed the independent sender test. One measured capture had 440 Hz amplitude 10002.1; comparison components were 660 Hz 0.3274 and 880 Hz 0.1388 (16-bit sample units). Sender completion and return to idle also passed. The full automatically provisioned run is retained in `test-results/airplay-sender.txt` (local ignored evidence).

This validates **RAOP / AirPlay 1 real audio**, not AirPlay 2 playback, Apple phone interoperability, multi-room synchronization or physical audio output.

The bounded AirPlay 2 feasibility attempt failed before media transfer: pyatv 0.18.0's initial SETUP hardcodes `timingProtocol: NTP` and has no `streams` array yet. Shairport Sync 5.6.2 initializes that handler's response to 501 and explicitly leaves NTP streams unimplemented. Its supported full audio branch uses PTP. Changing a timing string alone would not supply the missing PTP sender implementation, so this test does not modify the protocol library or receiver to manufacture a pass. The failure is a documented mode mismatch between this sender and receiver, not evidence of a bridge configuration defect.

Discovery plus a V1 setting also timed out at ANNOUNCE in this experiment. The successful public manual configuration avoids inheriting AP2 transient authentication characteristics. No credentials were stored. A fresh unconstrained installation initially selected srptools 2.0.0, whose constructor signature is incompatible with pyatv 0.18.0; the test therefore pins srptools 1.0.1.

Primary references:

- [pyatv file streaming API](https://pyatv.dev/development/stream/)
- [pyatv manual configuration and protocol-version settings](https://pyatv.dev/documentation/atvremote/)
- [pyatv 0.18.0 AirPlay V2 initial SETUP](https://github.com/postlund/pyatv/blob/v0.18.0/pyatv/protocols/raop/protocols/airplayv2.py#L45-L67)
- [Shairport Sync 5.6.2 SETUP handling](https://github.com/mikebrady/shairport-sync/blob/5.6.2/rtsp.c#L2249-L2443)
