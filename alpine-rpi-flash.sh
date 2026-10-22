#!/usr/bin/env bash
# ==============================================================================
# Alpine Linux Raspberry Pi MicroSD Flasher & Headless Provisioner
#
# Compatible with: Raspberry Pi 1, 2, 3, 4, 5, Zero, Zero W, Zero 2 W,
#                  Compute Modules (all generations)
#
# Features:
#   1. Safely writes Alpine Linux (.img, .img.gz, .img.xz, or .tar.gz)
#      to a MicroSD card.
#   2. Provisions two partitions:
#      - Partition 1: FAT32 (bootloader, kernel, firmware, apkovl overlay)
#      - Partition 2: ext4 (persistent root filesystem)
#   3. Headless first-boot automation ('sys' mode only):
#      - The Pi boots Alpine from RAM using the generated overlay (apkovl),
#        brings up the network, runs setup-disk to install Alpine onto the
#        ext4 partition, then reboots into the installed system.
#        THE FIRST BOOT NEEDS INTERNET ACCESS (Ethernet or the Wi-Fi you
#        configure here) because packages are downloaded during the install.
#      - SSH (OpenSSH), mDNS (<hostname>.local via avahi).
#      - User account with SHA-512 crypt password hash, sudo (wheel).
#      - Optional SSH public key installation.
#      - Hostname, /etc/hosts, timezone (tzdata) and UTF-8 locale.
#      - Optional IPv6 disable.
#      - Wi-Fi pre-configuration (wpa_supplicant), with the Broadcom/Cypress
#        firmware staged into the overlay so Wi-Fi works on the first boot.
#      - Custom file(s)/folder(s) copied into /home/<user>/.
#   4. Drive safety checks so system and non-removable disks are not offered.
#   5. Broad hardware compatibility:
#      - RPi 1/2 (armhf/armv7): ethernet via USB (smsc95xx) is brought up
#        with an active polling strategy so slow driver enumeration does not
#        prevent the first-boot installer from reaching the internet.
#      - Ethernet is always attempted even if the cable is absent; boot is
#        never blocked by a missing network interface.
#      - RPi 1/2-specific config.txt patches applied automatically
#        (arm_64bit=0, vc4-kms-v3d disabled) when an armhf/armv7 image is used.
#
# Usage: sudo ./alpine-rpi-flash.sh [--show-all] [--debug] [-h|--help]
#   --show-all   also list non-removable, non-system disks (use with care)
#   --debug      explain why each disk was skipped in the drive list
#
# WARNING: this script ERASES the disk you select. Double-check the device.
# ==============================================================================

set -o pipefail

readonly LOCALE="en_US.UTF-8"
readonly DEFAULT_TIMEZONE="UTC"
readonly DEFAULT_WIFI_COUNTRY="US"
# Names that must not be reused for the interactive user account.
readonly RESERVED_USERS=" root bin daemon adm lp sync shutdown halt mail news uucp operator man postmaster cron ftp sshd ntp nobody chrony avahi messagebus polkitd "

SHOW_ALL=0
DEBUG=0
MOUNT_DIRS=()
TEMP_DIRS=()
BOOT_MNT=""
STAGING_DIR=""
FW_DIR=""
SELECTED_IMAGE=""

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
die()  { echo "Error: $*" >&2; exit 1; }
warn() { echo "[!] $*" >&2; }

# read wrapper: abort cleanly on EOF instead of looping forever on empty input
must_read() { read "$@" || die "Unexpected end of input."; }

