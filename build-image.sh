#!/bin/bash

#==============================================================================
# Arch R - SD Card Image Builder
#==============================================================================
# Creates a flashable SD card image for R36S
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
# Configuration
#------------------------------------------------------------------------------

OUTPUT_DIR="$SCRIPT_DIR/output"
ROOTFS_DIR="$OUTPUT_DIR/rootfs"
IMAGE_DIR="$OUTPUT_DIR/images"
IMAGE_NAME="ArchR-R36S-$(date +%Y%m%d).img"

# CRITICAL: Always clean up loop devices and mounts on exit (success OR failure).
# Without this trap, a build error leaves loop devices and mounts dangling —
# loop device holds the image file, mounts prevent cleanup.
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
BOOT_SIZE=128        # Boot partition (FAT32)
ROOTFS_SIZE=6144     # Root filesystem (ext4) - 6GB for full Arch + gaming stack
# ROMS partition will use remaining space on actual SD card

# Total image size
IMAGE_SIZE=$((BOOT_SIZE + ROOTFS_SIZE + 32))  # +32MB for partition table

log "=== Arch R Image Builder ==="

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
    error "Rootfs not found at: $ROOTFS_DIR"
    error "Run build-rootfs.sh first!"
fi

if [ ! -f "$ROOTFS_DIR/boot/Image" ]; then
    warn "Kernel Image not found in rootfs. Make sure kernel is installed."
else
    # Validate kernel Image size (kernel 6.6 trimmed is ~18MB, stale 4.4 was ~5MB)
    IMAGE_BYTES=$(stat -c%s "$ROOTFS_DIR/boot/Image")
    if [ "$IMAGE_BYTES" -lt 10000000 ]; then
        warn "Kernel Image is only $(($IMAGE_BYTES / 1024 / 1024))MB — expected ~18MB for kernel 6.6!"
        warn "This may be a stale kernel 4.4 build. Run build-kernel.sh first."
        error "Aborting: kernel Image too small (likely wrong version)"
    fi
    log "  Kernel Image: $(($IMAGE_BYTES / 1024 / 1024))MB (OK)"
fi

# Check required tools
for tool in parted mkfs.vfat mkfs.ext4 losetup; do
    if ! command -v $tool &> /dev/null; then
        error "Required tool not found: $tool"
    fi
done

log "  ✓ Prerequisites OK"

#------------------------------------------------------------------------------
# Step 2: Create Image File
#------------------------------------------------------------------------------
log ""
log "Step 2: Creating image file..."

mkdir -p "$IMAGE_DIR"

# Remove old images (current date and any previous builds)
rm -f "$IMAGE_DIR"/ArchR-R36S-*.img "$IMAGE_DIR"/ArchR-R36S-*.img.xz

# Create sparse image file
dd if=/dev/zero of="$IMAGE_FILE" bs=1M count=0 seek=$IMAGE_SIZE 2>/dev/null
log "  ✓ Created ${IMAGE_SIZE}MB image"

#------------------------------------------------------------------------------
# Step 2.5: Install U-Boot Bootloader
#------------------------------------------------------------------------------
log ""
log "Step 2.5: Installing U-Boot bootloader..."

# Search for U-Boot binaries — prefer R36S-u-boot-builder (known working)
UBOOT_DIR=""
for dir in "$SCRIPT_DIR/bootloader/u-boot-r36s-working" \
           "$OUTPUT_DIR/bootloader" \
           "$SCRIPT_DIR/bootloader/u-boot-rk3326/sd_fuse" \
           "$SCRIPT_DIR/bootloader/sd_fuse"; do
    if [ -f "$dir/idbloader.img" ] && [ -f "$dir/uboot.img" ] && [ -f "$dir/trust.img" ]; then
        UBOOT_DIR="$dir"
        break
    fi
done

if [ -n "$UBOOT_DIR" ]; then
    dd if="$UBOOT_DIR/idbloader.img" of="$IMAGE_FILE" bs=512 seek=64 conv=sync,noerror,notrunc 2>/dev/null
    dd if="$UBOOT_DIR/uboot.img" of="$IMAGE_FILE" bs=512 seek=16384 conv=sync,noerror,notrunc 2>/dev/null
    dd if="$UBOOT_DIR/trust.img" of="$IMAGE_FILE" bs=512 seek=24576 conv=sync,noerror,notrunc 2>/dev/null
    log "  ✓ U-Boot installed from $UBOOT_DIR"
