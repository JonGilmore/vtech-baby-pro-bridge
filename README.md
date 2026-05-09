# VTech Baby Pro Bridge

Native bridge that pulls live H.264 video from an RM series VTech Baby Pro camera without the official phone app, and serves it as RTSP/WebRTC/HLS for Frigate/Home Assistant/VLC.

The camera uses ThroughTek's TUTK/Kalay P2P with an X25519 + ChaCha20-Poly1305 auth/decrypt layer added by VTech on top of the SDK. We reimplement that layer in C, link against TUTK's bionic-only `.so` files via dlopen, and run the whole thing inside a bionic chroot on aarch64 Linux (Raspberry Pi 3B+ tested).

## Status: working end-to-end

- Real video at **1920×1080 @ 15 fps** decoded
- **LOCAL ONLY**
- Live in Frigate via go2rtc
- Containerized for ARM64 Linux

## Quick start

You'll need:

- A VTech Baby Pro camera already paired via the official app (so it has a UID + AV-channel password assigned). I used a `VTech RM5766` baby monitor.
- The camera's `xapk` from APKPure or a similar source (used to extract the TUTK license key — VTech-licensed, _not redistributed here_).
- A rooted Android phone with KernelSU (or any root that exposes `/sys/kernel/tracing`) and the VTech app installed. **Used once** to extract the license key + camera password via uprobe; not needed at runtime once you've captured them.
- An aarch64 Linux host on the camera's VLAN (Raspberry Pi 3B+ running Debian 13 tested). Must be on the same L2 segment as the camera — TUTK does UDP-broadcast discovery and broadcasts don't traverse routers.
- A laptop (macOS or Linux) for offset-computation, NDK cross-compile, and bionic-rootfs extraction.

### Prerequisites — packages to install

**On the laptop**

```bash
# macOS (Homebrew)
brew install --cask android-platform-tools     # adb
brew install --cask android-ndk                # cross-compile vtech_native
```

**On the aarch64 host (Pi) — required for the Docker path**

```bash
sudo apt-get update
sudo apt-get install -y docker.io
sudo systemctl is-active docker
sudo dpkg --verify docker.io
```

That gives you `docker`, `docker buildx` and the daemon. Verify with the usual hello-world test:

```bash
sudo docker run --rm hello-world
```

**Optional on the Pi (only for direct-chroot debugging without Docker):**

```bash
sudo apt-get install -y dnsmasq ffmpeg
# dnsmasq is required so bionic's resolver inside the chroot reaches a
# DNS server on 127.0.0.1:53. The Docker image bundles its own.
# ffmpeg is just for sanity-checking the H.264 output locally.
```

