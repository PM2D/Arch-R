#!/bin/bash

#==============================================================================
# Arch R - Build U-Boot BSP for RK3326
#==============================================================================
# Builds U-Boot v2017.09 BSP for all RK3326 handhelds.
# Same binary works for both original and clone boards — hwrev.c detects
# board variant via SARADC ch0, boot.ini overrides DTB as needed.
#
# Output: bootloader/u-boot-rk3326/sd_fuse/
#   idbloader.img  — DDR init + miniloader
#   uboot.img      — U-Boot proper
#   trust.img      — ARM Trusted Firmware (BL31 + BL32)
#
# Usage:
#   ./build-uboot.sh           # build for SD card
#   ./build-uboot.sh --clean   # clean build artifacts first
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UBOOT_DIR="$SCRIPT_DIR/bootloader/u-boot-rk3326"
RKBIN_DIR="$SCRIPT_DIR/bootloader/rkbin"
OUTPUT_DIR="$UBOOT_DIR/sd_fuse"

# Firmware versions (from rkbin)
DDR_BIN="$RKBIN_DIR/bin/rk33/rk3326_ddr_333MHz_v2.11.bin"
MINILOADER_BIN="$RKBIN_DIR/bin/rk33/rk3326_miniloader_v1.40.bin"
BL31_ELF="$RKBIN_DIR/bin/rk33/rk3326_bl31_v1.34.elf"
BL32_BIN="$RKBIN_DIR/bin/rk33/rk3326_bl32_v2.19.bin"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[U-BOOT]${NC} $1"; }
warn() { echo -e "${YELLOW}[U-BOOT] WARNING:${NC} $1"; }
error() { echo -e "${RED}[U-BOOT] ERROR:${NC} $1"; exit 1; }

#------------------------------------------------------------------------------
# Parse arguments
#------------------------------------------------------------------------------
CLEAN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --clean) CLEAN=true; shift ;;
        *) error "Unknown option: $1\nUsage: $0 [--clean]" ;;
    esac
done

#------------------------------------------------------------------------------
# Prerequisites
#------------------------------------------------------------------------------
log "=== Arch R U-Boot Builder ==="

if ! command -v aarch64-linux-gnu-gcc &>/dev/null; then
    error "Cross-compiler not found. Install with: sudo apt install gcc-aarch64-linux-gnu"
fi

if [ ! -d "$UBOOT_DIR" ]; then
    error "U-Boot source not found at: $UBOOT_DIR"
fi

if [ ! -f "$DDR_BIN" ]; then
    error "rkbin firmware not found at: $RKBIN_DIR\nExpected: $DDR_BIN"
fi

GCC_VER=$(aarch64-linux-gnu-gcc -dumpversion)
log "Compiler: aarch64-linux-gnu-gcc $GCC_VER"

#------------------------------------------------------------------------------
# Clean (optional)
#------------------------------------------------------------------------------
if [ "$CLEAN" = true ]; then
    log "Cleaning previous build..."
    make -C "$UBOOT_DIR" distclean 2>/dev/null || true
    rm -rf "$OUTPUT_DIR"
fi

#------------------------------------------------------------------------------
# Build U-Boot
#------------------------------------------------------------------------------
log ""
log "Step 1: Configuring (odroidgoa_defconfig)..."

cd "$UBOOT_DIR"

# GCC 13+ needs these warnings suppressed for 2017.09 codebase
export KCFLAGS="-Wno-error=array-bounds -Wno-error=enum-int-mismatch -Wno-error=implicit-function-declaration -Wno-error=format-overflow"

make odroidgoa_defconfig 2>&1 | tail -3

log "Step 2: Building U-Boot..."
NCPUS=$(nproc 2>/dev/null || echo 4)
make CROSS_COMPILE=aarch64-linux-gnu- all --jobs=$NCPUS 2>&1 | tail -5

if [ ! -f "u-boot.bin" ]; then
    error "Build failed — u-boot.bin not found"
fi

log "  u-boot.bin built OK"

#------------------------------------------------------------------------------
# Pack images
#------------------------------------------------------------------------------
log ""
log "Step 3: Packing images..."

mkdir -p "$OUTPUT_DIR"

# idbloader.img = DDR init + miniloader
"$UBOOT_DIR/tools/mkimage" -n px30 -T rksd -d "$DDR_BIN" "$OUTPUT_DIR/idbloader.img"
cat "$MINILOADER_BIN" >> "$OUTPUT_DIR/idbloader.img"
log "  idbloader.img (DDR v2.11 + miniloader v1.40)"

# uboot.img = packed U-Boot binary
UBOOT_LOAD_ADDR=$(grep -r "CONFIG_SYS_TEXT_BASE" include/autoconf.mk 2>/dev/null | cut -d= -f2 || echo "0x00200000")
"$RKBIN_DIR/tools/loaderimage" --pack --uboot u-boot.bin "$OUTPUT_DIR/uboot.img" "$UBOOT_LOAD_ADDR" 2>&1 | tail -1
log "  uboot.img (load addr: $UBOOT_LOAD_ADDR)"

# trust.img = BL31 + BL32
cat > /tmp/archr-trust.ini << TRUST_EOF
[VERSION]
MAJOR=1
MINOR=0
[BL30_OPTION]
SEC=0
[BL31_OPTION]
SEC=1
PATH=$BL31_ELF
ADDR=0x00010000
[BL32_OPTION]
SEC=1
PATH=$BL32_BIN
ADDR=0x08400000
[BL33_OPTION]
SEC=0
[OUTPUT]
PATH=$OUTPUT_DIR/trust.img
TRUST_EOF

"$RKBIN_DIR/tools/trust_merger" --rsa 3 /tmp/archr-trust.ini 2>&1 | tail -1
rm -f /tmp/archr-trust.ini
log "  trust.img (BL31 v1.34 + BL32 v2.19)"

#------------------------------------------------------------------------------
# Verify
#------------------------------------------------------------------------------
log ""
log "Step 4: Verifying..."

for img in idbloader.img uboot.img trust.img; do
    if [ ! -f "$OUTPUT_DIR/$img" ]; then
        error "Missing: $OUTPUT_DIR/$img"
    fi
    SIZE=$(du -h "$OUTPUT_DIR/$img" | cut -f1)
    log "  $img ($SIZE)"
done

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
log ""
log "=== U-Boot Build Complete ==="
log ""
log "Output: $OUTPUT_DIR/"
log "  idbloader.img — DDR v2.11 + miniloader v1.40"
log "  uboot.img     — U-Boot v2017.09 BSP"
log "  trust.img     — BL31 v1.34 + BL32 v2.19"
log ""
log "Same binary for both original and clone images."
log "Board detection: hwrev.c (SARADC ch0)"
log "DTB selection: boot.ini (variant A or B)"
