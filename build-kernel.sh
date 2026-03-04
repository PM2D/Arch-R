#!/bin/bash

#==============================================================================
# Arch R - Kernel Build Script
#==============================================================================
# Builds mainline Linux 6.12.x with Arch R patches for RK3326 R36S
# Applies: device patches, 6.12-LTS patches, mainline patches
# Builds: kernel Image + ALL DTBs + modules + out-of-tree joypad driver
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

KERNEL_VERSION="6.12.61"
KERNEL_URL="https://www.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"

# Paths
KERNEL_SRC="$SCRIPT_DIR/kernel/src/linux-${KERNEL_VERSION}"
PATCHES_DIR="$SCRIPT_DIR/patches/linux"
DTS_DIR="$SCRIPT_DIR/kernel/dts/archr"
JOYPAD_DIR="$SCRIPT_DIR/kernel/drivers/archr-joypad"
CONFIG_BASE="$SCRIPT_DIR/config/linux-archr-base.config"

# Output
OUTPUT_DIR="$SCRIPT_DIR/output"
BOOT_DIR="$OUTPUT_DIR/boot"
MODULES_DIR="$OUTPUT_DIR/modules"

# Cross-compilation
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# Build parallelism
JOBS=$(nproc)

# DTS target directory inside kernel
KERNEL_DTS_DIR="$KERNEL_SRC/arch/arm64/boot/dts/rockchip"

log "================================================================"
log "  Arch R - Kernel $KERNEL_VERSION (Mainline + Arch R patches)"
log "================================================================"
log ""
log "Source:   $KERNEL_SRC"
log "Patches:  $PATCHES_DIR"
log "DTS:      $DTS_DIR"
log "Config:   $CONFIG_BASE"
log "Jobs:     $JOBS"

#------------------------------------------------------------------------------
# Step 1: Verify Kernel Source
#------------------------------------------------------------------------------
log ""
log "Step 1: Checking kernel source..."

if [ ! -d "$KERNEL_SRC" ]; then
    TARBALL="$SCRIPT_DIR/kernel/src/linux-${KERNEL_VERSION}.tar.xz"
    if [ ! -f "$TARBALL" ]; then
        log "  Downloading kernel $KERNEL_VERSION..."
        wget -c "$KERNEL_URL" -O "$TARBALL"
    fi
    log "  Extracting..."
    tar -xf "$TARBALL" -C "$SCRIPT_DIR/kernel/src/"
fi

if [ ! -f "$KERNEL_SRC/Makefile" ]; then
    error "Kernel source not found at: $KERNEL_SRC"
fi

ACTUAL_VERSION=$(make -C "$KERNEL_SRC" -s kernelversion 2>/dev/null)
log "  Kernel: $ACTUAL_VERSION"

#------------------------------------------------------------------------------
# Step 2: Apply Patches (idempotent — skip already applied)
#------------------------------------------------------------------------------
log ""
log "Step 2: Applying patches..."

PATCH_MARKER="$KERNEL_SRC/.archr-patches-applied"

if [ -f "$PATCH_MARKER" ]; then
    log "  Patches already applied (marker exists). Skipping."
