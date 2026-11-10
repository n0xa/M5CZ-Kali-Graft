# graft.sh — Kali on the M5 Cardputer Zero

`graft.sh` builds a Kali Linux arm64 SD-card image for the M5Stack **Cardputer
Zero** (hardware rev v5, the production board): M5's **APPLaunch** on the
onboard ST7789 LCD with the built-in keyboard, an LXDE desktop on **HDMI** for
USB keyboard/mouse, onboard WiFi, and patched drivers for Realtek USB WiFi
adapters.

Every input is public, pinned, and sha256-verified. No OEM "donor" image is
needed: M5's own image build ([CardputerZero/pi-gen]) is now entirely open, so
this script builds the same pieces the same way, on top of Kali's official
Raspberry Pi image.

| Layer | Source |
|---|---|
| Base rootfs | Kali `2026.3` Raspberry Pi arm64 image (kali.download) |
| Kernel | stock Raspberry Pi `6.18.39+rpt-rpi-v8` .debs from archive.raspberrypi.com — the exact set M5 pins and tests |
| CZ drivers + overlays | [m5stack/m5stack-linux-dtoverlays] @ `7551854`, compiled inside the image against that kernel (panel, keypad, ES8389 audio + machine driver, bq27220, BMI270/BMM150, m5ioe1, gpio-forwarder, powerfail) |
| CM0 WiFi firmware | Raspberry Pi `firmware-brcm80211` (the BCM43439 NVRAM with `boardflags3=0x04000000`) |
| Launcher + apps | [CardputerZero/launcher] `0.6.105` + 13 first-party app releases (Camera, Music, Piano, Recorder, Files, Compass, IR-Chat, IR-Remote, Cap-CC1101 ×2, Cap-LoRa-1262 ×2, Keyboard-Guide) |
| Camera userspace | Raspberry Pi's libcamera `0.7.2+rpt20261009` (+ libpisp, tflite) and Debian trixie's boost 1.83 / absl, in a private tree used only by the Camera app |
| Boot splash, LCD→HDMI mirror | `splash.bmp`, `fb-mirror.py` from CardputerZero/pi-gen |

[CardputerZero/pi-gen]: https://github.com/CardputerZero/pi-gen
[m5stack/m5stack-linux-dtoverlays]: https://github.com/m5stack/m5stack-linux-dtoverlays
[CardputerZero/launcher]: https://github.com/CardputerZero/launcher

---

## TL;DR

```bash
# One-time host setup (Arch/Manjaro)
sudo pacman -S qemu-user-static qemu-user-static-binfmt git

# Build (downloads everything into ./cache and the Kali .xz on first run)
sudo ./graft.sh

# Flash — refuses non-removable disks, mounted disks, or too-small cards
sudo FLASH_DEV=/dev/sdX ./graft.sh flash

# Optional: put your ssh pubkey on the card (image itself stays generic)
sudo DEPLOY_SSH_DEV=/dev/sdX ./graft.sh deploy-ssh
```

On the device:
- **LCD**: APPLaunch, driven by the built-in keyboard.
- **HDMI**: LXDE, autologin as `kali`, for USB keyboard/mouse. The built-in
  keyboard is deliberately ignored by X.
- **Ctrl-Alt-F2…F6** (USB keyboard): text login on HDMI with your credentials.
  **Alt-F7** returns to the desktop. tty1 is intentionally dead (see below).
- **SSH**: `kali@<ip>`, password `kali`, or key-only after `deploy-ssh`.

---

## Stages

Run any subset, e.g. `sudo ./graft.sh configs verify`. The default is `all`.

