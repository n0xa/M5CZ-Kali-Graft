#!/usr/bin/env bash
# graft.sh — assemble a Kali arm64 image that runs APPLaunch on the M5 Cardputer Zero LCD.
#
# Stages (run any subset; default is "all"):
#   check     | verify host tooling + input images exist
#   donor     | fetch + decompress the OEM CZ image (skip if CZ_IMG present)
#   unxz      | decompress Kali base .xz (skip if .img exists)
#   resize    | grow Kali rootfs by $GROW_GB (skip if already grown)
#   mount     | loop-attach + mount both images (CZ ro, Kali rw)
#   boot      | transplant kernel/dtb/overlays + write merged config.txt/cmdline.txt/user-data
#   rootfs    | copy CZ kernel modules + CM0 BCM firmware blobs
#   applaunch | install APPLaunch from the donor's .deb (carefully — see /lib symlink note)
#   verify    | sanity-check the result
#   shell     | mount everything and drop into an interactive bash for tinkering
#   fresh     | delete the current .img so the next run starts from .xz
#
# Examples:
#   sudo ./graft.sh                            # run everything (will fetch OEM donor on first run)
#   sudo ./graft.sh boot verify                # re-do just the boot partition + verify
#   sudo ./graft.sh shell                      # mount + interactive subshell
#   sudo CZ_HOSTNAME=cz-test ./graft.sh boot   # custom hostname
#   sudo APPLAUNCH_DEB=/path/to/new.deb ./graft.sh applaunch  # swap APPLaunch build
#   sudo CZ_IMG=/path/to/CardputerZero.img ./graft.sh         # use a field-customized donor
#
# Environment overrides (defaults resolve against the script dir; large
# binary inputs/outputs live alongside graft.sh and are ignored by git):
#   CZ_IMG          path to decompressed donor .img (default: $SCRIPT_DIR/cardputerzero-trixie-arm64-latest.img)
#   CZ_XZ           path to donor .img.xz (default: $SCRIPT_DIR/cardputerzero-trixie-arm64-latest.img.xz)
#   CZ_URL          URL to fetch CZ_XZ from if absent (default: M5Stack OSS bucket)
#   KALI_XZ         path to kali-…-arm64.img.xz source (default: $SCRIPT_DIR/kali-linux-2026.1-raspberry-pi-arm64.img.xz)
#   OUT_IMG         path to the produced .img (defaults to KALI_XZ minus .xz)
#   APPLAUNCH_DEB   path to applaunch_*.deb (defaults: most recent $SCRIPT_DIR/applaunch_*.deb, else donor's bundled one)
#   LAUNCHER_SRC    path to the M5CardputerZero-Launcher source tree (default: $SCRIPT_DIR/M5CardputerZero-Launcher, then $SCRIPT_DIR/../M5CardputerZero-Launcher)
#   CZ_HOSTNAME     hostname to set in cloud-init user-data (default: cardputerzero-kali)
#   GROW_GB         extra GiB to add to rootfs (default: 4)

set -euo pipefail

# ─── Paths & defaults ────────────────────────────────────────────────────────
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Donor: M5Stack's OEM CardputerZero OS image (Debian Trixie arm64).
# M5's "…-latest.img.xz" is a MOVING pointer — building against it blind is how
# we shipped a kernel/modules-skewed image (a silent kernel bump). So we PIN to
# a specific OSS object version (versionId), which is reproducible and notes
# exactly which upstream image we recalibrated against. `graft.sh drift` compares
# the pin to current latest and flags when M5 publishes a new one.
# To use a hand-modified donor (e.g. a dd of a tinkered-on CZ SD card), set CZ_IMG.
CZ_BASE_URL="${CZ_BASE_URL:-https://cardputer-zero-repo.oss-cn-shenzhen.aliyuncs.com/cardputerzero-trixie-arm64-latest.img.xz}"
# Pinned donor version. Bump deliberately when recalibrating to a newer image
# (get the new id from: curl -sI <CZ_BASE_URL> | grep -i x-oss-version-id).
#   pinned: 2026-06-08 publish — kernel 6.18.33+rpt-rpi-v8
CZ_VERSION_ID="${CZ_VERSION_ID:-CAEQjAEYgYDApKSfmfUZIiAwNzNhNWNmZWU5YjE0NWU3ODE1MDE0YjE1MzY2MjBhMA--}"
CZ_URL="${CZ_URL:-${CZ_BASE_URL}?versionId=${CZ_VERSION_ID}}"
CZ_XZ="${CZ_XZ:-$SCRIPT_DIR/cardputerzero-trixie-arm64-latest.img.xz}"
CZ_IMG="${CZ_IMG:-${CZ_XZ%.xz}}"

KALI_XZ="${KALI_XZ:-$SCRIPT_DIR/kali-linux-2026.1-raspberry-pi-arm64.img.xz}"
OUT_IMG="${OUT_IMG:-${KALI_XZ%.xz}}"

# zeroclaw — Apache-2.0 AI agent CLI from https://github.com/zeroclaw-labs/zeroclaw.
# APPLaunch's Claw app shells out to /home/pi/zeroclaw, but the binary doesn't
# ship with M5Stack's OEM image — beta testers are expected to install it.
# Pinned version + SHA so the build is reproducible; bump as needed.
ZEROCLAW_VER="${ZEROCLAW_VER:-v0.7.5}"
ZEROCLAW_TGZ_NAME="zeroclaw-aarch64-unknown-linux-gnu.tar.gz"
ZEROCLAW_URL="${ZEROCLAW_URL:-https://github.com/zeroclaw-labs/zeroclaw/releases/download/${ZEROCLAW_VER}/${ZEROCLAW_TGZ_NAME}}"
ZEROCLAW_SHA256="${ZEROCLAW_SHA256:-0b1197f1d80243e5c748b63a550cc6dfc37e407c4d15f729b32324ba9fe4c2ac}"
ZEROCLAW_CACHE="${ZEROCLAW_CACHE:-$SCRIPT_DIR/cache/$ZEROCLAW_TGZ_NAME}"

CZ_HOSTNAME="${CZ_HOSTNAME:-cardputerzero-kali}"
GROW_GB="${GROW_GB:-4}"

CZ_BOOT=/mnt/cz_boot
CZ_ROOT=/mnt/cz_root
KALI_BOOT=/mnt/kali_boot
KALI_ROOT=/mnt/kali_root

CZ_LOOP=""
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

