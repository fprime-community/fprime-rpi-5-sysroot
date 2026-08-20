#!/usr/bin/env bash
#
# shrink-sd-image.sh: produce a minimal-size image from a Raspberry Pi SD card
# without dumping the whole card.
#
# Shrinks the card's root filesystem and partition in place, copies only the
# used portion of the card to an image file, then runs the vendored PiShrink
# on the image to re-arm first-boot filesystem auto-expansion (and optionally
# compress). Flash the resulting image to any card >= the shrunk size; it
# expands to fill the card on first boot.
#
# Usage: sudo ./shrink-sd-image.sh <device> [output.img]
#   e.g. sudo ./shrink-sd-image.sh /dev/sdb rpi-golden.img
#
# WARNING: run this from a Linux host with the card in a reader — never on a
# system booted from the card. The card's partition table is modified.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PISHRINK="${SCRIPT_DIR}/pishrink/pishrink.sh"

usage() {
    echo "Usage: sudo $0 <device> [output.img]" >&2
    echo "  e.g. sudo $0 /dev/sdb rpi-golden.img" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root (use sudo)." >&2
    exit 1
fi

[ $# -ge 1 ] || usage
DEVICE="$1"
OUTPUT="${2:-rpi-shrunk.img}"

[ -b "${DEVICE}" ] || { echo "Error: ${DEVICE} is not a block device." >&2; exit 1; }
[ -x "${PISHRINK}" ] || { echo "Error: ${PISHRINK} not found." >&2; exit 1; }

for tool in parted e2fsck resize2fs tune2fs dd; do
    command -v "${tool}" >/dev/null || { echo "Error: ${tool} is not installed." >&2; exit 1; }
done

# Refuse to operate on the disk hosting the running root filesystem
ROOT_DISK="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)"
if [ -n "${ROOT_DISK}" ] && [ "/dev/${ROOT_DISK}" = "${DEVICE}" ]; then
    echo "Error: ${DEVICE} hosts the running root filesystem. Aborting." >&2
    exit 1
fi

# The root filesystem is the last (highest-numbered) partition
PART_NUM="$(parted -ms "${DEVICE}" unit B print | tail -1 | cut -d: -f1)"
case "${DEVICE}" in
    *[0-9]) PART="${DEVICE}p${PART_NUM}" ;;
    *)      PART="${DEVICE}${PART_NUM}" ;;
esac
[ -b "${PART}" ] || { echo "Error: partition ${PART} not found." >&2; exit 1; }

echo "Device: ${DEVICE}  root partition: ${PART}  output: ${OUTPUT}"
read -r -p "This will modify the partition table on ${DEVICE}. Continue? [y/N] " REPLY
[ "${REPLY}" = "y" ] || [ "${REPLY}" = "Y" ] || { echo "Aborted."; exit 1; }

# Unmount anything mounted from the card
for mp in $(lsblk -no MOUNTPOINT "${DEVICE}" | grep -v '^$' || true); do
    echo "Unmounting ${mp}"
    umount "${mp}"
done

echo "Checking and shrinking the root filesystem to minimum size"
e2fsck -f "${PART}"
resize2fs -M "${PART}"

# Compute the shrunk filesystem's size and shrink the partition to match (+8MiB margin)
BLOCK_COUNT="$(tune2fs -l "${PART}" | awk -F: '/^Block count/ {gsub(/ /,""); print $2}')"
BLOCK_SIZE="$(tune2fs -l "${PART}" | awk -F: '/^Block size/ {gsub(/ /,""); print $2}')"
PART_START="$(parted -ms "${DEVICE}" unit B print | awk -F: -v n="${PART_NUM}" '$1 == n {gsub(/B/,"",$2); print $2}')"
NEW_END=$(( PART_START + BLOCK_COUNT * BLOCK_SIZE + 8*1024*1024 ))

echo "Shrinking partition ${PART_NUM} to end at ${NEW_END} bytes"
# parted prompts for confirmation when shrinking even with -s;
# ---pretend-input-tty lets the piped "Yes" answer it
echo Yes | parted ---pretend-input-tty "${DEVICE}" unit B resizepart "${PART_NUM}" "${NEW_END}"
partprobe "${DEVICE}"

# Copy only up to the end of the last partition
END="$(parted -ms "${DEVICE}" unit B print | tail -1 | cut -d: -f3 | tr -d B)"
BS=$((4*1024*1024))
COUNT=$(( (END + BS - 1) / BS ))
echo "Copying $(( COUNT * BS / 1024 / 1024 )) MiB from ${DEVICE} to ${OUTPUT}"
dd if="${DEVICE}" of="${OUTPUT}" bs="${BS}" count="${COUNT}" status=progress
sync

# PiShrink re-arms first-boot auto-expansion and truncates/compresses the image.
# -n skips its online update check.
echo "Running PiShrink on ${OUTPUT}"
"${PISHRINK}" -n -z "${OUTPUT}"

# Return ownership of the produced image(s) to the invoking user
if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    for f in "${OUTPUT}" "${OUTPUT}.gz"; do
        if [ -e "${f}" ]; then
            chown "${SUDO_USER}:$(id -gn "${SUDO_USER}")" "${f}"
        fi
    done
fi

echo "Done: ${OUTPUT}.gz — flash with Raspberry Pi Imager or ./flash-sd-card.sh."
echo "The filesystem will expand to fill the card on first boot."
