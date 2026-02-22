#!/bin/bash

#==============================================================================
# Arch R - Build Mesa 26 (Panfrost GPU driver for Mali-G31)
#==============================================================================
# Builds Mesa 26.0.x inside the rootfs chroot environment (native aarch64).
# Replaces ALARM's Mesa 25.x with Mesa 26 optimized for RK3326/Mali-G31.
#
# GPU Pipeline:
#   ES (GLES 1.0) → Mesa TNL → Panfrost → Mali-G31 GPU
#   RetroArch (GLES 2.0/3.1) → Panfrost → Mali-G31 GPU
#
# Mesa provides: EGL, GLES 1.0/2.0/3.1, GBM, kmsro (rockchip-drm ↔ panfrost bridge)
# Built with -Dgles1=enabled -Dglvnd=false (direct Mesa EGL, no libglvnd dispatch)
#
# This runs AFTER build-rootfs.sh and BEFORE build-emulationstation.sh
# Usage: sudo ./build-mesa.sh
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
ROOTFS_DIR="$OUTPUT_DIR/rootfs"
CACHE_DIR="$SCRIPT_DIR/.cache"

# CRITICAL: Always clean up bind mounts on exit (success OR failure).
cleanup_mounts() {
    echo "[MESA] Cleaning up bind mounts..."
    umount -l "$ROOTFS_DIR/run" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/sys" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/dev" 2>/dev/null || true
}
trap cleanup_mounts EXIT

# Mesa version
MESA_VERSION="26.0.0"
MESA_URL="https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"
MESA_TARBALL="$CACHE_DIR/mesa-${MESA_VERSION}.tar.xz"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[MESA]${NC} $1"; }
warn() { echo -e "${YELLOW}[MESA] WARNING:${NC} $1"; }
error() { echo -e "${RED}[MESA] ERROR:${NC} $1"; exit 1; }

#------------------------------------------------------------------------------
# Checks
#------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (for chroot)"
fi

if [ ! -d "$ROOTFS_DIR/usr" ]; then
    error "Rootfs not found at $ROOTFS_DIR. Run build-rootfs.sh first!"
fi

log "=== Building Mesa ${MESA_VERSION} (Panfrost for Mali-G31) ==="

#------------------------------------------------------------------------------
# Step 1: Download Mesa source
#------------------------------------------------------------------------------
log ""
log "Step 1: Getting Mesa source..."

mkdir -p "$CACHE_DIR"

if [ ! -f "$MESA_TARBALL" ]; then
    log "  Downloading Mesa ${MESA_VERSION}..."
    wget -O "$MESA_TARBALL" "$MESA_URL" || {
        # Try .0.1 if .0.0 not available yet
        MESA_VERSION="26.0.1"
        MESA_URL="https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz"
        MESA_TARBALL="$CACHE_DIR/mesa-${MESA_VERSION}.tar.xz"
        warn "26.0.0 not found, trying ${MESA_VERSION}..."
        wget -O "$MESA_TARBALL" "$MESA_URL"
    }
else
    log "  Using cached tarball: $(basename "$MESA_TARBALL")"
fi

#------------------------------------------------------------------------------
# Step 2: Extract and copy into rootfs
#------------------------------------------------------------------------------
log ""
log "Step 2: Setting up build environment in rootfs..."

BUILD_DIR="$ROOTFS_DIR/tmp/mesa-build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

log "  Extracting Mesa source..."
tar xf "$MESA_TARBALL" -C "$BUILD_DIR" --strip-components=1

log "  Source ready ($(du -sh "$BUILD_DIR" | cut -f1))"

#------------------------------------------------------------------------------
# Step 3: Setup chroot
#------------------------------------------------------------------------------
log ""
log "Step 3: Setting up chroot..."

# Copy QEMU
if [ -f "/usr/bin/qemu-aarch64-static" ]; then
    cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"
else
    error "qemu-aarch64-static not found. Install: sudo apt install qemu-user-static"
fi

# Bind mounts
mount --bind /dev "$ROOTFS_DIR/dev" 2>/dev/null || true
mount --bind /dev/pts "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
mount --bind /proc "$ROOTFS_DIR/proc" 2>/dev/null || true
mount --bind /sys "$ROOTFS_DIR/sys" 2>/dev/null || true
mount --bind /run "$ROOTFS_DIR/run" 2>/dev/null || true
cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"

log "  Chroot ready"

#------------------------------------------------------------------------------
# Step 4: Build inside chroot
#------------------------------------------------------------------------------
log ""
log "Step 4: Building Mesa inside chroot..."

cat > "$ROOTFS_DIR/tmp/build-mesa-chroot.sh" << 'BUILD_EOF'
#!/bin/bash
set -e

# Disable pacman Landlock sandbox (fails in QEMU chroot)
pacman() { command pacman --disable-sandbox "$@"; }

echo "=== Mesa Build: Installing dependencies ==="