else
    warn "U-Boot files not found!"
    warn "Run build-uboot.sh first for bootable image!"
fi

#------------------------------------------------------------------------------
# Step 3: Create Partitions
#------------------------------------------------------------------------------
log ""
log "Step 3: Creating partitions..."

# Create partition table
parted -s "$IMAGE_FILE" mklabel msdos

# Calculate partition boundaries
BOOT_START=16  # Start at 16MB for U-Boot space
BOOT_END=$((BOOT_START + BOOT_SIZE))
ROOTFS_START=$BOOT_END
ROOTFS_END=$((ROOTFS_START + ROOTFS_SIZE))

# Create partitions
parted -s "$IMAGE_FILE" mkpart primary fat32 ${BOOT_START}MiB ${BOOT_END}MiB
parted -s "$IMAGE_FILE" mkpart primary ext4 ${ROOTFS_START}MiB ${ROOTFS_END}MiB
parted -s "$IMAGE_FILE" set 1 boot on

log "  ✓ Partitions created"

#------------------------------------------------------------------------------
# Step 4: Setup Loop Devices
#------------------------------------------------------------------------------
log ""
log "Step 4: Setting up loop devices..."

LOOP_DEV=$(losetup -fP --show "$IMAGE_FILE")
BOOT_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p2"

# Wait for partitions to appear
sleep 1

log "  Loop device: $LOOP_DEV"
log "  Boot: $BOOT_PART"
log "  Root: $ROOT_PART"

#------------------------------------------------------------------------------
# Step 5: Format Partitions
#------------------------------------------------------------------------------
log ""
log "Step 5: Formatting partitions..."

mkfs.vfat -F 32 -n BOOT "$BOOT_PART"
mkfs.ext4 -L ROOTFS -O ^metadata_csum "$ROOT_PART"

log "  ✓ Partitions formatted"

#------------------------------------------------------------------------------
# Step 6: Mount and Copy Files
#------------------------------------------------------------------------------
log ""
log "Step 6: Copying files..."

MOUNT_ROOT="$OUTPUT_DIR/mnt_root"
MOUNT_BOOT="$OUTPUT_DIR/mnt_boot"

mkdir -p "$MOUNT_ROOT" "$MOUNT_BOOT"
mount "$ROOT_PART" "$MOUNT_ROOT"
mount "$BOOT_PART" "$MOUNT_BOOT"

# Copy rootfs (excluding /boot)
log "  Copying rootfs..."
rsync -aHxS --exclude='/boot' "$ROOTFS_DIR/" "$MOUNT_ROOT/"

# Copy boot files
log "  Copying boot files..."
if [ -d "$ROOTFS_DIR/boot" ]; then
    cp "$ROOTFS_DIR/boot/Image" "$MOUNT_BOOT/"
    # Only copy the R36S DTB — extra DTBs (r35s, rg351mp-linux) are not needed
    cp "$ROOTFS_DIR/boot/rk3326-gameconsole-r36s.dtb" "$MOUNT_BOOT/" 2>/dev/null || true
fi

# Copy U-Boot DTB (required for U-Boot display initialization)
# Default: Panel 4 V22 — most common R36S panel
UBOOT_DTB="$SCRIPT_DIR/kernel/dts/R36S-DTB/R36S/Panel 4 - V22/rg351mp-kernel.dtb"
if [ ! -f "$UBOOT_DTB" ]; then
    # Fallback to Panel 0 if Panel 4 V22 not available
    UBOOT_DTB="$SCRIPT_DIR/kernel/dts/R36S-DTB/R36S/Panel 0/rg351mp-kernel.dtb"
fi
if [ -f "$UBOOT_DTB" ]; then
    cp "$UBOOT_DTB" "$MOUNT_BOOT/rg351mp-kernel.dtb"
    log "  ✓ U-Boot DTB installed ($(basename "$(dirname "$UBOOT_DTB")")/rg351mp-kernel.dtb)"
else
    warn "U-Boot DTB not found! U-Boot may not initialize display."
fi

# boot.ini (fallback — extlinux.conf is primary boot method)
if [ -f "$SCRIPT_DIR/config/boot.ini" ]; then
    cp "$SCRIPT_DIR/config/boot.ini" "$MOUNT_BOOT/boot.ini"
    log "  ✓ boot.ini installed (fallback boot method)"
else
    error "boot.ini not found at config/boot.ini!"
fi

