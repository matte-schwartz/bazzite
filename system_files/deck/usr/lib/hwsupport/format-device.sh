#!/bin/bash

set -e
exec &> >(tee | logger -t steamos-format-device)

RUN_VALIDATION=1
EXTENDED_OPTIONS="nodiscard"
# default owner for the new filesystem
OWNER="1000:1000"

OPTS=$(getopt -l force,skip-validation,full,quick,owner:,device: -n format-device.sh -- "" "$@")

eval set -- "$OPTS"

while true; do
    case "$1" in
        --force) RUN_VALIDATION=0; shift ;;
        --skip-validation) RUN_VALIDATION=0; shift ;;
        --full) EXTENDED_OPTIONS="discard"; shift ;;
        --quick) EXTENDED_OPTIONS="nodiscard"; shift ;;
        --owner) OWNER="$2"; shift 2;;
        --device) STORAGE_DEVICE="$2"; shift 2 ;;
        --) shift; break ;;
    esac
done

if [[ "$#" -gt 0 ]]; then
    echo "Unknown option $1"; exit 22
fi

EXTENDED_OPTIONS="$EXTENDED_OPTIONS,root_owner=$OWNER"

STORAGE_PARTITION="${STORAGE_DEVICE}p1"

if [[ ! -e "$STORAGE_DEVICE" ]]; then
    exit 19 #ENODEV
fi

STORAGE_PARTBASE="${STORAGE_PARTITION#/dev/}"

systemctl stop steamos-automount@"$STORAGE_PARTBASE".service

# If any partitions on the device are mounted, unmount them before continuing
# to prevent problems later
for m in $(lsblk -n "$STORAGE_DEVICE" -o MOUNTPOINTS| awk NF | sort -u); do
    if ! umount "$m"; then
        echo "Failed to unmount filesystem: $m"
        exit 32 # EPIPE
    fi
done

# Test the sdcard
# Some fake cards advertise a larger size than their actual capacity,
# which can result in data loss or other unexpected behaviour. It is
# best to try to detect these issues as early as possible.
if [[ "$RUN_VALIDATION" != "0" ]]; then
    echo "stage=testing"
fi

# Format as EXT4 with casefolding for proton compatibility
echo "stage=formatting"
sync
parted --script "$STORAGE_DEVICE" mklabel gpt mkpart primary 0% 100%
sync
mkfs.btrfs -f -K "$STORAGE_PARTITION"
MOUNT_DIR="/var/run/sdcard-mount"
mkdir -p "$MOUNT_DIR"
mount -o "rw,noatime,lazytime,compress-force=zstd,space_cache=v2,autodefrag,ssd_spread" "$STORAGE_PARTITION" "$MOUNT_DIR"
btrfs subvolume create "$MOUNT_DIR/@"
btrfs subvolume set-default "$MOUNT_DIR/@"
umount -l "$MOUNT_DIR"
rmdir "$MOUNT_DIR"
sync
udevadm settle

# trigger the mount service
if ! systemctl start steamos-automount@"$STORAGE_PARTBASE".service; then
    echo "Failed to start mount service"
    journalctl --no-pager --boot=0 -u steamos-automount@"$STORAGE_PARTBASE".service
    exit 5
fi

exit 0
