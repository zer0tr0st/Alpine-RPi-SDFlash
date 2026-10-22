# Alpine-RPi-SDFlash

Flash [Alpine Linux](https://alpinelinux.org/) to a MicroSD card for a Raspberry Pi and have it **set itself up headlessly on first boot** — no monitor, keyboard or manual `setup-alpine` required.

The script writes the image, adds a persistent ext4 partition, and bakes your settings (user, password, SSH, hostname, Wi-Fi, timezone, …) into the card. On first boot the Pi connects to the network, installs Alpine in persistent **sys mode** onto the ext4 partition, reboots, and is reachable over SSH.

> **Warning:** the script **erases the disk you select**. It only offers removable/USB/`mmcblk` disks that are not mounted as system disks and asks you to type the device path to confirm — but always double-check the device.

## Contents

- [Features](#features)
- [Tested hardware](#tested-hardware)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Usage](#usage)
- [What you will be asked](#what-you-will-be-asked)
- [How it works](#how-it-works)
- [SD card layout](#sd-card-layout)
- [Security notes](#security-notes)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)

## Features

- Accepts Alpine Raspberry Pi images as `.img`, `.img.gz`, `.img.xz` or `.tar.gz`.
- Detects the architecture (`aarch64`, `armv7`, `armhf`) and the Alpine release from the file name, and pins the package repositories to that release.
- Creates a FAT32 boot partition and an ext4 root partition (4 MiB aligned).
- **Sys-mode install on first boot** (persistent, like a normal Linux install on the SD card).
- Headless provisioning:
  - user account in the `wheel` group with `sudo` (SHA-512 password hash)
  - root password: same as user, separate, or locked; optional direct root SSH
  - OpenSSH, optional SSH public key installation
  - hostname, `/etc/hosts`, timezone (with `tzdata`), UTF-8 locale
  - mDNS: reach the Pi as `<hostname>.local` (avahi)
  - optional IPv6 disable
  - optional Wi-Fi (multiple networks, country code) with the Broadcom/Cypress firmware pre-staged so Wi-Fi works on the very first boot
  - optional files/folders copied into `/home/<user>/`
- Wired Ethernet support, including the USB Ethernet adapters on the Pi 1/2/3 that appear late during boot.
- Disk safety checks: system disks, disks holding the image file, zero-size devices, RAM/zram/loop devices and (by default) non-removable disks are never offered.
- First-boot installer runs in the background, prints progress to the console and logs to `firstboot.log`; on failure the card stays bootable and it retries (up to 3 attempts).

## Tested hardware

| Board | Image | Status |
|---|---|---|
| Raspberry Pi Zero W | armhf | Tested, working |
| Raspberry Pi 1 | armhf | Tested, working (Ethernet) |
| Raspberry Pi 4 | aarch64 | Testing in progress |
| Other models (2, 3, Zero 2 W, 5, Compute Modules) | — | Not tested; may work |

Reports from other boards are welcome — please open an issue.

## Requirements

**Host:** a Linux machine with `sudo`/root and an SD card reader. Required tools:

`dd lsblk findmnt mountpoint mount umount partprobe udevadm openssl stat awk sed grep tr cut find sort realpath getent mktemp parted mkfs.vfat mkfs.ext4 tar gzip`

Additionally:

- `xz` for `.img.xz` images
- `curl` and `python3` if you configure Wi-Fi (used to fetch the Wi-Fi firmware)
- `zstd` and `wpa_passphrase` (from `wpa_supplicant`) are optional; used when available

Debian/Ubuntu:

```sh
sudo apt install parted dosfstools e2fsprogs util-linux openssl curl python3 xz-utils zstd wpasupplicant
```

**Network:** the Pi needs **internet access on first boot** (Ethernet, or the Wi-Fi you configure), because packages are downloaded during the install.

**Image:** download a Raspberry Pi image or tarball from the [Alpine downloads page](https://alpinelinux.org/downloads/) (Raspberry Pi section) that matches your board (`aarch64` for 64-bit boards, `armhf` for Pi 1/Zero, `armv7` for Pi 2/3 32-bit). Files in `~/Downloads` whose names contain `alpine` are detected automatically.

## Quick start

```sh
git clone https://github.com/zer0tr0st/Alpine-RPi-SDFlash.git
cd Alpine-RPi-SDFlash
chmod +x alpine-rpi-flash.sh
sudo ./alpine-rpi-flash.sh
```

Follow the prompts, put the card in the Pi, power it on, and wait roughly **3–6 minutes** (longer on slow boards/cards). Then:

```sh
ssh <user>@<hostname>.local
```

## Usage

```
sudo ./alpine-rpi-flash.sh [--show-all] [--debug] [-h|--help]
```

| Option | Description |
|---|---|
| `--show-all` | Also list non-removable, non-system disks. Use with great care. |
| `--debug` | Explain why each disk was skipped in the drive list. |
| `-h`, `--help` | Show help. |

If your card is not listed, run with `--debug` to see why.

## What you will be asked

1. **Image** — pick one found in `~/Downloads` or enter a path.
2. **Target drive** — choose from the safe list.
3. **User account** — username (default `alpine`), password, root password handling, root SSH.
4. **Hostname** (default `alpine`) and **timezone** (default: your host's).
5. **Disable IPv6?** (default yes)
6. **Headless boot tweaks** (`gpu_mem=32`, audio off; default no)
7. **Wi-Fi** (optional) — country code, one or more SSIDs/passwords.
8. **SSH public key** (optional) — defaults to `~/.ssh/id_ed25519.pub`, `id_ecdsa.pub` or `id_rsa.pub` if present.
9. **Files for the home folder** (optional).
10. **Confirmation** — type the device path (for example `/dev/sdb`) to proceed.

## How it works

1. **Flash** — writes the image with `dd` (or partitions and extracts a `.tar.gz`), then adds an ext4 partition after the boot partition.
2. **Overlay** — builds an Alpine apkovl (`<hostname>.apkovl.tar.gz`) containing your configuration and a first-boot installer, and places it on the FAT partition. Alpine applies it when the Pi first boots from RAM.
3. **First boot (RAM)** — the installer waits for the network (Ethernet and/or Wi-Fi), syncs the clock, then runs `setup-disk -m sys` against the ext4 partition. A scratch FAT image in RAM stands in for `/boot`, so the real boot partition is not touched until the install has succeeded.
4. **Switch-over** — the overlay is merged into the new root (keeping the system accounts and package list created by `setup-disk`), the packages are installed, and only then are the new kernel, initramfs, firmware and `config.txt` copied to the real boot partition and the kernel command line is pointed at the ext4 root. Originals are kept as `cmdline*.txt.alpine-orig`.
5. **Reboot** — the Pi boots from ext4. On that first successful boot a one-shot script removes the overlay from the FAT partition.

## SD card layout

| Partition | Type | Contents |
|---|---|---|
| 1 | FAT32 | Firmware, kernel, initramfs, `config.txt`, `cmdline.txt`, `usercfg.txt`, (temporarily) the overlay and `firstboot.log` |
| 2 | ext4 | Alpine root filesystem (`/`), mounted from `/dev/mmcblk0p2` (or the matching device) |

After installation the FAT partition is mounted at `/boot`.

## Security notes

- The overlay on the FAT partition contains the **password hashes** (SHA-512 crypt) and Wi-Fi settings until the first successful boot from ext4, when it is deleted. Anyone with the card before then can read it. If you provide a Wi-Fi password and `wpa_passphrase` is installed on the host, the derived PSK is stored instead of the plaintext passphrase.
- SSH `PasswordAuthentication` stays **enabled** even when a key is installed. Disable it in `/etc/ssh/sshd_config` once your key works.
- Root SSH login is off unless you enable it. If there is no user account, root is the only account and an SSH key is required when its password is locked.
- Change the default passwords you choose for anything exposed beyond a trusted network.

## Troubleshooting

**Watch progress / read the log.** The installer prints major steps on the console and logs everything to `firstboot.log` on the boot partition (and, after a successful install, to `/var/log/firstboot.log`). While it runs you can SSH in to the RAM system and run:

```sh
cat /media/mmcblk0p1/firstboot.log
```

**No network at first boot.** Check the cable or the Wi-Fi SSID/password/country code. The installer waits about 90 seconds for internet access before failing.

**`TLS: server certificate not trusted` or clock skew warnings.** The Pi has no battery-backed clock. The script sets a sane time at first boot; on an installed system run `sudo ntpd -q -n -p pool.ntp.org` and retry.

**Install failed.** The card remains bootable in RAM mode and the installer retries on the next boot, up to 3 attempts. After that it creates `.firstboot-failed` on the boot partition and stops. Reflash after fixing the cause (the log shows the failing step and, for `setup-disk`, its output).

**Not enough space on the boot partition.** The installer frees space by removing the offline `apks/` folder, the old modloop and the old kernel files, then fails if there is still not enough room. The log shows free and needed space.

**Pi does not boot after the install.** Put the card in your computer and check the FAT partition for `config.txt` and the kernel/initramfs files, and compare `cmdline.txt` with `cmdline.txt.alpine-orig`.

**Services failed to start (`dbus`, `chrony`).** Missing system accounts. The installer merges and verifies these (`messagebus`, `chrony`, `avahi`); the log lists them. Send the log if it still happens.

## Limitations

- Linux host only.
- Sys mode only (persistent install on the SD card); diskless mode is not supported.
- Requires internet on first boot.
- Only the first image partition layout of the official Alpine Raspberry Pi images is supported.
- Not every Raspberry Pi model has been tested (see [Tested hardware](#tested-hardware)).