```bash
# 1) Clone the repo on your host
git clone https://github.com/JonGilmore/vtech-baby-pro-bridge.git
cd vtech-baby-pro-bridge

# 2) Extract your TUTK license key from your VTech APK at runtime.
#    The key is decrypted by DexGuard's reflection chain at runtime — too
#    obfuscated for static decryption — so we hook the SDK call that
#    receives it via a kernel uprobe (bypasses every DexGuard layer,
#    including Frida/Xposed/ZygiskFrida — none of which work against this
#    app). Requires a rooted Android phone with KernelSU (or equivalent
#    root exposing /sys/kernel/tracing) and the VTech app installed.

# 2a) Compute the uprobe offset for your APK on your laptop. The .xapk is
#     just a zip of the base APK plus per-arch / per-locale splits. The
#     license-key SDK call lives in the arm64_v8a split. The offset is
#     version-specific.
unzip "MyVTechBabyPro.xapk" -d xapk/
python3 extract_license_offsets.py xapk/config.arm64_v8a.apk
#     → prints something like 0x2033cc; you'll paste it into the next step.

# 2b) Push the on-device script and run it. It registers the uprobe,
#     restarts the VTech app, captures TUTK_SDK_Set_License_Key's first
#     arg (the license-key C string), tears the probe back down, and
#     prints the key on stdout.
adb push extract_license_key.sh /data/local/tmp/
adb shell su -c '/data/local/tmp/extract_license_key.sh $(pm path com.cams.vtech.mvb.pro | grep arm64_v8a | sed s/^package://) 0x2033cc' > LICENSE_KEY.txt
#     stdout (the key) → LICENSE_KEY.txt; stderr (progress messages)
#     prints to your terminal so you can see what's happening.

# 2c) Extract your camera's AV-channel password the same way. Different
#     lib (libAVAPIs.so) and symbol (avClientStartEx); the probe reads
#     the password char* at offset 0x18 of the first-arg input struct.
#     Unlike the license key (set at app init), the password isn't sent
#     until you actually open the camera live view — so step 2d will
#     pause until you do that on the phone.
#     See FINDINGS.md "Camera AV Channel Password" for the full
#     offset-math walkthrough.
python3 extract_password_offsets.py xapk/config.arm64_v8a.apk
#     → prints something like 0x1fc18.

# 2d) Push and run. Then on your phone, open the VTech app and tap your
#     camera's tile to start live view — that triggers avClientStartEx
#     and the probe fires.
adb push extract_password.sh /data/local/tmp/
adb shell su -c '/data/local/tmp/extract_password.sh $(pm path com.cams.vtech.mvb.pro | grep arm64_v8a | sed s/^package://) 0x1fc18' | tee /tmp/vtech_password.txt
#     The captured password is on the last line; paste it into .env in
#     the next step.

# 2e) Extract your camera's TUTK UID. You can also just read it off the
#     camera-info screen in the VTech app — but the uprobe path is
#     consistent with 2a-2d and gives you ground truth for what the SDK
#     actually sees. Hooks IOTC_Connect_ByUID_Parallel; first arg is the
#     UID C-string. Same trigger as 2d (open camera live view). Skip
#     this step if you already have the UID (it's hardware-derived and
#     usually doesn't change when you re-pair on a different network).
python3 extract_uid_offsets.py xapk/config.arm64_v8a.apk
#     → prints something like 0x5fc74.

adb push extract_uid.sh /data/local/tmp/
adb shell su -c '/data/local/tmp/extract_uid.sh $(pm path com.cams.vtech.mvb.pro | grep arm64_v8a | sed s/^package://) 0x5fc74' | tee /tmp/vtech_uid.txt
#     The UID is on the last line; paste it into .env in the next step.

# 2f) Extract the TUTK SDK shared libraries from the APK. The bridge
#     dlopens these at runtime; we don't redistribute them (proprietary
#     ThroughTek code) — you have to pull them from your own APK. They
#     live inside config.arm64_v8a.apk (Android per-arch splits are
#     plain zip files), under lib/arm64-v8a/.
mkdir -p device_apk_libs
unzip -j -o xapk/config.arm64_v8a.apk \
    "lib/arm64-v8a/libTUTKGlobalAPIs.so" \
    "lib/arm64-v8a/libIOTCAPIs.so" \
    "lib/arm64-v8a/libAVAPIs.so" \
    "lib/arm64-v8a/libsodium.so" \
    -d device_apk_libs/
ls -la device_apk_libs/
#     You should see four .so files. `bridge/docker/build-context.sh`
#     copies them into the chroot at /data/local/tmp/ where the bridge
#     dlopens them.

# 3) Configure your camera credentials (see .env.example for fields)
cp .env.example .env
$EDITOR .env

# 4) Cross-compile the bridge binary AND extract the bionic-rootfs from
#    your phone. Both happen on your laptop with the rooted Android phone
#    connected via adb.
#
# 4a) Cross-compile vtech_native with the Android NDK (macOS path shown;
#     adjust for your NDK install location).
NDK=/opt/homebrew/Caskroom/android-ndk/29/AndroidNDK14206865.app/Contents/NDK
$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android24-clang -O2 -Wall -o bridge/vtech_native bridge/vtech_native.c -ldl
file bridge/vtech_native    # → ELF 64-bit ... interpreter /system/bin/linker64

# 4b) Extract the bionic-rootfs from the phone. The `-h` (--dereference)
#     flag is critical: Android 10+ uses absolute-path symlinks like
#     /system/bin/linker64 → /apex/com.android.runtime/bin/linker64 and
#     /apex/com.android.runtime/lib64/libc++.so → /system/lib64/libc++.so.
#     Without -h the tarball ends up full of dangling symlinks that break
#     the Docker build.
mkdir -p /tmp/bionic-rootfs
adb exec-out su -c "tar -hcf - \
    /apex/com.android.runtime \
    /system/lib64/libnetd_client.so /system/lib64/libutils.so \
    /system/lib64/libcutils.so /system/lib64/libbase.so /system/lib64/liblog.so \
    /system/bin/linker64 \
    2>/dev/null" \
  | tar -xf - -C /tmp/bionic-rootfs/

mkdir -p /tmp/bionic-rootfs/{proc,sys,dev,data/local/tmp,system/etc,etc}
tar -czf /tmp/bionic-rootfs.tar.gz -C /tmp bionic-rootfs

# 4c) rsync the whole working tree to the Pi. This includes the Docker
#     build context (bridge/docker/), the freshly built bridge binary,
#     the extracted SDK libs, your .env, your LICENSE_KEY.txt — i.e.
#     everything step 5+ on the Pi will need. Excluded: the .git dir,
#     the original .xapk/.apk files (huge, not needed on Pi), and the
#     archive/ tree.
PI=root@<pi-ip>
rsync -av \
    --exclude '.git' \
    --exclude 'archive' \
    --exclude 'anonymous_vdex' \
    --exclude 'xapk/' \
    --exclude '*.xapk' \
    --exclude '*.apk' \
    ./ "$PI:vtech-baby-pro-bridge/"

# Plus the bionic-rootfs tarball, which lives under /tmp/ (not in the repo)
# Stash the bionic-rootfs tarball under $HOME on the Pi (NOT /tmp, which
# is tmpfs on most distros and clears on reboot — losing the tarball
# silently breaks build-context.sh's next run).
rsync -av /tmp/bionic-rootfs.tar.gz "$PI:bionic-rootfs.tar.gz"

# 5) On the Pi: assemble build context, build the image, run the container.
cd ~/vtech-baby-pro-bridge/bridge/docker
ROOTFS_TARBALL=~/bionic-rootfs.tar.gz ./build-context.sh
docker build -t vtech-bridge:latest .

# 6) Source .env, then docker run with bind-mounted license-key file.
set -a; . ~/vtech-baby-pro-bridge/.env; set +a
docker rm -f vtech-bridge 2>/dev/null
docker run -d --name vtech-bridge \
    --restart unless-stopped --network host \
    --cap-add SYS_ADMIN --cap-add SYS_CHROOT \
    -e VTECH_UID="$VTECH_UID" \
    -e VTECH_PASSWORD="$VTECH_PASSWORD" \
    -v ~/vtech-baby-pro-bridge/LICENSE_KEY.txt:/chroot/data/local/tmp/LICENSE_KEY.txt:ro \
    vtech-bridge:latest

# 7) Verify the stream
docker exec vtech-bridge ffprobe rtsp://localhost:8554/vtech_baby 2>&1 | grep -E 'codec_name|width|height|r_frame_rate' #   → codec_name=h264  width=1280 (or 1920)  height=720 (or 1080)  r_frame_rate=15/1

# RTSP feed (point Frigate / VLC / go2rtc viewer at this):
#   rtsp://<pi-ip>:8554/vtech_baby
# WebRTC viewer:
#   http://<pi-ip>:1984/stream.html?src=vtech_baby
```

