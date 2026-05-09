#!/bin/bash
# Assemble the docker build context for vtech-bridge from this repo's existing
# artifacts. Run this on the host where you've already extracted the bionic
# rootfs and built the bridge binary (your dev Mac or the Pi).
#
# Inputs (all already exist after Phase 1/2):
#   ../device_apk_libs/lib{TUTKGlobalAPIs,IOTCAPIs,AVAPIs,sodium}.so   (patched)
#   ../bridge/vtech_native                                              (NDK-built)
#   ../bridge/libdnsfix.so                                              (optional)
#   ~/bionic-rootfs.tar.gz      OR   ~/bionic-rootfs/        (the chroot tree;
#                                                              we avoid /tmp by
#                                                              default since
#                                                              tmpfs clears on
#                                                              reboot)
#
# Output:
#   ./rootfs/   - the chroot tree, ready to COPY into the image
#   (the rest - Dockerfile, scripts, configs - is already in this directory)
set -euo pipefail

cd "$(dirname "$0")"

REPO=$(cd ../..; pwd)
ROOTFS_TARBALL=${ROOTFS_TARBALL:-$HOME/bionic-rootfs.tar.gz}
ROOTFS_DIR=${ROOTFS_DIR:-$HOME/bionic-rootfs}

# 1. Lay down the chroot tree from either a tarball or an existing directory
echo "[build-context] preparing rootfs/"
rm -rf rootfs
mkdir -p rootfs
if [ -f "$ROOTFS_TARBALL" ]; then
    echo "  using tarball: $ROOTFS_TARBALL"
    tar -C rootfs --strip-components=1 -xzf "$ROOTFS_TARBALL"
elif [ -d "$ROOTFS_DIR" ]; then
    echo "  using directory: $ROOTFS_DIR (skipping bind-mounted /proc /sys /dev)"
    # `tar` with --exclude is the cleanest way to skip bind-mounted dirs
    # without unmounting them. We then make empty mountpoints below.
    ( cd "$ROOTFS_DIR" && tar -cf - \
            --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
            . ) | tar -C rootfs -xf -
else
    echo "ERROR: need either ROOTFS_TARBALL ($ROOTFS_TARBALL) or ROOTFS_DIR ($ROOTFS_DIR)"
    exit 1
fi

# Always make sure /proc /sys /dev exist as empty dirs (mountpoints inside container)
mkdir -p rootfs/proc rootfs/sys rootfs/dev

# 2. Make sure the bridge binary + SDK libs in rootfs/data/local/tmp/ are the
#    latest from the repo (in case rootfs was assembled long ago)
echo "[build-context] refreshing /data/local/tmp/ contents"
mkdir -p rootfs/data/local/tmp
cp "$REPO/bridge/vtech_native" rootfs/data/local/tmp/

for lib in libTUTKGlobalAPIs libIOTCAPIs libAVAPIs; do
    if [ -f "$REPO/device_apk_libs/${lib}.so" ]; then
        cp "$REPO/device_apk_libs/${lib}.so" "rootfs/data/local/tmp/${lib}.so"
    fi
done
[ -f "$REPO/device_apk_libs/libsodium.so" ] && cp "$REPO/device_apk_libs/libsodium.so" rootfs/data/local/tmp/
[ -f "$REPO/bridge/libdnsfix.so" ]          && cp "$REPO/bridge/libdnsfix.so"          rootfs/data/local/tmp/

chmod +x rootfs/data/local/tmp/vtech_native

