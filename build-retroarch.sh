#!/bin/bash

#==============================================================================
# Arch R - RetroArch Build Script
#==============================================================================
# Builds RetroArch from source with KMS/DRM + EGL + GLES support for R36S.
#
# ALARM's precompiled retroarch package uses Qt/XCB (needs X11).
# R36S runs console-only with KMSDRM — no X server available.
# This script builds RetroArch with native KMS/DRM video context,
# bypassing X11 entirely (same approach as dArkOS).
#
# RetroArch supports GLES natively — no gl4es needed (unlike ES).
# Rendering: RetroArch (GL driver) → EGL/GLES 2.0 → Panfrost (Mali-G31)
#
# This runs AFTER build-rootfs.sh (needs rootfs with deps installed)
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
ROOTFS_DIR="$OUTPUT_DIR/rootfs"
CACHE_DIR="$SCRIPT_DIR/.cache"

# CRITICAL: Always clean up bind mounts on exit (success OR failure).
# Without this trap, a build error leaves /dev /proc /sys /run mounted
# inside the rootfs — this can break the host system (programs crash,
# can't open new apps, requires reboot).
cleanup_mounts() {
    echo "[RA-BUILD] Cleaning up bind mounts..."
    umount -l "$ROOTFS_DIR/run" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/sys" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/dev" 2>/dev/null || true
}
trap cleanup_mounts EXIT

# RetroArch source
RA_REPO="https://github.com/libretro/RetroArch.git"
RA_TAG="v1.22.2"
RA_CACHE="$CACHE_DIR/RetroArch"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[RA-BUILD]${NC} $1"; }
warn() { echo -e "${YELLOW}[RA-BUILD] WARNING:${NC} $1"; }
error() { echo -e "${RED}[RA-BUILD] ERROR:${NC} $1"; exit 1; }

#------------------------------------------------------------------------------
# Checks
#------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (for chroot)"
fi

if [ ! -d "$ROOTFS_DIR/usr" ]; then
    error "Rootfs not found at $ROOTFS_DIR. Run build-rootfs.sh first!"
fi

log "=== Building RetroArch with KMS/DRM support ==="
log "Tag: $RA_TAG"

#------------------------------------------------------------------------------
# Step 1: Clone / update RetroArch source on host
#------------------------------------------------------------------------------
log ""
log "Step 1: Getting RetroArch source..."

mkdir -p "$CACHE_DIR"

if [ -d "$RA_CACHE/.git" ]; then
    log "  Updating existing clone..."
    cd "$RA_CACHE"
    git fetch origin
    git checkout "$RA_TAG"
    git submodule update --init --recursive
    cd "$SCRIPT_DIR"
else
    log "  Cloning RetroArch..."
    git clone --depth 1 --recurse-submodules -b "$RA_TAG" "$RA_REPO" "$RA_CACHE"
fi

log "  Source ready"

#------------------------------------------------------------------------------
# Step 2: Copy source into rootfs for native build
#------------------------------------------------------------------------------
log ""
log "Step 2: Setting up build environment in rootfs..."

BUILD_DIR="$ROOTFS_DIR/tmp/ra-build"
rm -rf "$BUILD_DIR"
cp -a "$RA_CACHE" "$BUILD_DIR"

log "  Source copied to rootfs"

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
log "Step 4: Building RetroArch inside chroot..."

cat > "$ROOTFS_DIR/tmp/build-ra.sh" << 'BUILD_EOF'
#!/bin/bash
set -e

# Disable pacman Landlock sandbox (fails in QEMU chroot)
pacman() { command pacman --disable-sandbox "$@"; }

echo "=== RetroArch Build: Installing dependencies ==="

