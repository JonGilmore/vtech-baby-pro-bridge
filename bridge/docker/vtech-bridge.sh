#!/bin/bash
# Wrapper that go2rtc invokes as its `exec:` source.
# Inside the container: chroot into /chroot, run vtech_native, and (in the
# default audio+video mode) mux the bridge's H.264 stdout + the decrypted
# G.711µ audio fifo into a single MPEG-TS stream on stdout via ffmpeg.
set -e

ROOTFS=/chroot
UID_VAL=${VTECH_UID:-changeme}
PASS_VAL=${VTECH_PASSWORD:-changeme}
DURATION=${VTECH_DURATION:-0}    # 0 = forever (go2rtc's preferred mode)
DISABLE_AUDIO=${VTECH_DISABLE_AUDIO:-0}
VIDEO_FPS=${VTECH_VIDEO_FPS:-15} # camera defaults to HD@15fps

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

export VTECH_LICENSE_KEY_FILE="$LICENSE_FILE"

# Video-only escape hatch (raw Annex-B H.264 to stdout, pre-audio behavior).
# Useful for bisecting if the muxed path regresses.
if [ "$DISABLE_AUDIO" = "1" ]; then
    exec chroot "$ROOTFS" /data/local/tmp/vtech_native "$UID_VAL" "$PASS_VAL" "$DURATION"
fi

# Audio+video path. Layout:
#   bridge stdout (raw H.264 Annex-B) ──► ffmpeg input #0 (via /dev/fd/N from <())
#   bridge writes G.711µ to AFIFO     ──► ffmpeg input #1 (named pipe)
#   ffmpeg muxes both ───► MPEG-TS on stdout ───► go2rtc
#
# fifo lives inside the chroot tree because the bridge runs chrooted into
# /chroot — so the bridge sees the fifo at AFIFO_CHROOT and ffmpeg (running
# in the container's filesystem) sees the same fifo at AFIFO_HOST. Path is
# per-invocation (mktemp) so concurrent bridge instances don't collide.
AFIFO_NAME=$(mktemp -u vtech_audio_XXXXXX).fifo
AFIFO_HOST="$ROOTFS/data/local/tmp/$AFIFO_NAME"
AFIFO_CHROOT="/data/local/tmp/$AFIFO_NAME"
mkfifo "$AFIFO_HOST"
trap 'rm -f "$AFIFO_HOST"' EXIT

export VTECH_AUDIO_FIFO="$AFIFO_CHROOT"

# Audio is transcoded G.711µ → AAC because MPEG-TS doesn't have a standard
# stream type for raw G.711; ffmpeg muxes it as opaque "bin_data" which
# RTSP clients can't decode. AAC LC at 8 kHz mono / 64 kbps is the cheapest
# universally-decodable choice for baby-monitor speech audio.
# Tight analyzeduration/probesize so ffmpeg doesn't sit on input #0 for 5s
# (its default) before opening input #1. Until input #1 opens, the bridge's
# audio thread is blocked on fopen(fifo, "wb"), which means clients see
# nothing for the full analyze window — long enough for many of them
# (Frigate live view, WebRTC players) to give up before the stream starts.
# Audio codec: TUTK codec id 0x8a is µ-law in most SDK builds but A-law
# in some VTech firmware variants. Override with VTECH_AUDIO_CODEC=mulaw
# (or alaw) on `docker run` if one sounds wrong.
AUDIO_CODEC=${VTECH_AUDIO_CODEC:-alaw}

# Audio input: -use_wallclock_as_timestamps 1 stamps each chunk with the
# time it arrived from the bridge, so audio PTS doesn't drift relative to
# video over long sessions. (Not applied to video — raw H.264 has no PTS
# either way and ffmpeg already generates them from -r.)
#
# Audio encoder: -b:a 48k is the practical ceiling for AAC LC at 8 kHz
# mono (above that the codec clamps with a "Too many bits per frame"
# warning). -cutoff 4000 tells the encoder to focus its bit budget on
# the actual signal bandwidth (Nyquist = 4 kHz at 8 kHz sample rate).
exec ffmpeg -hide_banner -loglevel warning \
    -fflags +nobuffer -flags +low_delay \
    -analyzeduration 200000 -probesize 32k \
    -thread_queue_size 512 \
    -r "$VIDEO_FPS" -f h264 -i <(chroot "$ROOTFS" /data/local/tmp/vtech_native "$UID_VAL" "$PASS_VAL" "$DURATION") \
    -thread_queue_size 512 \
    -use_wallclock_as_timestamps 1 \
    -f "$AUDIO_CODEC" -ar 8000 -ac 1 -i "$AFIFO_HOST" \
    -map 0:v:0 -map 1:a:0 \
    -c:v copy \
    -c:a aac -b:a 48k -ar 8000 -ac 1 -cutoff 4000 \
    -max_delay 0 -flush_packets 1 \
    -f mpegts -muxdelay 0 -muxpreload 0 \
    -mpegts_flags +resend_headers \
    pipe:1
