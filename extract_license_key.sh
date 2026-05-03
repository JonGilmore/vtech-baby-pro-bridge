#!/system/bin/sh
# extract_license_key.sh — runtime-extract the TUTK SDK license key from a
# running VTech app via kernel uprobe. Bypasses every layer of DexGuard
# anti-tamper since kernel breakpoints are invisible to userspace.
#
# Requires:
#   - Rooted Android with tracefs (KernelSU tested; Magisk OK if tracefs is
#     exposed and the kernel has CONFIG_UPROBE_EVENTS=y)
#   - The VTech Baby Pro app installed
#   - Root (su)
#
# Usage:
#   extract_license_key.sh [apk_path] <probe_offset_hex>
#
#   <apk_path>          path to the split APK that contains
#                       libTUTKGlobalAPIs.so on this device. If omitted,
#                       auto-detected via `pm path`. Find manually with:
#                         pm path com.cams.vtech.mvb.pro | grep arm64_v8a
#   <probe_offset_hex>  combined offset (lib-in-apk + symbol-in-lib).
#                       Compute on your laptop with extract_license_offsets.py
#                       given the same split APK.
#
# Outputs the license-key string on stdout. Copy into LICENSE_KEY.txt.

set -e

PKG=com.cams.vtech.mvb.pro
TRACE=/sys/kernel/tracing
PROBE=set_license

case "$#" in
    1) APK=$(pm path "$PKG" 2>/dev/null | grep arm64_v8a | head -1 | sed 's/^package://')
       OFF="$1"
       ;;
    2) APK="$1"; OFF="$2" ;;
    *) echo "usage: $0 [apk_path] <probe_offset_hex>" >&2; exit 1 ;;
esac

if [ -z "$APK" ]; then
    echo "ERROR: could not locate the arm64_v8a split APK for $PKG" >&2
    echo "       check 'pm path $PKG' output, then pass the path explicitly" >&2
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
    # Remove our probe entry — uprobe_events takes append-style writes.
    echo "-:$PROBE" >> "$TRACE/uprobe_events" 2>/dev/null || true
}
trap cleanup EXIT

echo "# uprobe target: $APK at $OFF" >&2

# Wipe any stale probe with our name (e.g. left over from a prior crashed run).
# Failures here are expected if no such probe exists.
echo "-:$PROBE" >> "$TRACE/uprobe_events" 2>/dev/null || true

# Register the probe via APPEND (>) is rejected on some kernels with EBUSY).
echo "p:$PROBE $APK:$OFF license=+0(%x0):string" >> "$TRACE/uprobe_events"

# Confirm the probe was actually registered before trying to enable it.
if [ ! -f "$TRACE/events/uprobes/$PROBE/enable" ]; then
    echo "ERROR: kernel did not register the probe." >&2
    echo "       Common causes: bad offset, APK path unreadable by tracer," >&2
    echo "                      or this kernel lacks uprobe support for binfmt." >&2
    echo "       Current uprobe_events contents:" >&2
    cat "$TRACE/uprobe_events" >&2
    exit 4
fi

echo 1 > "$TRACE/events/uprobes/$PROBE/enable"
echo > "$TRACE/trace"

echo "# restarting $PKG so the JNI wrapper calls TUTK_SDK_Set_License_Key ..." >&2
am force-stop "$PKG" 2>/dev/null || true
sleep 1
monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true

echo "# waiting up to 30s for probe to fire ..." >&2
i=0
while [ "$i" -lt 30 ]; do
    if grep -q "$PROBE" "$TRACE/trace" 2>/dev/null; then
        break
    fi
    sleep 1
    i=$((i + 1))
done

KEY=$(grep "$PROBE" "$TRACE/trace" | head -1 | sed -nE 's/.*license="([^"]*)".*/\1/p')

if [ -z "$KEY" ]; then
    echo "ERROR: probe did not fire within 30s." >&2
    echo "       Verify the offset is correct and the app actually started:" >&2
    echo "       'dumpsys activity | grep $PKG' should show the app's process" >&2
    echo "       Also check that $APK is the same split APK you computed the offset from." >&2
    echo "Last 20 lines of trace buffer:" >&2
    tail -20 "$TRACE/trace" >&2
    exit 3
fi

echo "$KEY"
