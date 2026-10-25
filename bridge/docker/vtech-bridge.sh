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
#   bridge stdout (raw H.264 Annex-B) ──► VFIFO ──► ffmpeg input #0
#   bridge writes G.711µ to AFIFO     ──► ffmpeg input #1
#   ffmpeg muxes both ───► MPEG-TS on stdout ───► go2rtc
#
# fifos live inside the chroot tree because the bridge runs chrooted into
# /chroot — so the bridge sees the audio fifo at AFIFO_CHROOT and ffmpeg
# (running in the container's filesystem) sees the same fifo at AFIFO_HOST.
# Paths are per-invocation (mktemp) so concurrent bridge instances don't
# collide.
FIFO_ID=$(mktemp -u XXXXXX)
VFIFO_HOST="$ROOTFS/data/local/tmp/vtech_video_$FIFO_ID.fifo"
AFIFO_HOST="$ROOTFS/data/local/tmp/vtech_audio_$FIFO_ID.fifo"
AFIFO_CHROOT="/data/local/tmp/vtech_audio_$FIFO_ID.fifo"
mkfifo "$VFIFO_HOST" "$AFIFO_HOST"

export VTECH_AUDIO_FIFO="$AFIFO_CHROOT"

# The bridge and ffmpeg both run as children of this script (no `exec`) so
# that when either one exits, we tear the other down and exit too. Without
# that, a bridge that dies before its audio thread opens AFIFO (e.g. the
# camera is unreachable at connect time) leaves ffmpeg blocked in open() on
# AFIFO forever — and go2rtc, which never times out waiting for the first
# byte, shows the stream as dead until the container restarts.
#
# ffmpeg gets SIGKILL: its SIGTERM handler doesn't break it out of a
# blocking open() on a fifo.
BRIDGE_PID=
FFMPEG_PID=
cleanup() {
    set +e  # children may already be gone; don't let `set -e` skip the rm
    [ -n "$FFMPEG_PID" ] && kill -KILL "$FFMPEG_PID" 2>/dev/null
    [ -n "$BRIDGE_PID" ] && kill -TERM "$BRIDGE_PID" 2>/dev/null
    wait 2>/dev/null
    rm -f "$VFIFO_HOST" "$AFIFO_HOST"
}
trap cleanup EXIT
# go2rtc stops us with SIGTERM (#killsignal in go2rtc.yaml); exiting from
# the trap runs cleanup via the EXIT trap.
trap 'exit 143' TERM
trap 'exit 130' INT

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
chroot "$ROOTFS" /data/local/tmp/vtech_native "$UID_VAL" "$PASS_VAL" "$DURATION" > "$VFIFO_HOST" &
BRIDGE_PID=$!

ffmpeg -hide_banner -loglevel warning -nostdin \
    -fflags +nobuffer -flags +low_delay \
    -analyzeduration 200000 -probesize 32k \
    -thread_queue_size 512 \
    -r "$VIDEO_FPS" -f h264 -i "$VFIFO_HOST" \
    -thread_queue_size 512 \
    -use_wallclock_as_timestamps 1 \
    -f "$AUDIO_CODEC" -ar 8000 -ac 1 -i "$AFIFO_HOST" \
    -map 0:v:0 -map 1:a:0 \
    -c:v copy \
    -c:a aac -b:a 48k -ar 8000 -ac 1 -cutoff 4000 \
    -max_delay 0 -flush_packets 1 \
    -f mpegts -muxdelay 0 -muxpreload 0 \
    -mpegts_flags +resend_headers \
    pipe:1 &
FFMPEG_PID=$!

# Whichever exits first ends the stream; the EXIT trap stops the other.
rc=0
wait -n || rc=$?
echo "[vtech-bridge] pipeline exited (rc=$rc), tearing down" >&2
exit "$rc"
