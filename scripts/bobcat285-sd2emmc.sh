#!/bin/bash
# Clone SD card OS to eMMC on Bobcat 285 (RK3566/PX30)
# GPT layout: p1=uboot(raw,4M) p2=skyboot(vfat,512M) p3=update/rootfs(ext4,rest)
set -euo pipefail

SRC="/dev/mmcblk0"   # SD card (booted from this)
DST="/dev/mmcblk1"   # eMMC (target)

# Custom u-boot image (fallback bootcmd baked in) — downloaded and flashed to p1 instead of
# cloning the SD's copy.
UBOOT_IMG_URL="https://github.com/sicXnull/Debian-Helium-Miners/raw/refs/heads/main/loader-files/uboot.img"
UBOOT_IMG_PATH="/tmp/uboot.img"

# Partition names to match by (structure, not values, is assumed stable across units)
P1_NAME="uboot"
P2_NAME="skyboot"
P3_NAME="update"

# Pull start/size/type dynamically from the SD card's actual GPT table, matched by name —
# type GUIDs (and possibly offsets) can differ between units/firmware builds, so don't hardcode them.
get_field() {
    local line="$1" field="$2"
    case "$field" in
        start|size) echo "$line" | sed -n "s/.*${field}=[[:space:]]*\([0-9]\+\).*/\1/p" ;;
        type)       echo "$line" | sed -n 's/.*type=\([0-9A-Fa-f-]\+\).*/\1/p' ;;
    esac
}

get_part_line() {
    local name="$1"
    local line
    line=$(sfdisk -d "$SRC" | grep "name=\"${name}\"" || true)
    if [[ -z "$line" ]]; then
        echo "ERROR: no partition named '${name}' found on $SRC" >&2
        exit 1
    fi
    echo "$line"
}

L1=$(get_part_line "$P1_NAME")
L2=$(get_part_line "$P2_NAME")
L3=$(get_part_line "$P3_NAME")

P1_START=$(get_field "$L1" start); P1_SIZE=$(get_field "$L1" size); P1_TYPE=$(get_field "$L1" type)
P2_START=$(get_field "$L2" start); P2_SIZE=$(get_field "$L2" size); P2_TYPE=$(get_field "$L2" type)
P3_START=$(get_field "$L3" start);                                 P3_TYPE=$(get_field "$L3" type)

echo "Source partition table (read from $SRC):"
echo "  $P1_NAME:   start=$P1_START size=$P1_SIZE type=$P1_TYPE"
echo "  $P2_NAME: start=$P2_START size=$P2_SIZE type=$P2_TYPE"
echo "  $P3_NAME:   start=$P3_START type=$P3_TYPE (size on eMMC computed to fill remaining space)"

if [[ $EUID -ne 0 ]]; then
    echo "Must run as root" >&2; exit 1
fi

# Ensure required tools are installed (mkimage, sgdisk, mkfs.vfat/fsck.vfat, mkfs.ext4, rsync)
declare -A REQUIRED_PKGS=(
    [mkimage]=u-boot-tools
    [sgdisk]=gdisk
    [mkfs.vfat]=dosfstools
    [fsck.vfat]=dosfstools
    [mkfs.ext4]=e2fsprogs
    [rsync]=rsync
    [curl]=curl
)
MISSING_PKGS=()
for bin in "${!REQUIRED_PKGS[@]}"; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        MISSING_PKGS+=("${REQUIRED_PKGS[$bin]}")
    fi
