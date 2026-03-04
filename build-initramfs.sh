#!/bin/bash

#==============================================================================
# Arch R - Initramfs Builder
#==============================================================================
# Generates the initramfs directory for kernel embedding (CONFIG_INITRAMFS_SOURCE).
# Must run BEFORE build-kernel.sh — the kernel embeds this at compile time.
#
# Pipeline:
#   1. Compile archr-init.c + SVG splash library (static aarch64 binary)
#   2. Create initramfs directory tree (init + dev + proc + newroot)
#
# Logo is rendered from SVG paths at runtime (no ImageMagick needed).
#
# Output: $OUTPUT_DIR/initramfs/  (directory tree, not cpio)
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date '+%H:%M:%S')] WARNING:${NC} $1"; }
error() { echo -e "${RED}[$(date '+%H:%M:%S')] ERROR:${NC} $1"; exit 1; }

#------------------------------------------------------------------------------
# Configuration
#------------------------------------------------------------------------------
OUTPUT_DIR="$SCRIPT_DIR/output"
INITRAMFS_DIR="$OUTPUT_DIR/initramfs"
SPLASH_DIR="$SCRIPT_DIR/scripts/splash"

log "================================================================"
log "  Arch R - Initramfs Builder (SVG splash)"
log "================================================================"

#------------------------------------------------------------------------------
# Prerequisites
#------------------------------------------------------------------------------
if ! command -v aarch64-linux-gnu-gcc &>/dev/null; then
    error "Cross-compiler not found. Install: sudo apt install gcc-aarch64-linux-gnu"
fi

# Verify splash library files exist
for f in fbsplash.c svg_parser.c svg_renderer.c archr-logo.h; do
    if [ ! -f "$SPLASH_DIR/$f" ]; then
        error "Missing splash file: $SPLASH_DIR/$f"
    fi
done

#------------------------------------------------------------------------------
# Step 1: Compile archr-init (static aarch64 binary with SVG splash)
#------------------------------------------------------------------------------
log ""
log "Step 1: Compiling archr-init (SVG splash)..."

TMPDIR=$(mktemp -d)

aarch64-linux-gnu-gcc -static -O2 \
    -I"$SPLASH_DIR" \
    -o "$TMPDIR/archr-init" \
    "$SCRIPT_DIR/scripts/archr-init.c" \
    "$SPLASH_DIR/fbsplash.c" \
    "$SPLASH_DIR/svg_parser.c" \
    "$SPLASH_DIR/svg_renderer.c" \
    -lm

log "  archr-init compiled ($(du -h "$TMPDIR/archr-init" | cut -f1))"

#------------------------------------------------------------------------------
# Step 2: Create initramfs directory tree
#------------------------------------------------------------------------------
log ""
log "Step 2: Creating initramfs directory..."

rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"/{dev,proc,newroot}

cp "$TMPDIR/archr-init" "$INITRAMFS_DIR/init"
chmod 755 "$INITRAMFS_DIR/init"

#------------------------------------------------------------------------------
# Cleanup
#------------------------------------------------------------------------------
rm -rf "$TMPDIR"

INIT_SIZE=$(du -h "$INITRAMFS_DIR/init" | cut -f1)
log ""
log "================================================================"
log "  Initramfs Ready"
log "================================================================"
log ""
log "  Directory: $INITRAMFS_DIR"
log "  /init:     $INIT_SIZE (static aarch64 + SVG splash)"
log ""
log "  Kernel will embed this via CONFIG_INITRAMFS_SOURCE"