# Do NOT use --needed! build-rootfs.sh bloat cleanup deletes gcc/make/pkg-config
# binaries to save space, but pacman DB still thinks they're installed.
# Without --needed, pacman force-reinstalls and restores the actual binaries.
#
# Mesa 26 conflict: gcc/base-devel pull in pacman's mesa as dependency,
# which conflicts with our custom Mesa 26 files (GBM, EGL headers, drirc).
# Solution: save Mesa 26 files → let pacman overwrite → restore immediately.
# Our Mesa 26 has gles1=enabled + glvnd=false — pacman's mesa does NOT.

echo "  Saving ALL Mesa 26 files (EGL, GLES, GBM, gallium, DRI)..."
mkdir -p /tmp/mesa26-save/lib/gbm /tmp/mesa26-save/lib/dri /tmp/mesa26-save/lib/pkgconfig \
         /tmp/mesa26-save/include/EGL /tmp/mesa26-save/include/GLES /tmp/mesa26-save/include/GLES2 \
         /tmp/mesa26-save/include/GLES3 /tmp/mesa26-save/include/GL/internal \
         /tmp/mesa26-save/include/KHR /tmp/mesa26-save/share/drirc.d
# Libraries (real files + symlinks)
cp -a /usr/lib/libEGL.so* /tmp/mesa26-save/lib/ 2>/dev/null || true
cp -a /usr/lib/libGLESv1_CM.so* /tmp/mesa26-save/lib/ 2>/dev/null || true
cp -a /usr/lib/libGLESv2.so* /tmp/mesa26-save/lib/ 2>/dev/null || true
cp -a /usr/lib/libgbm* /tmp/mesa26-save/lib/ 2>/dev/null || true
cp -a /usr/lib/libgallium-26*.so* /tmp/mesa26-save/lib/ 2>/dev/null || true
cp -a /usr/lib/gbm/* /tmp/mesa26-save/lib/gbm/ 2>/dev/null || true
cp -a /usr/lib/dri/* /tmp/mesa26-save/lib/dri/ 2>/dev/null || true
# pkg-config
cp -a /usr/lib/pkgconfig/gbm.pc /usr/lib/pkgconfig/dri.pc \
      /usr/lib/pkgconfig/egl.pc /usr/lib/pkgconfig/glesv1_cm.pc \
      /usr/lib/pkgconfig/glesv2.pc /tmp/mesa26-save/lib/pkgconfig/ 2>/dev/null || true
# Headers
cp -a /usr/include/EGL/* /tmp/mesa26-save/include/EGL/ 2>/dev/null || true
cp -a /usr/include/GLES/* /tmp/mesa26-save/include/GLES/ 2>/dev/null || true
cp -a /usr/include/GLES2/* /tmp/mesa26-save/include/GLES2/ 2>/dev/null || true
cp -a /usr/include/GLES3/* /tmp/mesa26-save/include/GLES3/ 2>/dev/null || true
cp -a /usr/include/GL/internal/* /tmp/mesa26-save/include/GL/internal/ 2>/dev/null || true
cp -a /usr/include/KHR/* /tmp/mesa26-save/include/KHR/ 2>/dev/null || true
cp -a /usr/include/gbm.h /usr/include/gbm_backend_abi.h /tmp/mesa26-save/include/ 2>/dev/null || true
# drirc
cp -a /usr/share/drirc.d/* /tmp/mesa26-save/share/drirc.d/ 2>/dev/null || true

# Overwrite patterns: let pacman install its mesa files, we'll restore ours after
MESA_OVERWRITE=(
    --overwrite '/usr/lib/libEGL*'
    --overwrite '/usr/lib/libGLES*'
    --overwrite '/usr/lib/libGL.so*'
    --overwrite '/usr/lib/libOpenGL*'
    --overwrite '/usr/lib/libGLX*'
    --overwrite '/usr/lib/libgallium*'
    --overwrite '/usr/lib/libgbm*'
    --overwrite '/usr/lib/gbm/*'
    --overwrite '/usr/lib/dri/*'
    --overwrite '/usr/lib/pkgconfig/dri.pc'
    --overwrite '/usr/lib/pkgconfig/gbm.pc'
    --overwrite '/usr/lib/pkgconfig/egl.pc'
    --overwrite '/usr/lib/pkgconfig/glesv*'
    --overwrite '/usr/include/EGL/*'
    --overwrite '/usr/include/GLES/*'
    --overwrite '/usr/include/GLES2/*'
    --overwrite '/usr/include/GLES3/*'
    --overwrite '/usr/include/GL/internal/*'
    --overwrite '/usr/include/KHR/*'
    --overwrite '/usr/include/gbm*'
    --overwrite '/usr/share/drirc.d/*'
)

pacman -S --noconfirm "${MESA_OVERWRITE[@]}" \
    base-devel \
    gcc \
    glibc \
    linux-api-headers \
    make \
    pkg-config \
    libdrm \
    libglvnd \
    alsa-lib \
    systemd-libs \
    libxkbcommon \
    zlib \
    freetype2 \
    fontconfig \
    libusb \
    v4l-utils \
    flac \
    mbedtls

echo "  Restoring Mesa 26 files..."
# Remove pacman's conflicting Mesa files first
rm -f /usr/lib/libEGL.so.1.1.0 /usr/lib/libEGL_mesa.so* 2>/dev/null || true
rm -f /usr/lib/libGLESv2.so.2.1.0 2>/dev/null || true
rm -f /usr/lib/libGL.so* /usr/lib/libOpenGL.so* /usr/lib/libGLX.so* 2>/dev/null || true
rm -f /usr/lib/libgallium-[0-9]*.so 2>/dev/null || true
# Restore ALL Mesa 26 files (cp -a preserves symlinks correctly)
cp -a /tmp/mesa26-save/lib/libEGL.so* /usr/lib/ 2>/dev/null || true
cp -a /tmp/mesa26-save/lib/libGLESv1_CM.so* /usr/lib/ 2>/dev/null || true
cp -a /tmp/mesa26-save/lib/libGLESv2.so* /usr/lib/ 2>/dev/null || true
cp -a /tmp/mesa26-save/lib/libgbm* /usr/lib/ 2>/dev/null || true
cp -a /tmp/mesa26-save/lib/libgallium-26*.so* /usr/lib/ 2>/dev/null || true
cp -a /tmp/mesa26-save/lib/gbm/* /usr/lib/gbm/ 2>/dev/null || true
cp -a /tmp/mesa26-save/lib/dri/* /usr/lib/dri/ 2>/dev/null || true
cp -a /tmp/mesa26-save/lib/pkgconfig/*.pc /usr/lib/pkgconfig/ 2>/dev/null || true
cp -a /tmp/mesa26-save/include/EGL/* /usr/include/EGL/ 2>/dev/null || true
cp -a /tmp/mesa26-save/include/GLES/* /usr/include/GLES/ 2>/dev/null || true
cp -a /tmp/mesa26-save/include/GLES2/* /usr/include/GLES2/ 2>/dev/null || true
cp -a /tmp/mesa26-save/include/GLES3/* /usr/include/GLES3/ 2>/dev/null || true
cp -a /tmp/mesa26-save/include/GL/internal/* /usr/include/GL/internal/ 2>/dev/null || true
cp -a /tmp/mesa26-save/include/KHR/* /usr/include/KHR/ 2>/dev/null || true
cp -a /tmp/mesa26-save/include/gbm.h /tmp/mesa26-save/include/gbm_backend_abi.h /usr/include/ 2>/dev/null || true
cp -a /tmp/mesa26-save/share/drirc.d/* /usr/share/drirc.d/ 2>/dev/null || true
rm -rf /tmp/mesa26-save
# Verify critical symlinks
echo "  EGL: $(readlink /usr/lib/libEGL.so.1 2>/dev/null) (expect: libEGL.so.1.0.0)"
echo "  GLES2: $(readlink /usr/lib/libGLESv2.so.2 2>/dev/null) (expect: libGLESv2.so.2.0.0)"
echo "  gallium: $(ls /usr/lib/libgallium-26*.so 2>/dev/null | head -1)"
ldconfig
echo "  ✓ Mesa 26 files restored (EGL, GLES, GBM, gallium, DRI)"

echo "=== RetroArch Build: Configuring ==="

cd /tmp/ra-build

# Configure for KMS/DRM + EGL + GLES (no X11/Wayland/Qt)
# RetroArch uses a custom configure script (not autoconf)
# CFLAGS/CXXFLAGS MUST be passed to configure, NOT to make.
# configure writes them to config.mk. Passing to make overrides
# config.mk AND Makefile's CFLAGS += (which adds include paths).
CFLAGS="-O2 -march=armv8-a+crc -mtune=cortex-a35" \
CXXFLAGS="-O2 -march=armv8-a+crc -mtune=cortex-a35" \
./configure \
    --enable-kms \
    --enable-egl \
    --enable-opengles \
    --enable-opengles3 \
    --disable-x11 \
    --disable-wayland \
    --disable-qt \
    --disable-vulkan \
    --enable-alsa \
    --enable-udev \
    --enable-freetype \
    --enable-rgui \
    --enable-materialui \
    --enable-ozone \
    --enable-zlib \
    --enable-7zip \
    --enable-networking \
    --enable-translate \
    --disable-discord \
    --disable-steam \
    --disable-jack \
    --disable-pulse \
    --disable-oss \
    --disable-pipewire \
    --disable-sdl2 \
    --disable-microphone \
    --prefix=/usr

echo "=== RetroArch Build: Compiling ==="

# CFLAGS already set via configure → config.mk
# Do NOT pass CFLAGS= here — it overrides Makefile include paths
# Limit to 2 jobs — QEMU aarch64 emulation uses ~500MB per gcc process.
# -j$(nproc) on a modern CPU = OOM killer → closes all host programs.
make -j2

echo "=== RetroArch Build: Installing ==="

make install

# Verify the binary
echo ""
echo "--- Binary info ---"
ls -la /usr/bin/retroarch
file /usr/bin/retroarch

# Verify KMS/DRM support is compiled in
echo ""
echo "--- KMS/DRM check ---"
if strings /usr/bin/retroarch | grep -qi "kms\|drm_ctx\|khr_display"; then
    echo "  CONFIRMED: KMS/DRM context support compiled in"
else
    echo "  WARNING: KMS/DRM context strings not found!"
fi

# Verify no X11 dependency
echo ""
echo "--- X11 dependency check ---"
if ldd /usr/bin/retroarch | grep -qi "libX11\|libxcb"; then
    echo "  WARNING: X11 libraries linked!"
    ldd /usr/bin/retroarch | grep -i "libx11\|libxcb"
else
    echo "  CONFIRMED: No X11 dependency"
fi

# Ensure mbedtls .so symlinks match what the binary was linked against.
# RetroArch v1.22.2 links against libmbedtls.so.21 (mbedtls 3.x ABI).
# Package updates may bump the .so version number — create compat symlinks.
echo ""
echo "--- mbedtls symlinks ---"
for lib in libmbedtls libmbedcrypto libmbedx509; do
    LATEST=$(ls /usr/lib/${lib}.so.* 2>/dev/null | sort -V | tail -1)
    if [ -n "$LATEST" ]; then
        BASENAME=$(basename "$LATEST")
        [ ! -e /usr/lib/${lib}.so.21 ] && ln -sf "$BASENAME" /usr/lib/${lib}.so.21 && echo "  Created: ${lib}.so.21 → $BASENAME"
    fi
done
echo "  mbedtls symlinks verified"

# Ensure core info cache directory is writable by archr user.
# Without this, RetroArch logs "[ERROR] Failed to write core info cache file" every launch.
chmod 777 /usr/share/libretro/info 2>/dev/null || true

echo ""
echo "=== RetroArch Build: Complete ==="
BUILD_EOF

chmod +x "$ROOTFS_DIR/tmp/build-ra.sh"
chroot "$ROOTFS_DIR" /tmp/build-ra.sh

log "  RetroArch built and installed"

#------------------------------------------------------------------------------
# Step 5: Install Arch R RetroArch config
#------------------------------------------------------------------------------
log ""
log "Step 5: Installing RetroArch config..."

RA_CFG_DIR="$ROOTFS_DIR/home/archr/.config/retroarch"
mkdir -p "$RA_CFG_DIR/cores"
mkdir -p "$RA_CFG_DIR/saves"
mkdir -p "$RA_CFG_DIR/states"
mkdir -p "$RA_CFG_DIR/screenshots"

if [ -f "$SCRIPT_DIR/config/retroarch.cfg" ]; then
    cp "$SCRIPT_DIR/config/retroarch.cfg" "$RA_CFG_DIR/retroarch.cfg"
    log "  retroarch.cfg installed"
fi

# Fix ownership
chroot "$ROOTFS_DIR" chown -R archr:archr /home/archr/.config/retroarch

log "  Config installed"

#------------------------------------------------------------------------------
# Step 6: Cleanup
#------------------------------------------------------------------------------
log ""
log "Step 6: Cleaning up..."

# Remove build directory (saves ~500MB in rootfs)
rm -rf "$BUILD_DIR"
rm -f "$ROOTFS_DIR/tmp/build-ra.sh"

# Remove build-only deps to save space
# CRITICAL: RetroArch is the LAST build in the pipeline (after Mesa + ES).
# Without this cleanup, all build tools (gcc, make, base-devel, headers)
# remain in the final image — adding ~500MB of unnecessary bloat.
cat > "$ROOTFS_DIR/tmp/cleanup-ra.sh" << 'CLEAN_EOF'
#!/bin/bash
pacman() { command pacman --disable-sandbox "$@"; }
# Remove build-only packages (not needed at runtime)
# KEEP: gcc-libs (libstdc++.so — needed by everything C++),
#       alsa-lib, libdrm, freetype2, mbedtls, zlib (RetroArch runtime deps)
for pkg in gcc make base-devel binutils autoconf automake \
           fakeroot patch bison flex m4 libtool texinfo \
           pkg-config pkgconf linux-api-headers; do
    pacman -Rdd --noconfirm "$pkg" 2>/dev/null || true
done

# Re-strip headers and build artifacts (same as build-rootfs.sh bloat cleanup)
rm -rf /usr/include && mkdir -p /usr/include
rm -rf /usr/lib/gcc /usr/lib/clang
find /usr/lib -name "*.a" -delete 2>/dev/null
for bin in gcc g++ cc c++ cpp ld ld.bfd as objdump objcopy strip \
           ranlib ar nm readelf make cmake pkgconf pkg-config; do
    rm -f "/usr/bin/$bin" 2>/dev/null
done

# Rebuild ldconfig cache and update markers
ldconfig 2>/dev/null || true
touch /etc/.updated /var/.updated

pacman -Scc --noconfirm
CLEAN_EOF
chmod +x "$ROOTFS_DIR/tmp/cleanup-ra.sh"
chroot "$ROOTFS_DIR" /tmp/cleanup-ra.sh
rm -f "$ROOTFS_DIR/tmp/cleanup-ra.sh"

# Remove QEMU
rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"

# Bind mounts are cleaned up by the EXIT trap (cleanup_mounts)

log "  Cleanup complete"

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
log ""
log "=== RetroArch Build Complete ==="
log ""
log "Rendering: RetroArch (GL) → EGL/GLES 2.0 → Panfrost (Mali-G31)"
log "Context: KMS/DRM (no X11, no Wayland)"
log ""
log "Installed:"
log "  /usr/bin/retroarch              (binary, KMS/DRM + GLES)"
log "  /home/archr/.config/retroarch/  (config + saves + states)"
log ""
log "Config: video_driver=gl, video_context_driver=auto (KMS/DRM)"
log "Audio: alsathread, Input: udev"
log ""