done
if (( ${#MISSING_PKGS[@]} > 0 )); then
    UNIQUE_PKGS=($(printf '%s\n' "${MISSING_PKGS[@]}" | sort -u))
    echo "Installing missing packages: ${UNIQUE_PKGS[*]}"
    apt-get update && apt-get install -y "${UNIQUE_PKGS[@]}"
fi

ROOT_DEV=$(findmnt -n -o SOURCE / | sed 's/p\?[0-9]*$//')
if [[ "$ROOT_DEV" != "$SRC" ]]; then
    echo "ERROR: root ($ROOT_DEV) doesn't match expected SRC ($SRC)." >&2; exit 1
fi

if [[ ! -b "$DST" ]]; then
    echo "ERROR: $DST not found. Check lsblk — expected the eMMC (mmcblk1boot0/1 siblings)." >&2; exit 1
fi

if mount | grep -q "^${DST}"; then
    echo "ERROR: $DST has mounted partitions. Unmount first." >&2; exit 1
fi

SRC_SIZE=$(blockdev --getsize64 "$SRC")
DST_SIZE=$(blockdev --getsize64 "$DST")
DST_SECTORS=$(blockdev --getsz "$DST")
echo "SD (source):   $((SRC_SIZE/1024/1024)) MiB"
echo "eMMC (target): $((DST_SIZE/1024/1024)) MiB"

if (( DST_SIZE >= SRC_SIZE )); then
    echo "eMMC is not smaller than SD — will still fill p3 to available space, no shrink logic needed."
fi

USED_ROOT_KB=$(df --output=used / | tail -1)
# Reserve p1+p2+GPT/alignment slack; convert available sectors -> MB for the check
AVAIL_P3_SECTORS=$(( DST_SECTORS - P3_START - 100 ))   # 100-sector safety margin before backup GPT
AVAIL_P3_MB=$(( AVAIL_P3_SECTORS / 2048 ))
if (( USED_ROOT_KB/1024 > AVAIL_P3_MB )); then
    echo "ERROR: rootfs uses ~$((USED_ROOT_KB/1024))MB, only ${AVAIL_P3_MB}MB available on eMMC's p3." >&2
    echo "Free up space on / first, or this clone will not fit." >&2
    exit 1
fi
echo "rootfs used: $((USED_ROOT_KB/1024))MB — fits in ${AVAIL_P3_MB}MB available on eMMC p3"

echo "Downloading custom u-boot image..."
curl -fL -o "$UBOOT_IMG_PATH" "$UBOOT_IMG_URL"
UBOOT_IMG_SIZE=$(stat -c%s "$UBOOT_IMG_PATH")
P1_BYTES=$(( P1_SIZE * 512 ))
if (( UBOOT_IMG_SIZE > P1_BYTES )); then
    echo "ERROR: downloaded uboot.img is ${UBOOT_IMG_SIZE} bytes, exceeds p1's ${P1_BYTES}-byte capacity." >&2
    exit 1
fi
echo "uboot.img: ${UBOOT_IMG_SIZE} bytes (p1 capacity: ${P1_BYTES} bytes)"

lsblk "$SRC" "$DST"
read -rp "This will ERASE $DST. Type 'yes' to continue: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 1; }

echo "Wiping and repartitioning $DST (GPT, matching SD layout)..."
sgdisk --zap-all "$DST" >/dev/null
sgdisk -n "1:${P1_START}:$((P1_START+P1_SIZE-1))" -t "1:${P1_TYPE}" -c "1:${P1_NAME}" "$DST"
sgdisk -n "2:${P2_START}:$((P2_START+P2_SIZE-1))" -t "2:${P2_TYPE}" -c "2:${P2_NAME}" "$DST"
sgdisk -n "3:${P3_START}:0" -t "3:${P3_TYPE}" -c "3:${P3_NAME}" "$DST"   # 0 = use all remaining space
partprobe "$DST"
sleep 2
sgdisk -p "$DST"

DST_P1="${DST}p1"; DST_P2="${DST}p2"; DST_P3="${DST}p3"

echo "Flashing custom uboot.img to p1..."
dd if="$UBOOT_IMG_PATH" of="$DST_P1" bs=1M conv=fsync status=progress

echo "Raw-copying boot partition (p2, bit-for-bit — same size on both devices)..."
dd if="${SRC}p2" of="$DST_P2" bs=1M conv=fsync status=progress
fsck.vfat -a "$DST_P2" || true   # clear the "not properly unmounted" dirty bit carried over from the source

echo "Formatting p3 (rootfs, ext4)..."
mkfs.ext4 -F "$DST_P3"

mkdir -p /mnt/dst_root
mount "$DST_P3" /mnt/dst_root

echo "Rsyncing rootfs..."
rsync -aHAX --numeric-ids --info=progress2 \
    --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} \
    / /mnt/dst_root/

# Boot partition (p1, p2) is a byte-for-byte clone of the SD card. The only content change
# needed — confirmed by manual serial testing — is redirecting the two "load mmc 1:2" references
# in boot.cmd to "load mmc 0:2" (eMMC). Everything else (bootargs, root=/dev/mmcblk0p3, addresses)
# is left exactly as-is; testing confirmed those work unmodified once the device index is fixed.
mkdir -p /mnt/dst_boot
mount "$DST_P2" /mnt/dst_boot

BOOTCMD="/mnt/dst_boot/boot.cmd"
BOOTSCR="/mnt/dst_boot/boot.scr"

if [[ -f "$BOOTCMD" ]]; then
    cp "$BOOTCMD" "${BOOTCMD}.sdcard.bak"
    sed -i \
        -e 's/load mmc 1:2/load mmc 0:2/g' \
        -e 's|root=/dev/mmcblk0p3|root=/dev/mmcblk1p3|' \
        "$BOOTCMD"
    echo "--- Updated boot.cmd ---"
    cat "$BOOTCMD"
    echo "------------------------"
    mkimage -C none -A arm -T script -d "$BOOTCMD" "$BOOTSCR"
else
    echo "WARNING: $BOOTCMD not found on cloned boot partition — boot.scr NOT updated." >&2
fi

umount /mnt/dst_boot

umount /mnt/dst_root

echo "Done."
echo "This SoC's boot ROM may still prefer SD over eMMC (as with many Rockchip boards)."
echo "Pull the SD card and power-cycle to actually test eMMC boot."
