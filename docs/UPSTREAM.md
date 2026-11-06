# Upstream sources and build provenance

This project builds a Linux amd64 image from the official Debian image and pinned upstream sources. `Dockerfile` is the authoritative build recipe. The project's original code is licensed under [MIT](../LICENSE); [third-party notices](../THIRD_PARTY_NOTICES.md) describe component-specific licensing.

## Pinned inputs

| Component | Revision | Source and licence |
| --- | --- | --- |
| CastFabric MiPlay subset | `5b7733ee9185a85843606de6fe94867f7d5a42cf` | [Source](https://github.com/DjangoAILab/CastFabric/tree/5b7733ee9185a85843606de6fe94867f7d5a42cf/miair/miplay), MIT; vendored at `app/vendor/castfabric_miplay`, with original and delivered SHA256 in `SOURCE.json`, retained `LICENSE` and local patch notes in `NOTICE.md` |
| Debian | `trixie-slim`, manifest digest `sha256:89c1ea91e897f0fe0a3731595330bc45b8bdef4047464a07116f891a94054b31` | [Docker Official Image](https://hub.docker.com/_/debian); individual Debian package licences apply |
| Shairport Sync | `5.6.2`, commit `0a34fbda83724cc06266aadcf7c88acc8fef4e7d` | [Source](https://github.com/mikebrady/shairport-sync/tree/0a34fbda83724cc06266aadcf7c88acc8fef4e7d), [MIT with BSD/ISC component notices](https://github.com/mikebrady/shairport-sync/blob/0a34fbda83724cc06266aadcf7c88acc8fef4e7d/LICENSES) |
| nqptp | `1.2.9`, commit `ab8fb67483411640fd7f1e193889482f2421c37c` | [Source](https://github.com/mikebrady/nqptp/tree/ab8fb67483411640fd7f1e193889482f2421c37c), [GPL-2.0-only](https://github.com/mikebrady/nqptp/blob/ab8fb67483411640fd7f1e193889482f2421c37c/LICENSE) |
| librespot | `0.8.0`, commit `d36f9f1907e8cc9d68a93f8ebc6b627b1bf7267d` | [Source](https://github.com/librespot-org/librespot/tree/d36f9f1907e8cc9d68a93f8ebc6b627b1bf7267d), [MIT](https://github.com/librespot-org/librespot/blob/d36f9f1907e8cc9d68a93f8ebc6b627b1bf7267d/LICENSE); Rust dependencies have their own licences |
| gmrender-resurrect | Debian binary package `gmediarender=0.3-1` | [Debian package](https://packages.debian.org/trixie/gmediarender), [Debian source](https://sources.debian.org/src/gmrender-resurrect/0.3-1/), GPL-2.0-or-later and component notices; see installed `copyright` |
| xdg-dbus-proxy | Debian trixie security package, minimum `0.1.6-1+deb13u3` | [Debian package and source downloads](https://packages.debian.org/trixie/xdg-dbus-proxy), [upstream source](https://github.com/flatpak/xdg-dbus-proxy), [Debian copyright](https://metadata.ftp-master.debian.org/changelogs//main/x/xdg-dbus-proxy/xdg-dbus-proxy_0.1.6-1%2Bdeb13u3_copyright); LGPL-2.1-or-later, with LGPL-2.0-or-later component/packaging notices |

SHA-256 of the exact GitHub codeload archives used by the build:

```text
3e5a58aba5a751ed8c33ebd73228218105f0afe26da382cd76fd93fbf21f83f4  shairport-sync.tar.gz
3e90e2ea1f52f5c1559a5a46b2cdadb46ac6532a08a34f8cd7e77aa39f6a90c7  nqptp.tar.gz
fc1b26c1388ef8594fa615032516d972f58009d7ddfda8a601060c39f0edf67c  librespot.tar.gz
```

These hashes detect altered downloads; they are recorded by this project, not upstream signatures. The build verifies them before extraction. Librespot uses its upstream `Cargo.lock` with `cargo build --locked --no-default-features --features pulseaudio-backend,with-avahi,native-tls`. Rust/Cargo come from Debian trixie. Shairport enables AirPlay 2, PulseAudio, Avahi, OpenSSL, SoXR and FFmpeg. nqptp runs in the foreground under the Python supervisor; systemd is not used as the container supervisor.

Other Debian dependencies track the signed trixie and trixie-security repositories, allowing security updates on rebuild. Thus this is a revision-pinned application build, not a bit-for-bit reproducible Debian snapshot. The image records all installed Debian package versions at `/usr/local/share/doc/lan-audio-bridge/debian-packages.txt`.

The final image installs `xdg-dbus-proxy` and checks its Debian package version against `0.1.6-1+deb13u3`; the 0.1.1 build installed that exact Debian version. Debian retains the upstream `0.1.6` version while backporting fixes; an upstream-only version banner does not identify the patch level. The `debian/changelog` in the [official Debian security source package](https://security.debian.org/debian-security/pool/updates/main/x/xdg-dbus-proxy/xdg-dbus-proxy_0.1.6-1+deb13u3.debian.tar.xz) records the cumulative fixes: `deb13u1` corrects match-rule handling (CVE-2026-34080), `deb13u2` corrects broadcast filtering (CVE-2026-93676), and `deb13u3` applies upstream 0.1.9 message-filtering patches (CVE-2026-94422). Debian's [package security tracker](https://security-tracker.debian.org/tracker/source-package/xdg-dbus-proxy) and [DSA-6510-1](https://security-tracker.debian.org/tracker/DSA-6510-1) also identify the fixed versions. Check the installed Debian package version and provenance record when rebuilding. Do not substitute an unpatched upstream 0.1.6 binary.

The optional host-Avahi deployment runs this proxy in a separate container with explicit method/signal filters. The audio container cannot access the original host bus socket; Debian's [package description](https://packages.debian.org/trixie/xdg-dbus-proxy) explicitly requires this separation for filtering to be effective. Proxy protocol behavior is documented in the [upstream manual](https://github.com/flatpak/xdg-dbus-proxy/blob/main/xdg-dbus-proxy.xml). Application integration and recovery checks are separate from package availability; see [host-avahi.md](host-avahi.md).

## Notices and source availability

The optional desktop receiver in `app/vban_receiver.py` is original project code under MIT, implementing the public [VBAN PCM audio specification](https://vb-audio.com/Voicemeeter/VBANProtocol_Specifications.pdf). It supports a documented subset (48 kHz, stereo, signed 16-bit PCM); it does not vendor the Linux `vban` project or distribute Voicemeeter drivers or binaries. Voicemeeter is a separately installed client with its own licence. Protocol compatibility does not imply VB-Audio certification.

MiPlay includes only the pinned protocol modules and their offline simulator, not the CastFabric product server, account integrations or installer. The Docker build validates delivered source hashes and imports the receiver. Debian supplies `python3-dbus`, `python3-zeroconf`, `python3-pycryptodome` and FFmpeg; package copyright files are retained. Zeroconf is used for protocol data structures; the deployed adapter publishes through existing Avahi D-Bus and never starts its own Zeroconf socket. Modified protocol sources and notices are available verbatim inside `/app/vendor/castfabric_miplay/` and in this repository. This is an independent, experimental receiver, without a Xiaomi compatibility or certification claim.

This repository's original code, scripts and documentation are licensed under the root [MIT licence](../LICENSE). Third-party code, binaries and dependencies retain their own licences and copyright notices. The root licence does not relicense the full container image. This repository publishes source and build instructions; it does not include a prebuilt container image.

Relative links in this document target the source repository. In the image, use the absolute paths below to locate the corresponding materials.

Images built from the current Dockerfile include the project licence, third-party notices, this provenance record and Dockerfile under `/usr/local/share/doc/lan-audio-bridge/`. They also retain Debian copyright files under `/usr/share/doc/*/copyright`, licence texts under `/usr/share/common-licenses`, and directly compiled upstream notices under `/usr/local/share/doc/lan-audio-bridge/upstream/`. Exact source archives for Shairport Sync, nqptp and librespot are included at `/usr/local/share/lan-audio-bridge/sources/`. They are unmodified; the build flags are above and in the supplied Dockerfile. Shairport's `LICENSES` contains the primary licence and a component index; complete component notices are also retained in the source archive, including `tinyhttp/LICENSE` and source-file headers.

For source packages corresponding to installed Debian binaries, enable matching Debian `deb-src` repositories in a separate build environment and use `apt-get source PACKAGE=SOURCE_VERSION`; the binary package record and each package's `Source` metadata identify the source version. Debian's [source archive](https://sources.debian.org/) and [snapshot service](https://snapshot.debian.org/) retain historical versions. Before redistributing images, provide the corresponding source and notices required by the individual licences, including Debian libraries and Rust dependency notices; the three included application archives alone are not a complete corresponding-source bundle for the entire image.

Shairport Sync and librespot are independent implementations. This project does not assert AirPlay or Spotify certification. Spotify service access and account requirements remain governed by Spotify; upstream librespot documents a Premium account requirement. No service credentials or vendor media are included in the image.

## Build checks

The `base` target builds all native binaries and runtime dependencies without requiring application files. Its build fails unless Shairport reports AirPlay 2 and PulseAudio, librespot exposes the PulseAudio backend, nqptp and gmrender run their version commands, and GStreamer provides `pulsesink` and HTTP input. The `final` target adds the supervisor, scripts and this provenance record.

```sh
docker build --target base -t lan-audio-bridge:base .
docker build -t lan-audio-bridge:local .
```

These checks establish binary and plugin availability. Phone discovery, sender playback, physical audio output and timing-port coexistence require the separate runtime and physical-device acceptance checks described in the main documentation.

On 2026-10-28 the image was built successfully with Docker 28.1.1 on Linux amd64. The built binaries reported:

```text
Shairport Sync: 5.6.2-AirPlay2-smi11-OpenSSL-Avahi-PulseAudio-soxr
nqptp: 1.2.9, Shared Memory Interface smi11
librespot: 0.8.0, PulseAudio backend available
gmediarender: 0.3 (Debian package 0.3-1)
```

The source archives do not contain Git metadata, so librespot's version banner contains `VERGEN_IDEMPOTENT_OUTPUT` instead of the commit hash. The verified archive hash and revision table above identify the exact source. No dependency lockfile was regenerated. The installed binary help was checked for the configured receiver arguments, and `gst-inspect-1.0` confirmed `pulsesink` and `souphttpsrc`.

Two upstream details matter for runtime integration. nqptp 1.2.9 creates its shared memory after Shairport initiates the timing exchange, so startup readiness must check its listening sockets instead of waiting for the shared-memory file. Librespot 0.8.0's help text incorrectly describes `--device` as unsupported in a PulseAudio-only build: `src/main.rs` still parses the option, and `playback/src/audio_backend/pulseaudio.rs` supplies its value as the PulseAudio sink name. The receiver therefore uses `--device spotify_bus` together with the configured `PULSE_SERVER`.

The base image disables PulseAudio flat volumes. `/etc/machine-id` and `/var/lib/dbus/machine-id` both point to `/run/lan-audio/machine-id`, which the supervisor initializes from persistent data; the image does not clone one D-Bus identity across installations.
