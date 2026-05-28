# graft.sh — Kali on the M5 Cardputer Zero

`graft.sh` builds a Kali Linux arm64 SD-card image that runs M5Stack's stock
**APPLaunch** on the device's onboard ST7789V LCD, while keeping HDMI/SSH/Kali
tools available as the secondary UX. It works by **grafting** the CZ-specific
bits (M5-patched kernel + modules, carrier-board device-tree overlays,
WiFi/Bluetooth firmware, APPLaunch itself) onto a vanilla Kali Pi-arm64 image,
then chroot-installing the desktop stack via `qemu-user-static`.

The result is a single flashable `.img` file that boots straight to a working
launcher + console-mode autologin + opt-in LXDE on HDMI, all reproducible from
sources.

---

## TL;DR

```bash
# One-time host setup
sudo pacman -S qemu-user-static qemu-user-static-binfmt \
               aarch64-linux-gnu-gcc aarch64-linux-gnu-binutils \
               scons python-parse python-tqdm python-requests

# Build the (cached) launcher .deb from upstream source — only when the
# launcher source changes
sudo ./graft.sh launcher-build

# Build the full image (uses the cached .deb)
sudo ./graft.sh fresh all

# Flash
sudo dd if=kali-linux-2026.1-raspberry-pi-arm64.img \
        of=/dev/sdX bs=4M status=progress conv=fsync

# Drop your ssh pubkey onto the flashed card (image stays generic)
sudo DEPLOY_SSH_DEV=/dev/sdX ./graft.sh deploy-ssh
```

Then pull the card, boot, and:
- **LCD** shows APPLaunch (the M5 launcher) immediately
- **HDMI** (if plugged) shows a tty1 autologin as `kali`
- **SSH** `kali@<ip>` works key-only

---

## What you need in this directory

| File | Origin | Role |
|---|---|---|
| `graft.sh` | this repo | the build/flash/deploy script |
| `vendored/` | this repo | the `lsm6ds3tr-overlay` `.dtbo`/`.dts` (IMU; binds to the in-tree `st_lsm6dsx` driver) that the OEM image doesn't ship |
| `cache/` | populated at graft time, gitignored | fetched-and-verified upstream tarballs (currently just `zeroclaw-*.tar.gz`, pinned by SHA-256) |
| `cardputerzero-trixie-arm64-latest.img.xz` | M5Stack's [OSS bucket](https://cardputer-zero-repo.oss-cn-shenzhen.aliyuncs.com/cardputerzero-trixie-arm64-latest.img.xz); `stage_donor` will fetch it automatically | donor for kernel/modules/firmware/overlays — known-good OEM baseline so anyone can reproduce, even if they've tinkered on their CZ |
| `CardputerZero.img` (optional override) | `dd` of your own stock SD card | use via `CZ_IMG=/path/to/CardputerZero.img` if you want to graft from a field-modified donor instead |
| `kali-linux-2026.1-raspberry-pi-arm64.img.xz` | https://kali.download/arm-images/ | base rootfs |
| `M5CardputerZero-Launcher/` | https://github.com/CardputerZero/M5CardputerZero-Launcher | launcher source (auto-detected one level up too, for the workspace layout) |
| `applaunch_*_arm64.deb` | produced by `launcher-build` | cached prebuilt launcher |
| `kali-linux-2026.1-raspberry-pi-arm64.img` | produced by `unxz` + `all` | the flashable result |

---

## Stages

`graft.sh` is a staged pipeline; you can run any subset.

