#!/bin/bash

#==============================================================================
# Arch R - SD Card Image Builder
#==============================================================================
# Creates a flashable SD card image for Arch R.
#
# BOOT partition layout:
#   /KERNEL                      ← kernel Image
#   /boot.ini                    ← boot script (BSP reads directly, hwrev→DTB)
#   /dtbs/rk3326-*.dtb           ← ALL board DTBs (selected by boot.ini hwrev mapping)
#   /overlays/*.dtbo             ← all available panel overlays (no default — Flasher selects)
#
# Usage:
#   sudo ./build-image.sh --variant original   # Original R36S, OGA, OGS, RG351, etc.
#   sudo ./build-image.sh --variant clone      # K36 clones, RGB20S, RGB10X, etc.
#   sudo ./build-image.sh                      # defaults to original
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $1"; exit 1; }

#------------------------------------------------------------------------------
# Parse arguments
#------------------------------------------------------------------------------
VARIANT="original"

while [[ $# -gt 0 ]]; do
    case $1 in
        --variant)
            VARIANT="$2"
            shift 2
            ;;
        *)
            error "Unknown option: $1\nUsage: $0 --variant original|clone"
            ;;
    esac
done

if [ "$VARIANT" != "original" ] && [ "$VARIANT" != "clone" ]; then
    error "Invalid variant: $VARIANT (must be 'original' or 'clone')"
fi

#------------------------------------------------------------------------------
# Variant-specific configuration
#------------------------------------------------------------------------------
if [ "$VARIANT" = "original" ]; then
    IMAGE_SUFFIX="R36S"
    BOOT_INI="$SCRIPT_DIR/config/a_boot.ini"
else
    IMAGE_SUFFIX="R36S-clone"
    BOOT_INI="$SCRIPT_DIR/config/b_boot.ini"
fi

# U-Boot binaries (same BSP build for both variants)
UBOOT_BIN_DIR="$SCRIPT_DIR/bootloader/u-boot-rk3326/sd_fuse"

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
OUTPUT_DIR="$SCRIPT_DIR/output"
ROOTFS_DIR="$OUTPUT_DIR/rootfs"
BOOT_OUTPUT="$OUTPUT_DIR/boot"
PANELS_DIR="$OUTPUT_DIR/panels"
IMAGE_DIR="$OUTPUT_DIR/images"
IMAGE_NAME="ArchR-${IMAGE_SUFFIX}-$(date +%Y%m%d).img"

# Cleanup on exit
LOOP_DEV=""
cleanup_image() {
    echo "[IMAGE] Cleaning up mounts and loop devices..."
    umount -l "$OUTPUT_DIR/mnt_boot" 2>/dev/null || true
    umount -l "$OUTPUT_DIR/mnt_root" 2>/dev/null || true
    [ -n "$LOOP_DEV" ] && losetup -d "$LOOP_DEV" 2>/dev/null || true
    rmdir "$OUTPUT_DIR/mnt_root" "$OUTPUT_DIR/mnt_boot" 2>/dev/null || true
}
trap cleanup_image EXIT
IMAGE_FILE="$IMAGE_DIR/$IMAGE_NAME"

# Partition sizes (in MB)
BOOT_SIZE=128
ROOTFS_SIZE=6144
IMAGE_SIZE=$((BOOT_SIZE + ROOTFS_SIZE + 32))

log "=== Arch R Image Builder (variant: $VARIANT) ==="

#------------------------------------------------------------------------------
# Root check
#------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root"
fi

#------------------------------------------------------------------------------
# Step 1: Verify Prerequisites
#------------------------------------------------------------------------------
log ""
log "Step 1: Checking prerequisites..."

if [ ! -d "$ROOTFS_DIR" ]; then
    error "Rootfs not found at: $ROOTFS_DIR\nRun build-rootfs.sh first!"
fi

# Kernel
if [ ! -f "$BOOT_OUTPUT/KERNEL" ]; then
    error "Kernel not found at: $BOOT_OUTPUT/KERNEL\nRun build-kernel.sh first!"
fi
KERNEL_BYTES=$(stat -c%s "$BOOT_OUTPUT/KERNEL")
log "  KERNEL: $(($KERNEL_BYTES / 1024 / 1024))MB"

# Board DTBs
if [ ! -d "$BOOT_OUTPUT/dtbs" ]; then
    error "DTBs not found at: $BOOT_OUTPUT/dtbs/\nRun build-kernel.sh first!"