else
    PATCH_COUNT=0

    # Order: mainline first (GPIO API, input-polldev), then 6.12-LTS, then device-specific
    for PATCH_SUBDIR in mainline 6.12-lts device; do
        PDIR="$PATCHES_DIR/$PATCH_SUBDIR"
        if [ ! -d "$PDIR" ]; then
            warn "  Patch dir not found: $PDIR"
            continue
        fi
        for PATCH in $(ls "$PDIR"/*.patch 2>/dev/null | sort); do
            PNAME=$(basename "$PATCH")
            log "  Applying [$PATCH_SUBDIR] $PNAME..."
            if ! patch -d "$KERNEL_SRC" -p1 --forward --batch < "$PATCH" 2>&1 | tail -3; then
                warn "  Patch may have failed or already applied: $PNAME"
            fi
            PATCH_COUNT=$((PATCH_COUNT + 1))
        done
    done

    touch "$PATCH_MARKER"
    log "  Applied $PATCH_COUNT patches"
fi

#------------------------------------------------------------------------------
# Step 3: Copy DTS files
#------------------------------------------------------------------------------
log ""
log "Step 3: Copying DTS files..."

if [ ! -d "$DTS_DIR" ]; then
    error "DTS directory not found: $DTS_DIR"
fi

DTS_COUNT=0
for DTS_FILE in "$DTS_DIR"/*.dts "$DTS_DIR"/*.dtsi; do
    [ -f "$DTS_FILE" ] || continue
    DEST="$KERNEL_DTS_DIR/$(basename "$DTS_FILE")"
    cp "$DTS_FILE" "$DEST"
    DTS_COUNT=$((DTS_COUNT + 1))
done

# Add DTS entries to Makefile (for each .dts, ensure dtb- line exists)
ROCKCHIP_MAKEFILE="$KERNEL_DTS_DIR/Makefile"
for DTS_FILE in "$DTS_DIR"/*.dts; do
    [ -f "$DTS_FILE" ] || continue
    DTB_NAME=$(basename "$DTS_FILE" .dts)
    if ! grep -q "${DTB_NAME}.dtb" "$ROCKCHIP_MAKEFILE"; then
        # Add before the first empty line or at the end of the dtb list
        echo "dtb-\$(CONFIG_ARCH_ROCKCHIP) += ${DTB_NAME}.dtb" >> "$ROCKCHIP_MAKEFILE"
        log "  Added to Makefile: ${DTB_NAME}.dtb"
    fi
done

log "  Copied $DTS_COUNT DTS files"

#------------------------------------------------------------------------------
# Step 4: Configure Kernel
#------------------------------------------------------------------------------
log ""
log "Step 4: Configuring kernel..."

if [ ! -f "$CONFIG_BASE" ]; then
    error "Config base not found: $CONFIG_BASE"
fi

# Copy Arch R base config
cp "$CONFIG_BASE" "$KERNEL_SRC/.config"

# Replace placeholder for initramfs
INITRAMFS_DIR="$OUTPUT_DIR/initramfs"
if [ -d "$INITRAMFS_DIR" ] && [ -x "$INITRAMFS_DIR/init" ]; then
    log "  Embedding initramfs from: $INITRAMFS_DIR"
    sed -i "s|@INITRAMFS_SOURCE@|${INITRAMFS_DIR}|" "$KERNEL_SRC/.config"
else
    warn "  Initramfs not found at $INITRAMFS_DIR"
    warn "  Run build-initramfs.sh first! Disabling embedded initramfs."
    sed -i 's|CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE=""|' "$KERNEL_SRC/.config"
fi

# Finalize config
make -C "$KERNEL_SRC" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE olddefconfig

# Verify critical settings
log "  Verifying config..."
check_config() {
    local key="$1" expected="$2" desc="$3"
    local val=$(grep "^${key}=" "$KERNEL_SRC/.config" 2>/dev/null | head -1)
    if [ -z "$val" ]; then
        val=$(grep "^# ${key} is not set" "$KERNEL_SRC/.config" 2>/dev/null | head -1)
    fi
    if echo "$val" | grep -q "$expected"; then
        log "    $desc: OK"
    else
        warn "    $desc: UNEXPECTED ($val)"
    fi
}

check_config "CONFIG_DRM_PANFROST" "=m" "Panfrost GPU"
check_config "CONFIG_DRM_PANEL_SITRONIX_ST7703" "=y" "ST7703 panel"
check_config "CONFIG_FRAMEBUFFER_CONSOLE" "=y" "fbcon"
check_config "CONFIG_FRAMEBUFFER_CONSOLE_DEFERRED_TAKEOVER" "is not set" "No deferred takeover"
check_config "CONFIG_EXT4_FS" "=y" "ext4"
check_config "CONFIG_DEVTMPFS" "=y" "devtmpfs"

log "  Kernel configured"

#------------------------------------------------------------------------------
# Step 5: Build Kernel Image
#------------------------------------------------------------------------------
log ""
log "Step 5: Building kernel Image..."

make -C "$KERNEL_SRC" -j$JOBS ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE Image 2>&1 | tail -5

if [ ! -f "$KERNEL_SRC/arch/arm64/boot/Image" ]; then
    error "Kernel Image build failed!"
fi

IMAGE_SIZE=$(du -h "$KERNEL_SRC/arch/arm64/boot/Image" | cut -f1)
log "  Kernel Image built ($IMAGE_SIZE)"

#------------------------------------------------------------------------------
# Step 6: Build ALL Device Trees
#------------------------------------------------------------------------------
log ""
log "Step 6: Building Device Trees..."

# Build dtbs target (compiles all DTBs referenced in Makefile)
make -C "$KERNEL_SRC" -j$JOBS ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE DTC_FLAGS=-@ dtbs 2>&1 | tail -10

# Verify R36S DTB was built
if [ ! -f "$KERNEL_DTS_DIR/rk3326-gameconsole-r36s.dtb" ]; then
    error "R36S DTB not built!"
fi

DTB_COUNT=$(find "$KERNEL_DTS_DIR" -name "rk3326-*.dtb" | wc -l)
log "  Built $DTB_COUNT RK3326 DTBs"

#------------------------------------------------------------------------------
# Step 7: Build Kernel Modules
#------------------------------------------------------------------------------
log ""
log "Step 7: Building kernel modules..."

make -C "$KERNEL_SRC" -j$JOBS ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE modules 2>&1 | tail -5

log "  Kernel modules built"

#------------------------------------------------------------------------------
# Step 8: Build Out-of-Tree Drivers
#------------------------------------------------------------------------------
log ""
log "Step 8: Building out-of-tree drivers..."

if [ -d "$JOYPAD_DIR" ] && [ -f "$JOYPAD_DIR/Makefile" ]; then
    log "  Building archr-joypad..."
    make -C "$KERNEL_SRC" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE \
        M="$JOYPAD_DIR" modules 2>&1 | tail -5
    if find "$JOYPAD_DIR" -name "*.ko" | grep -q .; then
        log "  archr-joypad: OK"
    else
        warn "  archr-joypad: no .ko files produced"
    fi
else
    warn "  Joypad driver not found at: $JOYPAD_DIR"
fi

#------------------------------------------------------------------------------
# Step 9: Install to Output Directory
#------------------------------------------------------------------------------
log ""
log "Step 9: Installing artifacts..."

mkdir -p "$BOOT_DIR"
mkdir -p "$MODULES_DIR"

# Copy kernel image as KERNEL (Arch R naming convention)
cp "$KERNEL_SRC/arch/arm64/boot/Image" "$BOOT_DIR/KERNEL"
log "  Copied: KERNEL"

# Copy ALL RK3326 DTBs to dtbs/ subdirectory
mkdir -p "$BOOT_DIR/dtbs"
for DTB in "$KERNEL_DTS_DIR"/rk3326-*.dtb; do
    [ -f "$DTB" ] || continue
    cp "$DTB" "$BOOT_DIR/dtbs/"
done
log "  Copied: $(ls "$BOOT_DIR/dtbs"/rk3326-*.dtb 2>/dev/null | wc -l) DTBs to dtbs/"

# Install kernel modules
set -o pipefail
make -C "$KERNEL_SRC" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE \
    INSTALL_MOD_PATH="$MODULES_DIR" \
    modules_install 2>&1 | tail -5
set +o pipefail

# Install joypad driver module
if find "$JOYPAD_DIR" -name "*.ko" | grep -q .; then
    KREL=$(cat "$KERNEL_SRC/include/config/kernel.release" 2>/dev/null)
    JOYPAD_DEST="$MODULES_DIR/lib/modules/$KREL/extra/archr-joypad"
    mkdir -p "$JOYPAD_DEST"
    cp "$JOYPAD_DIR"/*.ko "$JOYPAD_DEST/"
    log "  Installed joypad modules to: extra/archr-joypad/"
    # Regenerate modules.dep
    depmod -b "$MODULES_DIR" "$KREL"
fi

# Remove build/source symlinks (save space on target)
rm -f "$MODULES_DIR/lib/modules/"*/source 2>/dev/null || true
rm -f "$MODULES_DIR/lib/modules/"*/build 2>/dev/null || true

# Verify critical modules
KREL=$(cat "$KERNEL_SRC/include/config/kernel.release" 2>/dev/null)
for MOD in panfrost; do
    if find "$MODULES_DIR/lib/modules/$KREL" -name "${MOD}.ko*" 2>/dev/null | grep -q .; then
        log "  Module OK: $MOD"
    else
        warn "  Module MISSING: $MOD"
    fi
done
# Note: rockchipdrm is CONFIG_DRM_ROCKCHIP=y (built-in, not a module) — no .ko to check

log "  Modules installed"

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
log ""
log "================================================================"
log "  BUILD COMPLETE"
log "================================================================"
log ""

KERNEL_FULL=$(make -C "$KERNEL_SRC" -s kernelversion 2>/dev/null)
KERNEL_SIZE=$(du -h "$BOOT_DIR/KERNEL" | cut -f1)
MODULES_SIZE=$(du -sh "$MODULES_DIR" 2>/dev/null | cut -f1)
DTB_COUNT=$(ls "$BOOT_DIR/dtbs"/rk3326-*.dtb 2>/dev/null | wc -l)

log "Kernel:  $KERNEL_FULL (mainline + Arch R patches)"
log "KERNEL:  $BOOT_DIR/KERNEL ($KERNEL_SIZE)"
log "DTBs:    $DTB_COUNT files in $BOOT_DIR/dtbs/"
log "Modules: $MODULES_DIR/ ($MODULES_SIZE)"
log ""
log "Key DTBs:"
for DTB in rk3326-gameconsole-r36s rk3326-odroid-go2 rk3326-gameconsole-r33s; do
    if [ -f "$BOOT_DIR/dtbs/${DTB}.dtb" ]; then
        log "  ${DTB}.dtb ($(du -h "$BOOT_DIR/dtbs/${DTB}.dtb" | cut -f1))"
    fi
done
log ""
log "Ready for deployment to SD card!"
