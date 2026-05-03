#!/bin/bash
# Wrapper that go2rtc invokes as its `exec:` source.
# Inside the container: chroot into /chroot and run vtech_native.
set -e

ROOTFS=/chroot
UID_VAL=${VTECH_UID:-changeme}
PASS_VAL=${VTECH_PASSWORD:-changeme}
DURATION=${VTECH_DURATION:-0}    # 0 = forever (go2rtc's preferred mode)

# Path to the TUTK license-key file. Default is the chroot-internal
# path you'd get if you bind-mounted the host's LICENSE_KEY.txt onto
# /chroot/data/local/tmp/LICENSE_KEY.txt at `docker run` time.
LICENSE_FILE=${VTECH_LICENSE_KEY_FILE:-/data/local/tmp/LICENSE_KEY.txt}

if [ "$UID_VAL" = "changeme" ] || [ "$PASS_VAL" = "changeme" ]; then
    echo "[vtech-bridge] ERROR: set VTECH_UID and VTECH_PASSWORD env vars" >&2
    exit 2
fi

if [ ! -s "$ROOTFS$LICENSE_FILE" ]; then
    echo "[vtech-bridge] ERROR: license key file not found at $ROOTFS$LICENSE_FILE" >&2
    echo "[vtech-bridge] Bind-mount your LICENSE_KEY.txt at \`docker run\` time:" >&2
    echo "[vtech-bridge]   -v /host/path/LICENSE_KEY.txt:$ROOTFS$LICENSE_FILE:ro" >&2
    echo "[vtech-bridge] Extract one from your VTech APK with decode_license_key.py." >&2
    exit 3
fi

# Forward signals so go2rtc can stop us cleanly via SIGTERM
export VTECH_LICENSE_KEY_FILE="$LICENSE_FILE"
exec chroot "$ROOTFS" /data/local/tmp/vtech_native "$UID_VAL" "$PASS_VAL" "$DURATION"