| Stage | What it does |
|---|---|
| `check` | Verify host tooling + input images |
| `donor` | Fetch the OEM CZ donor .img.xz from M5Stack's bucket if absent, then decompress (skipped if `CZ_IMG` exists) |
| `unxz` | Decompress Kali base .xz (skipped if .img already exists) |
| `resize` | Grow Kali rootfs by `$GROW_GB` (default 4 GiB → 18 GiB total) |
| `mount` | Loop-attach + mount both donor (ro) and Kali (rw) |
| `boot` | Transplant CZ kernel/dtb + write merged config.txt/cmdline.txt/cloud-init user-data. Copies `cardputerzero-overlay.dtbo` from donor; sources `lsm6ds3tr-overlay.dtbo` from `vendored/` when the donor lacks it (the OEM does) |
| `rootfs` | Copy CZ kernel modules + CM0 BCM firmware + Cypress NVRAM (incl. BCM43439 boardflags3 fix). Re-runs `depmod` |
| `applaunch` | Install APPLaunch .deb (prefers `applaunch_*_arm64.deb` from this dir, falls back to donor's). Also creates `/home/pi` and installs `vendored/zeroclaw` there |
| `launcher-build` | **(opt-in)** Build APPLaunch from `M5CardputerZero-Launcher/` source in a qemu chroot, package as a .deb, cache here. `LAUNCHER_REBUILD=1` to force re-build. |
| `configs` | Write static configs: glycin no-sandbox env, fbcon disable, X input ignore, X no-glamor, lightdm autologin, /etc/skel, agetty autologin, dbus WorkingDirectory drop-in |
| `packages` | chroot-apt install `lxde-core`, `lightdm-autologin-greeter`, `zram-tools`, `feh`, `libcamera0.7`; pre-create kali user; set startx default = LXDE; defensive `chmod 755 /` |
| `tweaks` | NM `managed=true`, mask `networking.service`, write `/etc/hosts` entry |
| `verify` | Sanity-check every fix landed correctly |
| `shell` | Mount everything + interactive bash for tinkering |
| `deploy-ssh` | **(post-flash)** Mount a flashed card and drop your pubkey into `/home/kali/.ssh/authorized_keys` |
| `fresh` | Delete the current .img so the next run starts from .xz |
| `all` | Full pipeline (skips `launcher-build` — that's opt-in) |

---

## Workflows

### A. First-time clean build

```bash
sudo ./graft.sh launcher-build   # ~15-25 min, downloads SDK on first run
sudo ./graft.sh fresh all        # ~25 min (unxz + chroot apt is the slow part)
sudo dd if=kali-linux-2026.1-raspberry-pi-arm64.img \
        of=/dev/sdX bs=4M status=progress conv=fsync
sudo DEPLOY_SSH_DEV=/dev/sdX ./graft.sh deploy-ssh
```

### B. Iterating on the launcher

Edit code in `M5CardputerZero-Launcher/projects/APPLaunch/`, then:

```bash
sudo LAUNCHER_REBUILD=1 ./graft.sh launcher-build   # ~2-5 min incremental
```

The new `applaunch_0.1-cz1+g<short-hash>_arm64.deb` gets cached here. Either
re-build the full image, or scp the new binary directly:

```bash
scp M5CardputerZero-Launcher/projects/APPLaunch/dist/M5CardputerZero-APPLaunch \
    kali@<ip>:/tmp/
ssh kali@<ip> 'sudo systemctl stop APPLaunch && \
  sudo install -m755 /tmp/M5CardputerZero-APPLaunch \
       /usr/share/APPLaunch/bin/M5CardputerZero-APPLaunch && \
  sudo systemctl start APPLaunch'
```

### C. Iterating on configs only

```bash
sudo ./graft.sh configs tweaks verify   # ~30 sec; reuses mounted image
sudo dd ...                              # re-flash
```

### D. Iterating on packages

```bash
sudo ./graft.sh packages verify   # ~5 min if apt cache is fresh
```

### E. Tinkering in a chroot

```bash
sudo ./graft.sh shell
# you're now in bash with /mnt/kali_{boot,root} and /mnt/cz_{boot,root} mounted
# poke around, then `exit` to clean up
```

### F. Override the launcher .deb

```bash
sudo APPLAUNCH_DEB=/path/to/some-other-applaunch.deb ./graft.sh applaunch
```

### G. Use a different host's SSH key

```bash
sudo DEPLOY_SSH_DEV=/dev/sdX DEPLOY_SSH_PUBKEY=/path/to/key.pub \
     ./graft.sh deploy-ssh
```

---

## Environment overrides

| Var | Default | Effect |
|---|---|---|
| `CZ_IMG` | `$SCRIPT_DIR/cardputerzero-trixie-arm64-latest.img` | Decompressed donor .img. **For the camera userspace lift to work, point this at M5Stack's `20250513_os.img` (or newer)** — the older `cardputerzero-trixie-arm64-latest` donor lacks `libcamera-ipa`. |
| `CZ_XZ` | `$SCRIPT_DIR/cardputerzero-trixie-arm64-latest.img.xz` | Donor .img.xz. If neither `CZ_IMG` nor `CZ_XZ` exists, `stage_donor` downloads from `CZ_URL`. |
| `CZ_URL` | M5Stack OSS bucket URL for the OEM image | Source for the fetch step. The default points at the older `-latest` build; for the camera-capable donor, fetch `https://m5stack.oss-cn-shenzhen.aliyuncs.com/resource/linux/cp0/20250513_os.img.zip` manually and `unzip` it. |
| `KALI_XZ` | `$SCRIPT_DIR/kali-linux-2026.1-raspberry-pi-arm64.img.xz` | Base rootfs .xz |
| `OUT_IMG` | `${KALI_XZ%.xz}` | Output .img path |
| `APPLAUNCH_DEB` | (auto: prefers most recent `$SCRIPT_DIR/applaunch_*.deb`, falls back to donor's) | Specific .deb to install |
| `LAUNCHER_SRC` | auto-detect (`$SCRIPT_DIR/M5CardputerZero-Launcher`, then `$SCRIPT_DIR/../M5CardputerZero-Launcher`) | Launcher source tree for `launcher-build` |
| `ZEROCLAW_VER` | `v0.7.5` | zeroclaw release tag to fetch |
| `ZEROCLAW_SHA256` | (matches v0.7.5 aarch64-linux-gnu tarball) | Required-match SHA-256 of the fetched tarball |
| `ZEROCLAW_URL` | GitHub release for `$ZEROCLAW_VER` | Override the fetch URL (e.g. a mirror) |
| `ZEROCLAW_CACHE` | `$SCRIPT_DIR/cache/zeroclaw-aarch64-unknown-linux-gnu.tar.gz` | Where to cache the fetched tarball |
| `CZ_HOSTNAME` | `cardputerzero-kali` | Hostname baked into cloud-init |
| `GROW_GB` | `4` | Extra GiB added to rootfs |
| `LAUNCHER_REBUILD` | `0` | If `1`, `launcher-build` re-runs even if a .deb at this commit is cached |
| `DEPLOY_SSH_DEV` | (required for `deploy-ssh`) | Block device of the flashed card |
| `DEPLOY_SSH_PUBKEY` | `~/.ssh/id_ed25519.pub` | Pubkey file to deploy |

---

## What's in the produced image

### Hardware (from the CZ donor)

- M5-patched Raspberry Pi kernel 6.12.75 with all `m5stack,*` device-tree overlays
- M5 kernel modules: `st7789v_m5stack`, `tca8418_keypad_m5stack`, `es8389_m5stack`, `pwm_bl_m5stack`, `py32ioexp`
- `cardputerzero-overlay.dtbo`, `lsm6ds3tr-overlay.dtbo`
- BCM43439 WiFi firmware **with the right `boardflags3=0x04000000` NVRAM** (Kali's stock NVRAM hangs the chip on this carrier)
- CM0-specific Broadcom firmware blobs

### Desktop & UX

- **APPLaunch** running on `/dev/fb1` (LCD), service auto-restart with `systemd-udev-settle` wait
- **agetty autologin** as `kali` on tty1 (visible on HDMI when plugged)
- **LXDE + lightdm auto-enabled** so HDMI lights up at boot (~164 MB available with desktop running on a 415 MB usable CM0). Xorg ignores the integrated keypad so APPLaunch keeps control on the LCD; HDMI session is for USB peripherals only. Mask `lightdm.service` to recover the ~80 MB if you don't want it.
- `update-alternatives x-session-manager → startlxde` so `startx` lands in LXDE too
- Kali wallpaper baked into pcmanfm's system-default config

### System

- `zramswap` enabled at 75% of RAM (~311 MB compressed swap on the CM0)
- `NetworkManager` configured with `[ifupdown] managed=true`; `networking.service` masked
- `kali` user pre-created with password `kali` + NOPASSWD sudo
- SSH key **NOT** baked in (use `deploy-ssh` post-flash)
- `bluetooth.service` masked (~10 MB saved); blueman/xfce4-*/orca/etc autostarts disabled (memory diet)

### Workarounds baked in (sharp edges of the platform)

- `GLYCIN_SANDBOX_MECHANISM=not-sandboxed` written to three places — `/etc/environment` (consumed by `pam_env` for X sessions and SSH), `/etc/environment.d/` (consumed by `systemd --user`), and `/etc/profile.d/` (consumed by login shells). Glycin's bwrap sandbox crashes on every aarch64 Pi image with OOM, which kills Gtk apps that try to load icons (panel/greeter/pcmanfm). pcmanfm's wallpaper load fails specifically and the LXDE desktop is solid black without this
- `xset s off; xset -dpms; xset s noblank` in `/etc/xdg/lxsession/LXDE/autostart` — X's default 10-minute screen blank + DPMS timeout looks like a regression when HDMI goes dark mid-demo. Device is intended for always-on / kiosk-like use
- `fbcon=map:99` in cmdline.txt suppresses the kernel framebuffer console entirely so APPLaunch owns the LCD solo. (A userspace unbind service was tried first but raced the `st7789v_m5stack` driver — fired before the fb registered, missed it, and the kernel auto-rebound. Side effect: HDMI text console is no longer visible — use SSH or `sudo systemctl start lightdm` for HDMI shells.)
- Xorg `40-cardputerzero-no-grab.conf` makes X ignore the integrated TCA8418 keypad + IR receiver (APPLaunch grabs them exclusively via EVIOCGRAB in our rebuilt launcher)
- `APPLaunch.service.d/wait-for-udev.conf` — APPLaunch races udev for `/dev/input/by-path/platform-3f804000.i2c-event`; the drop-in busy-waits up to 10 s
- `dbus.service.d/workdir.conf` — systemd 259+ chdir-to-User=home semantics break dbus (messagebus has home `/nonexistent`); explicit `WorkingDirectory=/`
- Defensive `chmod 755 /` + verify check — past chroot accidents have left `/` mode 700, which silently breaks every non-root service via libselinux.so.1 EACCES cascade
- `apt-mark hold` on `raspi-firmware`, `firmware-misc-nonfree`, `firmware-linux`, `firmware-linux-nonfree`, `kali-linux-firmware`, `linux-image-rpi-v8`, `linux-image-rpi-2712` — Kali is rolling, so `apt upgrade` is a daily reality, but those packages own `/boot/firmware/kernel8.img`, the dtb, the Cypress NVRAM, and the kernel binary. Letting them upgrade replaces our M5-patched 6.12.75 kernel and breaks `st7789v_m5stack.ko` / `tca8418_keypad_m5stack.ko` ABI, killing the LCD + keypad. To intentionally pull a refresh: `sudo apt-mark unhold <pkg>; sudo apt install <pkg>` then re-hold.
- `Xorg 98-vc4-no-glamor.conf` (`AccelMethod=none` + `ShadowFB=true`) — glamor's V3D tile-binning path hits `-ENOMEM` under load on the 512 MB Pi Zero 2 W (`AddScreen/ScreenInit failed for driver 0`). Software shadow-fb rendering is slow but actually puts pixels on the screen. `cma=384M` was tried and *bricks* the kernel — it leaves <60 MB for everything else
- Fetch + SHA-verify zeroclaw (Apache 2.0, [`zeroclaw-labs/zeroclaw`](https://github.com/zeroclaw-labs/zeroclaw)) at install time and extract to `/home/pi/zeroclaw` + `/home/pi/web/` — APPLaunch's Claw app shells out to a hardcoded `/home/pi/zeroclaw agent`; the OEM image's `/home/pi` is empty, so Claw immediately exits with "Press any key" without this helper present. Pinned to `v0.7.5` via `ZEROCLAW_VER` / `ZEROCLAW_SHA256` env vars. Other hardcoded paths (`roller485`, `M5CardputerZero-Calculator-linux-aarch64`, `start_mft2023_unified_racer.sh`, `zhou.wav`) need similar treatment but we don't have authoritative sources for them yet — those apps fail similarly until someone supplies the binaries
- **No kernel driver for the bq27220 fuel gauge.** Three things conspire: (1) M5Stack ships `CONFIG_BATTERY_BQ27XXX=n` in the OEM kernel; (2) mainline Linux has no in-tree driver for the bq27220 specifically (only related chips); (3) the chip's data flash is shipped with TI eval-kit defaults (`DesignCapacity = 3000 mAh` vs the actual 1200 mAh FLY 103040 cell), so its on-chip Impedance Track SOC is unreliable regardless. Earlier builds shipped an out-of-tree `bq27xxx_battery.ko` that bound the chip as `ti,bq27500` — wrong register map, returned junk readings, and was a binary we couldn't rebuild from source. We now drop both the kernel module and the `bq27220` overlay entirely. APPLaunch talks to the chip directly via `/dev/i2c-1` with the correct bq27220 register layout (see `projects/APPLaunch/main/hal/linux/hal_settings_linux.cpp`) and computes SOC from a Li-ion OCV curve, since the chip's own SOC register can't be trusted without a proper bqStudio data-flash flash. `/etc/modules-load.d/i2c-dev.conf` ensures `/dev/i2c-1` exists at boot

---

## Known upstream defects (no fix here yet)

Issues with M5Stack's stock OEM image we inherit and can't currently work around:

- ~~Camera applet shows black / no frames.~~ **FIXED in this image** (as of 2026-05-27): M5Stack's May 2025 OEM image added a `camera-gpio16-high-overlay` that drives GPIO16 high at DT-init time to power the IMX219 sensor's regulator, and our `stage_rootfs` now lifts M5's `libcamera-ipa` + Pi-patched `libcamera 0.7.0` + TFLite/absl/farmhash/cpuinfo deps from the donor (Kali rolling doesn't package the IPA). **Requires the 2025-05-13 (or newer) donor image** — `CZ_IMG=/path/to/20250513_os.img`. With the older `cardputerzero-trixie-arm64-latest` donor, verify fails because the donor lacks `libcamera-ipa` entirely
- **`pigpio` not packaged in Kali rolling.** The launcher's GPIO app shells out to `pigs prs/pfs/p ...` (pigpio's shell client) which requires the `pigpio` package + a running `pigpiod`. Kali drops it on security grounds (pigpio mmap's `/dev/mem`). The GPIO app's PWM tab silently no-ops. Workaround paths: (a) build pigpio from source in `stage_packages`, (b) port the launcher's GPIO app to libgpiod (we install `gpiod` so `gpioset/gpioget/gpioinfo` are available for digital I/O). Neither attempted yet.
- **Several launcher apps shell out to `/home/pi/...` binaries that don't exist in either our image or M5Stack's OEM** — we don't have authoritative public sources for them so they aren't vendored:
  - `/home/pi/roller485` — MIDI app's roller-motor controller
  - `/home/pi/start_mft2023_unified_racer.sh` — LOVYAN/racer game launcher script
  - `/home/pi/zhou.wav` — startup chime played via `tinyplay -D1 -d0`
  - `/home/pi/M5CardputerZero-Calculator-linux-aarch64` — Calculator. The `projects/Calculator/` submodule does exist upstream; vendoring its build the same way we do AppStore is a future TODO.

  These cause the corresponding apps to spawn-fail silently (return to the rotor with no error). All non-blocking — every other app works.

---

## Sharp edges of building

- **You need `qemu-user-static-binfmt` registered before stage_packages runs.** systemd-binfmt does this automatically once the package is installed.
- **The chroot apt install pulls ~700 MB of packages and runs for ~5-10 min on this laptop.** Fast SSDs help; the device's CM0 takes ~50 min for the same install at first boot, which is why we bake it in.
- **`fresh all` deletes the .img and starts over.** Re-run when you change `stage_unxz` / `stage_resize` related things. For everything else, run only the stages you changed.
- **The launcher build downloads ~500 MB of SDK static libs on first invocation** (cached under `M5CardputerZero-Launcher/SDK/github_source/`). Subsequent builds reuse them.

---

## Source patches we maintain

These live in `M5CardputerZero-Launcher/` as edits on top of upstream HEAD. They
fail loudly when upstream rebases over them — re-apply as needed.

| File | Why |
|---|---|
| `projects/APPLaunch/main/hal/keyboard_input.c` | `ioctl(fd, EVIOCGRAB, 1)` in `open_restricted` so the kernel VT layer can't also fan out keypad input to tty1 (was double-typing into HDMI shell while in APPLaunch) |
| `projects/APPLaunch/main/hal/battey.c` | `_battery_timer_cb` signature `int *` → `void *` for `thpool_add_work`; GCC 15 makes incompatible-pointer-types a hard error |
| `projects/APPLaunch/main/SConstruct` | Replace non-existent `pkg_config_cflags("libcamera")` with a real `subprocess.check_output(['pkg-config', '--cflags', 'libcamera'])` |

---

## Troubleshooting

### Just-flashed card boots to broken HDMI text login loop

Pull the card and check `/dev/sdX2/etc/passwd` for the kali user — if it's
missing, `stage_packages` didn't run (or skipped via stale sentinel). Re-run
`sudo ./graft.sh packages`.

### `chmod 755 /` regression

`stage_verify` catches this now. If it ever slips through and you see "everything
broken" on first boot, mount the rootfs from the laptop and `sudo chmod 755 /mnt/.../`.

### Cursor drift in launcher CLI

Was upstream bug in older launcher versions. Run `launcher-build` against a
fresh `M5CardputerZero-Launcher` HEAD — the fix is upstream now.

### Launcher build fails with `jpeglib.h: No such file`

Your chroot's apt-install of `libjpeg-dev` failed. Re-run `launcher-build` —
it'll re-attempt.

### Launcher build fails with `libcamera/camera.h: No such file`

Confirm your patched `projects/APPLaunch/main/SConstruct` is still in place with
the subprocess pkg-config call. See "Source patches" above.

### `ssh kali@<ip>` asks for password

You haven't run `deploy-ssh` yet, OR your pubkey isn't where the script looks for
it. Either run `sudo DEPLOY_SSH_DEV=/dev/sdX DEPLOY_SSH_PUBKEY=/path/to/key.pub
./graft.sh deploy-ssh`, or `ssh-copy-id kali@<ip>` interactively after the first
password login.

### "Permission denied" on `runuser -u messagebus /bin/bash` after boot

Almost certainly `/` got chmod'd to 700 somewhere. `chmod 755 /` and reboot. The
`stage_verify` check should prevent this in the first place; if you're seeing
it post-graft, the verify isn't matching reality — file a bug against this script.

---

## Lineage

This script started as a 100-line graft to get one test image booting and grew
as we hit each new bug on real hardware: BCM43439 NVRAM, glycin sandbox on
aarch64, systemd 259 user-home chdir, fbcon vs APPLaunch fb1 racing, the
TCA8418 keypad bleeding into X, etc. Each lesson is encoded as either a config
write, a chroot operation, or a `vfail` check.