# 2.5 Replace any dangling symlinks in /system/bin/ and /system/lib64/
#     with concrete files. On Android 10+, /system/bin/linker64 is a
#     symlink to /apex/com.android.runtime/bin/linker64; chmod inside
#     the Docker build can't follow that absolute path because we're
#     outside the chroot. Resolve them now while the rootfs is still
#     on the host filesystem and we can read both ends of each link.
echo "[build-context] resolving dangling symlinks under /system/"
for link in rootfs/system/bin/linker64 rootfs/system/bin/linker; do
    [ -L "$link" ] || continue
    target=$(readlink "$link")
    case "$target" in
        /*) src="rootfs$target" ;;
        *)  src="$(dirname "$link")/$target" ;;
    esac
    if [ -e "$src" ]; then
        echo "  $link -> $src (replacing symlink with concrete file)"
        rm -f "$link"
        cp "$src" "$link"
    else
        echo "  WARNING: $link points at $src but source is missing"
    fi
done

# 3. Make sure /system/etc/resolv.conf exists (bionic resolver fallback)
mkdir -p rootfs/system/etc rootfs/etc
cat > rootfs/system/etc/resolv.conf << 'EOF'
nameserver 127.0.0.1
EOF
cp rootfs/system/etc/resolv.conf rootfs/etc/resolv.conf

# 4. Hardlink/copy bionic libs into /system/lib64 (bionic linker's hardcoded
#    fallback path). We use cp -L (dereference) to avoid symlink-target
#    resolution issues inside the chroot.
#
#    The unpacked rootfs may already contain dangling symlinks under
#    /system/lib64/ (e.g. libclang_rt.hwasan-aarch64-android.so points at
#    a phone-side path that we didn't tar). cp -f refuses to write
#    *through* a dangling destination symlink, so rm -f the dest first.
#    `[ -e "$f" ]` skips dangling source symlinks via the same logic.
echo "[build-context] populating /system/lib64 with bionic libs"
mkdir -p rootfs/system/lib64
for f in rootfs/apex/com.android.runtime/lib64/bionic/*.so; do
    [ -e "$f" ] || continue
    name=$(basename "$f")
    rm -f "rootfs/system/lib64/$name"
    cp -f "$f" "rootfs/system/lib64/$name"
done
# libstdc++ → libc++ (NDK STL alias).
#
# NDK-compiled binaries link against libstdc++.so but on Android that's
# just an alias for libc++.so (which IS in the apex). Different Android
# versions ship libc++.so at different paths, so look in all three
# common locations.
LIBCXX=""
for cand in \
    rootfs/system/lib64/libc++.so \
    rootfs/apex/com.android.runtime/lib64/libc++.so \
    rootfs/apex/com.android.runtime/lib64/bionic/libc++.so; do
    if [ -e "$cand" ]; then
        LIBCXX="$cand"
        break
    fi
done
if [ -n "$LIBCXX" ]; then
    echo "[build-context] aliasing $LIBCXX as /system/lib64/libstdc++.so"
    rm -f rootfs/system/lib64/libstdc++.so rootfs/system/lib64/libc++.so
    cp -f "$LIBCXX" rootfs/system/lib64/libstdc++.so
    cp -f "$LIBCXX" rootfs/system/lib64/libc++.so
else
    echo "[build-context] WARNING: libc++.so not found anywhere in rootfs;"
    echo "                bridge dlopen of libTUTKGlobalAPIs.so will fail."
    echo "                Check that your phone's bionic-rootfs extraction"
    echo "                included libc++.so."
fi

# 5. Show what we've assembled
echo "[build-context] context size:"
du -sh rootfs/
echo "[build-context] /data/local/tmp/:"
ls -la rootfs/data/local/tmp/

cat << 'EOF'

[build-context] done. Next (assumes you're on aarch64 — for cross-arch
                builds add `docker buildx build --platform linux/arm64`):

   docker build -t vtech-bridge:latest .

   set -a; . ../../.env; set +a
   docker rm -f vtech-bridge 2>/dev/null
   docker run -d --name vtech-bridge \
       --restart unless-stopped --network host \
       --cap-add SYS_ADMIN --cap-add SYS_CHROOT \
       -e VTECH_UID="$VTECH_UID" \
       -e VTECH_PASSWORD="$VTECH_PASSWORD" \
       -v "$(realpath ../../LICENSE_KEY.txt):/chroot/data/local/tmp/LICENSE_KEY.txt:ro" \
       vtech-bridge:latest

   docker logs -f vtech-bridge

EOF