# IMPORTANT: Do NOT use --needed here!
# build-rootfs.sh bloat cleanup deletes gcc/ld/clang/llvm binaries and /usr/lib/gcc
# to save ~420MB in the final image. But pacman's DB still says they're "installed",
# so --needed would skip reinstalling them. Without --needed, pacman force-reinstalls
# all packages, ensuring the actual binaries exist.

# Meson build system + ninja
pacman -S --noconfirm \
    meson \
    ninja \
    cmake \
    python \
    python-mako \
    python-pyyaml \
    python-packaging

# Compilation toolchain + system headers
# glibc + linux-api-headers: rootfs bloat cleanup deletes /usr/include entirely.
# gcc/binutils restore their own headers but stdio.h etc. come from glibc.
pacman -S --noconfirm \
    gcc \
    binutils \
    glibc \
    linux-api-headers \
    pkgconf \
    flex \
    bison

# Mesa runtime + build dependencies
pacman -S --noconfirm \
    libdrm \
    expat \
    zlib \
    zstd \
    libelf \
    libglvnd \
    libunwind \
    wayland-protocols \
    llvm \
    llvm-libs \
    clang \
    libclc \
    spirv-llvm-translator \
    spirv-tools

echo "=== Mesa Build: Configuring ==="

cd /tmp/mesa-build

# Meson configure for RK3326 (Mali-G31 Bifrost via Panfrost)
#
# Key choices:
# - gallium-drivers=panfrost: Mali-G31 (Bifrost architecture)
#     panfrost also enables kmsro (rockchip-drm ↔ panfrost bridge)
# - vulkan-drivers= (empty): no Vulkan — saves build time, ES/RetroArch use GL/GLES
# - platforms= (empty): no X11/Wayland — we run on KMSDRM (EGL+GBM on DRM/KMS)
# - egl=enabled: SDL3 KMSDRM needs EGL for context creation
# - gles1=enabled: GLES 1.0 state tracker (TNL) for ES-fcamod native rendering
# - gles2=enabled: GLES 2.0/3.1 for RetroArch (Panfrost provides GLES 3.1)
# - gbm=enabled: SDL3 KMSDRM needs GBM for buffer management
# - opengl=true: OpenGL support
# - glvnd=false: install libEGL/libGLES directly (avoids libglvnd version conflicts)
# - glx=disabled: no X11 → no GLX
# - llvm=enabled: Panfrost in Mesa 26 requires LLVM (CLC for compute shaders)
# - video-codecs=all_free: enable free video decode

meson setup build \
    --prefix=/usr \
    --libdir=lib \
    --buildtype=release \
    -Db_lto=true \
    -Db_ndebug=true \
    -Dc_args="-O2 -march=armv8-a+crc -mtune=cortex-a35" \
    -Dcpp_args="-O2 -march=armv8-a+crc -mtune=cortex-a35" \
    -Dgallium-drivers=panfrost \
    -Dvulkan-drivers= \
    -Dplatforms= \
    -Degl=enabled \
    -Dgles1=enabled \
    -Dgles2=enabled \
    -Dopengl=true \
    -Dglx=disabled \
    -Dgbm=enabled \
    -Dglvnd=false \
    -Dllvm=enabled \
    -Dgallium-rusticl=false \
    -Dvalgrind=disabled \
    -Dlmsensors=disabled \
    -Dvideo-codecs=all_free

echo "=== Mesa Build: Compiling ==="

# Limit jobs — QEMU chroot eats ~500MB/gcc, avoid OOM
ninja -C build -j2

echo "=== Mesa Build: Installing ==="

# Remove ALARM mesa packages first (avoid file conflicts)
# --noconfirm because removing mesa may pull other packages
for pkg in mesa mesa-vdpau; do
    pacman -Rdd --noconfirm "$pkg" 2>/dev/null || true
done

# CRITICAL: Remove old libglvnd EGL/GLES files BEFORE installing Mesa 26.
# Mesa with glvnd=false installs libEGL.so.1.0.0 directly.
# But libglvnd's libEGL.so.1.1.0 has HIGHER .so version (1.1.0 > 1.0.0).
# ldconfig creates libEGL.so.1 symlink pointing to the HIGHEST version
# → old libglvnd EGL gets loaded instead of Mesa's → EGL_BAD_ALLOC.
# Same applies to libGLESv1_CM and libGLESv2.
echo "  Removing old libglvnd EGL/GLES files (version conflict prevention)..."
rm -f /usr/lib/libEGL.so* /usr/lib/libEGL_mesa.so*
rm -f /usr/lib/libGLESv1_CM.so*
rm -f /usr/lib/libGLESv2.so*
rm -f /usr/lib/libOpenGL.so*
echo "  Old EGL/GLES files removed"

# Install Mesa 26 into system (glvnd=false → direct libEGL.so, libGLESv1_CM.so, etc.)
ninja -C build install

# Rebuild ldconfig cache
ldconfig

# Verify symlinks point to Mesa's files (not stale libglvnd)
echo "  EGL symlink: $(ls -la /usr/lib/libEGL.so.1 2>/dev/null | awk '{print $NF}')"
echo "  GLES1 symlink: $(ls -la /usr/lib/libGLESv1_CM.so.1 2>/dev/null | awk '{print $NF}')"

