# VTech Baby Pro bridge container.
#
# Bundles:
#   - The bionic chroot (extracted from a real Android phone)
#   - The vtech_native bridge binary (linked against bionic, produces plaintext H.264)
#   - dnsmasq (listens on 127.0.0.1:53; bionic resolver inside chroot needs this)
#   - ffmpeg (used by go2rtc for snapshot/MJPEG endpoints)
#   - go2rtc (serves RTSP/WebRTC/HLS/MJPEG to Frigate or any client)
#
# Build context is assembled by `build-context.sh` from your existing artifacts
# (bionic-rootfs.tar.gz + the vtech-bridge files).
#
# Build:
#   ./build-context.sh
#   docker buildx build --platform linux/arm64 -t vtech-bridge:latest .
#
# Run (on aarch64 host on the camera's VLAN):
#   docker run -d --name vtech-bridge \
#       --network host \
#       --cap-add SYS_ADMIN --cap-add SYS_CHROOT \
#       -e VTECH_UID=<YOUR_CAMERA_UID> \
#       -e VTECH_PASSWORD=<YOUR_PASSWORD> \
#       -v /path/to/your/LICENSE_KEY.txt:/chroot/data/local/tmp/LICENSE_KEY.txt:ro \
#       vtech-bridge:latest
#
# (Or use docker compose with a `.env` file - see ../../.env.example.)
#
# (--network host is required for UDP broadcast to work; the camera discovery
#  packets need to leave on the same broadcast domain. Ditto bind mounts need
#  SYS_ADMIN. If your container runtime won't grant either, use --privileged.)

FROM debian:bookworm-slim

# Runtime deps: dnsmasq for DNS, ffmpeg for go2rtc snapshot transcoding,
# wget+ca-certs to install go2rtc.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        dnsmasq \
        ffmpeg \
        wget \
        ca-certificates \
        iproute2 \
    && rm -rf /var/lib/apt/lists/*

# Install go2rtc (single static binary)
RUN ARCH=$(dpkg --print-architecture) \
    && wget -q -O /usr/local/bin/go2rtc \
        "https://github.com/AlexxIT/go2rtc/releases/latest/download/go2rtc_linux_${ARCH}" \
    && chmod +x /usr/local/bin/go2rtc

# Bring in the bionic rootfs (~30 MB after extraction).
# build-context.sh assembled this directory.
COPY rootfs/ /chroot/

# Bridge wrapper, go2rtc + dnsmasq config, entrypoint
COPY vtech-bridge.sh /usr/local/bin/vtech-bridge.sh
COPY entrypoint.sh   /entrypoint.sh
COPY go2rtc.yaml     /etc/go2rtc/go2rtc.yaml
COPY dnsmasq.conf    /etc/dnsmasq.d/loopback-only.conf

RUN chmod +x /usr/local/bin/vtech-bridge.sh /entrypoint.sh \
        /chroot/data/local/tmp/vtech_native \
        /chroot/system/bin/linker64

# go2rtc default ports
EXPOSE 1984 8554 8555

# Sane defaults - override at `docker run` time
ENV VTECH_UID="changeme" \
    VTECH_PASSWORD="changeme" \
    VTECH_DURATION="0"

ENTRYPOINT ["/entrypoint.sh"]
