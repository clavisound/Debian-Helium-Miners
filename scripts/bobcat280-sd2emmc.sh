#!/bin/bash
# Clone SD card OS to eMMC on Bobcat 280 (PX30, GPT)
set -euo pipefail

SRC="/dev/mmcblk0"   # SD (booted from this)
DST="/dev/mmcblk2"   # eMMC (target)

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root" >&2
    exit 1
fi

# --- Preflight: ensure required tools are present, install only what's missing ---
declare -A PKG_FOR_CMD=(
    [parted]=parted
    [mkfs.vfat]=dosfstools
    [mkfs.ext4]=e2fsprogs
    [rsync]=rsync
    [sfdisk]=util-linux
    [blkid]=util-linux
    [findmnt]=util-linux
    [partprobe]=parted
)
MISSING_PKGS=()
for cmd in "${!PKG_FOR_CMD[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_PKGS+=("${PKG_FOR_CMD[$cmd]}")
    fi
done
if (( ${#MISSING_PKGS[@]} > 0 )); then
    UNIQUE_PKGS=($(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u))
    echo "Installing missing packages: ${UNIQUE_PKGS[*]}"
    apt-get update
    apt-get install -y "${UNIQUE_PKGS[@]}"
fi

ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/p\?[0-9]*$//')
if [[ "$ROOT_DEV" != "$SRC" ]]; then
    echo "ERROR: root ($ROOT_DEV) doesn't match expected SRC ($SRC)." >&2
    exit 1
fi

if [[ ! -b "$DST" ]]; then
    echo "ERROR: $DST not found." >&2
    exit 1
fi

if mount | grep -q "^${DST}"; then
    echo "ERROR: $DST has mounted partitions. Unmount first." >&2
    exit 1
fi

SRC_LABEL=$(parted -s "$SRC" print 2>/dev/null | awk -F': ' '/^Partition Table:/{print $2}')
if [[ "$SRC_LABEL" != "gpt" ]]; then
    echo "ERROR: expected GPT on $SRC, got '$SRC_LABEL'." >&2
    exit 1
fi

SRC_SIZE=$(blockdev --getsize64 "$SRC")
DST_SIZE=$(blockdev --getsize64 "$DST")
echo "SD (source):   $((SRC_SIZE/1024/1024)) MiB"
echo "eMMC (target): $((DST_SIZE/1024/1024)) MiB"

USED_ROOT_KB=$(df --output=used / | tail -1)
DST_MB=$((DST_SIZE/1024/1024))
BOOT_SIZE_MB=537
AVAIL_ROOT_MB=$((DST_MB - BOOT_SIZE_MB - 8))
if (( USED_ROOT_KB/1024 > AVAIL_ROOT_MB )); then
    echo "ERROR: rootfs uses ~$((USED_ROOT_KB/1024))MB, only ${AVAIL_ROOT_MB}MB available on eMMC." >&2
    exit 1
fi

PART1_START=$(sfdisk -d "$SRC" | awk '/p1 :/{if(match($0, /start= *[0-9]+/)){s=substr($0,RSTART,RLENGTH); gsub(/start= */,"",s); print s; exit}}')
if [[ -z "$PART1_START" ]]; then
    echo "ERROR: couldn't parse partition 1 start from 'sfdisk -d $SRC'." >&2
    exit 1
fi
echo "Boot area (idbloader/U-Boot) = first $PART1_START sectors"

BOOT_FSTYPE=$(blkid -s TYPE -o value "${SRC}p1")
ROOT_FSTYPE=$(blkid -s TYPE -o value "${SRC}p2")
echo "Boot fs: $BOOT_FSTYPE | Root fs: $ROOT_FSTYPE"

mkdir -p /mnt/src_boot
mountpoint -q /mnt/src_boot && umount /mnt/src_boot
mount -o ro "${SRC}p1" /mnt/src_boot
echo "Mounted ${SRC}p1 read-only at /mnt/src_boot"

lsblk "$SRC" "$DST"
echo "This will ERASE $DST (including its 'boot', 'update', and 'rootfs' partitions)."
read -rp "Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }

# --- 1. Raw-copy idbloader/U-Boot area (overwrites eMMC's incompatible factory U-Boot 2017.09) ---
echo "Copying idbloader/U-Boot area from SD to eMMC..."
dd if="$SRC" of="$DST" bs=512 count="$PART1_START" conv=fsync status=progress

# --- 2. Repartition eMMC: p1 = boot, p2 = rootfs, wiping old 3-part layout ---
echo "Partitioning $DST..."
BOOT_END_MB=$((PART1_START/2048 + BOOT_SIZE_MB))
parted -s "$DST" mklabel gpt
parted -s "$DST" mkpart boot fat32 "${PART1_START}s" "${BOOT_END_MB}MiB"
parted -s "$DST" set 1 esp on
parted -s "$DST" mkpart rootfs ext4 "${BOOT_END_MB}MiB" 100%
partprobe "$DST"
sleep 2

DST_P1="${DST}p1"
DST_P2="${DST}p2"

mkfs.vfat -F 32 -n boot "$DST_P1"
mkfs.ext4 -F -L rootfs "$DST_P2"

# --- 3. rsync boot and root ---
mkdir -p /mnt/dst_boot /mnt/dst_root
mount "$DST_P1" /mnt/dst_boot
mount "$DST_P2" /mnt/dst_root

echo "Rsyncing boot..."
rsync -aHAX --numeric-ids --info=progress2 /mnt/src_boot/ /mnt/dst_boot/

echo "Rsyncing root..."
rsync -aHAX --numeric-ids --info=progress2 \
    --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} \
    / /mnt/dst_root/

# --- 4. Fix extlinux.conf: point root= at eMMC's actual rootfs partition, not SD's ---
EXTLINUX_DST="/mnt/dst_boot/extlinux/extlinux.conf"
if [[ -f "$EXTLINUX_DST" ]]; then
    echo "Patching $EXTLINUX_DST: root= -> ${DST_P2}"
    sed -i "s|root=/dev/mmcblk[0-9]\+p2|root=${DST_P2}|" "$EXTLINUX_DST"
    sed -i "s|loglevel=1|loglevel=8|" "$EXTLINUX_DST"
    echo "--- resulting cmdline ---"
    grep '^cmdline=' "$EXTLINUX_DST"
else
    echo "WARNING: $EXTLINUX_DST not found — root path NOT patched, eMMC boot will fail." >&2
fi

umount /mnt/src_boot /mnt/dst_boot /mnt/dst_root

echo "Done. Remove SD card and power-cycle to boot from eMMC."
