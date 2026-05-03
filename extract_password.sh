#!/system/bin/sh
# extract_password.sh — runtime-extract the camera AV-channel password
# from the VTech app via kernel uprobe on TUTK's avClientStartEx.
#
# How it works:
#   - avClientStartEx(in_struct, out_struct) takes a struct pointer in x0.
#   - Offset 0x18 of that struct is `password_or_token` (a char*).
#   - We register a uprobe that follows that pointer and reads the
#     NUL-terminated string at it: pwd=+0(+0x18(%x0)):string
#   - The probe fires when the official VTech app opens the camera live
#     view (it calls avClientStartEx via JNI from Camera.startListening()).
#
# Requires:
#   - Rooted Android with tracefs (KernelSU tested; CONFIG_UPROBE_EVENTS=y)
#   - The VTech Baby Pro app installed and the camera already paired
#   - Root (su)
#
# Usage:
#   extract_password.sh [apk_path] <probe_offset_hex>
#
#   <apk_path>          path to the split APK that contains
#                       libAVAPIs.so on this device. Auto-detected via
#                       `pm path` if omitted.
#   <probe_offset_hex>  combined offset (lib-in-apk + symbol-in-lib)
#                       computed by extract_password_offsets.py on your
#                       laptop.
#
# Outputs the password string on stdout. Copy into your `.env` as
# VTECH_PASSWORD=...

set -e

PKG=com.cams.vtech.mvb.pro
TRACE=/sys/kernel/tracing
PROBE=get_password

case "$#" in
    1) APK=$(pm path "$PKG" 2>/dev/null | grep arm64_v8a | head -1 | sed 's/^package://')
       OFF="$1"
       ;;
    2) APK="$1"; OFF="$2" ;;
    *) echo "usage: $0 [apk_path] <probe_offset_hex>" >&2; exit 1 ;;
esac

if [ -z "$APK" ]; then
    echo "ERROR: could not locate the arm64_v8a split APK for $PKG" >&2
    exit 2
fi
if [ ! -f "$APK" ]; then
    echo "ERROR: APK not found at: $APK" >&2
    exit 2
fi
if [ ! -d "$TRACE/events/uprobes" ]; then
    echo "ERROR: $TRACE/events/uprobes missing — kernel needs CONFIG_UPROBE_EVENTS=y" >&2
    exit 2
fi

cleanup() {
    echo 0 > "$TRACE/events/uprobes/$PROBE/enable" 2>/dev/null || true
    echo "-:$PROBE" >> "$TRACE/uprobe_events" 2>/dev/null || true
}
trap cleanup EXIT

echo "# uprobe target: $APK at $OFF (avClientStartEx)" >&2

# Wipe any stale probe with our name.
echo "-:$PROBE" >> "$TRACE/uprobe_events" 2>/dev/null || true

# Register: read 8 bytes at x0+0x18 (= struct->password_or_token), follow
# that pointer, read the NUL-terminated string.
echo "p:$PROBE $APK:$OFF pwd=+0(+0x18(%x0)):string" >> "$TRACE/uprobe_events"

if [ ! -f "$TRACE/events/uprobes/$PROBE/enable" ]; then
    echo "ERROR: kernel did not register the probe." >&2
    echo "       Common causes: bad offset, APK path unreadable by tracer," >&2
    echo "                      or this kernel lacks uprobe support." >&2
    echo "       Current uprobe_events contents:" >&2
    cat "$TRACE/uprobe_events" >&2
    exit 4
fi

echo 1 > "$TRACE/events/uprobes/$PROBE/enable"
echo > "$TRACE/trace"

# Force-stop the app so the user starts from a clean state, then tell
# them to open the camera. We can't auto-tap "view camera" — depends on
# UI state, login session, camera pairing.
am force-stop "$PKG" 2>/dev/null || true

cat >&2 <<EOF
# Probe armed. NOW: on your phone, open the VTech app and tap your
# camera's tile to start the live view. The probe will fire as soon as
# the app calls avClientStartEx. Waiting up to 120s ...
EOF

i=0
while [ "$i" -lt 120 ]; do
    if grep -q "$PROBE" "$TRACE/trace" 2>/dev/null; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

PWD_VAL=$(grep "$PROBE" "$TRACE/trace" | head -1 | sed -nE 's/.*pwd="([^"]*)".*/\1/p')

if [ -z "$PWD_VAL" ]; then
    echo "ERROR: probe did not fire within 120s." >&2
    echo "       Did you open the camera live view in the app?" >&2
    echo "       If you did and still nothing fired, double-check the offset" >&2
    echo "       came from the same APK version that's installed on the device." >&2
    echo "Last 20 lines of trace buffer:" >&2
    tail -20 "$TRACE/trace" >&2
    exit 3
fi

echo "$PWD_VAL"
