ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:89c1ea91e897f0fe0a3731595330bc45b8bdef4047464a07116f891a94054b31

FROM ${DEBIAN_IMAGE} AS build
ARG TARGETARCH=amd64
ARG BUILD_JOBS=4
RUN test "$TARGETARCH" = amd64 && test "$(dpkg --print-architecture)" = amd64
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl build-essential autoconf automake libtool pkg-config \
    rustc cargo libpulse-dev libavahi-client-dev libssl-dev libconfig-dev \
    libpopt-dev libsoxr-dev libplist-dev libplist-utils libsodium-dev \
    libgcrypt20-dev uuid-dev libavutil-dev libavcodec-dev libavformat-dev \
    libswresample-dev xxd \
    && rm -rf /var/lib/apt/lists/*

# Immutable upstream revisions, with archive hashes verified before extraction.
WORKDIR /sources
RUN curl -fsSL --retry 3 https://codeload.github.com/mikebrady/shairport-sync/tar.gz/0a34fbda83724cc06266aadcf7c88acc8fef4e7d -o shairport-sync.tar.gz \
    && echo '3e5a58aba5a751ed8c33ebd73228218105f0afe26da382cd76fd93fbf21f83f4  shairport-sync.tar.gz' | sha256sum -c - \
    && curl -fsSL --retry 3 https://codeload.github.com/mikebrady/nqptp/tar.gz/ab8fb67483411640fd7f1e193889482f2421c37c -o nqptp.tar.gz \
    && echo '3e90e2ea1f52f5c1559a5a46b2cdadb46ac6532a08a34f8cd7e77aa39f6a90c7  nqptp.tar.gz' | sha256sum -c - \
    && curl -fsSL --retry 3 https://codeload.github.com/librespot-org/librespot/tar.gz/d36f9f1907e8cc9d68a93f8ebc6b627b1bf7267d -o librespot.tar.gz \
    && echo 'fc1b26c1388ef8594fa615032516d972f58009d7ddfda8a601060c39f0edf67c  librespot.tar.gz' | sha256sum -c - \
    && mkdir shairport-sync nqptp librespot \
    && tar -xzf shairport-sync.tar.gz --strip-components=1 -C shairport-sync \
    && tar -xzf nqptp.tar.gz --strip-components=1 -C nqptp \
    && tar -xzf librespot.tar.gz --strip-components=1 -C librespot

WORKDIR /sources/nqptp
RUN autoreconf -fi && ./configure --prefix=/usr/local \
    && make -j"${BUILD_JOBS}" && install -Dm755 nqptp /out/bin/nqptp
WORKDIR /sources/shairport-sync
RUN autoreconf -fi \
    && ./configure --prefix=/usr/local --with-airplay-2 --with-pulseaudio \
       --with-avahi --with-ssl=openssl --with-soxr --with-ffmpeg \
       --without-configfiles --without-create-user-group \
    && make -j"${BUILD_JOBS}" \
    && install -Dm755 shairport-sync /out/bin/shairport-sync
WORKDIR /sources/librespot
RUN cargo build --release --locked --jobs "${BUILD_JOBS}" --no-default-features \
       --features 'pulseaudio-backend,with-avahi,native-tls' \
    && install -Dm755 target/release/librespot /out/bin/librespot
RUN mkdir -p /out/share/doc/lan-audio-bridge/upstream /out/share/lan-audio-bridge/sources \
    && cp /sources/shairport-sync/LICENSES /out/share/doc/lan-audio-bridge/upstream/shairport-sync-LICENSES \
    && cp /sources/nqptp/LICENSE /out/share/doc/lan-audio-bridge/upstream/nqptp-LICENSE \
    && cp /sources/librespot/LICENSE /out/share/doc/lan-audio-bridge/upstream/librespot-LICENSE \
    && cp /sources/*.tar.gz /out/share/lan-audio-bridge/sources/ \
    && strip /out/bin/*

FROM ${DEBIAN_IMAGE} AS base
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates python3 pulseaudio pulseaudio-utils alsa-utils \
    dbus avahi-daemon avahi-utils gmediarender=0.3-1 \
    gstreamer1.0-tools gstreamer1.0-pulseaudio gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-libav \
    libpulse0 libavahi-client3 libssl3t64 libconfig11 libpopt0 libsoxr0 \
    libplist-2.0-4 libsodium23 libgcrypt20 libuuid1 \
    libavutil59 libavcodec61 libavformat61 libswresample5 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /out/ /usr/local/
# Fail the build if a selected protocol/backend or runtime library is absent.
RUN shairport-sync -V | tee /tmp/shairport-version \
    && grep -q '5.6.2' /tmp/shairport-version \
    && grep -q 'AirPlay2' /tmp/shairport-version \
    && grep -q 'PulseAudio' /tmp/shairport-version \
    && librespot --version \
    && librespot --backend '?' 2>&1 | tee /tmp/librespot-backends \
    && grep -q 'pulseaudio' /tmp/librespot-backends \
    && nqptp -V && gmediarender --version \
    && gst-inspect-1.0 pulsesink >/dev/null \
    && gst-inspect-1.0 souphttpsrc >/dev/null \
    && printf '\nflat-volumes = no\n' >> /etc/pulse/daemon.conf \
    && rm -f /etc/machine-id /var/lib/dbus/machine-id \
    && ln -s /run/lan-audio/machine-id /etc/machine-id \
    && ln -s /run/lan-audio/machine-id /var/lib/dbus/machine-id \
    && mkdir -p /data /run/lan-audio /usr/local/share/doc/lan-audio-bridge \
    && dpkg-query -W > /usr/local/share/doc/lan-audio-bridge/debian-packages.txt \
    && rm -f /tmp/shairport-version /tmp/librespot-backends

FROM base AS final
RUN apt-get update && apt-get install -y --no-install-recommends xdg-dbus-proxy \
    ffmpeg python3-dbus python3-zeroconf python3-pycryptodome \
    && dpkg --compare-versions "$(dpkg-query -W -f='${Version}' xdg-dbus-proxy)" ge '0.1.6-1+deb13u3' \
    && command -v dbus-run-session \
    && dpkg-query -W > /usr/local/share/doc/lan-audio-bridge/debian-packages.txt \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY app/ /app/
RUN python3 -c 'import dbus, zeroconf; from vendor.castfabric_miplay.receiver import MiPlayReceiver; import hashlib, json, pathlib; p = pathlib.Path("/app/vendor/castfabric_miplay"); m = json.loads((p / "SOURCE.json").read_text()); assert all(hashlib.sha256((p / n).read_bytes()).hexdigest() == v["sha256"] for n, v in m["files"].items())' \
    && gst-inspect-1.0 queue >/dev/null && ffmpeg -version >/dev/null
COPY scripts/probe-host.sh scripts/status.sh /app/scripts/
COPY docs/UPSTREAM.md /usr/local/share/doc/lan-audio-bridge/UPSTREAM.md
COPY LICENSE THIRD_PARTY_NOTICES.md Dockerfile /usr/local/share/doc/lan-audio-bridge/
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD ["python3", "/app/healthcheck.py"]
CMD ["python3", "/app/runtime.py"]