usage() {
    cat <<EOF
Usage: sudo ${0##*/} [--show-all] [--debug] [-h|--help]

  --show-all   Also list non-removable, non-system disks (use with care)
  --debug      Explain why each disk was skipped in the drive list
  -h, --help   Show this help
EOF
}

ask_yn() {
    local prompt=$1 def=${2:-N} hint ans
    [[ $def == Y ]] && hint="[Y/n]" || hint="[y/N]"
    must_read -r -p "$prompt $hint: " ans
    ans=${ans:-$def}
    [[ $ans =~ ^[Yy]$ ]]
}

human_bytes() {
    numfmt --to=iec "$1" 2>/dev/null || echo "$1 bytes"
}

cleanup() {
    local rc=$? d
    for d in "${MOUNT_DIRS[@]}"; do
        if mountpoint -q "$d" 2>/dev/null; then
            umount "$d" 2>/dev/null || umount -l "$d" 2>/dev/null
        fi
        # Never recurse into something that is still mounted (it may be the card).
        if mountpoint -q "$d" 2>/dev/null; then
            warn "$d is still mounted; leaving it in place."
        else
            rmdir "$d" 2>/dev/null
        fi
    done
    for d in "${TEMP_DIRS[@]}"; do
        [[ -n $d && -d $d ]] && rm -rf "$d" 2>/dev/null
    done
    exit "$rc"
}
trap cleanup EXIT
trap 'echo; echo "Interrupted."; exit 130' INT TERM

disk_mountpoints() {
    local node
    while IFS= read -r node; do
        findmnt -rn -o TARGET -S "$node" 2>/dev/null
    done < <(lsblk -lnpo NAME "$1" 2>/dev/null)
}

is_system_disk() {
    local mp node
    while IFS= read -r mp; do
        case $mp in
            /|/boot|/boot/*|/efi|/efi/*|/home|/home/*|/usr|/usr/*|/var|/var/*|/etc|/etc/*)
                return 0 ;;
        esac
    done < <(disk_mountpoints "$1")
    while IFS= read -r node; do
        if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq "$node"; then
            return 0
        fi
    done < <(lsblk -lnpo NAME "$1" 2>/dev/null)
    return 1
}

disk_holds_path() {
    local src
    src=$(findmnt -nvo SOURCE -T "$2" 2>/dev/null)
    src=${src%%\[*}
    [[ -n $src ]] && lsblk -lnpo NAME "$1" 2>/dev/null | grep -Fxq "$src"
}

unmount_disk() {
    local node target
    while IFS= read -r node; do
        while IFS= read -r target; do
            [[ -n $target ]] && umount "$target" 2>/dev/null
        done < <(findmnt -rn -o TARGET -S "$node" 2>/dev/null)
    done < <(lsblk -lnpo NAME "$1" 2>/dev/null)
}

list_candidate_disks() {
    local dev type bytes removable tran size model
    while IFS= read -r dev; do
        if [[ $dev == /dev/zram* || $dev == /dev/ram* ]]; then
            (( DEBUG )) && warn "[debug] skip $dev: RAM/zram device"
            continue
        fi
        type=$(lsblk -dno TYPE "$dev" 2>/dev/null | tr -d ' ')
        if [[ $type != disk ]]; then
            (( DEBUG )) && warn "[debug] skip $dev: type is '$type', not 'disk'"
            continue
        fi
        bytes=$(lsblk -bdno SIZE "$dev" 2>/dev/null | tr -d ' ')
        if ! [[ ${bytes:-0} -gt 0 ]]; then
            (( DEBUG )) && warn "[debug] skip $dev: reports 0 bytes (no media, or enclosure not ready)"
            continue
        fi
        if is_system_disk "$dev"; then
            (( DEBUG )) && warn "[debug] skip $dev: has system mounts or swap: $(disk_mountpoints "$dev" | tr '\n' ' ')"
            continue
        fi
        if disk_holds_path "$dev" "$SELECTED_IMAGE"; then
            (( DEBUG )) && warn "[debug] skip $dev: the selected image file is stored on it"
            continue
        fi

        removable=$(lsblk -dno RM "$dev" 2>/dev/null | tr -d ' ')
        tran=$(lsblk -dno TRAN "$dev" 2>/dev/null | tr -d ' ')
        if (( SHOW_ALL == 0 )) && [[ $removable != 1 && $tran != usb && $dev != /dev/mmcblk* ]]; then
            (( DEBUG )) && warn "[debug] skip $dev: not removable/USB/mmcblk (RM=$removable TRAN=${tran:-none}); use --show-all"
            continue
        fi

        size=$(lsblk -dno SIZE "$dev" 2>/dev/null | tr -d ' ')
        model=$(lsblk -dno MODEL "$dev" 2>/dev/null | sed 's/^ *//; s/ *$//')
        printf '%s|%s|%s|%s\n' "$dev" "$size" "${tran:-?}" "${model:-unknown}"
    done < <(lsblk -dnpo NAME -e 7,11 2>/dev/null)
}

find_partitions() {
    local p fs
    BOOT_PART=""
    ROOT_PART=""
    while IFS= read -r p; do
        fs=$(lsblk -dno FSTYPE "$p" 2>/dev/null | tr -d ' ')
        [[ -z $BOOT_PART && ($fs == vfat || $fs == msdos || $fs == fat) ]] && BOOT_PART=$p
        [[ -z $ROOT_PART && $fs == ext4 ]] && ROOT_PART=$p
    done < <(lsblk -lnpo NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print $1}')

    # Fallback to partition indices if FSTYPE is not yet populated
    if [[ -z $BOOT_PART ]]; then
        BOOT_PART=$(lsblk -lnpo NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print $1}' | sed -n '1p')
    fi
    if [[ -z $ROOT_PART ]]; then
        ROOT_PART=$(lsblk -lnpo NAME,TYPE "$TARGET_DISK" | awk '$2=="part"{print $1}' | sed -n '2p')
    fi
}

mount_retry() {
    local part=$1 dir=$2 attempt
    for attempt in 1 2 3; do
        mount "$part" "$dir" 2>/dev/null && return 0
        warn "Mounting $part failed (attempt $attempt/3); retrying..."
        sleep 2
    done
    return 1
}

# Create an ext4 filesystem on a freshly created partition. Desktop automounters
# (udisks/gvfs) often mount a new partition the moment it appears, which makes
# mkfs refuse to run, so unmount everything on the disk and retry.
make_ext4() {  # make_ext4 <partition> <label>
    local part=$1 label=$2 attempt
    for attempt in 1 2 3 4 5; do
        udevadm settle 2>/dev/null || sleep 1
        unmount_disk "$TARGET_DISK"
        if mkfs.ext4 -q -F -L "$label" "$part" 2>/dev/null; then
            return 0
        fi
        warn "mkfs.ext4 on $part failed (attempt $attempt/5); retrying..."
        sleep 2
    done
    return 1
}

# Passphrase must be 8-63 characters (empty = open network)
valid_psk() { [[ -z $1 ]] || (( ${#1} >= 8 && ${#1} <= 63 )); }

# ------------------------------------------------------------------------------
# Argument parsing & preflight
# ------------------------------------------------------------------------------
for arg in "$@"; do
    case $arg in
        --show-all) SHOW_ALL=1 ;;
        --debug)    DEBUG=1 ;;
        -h|--help)  usage; exit 0 ;;
        *)          usage >&2; exit 2 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script requires administrative privileges."
    echo "Please run with sudo: sudo $0"
    exit 1
fi

for cmd in dd lsblk findmnt mountpoint mount umount partprobe udevadm openssl stat \
           awk sed grep tr cut find sort realpath getent mktemp parted \
           mkfs.vfat mkfs.ext4 tar gzip; do
    command -v "$cmd" &>/dev/null || die "Required command '$cmd' is not installed."
done

echo "=========================================================="
echo " Alpine Linux MicroSD Flasher & Headless Provisioner (RPi)"
echo "=========================================================="

TARGET_USER="${SUDO_USER:-$USER}"
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
[[ -n $USER_HOME ]] || USER_HOME=$HOME
DOWNLOADS_DIR="$USER_HOME/Downloads"

# ------------------------------------------------------------------------------
# 1. Select Alpine Linux image or tarball
# ------------------------------------------------------------------------------
echo
echo "--- [Step 1/5] Select Alpine Linux Image ---"

prompt_image_path() {
    local p
    while true; do
        must_read -r -e -p "Enter full path to Alpine .img, .img.gz, .img.xz, or .tar.gz: " p
        p=${p/#\~/$USER_HOME}
        if [[ -f $p && ( $p =~ \.img(\.gz|\.xz)?$ || $p =~ \.tar\.gz$ ) ]]; then
            SELECTED_IMAGE=$(realpath "$p")
            return
        fi
        warn "Not a readable Alpine image or archive: $p"
    done
}

FOUND_IMAGES=()
if [[ -d $DOWNLOADS_DIR ]]; then
    while IFS= read -r -d '' f; do
        FOUND_IMAGES+=("$f")
    done < <(find "$DOWNLOADS_DIR" -maxdepth 2 -type f -iname '*alpine*' \
                  \( -name '*.img' -o -name '*.img.gz' -o -name '*.img.xz' -o -name '*.tar.gz' \) \
                  -print0 2>/dev/null | sort -z)
fi

n=${#FOUND_IMAGES[@]}
if (( n > 0 )); then
    echo "Found image(s) in $DOWNLOADS_DIR:"
    for i in "${!FOUND_IMAGES[@]}"; do
        echo "  $((i + 1))) $(basename "${FOUND_IMAGES[$i]}")"
    done
    echo "  $((n + 1))) Specify another path..."

    while [[ -z $SELECTED_IMAGE ]]; do
        must_read -r -p "Select an option [1-$((n + 1))]: " img_choice
        if [[ $img_choice =~ ^[0-9]+$ ]] && (( 10#$img_choice >= 1 && 10#$img_choice <= n )); then
            SELECTED_IMAGE=${FOUND_IMAGES[10#$img_choice - 1]}
        elif [[ $img_choice =~ ^[0-9]+$ ]] && (( 10#$img_choice == n + 1 )); then
            prompt_image_path
        else
            warn "Invalid selection."
        fi
    done
else
    prompt_image_path
fi

IMAGE_NAME=$(basename "$SELECTED_IMAGE")

IMAGE_ARCH="aarch64"
if [[ $IMAGE_NAME =~ armhf ]]; then
    IMAGE_ARCH="armhf"
elif [[ $IMAGE_NAME =~ armv7 ]]; then
    IMAGE_ARCH="armv7"
fi

# Detect the Pi family from the image name so we can apply the right
# config.txt defaults and network strategy on first boot.
# RPi 1 (A/B/A+/B+/Zero/W)      => armhf, ARMv6 single-core
# RPi 2                           => armv7 (or armhf for older images)
# RPi 3/4/5/Zero2W/CM etc.        => aarch64 (or armv7/armhf)
# We only need special handling for the armhf/ARMv6 family here.
IS_RPI_OLD=0   # 1 = RPi 1 or 2 family (needs ethernet-tolerant boot)
if [[ $IMAGE_ARCH == "armhf" || $IMAGE_ARCH == "armv7" ]]; then
    IS_RPI_OLD=1
fi

# Pin package repositories to the release that was flashed (e.g. v3.21), so the
# kernel/modloop and every package installed later come from the same branch.
ALPINE_BRANCH="latest-stable"
if [[ $IMAGE_NAME =~ ([0-9]+\.[0-9]+)\.[0-9]+ ]]; then
    ALPINE_BRANCH="v${BASH_REMATCH[1]}"
else
    warn "Could not read the Alpine version from '$IMAGE_NAME'; using 'latest-stable' repositories."
fi

IMAGE_BYTES=0
if [[ $SELECTED_IMAGE == *.xz ]]; then
    command -v xz &>/dev/null || die "Required command 'xz' is not installed."
    IMAGE_BYTES=$(xz --robot --list "$SELECTED_IMAGE" 2>/dev/null | awk '$1=="totals"{print $5}')
elif [[ $SELECTED_IMAGE == *.gz ]]; then
    IMAGE_BYTES=$(gzip -l "$SELECTED_IMAGE" 2>/dev/null | awk 'NR==2{print $2}')
else
    IMAGE_BYTES=$(stat -c %s "$SELECTED_IMAGE" 2>/dev/null || echo 0)
fi
[[ $IMAGE_BYTES =~ ^[0-9]+$ ]] || IMAGE_BYTES=0

echo "[+] Selected image: $IMAGE_NAME (Arch: $IMAGE_ARCH, repositories: $ALPINE_BRANCH)"
(( IS_RPI_OLD )) && echo "[+] RPi 1/2 compatibility mode active (armhf/armv7 image detected)."

# ------------------------------------------------------------------------------
# 2. Select target MicroSD card
# ------------------------------------------------------------------------------
echo
echo "--- [Step 2/5] Select Target MicroSD Card ---"

AVAILABLE_DISKS=()
while IFS= read -r line; do
    [[ -n $line ]] && AVAILABLE_DISKS+=("$line")
done < <(list_candidate_disks)

if (( ${#AVAILABLE_DISKS[@]} == 0 )); then
    echo "[!] No safe, removable drives detected."
    echo "    Plug in your MicroSD card and re-run the script."
    echo "    (Use --show-all to list non-removable, non-system disks,"
    echo "     or --debug to see why each disk was skipped.)"
    exit 1
fi

echo "Available drives:"
for i in "${!AVAILABLE_DISKS[@]}"; do
    IFS='|' read -r dev size tran model <<< "${AVAILABLE_DISKS[$i]}"
    echo "  $((i + 1))) $dev  (Size: $size, Transport: $tran, Model: $model)"
done

TARGET_DISK=""
while [[ -z $TARGET_DISK ]]; do
    must_read -r -p "Select drive to flash [1-${#AVAILABLE_DISKS[@]}]: " disk_choice
    if [[ $disk_choice =~ ^[0-9]+$ ]] && (( 10#$disk_choice >= 1 && 10#$disk_choice <= ${#AVAILABLE_DISKS[@]} )); then
        IFS='|' read -r TARGET_DISK disk_size disk_tran disk_model <<< "${AVAILABLE_DISKS[10#$disk_choice - 1]}"
    else
        warn "Invalid selection."
    fi
done

[[ -b $TARGET_DISK ]] || die "$TARGET_DISK is not a block device."
DISK_BYTES=$(lsblk -bdno SIZE "$TARGET_DISK" | tr -d ' ')
if (( IMAGE_BYTES > 0 && IMAGE_BYTES > DISK_BYTES )); then
    die "Image ($(human_bytes "$IMAGE_BYTES")) is larger than $TARGET_DISK ($(human_bytes "$DISK_BYTES"))."
fi
echo "[+] Target drive: $TARGET_DISK ($disk_size)"

# ------------------------------------------------------------------------------
# 3. Headless provisioning questions
# ------------------------------------------------------------------------------
echo
echo "--- [Step 3/5] Headless Configuration Settings ---"
echo "Alpine will be installed in persistent 'sys' mode on the ext4 partition by"
echo "the Pi itself on first boot (internet access is required for that step)."

# --- User & Root accounts -----------------------------------------------------
CREATE_USER=0
RPI_USER="alpine"
PASS_HASH=""
ROOT_PASS_HASH=""
ROOT_PASS_DESC=""
ALLOW_ROOT_SSH=0
SSH_ROOT_DESC="Disabled (PermitRootLogin no)"

if ask_yn "Create a user account with admin (sudo) privileges?" Y; then
    CREATE_USER=1
    while true; do
        must_read -r -p "Enter username [default: alpine]: " user_input
        RPI_USER=${user_input:-alpine}
        if [[ $RPI_USER =~ ^[a-z_][a-z0-9_-]{0,31}$ && $RESERVED_USERS != *" $RPI_USER "* ]]; then
            break
        fi
        warn "Invalid username (lowercase letters, digits, '_' or '-', max 32 chars, not a system account name)."
    done

    while true; do
        must_read -r -s -p "Enter password for '$RPI_USER': " RPI_PASS
        echo
        must_read -r -s -p "Confirm password: " RPI_PASS_CONFIRM
        echo
        if [[ -z $RPI_PASS ]]; then
            warn "Password cannot be empty."
        elif [[ $RPI_PASS != "$RPI_PASS_CONFIRM" ]]; then
            warn "Passwords do not match. Try again."
        else
            break
        fi
    done

    PASS_HASH=$(printf '%s' "$RPI_PASS" | openssl passwd -6 -stdin)
    unset RPI_PASS RPI_PASS_CONFIRM
    [[ $PASS_HASH == '$6$'* ]] || die "Failed to hash the password with openssl."
    echo "[+] User '$RPI_USER' will be created in wheel group with sudo enabled."

    if ask_yn "Use the same password for 'root'?" Y; then
        ROOT_PASS_HASH="$PASS_HASH"
        ROOT_PASS_DESC="Same as user '$RPI_USER'"
        echo "[+] Root password set to match '$RPI_USER'."
    else
        while true; do
            must_read -r -s -p "Enter password for 'root' (leave empty to lock root account): " ROOT_PASS
            echo
            if [[ -z $ROOT_PASS ]]; then
                ROOT_PASS_HASH="*"
                ROOT_PASS_DESC="Locked (password login disabled)"
                echo "[+] Root password locked."
                break
            fi
            must_read -r -s -p "Confirm password for 'root': " ROOT_PASS_CONFIRM
            echo
            if [[ $ROOT_PASS != "$ROOT_PASS_CONFIRM" ]]; then
                warn "Passwords do not match. Try again."
            else
                ROOT_PASS_HASH=$(printf '%s' "$ROOT_PASS" | openssl passwd -6 -stdin)
                unset ROOT_PASS ROOT_PASS_CONFIRM
                [[ $ROOT_PASS_HASH == '$6$'* ]] || die "Failed to hash the root password with openssl."
                ROOT_PASS_DESC="Custom password configured"
                echo "[+] Custom root password configured."
                break
            fi
        done
    fi

    if ask_yn "Allow logging into 'root' directly over SSH?" N; then
        ALLOW_ROOT_SSH=1
        SSH_ROOT_DESC="Allowed"
        echo "[+] Direct SSH login for 'root' enabled."
    else
        ALLOW_ROOT_SSH=0
        SSH_ROOT_DESC="Disabled (PermitRootLogin no)"
        echo "[+] Direct SSH login for 'root' disabled (PermitRootLogin no)."
    fi
else
    warn "Without a user account, root access will be used."
    ALLOW_ROOT_SSH=1
    SSH_ROOT_DESC="Allowed (only account)"
    while true; do
        must_read -r -s -p "Enter password for 'root' (leave empty to lock root account): " ROOT_PASS
        echo
        if [[ -z $ROOT_PASS ]]; then
            if ask_yn "Root password is empty. Leave root account locked (requires SSH key)?" N; then
                ROOT_PASS_HASH="*"
                ROOT_PASS_DESC="Locked (SSH key only)"
                echo "[+] Root password locked."
                break
            else
                continue
            fi
        fi
        must_read -r -s -p "Confirm password for 'root': " ROOT_PASS_CONFIRM
        echo
        if [[ $ROOT_PASS != "$ROOT_PASS_CONFIRM" ]]; then
            warn "Passwords do not match. Try again."
        else
            ROOT_PASS_HASH=$(printf '%s' "$ROOT_PASS" | openssl passwd -6 -stdin)
            unset ROOT_PASS ROOT_PASS_CONFIRM
            [[ $ROOT_PASS_HASH == '$6$'* ]] || die "Failed to hash the root password with openssl."
            ROOT_PASS_DESC="Custom password configured"
            echo "[+] Root password configured."
            break
        fi
    done
fi

# --- Hostname -----------------------------------------------------------------
must_read -r -p "Set hostname [default: alpine]: " host_input
RPI_HOSTNAME=$(printf '%s' "${host_input:-alpine}" \
    | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-' | sed -E 's/^-+//; s/-+$//' | cut -c1-63)
if [[ -z $RPI_HOSTNAME ]]; then
    RPI_HOSTNAME="alpine"
fi
echo "[+] Hostname will be set to: $RPI_HOSTNAME"

# --- Timezone -----------------------------------------------------------------
DETECTED_TZ=$(timedatectl show --value -p Timezone 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "$DEFAULT_TIMEZONE")
DETECTED_TZ=${DETECTED_TZ:-$DEFAULT_TIMEZONE}
while true; do
    must_read -r -p "Set timezone [default: $DETECTED_TZ]: " tz_input
    TIMEZONE=${tz_input:-$DETECTED_TZ}
    if [[ ! $TIMEZONE =~ ^[A-Za-z0-9_+/-]+$ || $TIMEZONE == *..* ]]; then
        warn "Invalid timezone name."
    elif [[ -d /usr/share/zoneinfo && ! -f /usr/share/zoneinfo/$TIMEZONE ]]; then
        warn "Unknown timezone '$TIMEZONE' (expected something like America/Los_Angeles or UTC)."
    else
        break
    fi
done
echo "[+] Timezone: $TIMEZONE"

# --- IPv6 ---------------------------------------------------------------------
DISABLE_IPV6=0
if ask_yn "Disable IPv6?" Y; then
    DISABLE_IPV6=1
fi

# --- Headless boot options ----------------------------------------------------
HEADLESS_TWEAKS=0
if ask_yn "Apply headless boot tweaks (gpu_mem=32, audio off)?" N; then
    HEADLESS_TWEAKS=1
fi

# --- Wi-Fi --------------------------------------------------------------------
WIFI_COUNTRY="$DEFAULT_WIFI_COUNTRY"
WIFI_SSIDS=()
WIFI_PSKS=()
if ask_yn "Pre-configure Wi-Fi for first boot?" N; then
    for cmd in curl python3; do
        command -v "$cmd" &>/dev/null || die "Wi-Fi setup needs '$cmd' (to stage the Wi-Fi firmware)."
    done
    while true; do
        must_read -r -p "Enter Wi-Fi country code [default: $DEFAULT_WIFI_COUNTRY]: " country_input
        WIFI_COUNTRY=$(printf '%s' "${country_input:-$DEFAULT_WIFI_COUNTRY}" | tr '[:lower:]' '[:upper:]')
        [[ $WIFI_COUNTRY =~ ^[A-Z]{2}$ ]] && break
        warn "Country code must be two letters (e.g. US, GB, DE)."
    done

    while true; do
        must_read -r -p "Enter Wi-Fi SSID: " net_ssid
        if [[ -z $net_ssid ]]; then
            warn "SSID cannot be empty."
            continue
        fi
        if (( $(printf '%s' "$net_ssid" | wc -c) > 32 )); then
            warn "SSID cannot be longer than 32 bytes."
            continue
        fi
        must_read -r -s -p "Enter Wi-Fi password for '$net_ssid' (empty if open network): " net_pass
        echo
        if ! valid_psk "$net_pass"; then
            warn "WPA passwords must be 8-63 characters."
            continue
        fi
        WIFI_SSIDS+=("$net_ssid")
        WIFI_PSKS+=("$net_pass")
        echo "[+] Added Wi-Fi network: $net_ssid"
        ask_yn "Add another Wi-Fi network?" N || break
    done
fi

# --- SSH public key & custom files --------------------------------------------
SSH_PUBKEY=""
INJECT_FILES=()
SSH_TARGET_USER="$RPI_USER"
(( CREATE_USER == 0 )) && SSH_TARGET_USER="root"

# If root is locked and there is no user, an SSH key is the only way in.
KEY_REQUIRED=0
if (( CREATE_USER == 0 )) && [[ $ROOT_PASS_HASH == "*" ]]; then
    KEY_REQUIRED=1
    warn "Root is locked and no user account exists: an SSH public key is required."
fi

want_key=0
if (( KEY_REQUIRED )); then
    want_key=1
elif ask_yn "Install an SSH public key for '$SSH_TARGET_USER'?" N; then
    want_key=1
fi

if (( want_key )); then
    default_key=""
    for k in "$USER_HOME/.ssh/id_ed25519.pub" "$USER_HOME/.ssh/id_ecdsa.pub" "$USER_HOME/.ssh/id_rsa.pub"; do
        if [[ -f $k ]]; then default_key=$k; break; fi
    done
    while true; do
        must_read -r -e -p "Path to public key [${default_key:-none}]: " key_input
        key_input=${key_input:-$default_key}
        key_input=${key_input/#\~/$USER_HOME}
        if [[ -z $key_input ]]; then
            if (( KEY_REQUIRED )); then
                warn "A key is required."
                continue
            fi
            warn "No key selected; skipping."
            break
        elif [[ -f $key_input ]] && grep -Eq '^(ssh-|ecdsa-|sk-)' "$key_input"; then
            SSH_PUBKEY=$(realpath "$key_input")
            echo "[+] Will install public key: $SSH_PUBKEY"
            break
        else
            warn "Not a valid public key file: $key_input"
            default_key=""
        fi
    done
fi

if (( CREATE_USER )); then
    if ask_yn "Include file(s) in the user's home folder (/home/$RPI_USER)?" N; then
        while true; do
            must_read -r -e -p "Enter path to file or folder to include: " custom_file
            custom_file=${custom_file/#\~/$USER_HOME}
            if [[ -e $custom_file ]]; then
                INJECT_FILES+=("$(realpath "$custom_file")")
                echo "[+] Queued: $custom_file"
            else
                warn "Path does not exist: $custom_file"
            fi
            ask_yn "Include another file?" N || break
        done
        # The overlay is unpacked into RAM on first boot, so keep it modest.
        if (( ${#INJECT_FILES[@]} > 0 )); then
            inject_bytes=$(du -scb -- "${INJECT_FILES[@]}" 2>/dev/null | tail -n 1 | cut -f1)
            if [[ $inject_bytes =~ ^[0-9]+$ ]] && (( inject_bytes > 50 * 1024 * 1024 )); then
                warn "Included files total $(human_bytes "$inject_bytes"); they are unpacked into RAM on first boot."
                ask_yn "Continue anyway?" N || die "Aborted. Nothing was written."
            fi
        fi
    fi
fi

# ------------------------------------------------------------------------------
# Final confirmation
# ------------------------------------------------------------------------------
echo
echo "Summary:"
echo "  Image:      $IMAGE_NAME ($IMAGE_ARCH, repos: $ALPINE_BRANCH)"
echo "  Target:     $TARGET_DISK ($disk_size, $disk_model)"
echo "  Install:    sys mode (installed by the Pi on first boot, needs internet)"
echo "  Hostname:   $RPI_HOSTNAME"
echo "  Timezone:   $TIMEZONE"
(( IS_RPI_OLD )) && echo "  Pi Family:  RPi 1/2 (armhf/armv7) — ethernet-tolerant boot enabled"
if (( CREATE_USER )); then
    echo "  User:       $RPI_USER (sudo admin)"
fi
echo "  Root Pass:  $ROOT_PASS_DESC"
echo "  Root SSH:   $SSH_ROOT_DESC"
[[ -n $SSH_PUBKEY ]] && echo "  SSH Key:    $(basename "$SSH_PUBKEY") (for '$SSH_TARGET_USER')"
if (( ${#WIFI_SSIDS[@]} > 0 )); then
    echo "  Wi-Fi:      ${#WIFI_SSIDS[@]} network(s) configured (Country: $WIFI_COUNTRY)"
fi
echo
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$TARGET_DISK"
echo
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
echo "  WARNING: ALL DATA ON $TARGET_DISK ($disk_size) WILL BE DESTROYED!"
echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
must_read -r -p "Type the device path ($TARGET_DISK) to confirm: " confirm_dev
if [[ $confirm_dev != "$TARGET_DISK" ]]; then
    echo "Operation cancelled. Nothing was written."
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Flash image or unpack archive
# ------------------------------------------------------------------------------
echo
echo "--- [Step 4/5] Preparing SD Card on $TARGET_DISK ---"

is_system_disk "$TARGET_DISK" && die "Refusing to write: $TARGET_DISK carries system mounts."
disk_holds_path "$TARGET_DISK" "$SELECTED_IMAGE" && die "The image file is stored on $TARGET_DISK."

echo "Unmounting any existing partitions on $TARGET_DISK..."
unmount_disk "$TARGET_DISK"
[[ -z $(disk_mountpoints "$TARGET_DISK") ]] || die "Could not unmount all partitions on $TARGET_DISK."

if [[ $SELECTED_IMAGE =~ \.tar\.gz$ ]]; then
    echo "Partitioning $TARGET_DISK (512MB FAT32 boot + ext4 root)..."
    parted -s "$TARGET_DISK" -- mklabel msdos || die "parted mklabel failed."
    parted -s "$TARGET_DISK" -- mkpart primary fat32 4MiB 512MiB || die "parted mkpart (boot) failed."
    parted -s "$TARGET_DISK" -- set 1 boot on || die "parted set boot failed."
    parted -s "$TARGET_DISK" -- mkpart primary ext4 512MiB 100% || die "parted mkpart (root) failed."
    partprobe "$TARGET_DISK" 2>/dev/null
    udevadm settle 2>/dev/null || sleep 2

    find_partitions
    [[ -n $BOOT_PART ]] || die "Could not find boot partition."
    [[ -n $ROOT_PART ]] || die "Could not find root partition."

    unmount_disk "$TARGET_DISK"   # automounters may have grabbed the new partitions
    echo "Formatting boot partition ($BOOT_PART) as FAT32..."
    mkfs.vfat -F32 -n BOOT "$BOOT_PART" || die "mkfs.vfat failed."
    echo "Formatting root partition ($ROOT_PART) as ext4..."
    make_ext4 "$ROOT_PART" rootfs || die "mkfs.ext4 failed on $ROOT_PART (is it still mounted?)."

    BOOT_MNT=$(mktemp -d /tmp/alpine-boot-XXXXXX)
    MOUNT_DIRS+=("$BOOT_MNT")
    mount_retry "$BOOT_PART" "$BOOT_MNT" || die "Could not mount boot partition $BOOT_PART."

    echo "Extracting Alpine Linux archive to $BOOT_PART..."
    tar -zxf "$SELECTED_IMAGE" -C "$BOOT_MNT" --no-same-owner || die "Extraction failed."
else
    echo "Flashing image to $TARGET_DISK with dd..."
    if [[ $SELECTED_IMAGE == *.xz ]]; then
        xz -dc -- "$SELECTED_IMAGE" | dd of="$TARGET_DISK" bs=4M iflag=fullblock conv=fsync status=progress
    elif [[ $SELECTED_IMAGE == *.gz ]]; then
        gzip -dc -- "$SELECTED_IMAGE" | dd of="$TARGET_DISK" bs=4M iflag=fullblock conv=fsync status=progress
    else
        dd if="$SELECTED_IMAGE" of="$TARGET_DISK" bs=4M conv=fsync status=progress
    fi
    flash_rc=$?
    (( flash_rc == 0 )) || die "Flashing failed (exit code $flash_rc)."

    echo "Flushing writes and refreshing partition table..."
    sync
    partprobe "$TARGET_DISK" 2>/dev/null
    udevadm settle 2>/dev/null || sleep 2

    find_partitions
    [[ -n $BOOT_PART ]] || die "Could not identify boot partition on $TARGET_DISK."

    # Standard Alpine image has one small FAT partition; add ext4 root after it.
    if [[ -z $ROOT_PART || $ROOT_PART == "$BOOT_PART" ]]; then
        echo "Creating ext4 root partition on the remaining SD card space..."
        p1_end=$(parted -s "$TARGET_DISK" unit s print 2>/dev/null | awk '$1=="1"{print $3}' | tr -d 's')
        [[ $p1_end =~ ^[0-9]+$ ]] || die "Could not determine the end of partition 1."
        # Round the start up to a 4 MiB boundary (8192 sectors) for SD card alignment.
        next_sector=$(( ((p1_end + 1 + 8191) / 8192) * 8192 ))
        # A previously used card may still hold an old ext4 superblock at this spot
        # (parted warns about it and automounters pick it up): zero the first 8 MiB.
        dd if=/dev/zero of="$TARGET_DISK" bs=512 seek="$next_sector" count=16384 conv=fsync status=none 2>/dev/null
        parted -s "$TARGET_DISK" mkpart primary ext4 "${next_sector}s" 100% || die "Could not create the root partition."
        partprobe "$TARGET_DISK" 2>/dev/null
        udevadm settle 2>/dev/null || sleep 2
        find_partitions
        [[ -n $ROOT_PART && $ROOT_PART != "$BOOT_PART" ]] || die "Root partition did not appear."
        echo "Formatting $ROOT_PART as ext4..."
        make_ext4 "$ROOT_PART" rootfs || die "mkfs.ext4 failed on $ROOT_PART (is it still mounted?)."
    fi

    unmount_disk "$TARGET_DISK"
    BOOT_MNT=$(mktemp -d /tmp/alpine-boot-XXXXXX)
    MOUNT_DIRS+=("$BOOT_MNT")
    mount_retry "$BOOT_PART" "$BOOT_MNT" || die "Could not mount boot partition $BOOT_PART."
fi

echo "[+] Boot partition ready at $BOOT_PART"

# ------------------------------------------------------------------------------
# 5. Headless provisioning: overlay (apkovl) and first-boot installer
# ------------------------------------------------------------------------------
echo
echo "--- [Step 5/5] Applying Alpine Headless Configuration ---"

STAGING_DIR=$(mktemp -d /tmp/alpine-apkovl-XXXXXX)
TEMP_DIRS+=("$STAGING_DIR")
chmod 755 "$STAGING_DIR"

mkdir -p "$STAGING_DIR/usr/local/sbin"
mkdir -p "$STAGING_DIR"/{etc/{apk,conf.d,local.d,network,profile.d,runlevels/{boot,default,sysinit,shutdown},ssh,sudoers.d,sysctl.d,wpa_supplicant},home,root/.ssh}
chmod 755 "$STAGING_DIR/etc" "$STAGING_DIR/home"
chmod 700 "$STAGING_DIR/root" "$STAGING_DIR/root/.ssh"

# --- Wi-Fi firmware (needed on first boot, before any package can be installed)
fetch_apk() {  # fetch_apk <pkg> <repo>  -> prints path of the downloaded .apk
    local pkg=$1 repo=$2 base ver out
    base="https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/$repo/$IMAGE_ARCH"
    ver=$(curl -fsSL "$base/APKINDEX.tar.gz" 2>/dev/null \
        | tar -zxOf - APKINDEX 2>/dev/null \
        | awk -v RS='' -v FS='\n' -v want="$pkg" '
            { hit = 0; ver = ""
              for (i = 1; i <= NF; i++) {
                  if ($i == "P:" want) hit = 1
                  if (substr($i, 1, 2) == "V:") ver = substr($i, 3)
              }
              if (hit) { print ver; exit } }')
    [[ -n $ver ]] || return 1
    out="$FW_DIR/${pkg}-${ver}.apk"
    curl -fsSL -o "$out" "$base/${pkg}-${ver}.apk" || return 1
    printf '%s\n' "$out"
}

# Extract selected files from an .apk (concatenated gzip streams of tar data).
# Rejects absolute paths, '..' components and links that point outside dest.
extract_apk_to() {  # extract_apk_to <apk> <dest> <comma-separated substrings>
    python3 - "$1" "$2" "$3" <<'PYEOF'
import io, os, sys, tarfile, zlib

apk, dest, pats = sys.argv[1], os.path.realpath(sys.argv[2]), sys.argv[3]
patterns = [p for p in pats.split(",") if p]
data = open(apk, "rb").read()
count = 0
while data:
    d = zlib.decompressobj(16 + zlib.MAX_WBITS)
    raw = d.decompress(data)
    data = d.unused_data
    if not raw:
        continue
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r") as t:
        for m in t:
            name = m.name
            if name.startswith(".") or (patterns and not any(p in name for p in patterns)):
                continue
            if not (m.isreg() or m.isdir() or m.issym()):
                continue
            if os.path.isabs(name) or ".." in name.split("/"):
                sys.exit("unsafe path in package: " + name)
            if m.issym():
                tgt = os.path.normpath(os.path.join(dest, os.path.dirname(name), m.linkname))
                if os.path.isabs(m.linkname) or not tgt.startswith(dest + os.sep):
                    continue
            try:
                t.extract(m, dest, filter="data")
            except TypeError:  # Python without extraction filters
                t.extract(m, dest)
            count += 1
print(count)
PYEOF
}

if (( ${#WIFI_SSIDS[@]} > 0 )); then
    echo "[+] Staging Broadcom & Cypress Wi-Fi firmware ($ALPINE_BRANCH)..."
    FW_DIR=$(mktemp -d /tmp/alpine-fw-XXXXXX)
    TEMP_DIRS+=("$FW_DIR")
    mkdir -p "$STAGING_DIR/lib/firmware/brcm" "$STAGING_DIR/lib/firmware/cypress"
    chmod 755 "$STAGING_DIR/lib" "$STAGING_DIR/lib/firmware" "$STAGING_DIR/lib/firmware/brcm" "$STAGING_DIR/lib/firmware/cypress"

    fw_ok=0
    brcm_pkg=$(fetch_apk "linux-firmware-brcm" "main") \
        && extract_apk_to "$brcm_pkg" "$STAGING_DIR" "raspberrypi,43430,43455" >/dev/null \
        && fw_ok=1
    cypress_pkg=$(fetch_apk "linux-firmware-cypress" "main") \
        && extract_apk_to "$cypress_pkg" "$STAGING_DIR" "43430,43455" >/dev/null \
        && fw_ok=1
    (( fw_ok )) || warn "Could not stage Wi-Fi firmware; Wi-Fi may not work on first boot (use Ethernet)."

    # Provide both compressed and uncompressed copies of .zst firmware
    if command -v zstd &>/dev/null; then
        find "$STAGING_DIR/lib/firmware" -name '*.zst' -exec zstd -d -k -f -q {} + 2>/dev/null || true
    fi

    # Raspberry Pi model aliases, so the driver finds firmware under the names
    # it probes for (Zero W / Zero 2 W / 3B = 43430, 3B+ / 4B = 43455).
    (
        cd "$STAGING_DIR/lib/firmware/brcm" 2>/dev/null || exit 0
        # mklink <target> <name>: create only if nothing (not even a dangling link) is there
        mklink() { [[ -e $2 || -L $2 ]] || ln -s "$1" "$2"; }
        for ext in bin bin.zst clm_blob clm_blob.zst; do
            [[ -e ../cypress/cyfmac43430-sdio.$ext ]] && mklink "../cypress/cyfmac43430-sdio.$ext" "brcmfmac43430-sdio.$ext"
        done
        for sfx in txt txt.zst bin bin.zst clm_blob clm_blob.zst; do
            if [[ ! -e brcmfmac43430-sdio.$sfx ]]; then
                cand=$(ls brcmfmac43430-sdio.*."$sfx" 2>/dev/null | grep -v 'raspberrypi,' | head -n 1)
                [[ -z $cand ]] && cand=$(ls brcmfmac43430-sdio.*."$sfx" 2>/dev/null | head -n 1)
                [[ -n $cand ]] && mklink "$cand" "brcmfmac43430-sdio.$sfx"
            fi
            if [[ -e brcmfmac43430-sdio.$sfx ]]; then
                for model in model-zero-w model-zero-2-w 3-model-b; do
                    mklink "brcmfmac43430-sdio.$sfx" "brcmfmac43430-sdio.raspberrypi,$model.$sfx"
                done
            fi
        done
        for sfx in txt txt.zst; do
            if [[ -e brcmfmac43455-sdio.$sfx ]]; then
                for model in 4-model-b 3-model-b-plus; do
                    mklink "brcmfmac43455-sdio.$sfx" "brcmfmac43455-sdio.raspberrypi,$model.$sfx"
                done
            fi
        done
    )
fi

# --- Service runlevels --------------------------------------------------------
touch "$STAGING_DIR/etc/.default_boot_services"
ln -sf /etc/init.d/networking "$STAGING_DIR/etc/runlevels/boot/networking"
ln -sf /etc/init.d/sshd       "$STAGING_DIR/etc/runlevels/default/sshd"
ln -sf /etc/init.d/local      "$STAGING_DIR/etc/runlevels/default/local"
ln -sf /etc/init.d/chronyd    "$STAGING_DIR/etc/runlevels/default/chronyd"
ln -sf /etc/init.d/dbus       "$STAGING_DIR/etc/runlevels/default/dbus"
ln -sf /etc/init.d/avahi-daemon "$STAGING_DIR/etc/runlevels/default/avahi-daemon"

if (( ${#WIFI_SSIDS[@]} > 0 )); then
    echo "brcmfmac" > "$STAGING_DIR/etc/modules"
    ln -sf /etc/init.d/wpa_supplicant "$STAGING_DIR/etc/runlevels/boot/wpa_supplicant"
    printf 'wpa_supplicant_args="-i wlan0"\n' > "$STAGING_DIR/etc/conf.d/wpa_supplicant"
fi

# --- Hostname & Hosts ---------------------------------------------------------
printf '%s\n' "$RPI_HOSTNAME" > "$STAGING_DIR/etc/hostname"
cat > "$STAGING_DIR/etc/hosts" <<HOSTS_EOF
127.0.0.1	localhost localhost.localdomain
127.0.1.1	$RPI_HOSTNAME.local $RPI_HOSTNAME
::1		localhost ip6-localhost ip6-loopback
HOSTS_EOF

# --- Locale & Timezone --------------------------------------------------------
cat > "$STAGING_DIR/etc/profile.d/locale.sh" <<LOCALE_EOF
export LANG="$LOCALE"
export LC_ALL="$LOCALE"
export CHARSET="UTF-8"
LOCALE_EOF
chmod 755 "$STAGING_DIR/etc/profile.d/locale.sh"
printf '%s\n' "$TIMEZONE" > "$STAGING_DIR/etc/timezone"
# Alpine uses /etc/localtime (provided by the tzdata package listed in 'world')
ln -sf "/usr/share/zoneinfo/$TIMEZONE" "$STAGING_DIR/etc/localtime"

# --- IPv6 ---------------------------------------------------------------------
if (( DISABLE_IPV6 )); then
    cmd_found=0
    for cf in "$BOOT_MNT"/cmdline*.txt; do
        [[ -f $cf ]] || continue
        cmd_found=1
        grep -q "ipv6.disable=1" "$cf" || sed -i 's/$/ ipv6.disable=1/' "$cf"
    done
    (( cmd_found )) || warn "No cmdline*.txt found on the boot partition; IPv6 could not be disabled via the kernel command line."
    # Override Alpine's default sysctl.d settings to omit IPv6 keys and suppress boot errors
    cat > "$STAGING_DIR/etc/sysctl.d/00-alpine.conf" <<'SYSCTL_EOF'
# Alpine base settings without IPv6 (IPv6 disabled via cmdline)
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.ping_group_range = 999 59999
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_rfc1337 = 1
kernel.panic = 120
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
kernel.unprivileged_bpf_disabled = 1
SYSCTL_EOF
fi

# --- APK packages & repositories ---------------------------------------------
# The first-boot installer installs everything in 'world' into the new root.
cat > "$STAGING_DIR/etc/apk/world" <<'WORLD_EOF'
alpine-base
openssh
wpa_supplicant
chrony
sudo
e2fsprogs
tzdata
dbus
avahi
WORLD_EOF
if (( ${#WIFI_SSIDS[@]} > 0 )); then
    {
        echo "linux-firmware-brcm"
        echo "linux-firmware-cypress"
        echo "wireless-tools"
    } >> "$STAGING_DIR/etc/apk/world"
fi

# No /etc/apk/repositories in the overlay on purpose: during the first (RAM) boot
# Alpine's initramfs runs apk offline and would warn about missing network caches.
# The first-boot installer adds the pinned network repositories itself.

# --- Chrony: no battery-backed clock, so allow stepping the time at any moment ---
mkdir -p "$STAGING_DIR/etc/chrony"
cat > "$STAGING_DIR/etc/chrony/chrony.conf" <<'CHRONY_EOF'
pool pool.ntp.org iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 -1
CHRONY_EOF

# --- User accounts & authentication ------------------------------------------
cat > "$STAGING_DIR/etc/passwd" <<'PASSWD_EOF'
root:x:0:0:root:/root:/bin/ash
bin:x:1:1:bin:/bin:/sbin/nologin
daemon:x:2:2:daemon:/sbin:/sbin/nologin
adm:x:3:4:adm:/var/adm:/sbin/nologin
lp:x:4:7:lp:/var/spool/lpd:/sbin/nologin
sync:x:5:0:sync:/sbin:/bin/sync
shutdown:x:6:0:shutdown:/sbin:/sbin/shutdown
halt:x:7:0:halt:/sbin:/sbin/halt
mail:x:8:12:mail:/var/spool/mail:/sbin/nologin
news:x:9:13:news:/etc/news:/sbin/nologin
uucp:x:10:14:uucp:/var/spool/uucp:/sbin/nologin
operator:x:11:0:operator:/root:/sbin/nologin
man:x:13:15:man:/usr/man:/sbin/nologin
postmaster:x:14:12:postmaster:/var/spool/mail:/sbin/nologin
cron:x:16:16:cron:/var/spool/cron:/sbin/nologin
ftp:x:21:21::/var/lib/ftp:/sbin/nologin
sshd:x:22:22:sshd:/dev/null:/sbin/nologin
ntp:x:123:123:NTP:/var/empty:/sbin/nologin
nobody:x:65534:65534:nobody:/:/sbin/nologin
PASSWD_EOF

cat > "$STAGING_DIR/etc/group" <<'GROUP_EOF'
root:x:0:root
bin:x:1:root,bin,daemon
daemon:x:2:root,bin,daemon
sys:x:3:root,bin,adm
adm:x:4:root,adm,daemon
tty:x:5:
disk:x:6:root
lp:x:7:lp
mem:x:8:
kmem:x:9:
wheel:x:10:root
floppy:x:11:
mail:x:12:mail
news:x:13:news
uucp:x:14:uucp
man:x:15:man
cron:x:16:cron
console:x:17:
audio:x:18:
cdrom:x:19:
dialout:x:20:root
ftp:x:21:ftp
sshd:x:22:sshd
input:x:23:
tape:x:26:
video:x:27:root
netdev:x:28:
kvm:x:34:
shadow:x:42:
users:x:100:
nobody:x:65534:
GROUP_EOF

root_hash="${ROOT_PASS_HASH:-*}"
cat > "$STAGING_DIR/etc/shadow" <<SHADOW_EOF
root:${root_hash}:19000:0:99999:7:::
bin:!::0:::::
daemon:!::0:::::
adm:!::0:::::
lp:!::0:::::
sync:!::0:::::
shutdown:!::0:::::
halt:!::0:::::
mail:!::0:::::
news:!::0:::::
uucp:!::0:::::
operator:!::0:::::
man:!::0:::::
postmaster:!::0:::::
cron:!::0:::::
ftp:!::0:::::
sshd:!::0:::::
ntp:!::0:::::
nobody:!::0:::::
SHADOW_EOF
# The shadow file holds password hashes: root-only (group shadow may read it)
chown 0:42 "$STAGING_DIR/etc/shadow"
chmod 640 "$STAGING_DIR/etc/shadow"

if (( CREATE_USER )); then
    printf '%s:x:1000:1000:%s:/home/%s:/bin/ash\n' "$RPI_USER" "$RPI_USER" "$RPI_USER" >> "$STAGING_DIR/etc/passwd"
    printf '%s:%s:19000:0:99999:7:::\n' "$RPI_USER" "$PASS_HASH" >> "$STAGING_DIR/etc/shadow"
    printf '%s:x:1000:\n' "$RPI_USER" >> "$STAGING_DIR/etc/group"
    # (no 'disk' group: it grants raw read/write access to every block device)
    for grp in wheel audio video netdev input dialout; do
        sed -i -E "/^${grp}:/ { s/:$/:$RPI_USER/; t; s/\$/,$RPI_USER/ }" "$STAGING_DIR/etc/group"
    done

    mkdir -p "$STAGING_DIR/home/$RPI_USER"
    chmod 755 "$STAGING_DIR/home/$RPI_USER"
    chown -R 1000:1000 "$STAGING_DIR/home/$RPI_USER"

    # sudo itself comes from the 'world' file at install time.
    mkdir -p "$STAGING_DIR/etc/sudoers.d"
    echo "%wheel ALL=(ALL:ALL) ALL" > "$STAGING_DIR/etc/sudoers.d/wheel"
    chmod 440 "$STAGING_DIR/etc/sudoers.d/wheel"
fi

# --- SSH daemon & keys --------------------------------------------------------
root_permit="no"
if (( CREATE_USER == 0 )) || (( ALLOW_ROOT_SSH )); then
    if [[ $ROOT_PASS_HASH != "*" ]]; then
        root_permit="yes"
    else
        root_permit="prohibit-password"
    fi
fi

cat > "$STAGING_DIR/etc/ssh/sshd_config" <<SSHD_EOF
PermitRootLogin $root_permit
PasswordAuthentication yes
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
Subsystem sftp /usr/lib/ssh/sftp-server
SSHD_EOF
chmod 644 "$STAGING_DIR/etc/ssh/sshd_config"

if [[ -n $SSH_PUBKEY ]]; then
    if (( CREATE_USER )); then
        mkdir -p "$STAGING_DIR/home/$RPI_USER/.ssh"
        cat "$SSH_PUBKEY" > "$STAGING_DIR/home/$RPI_USER/.ssh/authorized_keys"
        chmod 700 "$STAGING_DIR/home/$RPI_USER/.ssh"
        chmod 600 "$STAGING_DIR/home/$RPI_USER/.ssh/authorized_keys"
        chown -R 1000:1000 "$STAGING_DIR/home/$RPI_USER/.ssh"
        echo "[+] Installed SSH public key for '$RPI_USER'"
    else
        cat "$SSH_PUBKEY" > "$STAGING_DIR/root/.ssh/authorized_keys"
        chmod 600 "$STAGING_DIR/root/.ssh/authorized_keys"
        echo "[+] Installed SSH public key for 'root'"
    fi
fi
unset PASS_HASH ROOT_PASS_HASH root_hash

# --- Injected user files ------------------------------------------------------
if (( CREATE_USER )); then
    for item in "${INJECT_FILES[@]}"; do
        echo "[+] Staging $(basename "$item") into /home/$RPI_USER..."
        cp -a -- "$item" "$STAGING_DIR/home/$RPI_USER/" || die "Failed to copy $item"
    done
    chown -R 1000:1000 "$STAGING_DIR/home/$RPI_USER"
    chmod 755 "$STAGING_DIR/home/$RPI_USER"
fi

# --- Network / Wi-Fi ----------------------------------------------------------
if (( ${#WIFI_SSIDS[@]} > 0 )); then
    {
        printf 'ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=wheel\nupdate_config=1\ncountry=%s\n' "$WIFI_COUNTRY"
        for i in "${!WIFI_SSIDS[@]}"; do
            ssid_val=${WIFI_SSIDS[$i]}
            psk_val=${WIFI_PSKS[$i]}
            printf '\nnetwork={\n    ssid="%s"\n' "$ssid_val"
            if [[ -z $psk_val ]]; then
                printf '    key_mgmt=NONE\n'
            else
                # Prefer the derived 256-bit PSK over the plaintext passphrase
                psk_hex=""
                if command -v wpa_passphrase &>/dev/null; then
                    psk_hex=$(wpa_passphrase "$ssid_val" "$psk_val" 2>/dev/null | sed -n 's/^[[:space:]]*psk=\([0-9a-f]\{64\}\)$/\1/p')
                fi
                if [[ -n $psk_hex ]]; then
                    printf '    psk=%s\n' "$psk_hex"
                else
                    printf '    psk="%s"\n' "$psk_val"
                fi
            fi
            printf '}\n'
        done
    } > "$STAGING_DIR/etc/wpa_supplicant/wpa_supplicant.conf"
    chmod 600 "$STAGING_DIR/etc/wpa_supplicant/wpa_supplicant.conf"

    # With Wi-Fi: eth0 uses 'auto' (always attempt, even without a cable);
    # on RPi 1/2 the smsc95xx USB-ethernet driver can be slow to appear so
    # we tolerate a missing interface rather than hanging boot.
    cat > "$STAGING_DIR/etc/network/interfaces" <<'IFACE_EOF'
auto lo
iface lo inet loopback

# Ethernet: bring up unconditionally; if the adapter is absent the
# pre-up guard exits cleanly so boot is not blocked.
auto eth0
iface eth0 inet dhcp
    pre-up for i in $(seq 1 15); do [ -d /sys/class/net/eth0 ] && break; sleep 1; done; [ -d /sys/class/net/eth0 ] || exit 0

auto wlan0
iface wlan0 inet dhcp
    pre-up /bin/sh -c 'rfkill unblock wifi 2>/dev/null; for i in $(seq 1 20); do [ -d /sys/class/net/wlan0 ] && exit 0; sleep 1; done; exit 0'
IFACE_EOF
else
    # Ethernet-only: use 'auto' so eth0 is always attempted.
    # The pre-up guard ensures the interface existing is not required —
    # if the adapter is absent (or slow to appear) boot continues cleanly.
    cat > "$STAGING_DIR/etc/network/interfaces" <<'IFACE_EOF'
auto lo
iface lo inet loopback

# Ethernet: bring up unconditionally; if the adapter is absent the
# pre-up guard exits cleanly so boot is not blocked.
auto eth0
iface eth0 inet dhcp
    pre-up for i in $(seq 1 15); do [ -d /sys/class/net/eth0 ] && break; sleep 1; done; [ -d /sys/class/net/eth0 ] || exit 0
IFACE_EOF
fi

# --- Directory permissions ----------------------------------------------------
chmod 755 "$STAGING_DIR" "$STAGING_DIR/etc" "$STAGING_DIR/home"
chmod 755 "$STAGING_DIR/lib" 2>/dev/null || true
chmod 700 "$STAGING_DIR/root" "$STAGING_DIR/root/.ssh"

# --- First-boot installer -----------------------------------------------------
cat > "$STAGING_DIR/etc/alpine-firstboot.conf" <<CONF_EOF
TARGET_USER="$RPI_USER"
TARGET_HOSTNAME="$RPI_HOSTNAME"
ALPINE_BRANCH="$ALPINE_BRANCH"
FLASH_EPOCH="$(date +%s)"
CONF_EOF

cat > "$STAGING_DIR/usr/local/sbin/alpine-firstboot.sh" <<'FIRSTBOOT_EOF'
#!/bin/sh
# /usr/local/sbin/alpine-firstboot.sh (started by /etc/local.d/00-firstboot.start)
# Generated by alpine-rpi-flash.sh. Installs Alpine ('sys' mode) onto the ext4
# partition and reboots into it. On failure the card stays bootable (RAM mode),
# nothing on the boot partition is switched to the ext4 root, and the install
# is retried on the next boot (up to 3 attempts).

# Locate the boot media (FAT, mounted under /media by Alpine's initramfs)
BOOT_MNT=$(awk '$3=="vfat" && $2 ~ /^\/media\// {print $2; exit}' /proc/mounts)
: "${BOOT_MNT:=/media/mmcblk0p1}"
mount -o remount,rw "$BOOT_MNT" 2>/dev/null || true

# Log to the boot partition when writable, otherwise to /tmp
LOGFILE="$BOOT_MNT/firstboot.log"
( : >> "$LOGFILE" ) 2>/dev/null || LOGFILE=/tmp/firstboot.log
exec >> "$LOGFILE" 2>&1

echo "=========================================================="
echo " Alpine Linux First-Boot Automated Provisioning"
echo " Started at: $(date)"
echo "=========================================================="

CONF="/etc/alpine-firstboot.conf"
[ -f "$CONF" ] && . "$CONF"
: "${TARGET_USER:=alpine}" "${TARGET_HOSTNAME:=alpine}" "${ALPINE_BRANCH:=latest-stable}" "${FLASH_EPOCH:=0}"

# The Pi has no battery-backed clock. A stale clock makes TLS fail ("server certificate
# not trusted"), so never run with a time earlier than when this card was flashed.
if [ "$(date +%s)" -lt "$FLASH_EPOCH" ]; then
    date -s "@$FLASH_EPOCH" >/dev/null 2>&1 && echo "Clock was behind; set to the flash time: $(date)"
fi

# Progress goes to the log and to the console (the installer runs in the background)
say() { echo "$*"; echo "[firstboot] $*" > /dev/console 2>/dev/null; }

# --- Retry bookkeeping --------------------------------------------------------
if [ -f "$BOOT_MNT/.firstboot-failed" ]; then
    echo "Earlier attempts failed; not retrying. See this log."
    exit 0
fi
ATT_FILE="$BOOT_MNT/.firstboot-attempts"
ATT=$(cat "$ATT_FILE" 2>/dev/null || echo 0)
ATT=$((ATT + 1))
echo "$ATT" > "$ATT_FILE" 2>/dev/null || true
if [ "$ATT" -gt 3 ]; then
    echo "Giving up after 3 failed attempts."
    touch "$BOOT_MNT/.firstboot-failed" 2>/dev/null || true
    exit 0
fi
echo "[+] Attempt $ATT/3 | User: $TARGET_USER | Hostname: $TARGET_HOSTNAME | Boot media: $BOOT_MNT"

STAGE=/stage

rescue_ssh() {
    # Best effort: make the card reachable over SSH so the log can be read.
    if apk add openssh >/dev/null 2>&1; then
        rc-service sshd start >/dev/null 2>&1 || true
        echo "[+] Rescue SSH started (running from RAM)."
    fi
}

fail() {
    say "ERROR: $*"
    tail -n 15 "$LOGFILE" > /dev/console 2>/dev/null
    umount "$STAGE/boot" 2>/dev/null || true
    umount "$STAGE" 2>/dev/null || true
    rm -f /tmp/fakeboot.img
    echo "Install failed (attempt $ATT/3). The card was NOT switched to the ext4 root."
    rescue_ssh
    exit 1
}

wait_net() {
    i=0
    while [ "$i" -lt 90 ]; do
        wget -q -T 4 --spider http://dl-cdn.alpinelinux.org/alpine/ 2>/dev/null && return 0
        i=$((i + 1))
        sleep 2
    done
    return 1
}

# --- 1. Radio, driver, network ------------------------------------------------
# Unblock Wi-Fi radios and load Broadcom driver (no-op on Pi 1/2 without Wi-Fi).
command -v rfkill >/dev/null 2>&1 && rfkill unblock wifi 2>/dev/null
modprobe brcmfmac 2>/dev/null || true

# Wait briefly for wlan0 then bring it up if present.
for _ in $(seq 1 10); do
    [ -d /sys/class/net/wlan0 ] && break
    sleep 1
done
if [ -d /sys/class/net/wlan0 ]; then
    ip link set wlan0 up 2>/dev/null || true
    ifup wlan0 2>/dev/null || true
fi

# Ethernet: actively bring up eth0 regardless of whether it was configured via
# allow-hotplug or auto.  On Raspberry Pi 1/2 the smsc95xx or LAN9514 USB
# Ethernet driver may appear well after the networking service starts (the USB
# bus on Pi 1 can take 30-45 s to fully enumerate), so we explicitly load the
# driver, then poll for the interface and attempt ifup.  If the interface is
# physically absent we still continue — Wi-Fi (if configured) may provide the
# connection, or the user accepts that internet is needed before first boot.
modprobe smsc95xx 2>/dev/null || true   # RPi 1 B / B+ / A+ USB ethernet
modprobe lan78xx  2>/dev/null || true   # RPi 3 B+ / CM3+ USB ethernet
say "Waiting for eth0 to appear (up to 45 s for USB ethernet)..."
eth0_up=0
for i in $(seq 1 45); do
    if [ -d /sys/class/net/eth0 ]; then
        ip link set eth0 up 2>/dev/null || true
        # Give the link a moment to negotiate before requesting DHCP
        sleep 2
        ifup eth0 2>/dev/null || true
        eth0_up=1
        say "eth0 is present and configured (attempt $i)."
        break
    fi
    sleep 1
done
if [ "$eth0_up" -eq 0 ]; then
    say "Warning: eth0 not found after 45 s (no cable or adapter absent). Continuing — will use Wi-Fi if available."
fi

say "Waiting for internet access..."
wait_net || fail "No internet access after 2 minutes (check Ethernet or Wi-Fi settings)."
# --- 2. Clock (needed for TLS) ------------------------------------------------
timeout 30 ntpd -q -n -p pool.ntp.org 2>/dev/null || echo "Warning: NTP sync failed; continuing."

# --- 3. Work out the partitions from the running boot media -------------------
BOOT_PART=$(awk -v m="$BOOT_MNT" '$2==m {print $1; exit}' /proc/mounts)
case $BOOT_PART in
    /dev/*1) ROOT_PART="${BOOT_PART%1}2" ;;
    *) fail "Cannot derive the root partition from boot device '$BOOT_PART'." ;;
esac
echo "[+] Boot partition: $BOOT_PART | Root partition: $ROOT_PART"

for _ in $(seq 1 15); do
    [ -b "$ROOT_PART" ] && break
    sleep 1
done
[ -b "$ROOT_PART" ] || fail "$ROOT_PART not found."

# --- 4. Repositories: local boot-media repo (if any) + pinned network repos ---
printf '%s\n' \
    "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main" \
    "https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/community" > /tmp/repositories.net
{
    [ -d "$BOOT_MNT/apks" ] && echo "$BOOT_MNT/apks"
    cat /tmp/repositories.net
} > /tmp/repositories.merged
cp /tmp/repositories.merged /etc/apk/repositories

command -v mkfs.ext4 >/dev/null 2>&1 || apk add e2fsprogs || fail "Could not install e2fsprogs."

# --- 5. Install onto the ext4 root --------------------------------------------
# setup-disk's Raspberry Pi support expects /boot to be a mounted FAT filesystem
# (without it the install does not complete). Handing it the REAL boot partition would
# let it rewrite firmware/config.txt/kernel before the install is known to have worked,
# so it gets a scratch FAT image in RAM instead. Only after everything succeeded are
# its results copied to the real boot partition (the "setup-alpine layout" described
# on the Alpine wiki's Raspberry Pi sys-mode page).

ls "$BOOT_MNT"/cmdline*.txt >/dev/null 2>&1 || fail "No cmdline*.txt found on the boot partition."
APKOVL_FILE=$(ls "$BOOT_MNT"/*.apkovl.tar.gz 2>/dev/null | head -n 1)
[ -n "$APKOVL_FILE" ] || fail "Overlay (*.apkovl.tar.gz) not found on the boot media."

# Keep the original command lines (they carry console=, ipv6.disable=, ...) in RAM
mkdir -p /tmp/cmdline.orig.d
cp "$BOOT_MNT"/cmdline*.txt /tmp/cmdline.orig.d/ || fail "Cannot read cmdline*.txt."

command -v mkfs.vfat >/dev/null 2>&1 || apk add dosfstools || fail "Could not install dosfstools."
modprobe loop 2>/dev/null || true
FAKEIMG=/tmp/fakeboot.img
rm -f "$FAKEIMG"
dd if=/dev/zero of="$FAKEIMG" bs=1M count=0 seek=160 2>/dev/null || fail "Cannot create the scratch boot image."
mkfs.vfat "$FAKEIMG" >/dev/null || fail "mkfs.vfat on the scratch image failed."

say "Formatting $ROOT_PART as ext4..."
mkfs.ext4 -q -F -L rootfs "$ROOT_PART" || fail "mkfs.ext4 failed."

mkdir -p "$STAGE"
mount "$ROOT_PART" "$STAGE" || fail "Cannot mount $ROOT_PART."
mkdir -p "$STAGE/boot"
mount -o loop "$FAKEIMG" "$STAGE/boot" || fail "Cannot mount the scratch boot image."

say "Installing Alpine to $ROOT_PART (setup-disk; this takes a few minutes)..."
setup-disk -m sys "$STAGE" </dev/null >/tmp/setup-disk.out 2>&1
SD_RC=$?
# Log the output without the progress-bar noise
tr '\r' '\n' < /tmp/setup-disk.out | tr -d '\033' | grep -v '%' | grep -v '\[fetch' | tail -n 60
echo "setup-disk exit code: $SD_RC"

# Sanity checks: bootloader warnings from setup-disk are ignorable, a missing system is not.
# (/sbin/init is an absolute symlink, so test the link itself and busybox inside the new root.)
[ -L "$STAGE/sbin/init" ] || [ -e "$STAGE/sbin/init" ] || fail "Installed root has no /sbin/init (setup-disk exit code $SD_RC)."
[ -x "$STAGE/bin/busybox" ] || fail "Installed root has no /bin/busybox."
[ -f "$STAGE/etc/alpine-release" ] || fail "Installed root has no /etc/alpine-release."
ls "$STAGE"/lib/modules/* >/dev/null 2>&1 || fail "Installed root has no kernel modules."
ls "$STAGE"/boot/vmlinuz-* >/dev/null 2>&1 || fail "setup-disk produced no kernel in /boot."
ls "$STAGE"/boot/initramfs-* >/dev/null 2>&1 || fail "setup-disk produced no initramfs in /boot."
[ "$SD_RC" -eq 0 ] || echo "Note: setup-disk returned $SD_RC; sanity checks passed, continuing."

echo "Applying configuration overlay to the installed root..."
# IMPORTANT: the overlay carries its own /etc/apk/world. If it simply replaced the one
# setup-disk wrote, the next 'apk add' would PURGE everything setup-disk installed that
# is not in our list (linux-rpi, raspberrypi-bootloader, mkinitfs, ...). So keep both.
cp "$STAGE/etc/apk/world" /tmp/world.setupdisk || fail "Cannot read the world file written by setup-disk."
# Same problem for the account databases: setup-disk already installed packages that
# created their own system users/groups (messagebus, chrony, avahi, ...). Save them so
# they can be merged back after the overlay's passwd/group/shadow are unpacked.
for f in passwd group shadow; do
    cp "$STAGE/etc/$f" "/tmp/$f.sys" || fail "Cannot read /etc/$f of the installed root."
done
tar -xzf "$APKOVL_FILE" -C "$STAGE" || fail "Could not unpack the overlay."
for f in passwd group shadow; do
    # append every entry of the installed system that the overlay does not define
    awk -F: 'NR==FNR { seen[$1] = 1; next } !($1 in seen)' "$STAGE/etc/$f" "/tmp/$f.sys" >> "$STAGE/etc/$f"
done
cp "$STAGE/etc/apk/world" /tmp/world.overlay
cat /tmp/world.setupdisk /tmp/world.overlay | grep -v '^#' | sort -u > "$STAGE/etc/apk/world"
rm -f "$STAGE/etc/local.d/00-firstboot.start" "$STAGE/usr/local/sbin/alpine-firstboot.sh" \
      "$STAGE/etc/alpine-firstboot.conf" "$STAGE/etc/.default_boot_services"
cp /tmp/repositories.net "$STAGE/etc/apk/repositories"

say "Installing packages into the new root..."
PKGS=$(grep -v '^#' /tmp/world.overlay | tr '\n' ' ')
# shellcheck disable=SC2086
apk add --root "$STAGE" --keys-dir /etc/apk/keys \
    --repositories-file /tmp/repositories.merged --no-progress $PKGS \
    || fail "apk add failed."

# Safety net: make sure the service accounts exist even if the merge missed them
ensure_sys_user() {  # ensure_sys_user <name> <home>
    grep -q "^$1:" "$STAGE/etc/passwd" && return 0
    echo "Account '$1' missing after merge; creating it."
    chroot "$STAGE" /bin/busybox addgroup -S "$1" 2>/dev/null
    chroot "$STAGE" /bin/busybox adduser -S -D -H -h "$2" -s /sbin/nologin -G "$1" -g "$1" "$1" \
        || echo "Warning: could not create account $1."
}
ensure_sys_user messagebus /dev/null
ensure_sys_user chrony /var/empty
ensure_sys_user avahi /run/avahi-daemon
grep -E '^(messagebus|chrony|avahi):' "$STAGE/etc/passwd"

# Nothing the install depends on may have been removed again
ls "$STAGE"/lib/modules/* >/dev/null 2>&1 || fail "Kernel modules disappeared after apk add."
ls "$STAGE"/boot/vmlinuz-* >/dev/null 2>&1 || fail "Kernel disappeared after apk add."
ls "$STAGE"/boot/initramfs-* >/dev/null 2>&1 || fail "Initramfs disappeared after apk add."

# Re-assert ownership/permissions
[ -f "$STAGE/etc/shadow" ] && { chown 0:42 "$STAGE/etc/shadow"; chmod 640 "$STAGE/etc/shadow"; }
[ -d "$STAGE/root" ] && { chown 0:0 "$STAGE/root"; chmod 700 "$STAGE/root"; }
[ -d "$STAGE/home/$TARGET_USER" ] && chown -R 1000:1000 "$STAGE/home/$TARGET_USER"
[ -f "$STAGE/etc/sudoers.d/wheel" ] && chmod 440 "$STAGE/etc/sudoers.d/wheel"

# Seed the installed system's clock (OpenRC's swclock restores it from this file's
# mtime), so the first boot has a sane time even before chrony has synchronised.
mkdir -p "$STAGE/lib/rc/cache"
touch "$STAGE/lib/rc/cache/shutdowntime"

# fstab: the FAT partition is /boot (kernel, initramfs, firmware and config.txt live there)
cat > "$STAGE/etc/fstab" <<FSTAB_EOF
# /etc/fstab: static file system information
$ROOT_PART	/	ext4	defaults,noatime	0	1
$BOOT_PART	/boot	vfat	defaults	0	2
FSTAB_EOF

# One-shot cleanup after the first successful boot from ext4: remove the overlay
# (it contains password hashes and Wi-Fi settings) from the FAT partition.
cat > "$STAGE/etc/local.d/10-bootcleanup.start" <<'CLEAN_EOF'
#!/bin/sh
mount -o remount,rw /boot 2>/dev/null
rm -f /boot/*.apkovl.tar.gz /boot/.firstboot-attempts
rm -f /etc/local.d/10-bootcleanup.start
CLEAN_EOF
chmod 755 "$STAGE/etc/local.d/10-bootcleanup.start"

# --- Switch the real boot partition over (last step, only after everything worked) ---
say "Writing the new boot files to the boot partition..."
mount -o remount,rw "$BOOT_MNT" 2>/dev/null || true
# Net space needed: size of every new file minus the size of the old file it overwrites
# (the firmware, device trees and overlays are replaced in place, only the kernel and
# initramfs are really new at the FAT root). 4 MiB margin for FAT cluster rounding.
need_bytes=$(cd "$STAGE/boot" && find . -type f | while IFS= read -r f; do
    n=$(stat -c %s "$f" 2>/dev/null || echo 0)
    o=$(stat -c %s "$BOOT_MNT/$f" 2>/dev/null || echo 0)
    echo $((n - o))
done | awk '{ s += $1 } END { print s + 0 }')
need=$(( need_bytes / 1024 + 4096 ))
free_k() { df -k "$BOOT_MNT" | awk 'NR==2 {print $4}'; }
avail=$(free_k)
echo "Boot partition: ${avail}K free, ${need}K needed (net)."

# Not enough room? Remove what is no longer needed, least important first:
# 1. the offline package repository, 2. the diskless modloop, 3. the old kernel and
# initramfs in boot/ (the new config.txt loads the new ones from the FAT root).
if [ "${avail:-0}" -lt "$need" ]; then
    rm -rf "$BOOT_MNT/apks"
    avail=$(free_k)
fi
if [ "${avail:-0}" -lt "$need" ]; then
    rm -f "$BOOT_MNT"/boot/modloop-*
    avail=$(free_k)
fi
if [ "${avail:-0}" -lt "$need" ]; then
    rm -f "$BOOT_MNT"/boot/vmlinuz-* "$BOOT_MNT"/boot/initramfs-*
    avail=$(free_k)
fi
echo "Boot partition after cleanup: ${avail}K free."
[ "${avail:-0}" -ge "$need" ] || fail "Not enough free space on the boot partition (${avail}K free, ${need}K needed)."
cp -R "$STAGE/boot/." "$BOOT_MNT/" || fail "Copying the boot files to the boot partition failed."
sync

# Command lines: original image command line (console=, ipv6.disable=, ...) + root=
fix_cmdline() {
    name=$1
    CMD=$(tr '\n' ' ' < "/tmp/cmdline.orig.d/$name" | sed -E 's/(^| )root=[^ ]*//g; s/(^| )rootfstype=[^ ]*//g; s/(^| )rootwait//g; s/  +/ /g; s/^ //; s/ $//')
    case $CMD in
        *modules=*) case $CMD in *ext4*) ;; *) CMD=$(echo "$CMD" | sed -E 's/modules=([^ ]*)/modules=\1,ext4/') ;; esac ;;
    esac
    cp "/tmp/cmdline.orig.d/$name" "$BOOT_MNT/$name.alpine-orig"
    echo "$CMD root=$ROOT_PART rootfstype=ext4 rootwait" > "$BOOT_MNT/$name"
    echo "[+] Updated $BOOT_MNT/$name:"
    cat "$BOOT_MNT/$name"
}
for cf in /tmp/cmdline.orig.d/cmdline*.txt; do
    [ -f "$cf" ] && fix_cmdline "${cf##*/}"
done

echo "Syncing..."
cp "$LOGFILE" "$STAGE/var/log/firstboot.log" 2>/dev/null || true
sync
umount "$STAGE/boot" 2>/dev/null || true
umount "$STAGE" 2>/dev/null || true
rm -f "$FAKEIMG"
sync

echo "=========================================================="
say " 'sys' installation complete! Rebooting into the system..."
echo "=========================================================="
sleep 3
reboot
exit 0
FIRSTBOOT_EOF
chmod 755 "$STAGING_DIR/usr/local/sbin/alpine-firstboot.sh"
chmod 755 "$STAGING_DIR/usr" "$STAGING_DIR/usr/local" "$STAGING_DIR/usr/local/sbin"

# Launcher: run the installer in the background so boot is not blocked (the
# console stays usable and SSH is reachable while the install runs).
cat > "$STAGING_DIR/etc/local.d/00-firstboot.start" <<'LAUNCH_EOF'
#!/bin/sh
setsid /usr/local/sbin/alpine-firstboot.sh </dev/null >/dev/null 2>&1 &
exit 0
LAUNCH_EOF
chmod 755 "$STAGING_DIR/etc/local.d/00-firstboot.start"

# --- Build .apkovl.tar.gz -----------------------------------------------------
echo "[+] Building overlay archive (${RPI_HOSTNAME}.apkovl.tar.gz)..."
tar --numeric-owner -czf "$BOOT_MNT/${RPI_HOSTNAME}.apkovl.tar.gz" -C "$STAGING_DIR" . || die "Failed to build apkovl."

# --- usercfg.txt (appended, never overwritten) --------------------------------
add_usercfg() {
    local line=$1
    grep -qxF "$line" "$BOOT_MNT/usercfg.txt" 2>/dev/null || echo "$line" >> "$BOOT_MNT/usercfg.txt"
}
if (( HEADLESS_TWEAKS )); then
    add_usercfg "# Generated by alpine-rpi-flash.sh"
    add_usercfg "gpu_mem=32"
    add_usercfg "dtparam=audio=off"
fi

# RPi 1 / 2 (armhf / armv7) safety patches for config.txt:
#   - Disable the VC4 KMS overlay: it is incompatible with BCM2835/BCM2836
#     and causes a black screen / kernel panic on Pi 1 and some Pi 2 boards.
#   - Force 32-bit mode (arm_64bit=0) so the 32-bit kernel is loaded.
#   - Remove dtoverlay=vc4-kms-v3d if the image already ships it.
if (( IS_RPI_OLD )); then
    add_usercfg "# RPi 1/2 compatibility (added by alpine-rpi-flash.sh)"
    add_usercfg "arm_64bit=0"
    add_usercfg "dtoverlay=disable-bt"

    # Patch config.txt in-place: comment out any vc4-kms-v3d overlay line
    # that the stock Alpine image may have written.
    for cfg in "$BOOT_MNT/config.txt" "$BOOT_MNT/usercfg.txt"; do
        [[ -f $cfg ]] || continue
        # Comment out vc4-kms-v3d (incompatible with BCM2835/BCM2836)
        sed -i 's/^\(dtoverlay=vc4-kms-v3d\)/#\1  # disabled for RPi 1\/2 by alpine-rpi-flash/' "$cfg" 2>/dev/null || true
    done
    echo "[+] Applied RPi 1/2 config.txt compatibility patches (arm_64bit=0, vc4-kms-v3d disabled)."
fi

echo "Flushing final filesystem sync..."
sync
umount "$BOOT_MNT" || die "Failed to unmount $BOOT_MNT. Do NOT remove card yet."
sync

echo
echo "=========================================================="
echo "  [SUCCESS] MicroSD Card is Ready to Boot Alpine Linux!  "
echo "=========================================================="
echo "Image:     $IMAGE_NAME ($IMAGE_ARCH, repos: $ALPINE_BRANCH)"
echo "Disk:      $TARGET_DISK"
echo "Install:   sys mode (installed by the Pi on first boot)"
echo "Hostname:  $RPI_HOSTNAME"
echo "Timezone:  $TIMEZONE"
echo "SSH:       Enabled (OpenSSH, mDNS via avahi)"
if (( IS_RPI_OLD )); then
    echo "Pi Family: RPi 1/2 (armhf/armv7) — ethernet-tolerant boot, vc4-kms-v3d disabled"
fi
if (( DISABLE_IPV6 )); then echo "IPv6:      Disabled"; else echo "IPv6:      Enabled"; fi
if (( CREATE_USER )); then
    echo "User:      $RPI_USER (sudo enabled)"
fi
echo "Root Pass: $ROOT_PASS_DESC"
echo "Root SSH:  $SSH_ROOT_DESC"
if [[ -n $SSH_PUBKEY ]]; then
    echo "SSH key:   $(basename "$SSH_PUBKEY") installed for '$SSH_TARGET_USER'"
fi
if (( ${#WIFI_SSIDS[@]} > 0 )); then
    echo "Wi-Fi:     ${#WIFI_SSIDS[@]} network(s) configured (Country: $WIFI_COUNTRY)"
    for ssid in "${WIFI_SSIDS[@]}"; do
        echo "           - $ssid"
    done
fi
if (( ${#INJECT_FILES[@]} > 0 )); then
    echo "Files in ~/:"
    for f in "${INJECT_FILES[@]}"; do
        echo "           - $(basename "$f")"
    done
fi
echo
echo "Next Steps:"
echo "  1. Unplug the MicroSD card and insert it into your Raspberry Pi."
echo "  2. Connect power. The Pi needs INTERNET ACCESS (Ethernet, or the Wi-Fi"
echo "     configured above): it downloads packages, installs Alpine onto the"
echo "     ext4 partition and reboots. Allow roughly 3-6 minutes."
echo "  3. If it does not come up, put the card back in this computer and read"
echo "     firstboot.log on the boot partition."
if (( CREATE_USER )); then
    echo "  4. Connect via SSH:"
    echo "     ssh $RPI_USER@$RPI_HOSTNAME.local"
    if [[ $root_permit == "yes" ]]; then
        echo "     (or ssh root@$RPI_HOSTNAME.local)"
    fi
else
    echo "  4. Connect via SSH:"
    echo "     ssh root@$RPI_HOSTNAME.local"
fi
echo "=========================================================="