fi
DTB_COUNT=$(ls "$BOOT_OUTPUT/dtbs"/rk3326-*.dtb 2>/dev/null | wc -l)
log "  Board DTBs: $DTB_COUNT files"

# Kernel modules in rootfs
if [ ! -d "$ROOTFS_DIR/lib/modules" ] || [ -z "$(ls "$ROOTFS_DIR/lib/modules/" 2>/dev/null)" ]; then
    warn "Kernel modules not found in rootfs! Run build-rootfs.sh after build-kernel.sh."
else
    log "  Kernel modules: OK"
fi

# Panel overlays (generate if missing)
if [ ! -d "$PANELS_DIR" ] || [ -z "$(ls "$PANELS_DIR"/*.dtbo 2>/dev/null)" ]; then
    log "  Panel overlays not found — generating..."
    if [ -x "$SCRIPT_DIR/scripts/generate-panel-dtbos.sh" ]; then
        "$SCRIPT_DIR/scripts/generate-panel-dtbos.sh"
    else
        warn "Panel overlays not found and generate-panel-dtbos.sh not executable!"
    fi
fi

# U-Boot
if [ ! -d "$UBOOT_BIN_DIR" ] || [ ! -f "$UBOOT_BIN_DIR/idbloader.img" ]; then
    error "U-Boot binaries not found at: $UBOOT_BIN_DIR"
fi
log "  U-Boot: $UBOOT_BIN_DIR"

# Tools
for tool in parted mkfs.vfat mkfs.ext4 losetup; do
    if ! command -v $tool &> /dev/null; then
        error "Required tool not found: $tool"
    fi
done

log "  Prerequisites OK"

#------------------------------------------------------------------------------
# Step 2: Create Image File
#------------------------------------------------------------------------------
log ""
log "Step 2: Creating image file..."

mkdir -p "$IMAGE_DIR"
rm -f "$IMAGE_DIR"/ArchR-${IMAGE_SUFFIX}-*.img "$IMAGE_DIR"/ArchR-${IMAGE_SUFFIX}-*.img.xz

dd if=/dev/zero of="$IMAGE_FILE" bs=1M count=0 seek=$IMAGE_SIZE 2>/dev/null
log "  Created ${IMAGE_SIZE}MB image: $IMAGE_NAME"

#------------------------------------------------------------------------------
# Step 3: Install U-Boot Bootloader
#------------------------------------------------------------------------------
log ""
log "Step 3: Installing U-Boot bootloader..."

dd if="$UBOOT_BIN_DIR/idbloader.img" of="$IMAGE_FILE" bs=512 seek=64 conv=sync,noerror,notrunc 2>/dev/null
dd if="$UBOOT_BIN_DIR/uboot.img" of="$IMAGE_FILE" bs=512 seek=16384 conv=sync,noerror,notrunc 2>/dev/null
dd if="$UBOOT_BIN_DIR/trust.img" of="$IMAGE_FILE" bs=512 seek=24576 conv=sync,noerror,notrunc 2>/dev/null
log "  U-Boot installed"

#------------------------------------------------------------------------------
# Step 4: Create and Format Partitions
#------------------------------------------------------------------------------
log ""
log "Step 4: Creating partitions..."

parted -s "$IMAGE_FILE" mklabel msdos

BOOT_START=16
BOOT_END=$((BOOT_START + BOOT_SIZE))
ROOTFS_START=$BOOT_END
ROOTFS_END=$((ROOTFS_START + ROOTFS_SIZE))

parted -s "$IMAGE_FILE" mkpart primary fat32 ${BOOT_START}MiB ${BOOT_END}MiB
parted -s "$IMAGE_FILE" mkpart primary ext4 ${ROOTFS_START}MiB ${ROOTFS_END}MiB
parted -s "$IMAGE_FILE" set 1 boot on

LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")
BOOT_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"
sleep 1

mkfs.vfat -F 32 -n BOOT "$BOOT_PART"
mkfs.ext4 -L STORAGE -O ^metadata_csum "$ROOT_PART"

log "  Partitions: BOOT (${BOOT_SIZE}MB FAT32) + STORAGE (${ROOTFS_SIZE}MB ext4)"

#------------------------------------------------------------------------------
# Step 5: Mount and Copy Files
#------------------------------------------------------------------------------
log ""
log "Step 5: Copying files..."

MOUNT_ROOT="$OUTPUT_DIR/mnt_root"
MOUNT_BOOT="$OUTPUT_DIR/mnt_boot"

