#!/usr/bin/env bash
# graft.sh — build a Kali Linux arm64 SD-card image for the M5Stack Cardputer Zero.
#
# Everything is assembled from public, pinned, checksum-verified sources — no
# OEM "donor" image is needed any more:
#
#   base      Kali's official Raspberry Pi arm64 image (kali.download)
#   kernel    stock Raspberry Pi 6.18.39+rpt-rpi-v8 .debs (archive.raspberrypi.com),
#             the exact set M5's own image build pins (CardputerZero/pi-gen)
#   drivers   m5stack/m5stack-linux-dtoverlays, built from source in the image
#             (LCD panel, keypad, audio, battery gauge, IMU, IO expander, overlays)
#   firmware  Raspberry Pi's firmware-brcm80211 (CM0-correct BCM43439 NVRAM)
#   apps      CardputerZero/launcher (APPLaunch) + first-party app .debs (GitHub releases)
#
# Stages (run any subset; default is "all"):
#   check      verify host tooling
#   fetch      download + sha256-verify every pinned input into cache/
#   unxz       decompress the Kali base .xz (skip if the .img already exists)
#   resize     grow the Kali rootfs by $GROW_GB (skip if already grown)
#   mount      loop-attach + mount the Kali image
#   kernel     install the pinned RPi kernel + CM0 WiFi firmware (chroot)
#   drivers    build + install the Cardputer Zero drivers/overlays (chroot)
#   boot       write config.txt / cmdline.txt / splash
#   configs    static configs (glycin, X input, lightdm, consoles, audio, …)
#   packages   desktop stack, kali user/groups, Realtek USB WiFi DKMS (chroot)
#   apps       APPLaunch + first-party apps (chroot, real apt install) + Camera libcamera
#   tweaks     NetworkManager, hostname + /etc/hosts, first-boot resize
#   verify     sanity-check the result
#   flash      write the image to FLASH_DEV (e.g. FLASH_DEV=/dev/sdc)
#   deploy-ssh drop a pubkey onto a flashed card (DEPLOY_SSH_DEV=/dev/sdX)
#   drift      compare our pins against upstream's latest releases
#   shell      mount everything + interactive bash
#   fresh      delete the output .img so the next run starts from the .xz
#
# Examples:
#   sudo ./graft.sh                                   # full build
#   sudo FLASH_DEV=/dev/sdc ./graft.sh flash          # write it to a card
#   sudo DEPLOY_SSH_DEV=/dev/sdc ./graft.sh deploy-ssh
#   sudo ./graft.sh configs verify                    # iterate on configs only

set -euo pipefail

# ─── Paths & defaults ────────────────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CACHE="${CACHE:-$SCRIPT_DIR/cache}"

# Kali base image. Bump KALI_VER + KALI_SHA256 together
# (https://kali.download/arm-images/kali-<ver>/SHA256SUMS).
KALI_VER="${KALI_VER:-2026.3}"
KALI_XZ_NAME="kali-linux-${KALI_VER}-raspberry-pi-arm64.img.xz"
KALI_URL="${KALI_URL:-https://kali.download/arm-images/kali-${KALI_VER}/${KALI_XZ_NAME}}"
KALI_SHA256="${KALI_SHA256:-85906ae2758c9cc969553579161ff80bbac1130701b24bc375e6100b73ee4843}"
KALI_XZ="${KALI_XZ:-$SCRIPT_DIR/$KALI_XZ_NAME}"
OUT_IMG="${OUT_IMG:-${KALI_XZ%.xz}}"

# Kernel: the Raspberry Pi kernel M5 tests the Cardputer Zero against. Same
# version + sha256 set as CardputerZero/pi-gen stage0/02-firmware/files/
# kernel-packages.sha256 (v8 flavour only — the CM0 is a Pi Zero 2 class SoC).
# Old versions stay in the RPi pool after the index moves on, so the pins keep
# resolving. To bump: copy the new manifest from pi-gen, then rebuild drivers.
KVER="${KVER:-6.18.39+rpt-rpi-v8}"
RPI_POOL="https://archive.raspberrypi.com/debian/pool/main"
KERNEL_DEBS="
l/linux/linux-base-6.18.39+rpt-rpi-v8_6.18.39-1+rpt1_arm64.deb|cead9306c9f655af09cb5517477113406b070e26e55f167704e6ba45e4582370
l/linux/linux-base-rpi-v8_6.18.39-1+rpt1_arm64.deb|cde690792efd906ce1c3fac9a2c4e82d79a654704ccce65da25db9688b25206f
l/linux/linux-headers-6.18.39+rpt-common-rpi_6.18.39-1+rpt1_all.deb|5904d2c6a3e8fafe75ce3d53d86220b8057290d86cb95a96ad787a6900f4b344
l/linux/linux-headers-6.18.39+rpt-rpi-v8_6.18.39-1+rpt1_arm64.deb|e5e5619d9d048dd43ec5db90a09aeb563596a7b1c4d2bbeeae3f69cec1301813
l/linux/linux-headers-rpi-v8_6.18.39-1+rpt1_arm64.deb|9c2a7f10a09f24d4dd1fcacbf1e12d8eb00342a86d989e2d75090bd35f3cb149
l/linux/linux-image-6.18.39+rpt-rpi-v8_6.18.39-1+rpt1_arm64.deb|b007b959f853ca4d26c53d42d166ca7e8619a31f885d52b334c4cab557965265
l/linux/linux-image-rpi-v8_6.18.39-1+rpt1_arm64.deb|b46b50c6167f5cef33a5ecf7f5555daaa25551fa032d4c2cab2525da7dcd8406
l/linux/linux-kbuild-6.18.39+rpt_6.18.39-1+rpt1_arm64.deb|e3deb75129c67f0eafe5cec64eccc7ec4601890c25788487209fec1a3f605dad
"
KERNEL_HOLD_PKGS="linux-image-$KVER linux-image-rpi-v8 linux-headers-$KVER linux-headers-rpi-v8 linux-headers-${KVER%%+*}+rpt-common-rpi linux-kbuild-${KVER%%+*}+rpt linux-base-$KVER linux-base-rpi-v8"

# CM0 WiFi firmware. Kali's cyfmac43439-sdio.txt NVRAM has the wrong
# boardflags3 for this carrier; Raspberry Pi's package has the right one.
FW_BRCM_DEB="f/firmware-nonfree/firmware-brcm80211_20260519-1~bpo13+1+rpt1_all.deb|c25e13e84be8dbf58b6b3381b4a10ad7e9dbeae101579376f457e0f17e60d902"

# Drivers + overlays. 7551854 is the commit M5's current stable image
# (20260929-070146-5f4c44f) was built from — see `graft.sh drift`.
DTOVERLAYS_REPO="${DTOVERLAYS_REPO:-https://github.com/m5stack/m5stack-linux-dtoverlays.git}"
DTOVERLAYS_COMMIT="${DTOVERLAYS_COMMIT:-75518549a2640486f5d13ea72ca4935b198d7c20}"

# Small assets from M5's image build: LCD boot splash + LCD→HDMI mirror tool.
PIGEN_COMMIT="791a985d4efca7327ae1fdb6c48230ac0d1ee1bc"
PIGEN_RAW="https://raw.githubusercontent.com/CardputerZero/pi-gen/$PIGEN_COMMIT/stage2/05-cardputerzero/files"
PIGEN_ASSETS="
splash.bmp|21466ad04871484b878dc18b409a61ba97e5e08880a0e48f35f3f7420a270091
fb-mirror.py|f10e719380975375ea9cbf0ae118ca575495e884d1442e521bae354697f5f833
fb-mirror.desktop|6ddf944f334f2a3211dfffee4b053411c9c9848a31f3467141924c663adf76a9
"

# APPLaunch + first-party apps — the set M5's image installs (pi-gen
# stage2/05-cardputerzero/0[23]-run.sh), minus FactoryTest (hard-depends on
# Raspberry Pi's patched libcamera; it's a factory QA tool anyway).
# Format: slug|url|sha256. Pin + bump deliberately.
CZ_DEBS="
launcher|https://github.com/CardputerZero/launcher/releases/download/launcher-v0.6.105/applaunch_0.6.105-m5stack1_arm64.deb|a38cffde9cb4d60f4ff2d6c95323c64f66cc705fdf315b0550e123ca7b5a9544
camera|https://github.com/CardputerZero/Camera/releases/download/v1.0.3/Camera_1.0.3_m5stack1_arm64.deb|1f0f0394d3d850762db840ae4c0f3fc242c55b1eb8c8367fba0f8daa39f94330
music|https://github.com/CardputerZero/Music/releases/download/v1.0.0/m5cardputerzero-music_0.1.7_m5stack1_arm64.deb|32f3a9e55ad9b3304d6cd64da0386b9cbc57cd2a318d32cf382e1187329b1146
piano|https://github.com/CardputerZero/Piano/releases/download/v1.0.0/m5cardputerzero-piano_0.1.1_m5stack1_arm64.deb|5d33167dda81648ca6e6b631fc5584b88e016f7b32dedb107adc1a193cb5f89f
compass|https://github.com/CardputerZero/Compass/releases/download/v1.0.0/m5cardputerzero-compass_0.2.4_m5stack1_arm64.deb|11ab1e4a0a1089dd48ae5c5c73248ea9d289b321c457bff225ae41c9529270bc
ir-chat|https://github.com/CardputerZero/IR-Chat/releases/download/v1.0.0/m5cardputerzero-ir-chat_0.1.3_m5stack1_arm64.deb|aa1ed146b088f6c9bb52c9328614b01e018cb8d9014ee083651ed404c64210cd
ir-remote|https://github.com/CardputerZero/IR-Remote/releases/download/v1.0.0/m5cardputerzero-ir-remote_0.1.4_m5stack1_arm64.deb|10be7020d2f2e3cd7cf0c5ede98443f8940efbfffb4aba801b87329409d67137
cap-cc1101-nfc|https://github.com/CardputerZero/Cap-CC1101-NFC/releases/download/v1.0.1/m5cardputerzero-cap-cc1101-nfc_1.0.1_m5stack1_arm64.deb|d779d4949741a6fd6d5f005c7e29efd768996ceeb39c187c8008548d9fdd8095
cap-cc1101-subg-chat|https://github.com/CardputerZero/Cap-CC1101-SubG-Chat/releases/download/v1.0.1/m5cardputerzero-cap-cc1101-subg-chat_1.0.1_m5stack1_arm64.deb|8ba26d9a513488673b5e8d9c3af5bc1ec6a04a4c3f859d256e420ee425e8c534
recorder|https://github.com/CardputerZero/Recorder/releases/download/v1.0.0/m5cardputerzero-recorder_0.1.8_m5stack1_arm64.deb|ed3fb90fbf84097138d0d30c11eaa132a4f8695ece4bec48ca2a1f8ea04727e7
files|https://github.com/CardputerZero/Files/releases/download/v1.0.2/m5cardputerzero-files_1.0.2_m5stack1_arm64.deb|6994a3f2b1152beb9cc734808103e7d59cb7c7b63856f95c836c401511b8c060
cap-lora-1262|https://github.com/CardputerZero/Cap-LoRa-1262/releases/download/v1.0.1/m5cardputerzero-cap-lora-1262_1.0.1_m5stack1_arm64.deb|5238fa7e20a5c63e8eb4e3ff38d6ee730c797e2afdeebfd18da200584ef84f5c
cap-lora-1262-gps|https://github.com/CardputerZero/Cap-LoRa-1262-GPS/releases/download/v1.0.0/m5cardputerzero-cap-lora-1262-gps_1.0.0_m5stack1_arm64.deb|4da7984c97effa75c36ee6d4fd93e0ee49f251781586d5dc4542b09b0b88eaa7
keyboard-guide|https://github.com/CardputerZero/Keyboard-Guide/releases/download/v1.0.1/m5cardputerzero-keyboard-guide_1.0.1_m5stack1_arm64.deb|d7fdc0aeb6b3a9b2c7c7450962ca1bf2211790fec488abc97235f052ded43c30
"
# Prereqs for the Cap-CC1101 pair: raspi-utils-core/-dt and their libs are
# not packaged by Kali at all. Taken from Raspberry Pi's pool directly (not a
# whole foreign apt source, which could later out-prioritise Kali packages).
# All four chains terminate in Debian packages Kali has (libc6, libfdt1).
CZ_PREREQ_DEBS="
raspi-utils-core|$RPI_POOL/r/raspi-utils/raspi-utils-core_20260626-1_arm64.deb|3df579a81d76081e283409840beb9b1df26a9487c50aef95293743a4ba689fb9
raspi-utils-dt|$RPI_POOL/r/raspi-utils/raspi-utils-dt_20260626-1_arm64.deb|068adfdf78097ca0429da2adac0f35769e217e8db20045c0090536e690b2d606
libgpiolib0|$RPI_POOL/r/raspi-utils/libgpiolib0_20260626-1_arm64.deb|594956f65e16d1fcbfd7b76046e11800ff12c0784936ed6fc3b792e707cee8f9
libdtovl0|$RPI_POOL/r/raspi-utils/libdtovl0_20260626-1_arm64.deb|4b81f914be83ca68cba2da4d8d4d70bdfe3ee9b3006b7e049e86c46d29968225
"

# Camera userspace. M5's CameraApp links Raspberry Pi's libcamera fork
# (0.7.2+rpt…, which exports Pi-only symbols such as
# properties::PixelArrayReadableArea); Kali's upstream libcamera 0.7.2 has the
# same soname but not those symbols, so the app dies at symbol lookup. Rather
# than overwrite Kali's libcamera, these are unpacked into a private tree
# (/opt/rpi-libcamera) that only camera_app sees, via a wrapper. boost 1.83
# and absl 20240722 come from Debian trixie because Kali has moved on to newer
# sonames; nothing here collides with a Kali library.
# Format: url|sha256.
DEBIAN_POOL="https://deb.debian.org/debian/pool/main"
CAMERA_DEBS="
$RPI_POOL/libc/libcamera/libcamera0.7_0.7.2+rpt20261009-1_arm64.deb|371424b861f0a6611babab81561c66e7c8cb8160798fe31a2f011826673ff549
$RPI_POOL/libc/libcamera/libcamera-ipa_0.7.2+rpt20261009-1_arm64.deb|0ee197e03669f755dc437d5a1784b10eb12369fad299f5ef87dbc1bbc43a386f
$RPI_POOL/libp/libpisp/libpisp1_1.7.0-1_arm64.deb|8fa7ecd55730771249c243132a562f43477c513858de2e3b79eef04cbdefc8e1
$RPI_POOL/libp/libpisp/libpisp-common_1.7.0-1_all.deb|d2a97e4e5c9cd182fb1878aefcacb2dee665c012024a046e976876102d0f76ab
$RPI_POOL/t/tensorflow/libtensorflow-lite2.20.0_2.20.0-1+rpt1_arm64.deb|147f938692eb5856ac95f94e6b65c85eb30f9d5e6ee3f39e358b47869d24202b
$DEBIAN_POOL/b/boost1.83/libboost-log1.83.0_1.83.0-4.2_arm64.deb|7dd3889295a032c0a89a52dc0fc969ccb17491fda657d242b287096419b5cd72
$DEBIAN_POOL/b/boost1.83/libboost-thread1.83.0_1.83.0-4.2_arm64.deb|973c3211095ad0547406bb94cd2e30948095e23e9d96b496023a4126dd1955c3
$DEBIAN_POOL/b/boost1.83/libboost-filesystem1.83.0_1.83.0-4.2_arm64.deb|10b958550550b2e7c71f0ae216566bb9eb959da645a6a0db25fb499549c49f15
$DEBIAN_POOL/b/boost1.83/libboost-atomic1.83.0_1.83.0-4.2_arm64.deb|a42c1a9aa8aea6b92f3393d955106d6500dafc04163b7967c4b5c4bb744fe8a3
$DEBIAN_POOL/a/abseil/libabsl20240722_20240722.0-4_arm64.deb|eb6648c73cd69c577a2bc18c8d66d44de897c0207a734ffdb55f91945404d0ac
"
RPI_LIBCAMERA_DIR=/opt/rpi-libcamera