# Fetch (with SHA-pinned cache), verify, and extract zeroclaw into <pi_home>.
# Idempotent — bails early if /home/pi/zeroclaw is already there.
install_zeroclaw() {
    local pi_home="$1"
    if [[ -x "$pi_home/zeroclaw" ]]; then
        ok "/home/pi/zeroclaw already installed — skipping"
        return
    fi

    mkdir -p "$(dirname "$ZEROCLAW_CACHE")"
    if [[ ! -f "$ZEROCLAW_CACHE" ]] || ! echo "$ZEROCLAW_SHA256  $ZEROCLAW_CACHE" | sha256sum -c --status; then
        log "Fetching zeroclaw $ZEROCLAW_VER from $ZEROCLAW_URL"
        curl -L --fail --progress-bar -o "$ZEROCLAW_CACHE.part" "$ZEROCLAW_URL"
        mv "$ZEROCLAW_CACHE.part" "$ZEROCLAW_CACHE"
    fi
    echo "$ZEROCLAW_SHA256  $ZEROCLAW_CACHE" | sha256sum -c --status \
        || err "zeroclaw SHA256 mismatch ($ZEROCLAW_CACHE) — refusing to install"

    # Tarball layout: ./zeroclaw + ./web/dist/... — extract everything to /home/pi
    log "Extracting zeroclaw $ZEROCLAW_VER → $pi_home"
    tar -xzf "$ZEROCLAW_CACHE" -C "$pi_home"
    chown -R 1000:1000 "$pi_home/zeroclaw" "$pi_home/web" 2>/dev/null || true
    chmod 755 "$pi_home/zeroclaw"
    ok "Installed /home/pi/zeroclaw + web assets (Claw applet)"
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────
unmount_all() {
    for m in "$KALI_ROOT" "$KALI_BOOT" "$CZ_ROOT" "$CZ_BOOT"; do
        if mountpoint -q "$m" 2>/dev/null; then
            umount "$m" 2>/dev/null || umount -l "$m" 2>/dev/null || true
        fi
    done
}
detach_loops() {
    # Detach any loops backing our image files (resilient even after a crash)
    for img in "$CZ_IMG" "$OUT_IMG"; do
        [[ -f "$img" ]] || continue
        while read -r loop; do
            [[ -n "$loop" ]] && losetup -d "$loop" 2>/dev/null || true
        done < <(losetup -j "$img" 2>/dev/null | cut -d: -f1)
    done
    CZ_LOOP=""; KALI_LOOP=""
}
cleanup() { unmount_all; detach_loops; }
trap cleanup EXIT

# ─── Stages ──────────────────────────────────────────────────────────────────

# check_donor_drift: compare our pinned donor version against M5's current
# "latest" by ETag (HEAD both). Informational — it never fails the build (we
# build against the pin on purpose); it just flags when upstream has moved so we
# know to recalibrate (bump CZ_VERSION_ID, rebuild, reflash).
check_donor_drift() {
    command -v curl >/dev/null 2>&1 || { warn "curl missing — skipping donor drift check"; return 0; }
    local pin lat
    pin=$(curl -fsSI --max-time 30 "${CZ_BASE_URL}?versionId=${CZ_VERSION_ID}" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')
    lat=$(curl -fsSI --max-time 30 "${CZ_BASE_URL}"                            2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')
    if [[ -z "$lat" || -z "$pin" ]]; then
        warn "donor drift check: upstream unreachable (offline?) — skipping"
    elif [[ "$pin" == "$lat" ]]; then
        ok "donor pin is current — upstream 'latest' == pinned version"
    else
        warn "UPSTREAM DONOR MOVED: latest ETag $lat != pinned $pin"
        warn "M5 published a new CZ image. To recalibrate: set CZ_VERSION_ID to the new id"
        warn "(curl -sI '$CZ_BASE_URL' | grep -i x-oss-version-id), then rebuild + reflash."
    fi
}

stage_check() {
    log "Checking dependencies"
    require_cmds xz parted partprobe e2fsck resize2fs blkid losetup ar tar zstd mountpoint truncate curl
    # Donor: stage_donor handles fetch/decompress, so we just need to know
    # *something* about the donor is resolvable from here (file present, .xz
    # present, or URL provided so we can fetch).
    if [[ ! -f "$CZ_IMG" && ! -f "$CZ_XZ" && -z "${CZ_URL:-}" ]]; then
        err "No CZ donor available: set CZ_IMG, place CZ_XZ at $CZ_XZ, or leave CZ_URL set"
    fi
    [[ -f "$KALI_XZ" || -f "$OUT_IMG" ]] || err "Kali source missing: $KALI_XZ and $OUT_IMG"
    ok "Dependencies + inputs OK"
    dim "CZ donor:  $CZ_IMG"
    dim "CZ xz:     $CZ_XZ"
    dim "Kali xz:   $KALI_XZ"
    dim "Out img:   $OUT_IMG"
    dim "Hostname:  $CZ_HOSTNAME"
    check_donor_drift
}

stage_donor() {
    if [[ -f "$CZ_IMG" ]]; then
        ok "$(basename "$CZ_IMG") already present — skipping donor fetch"
        return
    fi
    if [[ ! -f "$CZ_XZ" ]]; then
        log "Fetching donor image: $CZ_URL"
        curl -L --fail --progress-bar -o "$CZ_XZ.part" "$CZ_URL"
        mv "$CZ_XZ.part" "$CZ_XZ"
        ok "Downloaded: $(du -h "$CZ_XZ" | cut -f1)"
    fi
    log "Decompressing $(basename "$CZ_XZ")"
    xz -d -k -T 0 "$CZ_XZ"
    ok "Decompressed: $(du -h "$CZ_IMG" | cut -f1)"
}

stage_unxz() {
    if [[ -f "$OUT_IMG" ]]; then
        ok "$(basename "$OUT_IMG") already present — skipping unxz"
        return
    fi
    log "Decompressing $(basename "$KALI_XZ")"
    xz -d -k -T 0 "$KALI_XZ"
    ok "Decompressed: $(du -h "$OUT_IMG" | cut -f1)"
}

stage_resize() {
    local current_size_gb
    current_size_gb=$(($(stat -c%s "$OUT_IMG") / 1024 / 1024 / 1024))
    if (( current_size_gb >= 18 )); then
        ok "Image already $current_size_gb GiB — skipping resize"
        return
    fi
    log "Growing image by $GROW_GB GiB (current: $current_size_gb GiB)"
    truncate -s +"${GROW_GB}G" "$OUT_IMG"
    local loop
    loop=$(losetup -fP --show "$OUT_IMG")
    parted --script "$loop" resizepart 2 100%
    partprobe "$loop"
    e2fsck -f -y "${loop}p2" || true
    resize2fs "${loop}p2"
    losetup -d "$loop"
    ok "Resized to $(($(stat -c%s "$OUT_IMG") / 1024 / 1024 / 1024)) GiB"
}

stage_mount() {
    # Idempotent: if already mounted, no-op
    if mountpoint -q "$KALI_ROOT" && mountpoint -q "$CZ_ROOT"; then
        ok "Already mounted"
        # Recover loop names from /proc/mounts for downstream stages
        CZ_LOOP=$(findmnt -no SOURCE "$CZ_ROOT"   | sed 's/p[0-9]*$//')
        KALI_LOOP=$(findmnt -no SOURCE "$KALI_ROOT" | sed 's/p[0-9]*$//')
        return
    fi
    log "Loop-attaching and mounting"
    mkdir -p "$CZ_BOOT" "$CZ_ROOT" "$KALI_BOOT" "$KALI_ROOT"

    CZ_LOOP=$(losetup -fP --show --read-only "$CZ_IMG")
    KALI_LOOP=$(losetup -fP --show "$OUT_IMG")

    mount -o ro            "${CZ_LOOP}p1"   "$CZ_BOOT"
    mount -o ro,noload     "${CZ_LOOP}p2"   "$CZ_ROOT"
    mount                  "${KALI_LOOP}p1" "$KALI_BOOT"
    mount                  "${KALI_LOOP}p2" "$KALI_ROOT"
    ok "Mounted: cz=$CZ_LOOP kali=$KALI_LOOP"
}

stage_boot() {
    log "Boot-partition transplant"

    # Backup originals (idempotent — don't clobber existing .kali)
    for f in kernel8.img bcm2710-rpi-cm0.dtb config.txt cmdline.txt; do
        [[ -f "$KALI_BOOT/$f.kali" ]] || cp -a "$KALI_BOOT/$f" "$KALI_BOOT/$f.kali"
    done

    cp -a "$CZ_BOOT/kernel8.img"         "$KALI_BOOT/"
    cp -a "$CZ_BOOT/bcm2710-rpi-cm0.dtb" "$KALI_BOOT/"

    # cardputerzero-overlay.dtbo: install OUR patched version (vendored), not
    # the donor's. M5's stock overlay declares 3 SPI0 chip-selects with CS2
    # mapped to GPIO22, but no overlay node consumes CS2 — it's dead weight
    # left over from copy-paste. The conflict surfaces when you plug in M5's
    # own LoRa SX1262 cap (Ultimate Edition Kickstarter accessory): the cap's
    # BUSY signal lives on GPIO22 and the applet's `busy_gpio_init` fails
    # with rc=1 because the SPI subsystem has already claimed the pin. Our
    # patched .dtbo drops num-cs to 2, removes the third cs-gpios triplet,
    # and cleans up the matching __fixups__ reference. Diff is ±4 lines, no
    # other functional change. Keep the donor's original on disk as a `.m5orig`
    # backup so users can revert if some other consumer of CS2 ever appears.
    # Version-agnostic: patch the DONOR's own overlay at build time rather than
    # shipping a static .dtbo that goes stale every donor bump (and that would
    # also carry the old IO-expander binding — M5 renamed py32ioexp -> m5ioe1).
    # Decompile, drop num-cs 3->2 + the dead CS2/GPIO22 triplet + its __fixups__
    # ref, recompile. dtc round-trip is lossless (verified). The num-cs sed is a
    # no-op if M5 ever fixes it upstream; stage_verify re-checks num-cs == 2.
    local cz_ovl="$CZ_BOOT/overlays/cardputerzero-overlay.dtbo"
    if command -v dtc >/dev/null 2>&1 && [[ -f "$cz_ovl" ]]; then
        local ov_dts; ov_dts=$(mktemp)
        dtc -I dtb -O dts -o "$ov_dts" "$cz_ovl" 2>/dev/null
        sed -i \
            -e 's/num-cs = <0x03>/num-cs = <0x02>/' \
            -e 's/\(cs-gpios = <0xffffffff 0x08 0x01 0xffffffff 0x07 0x01\) 0xffffffff 0x16 0x01>/\1>/' \
            -e 's/, "[^"]*:cs-gpios:24"//' \
            "$ov_dts"
        if dtc -I dts -O dtb -o "$KALI_BOOT/overlays/cardputerzero-overlay.dtbo" "$ov_dts" 2>/dev/null \
           && dtc -I dtb -O dts "$KALI_BOOT/overlays/cardputerzero-overlay.dtbo" 2>/dev/null | grep -q 'num-cs = <0x02>'; then
            ok "Patched cardputerzero-overlay (num-cs 3->2, dropped dead CS2/GPIO22)"
        else
            warn "build-time overlay patch failed — falling back to vendored .dtbo"
            install -m644 "$SCRIPT_DIR/vendored/cardputerzero-overlay-cs2fix.dtbo" \
                          "$KALI_BOOT/overlays/cardputerzero-overlay.dtbo"
        fi
        rm -f "$ov_dts"
        install -m644 "$cz_ovl" "$KALI_BOOT/overlays/cardputerzero-overlay.dtbo.m5orig"
    else
        warn "dtc or donor overlay missing — using vendored .dtbo (may be stale for this donor)"
        install -m644 "$SCRIPT_DIR/vendored/cardputerzero-overlay-cs2fix.dtbo" \
                      "$KALI_BOOT/overlays/cardputerzero-overlay.dtbo"
        [[ -f "$cz_ovl" ]] && install -m644 "$cz_ovl" "$KALI_BOOT/overlays/cardputerzero-overlay.dtbo.m5orig"
    fi

    # Overlays we want present: lsm6ds3tr (IMU, bound by mainline st_lsm6dsx)
    # plus two GPIO-high overlays that M5Stack added in their 2025-05-13 image
    # to power on the camera (GPIO16) and speaker amp (GPIO24) at DT-init time.
    # The camera-gpio16 overlay is the suspected fix for the IMX219 sensor not
    # ACKing i2c reads — sensor was unpowered without it. (`install` instead of
    # `cp -a` — exfat→FAT32 ownership preservation silently fails with cp -a.)
    #
    # No bq27220 overlay: the chip has no in-tree Linux driver, and the
    # out-of-tree binary M5 ships against it isn't useful (data flash is
    # uncalibrated, on-chip SOC is wrong regardless). APPLaunch talks to the
    # chip directly via /dev/i2c-1 — see stage_configs for the i2c-dev autoload.
    for ov in lsm6ds3tr-overlay.dtbo camera-gpio16-high-overlay.dtbo spk-gpio24-high-overlay.dtbo; do
        if [[ -f "$CZ_BOOT/overlays/$ov" ]]; then
            install -m644 "$CZ_BOOT/overlays/$ov" "$KALI_BOOT/overlays/$ov"
        else
            install -m644 "$SCRIPT_DIR/vendored/$ov" "$KALI_BOOT/overlays/$ov"
        fi
    done

    write_config_txt
    write_cmdline_txt
    write_user_data
    ok "Boot partition ready"
}

write_config_txt() {
    log "Writing config.txt (Kali base + CZ overlays + Pi-Tail dwc2)"
    cat > "$KALI_BOOT/config.txt" <<'CONFIG'
# Cardputer Zero on Kali — merged config.txt
# Original Kali base preserved as config.txt.kali.
# Boots CZ's M5-patched kernel (kernel8.img, transplanted from the donor)
# directly via the GPU firmware loader — no u-boot chain, same as the OEM image.

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

# Cardputer Zero carrier-board overlays
dtoverlay=cardputerzero-overlay
dtoverlay=lsm6ds3tr-overlay

# Power-enable the IMX219 camera sensor (GPIO16 HIGH) and the speaker amp
# (GPIO24 HIGH) at DT-init time. M5 added these to their May 2025 image; the
# camera one is the suspected fix for the sensor not ACKing i2c probes on
# earlier builds (which we and other beta testers reported as a "dead camera").
dtoverlay=camera-gpio16-high-overlay
dtoverlay=spk-gpio24-high-overlay

# IR receiver + transmitter (per CZ stock config)
dtoverlay=gpio-ir,gpio_pin=13,gpio_pull=up
dtoverlay=pwm-ir-tx,gpio_pin=12,func=4

# USB OTG (gadget mode) — for later Pi-Tail USB-Ethernet
dtoverlay=dwc2
CONFIG
}

write_cmdline_txt() {
    local partuuid
    partuuid=$(blkid -s PARTUUID -o value "${KALI_LOOP}p2")
    log "Writing cmdline.txt with PARTUUID=$partuuid"
    # 'quiet' silences kernel chatter on tty1.
    # 'consoleblank=0' disables the 10-min auto-blank — small device, we don't
    #     want the kernel blanking fbcon and dragging APPLaunch's redraws along.
    # 'fbcon=map:99' tells the framebuffer console to attach itself to /dev/fb99
    #     which never exists. Without this, when HDMI is unplugged the LCD
    #     becomes fb0 and the kernel auto-binds fbcon to it, painting kernel
    #     messages + cursor over APPLaunch. We tried a userspace unbind service
    #     (`disable-fbcon.service`) but it racey-ran before the st7789v module
    #     registered the fb, missed it, and the kernel rebound automatically.
    #     map:99 is the only race-free fix. Side effect: HDMI text console is
    #     no longer visible — use SSH or lightdm/X for HDMI shells.
    cat > "$KALI_BOOT/cmdline.txt" <<CMDLINE
console=serial0,115200 console=tty1 root=PARTUUID=${partuuid} rootfstype=ext4 fsck.repair=yes rootwait quiet fbcon=map:99 consoleblank=0 modules-load=dwc2
CMDLINE
}

write_user_data() {
    log "Writing cloud-init user-data (hostname=$CZ_HOSTNAME, ssh on)"
    cat > "$KALI_BOOT/user-data" <<YAML
#cloud-config
# vim: syntax=yaml

hostname: $CZ_HOSTNAME
manage_etc_hosts: true

users:
  - default

ssh_pwauth: true
package_upgrade: false

runcmd:
  - [ systemctl, enable, ssh ]
  - [ systemctl, start, ssh ]
YAML
}

stage_rootfs() {
    log "Rootfs transplant: modules + firmware"

    # Kernel modules. Kali is usrmerged so the canonical path is /usr/lib/modules.
    # Version-agnostic: derive the kernel version from the DONOR's own v8 module
    # dir (the CM0 / Pi-Zero-2-W kernel is the +rpt-rpi-v8 flavour), so the graft
    # follows whatever kernel M5 ships instead of being nailed to one version and
    # skewing against the transplanted kernel8.img. stage_verify re-checks the match.
    local KVER
    KVER=$(basename "$(ls -d "$CZ_ROOT"/lib/modules/*+rpt-rpi-v8 2>/dev/null | sort -V | tail -1)")
    [[ -n "$KVER" ]] || err "donor has no +rpt-rpi-v8 kernel modules ($CZ_ROOT/lib/modules)"
    log "Donor kernel modules: $KVER"
    local mod_src="$CZ_ROOT/lib/modules/$KVER"
    local mod_dst="$KALI_ROOT/usr/lib/modules/$KVER"
    local rebuild_depmod=0
    if [[ -d "$mod_dst" ]]; then
        ok "Modules dir already present — skipping (delete it to force re-copy)"
    else
        [[ -d "$mod_src" ]] || err "CZ modules dir missing: $mod_src"
        cp -a "$mod_src" "$KALI_ROOT/usr/lib/modules/"
        ok "Copied $(du -sh "$mod_dst" | cut -f1) of modules"
        rebuild_depmod=1

        # M5's 2025-05+ image ships bq27xxx_battery*.ko in BOTH /extra/ (their
        # out-of-tree builds, incl. _hdq variant) AND /kernel/drivers/power/supply/
        # (in-tree variants enabled via CONFIG_BATTERY_BQ27XXX=y). We don't want
        # any of them: the chip's data flash is uncalibrated, the kernel driver
        # binds it as bq27500 (wrong register map), and APPLaunch already reads
        # it correctly via /dev/i2c-1 with a voltage-derived SOC. Strip both
        # locations before depmod so they aren't loaded at boot. See README's
        # "no kernel driver for bq27220" entry for context.
        rm -f "$mod_dst/extra/bq27xxx_battery"*.ko \
              "$mod_dst/kernel/drivers/power/supply/bq27xxx_battery"*.ko
    fi

    if (( rebuild_depmod )); then
        log "Rebuilding modules.dep (depmod) for $KVER"
        depmod -b "$KALI_ROOT" "$KVER"
    fi

    # Kernel headers: copy from the donor so the /lib/modules/<kver>/build
    # symlink resolves inside the Kali rootfs. Required for out-of-tree module
    # builds (e.g. realtek-rtl88xxau for the AWUS036ACS). The donor ships these
    # as installed dpkg packages; we copy directly without dpkg registration
    # (the kernel is held, so no version conflict can arise at runtime).
    #
    # Package layout:
    #   linux-headers-<kver-base>+rpt-common-rpi  → /usr/src/  (arch-independent)
    #   linux-headers-<KVER>                       → /usr/src/  (arch-specific)
    #   linux-kbuild-<kver-base>+rpt               → /usr/lib/  (kbuild scripts/tools)
    # The common-rpi Makefile's 'scripts' entry is a symlink into /usr/lib/linux-kbuild-*/
    local kver_base="${KVER%%+*}"  # "6.18.33+rpt-rpi-v8" -> "6.18.33"
    for hdr in \
        "linux-headers-${kver_base}+rpt-common-rpi" \
        "linux-headers-${KVER}"
    do
        local hdr_dst="$KALI_ROOT/usr/src/$hdr"
        local hdr_src="$CZ_ROOT/usr/src/$hdr"
        if [[ -d "$hdr_dst" ]]; then
            ok "Kernel headers already present: $hdr — skipping"
        elif [[ -d "$hdr_src" ]]; then
            cp -a "$hdr_src" "$KALI_ROOT/usr/src/"
            ok "Copied $(du -sh "$hdr_dst" | cut -f1): $hdr"
        else
            warn "Donor missing kernel headers: $hdr (module builds will fail)"
        fi
    done
    # linux-kbuild installs to /usr/lib/, not /usr/src/
    local kbuild_name="linux-kbuild-${kver_base}+rpt"
    local kbuild_dst="$KALI_ROOT/usr/lib/$kbuild_name"
    local kbuild_src="$CZ_ROOT/usr/lib/$kbuild_name"
    if [[ -d "$kbuild_dst" ]]; then
        ok "Kbuild scripts already present: $kbuild_name — skipping"
    elif [[ -d "$kbuild_src" ]]; then
        cp -a "$kbuild_src" "$KALI_ROOT/usr/lib/"
        ok "Copied $(du -sh "$kbuild_dst" | cut -f1): $kbuild_name (kbuild scripts)"
    else
        warn "Donor missing $kbuild_name at /usr/lib/ (module builds will fail)"
    fi

    # CM0-specific Broadcom firmware (brcm/ tree)
    log "Copying CM0-specific Broadcom firmware blobs (brcm/)"
    for f in \
        brcmfmac43430-sdio.raspberrypi,0-compute-module.bin \
        brcmfmac43430-sdio.raspberrypi,0-compute-module.txt \
        brcmfmac43436s-sdio.raspberrypi,0-compute-module.bin \
        brcmfmac43436s-sdio.raspberrypi,0-compute-module.txt \
        brcmfmac43439-sdio.raspberrypi,0-compute-module.bin \
        brcmfmac43439-sdio.raspberrypi,0-compute-module.clm_blob \
        brcmfmac43439-sdio.raspberrypi,0-compute-module.txt
    do
        [[ -f "$CZ_ROOT/lib/firmware/brcm/$f" ]] && \
            cp -a "$CZ_ROOT/lib/firmware/brcm/$f" "$KALI_ROOT/usr/lib/firmware/brcm/"
    done

    # Cypress firmware (cypress/) — load-bearing for BCM43439.
    # The brcm/ entries above are symlinks into ../cypress/. Kali's stock cypress/
    # dir is missing several of the targets, leaving dangling symlinks. More
    # importantly, the cyfmac43439-sdio.txt NVRAM Kali ships has
    # boardflags3=0x08000000 (wrong for CZ); donor has 0x04000000 which is what
    # the chip actually needs to bring up its HT clock. Without the donor's
    # NVRAM the chip wedges with "HT Avail timeout" and wlan0 never appears.
    # See memory: project_wifi_nvram_boardflags3.
    log "Copying Cypress firmware (cypress/) — includes CZ-specific NVRAM for BCM43439"
    for f in \
        cyfmac43439-sdio.bin \
        cyfmac43439-sdio.clm_blob \
        cyfmac43439-sdio.txt
    do
        if [[ -f "$CZ_ROOT/lib/firmware/cypress/$f" ]]; then
            cp -af "$CZ_ROOT/lib/firmware/cypress/$f" "$KALI_ROOT/usr/lib/firmware/cypress/"
        fi
    done

    # Symlink the missing CM0 .clm_blob → generic cypress blob
    local clm="$KALI_ROOT/usr/lib/firmware/brcm/brcmfmac43430-sdio.raspberrypi,0-compute-module.clm_blob"
    if [[ ! -e "$clm" ]]; then
        ln -sf ../cypress/cyfmac43430-sdio.clm_blob "$clm"
    fi

    # Camera userspace lift — gated on donor shipping libcamera-ipa. Kali rolling
    # doesn't package libcamera-ipa at all, and the Pi-patched IPA links against
    # symbols (libcamera::controls::rpi::CnnEnableInputTensor, etc.) that
    # upstream Debian's libcamera 0.7.1 doesn't expose. The fix is to lift the
    # whole camera userspace stack ABI-consistently from M5's donor (their
    # libcamera 0.7.0 has the Pi patches that the IPA needs). Without this the
    # IMX219 sensor is reachable but no app can register the camera — applet
    # shows a black viewfinder. Requires donor = M5's 2025-05+ image (the older
    # cardputerzero-trixie-arm64-latest doesn't include the IPA stack).
    local ipa_marker="$CZ_ROOT/usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_rpi_vc4.so"
    if [[ -f "$ipa_marker" ]]; then
        log "Donor ships libcamera-ipa — lifting camera userspace stack"

        # Version-agnostic lift. M5 bumps their Pi-patched libcamera over time
        # (0.7.0 -> 0.7.1 -> …, sometimes to the same number Kali ships but with
        # the Pi patches Kali's lacks), so derive versions instead of hardcoding.
        local lcdir="$KALI_ROOT/usr/lib/aarch64-linux-gnu"
        local m5dir="$CZ_ROOT/usr/lib/aarch64-linux-gnu"
        local m5_lcver
        m5_lcver=$(basename "$(ls "$m5dir"/libcamera.so.[0-9]*.[0-9]*.[0-9]* 2>/dev/null | sort -V | tail -1)" 2>/dev/null | sed 's/^libcamera\.so\.//') || true
        [[ -n "$m5_lcver" ]] || err "donor libcamera version not found in $m5dir"
        log "Lifting M5 Pi-patched libcamera $m5_lcver over Kali's"

        # Move Kali's versioned libcamera + base OUT (any X.Y.Z) so ldconfig can't
        # prefer a numerically-higher Kali build over M5's patched one; back up for revert.
        install -d -m755 "$KALI_ROOT/root/kali-libcamera-backup"
        for f in "$lcdir"/libcamera.so.[0-9]*.[0-9]*.[0-9]* "$lcdir"/libcamera-base.so.[0-9]*.[0-9]*.[0-9]*; do
            [[ -f "$f" ]] && mv "$f" "$KALI_ROOT/root/kali-libcamera-backup/"
        done
        # Drop the dev + soname symlinks; cp -af below brings M5's, ldconfig fixes up.
        rm -f "$lcdir"/libcamera.so "$lcdir"/libcamera.so.[0-9]* \
              "$lcdir"/libcamera-base.so "$lcdir"/libcamera-base.so.[0-9]*

        # Copy ALL of M5's libcamera + base (every symlink + the versioned .so).
        for f in "$m5dir"/libcamera.so* "$m5dir"/libcamera-base.so*; do
            [[ -e "$f" ]] && cp -af "$f" "$lcdir/"
        done

        # Stash M5's versioned libcamera in the rootfs so the post-apt re-assert
        # (stage_packages) can restore it even when apt reinstalls the SAME version
        # number — M5's 0.7.1 vs Kali's 0.7.1 collide and apt overwrites in place.
        install -d -m755 "$KALI_ROOT/root/m5-libcamera-pinned"
        for f in "$m5dir"/libcamera.so.[0-9]*.[0-9]*.[0-9]* "$m5dir"/libcamera-base.so.[0-9]*.[0-9]*.[0-9]*; do
            [[ -f "$f" ]] && cp -af "$f" "$KALI_ROOT/root/m5-libcamera-pinned/"
        done

        # Camera-stack runtime deps not packaged in Kali: TFLite (used by IPA
        # for autofocus / scene detection), absl, farmhash, cpuinfo.
        for pat in 'libtensorflow-lite.so*' 'libfarmhash.so*' 'libcpuinfo.so*' 'libabsl_*.so.20240722'; do
            for src in "$CZ_ROOT"/usr/lib/aarch64-linux-gnu/$pat; do
                [[ -e "$src" ]] && cp -af "$src" "$KALI_ROOT/usr/lib/aarch64-linux-gnu/"
            done
        done

        # IPA plugins (.so + .so.sign) and per-sensor tuning JSONs
        install -d -m755 "$KALI_ROOT/usr/lib/aarch64-linux-gnu/libcamera"
        cp -af "$CZ_ROOT/usr/lib/aarch64-linux-gnu/libcamera/ipa" \
               "$KALI_ROOT/usr/lib/aarch64-linux-gnu/libcamera/"
        install -d -m755 "$KALI_ROOT/usr/share/libcamera"
        cp -af "$CZ_ROOT/usr/share/libcamera/ipa" \
               "$KALI_ROOT/usr/share/libcamera/"

        # IPC proxy workers (libcamera runs the IPA in a separate process for
        # isolation; this is the helper binary that hosts the IPA module).
        install -d -m755 "$KALI_ROOT/usr/libexec/aarch64-linux-gnu/libcamera"
        for f in raspberrypi_ipa_proxy vimc_ipa_proxy v4l2-compat.so; do
            [[ -f "$CZ_ROOT/usr/libexec/aarch64-linux-gnu/libcamera/$f" ]] && \
                install -m755 "$CZ_ROOT/usr/libexec/aarch64-linux-gnu/libcamera/$f" \
                              "$KALI_ROOT/usr/libexec/aarch64-linux-gnu/libcamera/"
        done

        # ldconfig runs later inside the chroot (stage_packages); rebuilding
        # /etc/ld.so.cache here against the live system would be wrong anyway.
        ok "Camera userspace lifted from donor"
    else
        warn "Donor lacks libcamera-ipa — camera applet will show black viewfinder."
        warn "Use M5's 2025-05+ image as donor (CZ_IMG=/path/to/20250513_os.img)."
    fi

    # Hostname (cloud-init handles it too, but be belt-and-braces)
    echo "$CZ_HOSTNAME" > "$KALI_ROOT/etc/hostname"
    ok "Rootfs transplant done"
}

stage_applaunch() {
    log "Installing APPLaunch"

    local deb="${APPLAUNCH_DEB:-}"
    if [[ -z "$deb" ]]; then
        # Prefer the most recent locally-built .deb (from stage_launcher_build);
        # fall back to the donor's bundled one.
        deb=$(ls -t "$SCRIPT_DIR"/applaunch_*_arm64.deb 2>/dev/null | head -1 || true)
        if [[ -z "$deb" ]]; then
            deb=$(ls "$CZ_ROOT/home/pi/"applaunch_*_arm64.deb 2>/dev/null | head -1 || true)
        fi
    fi
    [[ -f "$deb" ]] || err "APPLaunch .deb not found (set APPLAUNCH_DEB env var or run launcher-build)"
    dim "From: $deb"

    # /home/pi helper binaries — install independently of the .deb step so they
    # land on re-runs even if APPLaunch itself is already in place. APPLaunch
    # ships hardcoded /home/pi/... paths for its terminal apps (Claw, Calculator,
    # racer, roller485); the OEM image ships an empty /home/pi and these are
    # end-user-installed externals.
    install -d -m755 -o 1000 -g 1000 "$KALI_ROOT/home/pi"
    # Camera app writes captures to /home/pi/Pictures/IMX219_*.jpg —
    # pre-create the directory so writes don't ENOENT. (Still useless
    # until the IMX219 -EREMOTEIO upstream defect is resolved, but the
    # path is ready when it is.)
    install -d -m755 -o 1000 -g 1000 "$KALI_ROOT/home/pi/Pictures"
    install_zeroclaw "$KALI_ROOT/home/pi"

    if [[ -x "$KALI_ROOT/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch" \
       && -L "$KALI_ROOT/etc/systemd/system/multi-user.target.wants/APPLaunch.service" ]]; then
        ok "APPLaunch already installed + enabled — skipping (rm /usr/share/APPLaunch to force)"
        return
    fi

    local work
    work=$(mktemp -d)
    cp "$deb" "$work/applaunch.deb"
    ( cd "$work" && ar x applaunch.deb )

    mkdir -p "$work/payload"
    # Compression varies: donor's .deb is zstd, our local-built one is xz (dpkg-deb default).
    # `tar -xaf` auto-detects by file magic.
    data_archive=$(ls "$work"/data.tar.* | head -1)
    [[ -n "$data_archive" ]] || err "no data.tar.* found in .deb"
    tar -xaf "$data_archive" -C "$work/payload"

    # CRITICAL: /lib in Kali is a symlink → usr/lib. GNU tar refuses to extract
    # through symlinks (CVE-2018-20482 hardening). If we let tar drop directly
    # into $KALI_ROOT it'd replace /lib with a real directory — boot-fatal.
    # So extract to a tmpdir first, then manually map /lib/* → /usr/lib/*.
    if [[ -d "$work/payload/lib" ]]; then
        cp -a "$work/payload/lib/." "$KALI_ROOT/usr/lib/"
        rm -rf "$work/payload/lib"
    fi
    cp -a "$work/payload/." "$KALI_ROOT/"
    rm -rf "$work"

    # Replicate the .deb postinst manually (no chroot needed)
    mkdir -p "$KALI_ROOT/var/cache/APPLaunch"
    rm -rf "$KALI_ROOT/usr/share/APPLaunch/cache"
    ln -s /var/cache/APPLaunch "$KALI_ROOT/usr/share/APPLaunch/cache"

    # systemctl enable equivalent
    mkdir -p "$KALI_ROOT/etc/systemd/system/multi-user.target.wants"
    ln -sf /lib/systemd/system/APPLaunch.service \
        "$KALI_ROOT/etc/systemd/system/multi-user.target.wants/APPLaunch.service"

    # Drop-in: wait for udev to populate /dev/input/by-path symlinks before
    # APPLaunch starts. Without this, APPLaunch races udev — opens the keypad
    # via the missing by-path symlink, libinput returns ENOENT, and the
    # keypad is silently lost for the whole session.
    mkdir -p "$KALI_ROOT/etc/systemd/system/APPLaunch.service.d"
    cat > "$KALI_ROOT/etc/systemd/system/APPLaunch.service.d/wait-for-udev.conf" <<'EOF'
[Unit]
After=systemd-udev-settle.service multi-user.target
Wants=systemd-udev-settle.service

[Service]
ExecStartPre=/bin/sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do [ -e /dev/input/by-path/platform-3f804000.i2c-event ] && exit 0; sleep 1; done; exit 0"
EOF

    ok "APPLaunch installed + service enabled"
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

    # Expose i2c-1 to userspace. The bq27220 fuel gauge has no in-tree Linux
    # driver, so we don't bind a kernel driver to it at all — APPLaunch reads
    # the chip directly via /dev/i2c-1 with the correct bq27220 register map
    # (see projects/APPLaunch/main/hal/linux/hal_settings_linux.cpp). Without
    # this, /dev/i2c-1 is missing at boot and APPLaunch falls through to no
    # battery info at all.
    mkdir -p "$KALI_ROOT/etc/modules-load.d"
    cat > "$KALI_ROOT/etc/modules-load.d/i2c-dev.conf" <<'EOF'
i2c-dev
EOF

    # Audio routing. Two ALSA cards register at boot — card 0 is vc4hdmi
    # (CZ has no physical HDMI sink, opens fail with ENOSTR), card 1 is the
    # ES8389 codec driven by es8389_m5stack.ko + the cardputerzero-overlay's
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

    # gpsd config — points at /dev/ttyS0 at 115200 baud for the LoRa+GNSS
    # cap's onboard ATGM336H. The chip ships pre-configured to 115200 NMEA
    # (matches Pi serial console rate, no auto-baud needed). We mask
    # serial-getty@ttyS0 in stage_packages so login doesn't fight gpsd for
    # the port. -n = poll immediately rather than waiting for a client; -s
    # locks the baud rate. USBAUTO disabled so hotplug rules don't try to
    # claim some other GPS we don't have.
    cat > "$KALI_ROOT/etc/default/gpsd" <<'EOF'
DEVICES="/dev/ttyS0"
GPSD_OPTIONS="-n -s 115200"
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

    # Lightdm autostarts LXDE on HDMI (enabled in stage_packages). tty1's getty
    # autologin is the fallback if lightdm is masked or fails. The fbcon=map:99
    # cmdline still suppresses the kernel framebuffer console on both outputs
    # so APPLaunch owns the LCD cleanly.
    mkdir -p "$KALI_ROOT/etc/systemd/system/getty@tty1.service.d"
    cat > "$KALI_ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kali --noclear %I $TERM
Type=idle
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
stage_packages() {
    log "Installing desktop stack via qemu-user-static chroot"

    [[ -x /usr/bin/qemu-aarch64-static ]] \
        || err "qemu-aarch64-static not installed. Run: sudo pacman -S qemu-user-static qemu-user-static-binfmt"
    [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]] \
        || err "binfmt_misc qemu-aarch64 not registered. Try: sudo systemctl restart systemd-binfmt"

    # Sentinel: skip if EVERYTHING this stage installs is already present
    # (LXDE + autologin greeter + libcamera + ffmpeg + gpiod + the
    # pre-baked kali user). We can't just check LXDE binaries — earlier
    # versions of this stage didn't bake some of these, and we'd silently
    # skip them on a re-run.
    if [[ -x "$KALI_ROOT/usr/bin/lxsession" \
       && -x "$KALI_ROOT/usr/lib/lightdm-autologin-greeter/lightdm-autologin-greeter" \
       && -f "$KALI_ROOT/usr/lib/aarch64-linux-gnu/libcamera.so.0.7" \
       && -x "$KALI_ROOT/usr/bin/ffmpeg" \
       && -x "$KALI_ROOT/usr/bin/gpioset" \
       && -f "$KALI_ROOT/home/kali/.ssh/authorized_keys" ]] \
       && grep -q '^kali:' "$KALI_ROOT/etc/passwd" \
       && find "$KALI_ROOT/usr/lib/modules" -name '88XXau.ko*' \
               -path '*/updates/dkms/*' -not -path '*/6.12.*' 2>/dev/null | grep -q .; then
        ok "Desktop packages + kali user + SSH key + 88XXau all present — skipping"
        return
    fi

    # Save resolv.conf state so we can restore image-neutral after the chroot.
    # File-scope (not local) so the cleanup helper sees them on RETURN trap.
    CHROOT_RESOLV="$KALI_ROOT/etc/resolv.conf"
    CHROOT_RESOLV_WAS_SYMLINK=false
    [[ -L "$CHROOT_RESOLV" ]] && CHROOT_RESOLV_WAS_SYMLINK=true
    cp -f /etc/resolv.conf "$CHROOT_RESOLV"

    mount --bind /dev     "$KALI_ROOT/dev"
    mount --bind /dev/pts "$KALI_ROOT/dev/pts"
    mount -t proc proc    "$KALI_ROOT/proc"
    mount -t sysfs sysfs  "$KALI_ROOT/sys"

    # Cleanup on any exit path. Unmounts in reverse order + restores
    # resolv.conf. Idempotent — outer cleanup() trap will also try to unmount
    # but mountpoint -q will see them as gone.
    chroot_cleanup() {
        umount -l "$KALI_ROOT/sys"     2>/dev/null || true
        umount -l "$KALI_ROOT/proc"    2>/dev/null || true
        umount -l "$KALI_ROOT/dev/pts" 2>/dev/null || true
        umount -l "$KALI_ROOT/dev"     2>/dev/null || true
        if [[ "${CHROOT_RESOLV_WAS_SYMLINK:-false}" == "true" ]]; then
            rm -f "$CHROOT_RESOLV"
            ln -sf /run/systemd/resolve/stub-resolv.conf "$CHROOT_RESOLV" 2>/dev/null || \
            ln -sf /etc/resolvconf/run/resolv.conf "$CHROOT_RESOLV" 2>/dev/null || \
            : > "$CHROOT_RESOLV"
        elif [[ -f "${CHROOT_RESOLV:-}" ]]; then
            : > "$CHROOT_RESOLV"
        fi
    }
    trap chroot_cleanup RETURN

    chroot "$KALI_ROOT" /usr/bin/env -i \
        DEBIAN_FRONTEND=noninteractive \
        HOME=/root \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        LC_ALL=C \
        bash -e <<'CHROOT'
apt-get update

# gcc + make must land before realtek-rtl88xxau-dkms triggers the DKMS build.
# dkms doesn't declare gcc as a dependency (it's expected to be present), so a
# single combined apt-get could configure rtl88xxau-dkms before gcc is ready.
apt-get install -y --no-install-recommends gcc make

apt-get install -y --no-install-recommends \
    -o Dpkg::Options::="--force-confold" \
    -o Dpkg::Options::="--force-confdef" \
    zram-tools \
    cloud-guest-utils \
    lxde-core \
    lightdm-autologin-greeter \
    feh \
    libcamera0.7 \
    ffmpeg \
    gpiod \
    pipewire-alsa \
    gpsd \
    gpsd-clients \
    realtek-rtl88xxau-dkms

# DKMS skips the 6.18.33 kernel due to BUILD_EXCLUSIVE_KERNEL in dkms.conf,
# and its /var/lib/dkms/rtl88xxau/<ver>/source symlink is never created (so
# 'dkms install' can't find the source either). Build the module directly with
# make against the transplanted 6.18.33 kernel headers — same thing DKMS would
# call internally, just without the DKMS orchestration layer.
# Source dir: Kali uses 'realtek-rtl88xxau-<ver>' (Debian src pkg name).
RTL_SRC=$(ls -d /usr/src/*rtl88xxau-* 2>/dev/null | sort -V | tail -1)
CZ_KVER=$(ls /lib/modules/ | grep '+rpt-rpi-v8$' | sort -V | tail -1)
if [ -n "$RTL_SRC" ] && [ -n "$CZ_KVER" ]; then
    # The donor kernel headers reference aarch64-linux-gnu-gcc-14 but Kali ships
    # gcc-15. Shim the versioned names so kbuild resolves them correctly.
    for _t in gcc gcc-ar gcc-nm gcc-ranlib; do
        [ -e "/usr/bin/aarch64-linux-gnu-${_t}-14" ] || \
            ln -sf "aarch64-linux-gnu-${_t}-15" "/usr/bin/aarch64-linux-gnu-${_t}-14"
    done
    # 6.18.33 kbuild dropped EXTRA_CFLAGS support (replaced by ccflags-y).
    # The driver's Makefile uses EXTRA_CFLAGS throughout; patch it before building.
    sed -i 's/^EXTRA_CFLAGS\b/ccflags-y/g; s/^EXTRA_LDFLAGS\b/ldflags-y/g' \
        "$RTL_SRC/Makefile"
    # Kernel 6.16 removed from_timer() (→ timer_container_of) and del_timer_sync()
    # (→ timer_delete_sync). Write a compat shim and inject it into the affected header.
    cat > "$RTL_SRC/include/rtw_compat_6_16.h" <<'COMPAT'
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
    grep -q 'rtw_compat_6_16.h' "$RTL_SRC/include/osdep_service_linux.h" || \
        sed -i '/#define __OSDEP_LINUX_SERVICE_H_/a #include "rtw_compat_6_16.h"' \
            "$RTL_SRC/include/osdep_service_linux.h"
    # Kernel 6.17 added int radio_idx to set_wiphy_params, set_tx_power, get_tx_power
    # cfg80211_ops callbacks. Patch the driver's ioctl_cfg80211.c signatures to match.
    # Use a Python patcher so multiline declarations are handled safely.
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

# set_wiphy_params: add radio_idx between wiphy and u32 changed
c = patch(c,
    'cfg80211_rtw_set_wiphy_params(struct wiphy *wiphy, u32 changed)',
    'cfg80211_rtw_set_wiphy_params(struct wiphy *wiphy, int radio_idx __maybe_unused, u32 changed)',
    'set_wiphy_params')

# set_tx_power: add radio_idx between the #endif/#if guards
# (declaration has #if guards between params so regex can't span them)
c = patch(c,
    '#endif\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)) || defined(COMPAT_KERNEL_RELEASE)\n\tenum nl80211_tx_power_setting type, int mbm)',
    '#endif\n\tint radio_idx __maybe_unused,\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(2, 6, 36)) || defined(COMPAT_KERNEL_RELEASE)\n\tenum nl80211_tx_power_setting type, int mbm)',
    'set_tx_power')

# get_tx_power: add radio_idx before the #if >= 6.14.0 link_id block
c = patch(c,
    '#endif\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0))\n\tunsigned int link_id,',
    '#endif\n\tint radio_idx __maybe_unused,\n#if (LINUX_VERSION_CODE >= KERNEL_VERSION(6, 14, 0))\n\tunsigned int link_id,',
    'get_tx_power')

with open(path, 'w') as f:
    f.write(c)
print(f'Done — {"changes made" if c != orig else "no changes"}')
sys.exit(0)
PYPATCH
    python3 /tmp/patch_cfg80211.py "$RTL_SRC/os_dep/linux/ioctl_cfg80211.c" \
        || echo "[rtl88xxau] NOTE: cfg80211 patch had no effect (may already be applied)"
    # Build directly in the source dir, exactly as DKMS does.
    if (cd "$RTL_SRC" && make KVER="$CZ_KVER" KSRC="/lib/modules/$CZ_KVER/build"); then
        KO=$(find "$RTL_SRC" -name '88XXau.ko' | head -1)
        if [ -n "$KO" ]; then
            mkdir -p "/lib/modules/$CZ_KVER/updates/dkms"
            cp "$KO" "/lib/modules/$CZ_KVER/updates/dkms/88XXau.ko"
            depmod "$CZ_KVER"
            echo "[rtl88xxau] Built and installed 88XXau.ko for $CZ_KVER"
        else
            echo "[rtl88xxau] WARNING: make succeeded but 88XXau.ko not found"
            find "$RTL_SRC" -name '*.ko' 2>/dev/null | sed 's/^/  found: /'
        fi
    else
        echo "[rtl88xxau] WARNING: manual build failed for $CZ_KVER"
    fi
else
    echo "[rtl88xxau] WARNING: source (${RTL_SRC:-none}) or kernel (${CZ_KVER:-none}) not found"
fi

# Pre-create the kali user with password 'kali' instead of relying on
# cloud-init. Kali's stock Pi image is cloud-init-based — datasource setup
# depends on /boot/firmware/user-data being read BEFORE filesystems are
# mounted, which doesn't always happen reliably. Pre-baking avoids the
# whole class of "user doesn't exist yet at boot" failures (agetty autologin
# loop, sshd rejecting kali, APPLaunch fail to find /home/kali, etc).
if ! getent passwd kali >/dev/null; then
    useradd -m -G sudo,users,audio,video,plugdev,netdev -s /bin/bash kali
fi
echo 'kali:kali' | chpasswd
echo 'kali ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/kali-nopasswd
chmod 440 /etc/sudoers.d/kali-nopasswd

# Device-access groups for APPLaunch-launched apps. APPLaunch runs as root but
# execs apps (.desktop entries, e.g. flint) deprivileged as `kali` via
# setuid/initgroups — so `kali` must directly own the hardware it touches. Stock
# RaspiOS gives its `pi` user this whole set; the Kali base under-provisions it.
#   input   -> /dev/input/event* (TCA8418 keypad) is 0660 root:input; without
#              this, launched GUI apps render but get NO keystrokes.
#   i2c     -> /dev/i2c-* is 0660 root:i2c.
#   dialout -> serial UARTs (/dev/ttyAMA*, GPS/LoRa) when not world-rw.
#   render  -> /dev/dri/render* (GPU); harmless + forward-compatible.
# NOTE: SPI/GPIO/render *nodes* are root:plugdev 0666 here (this image's
# 99-com.rules), and kali is already in plugdev (above), so no spi/gpio groups
# are needed — don't create them; nothing on this image is owned by them.
for grp in input i2c dialout render; do
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

# Hold the load-bearing kernel/bootloader/firmware packages. Kali is rolling
# and users routinely `apt upgrade` to refresh security tools — but that drags
# in upgrades to raspi-firmware (replaces our M5-patched /boot/firmware/
# kernel8.img + bcm2710-rpi-cm0.dtb), firmware-misc-nonfree / kali-linux-firmware
# (replaces our CZ-specific Cypress NVRAM), and the linux-image-rpi-* metas
# (would bring a different kernel version that doesn't match our out-of-tree
# st7789v_m5stack.ko, tca8418_keypad_m5stack.ko, etc.). Any of those bricks
# the LCD; raspi-firmware alone bricks boot.
#
# To intentionally upgrade one of these (e.g. M5Stack publishes a refreshed
# kernel), `sudo apt-mark unhold <pkg>; sudo apt install <pkg>` then re-hold.
# libcamera0.7 is also held: stage_rootfs lifted M5's Pi-patched 0.7.0 over
# Kali's upstream 0.7.1 because the IPA links against Pi-specific symbols.
# An `apt upgrade` of libcamera0.7 would overwrite our patched binary with
# the upstream one and the camera applet would go black again.
apt-mark hold \
    raspi-firmware \
    firmware-misc-nonfree \
    firmware-linux \
    firmware-linux-nonfree \
    kali-linux-firmware \
    linux-image-rpi-v8 \
    linux-image-rpi-2712 \
    linux-headers-rpi-v8 \
    linux-headers-rpi-2712 \
    libcamera0.7

# Re-assert the M5 Pi-patched libcamera lift. apt (just above) installed Kali's
# libcamera0.7 package, clobbering M5's binary — and when M5 and Kali share a
# version number it overwrites M5's *in place*. apt-mark hold only blocks future
# upgrades, not the initial install in the same run. So: move apt's versioned
# libcamera (any X.Y.Z) out, then RESTORE M5's from the stash stage_rootfs saved,
# and let ldconfig re-point the soname. Version-agnostic — no hardcoded numbers.
mkdir -p /root/kali-libcamera-backup
for f in /usr/lib/aarch64-linux-gnu/libcamera.so.[0-9]*.[0-9]*.[0-9]* /usr/lib/aarch64-linux-gnu/libcamera-base.so.[0-9]*.[0-9]*.[0-9]*; do
    [ -f "$f" ] && mv "$f" /root/kali-libcamera-backup/ 2>/dev/null
done
rm -f /usr/lib/aarch64-linux-gnu/libcamera.so.[0-9]* /usr/lib/aarch64-linux-gnu/libcamera-base.so.[0-9]*
cp -af /root/m5-libcamera-pinned/. /usr/lib/aarch64-linux-gnu/ 2>/dev/null
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

# Mask bluetooth daemon (saves ~10 MB; user can unmask if they actually need BT)
systemctl mask bluetooth.service

# Mask serial-getty@ttyS0 so it doesn't fight gpsd for the UART. The LoRa+GNSS
# cap's ATGM336H lives on ttyS0; without this mask, getty grabs the port on
# every boot and gpsd can't claim it. Kernel boot console still uses ttyS0
# for OUTPUT (no read contention with gpsd, baud rates match at 115200), so
# we don't lose serial-port boot debugging. Nobody buying an LCD+keypad
# pocket-deck expects a serial login on the GPIO header anyway.
systemctl mask serial-getty@ttyS0.service

# Enable gpsd so the LoRa+GNSS cap (or any other ttyS0 NMEA source) Just Works
# at boot. /etc/default/gpsd was already written by stage_configs pointing at
# /dev/ttyS0 @ 115200. -n in GPSD_OPTIONS makes it poll immediately so kismet
# / cgps / gpspipe see data without first connecting.
systemctl enable gpsd.socket
systemctl enable gpsd.service

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

    ok "Desktop stack installed"
}

# ── stage_launcher_build (opt-in): build APPLaunch from upstream + cache .deb ─
#
# Mounts the in-progress Kali rootfs as a qemu chroot, installs build
# dependencies, runs scons against M5CardputerZero-Launcher/projects/APPLaunch,
# and packages the dist/ output as a real .deb at
#   $SCRIPT_DIR/applaunch_0.1-cz1+g<short-hash>_arm64.deb
# Cached: if the .deb for the current source HEAD already exists, skip the
# rebuild. Force with LAUNCHER_REBUILD=1.
#
# stage_applaunch will prefer the most-recent locally-built .deb over the
# donor's, unless APPLAUNCH_DEB is set explicitly.
stage_launcher_build() {
    log "Launcher build (opt-in)"

    # The launcher tree may live alongside graft.sh, or one level up (the
    # historical workspace layout). Caller may override via LAUNCHER_SRC.
    local src="${LAUNCHER_SRC:-}"
    if [[ -z "$src" ]]; then
        for candidate in "$SCRIPT_DIR/M5CardputerZero-Launcher" "$SCRIPT_DIR/../M5CardputerZero-Launcher"; do
            [[ -d "$candidate/projects/APPLaunch" ]] && { src="$candidate"; break; }
        done
    fi
    [[ -n "$src" && -d "$src/projects/APPLaunch" ]] \
        || err "Launcher source not found (looked in \$LAUNCHER_SRC, $SCRIPT_DIR/M5CardputerZero-Launcher, $SCRIPT_DIR/../M5CardputerZero-Launcher)"

    require_cmds qemu-aarch64-static git

    # Use git short hash as the cache key. If source isn't a git tree, fall
    # back to a timestamp (won't dedupe but won't break).
    local commit
    if commit=$(git -C "$src" rev-parse --short HEAD 2>/dev/null); then :; else commit=$(date +%Y%m%d%H%M%S); fi
    local deb_name="applaunch_0.1-cz1+g${commit}_arm64.deb"
    local deb_path="$SCRIPT_DIR/$deb_name"

    if [[ -f "$deb_path" && "${LAUNCHER_REBUILD:-0}" != "1" ]]; then
        ok "Cached .deb already present: $deb_name (LAUNCHER_REBUILD=1 to force)"
        return
    fi

    # We need a mounted Kali rootfs to chroot into. If stage_mount hasn't run,
    # do it now (caller may invoke `launcher-build` standalone).
    if ! mountpoint -q "$KALI_ROOT"; then
        stage_check
        stage_unxz
        stage_resize
        stage_mount
    fi

    # Bind kernel filesystems + resolv.conf for apt
    CHROOT_RESOLV="$KALI_ROOT/etc/resolv.conf"
    CHROOT_RESOLV_WAS_SYMLINK=false
    [[ -L "$CHROOT_RESOLV" ]] && CHROOT_RESOLV_WAS_SYMLINK=true
    cp -f /etc/resolv.conf "$CHROOT_RESOLV"
    mount --bind /dev     "$KALI_ROOT/dev"
    mount --bind /dev/pts "$KALI_ROOT/dev/pts"
    mount -t proc proc    "$KALI_ROOT/proc"
    mount -t sysfs sysfs  "$KALI_ROOT/sys"

    # Detect if the launcher source filesystem supports symlinks. If not
    # (exfat-mounted USB drives, fat32, etc.), upstream AppStore's SConstruct
    # fails at `ensure_sysroot_lib_layout()` which symlinks a multiarch alias
    # into static_lib/lib/. Rsync the tree to a scratch dir on the host's
    # main filesystem first, then bind-mount the scratch. Override the
    # scratch path with LAUNCHER_SCRATCH if /var/tmp is undesirable.
    if ! ln -sf /tmp/x "$src/.symlink-probe" 2>/dev/null; then
        local scratch="${LAUNCHER_SCRATCH:-/var/tmp/launcher-build-scratch}"
        log "Source fs at $src doesn't support symlinks (exfat?); staging to $scratch"
        mkdir -p "$scratch"
        rsync -aH --delete "$src/" "$scratch/" 2>&1 | tail -3
        src="$scratch"
        ok "Launcher tree staged to symlink-capable filesystem"
    fi
    rm -f "$src/.symlink-probe" 2>/dev/null

    # Bind source into chroot
    mkdir -p "$KALI_ROOT/src"
    mount --bind "$src" "$KALI_ROOT/src"

    launcher_cleanup() {
        umount -l "$KALI_ROOT/src"     2>/dev/null || true
        umount -l "$KALI_ROOT/sys"     2>/dev/null || true
        umount -l "$KALI_ROOT/proc"    2>/dev/null || true
        umount -l "$KALI_ROOT/dev/pts" 2>/dev/null || true
        umount -l "$KALI_ROOT/dev"     2>/dev/null || true
        if [[ "${CHROOT_RESOLV_WAS_SYMLINK:-false}" == "true" ]]; then
            rm -f "$CHROOT_RESOLV"
            ln -sf /run/systemd/resolve/stub-resolv.conf "$CHROOT_RESOLV" 2>/dev/null || \
            ln -sf /etc/resolvconf/run/resolv.conf "$CHROOT_RESOLV" 2>/dev/null || \
            : > "$CHROOT_RESOLV"
        elif [[ -f "${CHROOT_RESOLV:-}" ]]; then
            : > "$CHROOT_RESOLV"
        fi
    }
    trap launcher_cleanup RETURN

    log "Installing build dependencies in chroot"
    chroot "$KALI_ROOT" /usr/bin/env -i \
        DEBIAN_FRONTEND=noninteractive HOME=/root \
        PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C \
        bash -e <<'CHROOT'
apt-get update -qq
apt-get install -y --no-install-recommends \
    -o Dpkg::Options::="--force-confold" \
    build-essential scons python3-parse python3-tqdm \
    git wget tar xz-utils ca-certificates dpkg-dev \
    libjpeg-dev libpng-dev libfreetype-dev libfontconfig-dev \
    libinput-dev libudev-dev libcamera-dev libcamera0.7 \
    libdrm-dev libgbm-dev libgles-dev libegl-dev libsdl2-dev \
    libasound2-dev libpulse-dev libssl-dev pkg-config cmake unzip
CHROOT

    log "Compiling launcher (chroot, qemu-emulated aarch64)"
    chroot "$KALI_ROOT" /usr/bin/env -i \
        DEBIAN_FRONTEND=noninteractive HOME=/root \
        PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C \
        CardputerZero=y \
        bash -e <<'CHROOT'
# aarch64-linux-gnu-* symlinks → native binaries so CardputerZero=y's
# cross-compile config still works
mkdir -p /usr/local/bin
for t in gcc g++ cpp ld ar strip ranlib nm objcopy objdump readelf as; do
    [ -x /usr/bin/$t ] && ln -sf /usr/bin/$t /usr/local/bin/aarch64-linux-gnu-$t
done

cd /src/projects/APPLaunch
# Pre-stage config_tmp.mk so the top SConstruct doesn't try to download static_lib
mkdir -p build/config
echo 'CONFIG_TOOLCHAIN_SYSROOT=""' > build/config/config_tmp.mk

yes | scons -j$(nproc) 2>&1 | tail -8

[ -x dist/M5CardputerZero-APPLaunch ] || { echo "BUILD FAILED: no binary at dist/"; exit 1; }
strip --strip-unneeded dist/M5CardputerZero-APPLaunch
ls -la dist/M5CardputerZero-APPLaunch

# AppStore is a sibling scons project. The launcher's STORE rotor entry
# spawns /usr/share/APPLaunch/bin/M5CardputerZero-AppStore; without this
# step the binary is missing and clicking STORE silently bounces back to
# the main menu. Mirrors the upstream CI workflow's "Build AppStore" +
# "Copy AppStore into APPLaunch dist" jobs.
if [ -d /src/projects/AppStore/main ]; then
    cd /src/projects/AppStore
    rm -rf build dist
    mkdir -p build/config
    # AppStore's SConstruct auto-writes this file with the full LV_USE_*
    # config when CardputerZero=y, but only if the file doesn't exist. Pre-
    # staging a minimal version (just CONFIG_TOOLCHAIN_SYSROOT) preempts the
    # auto-stage and the resulting build hits `#error Unsupported display
    # configuration` because LV_USE_LINUX_FBDEV isn't set. Write the FULL
    # config ourselves — same flags the SConstruct would have written, plus
    # blank SYSROOT to avoid the static_lib download.
    cat > build/config/config_tmp.mk <<'MK'
CONFIG_V9_5_LV_USE_LINUX_FBDEV=y
CONFIG_V9_5_LV_DRAW_SW_ASM_NEON=y
CONFIG_V9_5_LV_USE_DRAW_SW_ASM=1
CONFIG_V9_5_LV_USE_EVDEV=y
CONFIG_TOOLCHAIN_PREFIX="aarch64-linux-gnu-"
CONFIG_TOOLCHAIN_SYSROOT=""
MK
    # Force SConstruct's ensure_sysroot_lib_layout() to take its "full lib
    # symlink" path. If static_lib/lib exists as a real directory (because the
    # downloaded tarball ships one), the SConstruct only symlinks lib/aarch64-
    # linux-gnu — but the linker also needs lib/ld-linux-aarch64.so.1, which
    # only exists under usr/lib/. Removing static_lib/lib makes SConstruct
    # symlink the whole lib → usr/lib instead, exposing everything the linker
    # wants. Worth filing as an upstream AppStore SConstruct PR; for now,
    # patch around it.
    [ -d static_lib/lib ] && [ ! -L static_lib/lib ] && rm -rf static_lib/lib

    # Filter scons output to keep meaningful lines (warnings/errors and
    # high-level progress); full output is verbose under -j. Tee full log
    # to /src/appstore-build.log for post-mortem if something fails.
    yes | scons -j$(nproc) 2>&1 | tee /src/appstore-build.log | grep -E "(error:|warning:|undefined reference|^CC |^LD |^scons:|FAIL)" || true
    [ -x dist/M5CardputerZero-AppStore ] || { echo "BUILD FAILED: no AppStore binary at dist/"; exit 1; }
    strip --strip-unneeded dist/M5CardputerZero-AppStore
    ls -la dist/M5CardputerZero-AppStore

    # Stage AppStore artifacts into APPLaunch's dist tree so they end up
    # in the .deb in the right places (bin/, share/images/).
    mkdir -p /src/projects/APPLaunch/dist/bin
    cp dist/M5CardputerZero-AppStore /src/projects/APPLaunch/dist/bin/
    cp appstore.py                   /src/projects/APPLaunch/dist/bin/
    mkdir -p /src/projects/APPLaunch/dist/APPLaunch/share/images
    cp share/images/store_wordmark.png \
       share/images/store_arrow_left.png \
       share/images/store_arrow_right.png \
       share/images/store_arrow_up.png \
       share/images/store_arrow_down.png \
       /src/projects/APPLaunch/dist/APPLaunch/share/images/ 2>/dev/null || true
else
    echo "WARN: projects/AppStore submodule not initialized — STORE app will not work"
fi
CHROOT

    log "Packaging .deb"
    chroot "$KALI_ROOT" /usr/bin/env -i \
        DEBIAN_FRONTEND=noninteractive HOME=/root \
        PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C \
        DEB_VERSION="0.1-cz1+g${commit}" DEB_NAME="$deb_name" \
        bash -e <<'CHROOT'
WORK=$(mktemp -d)
SRC=/src/projects/APPLaunch/dist

# Filesystem layout
install -d -m755 "$WORK/usr/share/APPLaunch/bin"
install -m755 "$SRC/M5CardputerZero-APPLaunch" "$WORK/usr/share/APPLaunch/bin/"

# AppStore (built by the previous chroot block; copied into APPLaunch's
# dist/bin/ alongside the launcher). Optional — only install if present.
if [ -x "$SRC/bin/M5CardputerZero-AppStore" ]; then
    install -m755 "$SRC/bin/M5CardputerZero-AppStore" "$WORK/usr/share/APPLaunch/bin/"
fi
if [ -f "$SRC/bin/appstore.py" ]; then
    install -m755 "$SRC/bin/appstore.py" "$WORK/usr/share/APPLaunch/bin/"
fi

# Share tree (applications/, lib/, share/, etc.)
if [ -d "$SRC/APPLaunch" ]; then
    cp -a "$SRC/APPLaunch/." "$WORK/usr/share/APPLaunch/"
fi

# Systemd unit. Note: Kali is usrmerged so /lib → /usr/lib, but per Debian
# policy .deb places unit files under /lib/systemd/system; the symlink takes
# care of routing at install time.
install -d -m755 "$WORK/lib/systemd/system"
cat > "$WORK/lib/systemd/system/APPLaunch.service" <<'EOF'
[Unit]
Description=APPLaunch Service

[Service]
ExecStart=/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch
WorkingDirectory=/usr/share/APPLaunch
Restart=always
RestartSec=1
StartLimitInterval=0

[Install]
WantedBy=multi-user.target
EOF

# DEBIAN metadata
install -d -m755 "$WORK/DEBIAN"
cat > "$WORK/DEBIAN/control" <<EOF
Package: applaunch
Version: ${DEB_VERSION}
Architecture: arm64
Maintainer: CardputerZero local build <root@cardputerzero-kali>
Section: utils
Priority: optional
Depends: libc6, libstdc++6, libcamera0.7, libjpeg62-turbo, libfreetype6, libinput10, libxkbcommon0, libudev1
Description: M5 Cardputer Zero LCD application launcher
 LVGL-based UI for the Cardputer Zero's onboard ST7789V display. Built from
 upstream M5CardputerZero-Launcher source.
EOF

cat > "$WORK/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
mkdir -p /var/cache/APPLaunch
[ -L /usr/share/APPLaunch/cache ] || ln -sf /var/cache/APPLaunch /usr/share/APPLaunch/cache
systemctl daemon-reload 2>/dev/null || true
systemctl enable APPLaunch.service 2>/dev/null || true
EOF
chmod 755 "$WORK/DEBIAN/postinst"

cat > "$WORK/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
systemctl stop APPLaunch.service 2>/dev/null || true
systemctl disable APPLaunch.service 2>/dev/null || true
EOF
chmod 755 "$WORK/DEBIAN/prerm"

# Build the .deb (zstd is the default since dpkg 1.21)
dpkg-deb --build --root-owner-group "$WORK" "/src/$DEB_NAME"
ls -la "/src/$DEB_NAME"
CHROOT

    [[ -f "$src/$deb_name" ]] || err "Build produced no .deb at $src/$deb_name"

    # Move the .deb out of the launcher source tree (which is /src in the chroot)
    # into $SCRIPT_DIR alongside graft.sh.
    if [[ "$src/$deb_name" != "$deb_path" ]]; then
        mv "$src/$deb_name" "$deb_path"
    fi
    chown $(stat -c '%u:%g' "$SCRIPT_DIR") "$deb_path"

    ok "Cached: $deb_name ($(du -h "$deb_path" | cut -f1))"
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

    # 3. /etc/hosts entry for the hostname (kills "sudo: unable to resolve host"
    #    warnings that otherwise spam every sudo invocation).
    local hosts="$KALI_ROOT/etc/hosts"
    if ! grep -qE "^127\.0\.1\.1[[:space:]]+$CZ_HOSTNAME\b" "$hosts" 2>/dev/null; then
        echo "127.0.1.1	$CZ_HOSTNAME" >> "$hosts"
    fi

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
    log "Verifying graft integrity"
    VERIFY_ERRS=0

    # /lib symlink (the landmine)
    [[ -L "$KALI_ROOT/lib" ]] || vfail "/lib is not a symlink (usrmerge broken)"
    [[ -L "$KALI_ROOT/lib/ld-linux-aarch64.so.1" ]] || vfail "ld-linux-aarch64.so.1 not reachable via /lib"

    # Boot files (no u-boot.bin — we boot kernel8.img directly via the GPU loader,
    # matching the OEM image.)
    for f in kernel8.img bcm2710-rpi-cm0.dtb \
             overlays/cardputerzero-overlay.dtbo \
             overlays/lsm6ds3tr-overlay.dtbo \
             overlays/camera-gpio16-high-overlay.dtbo \
             overlays/spk-gpio24-high-overlay.dtbo; do
        [[ -f "$KALI_BOOT/$f" ]] || vfail "missing boot file: $f"
    done

    # Kernel <-> modules match. THE check that would have caught the 2026-06
    # donor skew: a moving "latest" donor bumped kernel8.img to 6.18.29 while the
    # rootfs still carried 6.12.75 modules (left over from re-running on an old
    # image), so the kernel booted with ZERO loadable drivers — black LCD, no
    # HDMI, no network. The boot kernel's version string MUST have a matching
    # /lib/modules/<ver> dir or the image is dead on arrival.
    local kver
    # `|| true`: grep -m1 closes the pipe on first match, SIGPIPE-ing strings,
    # which returns 141 under `set -o pipefail` — harmless here (the value is
    # already captured), so don't let it abort the build.
    kver=$( { zcat "$KALI_BOOT/kernel8.img" 2>/dev/null || cat "$KALI_BOOT/kernel8.img"; } \
            | strings 2>/dev/null | grep -m1 'Linux version' | awk '{print $3}' ) || true
    if [[ -z "$kver" ]]; then
        vfail "could not read kernel8.img version (cannot verify kernel<->modules match)"
    elif [[ ! -d "$KALI_ROOT/lib/modules/$kver" ]]; then
        vfail "kernel8.img is $kver but rootfs has no /lib/modules/$kver — donor skew, image boots with NO drivers. Have: $(ls "$KALI_ROOT/lib/modules" 2>/dev/null | tr '\n' ' ')"
    else
        ok "kernel8.img $kver matches /lib/modules/$kver"
    fi

    # Configs reference our overlays
    grep -q '^dtoverlay=cardputerzero-overlay' "$KALI_BOOT/config.txt" || vfail "cardputerzero-overlay not in config.txt"
    ! grep -q '^kernel=u-boot.bin'             "$KALI_BOOT/config.txt" || vfail "stale kernel=u-boot.bin in config.txt (should boot kernel8.img directly)"
    grep -q 'root=PARTUUID='                   "$KALI_BOOT/cmdline.txt" || vfail "cmdline.txt has no root=PARTUUID"

    # Confirm we installed our patched cardputerzero-overlay (num-cs=2) and
    # not the donor's stock one (num-cs=3) that collides with the LoRa cap's
    # BUSY signal on GPIO22. dtc isn't always available in the build host so
    # we compare against the known size of our vendored fix (6790 bytes).
    if command -v dtc >/dev/null 2>&1; then
        dtc -I dtb -O dts "$KALI_BOOT/overlays/cardputerzero-overlay.dtbo" 2>/dev/null \
            | grep -q 'num-cs = <0x02>' \
            || vfail "installed cardputerzero-overlay still has num-cs != 2 (GPIO22 collides with LoRa cap)"
    else
        local cz_ovl_sz; cz_ovl_sz=$(stat -c %s "$KALI_BOOT/overlays/cardputerzero-overlay.dtbo" 2>/dev/null || echo 0)
        [[ "$cz_ovl_sz" -eq 6790 ]] \
            || vfail "cardputerzero-overlay.dtbo size $cz_ovl_sz != expected 6790 (likely stock M5 with the GPIO22 CS2 conflict)"
    fi

    # bq27220: must NOT have an overlay, driver, or any sysfs binding. The chip
    # has no in-tree Linux driver; APPLaunch reads it directly via /dev/i2c-1.
    ! grep -q '^dtoverlay=bq27220'        "$KALI_BOOT/config.txt"                                    || vfail "stale dtoverlay=bq27220 in config.txt (no in-tree driver — remove it)"
    [[ ! -f "$KALI_BOOT/overlays/bq27220.dtbo" ]]                                                    || vfail "stale bq27220.dtbo in /boot/overlays (no in-tree driver — remove it)"
    [[ ! -f "$KALI_ROOT/usr/lib/modules/$kver/kernel/drivers/power/supply/bq27xxx_battery.ko" ]] \
        || vfail "stale bq27xxx_battery.ko in rootfs (out-of-tree binary, no GPL source — remove it)"

    # /dev/i2c-1 autoload (APPLaunch's bq27220 reader needs it)
    grep -qx 'i2c-dev' "$KALI_ROOT/etc/modules-load.d/i2c-dev.conf" 2>/dev/null \
        || vfail "i2c-dev not in /etc/modules-load.d/i2c-dev.conf (APPLaunch will see no battery)"

    # ALSA routing must point default at hw:1,0 (ES8389) via softvol, or no
    # audio app works ("Unknown PCM cards.pcm.front") and alsamixer has no
    # adjustable controls (kernel codec module exposes none natively).
    grep -q 'slave.pcm "hw:1,0"' "$KALI_ROOT/etc/asound.conf" 2>/dev/null \
        || vfail "asound.conf missing or not routed at hw:1,0 (audio will be silent)"

    # gpsd config + service state must be ready for the LoRa+GNSS cap.
    # serial-getty@ttyS0 must be masked or it'll fight gpsd for /dev/ttyS0
    # at every boot and the LoRa cap's GPS will appear dead.
    grep -q '^DEVICES="/dev/ttyS0"' "$KALI_ROOT/etc/default/gpsd" 2>/dev/null \
        || vfail "/etc/default/gpsd not pointed at /dev/ttyS0 (LoRa cap GPS won't be readable)"
    [[ -L "$KALI_ROOT/etc/systemd/system/serial-getty@ttyS0.service" \
       && "$(readlink "$KALI_ROOT/etc/systemd/system/serial-getty@ttyS0.service")" == "/dev/null" ]] \
        || vfail "serial-getty@ttyS0 not masked (will steal ttyS0 from gpsd on boot)"
    [[ -L "$KALI_ROOT/etc/systemd/system/multi-user.target.wants/gpsd.service" \
       || -L "$KALI_ROOT/etc/systemd/system/sockets.target.wants/gpsd.socket" ]] \
        || vfail "gpsd not enabled at boot (LoRa cap GPS won't auto-start)"

    # /etc/environment must carry GLYCIN_SANDBOX_MECHANISM so pam_env propagates
    # it into lightdm X sessions (without it, pcmanfm fails to load the
    # wallpaper JPEG via glycin and the LXDE desktop is solid black).
    grep -q '^GLYCIN_SANDBOX_MECHANISM=not-sandboxed' "$KALI_ROOT/etc/environment" 2>/dev/null \
        || vfail "GLYCIN_SANDBOX_MECHANISM missing from /etc/environment (LXDE wallpaper will be black)"

    # LXDE autostart must disable X screen blanking + DPMS or HDMI goes dark
    # after 10 min — bad demo material on an always-on or kiosk device.
    grep -qE '^xset -dpms' "$KALI_ROOT/etc/xdg/lxsession/LXDE/autostart" 2>/dev/null \
        || vfail "LXDE autostart missing 'xset -dpms' (HDMI will blank after 10 min)"

    # graphical.target must be the default or display-manager (lightdm) never
    # starts at boot — its [Install] only declares WantedBy=graphical.target.
    [[ -L "$KALI_ROOT/etc/systemd/system/default.target" \
       && "$(readlink "$KALI_ROOT/etc/systemd/system/default.target")" =~ graphical\.target$ ]] \
        || vfail "default.target is not graphical.target (lightdm won't auto-start)"

    # Camera userspace (lifted from M5 donor in stage_rootfs). All three are
    # required to render frames; any one missing and the applet shows black.
    [[ -f "$KALI_ROOT/usr/lib/aarch64-linux-gnu/libcamera/ipa/ipa_rpi_vc4.so" ]] \
        || vfail "ipa_rpi_vc4.so missing (camera applet will be black)"
    [[ -f "$KALI_ROOT/usr/libexec/aarch64-linux-gnu/libcamera/raspberrypi_ipa_proxy" ]] \
        || vfail "raspberrypi_ipa_proxy missing (IPA can't be hosted)"
    # libcamera: the Pi-patched build lifted from the donor must be the one in
    # /usr/lib. Version derived from the donor (M5 bumps it: 0.7.0 -> 0.7.1 -> …),
    # which may now equal Kali's number but with the Pi patches Kali lacks.
    local m5lc m5maj
    m5lc=$(basename "$(ls "$CZ_ROOT"/usr/lib/aarch64-linux-gnu/libcamera.so.[0-9]*.[0-9]*.[0-9]* 2>/dev/null | sort -V | tail -1)" 2>/dev/null | sed 's/^libcamera\.so\.//') || true
    if [[ -z "$m5lc" ]]; then
        vfail "could not determine donor libcamera version"
    else
        m5maj="${m5lc%.*}"   # 0.7.1 -> 0.7
        [[ -f "$KALI_ROOT/usr/lib/aarch64-linux-gnu/libcamera.so.$m5lc" ]] \
            || vfail "libcamera $m5lc (M5 Pi-patched) missing — IPA needs CnnEnableInputTensor symbol"
        if [[ -L "$KALI_ROOT/usr/lib/aarch64-linux-gnu/libcamera.so.$m5maj" ]]; then
            [[ "$(readlink "$KALI_ROOT/usr/lib/aarch64-linux-gnu/libcamera.so.$m5maj")" == "libcamera.so.$m5lc" ]] \
                || vfail "libcamera.so.$m5maj soname not pointed at $m5lc (camera would use wrong ABI)"
        fi
        # No OTHER versioned libcamera should linger (Kali's was moved to backup).
        for other in "$KALI_ROOT"/usr/lib/aarch64-linux-gnu/libcamera.so.[0-9]*.[0-9]*.[0-9]*; do
            if [[ -f "$other" && "$(basename "$other")" != "libcamera.so.$m5lc" ]]; then
                vfail "stale $(basename "$other") in /usr/lib (ldconfig may pick it over $m5lc)"
            fi
        done
    fi

    # M5 modules
    for mod in pwm_bl_m5stack es8389_m5stack st7789v_m5stack tca8418_keypad_m5stack m5ioe1; do
        [[ -f "$KALI_ROOT/usr/lib/modules/$kver/extra/$mod.ko" ]] \
            || vfail "M5 module missing: $mod.ko"
    done

    # AWUS036ACS (RTL8811AU) driver built by DKMS in stage_packages.
    # Installed to updates/dkms/ by DKMS postinst; absent means the DKMS build
    # failed (usually: headers not copied from donor before stage_packages ran,
    # or gcc/make not available in the chroot when rtl88xxau-dkms was configured).
    find "$KALI_ROOT/usr/lib/modules" -name '88XXau.ko*' \
            -path '*/updates/dkms/*' -not -path '*/6.12.*' 2>/dev/null | grep -q . \
        || vfail "88XXau.ko missing for M5 boot kernel (DKMS build failed — AWUS036ACS won't work)"

    # First-boot rootfs grow (cloud-init is disabled, so this is what fills the card)
    [[ -x "$KALI_ROOT/usr/local/sbin/cz-firstboot-resize.sh" ]] \
        || vfail "cz-firstboot-resize.sh missing (rootfs won't auto-grow on first boot)"
    [[ -L "$KALI_ROOT/etc/systemd/system/multi-user.target.wants/cz-firstboot-resize.service" ]] \
        || vfail "cz-firstboot-resize.service not enabled (rootfs won't auto-grow)"
    [[ -x "$KALI_ROOT/usr/bin/growpart" || -x "$KALI_ROOT/usr/local/bin/growpart" ]] \
        || vfail "growpart not in image (cloud-guest-utils) — first-boot resize will no-op"

    # APPLaunch
    [[ -x "$KALI_ROOT/usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch" ]] \
        || vfail "APPLaunch binary missing"
    [[ -L "$KALI_ROOT/etc/systemd/system/multi-user.target.wants/APPLaunch.service" ]] \
        || vfail "APPLaunch.service not enabled (no symlink in multi-user.target.wants)"
    [[ -f "$KALI_ROOT/etc/systemd/system/APPLaunch.service.d/wait-for-udev.conf" ]] \
        || vfail "APPLaunch udev-wait drop-in missing (keypad will race udev and silently fail to grab)"

    # CM0 WiFi firmware (the missing .clm_blob landmine)
    [[ -e "$KALI_ROOT/usr/lib/firmware/brcm/brcmfmac43430-sdio.raspberrypi,0-compute-module.clm_blob" ]] \
        || vfail "CM0 43430 .clm_blob missing or unresolved"

    # BCM43439 NVRAM has the right boardflags3 (donor 0x04000000, not Kali default 0x08000000).
    # The chip wedges with HT timeout on the wrong value — see project_wifi_nvram_boardflags3.
    local nvram="$KALI_ROOT/usr/lib/firmware/cypress/cyfmac43439-sdio.txt"
    if [[ -f "$nvram" ]]; then
        grep -q '^boardflags3=0x04000000' "$nvram" \
            || vfail "BCM43439 NVRAM has wrong boardflags3 (need 0x04000000 from donor)"
    else
        vfail "BCM43439 NVRAM cyfmac43439-sdio.txt missing"
    fi

    # cmdline.txt has 'quiet' so kernel logs don't clobber APPLaunch on LCD
    grep -qw 'quiet' "$KALI_BOOT/cmdline.txt" \
        || vfail "cmdline.txt missing 'quiet' (LCD will show kernel log spam over APPLaunch)"

    # Desktop stack baked in (replaces the old firstboot-fetch approach)
    [[ -x "$KALI_ROOT/usr/bin/lxsession" ]] \
        || vfail "lxsession not installed (stage_packages didn't run or failed)"
    [[ -x "$KALI_ROOT/usr/lib/lightdm-autologin-greeter/lightdm-autologin-greeter" ]] \
        || vfail "lightdm-autologin-greeter not installed"
    [[ -f "$KALI_ROOT/usr/lib/systemd/system/lightdm.service" ]] \
        || vfail "lightdm not installed"
    [[ -L "$KALI_ROOT/etc/systemd/system/multi-user.target.wants/zramswap.service" ]] \
        || vfail "zramswap.service not enabled"
    [[ -f "$KALI_ROOT/etc/systemd/system/getty@tty1.service.d/autologin.conf" ]] \
        || vfail "getty@tty1 autologin drop-in missing"
    [[ -f "$KALI_ROOT/etc/systemd/system/dbus.service.d/workdir.conf" ]] \
        || vfail "dbus.service WorkingDirectory drop-in missing (would cascade-fail dbus/polkit/NM)"
    [[ -f "$KALI_ROOT/etc/default/zramswap" ]] \
        || vfail "/etc/default/zramswap config missing"
    [[ -f "$KALI_ROOT/etc/lightdm/lightdm.conf.d/lightdm-autologin-greeter.conf" ]] \
        || vfail "lightdm autologin conf missing"
    grep -q '^wallpaper=/usr/share/backgrounds/kali/' "$KALI_ROOT/etc/xdg/pcmanfm/LXDE/pcmanfm.conf" 2>/dev/null \
        || vfail "pcmanfm.conf wallpaper not pointing at Kali bg (would show solid black on startup)"
    grep -q '^PERCENT=75' "$KALI_ROOT/etc/default/zramswap" 2>/dev/null \
        || vfail "zramswap PERCENT not bumped to 75 (LXDE menu open will OOM-thrash)"
    [[ -L "$KALI_ROOT/etc/systemd/system/bluetooth.service" \
       && "$(readlink "$KALI_ROOT/etc/systemd/system/bluetooth.service")" == "/dev/null" ]] \
        || vfail "bluetooth.service not masked (~10 MB resident on a 415 MB device)"
    grep -q '^Hidden=true' "$KALI_ROOT/etc/xdg/autostart/blueman.desktop" 2>/dev/null \
        || vfail "blueman.desktop autostart not disabled (memory diet not applied)"
    [[ -f "$KALI_ROOT/etc/environment.d/glycin-nosandbox.conf" ]] \
        || vfail "GLYCIN_SANDBOX_MECHANISM env override missing"
    [[ -f "$KALI_ROOT/etc/X11/xorg.conf.d/40-cardputerzero-no-grab.conf" ]] \
        || vfail "Xorg ignore-keypad config missing (integrated kbd would get stolen from APPLaunch)"
    [[ -f "$KALI_ROOT/etc/X11/xorg.conf.d/98-vc4-no-glamor.conf" ]] \
        || vfail "Xorg no-glamor config missing (Xorg will fail to allocate V3D tile-binning buffers on this RAM)"
    [[ -x "$KALI_ROOT/home/pi/zeroclaw" ]] \
        || vfail "/home/pi/zeroclaw missing (Claw applet will instantly exit)"

    # Apt holds for the load-bearing kernel/bootloader/firmware packages —
    # without these a casual `apt upgrade` will replace kernel8.img, the dtb,
    # or the firmware blobs and the LCD/keypad will silently die on next boot.
    for pkg in raspi-firmware firmware-misc-nonfree firmware-linux \
               firmware-linux-nonfree kali-linux-firmware \
               linux-image-rpi-v8 linux-image-rpi-2712; do
        awk -v pkg="$pkg" '
            BEGIN{found=0; held=0}
            /^Package: /{p=($2==pkg)}
            p && /^Status: hold ok installed$/{held=1}
            p && /^Package: /{found=1}
            END{exit !(held)}
        ' "$KALI_ROOT/var/lib/dpkg/status" \
            || vfail "package $pkg not apt-held (apt upgrade will brick the kernel/firmware)"
    done
    grep -qw 'fbcon=map:99' "$KALI_BOOT/cmdline.txt" \
        || vfail "cmdline.txt missing 'fbcon=map:99' (kernel will paint console over APPLaunch's LCD when HDMI is unplugged)"
    grep -qw 'quiet' "$KALI_BOOT/cmdline.txt" \
        || vfail "cmdline.txt missing 'quiet' (kernel log will spam fbcon)"

    # Tweaks landed
    grep -q '^managed=true' "$KALI_ROOT/etc/NetworkManager/NetworkManager.conf" 2>/dev/null \
        || vfail "NM ifupdown integration not set to managed=true (eth0 won't auto-up)"
    [[ "$(readlink "$KALI_ROOT/etc/systemd/system/networking.service" 2>/dev/null)" == "/dev/null" ]] \
        || vfail "networking.service not masked (will time out at boot)"
    grep -qE "^127\.0\.1\.1[[:space:]]+$CZ_HOSTNAME\b" "$KALI_ROOT/etc/hosts" \
        || vfail "/etc/hosts missing entry for $CZ_HOSTNAME (sudo will warn)"

    # / mode 700 destroys the whole system: every non-root setuid fails to
    # traverse / → ld.so can't open libselinux.so.1 → bash/dbus/polkit/sshd
    # session/agetty autologin all fail with "permission denied" cascades.
    # Must be 755. Other critical dirs must also be world-traversable.
    local d mode
    for d in / /usr /usr/bin /usr/sbin /usr/lib /lib /etc /var /var/lib /run /home; do
        # -L follows symlinks so we check the target's mode (e.g. /lib → /usr/lib
        # on usrmerged systems). The symlink's own mode is always 777 and
        # irrelevant for traversal.
        mode=$(stat -L -c '%a' "$KALI_ROOT$d" 2>/dev/null) || continue
        [[ "$mode" == "755" || "$mode" == "555" ]] \
            || vfail "$d has mode $mode (must be 755 or 555 — non-root services will fail)"
    done
    # /tmp is the exception — must be 1777 (sticky world-writable), not 755.
    # apt-get in our chroot mkstemp's here and silently fails otherwise.
    mode=$(stat -L -c '%a' "$KALI_ROOT/tmp" 2>/dev/null)
    [[ "$mode" == "1777" ]] || vfail "/tmp has mode $mode (must be 1777 — apt + many .debs mkstemp here)"

    if (( VERIFY_ERRS == 0 )); then
        ok "All checks passed"
        return 0
    else
        err "$VERIFY_ERRS check(s) failed"
    fi
}

stage_shell() {
    log "Dropping into interactive shell. Type 'exit' to unmount & clean up."
    dim "cz_boot=$CZ_BOOT  cz_root=$CZ_ROOT  kali_boot=$KALI_BOOT  kali_root=$KALI_ROOT"
    PS1='\[\033[1;35m\][graft]\[\033[0m\] \w \$ ' bash --norc -i
}

stage_fresh() {
    log "Removing $OUT_IMG (will be re-decompressed on next run)"
    rm -f "$OUT_IMG"
    ok "Fresh start ready"
}

# ── stage_deploy_ssh: drop a pubkey into a flashed SD card ─────────────────
#
# Usage: sudo ./graft.sh deploy-ssh /dev/sdX [pubkey-file]
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
    deploy_cleanup() { umount -l "$mnt" 2>/dev/null || true; rmdir "$mnt" 2>/dev/null || true; }
    trap deploy_cleanup RETURN

    getent passwd kali >/dev/null 2>&1 || true   # host check is irrelevant; check inside rootfs
    grep -q '^kali:' "$mnt/etc/passwd" \
        || err "No kali user in target rootfs — re-run packages stage first"

    install -d -m700 "$mnt/home/kali/.ssh"
    cp "$pubkey_file" "$mnt/home/kali/.ssh/authorized_keys"
    chmod 600 "$mnt/home/kali/.ssh/authorized_keys"
    # Use the target's kali UID/GID (1000:1000 — pre-baked by stage_packages)
    chown 1000:1000 "$mnt/home/kali/.ssh/authorized_keys"
    chown 1000:1000 "$mnt/home/kali/.ssh"

    sync
    ok "Pubkey deployed to $target_dev (kali user)"
    dim "Card safe to pull and boot — ssh kali@<ip> will work key-only."
}

stage_summary() {
    sync
    log "Summary"
    dim "Image:    $OUT_IMG ($(du -h "$OUT_IMG" | cut -f1))"
    dim "PARTUUID: $(blkid -s PARTUUID -o value "${KALI_LOOP}p2" 2>/dev/null || echo "?")"
    echo
    echo "To flash:"
    echo "  lsblk"
    echo "  sudo dd if='$OUT_IMG' of=/dev/sdX bs=4M status=progress conv=fsync"
    echo
    echo "After boot, expected serial console at 115200 baud."
    echo "SSH should come up automatically with kali:kali."
}

# ─── Main ────────────────────────────────────────────────────────────────────

show_help() {
    cat <<'HELP'
graft.sh — assemble a Kali arm64 image that runs APPLaunch on the M5 Cardputer Zero LCD.

Stages (run any subset; default is "all"):
  check     | verify host tooling + input images exist
  donor     | fetch + decompress the OEM CZ donor (skip if CZ_IMG present)
  unxz      | decompress Kali base .xz (skip if .img exists)
  resize    | grow Kali rootfs by $GROW_GB (skip if already grown)
  mount     | loop-attach + mount both images (CZ ro, Kali rw)
  boot      | transplant kernel/dtb/overlays + write merged config.txt/cmdline.txt/user-data
  rootfs    | copy CZ kernel modules + CM0 BCM firmware blobs + Cypress NVRAM (incl. BCM43439 boardflags3 fix)
  applaunch      | install APPLaunch .deb (prefers local build, else donor's bundled one)
  launcher-build | (opt-in, NOT in 'all') build APPLaunch from upstream source + cache .deb. LAUNCHER_REBUILD=1 to force.
  configs        | write static configs (glycin env, fbcon disable, X input ignore, lightdm autologin, skel)
  packages       | chroot via qemu-user-static and apt-install LXDE + lightdm-autologin-greeter + zram-tools + feh
  tweaks    | NM managed=true, mask networking.service, /etc/hosts entry
  verify    | sanity-check the result
  shell     | mount everything and drop into an interactive bash for tinkering
  deploy-ssh| (post-flash) drop a pubkey into kali user on a flashed SD card. DEPLOY_SSH_DEV=/dev/sdX [DEPLOY_SSH_PUBKEY=path]
  fresh     | delete the current .img so the next run starts from .xz

Examples:
  sudo ./graft.sh                            # run everything
  sudo ./graft.sh boot verify                # re-do just the boot partition + verify
  sudo ./graft.sh shell                      # mount + interactive subshell
  sudo CZ_HOSTNAME=cz-test ./graft.sh boot   # custom hostname
  sudo APPLAUNCH_DEB=/path/to/new.deb ./graft.sh applaunch  # swap APPLaunch build

Environment overrides (defaults resolve against \$SCRIPT_DIR):
  CZ_IMG          path to decompressed donor .img (default: \$SCRIPT_DIR/cardputerzero-trixie-arm64-latest.img)
  CZ_XZ           path to donor .img.xz (default: \$SCRIPT_DIR/cardputerzero-trixie-arm64-latest.img.xz)
  CZ_URL          URL to fetch CZ_XZ from if absent (default: M5Stack OSS bucket)
  KALI_XZ         path to kali-…-arm64.img.xz source (default: \$SCRIPT_DIR/kali-linux-2026.1-raspberry-pi-arm64.img.xz)
  OUT_IMG         path to the produced .img (defaults to KALI_XZ minus .xz)
  APPLAUNCH_DEB   path to applaunch_*.deb (defaults: most recent \$SCRIPT_DIR/applaunch_*.deb, else donor's bundled)
  LAUNCHER_SRC    path to M5CardputerZero-Launcher (auto-detected if alongside or one level up)
  CZ_HOSTNAME     hostname to set in cloud-init user-data (default: cardputerzero-kali)
  GROW_GB         extra GiB to add to rootfs (default: 4)
HELP
}

# Help/version need no privileges — handle before sudo re-exec
case "${1:-}" in
    -h|--help|help) show_help; exit 0 ;;
esac

require_root "$@"

# Run sequence ─ default is "all"; user may pass any sequence of stages
STAGES=("$@")
[[ ${#STAGES[@]} -gt 0 ]] || STAGES=(all)

run_stage() {
    case "$1" in
        check)     stage_check ;;
        drift)     check_donor_drift ;;
        donor)     stage_check; stage_donor ;;
        unxz)      stage_check; stage_unxz ;;
        resize)    stage_check; stage_unxz; stage_resize ;;
        mount)     stage_check; stage_donor; stage_unxz; stage_resize; stage_mount ;;
        boot)      stage_check; stage_donor; stage_unxz; stage_resize; stage_mount; stage_boot ;;
        rootfs)    stage_check; stage_donor; stage_unxz; stage_resize; stage_mount; stage_rootfs ;;
        applaunch) stage_check; stage_donor; stage_unxz; stage_resize; stage_mount; stage_applaunch ;;
        launcher-build) stage_check; stage_launcher_build ;;
        configs)   stage_check; stage_donor; stage_unxz; stage_resize; stage_mount; stage_configs ;;
        packages)  stage_check; stage_donor; stage_unxz; stage_resize; stage_mount; stage_packages ;;
        tweaks)    stage_check; stage_donor; stage_unxz; stage_resize; stage_mount; stage_tweaks ;;
        verify)    stage_check; stage_donor; stage_unxz; stage_resize; stage_mount; stage_verify ;;
        shell)     stage_check; stage_donor; stage_unxz; stage_resize; stage_mount; stage_shell ;;
        deploy-ssh) stage_deploy_ssh ;;
        fresh)     cleanup; stage_fresh ;;
        all)
            stage_check
            stage_donor
            stage_unxz
            stage_resize
            stage_mount
            stage_boot
            stage_rootfs
            stage_applaunch
            stage_configs
            stage_packages
            stage_tweaks
            stage_verify
            stage_summary
            ;;
        *) err "Unknown stage: $1 (try: $0 --help)" ;;
    esac
}

for s in "${STAGES[@]}"; do run_stage "$s"; done