# Panel DTBO overlays (ScreenFiles/)
PANELS_DIR="$OUTPUT_DIR/panels/ScreenFiles"
if [ -d "$PANELS_DIR" ]; then
    cp -r "$PANELS_DIR" "$MOUNT_BOOT/"
    panel_count=$(find "$MOUNT_BOOT/ScreenFiles" -name "*.dtbo" | wc -l)
    log "  ✓ Panel DTBOs installed (${panel_count} panels)"
else
    warn "Panel DTBOs not found! Run scripts/generate-panel-dtbos.sh first"
fi

# U-Boot logo (BMP format — U-Boot displays logo.bmp natively during boot)
log "  Converting boot logo..."
LOGO_SRC="$SCRIPT_DIR/ArchR.png"

if [ -f "$LOGO_SRC" ]; then
    if command -v convert &>/dev/null; then
        convert "$LOGO_SRC" -resize 640x480! -alpha remove -type TrueColor BMP3:"$MOUNT_BOOT/logo.bmp"
        log "  ✓ logo.bmp created ($(du -h "$MOUNT_BOOT/logo.bmp" | cut -f1))"
    elif command -v ffmpeg &>/dev/null; then
        ffmpeg -y -loglevel error -i "$LOGO_SRC" -vf "scale=640:480" -pix_fmt bgr24 "$MOUNT_BOOT/logo.bmp"
        log "  ✓ logo.bmp created via ffmpeg"
    else
        warn "Neither imagemagick nor ffmpeg found — logo.bmp skipped"
        warn "Install with: sudo apt install imagemagick"
    fi
else
    warn "ArchR.png not found — logo.bmp skipped (U-Boot will show no logo)"
fi

# Create extlinux.conf (primary boot method — U-Boot loads this first)
mkdir -p "$MOUNT_BOOT/extlinux"
cat > "$MOUNT_BOOT/extlinux/extlinux.conf" << 'EXTLINUX_EOF'
LABEL ArchR
  LINUX /Image
  FDT /rk3326-gameconsole-r36s.dtb
  APPEND root=/dev/mmcblk1p2 rootwait rw console=ttyFIQ0 loglevel=0 quiet vt.global_cursor_default=0 consoleblank=0 printk.devkmsg=off fsck.mode=skip
EXTLINUX_EOF
log "  ✓ extlinux.conf installed (primary boot method)"

# Create fstab (overrides rootfs fstab with correct entries)
cat > "$MOUNT_ROOT/etc/fstab" << 'FSTAB_EOF'
# Arch R fstab — optimized for fast boot
# fsck disabled (fsck.mode=skip in cmdline + pass=0 here)
LABEL=BOOT        /boot     vfat     defaults,noatime                       0      0
LABEL=ROOTFS      /         ext4     defaults,noatime                       0      0
LABEL=ROMS        /roms     vfat     defaults,utf8,noatime,uid=1001,gid=1001,nofail,x-systemd.device-timeout=10s  0  0
tmpfs             /tmp      tmpfs    defaults,nosuid,nodev,size=128M        0      0
tmpfs             /var/log  tmpfs    defaults,nosuid,nodev,noexec,size=16M  0      0
FSTAB_EOF
log "  ✓ Files copied"

#------------------------------------------------------------------------------
# Step 7: Cleanup
#------------------------------------------------------------------------------
log ""
log "Step 7: Syncing filesystem..."

sync

# Mounts and loop device cleaned up by EXIT trap (cleanup_image)
log "  ✓ Sync complete"

#------------------------------------------------------------------------------
# Step 8: Compress (optional)
#------------------------------------------------------------------------------
log ""
log "Step 8: Compressing image..."

if command -v xz &> /dev/null; then
    rm -f "${IMAGE_FILE}.xz"
    xz -9 -k "$IMAGE_FILE"
    COMPRESSED="${IMAGE_FILE}.xz"
    COMPRESSED_SIZE=$(du -h "$COMPRESSED" | cut -f1)
    log "  ✓ Compressed: $COMPRESSED ($COMPRESSED_SIZE)"
fi

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
log ""
log "=== Image Build Complete ==="
log ""

IMAGE_SIZE_ACTUAL=$(du -h "$IMAGE_FILE" | cut -f1)
log "Image: $IMAGE_FILE"
log "Size: $IMAGE_SIZE_ACTUAL"
log ""
log "To flash to SD card:"
log "  sudo dd if=$IMAGE_FILE of=/dev/sdX bs=4M status=progress"
log ""
log "✓ Arch R image ready!"