CZ_HOSTNAME="${CZ_HOSTNAME:-cardputerzero-kali}"
GROW_GB="${GROW_GB:-4}"

KALI_BOOT=/mnt/kali_boot
KALI_ROOT=/mnt/kali_root
KALI_LOOP=""

# ─── Output helpers ──────────────────────────────────────────────────────────
if [[ -t 2 ]]; then
    C_INFO=$'\033[1;34m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
    C_OK=$'\033[1;32m';   C_DIM=$'\033[2m';      C_RST=$'\033[0m'
else
    C_INFO= C_WARN= C_ERR= C_OK= C_DIM= C_RST=
fi
log()  { echo "${C_INFO}[*]${C_RST} $*"  >&2; }
ok()   { echo "${C_OK}[✓]${C_RST} $*"    >&2; }
warn() { echo "${C_WARN}[!]${C_RST} $*"  >&2; }
err()  { echo "${C_ERR}[X]${C_RST} $*"   >&2; exit 1; }
dim()  { echo "${C_DIM}    $*${C_RST}"   >&2; }

# ─── Pre-flight ──────────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        log "Re-executing under sudo..."
        exec sudo -E "$BASH" "$0" "$@"
    fi
}

require_cmds() {
    local missing=()
    for c in "$@"; do command -v "$c" >/dev/null || missing+=("$c"); done
    [[ ${#missing[@]} -eq 0 ]] || err "Missing tools: ${missing[*]}"
}


# dpkg_installed <pkg>: true if <pkg> is installed in the Kali rootfs.
dpkg_installed() {
    awk -v pkg="$1" '
        /^Package: /{p=($2==pkg)}
        p && /^Status: .* installed$/{found=1}
        END{exit !found}
    ' "$KALI_ROOT/var/lib/dpkg/status"
}

# dpkg_held <pkg>: true if <pkg> is installed AND apt-mark held.
dpkg_held() {
    awk -v pkg="$1" '
        /^Package: /{p=($2==pkg)}
        p && /^Status: hold ok installed$/{held=1}
        END{exit !held}
    ' "$KALI_ROOT/var/lib/dpkg/status"
}

# kernel_img_version: "Linux version" string of the FAT's kernel8.img.
kernel_img_version() {
    # `|| true`: grep -m1 closes the pipe early (SIGPIPE → 141 under pipefail).
    { zcat "$KALI_BOOT/kernel8.img" 2>/dev/null || cat "$KALI_BOOT/kernel8.img"; } \
        | strings 2>/dev/null | grep -m1 'Linux version' | awk '{print $3}' || true
}

# fetch_file <url> <sha256> <dest>: cached, checksum-verified download.
fetch_file() {
    local url="$1" sha="$2" dest="$3"
    if [[ -f "$dest" ]] && echo "$sha  $dest" | sha256sum -c --status; then
        return 0
    fi
    mkdir -p "$(dirname "$dest")"
    log "Fetching $(basename "$dest")"
    curl -fL --retry 3 --progress-bar -o "$dest.part" "$url"
    if ! echo "$sha  $dest.part" | sha256sum -c --status; then
        rm -f "$dest.part"
        err "SHA256 mismatch for $url — refusing to use it"
    fi
    mv "$dest.part" "$dest"
}

# ─── Chroot (qemu-user) ─────────────────────────────────────────────────────
# One set of bind mounts, brought up on first use and torn down by cleanup().
# /boot/firmware inside the chroot is the image's real FAT partition, so
# kernel hooks and `make install` targets that write there do the right thing.
CHROOT_UP=0
CHROOT_RESOLV_LINK=""
CHROOT_RESOLV_SAVED=0

chroot_up() {
    (( CHROOT_UP )) && return 0
    [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
        || err "binfmt_misc qemu-aarch64 not registered. Try: sudo systemctl restart systemd-binfmt"

    # resolv.conf: give the chroot the host's resolver, restore exactly on exit.
    # (Never write *through* a symlink — its absolute target would resolve on
    # the host.)
    local r="$KALI_ROOT/etc/resolv.conf"
    if [[ -L "$r" ]]; then
        CHROOT_RESOLV_LINK=$(readlink "$r")
        rm -f "$r"
    elif [[ -f "$r" ]]; then
        cp -a "$r" "$r.cz-graft-orig"
        CHROOT_RESOLV_SAVED=1
    fi
    cat /etc/resolv.conf > "$r"

    # Keep maintainer scripts from trying to start services in the chroot.
    printf '#!/bin/sh\nexit 101\n' > "$KALI_ROOT/usr/sbin/policy-rc.d"
    chmod 755 "$KALI_ROOT/usr/sbin/policy-rc.d"

    mount --bind /dev     "$KALI_ROOT/dev"
    mount --bind /dev/pts "$KALI_ROOT/dev/pts"
    mount -t proc proc    "$KALI_ROOT/proc"
    mount -t sysfs sysfs  "$KALI_ROOT/sys"
    mkdir -p "$KALI_ROOT/boot/firmware"
    mount --bind "$KALI_BOOT" "$KALI_ROOT/boot/firmware"
    CHROOT_UP=1
}

chroot_down() {
    (( CHROOT_UP )) || return 0
    local m
    for m in boot/firmware sys proc dev/pts dev; do
        if mountpoint -q "$KALI_ROOT/$m" 2>/dev/null; then
            umount "$KALI_ROOT/$m" 2>/dev/null || umount -l "$KALI_ROOT/$m" 2>/dev/null || true
        fi
    done
    rm -f "$KALI_ROOT/usr/sbin/policy-rc.d"
    local r="$KALI_ROOT/etc/resolv.conf"
    if [[ -n "$CHROOT_RESOLV_LINK" ]]; then
        rm -f "$r"; ln -s "$CHROOT_RESOLV_LINK" "$r"
    elif (( CHROOT_RESOLV_SAVED )); then
        mv -f "$r.cz-graft-orig" "$r"
    else
        rm -f "$r"
    fi
    CHROOT_RESOLV_LINK=""; CHROOT_RESOLV_SAVED=0; CHROOT_UP=0
}

# run_chroot [args...] <<'EOF' … EOF — run a bash script (stdin) in the image.
# KVER, KERNEL_HOLD_PKGS and RPI_LIBCAMERA_DIR are exported into it; positional args become $@.
run_chroot() {
    chroot_up
    chroot "$KALI_ROOT" /usr/bin/env -i \
        DEBIAN_FRONTEND=noninteractive \
        HOME=/root \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C \
        TERM=dumb \
        KVER="$KVER" \
        KERNEL_HOLD_PKGS="$KERNEL_HOLD_PKGS" \
        RPI_LIBCAMERA_DIR="$RPI_LIBCAMERA_DIR" \
        bash -e -s -- "$@"
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────
unmount_all() {
    chroot_down
    local m
    for m in "$KALI_ROOT" "$KALI_BOOT"; do
        if mountpoint -q "$m" 2>/dev/null; then
            umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        fi
    done
}
detach_loops() {
    # Detach any loops backing the output image (resilient even after a crash)
    [[ -f "$OUT_IMG" ]] || return 0
    local loop
    while read -r loop; do
        [[ -n "$loop" ]] && losetup -d "$loop" 2>/dev/null || true
    done < <(losetup -j "$OUT_IMG" 2>/dev/null | cut -d: -f1)
    KALI_LOOP=""
}
cleanup() { unmount_all; detach_loops; }
trap cleanup EXIT

# ─── Stages ──────────────────────────────────────────────────────────────────

stage_check() {
    log "Checking host tooling"
    require_cmds xz parted partprobe e2fsck resize2fs blkid losetup ar tar zstd \
                 mountpoint truncate curl git sha256sum strings lsblk blockdev
    [[ -x /usr/bin/qemu-aarch64-static ]] \
        || err "qemu-aarch64-static not installed. Run: sudo pacman -S qemu-user-static qemu-user-static-binfmt"
    [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
        || err "binfmt_misc qemu-aarch64 not registered. Try: sudo systemctl restart systemd-binfmt"
    ok "Host tooling OK"
    dim "Kali:     $KALI_VER  ($KALI_XZ)"
    dim "Out img:  $OUT_IMG"
    dim "Kernel:   $KVER"
    dim "Drivers:  m5stack-linux-dtoverlays @ ${DTOVERLAYS_COMMIT:0:7}"
    dim "Hostname: $CZ_HOSTNAME"
}

fetch_dtoverlays() {
    local d="$CACHE/m5stack-linux-dtoverlays"
    if [[ ! -d "$d/.git" ]]; then
        log "Cloning $DTOVERLAYS_REPO"
        git clone --quiet "$DTOVERLAYS_REPO" "$d"
    fi
    if ! git -C "$d" cat-file -e "${DTOVERLAYS_COMMIT}^{commit}" 2>/dev/null; then
        git -C "$d" fetch --quiet origin
    fi
    git -C "$d" cat-file -e "${DTOVERLAYS_COMMIT}^{commit}" 2>/dev/null \
        || err "dtoverlays commit $DTOVERLAYS_COMMIT not found in $DTOVERLAYS_REPO"
}

stage_fetch() {
    log "Fetching pinned inputs into $CACHE"
    local path sha slug url name

    if [[ -f "$OUT_IMG" ]]; then
        dim "$(basename "$OUT_IMG") exists — not fetching the Kali base image"
    else
        fetch_file "$KALI_URL" "$KALI_SHA256" "$KALI_XZ"
    fi

    while IFS='|' read -r path sha; do
        [[ -z "$path" ]] && continue
        fetch_file "$RPI_POOL/$path" "$sha" "$CACHE/kernel/$(basename "$path")"
    done <<< "$KERNEL_DEBS"

    IFS='|' read -r path sha <<< "$FW_BRCM_DEB"
    fetch_file "$RPI_POOL/$path" "$sha" "$CACHE/firmware/$(basename "$path")"

    while IFS='|' read -r slug url sha; do
        [[ -z "$slug" ]] && continue
        fetch_file "$url" "$sha" "$CACHE/apps/$(basename "$url")"
    done <<< "${CZ_PREREQ_DEBS}${CZ_DEBS}"

    while IFS='|' read -r url sha; do
        [[ -z "$url" ]] && continue
        fetch_file "$url" "$sha" "$CACHE/camera/$(basename "$url")"
    done <<< "$CAMERA_DEBS"

    while IFS='|' read -r name sha; do
        [[ -z "$name" ]] && continue
        fetch_file "$PIGEN_RAW/$name" "$sha" "$CACHE/pigen/$name"
    done <<< "$PIGEN_ASSETS"

    fetch_dtoverlays
    ok "All inputs present and verified"
}

stage_unxz() {
    if [[ -f "$OUT_IMG" ]]; then
        ok "$(basename "$OUT_IMG") already present — skipping unxz"
        return
    fi
    [[ -f "$KALI_XZ" ]] || err "Kali base missing: $KALI_XZ (run the fetch stage)"
    log "Decompressing $(basename "$KALI_XZ")"
    xz -d -k -T 0 "$KALI_XZ"
    rm -f "$OUT_IMG.grown"
    ok "Decompressed: $(du -h "$OUT_IMG" | cut -f1)"
}

stage_resize() {
    if [[ -f "$OUT_IMG.grown" ]]; then
        ok "Image already grown — skipping resize"
        return
    fi
    log "Growing image by $GROW_GB GiB (current: $(du -h --apparent-size "$OUT_IMG" | cut -f1))"
    truncate -s +"${GROW_GB}G" "$OUT_IMG"
    local loop
    loop=$(losetup -fP --show "$OUT_IMG")
    parted --script "$loop" resizepart 2 100%
    partprobe "$loop"
    e2fsck -f -y "${loop}p2" || true
    resize2fs "${loop}p2"
    losetup -d "$loop"
    : > "$OUT_IMG.grown"
    ok "Resized to $(du -h --apparent-size "$OUT_IMG" | cut -f1)"
}

stage_mount() {
    if mountpoint -q "$KALI_ROOT" && mountpoint -q "$KALI_BOOT"; then
        KALI_LOOP=$(findmnt -no SOURCE "$KALI_ROOT" | sed 's/p[0-9]*$//')
        ok "Already mounted ($KALI_LOOP)"
        return
    fi
    log "Loop-attaching and mounting"
    mkdir -p "$KALI_BOOT" "$KALI_ROOT"
    KALI_LOOP=$(losetup -fP --show "$OUT_IMG")
    mount "${KALI_LOOP}p2" "$KALI_ROOT"
    mount "${KALI_LOOP}p1" "$KALI_BOOT"
    ok "Mounted: $KALI_LOOP"
}

# ── stage_kernel: Raspberry Pi kernel + CM0 WiFi firmware ───────────────────
#
# Kali's own Pi kernel is 6.12; the Cardputer Zero drivers target (and M5
# tests on) the Raspberry Pi 6.18.39 build, so install that exact .deb set,
# for real (dpkg-registered), and hold it.
stage_kernel() {
    log "Kernel: Raspberry Pi $KVER + CM0 WiFi firmware"

    if [[ "$(kernel_img_version)" == "$KVER" ]] && dpkg_installed "linux-image-$KVER" \
       && dpkg_installed "linux-headers-$KVER"; then
        ok "Kernel $KVER already installed + on the boot FAT — skipping install"
    else
        local kdir="$KALI_ROOT/var/cache/cz-graft/kernel" path sha
        mkdir -p "$kdir"
        while IFS='|' read -r path sha; do
            [[ -z "$path" ]] && continue
            install -m644 "$CACHE/kernel/$(basename "$path")" "$kdir/"
        done <<< "$KERNEL_DEBS"

        run_chroot <<'CHROOT'
# 1. nexmon's brcmfmac DKMS module installs to updates/dkms/, which outranks
#    the in-tree brcmfmac. nexmon has no BCM43439 support, and on the CM0 its
#    module would replace the driver the onboard WiFi actually needs.
if dpkg-query -W -f='${Status}' brcmfmac-nexmon-dkms 2>/dev/null | grep -q 'install ok installed'; then
    apt-get purge -y brcmfmac-nexmon-dkms
fi

# 2. Pause the DKMS kernel hooks for the install. Kali's image ships
#    realtek-rtl88xxau/8814au DKMS packages limited to 6.12; stage_packages
#    patches + builds 88XXau for 6.18 itself. A third-party DKMS failure must
#    not abort the kernel's dpkg --configure.
paused=""
for h in /etc/kernel/postinst.d/dkms /etc/kernel/header_postinst.d/dkms; do
    if [ -x "$h" ]; then chmod -x "$h"; paused="$paused $h"; fi
done
trap 'for h in $paused; do chmod +x "$h"; done' EXIT

# 3. Kali's raspi-firmware hook (z50-raspi-firmware) copies DTBs/overlays from
#    /usr/lib/linux-image-<ver>/{broadcom,overlays}; Raspberry Pi's 6.18
#    packages ship them under /usr/lib/modules/<ver>/dtb/. Bridge the paths.
[ -e "/usr/lib/linux-image-$KVER" ] || ln -s "modules/$KVER/dtb" "/usr/lib/linux-image-$KVER"

apt-get update
# z50-raspi-firmware copies DTBs with rsync; make sure it's there first.
apt-get install -y --no-install-recommends rsync
apt-get install -y --no-install-recommends --allow-downgrades --allow-change-held-packages \
    /var/cache/cz-graft/kernel/*.deb

# 4. Whatever the hooks did, make the boot FAT carry exactly this kernel.
cp "/boot/vmlinuz-$KVER" /boot/firmware/kernel8.img
cp "/usr/lib/modules/$KVER/dtb/broadcom/bcm2710-rpi-cm0.dtb" /boot/firmware/
mkdir -p /boot/firmware/overlays
cp /usr/lib/modules/$KVER/dtb/overlays/*.dtbo /boot/firmware/overlays/
cp "/usr/lib/modules/$KVER/dtb/overlays/README" /boot/firmware/overlays/ 2>/dev/null || true
[ -f "/boot/initrd.img-$KVER" ] || update-initramfs -c -k "$KVER"
cp "/boot/initrd.img-$KVER" /boot/firmware/initramfs8

for p in $KERNEL_HOLD_PKGS; do apt-mark hold "$p"; done
rm -rf /var/cache/cz-graft/kernel
CHROOT
        ok "Kernel $KVER installed + held"
    fi

    # CM0 WiFi/BT firmware from Raspberry Pi's firmware-brcm80211: the brcm/
    # + cypress/ trees, symlinks and all, over Kali's. Load-bearing piece is
    # cypress/cyfmac43439-sdio.txt (boardflags3=0x04000000); with Kali's
    # NVRAM the BCM43439 wedges with "HT Avail timeout" and wlan0 never shows.
    local deb work fw="$KALI_ROOT/usr/lib/firmware"
    deb="$CACHE/firmware/$(basename "${FW_BRCM_DEB%%|*}")"
    work=$(mktemp -d)
    ( cd "$work" && ar x "$deb" && tar -xaf "$(ls data.tar.* | head -1)" )
    mkdir -p "$fw/brcm" "$fw/cypress"
    cp -a --remove-destination "$work/usr/lib/firmware/cypress/." "$fw/cypress/"
    cp -a --remove-destination "$work/usr/lib/firmware/brcm/."    "$fw/brcm/"
    rm -rf "$work"
    ok "CM0 WiFi firmware installed (Raspberry Pi firmware-brcm80211)"
}

# ── stage_drivers: Cardputer Zero drivers + overlays, built from source ─────
#
# Same build M5's image runs (pi-gen stage2/05-cardputerzero/01-run.sh):
# `make CONFIG_CARDPUTERO_V0_5=y install` in modules/CardputerZero, which also
# builds + installs the panel, keypad, codec, battery, IO-expander and IMU
# subdirs, their overlays (into /boot/firmware/overlays), the ST7789 panel
# init blob, fb_load (+ its sysinit unit) and the LCD/keypad udev rules.
# Their `config_setup` target is NOT used — stage_boot writes config.txt.
stage_drivers() {
    log "Drivers: m5stack-linux-dtoverlays @ ${DTOVERLAYS_COMMIT:0:7}, built against $KVER"
    local src="$KALI_ROOT/usr/src/m5stack-linux-dtoverlays"

    if [[ "$(cat "$src/.cz-graft-commit" 2>/dev/null)" == "$DTOVERLAYS_COMMIT" \
       && -f "$KALI_ROOT/usr/lib/modules/$KVER/extra/panel-mipi-dbi-m.ko" \
       && -f "$KALI_BOOT/overlays/cardputerzero-v5-overlay.dtbo" ]]; then
        ok "Drivers @ ${DTOVERLAYS_COMMIT:0:7} already built for $KVER — skipping build"
    else
        [[ -d "$KALI_ROOT/usr/src/linux-headers-$KVER" ]] \
            || err "kernel headers for $KVER not in image — run the kernel stage first"
        fetch_dtoverlays
        rm -rf "${src:?}"
        mkdir -p "$src"
        git -C "$CACHE/m5stack-linux-dtoverlays" archive "$DTOVERLAYS_COMMIT" | tar -x -C "$src"

        run_chroot <<'CHROOT'
apt-get update
apt-get install -y --no-install-recommends build-essential device-tree-compiler
mkdir -p /usr/share/keymaps /etc/udev/rules.d /etc/systemd/system/sysinit.target.wants \
         /usr/lib/firmware /usr/sbin /boot/firmware/overlays "/usr/lib/modules/$KVER/extra"
cd /usr/src/m5stack-linux-dtoverlays/modules/CardputerZero
make KERNELDIR="/usr/lib/modules/$KVER/build" EXTRADIR="/usr/lib/modules/$KVER/extra" \
     ARCH=arm64 CONFIG_CARDPUTERO_V0_5=y install
make ROOTFSPATH= install_led_permissions
depmod "$KVER"
CHROOT
        echo "$DTOVERLAYS_COMMIT" > "$src/.cz-graft-commit"
        ok "Drivers built + installed"
    fi

    # Not in the dtoverlays repo: these two ship from M5's image build itself.
    #  99-ignore-i2c-key.rules (pi-gen stage2/01-sys-tweaks) puts the internal
    #   keypad on its own seat so a desktop session never claims it.
    #  zz-cardputerzero-hdmi-display.rules strips the master-of-seat tag that
    #   99-cardputer-zero-lcd.rules sets on the panel's DRM card. Nothing ever
    #   opens a logind session on that seat, and with the tag present even
    #   root gets EACCES modesetting the panel. APPLaunch owns it directly.
    install -d "$KALI_ROOT/etc/udev/rules.d" "$KALI_ROOT/usr/lib/udev/rules.d"
    cat > "$KALI_ROOT/etc/udev/rules.d/99-ignore-i2c-key.rules" <<'EOF'
ACTION!="remove", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_PATH}=="platform-3f804000.i2c", ENV{ID_SEAT}="seat1", GROUP="input", MODE="0660"
EOF
    cat > "$KALI_ROOT/usr/lib/udev/rules.d/zz-cardputerzero-hdmi-display.rules" <<'EOF'
# APPLaunch owns the internal SPI panel directly; do not let LightDM create a
# second graphical session for that dedicated seat.
ACTION!="remove", SUBSYSTEM=="drm", KERNEL=="card*", \
  ENV{ID_PATH}=="platform-3f204000.spi-cs-0", \
  TAG-="master-of-seat"
EOF

    # panel_mipi_dbi_m doesn't reliably coldplug-autoload (every other CZ
    # driver does); APPLaunch needs /dev/fb_lcd at startup, so force it.
    mkdir -p "$KALI_ROOT/etc/modules-load.d"
    echo "panel_mipi_dbi_m" > "$KALI_ROOT/etc/modules-load.d/cardputerzero-panel.conf"

    # ExtPort / Grove 5V switches are m5ioe1-backed LED-class GPIOs; the
    # tmpfiles/udev pair installed above hands their brightness files to group
    # gpio. kali is added to it in stage_packages (Kali's image has no kali
    # user until then — it normally relies on cloud-init to create one).
    grep -q '^gpio:' "$KALI_ROOT/etc/group" || groupadd --root "$KALI_ROOT" --system gpio

    # fb_load's sysinit symlink is created by `make install`; make sure.
    if [[ -f "$KALI_ROOT/etc/systemd/system/fb_load.service" ]]; then
        mkdir -p "$KALI_ROOT/etc/systemd/system/sysinit.target.wants"
        ln -sfn ../fb_load.service "$KALI_ROOT/etc/systemd/system/sysinit.target.wants/fb_load.service"
    fi
}

stage_boot() {
    log "Boot partition: config.txt, cmdline.txt, splash"
    for f in config.txt cmdline.txt; do
        [[ -f "$KALI_BOOT/$f.kali" ]] || cp -a "$KALI_BOOT/$f" "$KALI_BOOT/$f.kali"
    done

    # 170x320 RGB565 BMP — native for the ST7789 panel; fb_load blits it.
    install -m644 "$CACHE/pigen/splash.bmp" "$KALI_BOOT/splash.bmp"

    write_config_txt
    write_cmdline_txt
    ok "Boot partition ready"
}

write_config_txt() {
    log "Writing config.txt"
    cat > "$KALI_BOOT/config.txt" <<'CONFIG'
# Cardputer Zero on Kali — written by graft.sh (Kali's original: config.txt.kali).
# Boots the Raspberry Pi 6.18 kernel (kernel8.img) straight from the GPU
# firmware loader, same as M5's image.

dtparam=i2c_arm=on
dtparam=i2s=on
dtparam=spi=on
dtparam=audio=off

camera_auto_detect=0
dtoverlay=imx219
display_auto_detect=1

auto_initramfs=1
dtoverlay=vc4-kms-v3d
max_framebuffers=2
disable_fw_kms_setup=1
arm_64bit=1
disable_overscan=1
arm_boost=1

[cm4]
otg_mode=1

[cm5]
dtoverlay=dwc2,dr_mode=host

[all]
enable_uart=1

# USB OTG (gadget-capable) controller
dtoverlay=dwc2

# Cardputer Zero carrier board, hardware rev v5 (production) — overlays built
# from m5stack-linux-dtoverlays by stage_drivers.
dtoverlay=cardputerzero-v5-overlay
dtoverlay=bq27220_v5
dtoverlay=bmi270_bmm150_overlay

# IR receiver + transmitter
dtoverlay=gpio-ir,gpio_pin=13,gpio_pull=up
dtoverlay=gpio-ir-tx,gpio_pin=12
CONFIG
}

write_cmdline_txt() {
    local partuuid
    partuuid=$(blkid -s PARTUUID -o value "${KALI_LOOP}p2")
    log "Writing cmdline.txt with PARTUUID=$partuuid"
    # 'quiet'          keep kernel chatter off the consoles.
    # 'consoleblank=0' no 10-min console blanking.
    # 'fbcon=map:99'   bind the kernel console to no framebuffer at boot, so
    #                  nothing paints over APPLaunch on the LCD whatever the fb
    #                  probe order. tty2..6 are mapped onto HDMI later, by
    #                  udev (cz-hdmi-console, see stage_configs).
    # No 'console=serial0,115200': ttyS0 is the LoRa+GNSS cap's UART, and the
    # GPS app refuses a port that's assigned to the serial console (M5's
    # pi-gen strips that token too).
    cat > "$KALI_BOOT/cmdline.txt" <<CMDLINE
console=tty1 root=PARTUUID=${partuuid} rootfstype=ext4 fsck.repair=yes rootwait quiet fbcon=map:99 consoleblank=0 modules-load=dwc2
CMDLINE
}

stage_configs() {
    log "Writing static configs (glycin env, fbcon disable, X input ignore, lightdm, /etc/skel)"

    # System-wide glycin sandbox bypass. The CM0's kernel / Pi userland combo
    # makes glycin's bwrap sandbox crash on every icon load (status 127/139)
    # which assert-kills any Gtk app. Bypassing the sandbox is the only known
    # workaround until upstream glycin fixes its aarch64 seccomp filter.
    mkdir -p "$KALI_ROOT/etc/environment.d"
    cat > "$KALI_ROOT/etc/environment.d/glycin-nosandbox.conf" <<'EOF'
GLYCIN_SANDBOX_MECHANISM=not-sandboxed
EOF
    mkdir -p "$KALI_ROOT/etc/profile.d"
    cat > "$KALI_ROOT/etc/profile.d/glycin-nosandbox.sh" <<'EOF'
export GLYCIN_SANDBOX_MECHANISM=not-sandboxed
EOF
    chmod 644 "$KALI_ROOT/etc/profile.d/glycin-nosandbox.sh"

    # Also append to /etc/environment so pam_env propagates it into lightdm-
    # autologin X sessions. environment.d / profile.d don't cover that path
    # (systemd --user vs login shells respectively), and without the env in
    # the session, pcmanfm-desktop fails to load the wallpaper JPEG via
    # gdk-pixbuf's glycin backend (OutOfMemory) and the desktop is solid black.
    if ! grep -q '^GLYCIN_SANDBOX_MECHANISM' "$KALI_ROOT/etc/environment" 2>/dev/null; then
        echo 'GLYCIN_SANDBOX_MECHANISM=not-sandboxed' >> "$KALI_ROOT/etc/environment"
    fi

    # Disable X screen blanking + DPMS — this device is always-on or HDMI-
    # demo-attached; we don't want a 10-minute black screen surprising users.
    # `xset` lines have no leading `@` so lxsession runs them once (not respawned
    # like the persistent daemons). Done as a separate file under lxsession.d so
    # we don't fight the Kali package's autostart contents.
    mkdir -p "$KALI_ROOT/etc/xdg/lxsession/LXDE"
    cat > "$KALI_ROOT/etc/xdg/lxsession/LXDE/autostart" <<'EOF'
@lxpanel --profile LXDE
@pcmanfm --desktop --profile LXDE
xset s off
xset -dpms
xset s noblank
EOF

    # fbcon is fully suppressed via the kernel cmdline `fbcon=map:99` in
    # write_cmdline_txt — that's race-free against st7789v_m5stack binding
    # after our userspace runs. No userspace service needed; clean up any
    # legacy disable-fbcon.service from older builds so it doesn't show as
    # active-but-no-op.
    rm -f "$KALI_ROOT/etc/systemd/system/disable-fbcon.service" \
          "$KALI_ROOT/etc/systemd/system/basic.target.wants/disable-fbcon.service"

    # Keep the integrated keypad + IR receiver out of X. Both APPLaunch (on the
    # LCD) and X (on HDMI) try to libinput-grab the same evdev nodes; whichever
    # gets there first wins, and APPLaunch loses every time. Tell X to ignore
    # these two devices so the keypad/IR stay with APPLaunch and only USB
    # peripherals (like the user's K400) drive the HDMI session.
    mkdir -p "$KALI_ROOT/etc/X11/xorg.conf.d"
    cat > "$KALI_ROOT/etc/X11/xorg.conf.d/40-cardputerzero-no-grab.conf" <<'EOF'
# Cardputer Zero — keep integrated keypad + IR receiver out of X.
# APPLaunch on the LCD owns them; X grabbing them steals input from the launcher.

Section "InputClass"
    Identifier "Cardputer Zero integrated keypad - ignore"
    MatchProduct "tca8418c"
    Option "Ignore" "on"
EndSection

Section "InputClass"
    Identifier "Cardputer Zero IR receiver - ignore"
    MatchProduct "gpio_ir_recv"
    Option "Ignore" "on"
EndSection
EOF

    # Disable V3D-accelerated 2D (glamor) on the Pi Zero 2 W. With glamor on,
    # X tries to allocate tile-binning buffers from V3D's CMA pool and fails
    # under load with "AddScreen/ScreenInit failed for driver 0" (the GEM DMA
    # helper returns -ENOMEM even for the 4 MB scanout BO). Software shadow-fb
    # is slower but the screen actually comes up.
    cat > "$KALI_ROOT/etc/X11/xorg.conf.d/98-vc4-no-glamor.conf" <<'EOF'
Section "Device"
    Identifier "vc4-noaccel"
    Driver "modesetting"
    Option "AccelMethod" "none"
    Option "ShadowFB" "true"
EndSection
EOF

    # Expose i2c-1 to userspace. The bq27220 kernel driver (bq27220_v5.dtbo,
    # see stage_boot) handles normal battery status via /sys/class/power_supply
    # now — this is for APPLaunch's separate Calibrate command
    # (cp0_lvgl_bq27220.cpp Bq27220System::calibrate()), which talks to the
    # chip directly via raw I2C_RDWR ioctls on /dev/i2c-1 regardless.
    mkdir -p "$KALI_ROOT/etc/modules-load.d"
    cat > "$KALI_ROOT/etc/modules-load.d/i2c-dev.conf" <<'EOF'
i2c-dev
EOF

    # rtw88 vs out-of-tree Realtek DKMS drivers:
    # Kernel 6.18 added in-tree rtw88_8821au (covers 0bda:0811 AWUS036ACS) and
    # rtw88_8822bu. These win the modalias race and prevent 88XXau.ko from loading.
    # Blacklist the in-tree variants so our DKMS builds have a clear path.
    mkdir -p "$KALI_ROOT/etc/modprobe.d"
    cat > "$KALI_ROOT/etc/modprobe.d/rtw88-dkms-override.conf" <<'EOF'
# Blacklist in-tree rtw88 USB drivers that conflict with out-of-tree DKMS builds.
# 88XXau (aircrack-ng fork) has better injection/monitor than rtw88_8821au.
# rtw88_8822bu intentionally omitted — no replacement 88XXBu driver yet.
blacklist rtw88_8821au
blacklist rtw88_8821a
blacklist rtw88_88xxa
blacklist rtw88_8812au
blacklist rtw88_8814au
EOF

    # 88XXau has no MODULE_DEVICE_TABLE exports, so udev cannot auto-load it via
    # modalias. Load it at boot (covers pre-connected adapters) and via udev rule
    # (covers hot-plug). The module's internal id_table claims the device on load.
    cat > "$KALI_ROOT/etc/modules-load.d/rtw88xxau.conf" <<'EOF'
# Out-of-tree Realtek 8811/8821AU driver (aircrack-ng fork, monitor/inject support).
# rtw88_8821au is blacklisted; this module claims the adapter at probe time.
88XXau
EOF

    mkdir -p "$KALI_ROOT/etc/udev/rules.d"
    cat > "$KALI_ROOT/etc/udev/rules.d/99-rtw88xxau.rules" <<'EOF'
# Hot-plug loader for out-of-tree 88XXau driver (no MODULE_ALIAS, so udev won't
# find it via modalias). Matches Realtek 8811/8821AU USB IDs.
ACTION=="add", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="0811", RUN+="/usr/sbin/modprobe 88XXau"
ACTION=="add", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="8822", RUN+="/usr/sbin/modprobe 88XXau"
ACTION=="add", SUBSYSTEM=="usb", DEVTYPE=="usb_device", ATTRS{idVendor}=="0bda", ATTRS{idProduct}=="a811", RUN+="/usr/sbin/modprobe 88XXau"
EOF

    # Audio routing. Two ALSA cards register at boot — card 0 is vc4hdmi
    # (CZ has no physical HDMI sink, opens fail with ENOSTR), card 1 is the
    # ES8389 codec driven by es8389_m5stack.ko + the cardputerzero-v5-overlay's
    # I2S wiring. ALSA's stock `default` device tries to resolve via
    # cards.pcm.front (per-codec conf files in /usr/share/alsa/cards/) which
    # doesn't exist for the M5-custom codec — so every ALSA app fails with
    # "Unknown PCM cards.pcm.front" unless we point `default` at hw:1,0
    # explicitly. Layered through a softvol plugin so apps see a usable
    # "Master" mixer control (the kernel codec module exposes no native
    # volume controls — alsamixer would otherwise show an empty Item: line).
    cat > "$KALI_ROOT/etc/asound.conf" <<'EOF'
pcm.!default {
    type plug
    slave.pcm "softvol_out"
}

pcm.softvol_out {
    type softvol
    slave.pcm "hw:1,0"
    control {
        name "Master"
        card 1
    }
    min_dB -51.0
    max_dB 0.0
    resolution 256
}

ctl.!default {
    type hw
    card 1
}
EOF

    # gpsd config — /dev/ttyS0 at 115200 baud for the LoRa+GNSS cap's
    # ATGM336H (ships at 115200 NMEA). -s locks the baud rate. No -n: gpsd is
    # socket-activated (stage_packages) and only opens the port while a client
    # is watching, so M5's GPS app can have it the rest of the time. USBAUTO
    # off so hotplug rules don't claim some other GPS we don't have.
    cat > "$KALI_ROOT/etc/default/gpsd" <<'EOF'
DEVICES="/dev/ttyS0"
GPSD_OPTIONS="-s 115200"
USBAUTO="false"
START_DAEMON="true"
EOF

    # zram swap config: 75% of RAM (~311 MB on the 415 MB CM0) compressed
    # via zstd. Service is enabled in stage_packages after zram-tools lands.
    # 50% was too tight — opening LXDE menus tipped the system over the edge.
    cat > "$KALI_ROOT/etc/default/zramswap" <<'EOF'
ALGO=zstd
PERCENT=75
PRIORITY=100
EOF

    # Lightdm: autologin kali → LXDE. Wins over any package-shipped configs.
    mkdir -p "$KALI_ROOT/etc/lightdm/lightdm.conf.d"
    cat > "$KALI_ROOT/etc/lightdm/lightdm.conf.d/lightdm-autologin-greeter.conf" <<'EOF'
[Seat:*]
autologin-user=kali
autologin-session=LXDE
user-session=LXDE
greeter-session=lightdm-autologin-greeter
EOF

    # NOTE: We used to drop /etc/skel/.config/pcmanfm/LXDE/desktop-items-0.conf
    # here, but that file is per-monitor-item state, NOT the wallpaper source
    # pcmanfm-desktop actually reads at startup. The real wallpaper setting
    # lives in /etc/xdg/pcmanfm/LXDE/pcmanfm.conf [desktop] section — which
    # is part of the pcmanfm package, so we patch it in stage_packages after
    # the package lands. See https://wiki.archlinux.org/title/PCManFM

    # ── Virtual consoles: tty1 dead, tty2..6 = normal login on HDMI ──────────
    #
    # The internal keypad is shared, not grabbed: upstream APPLaunch
    # deliberately dropped EVIOCGRAB so the apps it launches can read the same
    # evdev device. The kernel's VT keyboard handler therefore ALSO receives
    # every keypad press and types it into whichever VT is in the foreground.
    # The old design autologged `kali` into a shell on tty1, so typing in
    # APPLaunch also typed into a NOPASSWD-sudo shell. Now:
    #   - tty1: no getty and no autovt (masked) — nothing to type into.
    #   - X/LXDE (lightdm autologin) runs on its own VT; while it's in the
    #     foreground the kernel VT keyboard is off, so the keypad only reaches
    #     APPLaunch.
    #   - Ctrl-Alt-F2..F6 → logind spawns autovt@ttyN on demand: a normal,
    #     credentialed login prompt. Alt-F7 goes back to the desktop.
    # APPLaunch is a *user* unit: it used to be pulled up as a side-effect of
    # the tty1 autologin session. With that gone, lingering for `kali`
    # (stage_apps) is what starts the user manager — and APPLaunch — at boot.
    rm -rf "$KALI_ROOT/etc/systemd/system/getty@tty1.service.d"
    rm -f  "$KALI_ROOT/etc/systemd/system/getty.target.wants/getty@tty1.service"
    ln -sfn /dev/null "$KALI_ROOT/etc/systemd/system/getty@tty1.service"
    ln -sfn /dev/null "$KALI_ROOT/etc/systemd/system/autovt@tty1.service"

    # fbcon=map:99 (cmdline.txt) keeps the kernel console off EVERY
    # framebuffer at boot, so nothing ever paints over APPLaunch on the LCD.
    # That would also leave tty2..6 invisible on HDMI, so once the HDMI
    # framebuffer (vc4drmfb) registers — at boot, or later on HDMI hotplug —
    # map consoles 2..6 onto it, and only onto it. The LCD's framebuffer has a
    # different name and is never touched, regardless of fb probe order.
    install -d -m755 "$KALI_ROOT/usr/local/sbin"
    cat > "$KALI_ROOT/usr/local/sbin/cz-hdmi-console" <<'EOF'
#!/bin/sh
# Map VTs 2..6 onto the HDMI framebuffer passed as $1 (fb index).
# Invoked by /etc/udev/rules.d/90-cz-hdmi-console.rules.
fb="$1"
[ -n "$fb" ] || exit 0
con2fbmap=$(command -v con2fbmap || echo /usr/bin/con2fbmap)
for vt in 2 3 4 5 6; do
    "$con2fbmap" "$vt" "$fb" || true
done
EOF
    chmod 755 "$KALI_ROOT/usr/local/sbin/cz-hdmi-console"
    mkdir -p "$KALI_ROOT/etc/udev/rules.d"
    cat > "$KALI_ROOT/etc/udev/rules.d/90-cz-hdmi-console.rules" <<'EOF'
# HDMI text consoles (tty2..6) on the vc4 framebuffer only — see graft.sh stage_configs.
ACTION=="add", SUBSYSTEM=="graphics", KERNEL=="fb[0-9]*", ATTR{name}=="vc4drmfb", RUN+="/usr/local/sbin/cz-hdmi-console %n"
EOF

    # dbus.service WorkingDirectory drop-in. systemd 259+ chdirs to the User='s
    # home dir when WorkingDirectory= isn't set. dbus runs as User=messagebus
    # whose home is /nonexistent → systemd exits 200/CHDIR → dbus never starts
    # → polkit, NetworkManager, systemd-timesyncd, lightdm-autologin-greeter
    # all cascade-fail. WorkingDirectory=/ forces a sane working dir.
    mkdir -p "$KALI_ROOT/etc/systemd/system/dbus.service.d"
    cat > "$KALI_ROOT/etc/systemd/system/dbus.service.d/workdir.conf" <<'EOF'
[Service]
WorkingDirectory=/
EOF

    ok "Static configs staged"
}


# ── stage_packages: chroot into the rootfs and apt-install the desktop stack ──
#
# Requires qemu-user-static + qemu-user-static-binfmt on the host, and
# systemd-binfmt to have registered /proc/sys/fs/binfmt_misc/qemu-aarch64
# with the F (fix-binary) flag so the interpreter survives chroot.
# Bump PACKAGES_REV whenever stage_packages changes (new package, group,
# unit policy, …): the skip sentinel below only trusts an image stamped with
# the current revision, so an older image re-runs the whole stage.
PACKAGES_REV=2
PACKAGES_STAMP=/var/lib/cz-graft/packages.rev

stage_packages() {
    log "Installing desktop stack via qemu-user-static chroot"

    # Sentinel: skip only if this revision of the stage already ran AND the
    # expensive results (LXDE, the kali user, 88XXau for $KVER) are present.
    if [[ "$(cat "$KALI_ROOT$PACKAGES_STAMP" 2>/dev/null)" == "$PACKAGES_REV" \
       && -x "$KALI_ROOT/usr/bin/lxsession" \
       && -x "$KALI_ROOT/usr/lib/lightdm-autologin-greeter/lightdm-autologin-greeter" \
       && -f "$KALI_ROOT/usr/lib/aarch64-linux-gnu/libcamera.so.0.7" \
       && -x "$KALI_ROOT/usr/bin/ffmpeg" \
       && -x "$KALI_ROOT/usr/bin/gpioset" \
       && -x "$KALI_ROOT/usr/bin/con2fbmap" \
       && -f "$KALI_ROOT/usr/share/doc/pipewire-pulse/copyright" \
       && -d "$KALI_ROOT/home/kali/.ssh" ]] \
       && grep -q '^kali:' "$KALI_ROOT/etc/passwd" \
       && find "$KALI_ROOT/usr/lib/modules/$KVER" -name '88XXau.ko*' \
               -path '*/updates/dkms/*' 2>/dev/null | grep -q .; then
        ok "Desktop packages (rev $PACKAGES_REV) + kali user + 88XXau all present — skipping"
        return
    fi

    run_chroot <<'CHROOT'
apt-get update

# gcc + make must land before realtek-rtl88xxau-dkms triggers the DKMS build.
# dkms doesn't declare gcc as a dependency (it's expected to be present), so a
# single combined apt-get could configure rtl88xxau-dkms before gcc is ready.
apt-get install -y --no-install-recommends gcc make

# pipewire-pulse + wireplumber: APPLaunch's user unit is After=/Wants=
#   pipewire-pulse.service, and Music/Piano/Recorder/Keyboard-Guide talk
#   libpulse. pulseaudio-utils supplies the pactl/paplay they shell out to.
# fbset: con2fbmap, used by /usr/local/sbin/cz-hdmi-console (stage_configs).
# python3-gi + gir1.2-gtk-3.0 + python3-gi-cairo: M5's fb-mirror.py (LCD
#   mirrored into a window on the HDMI desktop; stage_apps installs it).
# xdg-user-dirs: hard Depends of applaunch; listed so it lands here, early.
# fonts-noto-cjk: the CZ apps (Camera, …) load NotoSansCJK-{Regular,Medium}.ttc
#   by absolute path for their UI text; M5's image installs it too.
apt-get install -y --no-install-recommends \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" \
    zram-tools \
    cloud-guest-utils \
    lxde-core \
    lightdm-autologin-greeter \
    feh \
    libcamera0.7 \
    libcamera-ipa \
    ffmpeg \
    gpiod \
    pipewire-alsa \
    pipewire-pulse \
    wireplumber \
    pulseaudio-utils \
    rtkit \
    fbset \
    xdg-user-dirs \
    python3-gi \
    python3-gi-cairo \
    gir1.2-gtk-3.0 \
    fonts-noto-cjk \
    gpsd \
    gpsd-clients \
    realtek-rtl88xxau-dkms

# Build Realtek out-of-tree drivers against the Raspberry Pi 6.18 kernel.
# DKMS skips 6.18 due to BUILD_EXCLUSIVE_KERNEL="^6\.12\..*" in its dkms.conf.
# We: (1) patch sources for 6.16–6.18 API changes, (2) strip BUILD_EXCLUSIVE so
# DKMS can manage the kernel going forward, (3) register + install via DKMS so
# future kernel upgrades trigger auto-rebuild, falling back to raw make if needed.
#
# Shared compat files written once, used by all driver builds below.
cat > /tmp/rtw_compat_6_16.h <<'COMPAT'
/* Compat shims for kernel 6.16+ which removed from_timer() and del_timer_sync() */
#ifndef RTW_COMPAT_6_16_H
#define RTW_COMPAT_6_16_H
#include <linux/version.h>
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 16, 0)
# ifndef from_timer
#  define from_timer(var, cb, field) timer_container_of(var, cb, field)
# endif
# ifndef del_timer_sync
#  define del_timer_sync(t) timer_delete_sync(t)
# endif
#endif
#endif /* RTW_COMPAT_6_16_H */
COMPAT

# Python patcher for cfg80211_ops signatures (kernel 6.17+ added int radio_idx).
# Uses str.replace — regex can't span the #if guards between params.
cat > /tmp/patch_cfg80211.py <<'PYPATCH'
import sys
path = sys.argv[1]
with open(path) as f:
    c = f.read()
orig = c

def patch(c, old, new, label):
    if old in c:
        print(f'Patched {label}')
        return c.replace(old, new, 1)
    elif new in c:
        print(f'Already patched {label}')
        return c
    else:
        print(f'WARNING: no match for {label}')
        return c

c = patch(c,
    'cfg80211_rtw_set_wiphy_params(struct wiphy *wiphy, u32 changed)',
    'cfg80211_rtw_set_wiphy_params(struct wiphy *wiphy, int radio_idx __maybe_unused, u32 changed)',
    'set_wiphy_params')
c = patch(c,
    '#endif\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)) || defined(COMPAT_KERNEL_RELEASE)\n\tenum nl80211_tx_power_setting type, int mbm)',
    '#endif\n\tint radio_idx __maybe_unused,\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)) || defined(COMPAT_KERNEL_RELEASE)\n\tenum nl80211_tx_power_setting type, int mbm)',
    'set_tx_power')
c = patch(c,
    '#endif\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0))\n\tunsigned int link_id,',
    '#endif\n\tint radio_idx __maybe_unused,\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0))\n\tunsigned int link_id,',
    'get_tx_power')

with open(path, 'w') as f:
    f.write(c)
print(f'Done — {"changes made" if c != orig else "no changes"}')
sys.exit(0)
PYPATCH

# Helper: patch + DKMS-register + build one Realtek aircrack-ng fork driver.
#   $1  glob under /usr/src/  e.g. '*rtl88xxau-*'
#   $2  .ko filename           e.g. '88XXau.ko'
#   $3  label                  e.g. 'rtl88xxau'
build_rtl_drv() {
    local pat="$1" ko_name="$2" label="$3"
    local src kver
    src=$(ls -d /usr/src/$pat 2>/dev/null | sort -V | tail -1)
    kver=$(ls /lib/modules/ | grep '+rpt-rpi-v8$' | sort -V | tail -1)
    if [ -z "$src" ] || [ -z "$kver" ]; then
        echo "[$label] WARNING: source (${src:-none}) or kernel (${kver:-none}) not found"
        return
    fi

    # The RPi 6.18 headers build with aarch64-linux-gnu-gcc-14; their package
    # Depends on gcc-14-for-host, so stage_kernel already installed the real
    # compiler. Fallback shim only if it's somehow absent (no-op otherwise).
    for _t in gcc gcc-ar gcc-nm gcc-ranlib; do
        [ -e "/usr/bin/aarch64-linux-gnu-${_t}-14" ] || \
            ln -sf "aarch64-linux-gnu-${_t}-15" "/usr/bin/aarch64-linux-gnu-${_t}-14"
    done

    # kbuild 6.18 dropped EXTRA_CFLAGS — must be ccflags-y.
    sed -i 's/^EXTRA_CFLAGS\b/ccflags-y/g; s/^EXTRA_LDFLAGS\b/ldflags-y/g' "$src/Makefile"

    # Timer compat header (from_timer / del_timer_sync removed in 6.16).
    cp /tmp/rtw_compat_6_16.h "$src/include/"
    grep -q 'rtw_compat_6_16.h' "$src/include/osdep_service_linux.h" || \
        sed -i '/#define __OSDEP_LINUX_SERVICE_H_/a #include "rtw_compat_6_16.h"' \
            "$src/include/osdep_service_linux.h"

    # cfg80211_ops signatures (radio_idx added in 6.17).
    python3 /tmp/patch_cfg80211.py "$src/os_dep/linux/ioctl_cfg80211.c" || \
        echo "[$label] NOTE: cfg80211 patch had no effect"

    # Strip BUILD_EXCLUSIVE_KERNEL so DKMS manages future kernel upgrades.
    sed -i '/BUILD_EXCLUSIVE_KERNEL/d' "$src/dkms.conf"

    # Register with DKMS (idempotent — 'already added' is fine).
    local dname dver
    dname=$(awk -F'"' '/^PACKAGE_NAME/{print $2; exit}' "$src/dkms.conf")
    dver=$(awk -F'"' '/^PACKAGE_VERSION/{print $2; exit}' "$src/dkms.conf")
    if [ -n "$dname" ] && [ -n "$dver" ]; then
        dkms add -m "$dname" -v "$dver" 2>/dev/null || true
        # Build + install via DKMS — populates the DB so 'dkms autoinstall' fires
        # on future kernel upgrades. DKMS calls the dkms.conf MAKE line, which for
        # these drivers is: make KVER=$kernelver KSRC=/lib/modules/$kernelver/build
        if dkms install --force -m "$dname" -v "$dver" -k "$kver" 2>&1; then
            depmod "$kver"
            echo "[$label] DKMS built and installed $ko_name for $kver"
            return
        fi
        echo "[$label] DKMS install failed — falling back to manual build"
    fi

    # Manual fallback (same make invocation as dkms.conf MAKE line).
    if (cd "$src" && make KVER="$kver" KSRC="/lib/modules/$kver/build"); then
        local ko
        ko=$(find "$src" -name "$ko_name" | head -1)
        if [ -n "$ko" ]; then
            mkdir -p "/lib/modules/$kver/updates/dkms"
            cp "$ko" "/lib/modules/$kver/updates/dkms/$ko_name"
            depmod "$kver"
            echo "[$label] Manual build installed $ko_name for $kver"
        else
            echo "[$label] WARNING: make succeeded but $ko_name not found"
            find "$src" -name '*.ko' 2>/dev/null | sed 's/^/  found: /'
        fi
    else
        echo "[$label] WARNING: manual build failed for $kver"
    fi
}

# RTL8811AU / RTL8812AU / RTL8821AU — Alfa AWUS036ACS and similar
build_rtl_drv '*rtl88xxau-*' '88XXau.ko' 'rtl88xxau'
# RTL8812BU / RTL8822BU — TP-Link T2U, Panda PAU0D and similar
build_rtl_drv '*rtl88x2bu-*' '88XXBu.ko' 'rtl88x2bu'

# Pre-create the kali user with password 'kali' instead of relying on
# cloud-init. On Kali 2026.3's Pi image cloud-init never runs at all:
# ds-identify finds no datasource (nothing points NoCloud at /boot/firmware),
# so the generator disables it and /boot/firmware/user-data is ignored. The
# user, hostname, ssh and rootfs grow are therefore all baked in here instead.
# UID 1000 specifically: APPLaunch's postinst enables the launcher for UID 1000.
if ! getent passwd kali >/dev/null; then
    if getent passwd 1000 >/dev/null; then
        echo "ERROR: UID 1000 is taken by $(getent passwd 1000 | cut -d: -f1); APPLaunch needs kali at 1000" >&2
        exit 1
    fi
    getent group kali >/dev/null || groupadd -g 1000 kali
    useradd -m -u 1000 -g kali -G sudo,users,audio,video,plugdev,netdev -s /bin/bash kali
fi
echo 'kali:kali' | chpasswd
echo 'kali ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/kali-nopasswd
chmod 440 /etc/sudoers.d/kali-nopasswd

# Device-access groups. APPLaunch is a systemd *user* unit running as kali,
# and the apps it launches inherit that — so `kali` must directly own the
# hardware they touch. Stock RaspiOS gives its `pi` user this whole set; the
# Kali base under-provisions it (and the `useradd -G` above only runs when
# kali didn't already exist — it does in Kali's image).
#   input   -> /dev/input/event* (TCA8418 keypad) is 0660 root:input.
#   video   -> /dev/fb_lcd + the panel's /dev/dri/card* (APPLaunch draws here).
#   audio   -> ES8389 codec PCM devices.
#   i2c     -> /dev/i2c-* is 0660 root:i2c (battery calibration).
#   dialout -> serial UARTs (/dev/ttyAMA*, GPS/LoRa) when not world-rw.
#   render  -> /dev/dri/render* (GPU); harmless + forward-compatible.
#   spi     -> /dev/spidev* (the LoRa cap's SX1262). Raspberry Pi's 99-com.rules
#              asks for GROUP="spi", but Kali has no such group, so udev fell
#              back to root:root 0600 and Cap-LoRa-1262 couldn't open it.
# (The gpio group for the ExtPort LED switches is created in stage_drivers.)
getent group spi >/dev/null || groupadd --system spi
for grp in input video audio i2c dialout render gpio spi; do
    getent group "$grp" >/dev/null && usermod -aG "$grp" kali
done

# NOTE: SSH authorized_keys are NOT baked into the image. The image stays
# generic/shareable (no personal credentials). Use `graft.sh deploy-ssh
# /dev/sdX` AFTER flashing to drop your pubkey on a specific card.
# Pre-create the .ssh dir with right perms so post-flash deploy is a one-liner.
install -d -m700 -okali -gkali /home/kali/.ssh

# Boot to graphical.target so display-manager.service (alias for lightdm)
# actually starts at boot. lightdm's [Install] section only declares
# WantedBy=graphical.target — a plain `systemctl enable lightdm` against
# multi-user.target as default goes nowhere (the sysv-install fallback
# fires, creates rc?.d symlinks, but systemd never pulls the unit). With
# graphical.target as default the display-manager.service symlink is
# honored and HDMI lights up automatically.
#
# APPLaunch on the LCD still owns the integrated keypad (Xorg ignores it
# via 40-cardputerzero-no-grab.conf), so HDMI session is for USB
# peripherals only. Costs ~50-80 MB at idle on the 415 MB usable CM0 —
# measured 164 MB free with desktop up, well above the thrashing zone.
systemctl set-default graphical.target
systemctl enable lightdm
systemctl enable zramswap

# pigpio is not packaged in Kali rolling (security posture — it relies on
# direct /dev/mem access). The launcher's GPIO app calls `pigs prs/pfs/p`,
# which require pigpiod + pigs. Those commands silently fail at runtime;
# the GPIO app's PWM tab won't drive anything. Documented in README under
# "Known upstream defects". Future fix: build pigpio from source, or port
# the GPIO app to libgpiod (which we install via the `gpiod` apt package).

# Hold the load-bearing firmware packages. Kali is rolling and users routinely
# `apt upgrade` — but raspi-firmware owns the GPU bootloader on the FAT, and
# firmware-brcm80211 / firmware-nexmon / kali-linux-firmware own the brcm/
# and cypress/ files stage_kernel overwrote with Raspberry Pi's CM0-correct
# set (BCM43439 NVRAM boardflags3=0x04000000). Kali's versions wedge the
# chip ("HT Avail timeout", no wlan0). The kernel packages themselves are
# held in stage_kernel. To deliberately refresh one:
#   sudo apt-mark unhold <pkg>; sudo apt install <pkg>; re-hold.
for pkg in raspi-firmware firmware-brcm80211 firmware-nexmon \
           firmware-misc-nonfree firmware-linux firmware-linux-nonfree \
           kali-linux-firmware linux-image-rpi-2712 linux-headers-rpi-2712; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed'; then
        apt-mark hold "$pkg"
    fi
done
ldconfig

# Disable glycin's image THUMBNAILERS + the SVG loader. Two related upstream
# glycin bugs bite this aarch64/Pi-Zero-2-W combo, both as bwrap+seccomp
# livelocks at 100% CPU:
#   1) glycin-svg livelocks single-shot — pcmanfm's desktop spawns it to
#      thumbnail one SVG icon and a render thread spins forever.
#   2) ANY glycin thumbnailer (image-rs, heif, jxl, svg) PILES UP when a file
#      manager browses a directory of images: one bwrap+loader is forked per
#      file, each wedges + holds ~50-60 MB, and on the 512 MB CM0 a few hundred
#      drives load past 20 and the OOM killer starts taking the desktop session
#      (pipewire/dbus/wireplumber) while the box thrashes for hours. Observed
#      live: a wardrive left running overnight pulled glycin-image-rs into this
#      pileup. Kismet survived (it's a system unit), but the desktop session
#      died and the UI falsely read "stopped".
# Fix: divert EVERY glycin thumbnailer (kills the pileup trigger) plus the svg
# *loader* conf.d (kills the single-shot icon livelock). The non-svg loader
# conf.d entries are left in place so glycin-image-rs still paints the JPEG
# wallpaper single-shot (it doesn't livelock that way; only repeated
# thumbnailing piles up). Diverts are durable across apt upgrades + reversible.
for f in $(ls /usr/share/thumbnailers/glycin-*.thumbnailer 2>/dev/null) \
         $(ls /usr/share/glycin-loaders/*/conf.d/glycin-svg.conf 2>/dev/null); do
    if [ -e "$f" ]; then
        dpkg-divert --rename --divert "$f.disabled" --add "$f" || true
    fi
done

# ── Memory diet: disable autostart bloat (~110 MB savings on the 415 MB CM0)
# Each unwanted .desktop gets a "Hidden=true" line appended, which suppresses
# the autostart per the FreeDesktop spec.
for f in \
    blueman.desktop \
    orca-autostart.desktop \
    onboard-autostart.desktop \
    geoclue-demo-agent.desktop \
    print-applet.desktop \
    polkit-mate-authentication-agent-1.desktop \
    xiccd.desktop \
    xcape-super-key-bind.desktop \
    org.gnome.SettingsDaemon.DiskUtilityNotify.desktop \
    xfce4-clipman-plugin-autostart.desktop \
    xfce4-notifyd.desktop \
    xfce4-power-manager.desktop \
    xfce4-screensaver.desktop \
    xfsettingsd.desktop \
    xfce-disable-motherboard-beep.desktop \
    pkcs11-register.desktop \
    gnome-keyring-pkcs11.desktop \
    gnome-keyring-secrets.desktop; do
    p=/etc/xdg/autostart/"$f"
    [ -f "$p" ] && ! grep -q "^Hidden=true" "$p" && echo "Hidden=true" >> "$p"
done

# Bluetooth stays ON (as on M5's image). The CM0's CYW4343A2 comes up as hci0,
# and APPLaunch polls org.bluez every 2 s for its settings page — masking
# bluetooth.service while Kali's dbus-org.bluez.service alias still points at
# it made every poll fail with "File exists" and flooded the user journal.
# Undo the mask older graft builds applied.
if [ "$(readlink /etc/systemd/system/bluetooth.service)" = /dev/null ]; then
    systemctl unmask bluetooth.service
fi
systemctl enable bluetooth.service

# ttyS0 is the LoRa+GNSS cap's UART (ATGM336H), so nothing may hold it at
# boot: no serial getty (masked here) and no kernel console (cmdline.txt has
# no console=serial0). M5's GPS app opens the port itself and refuses one
# that's assigned to a console.
systemctl mask serial-getty@ttyS0.service

# gpsd is socket-activated only: the daemon starts when a client (kismet,
# cgps, gpspipe) connects, and without -n it opens ttyS0 only while a client
# is watching. So the GPS app and gpsd clients can both use the cap, just not
# at the same moment. /etc/default/gpsd is written by stage_configs.
systemctl disable gpsd.service
systemctl enable gpsd.socket

# Override pcmanfm-desktop's wallpaper at the system-default level
# (/etc/xdg/pcmanfm/LXDE/pcmanfm.conf [desktop] section). The package default
# points at /etc/alternatives/desktop-background — which is a symlink chain
# pcmanfm-desktop fails to render on startup (silently falls back to solid
# black). Direct path avoids the alternatives indirection entirely.
PCMANFM_CONF=/etc/xdg/pcmanfm/LXDE/pcmanfm.conf
if [ -f "$PCMANFM_CONF" ]; then
    sed -i 's|^wallpaper=.*|wallpaper=/usr/share/backgrounds/kali/kali-glitch-16x9.jpg|' "$PCMANFM_CONF"
fi

# Default x-session-manager → LXDE (not XFCE). Affects `startx` from a tty
# login, lightdm's default greeter session pick, etc. Kali installs both
# desktop environments; xfce wins the alternative by default, but our
# default desktop is LXDE.
if [ -x /usr/bin/startlxde ]; then
    update-alternatives --set x-session-manager /usr/bin/startlxde 2>/dev/null || true
fi

# /etc/skel/.xsession: makes startx start LXDE for anyone newly-created
# via useradd -m (cloud-init or otherwise) without needing per-user shell access.
cat > /etc/skel/.xsession <<'EOF'
exec startlxde
EOF
chmod 755 /etc/skel/.xsession

# Also stamp the kali user's home (created earlier in this same chroot run)
cp /etc/skel/.xsession /home/kali/.xsession
chown kali:kali /home/kali/.xsession
chmod 755 /home/kali/.xsession

apt-get clean
rm -rf /var/lib/apt/lists/*

# Defensive: something in the chroot install (or our prior surgery) has been
# known to leave / at mode 700 in the resulting image, which prevents any
# non-root setuid traversal — every User= service fails with libselinux.so.1
# / EACCES cascades. Explicitly restore critical dir perms.
chmod 755 / /usr /usr/bin /usr/sbin /usr/lib /lib /etc /var /var/lib /run /home 2>/dev/null || true
# /tmp must be 1777 (sticky world-writable) — apt's _apt user mkstemp's here
# during package downloads, and so does /usr/bin/install -d for many .debs.
# A bare `chmod 755 /tmp` silently breaks the chroot's apt step on the next
# build with "Unable to mkstemp /tmp/apt.sig.* - GetTempFile (13: Permission
# denied)".
chmod 1777 /tmp 2>/dev/null || true
CHROOT

    mkdir -p "$KALI_ROOT${PACKAGES_STAMP%/*}"
    echo "$PACKAGES_REV" > "$KALI_ROOT$PACKAGES_STAMP"
    ok "Desktop stack installed (rev $PACKAGES_REV)"
}

# ── install_camera_libcamera: private Raspberry Pi libcamera for camera_app ─
#
# Unpacks CAMERA_DEBS into $RPI_LIBCAMERA_DIR (not into /usr: Kali's own
# libcamera0.7 stays installed and untouched), diverts /usr/bin/camera_app and
# puts a wrapper in its place that points the loader and libcamera's IPA /
# proxy / tuning / pipeline lookups at the private tree. The dpkg diversion
# survives Camera package upgrades.
install_camera_libcamera() {
    log "Camera: private Raspberry Pi libcamera in $RPI_LIBCAMERA_DIR"
    local stage="$KALI_ROOT/var/cache/cz-graft/camera" in_chroot=() url f
    rm -rf "${stage:?}"
    mkdir -p "$stage"
    while IFS='|' read -r url _; do
        [[ -z "$url" ]] && continue
        f=$(basename "$url")
        install -m644 "$CACHE/camera/$f" "$stage/"
        in_chroot+=("/var/cache/cz-graft/camera/$f")
    done <<< "$CAMERA_DEBS"

    run_chroot "${in_chroot[@]}" <<'CHROOT'
rm -rf "$RPI_LIBCAMERA_DIR"
mkdir -p "$RPI_LIBCAMERA_DIR"
for d in "$@"; do dpkg-deb -x "$d" "$RPI_LIBCAMERA_DIR"; done
rm -rf "$RPI_LIBCAMERA_DIR/usr/share/doc" "$RPI_LIBCAMERA_DIR/usr/share/lintian" /var/cache/cz-graft/camera
mkdir -p /usr/lib/cz-graft
dpkg-divert --local --rename --divert /usr/lib/cz-graft/camera_app.real --add /usr/bin/camera_app
CHROOT
    [[ -f "$KALI_ROOT/usr/lib/cz-graft/camera_app.real" ]] \
        || err "camera_app was not diverted to /usr/lib/cz-graft/camera_app.real"

    cat > "$KALI_ROOT/usr/bin/camera_app" <<EOF
#!/bin/sh
# graft.sh: run M5's CameraApp against Raspberry Pi's libcamera fork, kept in
# a private tree so Kali's own libcamera is left alone. Real binary is
# dpkg-diverted to /usr/lib/cz-graft/camera_app.real.
R=$RPI_LIBCAMERA_DIR
L=\$R/usr/lib/aarch64-linux-gnu
export LD_LIBRARY_PATH="\$L\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export LIBCAMERA_IPA_MODULE_PATH="\$L/libcamera/ipa"
export LIBCAMERA_IPA_PROXY_PATH="\$R/usr/libexec/aarch64-linux-gnu/libcamera"
export LIBCAMERA_IPA_CONFIG_PATH="\$R/usr/share/libcamera/ipa"
export LIBCAMERA_RPI_CONFIG_FILE="\${LIBCAMERA_RPI_CONFIG_FILE:-\$R/usr/share/libcamera/pipeline/rpi/vc4/rpi_apps.yaml}"
exec /usr/lib/cz-graft/camera_app.real "\$@"
EOF
    chmod 755 "$KALI_ROOT/usr/bin/camera_app"
    ok "camera_app wrapped onto $RPI_LIBCAMERA_DIR"
}

# ── stage_apps: APPLaunch + first-party apps, real apt install ──────────────
#
# Real `apt install` of the pinned .debs (postinst runs, dpkg registers it,
# dependencies resolve from Kali). APPLaunch's postinst enables its *user*
# unit for UID 1000 (kali) offline, into ~kali/.config/systemd/user/.
stage_apps() {
    log "Installing APPLaunch + first-party apps"

    grep -q '^kali:x:1000:' "$KALI_ROOT/etc/passwd" \
        || err "UID 1000 must be 'kali' before APPLaunch's postinst runs (it enables the launcher for UID 1000)"

    local stage="$KALI_ROOT/var/cache/cz-graft/apps" in_chroot=() slug url sha f
    rm -rf "${stage:?}"
    mkdir -p "$stage"
    while IFS='|' read -r slug url sha; do
        [[ -z "$slug" ]] && continue
        f=$(basename "$url")
        install -m644 "$CACHE/apps/$f" "$stage/"
        in_chroot+=("/var/cache/cz-graft/apps/$f")
    done <<< "${CZ_PREREQ_DEBS}${CZ_DEBS}"

    log "apt install: ${#in_chroot[@]} local .debs"
    run_chroot "${in_chroot[@]}" <<'CHROOT'
apt-get update
apt-get install -y --no-install-recommends "$@"
# Product default is ADB off (M5's pi-gen does the same after installing the
# launcher); the launcher postinst can enable its hotplug monitor.
systemctl disable cardputer-adb-hotplug.service adbd.service 2>/dev/null || true
rm -rf /var/cache/cz-graft/apps
apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOT

    # Start kali's user manager at boot even with nobody logged in. APPLaunch
    # is a user unit (WantedBy=default.target of the user manager); without
    # lingering it would only start once someone logs in — and tty1's old
    # autologin, which used to do that implicitly, is gone (stage_configs).
    mkdir -p "$KALI_ROOT/var/lib/systemd/linger"
    : > "$KALI_ROOT/var/lib/systemd/linger/kali"

    # APPLaunch races udev for the keypad's by-path symlink; libinput then
    # gets ENOENT and the keypad is lost for the session. Wait for it.
    mkdir -p "$KALI_ROOT/etc/systemd/user/APPLaunch.service.d"
    cat > "$KALI_ROOT/etc/systemd/user/APPLaunch.service.d/wait-for-udev.conf" <<'EOF'
[Unit]
After=systemd-udev-settle.service

[Service]
ExecStartPre=/bin/sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do [ -e /dev/input/by-path/platform-3f804000.i2c-event ] && exit 0; sleep 1; done; exit 0"
EOF
    # Older graft builds enabled APPLaunch globally; the launcher's postinst
    # now scopes it to UID 1000 — drop any stale global link.
    rm -f "$KALI_ROOT/etc/systemd/user/default.target.wants/APPLaunch.service"

    # M5's LCD→HDMI mirror: a GTK window on the LXDE desktop showing the LCD.
    install -m755 "$CACHE/pigen/fb-mirror.py"      "$KALI_ROOT/usr/bin/fb-mirror.py"
    install -m644 "$CACHE/pigen/fb-mirror.desktop" "$KALI_ROOT/usr/share/applications/fb-mirror.desktop"

    install_camera_libcamera

    ok "APPLaunch + apps installed; kali lingers so APPLaunch starts at boot"
}

stage_tweaks() {
    log "Post-install tweaks: NetworkManager, /etc/hosts, networking.service"

    # 1. NetworkManager: switch ifupdown integration to "managed" so NM owns
    #    eth0 at boot. Default is "managed=false", which leaves eth0 to
    #    ifupdown — but ifupdown's networking.service times out on its own
    #    lockfile at boot (USB-Ethernet enumerates too slowly to clear the
    #    15s ifup window). Switching to NM-managed gets eth0 up at boot.
    local nmconf="$KALI_ROOT/etc/NetworkManager/NetworkManager.conf"
    if [[ -f "$nmconf" ]] && grep -q '^managed=false' "$nmconf"; then
        [[ -f "$nmconf.kali" ]] || cp -a "$nmconf" "$nmconf.kali"
        sed -i 's/^managed=false/managed=true/' "$nmconf"
        ok "NM ifupdown integration → managed=true"
    fi

    # 2. Disable + mask networking.service (the legacy ifupdown unit that
    #    times out at boot — NM does the work now).
    ln -sf /dev/null "$KALI_ROOT/etc/systemd/system/networking.service"
    rm -f "$KALI_ROOT/etc/systemd/system/network-online.target.wants/networking.service" \
          "$KALI_ROOT/etc/systemd/system/multi-user.target.wants/networking.service"

    # 3. Hostname. Set directly: cloud-init never runs on this image, so a
    #    hostname in user-data would be ignored (it used to leave the device
    #    as Kali's stock "kali-raspberry-pi"). /etc/hosts gets the matching
    #    127.0.1.1 line, replacing Kali's, so sudo can resolve the host.
    echo "$CZ_HOSTNAME" > "$KALI_ROOT/etc/hostname"
    local hosts="$KALI_ROOT/etc/hosts"
    sed -i '/^127\.0\.1\.1[[:space:]]/d' "$hosts"
    echo "127.0.1.1	$CZ_HOSTNAME" >> "$hosts"

    # 4. First-boot rootfs grow. cloud-init is DISABLED on this image (its
    #    datasource is unreliable here — same reason we pre-bake the kali user),
    #    so cloud-init's growpart module never runs and the rootfs stays at the
    #    built image size instead of filling the SD card. Ship a tiny one-shot
    #    service that does growpart + resize2fs once on first boot, guarded by a
    #    sentinel so it never runs again. (growpart from cloud-guest-utils,
    #    installed in stage_packages; resize2fs + parted are in the base.)
    install -d -m755 "$KALI_ROOT/usr/local/sbin"
    cat > "$KALI_ROOT/usr/local/sbin/cz-firstboot-resize.sh" <<'RESIZE'
#!/bin/sh
# Grow the root partition + filesystem to fill the card, once, on first boot.
set -e
SENTINEL=/var/lib/cz-graft/.resized
[ -e "$SENTINEL" ] && exit 0
SRC=$(findmnt -no SOURCE /)
DISK=$(lsblk -no PKNAME "$SRC" 2>/dev/null)
PART=$(printf '%s' "$SRC" | grep -oE '[0-9]+$')
if [ -n "$DISK" ] && [ -n "$PART" ]; then
    growpart "/dev/$DISK" "$PART" || true   # extend the partition (online)
    resize2fs "$SRC" || true                # grow the ext4 (online, mounted /)
fi
mkdir -p "$(dirname "$SENTINEL")"
: > "$SENTINEL"
RESIZE
    chmod 755 "$KALI_ROOT/usr/local/sbin/cz-firstboot-resize.sh"
    cat > "$KALI_ROOT/etc/systemd/system/cz-firstboot-resize.service" <<'RUNIT'
[Unit]
Description=Grow root filesystem to fill the SD card (first boot)
Documentation=https://github.com/n0xa/M5CZ-Kali-Graft
ConditionPathExists=!/var/lib/cz-graft/.resized
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/cz-firstboot-resize.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
RUNIT
    mkdir -p "$KALI_ROOT/etc/systemd/system/multi-user.target.wants"
    ln -sf /etc/systemd/system/cz-firstboot-resize.service \
        "$KALI_ROOT/etc/systemd/system/multi-user.target.wants/cz-firstboot-resize.service"
    ok "First-boot rootfs-resize service installed + enabled"

    ok "Tweaks applied"
}


VERIFY_ERRS=0
vfail() { warn "$1"; VERIFY_ERRS=$((VERIFY_ERRS+1)); }

stage_verify() {
    log "Verifying image"
    chroot_down   # verify the image as it will boot (no chroot binds, no policy-rc.d)
    VERIFY_ERRS=0
    local f p kver

    # usrmerge intact (a real /lib directory is boot-fatal)
    [[ -L "$KALI_ROOT/lib" ]] || vfail "/lib is not a symlink (usrmerge broken)"
    [[ -L "$KALI_ROOT/lib/ld-linux-aarch64.so.1" ]] || vfail "ld-linux-aarch64.so.1 not reachable via /lib"

    # ── Kernel ────────────────────────────────────────────────────────────
    for f in kernel8.img initramfs8 bcm2710-rpi-cm0.dtb \
             overlays/vc4-kms-v3d.dtbo overlays/imx219.dtbo overlays/dwc2.dtbo \
             overlays/gpio-ir.dtbo overlays/gpio-ir-tx.dtbo \
             overlays/cardputerzero-v5-overlay.dtbo overlays/bq27220_v5.dtbo \
             overlays/bmi270_bmm150_overlay.dtbo splash.bmp; do
        [[ -f "$KALI_BOOT/$f" ]] || vfail "missing boot file: $f"
    done
    kver=$(kernel_img_version)
    if [[ "$kver" != "$KVER" ]]; then
        vfail "kernel8.img is '${kver:-unreadable}', expected $KVER"
    elif [[ ! -d "$KALI_ROOT/usr/lib/modules/$kver" ]]; then
        vfail "kernel8.img is $kver but rootfs has no /lib/modules/$kver — image boots with NO drivers"
    else
        ok "kernel8.img $kver matches /lib/modules/$kver"
    fi
    for p in $KERNEL_HOLD_PKGS raspi-firmware; do
        dpkg_held "$p" || vfail "$p not installed+held (apt upgrade could swap the kernel/firmware)"
    done
    # Whichever packages own the brcm/cypress files (firmware-nexmon on Kali,
    # firmware-brcm80211 on Debian/RPi OS) must be held, or an upgrade puts
    # back an NVRAM that wedges the BCM43439.
    for p in firmware-brcm80211 firmware-nexmon kali-linux-firmware; do
        dpkg_installed "$p" && ! dpkg_held "$p" && vfail "$p installed but not held (apt upgrade could replace the CM0 NVRAM)"
    done
    dpkg_installed brcmfmac-nexmon-dkms && vfail "brcmfmac-nexmon-dkms still installed (would shadow in-tree brcmfmac)"
    find "$KALI_ROOT/usr/lib/modules/$KVER" -path '*updates*' -name 'brcmfmac.ko*' 2>/dev/null | grep -q . \
        && vfail "a DKMS brcmfmac.ko exists for $KVER (would shadow the in-tree driver the CM0 WiFi needs)"

    # ── Config / cmdline ──────────────────────────────────────────────────
    for p in cardputerzero-v5-overlay bq27220_v5 bmi270_bmm150_overlay vc4-kms-v3d; do
        grep -q "^dtoverlay=$p\$" "$KALI_BOOT/config.txt" || vfail "dtoverlay=$p not in config.txt"
    done
    ! grep -q '^kernel=' "$KALI_BOOT/config.txt" || vfail "config.txt overrides kernel= (should boot kernel8.img)"
    grep -q 'root=PARTUUID='   "$KALI_BOOT/cmdline.txt" || vfail "cmdline.txt has no root=PARTUUID"
    grep -qw 'fbcon=map:99'    "$KALI_BOOT/cmdline.txt" || vfail "cmdline.txt missing fbcon=map:99 (console would paint over APPLaunch)"
    grep -qw 'quiet'           "$KALI_BOOT/cmdline.txt" || vfail "cmdline.txt missing 'quiet'"
    ! grep -qE 'console=(serial0|ttyS0)' "$KALI_BOOT/cmdline.txt" \
        || vfail "cmdline.txt puts a console on ttyS0 (the GPS app refuses a console UART)"

    # ── Cardputer Zero drivers ────────────────────────────────────────────
    for p in panel-mipi-dbi-m st7789v_m5stack pwm_bl_m5stack tca8418_keypad_m5stack \
             es8389_m5stack bq27xxx_battery bq27xxx_battery_i2c m5ioe1 \
             gpio-forwarder cardputerzero-audio powerfail_suo; do
        [[ -f "$KALI_ROOT/usr/lib/modules/$KVER/extra/$p.ko" ]] || vfail "CZ module missing: $p.ko"
    done
    find "$KALI_ROOT/usr/lib/modules/$KVER/extra" -name 'bmi270*.ko' 2>/dev/null | grep -q . \
        || vfail "BMI270 IMU module missing"
    grep -q 'extra/panel-mipi-dbi-m.ko' "$KALI_ROOT/usr/lib/modules/$KVER/modules.dep" 2>/dev/null \
        || vfail "depmod didn't index the CZ modules for $KVER"
    [[ -f "$KALI_ROOT/usr/lib/firmware/cardputerzero,st7789v_lcd.bin" ]] \
        || vfail "panel init firmware missing (backlight on, nothing renders)"
    [[ -f "$KALI_ROOT/usr/lib/firmware/bmi270-init-data.fw" ]] || vfail "bmi270-init-data.fw missing"
    grep -qx 'panel_mipi_dbi_m' "$KALI_ROOT/etc/modules-load.d/cardputerzero-panel.conf" 2>/dev/null \
        || vfail "panel_mipi_dbi_m not forced via modules-load.d"
    grep -qx 'i2c-dev' "$KALI_ROOT/etc/modules-load.d/i2c-dev.conf" 2>/dev/null \
        || vfail "i2c-dev not in modules-load.d (APPLaunch battery calibration needs /dev/i2c-1)"
    for f in etc/udev/rules.d/99-cardputer-zero-lcd.rules \
             etc/udev/rules.d/99-cardputer-zero-keyboard.rules \
             etc/udev/rules.d/99-ignore-i2c-key.rules \
             usr/lib/udev/rules.d/zz-cardputerzero-hdmi-display.rules \
             usr/lib/udev/rules.d/60-cardputerzero-leds.rules \
             usr/lib/tmpfiles.d/cardputerzero-leds.conf; do
        [[ -f "$KALI_ROOT/$f" ]] || vfail "missing $f"
    done
    [[ -x "$KALI_ROOT/usr/sbin/fb_load" ]] || vfail "fb_load binary missing"
    [[ -L "$KALI_ROOT/etc/systemd/system/sysinit.target.wants/fb_load.service" ]] \
        || vfail "fb_load.service not enabled"
    for p in gpio input video audio i2c spi dialout; do
        grep "^$p:" "$KALI_ROOT/etc/group" | grep -q '\bkali\b' \
            || vfail "kali not in $p group (APPLaunch runs as kali and needs it)"
    done
    # A udev GROUP= naming a group that doesn't exist silently leaves the node
    # root:root 0600 (that's how spidev broke LoRa). Check every one.
    local g
    for g in $(grep -hoE 'GROUP="[a-z_-]+"' "$KALI_ROOT"/usr/lib/udev/rules.d/*.rules \
                   "$KALI_ROOT"/etc/udev/rules.d/*.rules 2>/dev/null | cut -d'"' -f2 | sort -u); do
        grep -q "^$g:" "$KALI_ROOT/etc/group" || vfail "udev rules use GROUP=\"$g\" but the group doesn't exist"
    done

    # ── CM0 WiFi firmware ─────────────────────────────────────────────────
    grep -q '^boardflags3=0x04000000' "$KALI_ROOT/usr/lib/firmware/cypress/cyfmac43439-sdio.txt" 2>/dev/null \
        || vfail "BCM43439 NVRAM missing or wrong boardflags3 (need 0x04000000)"
    [[ -e "$KALI_ROOT/usr/lib/firmware/brcm/brcmfmac43439-sdio.raspberrypi,0-compute-module.bin" ]] \
        || vfail "CM0 brcmfmac43439 firmware link missing/dangling"

    # ── Consoles: tty1 dead, HDMI consoles on tty2..6 ─────────────────────
    for u in getty@tty1.service autovt@tty1.service; do
        [[ "$(readlink "$KALI_ROOT/etc/systemd/system/$u" 2>/dev/null)" == "/dev/null" ]] \
            || vfail "$u not masked (keypad would type into a tty1 shell)"
    done
    [[ ! -e "$KALI_ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" ]] \
        || vfail "stale tty1 autologin drop-in present"
    [[ -x "$KALI_ROOT/usr/local/sbin/cz-hdmi-console" ]] || vfail "cz-hdmi-console missing"
    [[ -f "$KALI_ROOT/etc/udev/rules.d/90-cz-hdmi-console.rules" ]] || vfail "90-cz-hdmi-console.rules missing"
    [[ -x "$KALI_ROOT/usr/bin/con2fbmap" ]] || vfail "con2fbmap missing (fbset) — HDMI consoles would be blank"

    # ── APPLaunch + apps ──────────────────────────────────────────────────
    [[ -x "$KALI_ROOT/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch" ]] || vfail "APPLaunch binary missing"
    dpkg_installed applaunch || vfail "applaunch not dpkg-registered"
    [[ -L "$KALI_ROOT/home/kali/.config/systemd/user/default.target.wants/APPLaunch.service" ]] \
        || vfail "APPLaunch user unit not enabled for kali"
    [[ -f "$KALI_ROOT/var/lib/systemd/linger/kali" ]] \
        || vfail "kali not lingering (APPLaunch would not start at boot)"
    [[ -f "$KALI_ROOT/etc/systemd/user/APPLaunch.service.d/wait-for-udev.conf" ]] \
        || vfail "APPLaunch udev-wait drop-in missing"
    [[ -f "$KALI_ROOT/usr/lib/systemd/user/pipewire-pulse.service" ]] \
        || vfail "pipewire-pulse user unit missing (APPLaunch Wants= it; audio apps need it)"
    [[ -x "$KALI_ROOT/usr/bin/camera_app" ]] || vfail "camera_app missing"
    grep -q "$RPI_LIBCAMERA_DIR" "$KALI_ROOT/usr/bin/camera_app" 2>/dev/null \
        || vfail "/usr/bin/camera_app is not the private-libcamera wrapper (app dies at symbol lookup on Kali's libcamera)"
    [[ -x "$KALI_ROOT/usr/lib/cz-graft/camera_app.real" ]] || vfail "diverted camera_app.real missing"
    for f in usr/lib/aarch64-linux-gnu/libcamera.so.0.7 \
             usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_rpi_vc4.so \
             usr/lib/aarch64-linux-gnu/libtensorflow-lite.so.2.20.0 \
             usr/lib/aarch64-linux-gnu/libboost_log.so.1.83.0 \
             usr/libexec/aarch64-linux-gnu/libcamera/raspberrypi_ipa_proxy \
             usr/share/libcamera/ipa/rpi/vc4/imx219.json \
             usr/share/libcamera/pipeline/rpi/vc4/rpi_apps.yaml; do
        [[ -e "$KALI_ROOT$RPI_LIBCAMERA_DIR/$f" ]] || vfail "private libcamera tree missing $f"
    done
    [[ -f "$KALI_ROOT/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc" ]] \
        || vfail "NotoSansCJK fonts missing (CZ apps load them by path)"
    local slug bin
    while IFS='|' read -r slug bin; do
        [[ -z "$slug" ]] && continue
        [[ -f "$KALI_ROOT/usr/share/APPLaunch/applications/$slug.desktop" ]] || vfail "$slug.desktop missing"
        [[ -x "$KALI_ROOT/$bin" ]] || vfail "$bin missing"
    done <<'EOF'
camera_app|usr/bin/camera_app
music|usr/share/APPLaunch/bin/M5CardputerZero-Music
piano|usr/share/APPLaunch/bin/M5CardputerZero-Piano
compass|usr/share/APPLaunch/bin/M5CardputerZero-Compass
ir-chat|usr/share/APPLaunch/bin/M5CardputerZero-IR-Chat
ir-remote|usr/share/APPLaunch/bin/M5CardputerZero-IR-Remote
cap-cc1101-nfc|usr/share/APPLaunch/bin/M5CardputerZero-Cap-CC1101-NFC
cap-cc1101-subg-chat|usr/share/APPLaunch/bin/M5CardputerZero-Cap-CC1101-SubG-Chat
recorder|usr/share/APPLaunch/bin/M5CardputerZero-Recorder
files|usr/share/APPLaunch/bin/M5CardputerZero-Files
cap-lora-1262|usr/share/Cap-LoRa-1262/bin/Cap-LoRa-1262
cap-lora-1262-gps|usr/share/APPLaunch/bin/M5CardputerZero-Cap-LoRa-1262-GPS
keyboard-guide|usr/share/APPLaunch/bin/M5CardputerZero-Keyboard-Guide
EOF
    [[ -x "$KALI_ROOT/usr/bin/fb-mirror.py" ]] || vfail "fb-mirror.py missing"

    # ── USB WiFi (Realtek DKMS, patched for 6.18) ─────────────────────────
    find "$KALI_ROOT/usr/lib/modules/$KVER" -name '88XXau.ko*' -path '*/updates/dkms/*' 2>/dev/null | grep -q . \
        || vfail "88XXau.ko missing for $KVER (AWUS036ACS won't work)"
    grep -q 'blacklist rtw88_8821au' "$KALI_ROOT/etc/modprobe.d/rtw88-dkms-override.conf" 2>/dev/null \
        || vfail "rtw88-dkms-override.conf missing — rtw88_8821au would claim AWUS036ACS"
    [[ -f "$KALI_ROOT/etc/modules-load.d/rtw88xxau.conf" ]] || vfail "rtw88xxau.conf missing"
    [[ -f "$KALI_ROOT/etc/udev/rules.d/99-rtw88xxau.rules" ]] || vfail "99-rtw88xxau.rules missing"

    # ── Desktop + system configs ──────────────────────────────────────────
    grep -q 'slave.pcm "hw:1,0"' "$KALI_ROOT/etc/asound.conf" 2>/dev/null \
        || vfail "asound.conf missing or not routed at hw:1,0"
    grep -q '^DEVICES="/dev/ttyS0"' "$KALI_ROOT/etc/default/gpsd" 2>/dev/null \
        || vfail "/etc/default/gpsd not pointed at /dev/ttyS0"
    [[ "$(readlink "$KALI_ROOT/etc/systemd/system/serial-getty@ttyS0.service" 2>/dev/null)" == "/dev/null" ]] \
        || vfail "serial-getty@ttyS0 not masked (steals ttyS0 from the GPS cap)"
    ! grep -q -- '-n' <<< "$(grep '^GPSD_OPTIONS' "$KALI_ROOT/etc/default/gpsd" 2>/dev/null)" \
        || vfail "gpsd runs with -n (would hold ttyS0 permanently and lock out the GPS app)"
    [[ ! -e "$KALI_ROOT/etc/systemd/system/multi-user.target.wants/gpsd.service" ]] \
        || vfail "gpsd.service enabled at boot (should be socket-activated only)"
    [[ -L "$KALI_ROOT/etc/systemd/system/sockets.target.wants/gpsd.socket" ]] || vfail "gpsd.socket not enabled"
    grep -q '^GLYCIN_SANDBOX_MECHANISM=not-sandboxed' "$KALI_ROOT/etc/environment" 2>/dev/null \
        || vfail "GLYCIN_SANDBOX_MECHANISM missing from /etc/environment"
    grep -qE '^xset -dpms' "$KALI_ROOT/etc/xdg/lxsession/LXDE/autostart" 2>/dev/null \
        || vfail "LXDE autostart missing 'xset -dpms'"
    [[ "$(readlink "$KALI_ROOT/etc/systemd/system/default.target" 2>/dev/null)" =~ graphical\.target$ ]] \
        || vfail "default.target is not graphical.target (lightdm won't auto-start)"
    [[ -x "$KALI_ROOT/usr/bin/lxsession" ]] || vfail "lxsession not installed"
    [[ -x "$KALI_ROOT/usr/lib/lightdm-autologin-greeter/lightdm-autologin-greeter" ]] \
        || vfail "lightdm-autologin-greeter not installed"
    [[ -f "$KALI_ROOT/etc/lightdm/lightdm.conf.d/lightdm-autologin-greeter.conf" ]] \
        || vfail "lightdm autologin conf missing"
    [[ -L "$KALI_ROOT/etc/systemd/system/multi-user.target.wants/zramswap.service" ]] \
        || vfail "zramswap.service not enabled"
    grep -q '^PERCENT=75' "$KALI_ROOT/etc/default/zramswap" 2>/dev/null || vfail "zramswap PERCENT not 75"
    [[ -f "$KALI_ROOT/etc/systemd/system/dbus.service.d/workdir.conf" ]] \
        || vfail "dbus.service WorkingDirectory drop-in missing"
    [[ "$(readlink "$KALI_ROOT/etc/systemd/system/bluetooth.service" 2>/dev/null)" != "/dev/null" ]] \
        || vfail "bluetooth.service masked (APPLaunch's bluez polling floods the journal)"
    [[ "$(cat "$KALI_ROOT/etc/hostname" 2>/dev/null)" == "$CZ_HOSTNAME" ]] \
        || vfail "/etc/hostname is not $CZ_HOSTNAME"
    [[ -f "$KALI_ROOT/etc/X11/xorg.conf.d/40-cardputerzero-no-grab.conf" ]] \
        || vfail "Xorg ignore-keypad config missing"
    [[ -f "$KALI_ROOT/etc/X11/xorg.conf.d/98-vc4-no-glamor.conf" ]] \
        || vfail "Xorg no-glamor config missing"
    grep -q '^wallpaper=/usr/share/backgrounds/kali/' "$KALI_ROOT/etc/xdg/pcmanfm/LXDE/pcmanfm.conf" 2>/dev/null \
        || vfail "pcmanfm.conf wallpaper not pointing at Kali bg"
    [[ -x "$KALI_ROOT/usr/local/sbin/cz-firstboot-resize.sh" ]] || vfail "cz-firstboot-resize.sh missing"
    [[ -L "$KALI_ROOT/etc/systemd/system/multi-user.target.wants/cz-firstboot-resize.service" ]] \
        || vfail "cz-firstboot-resize.service not enabled"
    [[ -x "$KALI_ROOT/usr/bin/growpart" ]] || vfail "growpart missing (cloud-guest-utils)"
    grep -q '^managed=true' "$KALI_ROOT/etc/NetworkManager/NetworkManager.conf" 2>/dev/null \
        || vfail "NM ifupdown managed=true not set"
    [[ "$(readlink "$KALI_ROOT/etc/systemd/system/networking.service" 2>/dev/null)" == "/dev/null" ]] \
        || vfail "networking.service not masked"
    grep -qE "^127\.0\.1\.1[[:space:]]+$CZ_HOSTNAME\b" "$KALI_ROOT/etc/hosts" \
        || vfail "/etc/hosts missing $CZ_HOSTNAME"
    [[ ! -e "$KALI_ROOT/usr/sbin/policy-rc.d" ]] || vfail "policy-rc.d left behind (services would never start)"

    # / or other key dirs at mode 700 silently breaks every non-root service.
    local d mode
    for d in / /usr /usr/bin /usr/sbin /usr/lib /lib /etc /var /var/lib /run /home; do
        mode=$(stat -L -c '%a' "$KALI_ROOT$d" 2>/dev/null) || continue
        [[ "$mode" == "755" || "$mode" == "555" ]] || vfail "$d has mode $mode (must be 755)"
    done
    mode=$(stat -L -c '%a' "$KALI_ROOT/tmp" 2>/dev/null)
    [[ "$mode" == "1777" ]] || vfail "/tmp has mode $mode (must be 1777)"

    if (( VERIFY_ERRS == 0 )); then
        ok "All checks passed"
    else
        err "$VERIFY_ERRS check(s) failed"
    fi
}

stage_shell() {
    log "Dropping into interactive shell. Type 'exit' to unmount & clean up."
    dim "kali_boot=$KALI_BOOT  kali_root=$KALI_ROOT   (chroot in: sudo chroot $KALI_ROOT)"
    chroot_up
    PS1='\[\033[1;35m\][graft]\[\033[0m\] \w \$ ' bash --norc -i
}

stage_fresh() {
    log "Removing $OUT_IMG (will be re-decompressed on next run)"
    rm -f "$OUT_IMG" "$OUT_IMG.grown"
    ok "Fresh start ready"
}

# ── stage_deploy_ssh: drop a pubkey into a flashed SD card ─────────────────
#
# Usage: sudo DEPLOY_SSH_DEV=/dev/sdX [DEPLOY_SSH_PUBKEY=key.pub] ./graft.sh deploy-ssh
#
# Mounts /dev/sdX's rootfs partition (always p2 for our layout), writes the
# pubkey into /home/kali/.ssh/authorized_keys, unmounts. No personal creds
# touch the .img file itself — image stays generic.
stage_deploy_ssh() {
    local target_dev="${DEPLOY_SSH_DEV:-}"
    local pubkey_file="${DEPLOY_SSH_PUBKEY:-}"

    [[ -n "$target_dev" ]] \
        || err "deploy-ssh needs a target device. Usage: DEPLOY_SSH_DEV=/dev/sdX sudo ./graft.sh deploy-ssh"
    [[ -b "$target_dev" ]] \
        || err "Not a block device: $target_dev"

    # Pubkey resolution: env var > arg > host's id_ed25519.pub
    if [[ -z "$pubkey_file" ]]; then
        for cand in "$HOME/.ssh/id_ed25519.pub" /home/axon/.ssh/id_ed25519.pub; do
            [[ -f "$cand" ]] && { pubkey_file=$cand; break; }
        done
    fi
    [[ -f "$pubkey_file" ]] \
        || err "No pubkey found. Set DEPLOY_SSH_PUBKEY=/path/to/key.pub"

    log "Deploying $(basename "$pubkey_file") to kali user on $target_dev"

    local mnt
    mnt=$(mktemp -d -p /mnt deploy-ssh.XXXXXX)
    mount "${target_dev}2" "$mnt"
    if ! grep -q '^kali:' "$mnt/etc/passwd"; then
        umount "$mnt"; rmdir "$mnt"
        err "No kali user in target rootfs — re-run packages stage first"
    fi

    install -d -m700 "$mnt/home/kali/.ssh"
    cp "$pubkey_file" "$mnt/home/kali/.ssh/authorized_keys"
    chmod 600 "$mnt/home/kali/.ssh/authorized_keys"
    # Use the target's kali UID/GID (1000:1000 — pre-baked by stage_packages)
    chown 1000:1000 "$mnt/home/kali/.ssh/authorized_keys"
    chown 1000:1000 "$mnt/home/kali/.ssh"

    sync
    umount "$mnt"; rmdir "$mnt"
    ok "Pubkey deployed to $target_dev (kali user)"
    dim "Card safe to pull and boot — ssh kali@<ip> will work key-only."
}


# ── stage_flash: write OUT_IMG to a removable card ──────────────────────────
# Usage: sudo FLASH_DEV=/dev/sdX ./graft.sh flash
# Refuses anything that isn't a whole, removable/USB/MMC disk with no mounted
# partitions, that holds the host's root, or that is smaller than the image.
stage_flash() {
    local dev="${FLASH_DEV:-}"
    [[ -n "$dev" ]] || err "flash needs FLASH_DEV=/dev/sdX"
    [[ -b "$dev" ]] || err "Not a block device: $dev"
    [[ -f "$OUT_IMG" ]] || err "No image to flash: $OUT_IMG"
    [[ "$(lsblk -dno TYPE "$dev")" == "disk" ]] || err "$dev is not a whole disk"

    local rm_flag tran model size img_size rootdisk
    rm_flag=$(lsblk -dno RM "$dev" | tr -d ' ')
    tran=$(lsblk -dno TRAN "$dev" | tr -d ' ')
    model=$(lsblk -dno MODEL "$dev" | sed 's/ *$//')
    [[ "$rm_flag" == "1" || "$tran" == "usb" || "$tran" == "mmc" ]] \
        || err "Refusing: $dev is not removable/USB/MMC (RM=$rm_flag TRAN=$tran)"
    rootdisk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1)
    [[ "/dev/$rootdisk" != "$dev" ]] || err "Refusing: $dev holds the host's root filesystem"
    if lsblk -nro MOUNTPOINTS "$dev" | grep -q .; then
        err "Refusing: $dev has mounted partitions — unmount them first"
    fi
    size=$(blockdev --getsize64 "$dev")
    img_size=$(stat -c%s "$OUT_IMG")
    (( size > 0 )) || err "$dev reports 0 bytes — is a card inserted?"
    (( size >= img_size )) \
        || err "$dev is $((size/1000000000)) GB, image is $((img_size/1000000000)) GB — use a bigger card or a smaller GROW_GB"

    cleanup   # the image must not be loop-mounted while we read it
    log "Writing $(basename "$OUT_IMG") → $dev (${model:-?}, $((size/1000000000)) GB)"
    dd if="$OUT_IMG" of="$dev" bs=4M status=progress conv=fsync oflag=direct
    sync
    partprobe "$dev" 2>/dev/null || true
    ok "Flashed $dev"
    dim "Optional: sudo DEPLOY_SSH_DEV=$dev ./graft.sh deploy-ssh"
}

# ── stage_drift: are our pins behind upstream? (informational) ─────────────
stage_drift() {
    log "Comparing pins against upstream"
    local rel ver latest_kali
    rel=$(curl -fsSL --max-time 30 https://api.github.com/repos/CardputerZero/pi-gen/releases/latest 2>/dev/null \
          | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d["tag_name"]); print(d.get("body",""))' 2>/dev/null) \
        || { warn "GitHub unreachable — skipping"; return 0; }
    dim "M5 latest stable image: $(head -1 <<< "$rel")"
    grep -E 'Launcher|Kernel|Driver overlay' <<< "$rel" | sed 's/^/      /' >&2 || true

    ver=$(grep -oE 'applaunch_[0-9.]+' <<< "$CZ_DEBS" | head -1 | sed 's/applaunch_//')
    grep -q "APPLaunch): $ver\b" <<< "$rel" \
        && ok "launcher pin $ver matches" || warn "launcher pin $ver differs from M5's stable image"
    grep -q "Kernel: 1:${KVER%%+*}-" <<< "$rel" \
        && ok "kernel pin ${KVER%%+*} matches" || warn "kernel pin ${KVER%%+*} differs from M5's stable image"
    grep -q "dtoverlays @ ${DTOVERLAYS_COMMIT:0:7}" <<< "$rel" \
        && ok "dtoverlays pin ${DTOVERLAYS_COMMIT:0:7} matches" || warn "dtoverlays pin ${DTOVERLAYS_COMMIT:0:7} differs from M5's stable image"

    latest_kali=$(curl -fsSL --max-time 30 https://kali.download/arm-images/ 2>/dev/null \
                  | grep -oE 'kali-20[0-9]+\.[0-9]+' | sort -uV | tail -1 | sed 's/kali-//')
    if [[ -n "$latest_kali" ]]; then
        [[ "$latest_kali" == "$KALI_VER" ]] && ok "Kali $KALI_VER is the latest ARM release" \
            || warn "Kali $latest_kali is out (pinned: $KALI_VER)"
    fi
}

stage_summary() {
    sync
    log "Summary"
    dim "Image:    $OUT_IMG ($(du -h --apparent-size "$OUT_IMG" | cut -f1))"
    dim "PARTUUID: $(blkid -s PARTUUID -o value "${KALI_LOOP}p2" 2>/dev/null || echo "?")"
    echo
    echo "To flash:  sudo FLASH_DEV=/dev/sdX ./graft.sh flash"
    echo "Then:      sudo DEPLOY_SSH_DEV=/dev/sdX ./graft.sh deploy-ssh   (optional)"
    echo
    echo "On the device: LCD = APPLaunch, HDMI = LXDE (autologin kali)."
    echo "Ctrl-Alt-F2 on a USB keyboard = text login on HDMI; Alt-F7 = back to the desktop."
}

# ─── Main ────────────────────────────────────────────────────────────────────

show_help() {
    sed -n '2,/^set -euo pipefail/{/^set -euo/d;s/^# \{0,1\}//;p}' "$0"
    cat <<'HELP'
Environment overrides:
  KALI_VER / KALI_URL / KALI_SHA256 / KALI_XZ   Kali base image (default 2026.3)
  OUT_IMG          output .img (default: KALI_XZ minus .xz)
  CACHE            download cache (default: ./cache)
  DTOVERLAYS_COMMIT  m5stack-linux-dtoverlays commit to build
  CZ_HOSTNAME      hostname (default: cardputerzero-kali)
  GROW_GB          extra GiB added to the rootfs (default: 4)
  FLASH_DEV        target card for `flash`
  DEPLOY_SSH_DEV / DEPLOY_SSH_PUBKEY   target + key for `deploy-ssh`
HELP
}

case "${1:-}" in
    -h|--help|help) show_help; exit 0 ;;
esac

require_root "$@"

STAGES=("$@")
[[ ${#STAGES[@]} -gt 0 ]] || STAGES=(all)

# Each stage pulls in what it needs to have the image mounted.
prep() { stage_check; stage_fetch; stage_unxz; stage_resize; stage_mount; }

run_stage() {
    case "$1" in
        check)      stage_check ;;
        fetch)      stage_check; stage_fetch ;;
        unxz)       stage_check; stage_fetch; stage_unxz ;;
        resize)     stage_check; stage_fetch; stage_unxz; stage_resize ;;
        mount)      prep ;;
        kernel)     prep; stage_kernel ;;
        drivers)    prep; stage_drivers ;;
        boot)       prep; stage_boot ;;
        configs)    prep; stage_configs ;;
        packages)   prep; stage_packages ;;
        apps)       prep; stage_apps ;;
        tweaks)     prep; stage_tweaks ;;
        verify)     prep; stage_verify ;;
        shell)      prep; stage_shell ;;
        flash)      stage_flash ;;
        deploy-ssh) stage_deploy_ssh ;;
        drift)      stage_drift ;;
        fresh)      cleanup; stage_fresh ;;
        all)
            prep
            stage_kernel
            stage_drivers
            stage_boot
            stage_configs
            stage_packages
            stage_apps
            stage_tweaks
            stage_verify
            stage_summary
            ;;
        *) err "Unknown stage: $1 (try: $0 --help)" ;;
    esac
}

for s in "${STAGES[@]}"; do run_stage "$s"; done
