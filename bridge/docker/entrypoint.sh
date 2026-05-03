#!/bin/bash
# Container entrypoint for the VTech Baby Pro bridge.
# Sets up bind mounts for the bionic chroot, starts dnsmasq, runs go2rtc.
set -euo pipefail

ROOTFS=/chroot

echo "[entrypoint] bind-mounting /proc /sys /dev into ${ROOTFS}/"
for d in proc sys dev; do
    if ! mountpoint -q "${ROOTFS}/${d}"; then
        mount --bind "/${d}" "${ROOTFS}/${d}"
    fi
done

echo "[entrypoint] starting dnsmasq on 127.0.0.1:53"
# Run in foreground so we can capture failures, but background it from this
# script so go2rtc gets PID 1.
dnsmasq --keep-in-foreground \
        --pid-file=/tmp/dnsmasq.pid \
        --conf-file=/etc/dnsmasq.d/loopback-only.conf \
        2>&1 | sed 's/^/[dnsmasq] /' &

# Wait for it to actually be listening
for i in 1 2 3 4 5 6 7 8 9 10; do
    if ss -lnu sport = :53 2>/dev/null | grep -q '127.0.0.1'; then
        echo "[entrypoint] dnsmasq up"
        break
    fi
    sleep 0.3
done

echo "[entrypoint] starting go2rtc"
exec /usr/local/bin/go2rtc -c /etc/go2rtc/go2rtc.yaml
