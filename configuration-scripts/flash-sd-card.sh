#!/usr/bin/env bash
#
# flash-sd-card.sh: write a Raspberry Pi image (raw, .gz, or .xz) to an SD card.
#
# Usage: sudo ./flash-sd-card.sh <image[.gz|.xz]> <device>
#   e.g. sudo ./flash-sd-card.sh rpi-shrunk.img.gz /dev/sdb
set -euo pipefail

usage() {
    echo "Usage: sudo $0 <image[.gz|.xz]> <device>" >&2
    echo "  e.g. sudo $0 rpi-shrunk.img.gz /dev/sdb" >&2
    exit 1
}

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: this script must be run as root (use sudo)." >&2
    exit 1
fi

[ $# -eq 2 ] || usage
IMAGE="$1"
DEVICE="$2"

[ -f "${IMAGE}" ] || { echo "Error: ${IMAGE} is not a file." >&2; exit 1; }
[ -b "${DEVICE}" ] || { echo "Error: ${DEVICE} is not a block device." >&2; exit 1; }

# Refuse to flash the disk hosting the running root filesystem
ROOT_DISK="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)"
if [ -n "${ROOT_DISK}" ] && [ "/dev/${ROOT_DISK}" = "${DEVICE}" ]; then
    echo "Error: ${DEVICE} hosts the running root filesystem. Aborting." >&2
    exit 1
fi

echo "Target device:"
lsblk -o NAME,SIZE,MODEL,MOUNTPOINT "${DEVICE}"
read -r -p "ALL DATA on ${DEVICE} will be destroyed. Continue? [y/N] " REPLY
[ "${REPLY}" = "y" ] || [ "${REPLY}" = "Y" ] || { echo "Aborted."; exit 1; }

# Unmount anything mounted from the card
for mp in $(lsblk -no MOUNTPOINT "${DEVICE}" | grep -v '^$' || true); do
    echo "Unmounting ${mp}"
    umount "${mp}"
done

case "${IMAGE}" in
    *.gz) DECOMPRESS="zcat" ;;
    *.xz) DECOMPRESS="xzcat" ;;
    *)    DECOMPRESS="cat" ;;
esac

echo "Writing ${IMAGE} to ${DEVICE}"
${DECOMPRESS} "${IMAGE}" | dd of="${DEVICE}" bs=4M status=progress conv=fsync
sync

echo "Done. Insert the card into the Pi; the filesystem expands on first boot."