| Stage | What it does |
|---|---|
| `check` | Verify host tooling (qemu binfmt, git, parted, …) |
| `fetch` | Download + sha256-verify every pinned input into `cache/` (Kali .xz goes next to the script) |
| `unxz` / `resize` | Decompress Kali, grow the rootfs by `GROW_GB` |
| `mount` | Loop-mount the image |
| `kernel` | chroot: purge nexmon's `brcmfmac` DKMS, install + hold the RPi 6.18.39 kernel/headers, put kernel8.img / CM0 dtb / overlays / initramfs8 on the FAT; install RPi's CM0 WiFi firmware |
| `drivers` | chroot: build m5stack-linux-dtoverlays (`make CONFIG_CARDPUTERO_V0_5=y install`), udev seat rules, panel autoload, gpio group |
| `boot` | `config.txt`, `cmdline.txt`, LCD splash |
| `configs` | glycin, X input-ignore + no-glamor, lightdm autologin, consoles, ALSA, gpsd, zram, Realtek blacklist |
| `packages` | chroot: LXDE, lightdm, pipewire-pulse, fbset, gpsd, Noto CJK fonts, …; patch + build `88XXau` for 6.18; kali user/groups (incl. `spi`); memory diet |
| `apps` | chroot: real `apt install` of APPLaunch + apps; linger for `kali`; fb-mirror; private RPi libcamera + `camera_app` wrapper |
| `tweaks` | NetworkManager, hostname + `/etc/hosts`, first-boot rootfs grow |
| `verify` | ~100 checks on the finished image |
| `flash` | `FLASH_DEV=/dev/sdX` — guarded `dd` to a removable card |
| `deploy-ssh` | `DEPLOY_SSH_DEV=/dev/sdX` — pubkey into `/home/kali/.ssh` |
| `drift` | Compare our launcher/kernel/driver/Kali pins against upstream's latest |
| `shell` | Mount + chroot binds + interactive shell |
| `fresh` | Delete the output .img (next run starts from the .xz) |

Stages are idempotent: `kernel` and `drivers` skip their builds when the
pinned version is already in the image. `packages` skips only when its stamp
(`/var/lib/cz-graft/packages.rev`) matches `PACKAGES_REV`, so **bump
`PACKAGES_REV` in `graft.sh` whenever you change `stage_packages`**, or a
re-run on an existing image silently keeps the old package set.

## Bumping pins

All pins live at the top of `graft.sh`. Run `sudo ./graft.sh drift` to see what
M5's latest stable image uses. The release notes on CardputerZero/pi-gen list
the launcher version, kernel version and dtoverlays commit for every image.

- **Kernel**: copy the v8 lines of pi-gen's
  `stage0/02-firmware/files/kernel-packages.sha256` into `KERNEL_DEBS`, set `KVER`,
  then run `sudo ./graft.sh fresh all`. The drivers must be rebuilt against the
  new headers.
- **Drivers**: `DTOVERLAYS_COMMIT`.
- **Apps**: URL + sha256 in `CZ_DEBS`.
- **Kali**: `KALI_VER` + `KALI_SHA256` (from that release's `SHA256SUMS`).

## Environment overrides

| Var | Default | Effect |
|---|---|---|
| `KALI_VER`, `KALI_URL`, `KALI_SHA256`, `KALI_XZ` | 2026.3 | Kali base image |
| `OUT_IMG` | `KALI_XZ` minus `.xz` | Output image |
| `CACHE` | `./cache` | Download cache |
| `DTOVERLAYS_COMMIT` | `7551854…` | Driver source revision |
| `CZ_HOSTNAME` | `cardputerzero-kali` | Hostname |
| `GROW_GB` | `4` | Extra GiB in the rootfs (first boot grows it to fill the card anyway) |
| `FLASH_DEV` | — | Target for `flash` |
| `DEPLOY_SSH_DEV`, `DEPLOY_SSH_PUBKEY` | —, `~/.ssh/id_ed25519.pub` | `deploy-ssh` |

---

## Design notes (the sharp edges)

- **Keyboard sharing and the consoles.** Upstream APPLaunch deliberately
  doesn't `EVIOCGRAB` the keypad, so the apps it launches can read it too. The
  kernel VT keyboard therefore also sees every keypress and types into the
  foreground VT. tty1 therefore has no getty at all (`getty@tty1` and
  `autovt@tty1` are masked). X runs on its own VT, where the kernel keyboard is
  off. tty2–6 are ordinary credentialed logins via logind's autovt.
- **No kernel console on the LCD.** `fbcon=map:99` binds the console to no
  framebuffer at boot. A udev rule then maps tty2–6 onto the HDMI framebuffer
  (`vc4drmfb`) only, via `con2fbmap`, so the LCD stays APPLaunch-only whatever
  the fb probe order. *Needs confirming on hardware.* If tty2 is blank on HDMI,
  this is where to look.
- **APPLaunch is a user unit.** Its postinst enables it for UID 1000. A linger
  file (`/var/lib/systemd/linger/kali`) starts kali's user manager, and with it
  APPLaunch, at boot without anyone logging in.
- **Kernel install in a chroot.** Kali's `z50-raspi-firmware` hook looks for
  DTBs under `/usr/lib/linux-image-<ver>/`, while RPi's 6.18 packages ship them
  under `/usr/lib/modules/<ver>/dtb/`, so the script bridges the path with a
  symlink. The DKMS kernel hooks are paused during the install so Kali's
  6.12-only Realtek DKMS packages can't abort it.
  `brcmfmac-nexmon-dkms` is purged: it has no BCM43439 support, and its
  `updates/dkms/brcmfmac.ko` would shadow the driver the onboard WiFi needs.
- **CM0 WiFi firmware.** The `brcm/` and `cypress/` trees from Raspberry Pi's
  `firmware-brcm80211` .deb are copied over Kali's files; the package itself
  isn't installed. On Kali those paths belong to `firmware-nexmon`.
- **Holds.** The RPi kernel packages and `raspi-firmware` are `apt-mark hold`,
  and so is whichever firmware package owns the brcm/cypress files
  (`firmware-nexmon` on Kali; `verify` fails if one is installed but not
  held). A routine `apt upgrade`
  would otherwise replace the kernel the CZ modules are built for, or put back
  Kali's wrong BCM43439 NVRAM. To refresh one deliberately: `apt-mark unhold`,
  install it, then hold it again.
- **Realtek USB WiFi.** `realtek-rtl88xxau-dkms` is limited to 6.12. Its
  sources are patched for 6.16–6.18 API changes (timer API, `radio_idx`,
  `ccflags-y`) and built for 6.18. The in-tree `rtw88_88xxa` drivers are
  blacklisted so `88XXau` wins for the AWUS036ACS.
- **Low-RAM survival.** zram at 75%, a memory diet on autostarts. glycin's
  sandbox is bypassed and its thumbnailers diverted, because they livelock or
  pile up on aarch64. Xorg uses no glamor (V3D `-ENOMEM` on
  512 MB).
- **Bluetooth stays enabled.** The CM0's CYW4343A2 (hci0) works, and
  APPLaunch polls bluez every 2 s. Masking `bluetooth.service` while the
  `dbus-org.bluez.service` alias remains made every poll log "failed to load
  properly … File exists", flooding the journal. `verify` fails if it's masked.
- **systemd 259 + dbus**: `WorkingDirectory=/` drop-in (messagebus home is
  `/nonexistent`). `stage_verify` also guards `/` against mode 700.
- **ttyS0 belongs to the LoRa+GNSS cap.** There's no serial console on it (no
  `console=serial0` in cmdline.txt, `serial-getty@ttyS0` masked): M5's GPS app
  opens the port itself and refuses one assigned to a console. gpsd is
  configured for it (115200) but **socket-activated only**, without `-n`, so it
  holds the port only while a client (kismet, cgps, …) is watching. The GPS
  app and gpsd clients can each use the cap, just not at the same time.