echo "=== Mesa Build: Verifying ==="

# Mesa 26 architecture: single libgallium-*.so megadriver (no per-driver .so in /usr/lib/dri/)
# GBM backend: /usr/lib/gbm/dri_gbm.so

# Check gallium megadriver (contains panfrost + kmsro)
GALLIUM_SO=$(ls /usr/lib/libgallium-*.so 2>/dev/null | head -1)
if [ -n "$GALLIUM_SO" ]; then
    echo "  Gallium driver: OK ($(basename "$GALLIUM_SO"), $(du -h "$GALLIUM_SO" | cut -f1))"
else
    echo "  ERROR: libgallium-*.so not found!"
    exit 1
fi

# Check GBM DRI backend
if [ -f /usr/lib/gbm/dri_gbm.so ]; then
    echo "  GBM DRI backend: OK"
else
    echo "  WARNING: dri_gbm.so not found"
fi

# Check EGL (glvnd=false → direct libEGL.so, NOT libEGL_mesa.so vendor dispatch)
if [ -f /usr/lib/libEGL.so.1 ]; then
    EGL_SIZE=$(du -h /usr/lib/libEGL.so.1 | cut -f1)
    echo "  EGL: OK (libEGL.so.1, ${EGL_SIZE} — should be ~360KB for Mesa direct)"
else
    echo "  WARNING: libEGL.so.1 not found"
fi

# Check GBM
if [ -f /usr/lib/libgbm.so.1 ]; then
    echo "  GBM: OK (libgbm.so.1)"
else
    echo "  WARNING: GBM library not found"
fi

# Check GLES 1.0 (needed for ES-fcamod with -DGLES=ON)
if [ -f /usr/lib/libGLESv1_CM.so ] || [ -f /usr/lib/libGLESv1_CM.so.1 ]; then
    echo "  GLES 1.0: OK ($(ls /usr/lib/libGLESv1_CM.so* 2>/dev/null | head -1))"
else
    echo "  WARNING: libGLESv1_CM.so not found — GLES 1.0 ES build will fail!"
    echo "  Verify Mesa was built with -Dgles1=enabled"
fi
if [ -f /usr/include/GLES/gl.h ]; then
    echo "  GLES headers: OK (/usr/include/GLES/gl.h)"
else
    echo "  WARNING: GLES/gl.h header not found"
fi

echo "  Mesa 26 verified — Panfrost in gallium megadriver"

echo "=== Mesa Build: Complete ==="
BUILD_EOF

chmod +x "$ROOTFS_DIR/tmp/build-mesa-chroot.sh"
chroot "$ROOTFS_DIR" /tmp/build-mesa-chroot.sh

log "  Mesa ${MESA_VERSION} built and installed"

#------------------------------------------------------------------------------
# Step 5: Cleanup
#------------------------------------------------------------------------------
log ""
log "Step 5: Cleaning up..."

# Remove build directory (saves ~1-2GB in rootfs)
rm -rf "$BUILD_DIR"
rm -f "$ROOTFS_DIR/tmp/build-mesa-chroot.sh"

# Remove build-only deps to save space
cat > "$ROOTFS_DIR/tmp/cleanup-mesa.sh" << 'CLEAN_EOF'
#!/bin/bash
pacman() { command pacman --disable-sandbox "$@"; }
# Remove build-only packages (not needed at runtime)
for pkg in meson ninja flex bison python-mako python-pyyaml; do
    pacman -Rdd --noconfirm "$pkg" 2>/dev/null || true
done
pacman -Scc --noconfirm
CLEAN_EOF
chmod +x "$ROOTFS_DIR/tmp/cleanup-mesa.sh"
chroot "$ROOTFS_DIR" /tmp/cleanup-mesa.sh
rm -f "$ROOTFS_DIR/tmp/cleanup-mesa.sh"

# Remove QEMU
rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"

# Bind mounts are cleaned up by the EXIT trap (cleanup_mounts)

log "  Cleanup complete"

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
log ""
log "=== Mesa ${MESA_VERSION} Build Complete ==="
log ""
log "Pipeline: ES (GLES 1.0) -> Mesa TNL -> Panfrost (Mali-G31)"
log ""
log "Installed (glvnd=false, direct):"
log "  /usr/lib/libgallium-26.0.0.so    (Panfrost + kmsro megadriver, with GLES 1.0 TNL)"
log "  /usr/lib/libEGL.so.1.0.0         (Mesa direct EGL — no libglvnd dispatch)"
log "  /usr/lib/libGLESv1_CM.so.1.1.0   (Mesa direct GLES 1.0)"
log "  /usr/lib/libGLESv2.so.2.0.0      (Mesa direct GLES 2.0)"
log "  /usr/lib/libgbm.so.1             (GBM — buffer management for KMSDRM)"
log "  /usr/lib/gbm/dri_gbm.so          (GBM DRI backend)"
log ""
log "Next: run build-emulationstation.sh (ES links against Mesa 26 EGL/GLES)"
