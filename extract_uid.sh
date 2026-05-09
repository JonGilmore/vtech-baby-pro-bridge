#!/system/bin/sh
# extract_uid.sh — runtime-extract the camera's TUTK UID from the VTech
# app via kernel uprobe on IOTC_Connect_ByUID_Parallel.
#
# How it works:
#   - IOTC_Connect_ByUID_Parallel(const char *uid, int sid) takes the UID
#     C-string in x0.
#   - We register a uprobe that reads the NUL-terminated string at that
#     pointer: uid=+0(%x0):string
#   - The probe fires when the official VTech app opens a TUTK session
#     to the camera (i.e., when you tap the camera tile to start live view).
#
# Requires:
#   - Rooted Android with tracefs (KernelSU tested; CONFIG_UPROBE_EVENTS=y)
#   - The VTech Baby Pro app installed and the camera already paired
#   - Root (su)
#
# Usage:
#   extract_uid.sh [apk_path] <probe_offset_hex>
#
#   <apk_path>          path to the split APK that contains
#                       libIOTCAPIs.so on this device. Auto-detected via
#                       `pm path` if omitted.
#   <probe_offset_hex>  combined offset (lib-in-apk + symbol-in-lib)
#                       computed by extract_uid_offsets.py on your laptop.
#
# Outputs the UID string on stdout. Copy into your `.env` as
# VTECH_UID=...

set -e

PKG=com.cams.vtech.mvb.pro
TRACE=/sys/kernel/tracing
PROBE=get_uid

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

echo "# uprobe target: $APK at $OFF (IOTC_Connect_ByUID_Parallel)" >&2

# Wipe any stale probe with our name.
echo "-:$PROBE" >> "$TRACE/uprobe_events" 2>/dev/null || true

# Register: read NUL-terminated string at the address in x0 (the UID C-string).
echo "p:$PROBE $APK:$OFF uid=+0(%x0):string" >> "$TRACE/uprobe_events"

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

am force-stop "$PKG" 2>/dev/null || true

cat >&2 <<EOF
# Probe armed. NOW: on your phone, open the VTech app and tap your
# camera's tile to start the live view. The probe will fire as soon
# as the app calls IOTC_Connect_ByUID_Parallel. Waiting up to 120s ...
EOF

i=0
while [ "$i" -lt 120 ]; do
    if grep -q "$PROBE" "$TRACE/trace" 2>/dev/null; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

UID_VAL=$(grep "$PROBE" "$TRACE/trace" | head -1 | sed -nE 's/.*uid="([^"]*)".*/\1/p')

if [ -z "$UID_VAL" ]; then
    echo "ERROR: probe did not fire within 120s." >&2
    echo "       Did you open the camera live view in the app?" >&2
    echo "Last 20 lines of trace buffer:" >&2
    tail -20 "$TRACE/trace" >&2
    exit 3
fi

echo "$UID_VAL"