- **Camera** uses Raspberry Pi's libcamera fork, because M5's CameraApp links
  Pi-only symbols (`properties::PixelArrayReadableArea`, …) that Kali's
  upstream libcamera 0.7.2 lacks. It's the same soname, so it lives in a private
  tree, `/opt/rpi-libcamera`. `/usr/bin/camera_app` is dpkg-diverted to
  `/usr/lib/cz-graft/camera_app.real` and replaced by a wrapper that points
  the loader and libcamera's IPA, proxy, tuning and pipeline paths there.
  Kali's own libcamera is untouched.
- **spidev** gets `GROUP="spi"` from Raspberry Pi's udev rules, but Kali has no
  `spi` group, so the node silently stayed `root:root 0600` and the LoRa app
  couldn't open it. The group is created and kali is added to it. `verify`
  now checks that every group named by a udev `GROUP=` exists.
- **cloud-init never runs** on Kali 2026.3's Pi image: ds-identify finds no
  datasource. The user, hostname, ssh and rootfs grow are therefore baked in
  directly, and `/boot/firmware/user-data` is no longer written. `tweaks` sets
  `/etc/hostname` and the `127.0.1.1` line in `/etc/hosts` to `CZ_HOSTNAME`
  (the base image otherwise boots as `kali-raspberry-pi`).
- **Fonts.** M5's apps load Noto CJK by absolute path
  (`/usr/share/fonts/opentype/noto/NotoSansCJK-*.ttc`), so `fonts-noto-cjk`
  is installed.
- **ALSA default** routes to `hw:1,0` through softvol. *Re-check on hardware*:
  M5's driver set now includes a `cardputerzero-audio` machine driver and the
  image runs pipewire, so the card index and the need for softvol may have
  changed.

## Hardware status

Tested on a v5 board with the image as built by this script:

| Works | Notes |
|---|---|
| LCD splash, APPLaunch, lock screen, keypad | |
| Onboard WiFi, Bluetooth, battery gauge, 5V GPIO, Settings | |
| Camera (imx219) | live preview via the private libcamera |
| Compass and the other APPLaunch apps | |
| LoRa-1262 cap | SX1262 initialises, radio + frequency shown |
| LoRa-1262 GPS | UART opens and NMEA arrives ("searching" indoors) |

| Not working / untested | Notes |
|---|---|
| IR transmit | No LED output; see the known gaps below |
| IR receive | Captures fine |
| CC1101 NFC / Sub-GHz caps | Not tested (no hardware) |
| HDMI tty2 mapping, ALSA routing | See the design notes above; not re-checked |

## Not included / known gaps

- **FactoryTest** is skipped. It's M5's factory QA tool, and it hard-depends
  (via apt) on Raspberry Pi's libcamera packages.
- **IR Remote replay of long captures.** The kernel rejects a single LIRC
  transmit longer than 500 ms in total (`IR_MAX_DURATION`), and IR-Remote 0.1.4
  replays the whole capture, including every repeat frame recorded while the
  button was held. Those sends fail with `EINVAL`. Tap the remote briefly when
  recording, and delete long captures. This is an upstream app bug
  (`src/models/ir_service_model.cpp` sends everything after the leading gap).
- **IR transmit shows no LED output** on the test unit, even with short
  captures the kernel accepts (`sent pulses=271` in the journal). GPIO12 is
  owned by `gpio-ir-tx` and is driven high during a send (sampled with
  `pinctrl lev 12`), and the config matches M5's (`gpio-ir-tx,gpio_pin=12`).
  Forcing GPIO12 high by hand, with or without the Grove 5V rail, also lit
  nothing in a phone camera. That points at the board's LED path rather than
  the image, but it hasn't yet been compared against M5's stock image.
- **`rtl88x2bu` (RTL8812BU/8822BU)**: the `packages` stage calls the build
  for it, but `realtek-rtl88x2bu-dkms` isn't installed, so it only logs
  `WARNING: source (none) … not found`. Only `88XXau` is built.
- **LaunchWizard** (M5's first-boot OOBE) is installed but not enabled.
  APPLaunch starts directly.
- **GPU-firmware boot splash**: M5 ships a custom `start.elf`/`fixup.dat` that
  draws a splash before Linux starts. It's closed-source and cosmetic, so it
  isn't used. The Linux-side `fb_load` splash is installed.
- **Internal WiFi monitor mode**: nexmon has no BCM43439 port. Use a USB
  adapter.

## Troubleshooting

- **LCD backlight on, nothing drawn**: `lsmod | grep panel_mipi_dbi_m` and
  `ls /dev/fb_lcd`; `journalctl --user -u APPLaunch` (as kali).
- **APPLaunch not running at boot**: is `/var/lib/systemd/linger/kali` present?
  Check `loginctl show-user kali | grep Linger`.
- **No wlan0**: `dmesg | grep brcmf`. "HT Avail timeout" means the wrong NVRAM.
  Check `grep boardflags3 /lib/firmware/cypress/cyfmac43439-sdio.txt`.
- **`ssh kali@<ip>` asks for a password**: run `deploy-ssh`, or `ssh-copy-id` once.
  After reflashing, the host key changes: `ssh-keygen -R <ip>`.
- **Camera app won't start**: `ldd /usr/lib/cz-graft/camera_app.real` under
  the wrapper's `LD_LIBRARY_PATH`. An undefined `libcamera::properties::…`
  symbol means it's loading Kali's libcamera, not `/opt/rpi-libcamera`.
- **GPS "Could not open GPS power or UART"**: check for `console=serial0` in
  `/boot/firmware/cmdline.txt`, and whether gpsd holds the port
  (`fuser /dev/ttyS0`). Stop gpsd's clients first.
- **LoRa "SX1262 Not initialized"**: `ls -l /dev/spidev0.*` should show group
  `spi`, and `id kali` should include it.
- **IR Remote "LIRC write failed: Invalid argument"**: the capture is longer
  than 500 ms. Re-record with a short tap.
- **Everything is "permission denied" after boot**: `/` lost mode 755. Run
  `chmod 755 /`.

## Lineage

This started as a 100-line graft that copied M5's closed, prototype-era
kernel, modules and firmware out of their OEM image onto Kali. Once M5 opened
the whole stack, the donor image went away. Each lesson from real hardware
(BCM43439 NVRAM, glycin on aarch64, systemd 259 + dbus, fbcon vs APPLaunch,
keypad sharing, etc.) is still encoded as a config write, a chroot step, or a
`vfail` check.