mkdir -p "$MOUNT_ROOT" "$MOUNT_BOOT"
mount "$ROOT_PART" "$MOUNT_ROOT"
mount "$BOOT_PART" "$MOUNT_BOOT"

# --- Rootfs (excluding /boot) ---
log "  Copying rootfs..."
rsync -aHxS --exclude='/boot' "$ROOTFS_DIR/" "$MOUNT_ROOT/"

# --- Variant marker ---
mkdir -p "$MOUNT_ROOT/etc/archr"
echo "$VARIANT" > "$MOUNT_ROOT/etc/archr/variant"

# --- First-boot flag ---
rm -f "$MOUNT_ROOT/var/lib/archr/.first-boot-done"

# --- BOOT partition: KERNEL ---
cp "$BOOT_OUTPUT/KERNEL" "$MOUNT_BOOT/KERNEL"
log "  KERNEL installed"

# --- BOOT partition: Board DTBs (ALL rk3326-*.dtb) ---
mkdir -p "$MOUNT_BOOT/dtbs"
cp "$BOOT_OUTPUT/dtbs"/rk3326-*.dtb "$MOUNT_BOOT/dtbs/"
dtb_count=$(ls "$MOUNT_BOOT/dtbs"/rk3326-*.dtb | wc -l)
log "  DTBs: $dtb_count board DTBs in /dtbs/"

# --- BOOT partition: Panel overlays ---
mkdir -p "$MOUNT_BOOT/overlays"
overlay_count=0

if [ -d "$PANELS_DIR" ]; then
    for dtbo in "$PANELS_DIR"/*.dtbo; do
        [ -f "$dtbo" ] || continue
        cp "$dtbo" "$MOUNT_BOOT/overlays/"
        overlay_count=$((overlay_count + 1))
    done

    log "  Panel overlays: $overlay_count shipped (no default — Flasher selects panel)"
else
    warn "No panel overlays found — display may not work without mipi-panel.dtbo!"
fi

# --- BOOT partition: boot.ini (BSP U-Boot reads directly) ---
cp "$BOOT_INI" "$MOUNT_BOOT/boot.ini"
log "  boot.ini installed"

# --- Initramfs is embedded in kernel (no separate file needed) ---

# --- Rootfs: fstab ---
cat > "$MOUNT_ROOT/etc/fstab" << 'FSTAB_EOF'
# Arch R fstab — optimized for fast boot
# fsck disabled (fsck.mode=skip in cmdline + pass=0 here)
LABEL=BOOT        /boot     vfat     defaults,noatime                       0      0
LABEL=STORAGE     /         ext4     defaults,noatime                       0      0
LABEL=ROMS        /roms     vfat     defaults,utf8,noatime,uid=1001,gid=1001,nofail,x-systemd.device-timeout=10s  0  0
tmpfs             /tmp      tmpfs    defaults,nosuid,nodev,size=128M        0      0
tmpfs             /var/log  tmpfs    defaults,nosuid,nodev,noexec,size=16M  0      0
FSTAB_EOF

log "  fstab installed"

#------------------------------------------------------------------------------
# Step 6: Sync and Unmount
#------------------------------------------------------------------------------
log ""
log "Step 6: Syncing filesystem..."
sync
log "  Sync complete"

#------------------------------------------------------------------------------
# Step 7: Compress
#------------------------------------------------------------------------------
log ""
log "Step 7: Compressing image..."

if command -v xz &> /dev/null; then
    rm -f "${IMAGE_FILE}.xz"
    xz -9 -k "$IMAGE_FILE"
    COMPRESSED="${IMAGE_FILE}.xz"
    COMPRESSED_SIZE=$(du -h "$COMPRESSED" | cut -f1)
    log "  Compressed: $COMPRESSED ($COMPRESSED_SIZE)"
fi

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
log ""
log "=== Image Build Complete ($VARIANT) ==="
log ""

IMAGE_SIZE_ACTUAL=$(du -h "$IMAGE_FILE" | cut -f1)
log "Image:    $IMAGE_FILE ($IMAGE_SIZE_ACTUAL)"
log "Variant:  $VARIANT"
log "DTBs:     $dtb_count board DTBs"
log "Overlays: $overlay_count panel overlays"
log ""
log "To flash to SD card:"
log "  sudo dd if=$IMAGE_FILE of=/dev/sdX bs=4M status=progress"
log ""
log "Arch R image ready!"