## Layout

| Path                                                         | What it is                                                                                                                        |
| ------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| [`bridge/`](bridge/)                                         | Production code — bridge source, Docker setup, README                                                                             |
| [`extract_license_offsets.py`](extract_license_offsets.py)   | Computes the kernel-uprobe offset for `TUTK_SDK_Set_License_Key` from your VTech APK. Run on your laptop.                         |
| [`extract_license_key.sh`](extract_license_key.sh)           | Runs on a rooted Android device. Installs the uprobe, restarts the app, prints the captured license key.                          |
| [`extract_password_offsets.py`](extract_password_offsets.py) | Same machinery, different lib + symbol — computes the offset for `avClientStartEx` to capture the per-camera AV-channel password. |
| [`extract_password.sh`](extract_password.sh)                 | Runs on a rooted Android device. Hooks `avClientStartEx`, waits for you to open the camera live view, prints the password.        |
| [`extract_uid_offsets.py`](extract_uid_offsets.py)           | Computes the offset for `IOTC_Connect_ByUID_Parallel` to capture the camera's TUTK UID. Useful if the camera-info screen in the app isn't accessible or you want ground-truth from the SDK. |
| [`extract_uid.sh`](extract_uid.sh)                           | Runs on a rooted Android device. Hooks `IOTC_Connect_ByUID_Parallel`, prints the UID. Same camera-live-view trigger as the password extractor. |
| [`.env.example`](.env.example)                               | Template for camera UID / password / license-key path. Copy to `.env` and fill in.                                                |

## Notes on the camera password

The VTech onboarding flow generates a per-camera AV-channel password (8 chars, mixed case + digits) during pairing — it is NOT the WiFi password or the parent-unit password. The cleanest way to retrieve it is the kernel-uprobe extractor in step 2c/2d above

## AI Disclaimer

AI was heavily used during the reverse engineering of the VTech APK.
