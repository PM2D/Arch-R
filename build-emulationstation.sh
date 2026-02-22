#!/bin/bash

#==============================================================================
# Arch R - EmulationStation Build Script
#==============================================================================
# Builds EmulationStation-fcamod (christianhaitian fork) for aarch64
# inside the rootfs chroot environment.
#
# Patches applied (21 total):
#   1-5:   Context fixes (go2, MINOR, ES profile, null safety, MakeCurrent)
#   6-7:   Safety fixes (getShOutput, language restart)
#   8-12:  Performance (no depth, stencil, disable depth test)
#   13-14: Eliminate popen, reduce polling intervals
#   15:    Cache getThemeSets() (19+ dir scans → 1)
#   16:    Remove dead readList() call
#   17:    NanoSVG static rasterizer
#   18:    Boot profiling (5 timestamps → es-debug.log)
#   19:    ThreadPool VSync reduction (10→500ms, ~1.5s saved)
#   20:    Skip non-existent ROM directories
#   21:    MameNames lazy init (call_once)
#
# This runs AFTER build-rootfs.sh and BEFORE build-image.sh
# Requires: rootfs at output/rootfs with build deps installed
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/output"
ROOTFS_DIR="$OUTPUT_DIR/rootfs"
CACHE_DIR="$SCRIPT_DIR/.cache"

# CRITICAL: Always clean up bind mounts on exit (success OR failure).
# Without this trap, a build error leaves /dev /proc /sys /run mounted
# inside the rootfs — this can break the host system.
cleanup_mounts() {
    echo "[ES-BUILD] Cleaning up bind mounts..."
    umount -l "$ROOTFS_DIR/run" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/sys" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/proc" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/dev/pts" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/dev" 2>/dev/null || true
}
trap cleanup_mounts EXIT

# EmulationStation source
ES_REPO="https://github.com/christianhaitian/EmulationStation-fcamod.git"
ES_BRANCH="351v"
ES_CACHE="$CACHE_DIR/EmulationStation-fcamod"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[ES-BUILD]${NC} $1"; }
warn() { echo -e "${YELLOW}[ES-BUILD] WARNING:${NC} $1"; }
error() { echo -e "${RED}[ES-BUILD] ERROR:${NC} $1"; exit 1; }

#------------------------------------------------------------------------------
# Checks
#------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (for chroot)"
fi

if [ ! -d "$ROOTFS_DIR/usr" ]; then
    error "Rootfs not found at $ROOTFS_DIR. Run build-rootfs.sh first!"
fi

log "=== Building EmulationStation-fcamod ==="
log "Branch: $ES_BRANCH"

#------------------------------------------------------------------------------
# Step 1: Clone / update EmulationStation source on host
#------------------------------------------------------------------------------
log ""
log "Step 1: Getting EmulationStation source..."

mkdir -p "$CACHE_DIR"

if [ -d "$ES_CACHE/.git" ]; then
    log "  Updating existing clone..."
    cd "$ES_CACHE"
    git fetch origin
    git checkout "$ES_BRANCH"
    git reset --hard "origin/$ES_BRANCH"
    git submodule update --init --recursive
    cd "$SCRIPT_DIR"
else
    log "  Cloning EmulationStation-fcamod..."
    git clone --depth 1 --recurse-submodules -b "$ES_BRANCH" "$ES_REPO" "$ES_CACHE"
fi

log "  ✓ Source ready"

#------------------------------------------------------------------------------
# Step 2: Copy source into rootfs for native build
#------------------------------------------------------------------------------
log ""
log "Step 2: Setting up build environment in rootfs..."

BUILD_DIR="$ROOTFS_DIR/tmp/es-build"
rm -rf "$BUILD_DIR"
cp -a "$ES_CACHE" "$BUILD_DIR"

log "  ✓ Source copied to rootfs"

#------------------------------------------------------------------------------
# Step 2b: GLES 1.0 native — no gl4es needed
#------------------------------------------------------------------------------
log ""
log "Step 2b: GLES 1.0 native mode — gl4es NOT needed"
log "  ES will be built with -DGLES=ON (Renderer_GLES10.cpp)"
log "  Rendering: ES (GLES 1.0) → Mesa EGL → Panfrost (Mali-G31)"
log "  Mesa provides GLES 1.0 headers (GLES/gl.h) and libGLESv1_CM.so"

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

log "  ✓ Chroot ready"

#------------------------------------------------------------------------------
# Step 4: Build inside chroot
#------------------------------------------------------------------------------
log ""
log "Step 4: Building EmulationStation inside chroot..."

cat > "$ROOTFS_DIR/tmp/build-es.sh" << 'BUILD_EOF'
#!/bin/bash
set -e

# Disable pacman Landlock sandbox (fails in QEMU chroot)
pacman() { command pacman --disable-sandbox "$@"; }

echo "=== ES Build: Installing dependencies ==="

# Build dependencies (freeimage excluded — built from source below)
# Do NOT use --needed! build-rootfs.sh bloat cleanup deletes gcc/make/cmake/git
# binaries to save space, but pacman DB still thinks they're installed.
# Without --needed, pacman force-reinstalls and restores the actual binaries.
#
# Mesa 26 conflict: gcc/base-devel pull in pacman's mesa as dependency,
# which conflicts with our custom Mesa 26 files (GBM, EGL headers, drirc).
# Solution: save Mesa 26 files → let pacman overwrite → restore immediately.

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

pacman -S --noconfirm "${MESA_OVERWRITE[@]}" base-devel

# Then install specific build dependencies
# glibc + linux-api-headers: rootfs bloat cleanup deletes /usr/include entirely
pacman -S --noconfirm "${MESA_OVERWRITE[@]}" \
    make \
    gcc \
    glibc \
    linux-api-headers \
    cmake \
    git \
    unzip \
    sdl2 \
    sdl2_mixer \
    freetype2 \
    curl \
    rapidjson \
    boost \
    pugixml \
    alsa-lib \
    libdrm

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
echo "  dri_gbm: $(readelf -d /usr/lib/gbm/dri_gbm.so 2>/dev/null | grep gallium | awk '{print $NF}')"
ldconfig
echo "  ✓ Mesa 26 files restored (EGL, GLES, GBM, gallium, DRI)"
# NOTE: vlc removed — it pulls in mesa (conflicts with our Mesa 26) and 865MB of bloat.
# ES cmake has FATAL_ERROR if VLC not found, so we install a stub libvlc.so + headers
# below (before cmake). At runtime, libvlc_new()→NULL, video backgrounds disabled.

# GPU: Mesa 26 Panfrost is pre-installed by build-mesa.sh (NOT from pacman!)
# Do NOT install mesa from pacman — it conflicts with our custom Mesa 26.
# Our Mesa provides: libEGL.so, libGLESv1_CM.so, libGLESv2.so, Panfrost driver

# Build FreeImage from source (not available in ALARM aarch64 repos)
if ! pacman -Q freeimage &>/dev/null; then
    echo "=== Building FreeImage from source ==="
    cd /tmp
    rm -rf FreeImage FreeImage3180.zip
    curl -L -o FreeImage3180.zip \
        "https://downloads.sourceforge.net/project/freeimage/Source%20Distribution/3.18.0/FreeImage3180.zip"
    unzip -oq FreeImage3180.zip
    cd FreeImage
    # Patch Makefile for modern GCC compatibility (FreeImage 3.18.0 is old):
    # - C++14: bundled OpenEXR uses throw() specs removed in C++17
    # - unistd.h: bundled ZLib uses lseek/read/write/close without including it
    # - Wno flags: suppress implicit-function-declaration errors in bundled libs
    cat >> Makefile.gnu << 'MKPATCH'
override CFLAGS += -include unistd.h -Wno-implicit-function-declaration -Wno-int-conversion -DPNG_ARM_NEON_OPT=0
override CXXFLAGS += -std=c++14 -include unistd.h -DPNG_ARM_NEON_OPT=0
MKPATCH
    make -j2
    make install
    ldconfig
    cd /tmp && rm -rf FreeImage FreeImage3180.zip
    echo "  FreeImage built and installed"
fi

echo "=== ES Build: Rebuilding SDL3 with KMSDRM support ==="

# CRITICAL: ALARM's SDL3 package is built WITHOUT KMSDRM video backend.
# Without KMSDRM, SDL can only use x11/wayland/offscreen/dummy — none work
# on our console-only RK3326. We need to rebuild SDL3 with -DSDL_KMSDRM=ON.
# sdl2-compat (provides libSDL2) wraps SDL3, so it gains KMSDRM automatically.

if ! grep -ao 'kmsdrm' /usr/lib/libSDL3.so* 2>/dev/null | grep -qi kmsdrm; then
    echo "  SDL3 missing KMSDRM support — rebuilding from source..."
    pacman -S --noconfirm --needed cmake meson ninja pkgconf libdrm

    # Get the installed SDL3 version to build the matching release
    SDL3_VER=$(pacman -Q sdl3 2>/dev/null | awk '{print $2}' | cut -d- -f1)
    echo "  System SDL3 version: $SDL3_VER"

    cd /tmp
    rm -rf SDL3-kmsdrm-build

    # Clone matching version (or latest release if version detection fails)
    if [ -n "$SDL3_VER" ]; then
        git clone --depth 1 -b "release-${SDL3_VER}" \
            https://github.com/libsdl-org/SDL.git SDL3-kmsdrm-build 2>/dev/null \
        || git clone --depth 1 https://github.com/libsdl-org/SDL.git SDL3-kmsdrm-build
    else
        git clone --depth 1 https://github.com/libsdl-org/SDL.git SDL3-kmsdrm-build
    fi

    cd SDL3-kmsdrm-build
    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DSDL_KMSDRM=ON \
        -DSDL_KMSDRM_SHARED=OFF \
        -DSDL_WAYLAND=OFF \
        -DSDL_X11=OFF \
        -DSDL_VULKAN=OFF \
        -DSDL_PIPEWIRE=OFF \
        -DSDL_PULSEAUDIO=OFF \
        -DSDL_ALSA=ON \
        -DSDL_TESTS=OFF \
        -DSDL_INSTALL_TESTS=OFF

    cmake --build build -j$(nproc)

    # Only replace the shared library (keep headers/pkgconfig from package)
    install -m755 build/libSDL3.so.0.* /usr/lib/
    ldconfig

    cd /tmp && rm -rf SDL3-kmsdrm-build

    # Verify KMSDRM is now available
    if grep -ao 'kmsdrm' /usr/lib/libSDL3.so* 2>/dev/null | grep -qi kmsdrm; then
        echo "  SDL3 rebuilt with KMSDRM support — VERIFIED"
    else
        echo "  WARNING: SDL3 rebuild done but KMSDRM still not found!"
    fi
else
    echo "  SDL3 already has KMSDRM support — skipping rebuild"
fi

echo "=== ES Build: Verifying GLES 1.0 support ==="

# GLES 1.0 native — ES needs GLES/gl.h header and libGLESv1_CM.so library
# Mesa 26 must be built with -Dgles1=enabled -Dglvnd=false (run build-mesa.sh first!)
# With glvnd=false, Mesa directly installs libGLESv1_CM.so (not via libglvnd dispatch)

# If GLES 1.0 headers missing, install from Khronos registry
if [ ! -f /usr/include/GLES/gl.h ]; then
    echo "  GLES/gl.h not found — installing Khronos GLES 1.0 headers..."
    mkdir -p /usr/include/GLES
    curl -sL "https://registry.khronos.org/OpenGL/api/GLES/gl.h" -o /usr/include/GLES/gl.h
    curl -sL "https://registry.khronos.org/OpenGL/api/GLES/glext.h" -o /usr/include/GLES/glext.h
    curl -sL "https://registry.khronos.org/OpenGL/api/GLES/glplatform.h" -o /usr/include/GLES/glplatform.h
    echo "  Installed GLES 1.0 headers from Khronos"
fi

echo "  GLES headers: $(ls /usr/include/GLES/gl.h 2>/dev/null || echo 'MISSING!')"
echo "  libGLESv1_CM: $(ls /usr/lib/libGLESv1_CM.so* 2>/dev/null | head -1 || echo 'MISSING!')"
echo "  libEGL: $(ls /usr/lib/libEGL.so* 2>/dev/null | head -1)"

if [ ! -f /usr/include/GLES/gl.h ]; then
    echo "ERROR: GLES/gl.h not found! Run build-mesa.sh first."
    exit 1
fi
if [ ! -f /usr/lib/libGLESv1_CM.so ] && [ ! -f /usr/lib/libGLESv1_CM.so.1 ]; then
    echo "ERROR: libGLESv1_CM.so not found! Mesa must be built with -Dgles1=enabled -Dglvnd=false"
    exit 1
fi
echo "  ✓ GLES 1.0 verified"

echo "=== ES Build: Patching Renderer_GLES10.cpp for Panfrost ==="

cd /tmp/es-build

# Renderer_GLES10.cpp uses GLES 1.0 fixed-function pipeline (glVertexPointer etc.)
# Mesa Panfrost provides GLES 1.0 via internal TNL (fixed-function → shader translation)
# This is MUCH faster than gl4es: single translation at driver level vs double translation

# Patch 1: Remove go2/audio.h dependency (OGA-specific, all go2 code already commented out)
sed -i 's|#include <go2/audio.h>|// #include <go2/audio.h>  // Removed: OGA-specific, unused|' \
    es-core/src/renderers/Renderer_GLES10.cpp
echo "  Patch 1: Removed go2/audio.h dependency"

# Patch 2: Fix CONTEXT_MAJOR_VERSION bug in setupWindow().
# Original: sets MAJOR_VERSION twice. Second should be MINOR_VERSION.
# GLES 1.0 context: MAJOR=1, MINOR=0
sed -i 's/SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 0);/SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);/' \
    es-core/src/renderers/Renderer_GLES10.cpp
echo "  Patch 2: Fixed CONTEXT_MAJOR→MINOR bug"

# Patch 3: Add GLES context profile (needed for SDL3/sdl2-compat on KMSDRM)
# Without this, SDL may request Desktop GL context → EGL fails on Panfrost
sed -i '/SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 1);/i\\t\tSDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);' \
    es-core/src/renderers/Renderer_GLES10.cpp
echo "  Patch 3: Added GLES context profile for KMSDRM"

# Patch 4: Null safety for glGetString in createContext().
# If context creation fails, glGetString returns NULL → std::string(NULL) throws SIGABRT
sed -i 's|std::string glExts = (const char\*)glGetString(GL_EXTENSIONS);|const char* extsPtr = (const char*)glGetString(GL_EXTENSIONS); std::string glExts = extsPtr ? extsPtr : "";|' \
    es-core/src/renderers/Renderer_GLES10.cpp
echo "  Patch 4: Null safety for glGetString"

# Patch 5: Re-establish GL context in setSwapInterval().
# setIcon() via sdl2-compat loses the EGL context → all rendering fails silently
sed -i '/\t\t\/\/ vsync/i\\t\t// Arch R: Re-establish GL context — setIcon() via sdl2-compat loses it\n\t\tSDL_GL_MakeCurrent(getSDLWindow(), sdlContext);' \
    es-core/src/renderers/Renderer_GLES10.cpp
echo "  Patch 5: GL context restore in setSwapInterval"

echo "  ✓ Patched Renderer_GLES10.cpp (5 patches)"

# --- Performance patches (FPS stability) ---

# Patch 8: Remove depth buffer — ES is a 2D UI, never enables GL_DEPTH_TEST.
# Saves GPU bandwidth: no D24 attachment, no depth load/store per tile on Mali-G31.
# 24-bit depth at 640x480 = 921,600 bytes wasted per frame clear.
sed -i 's/SDL_GL_DEPTH_SIZE,  24/SDL_GL_DEPTH_SIZE,   0/' \
    es-core/src/renderers/Renderer_GLES10.cpp
echo "  Patch 8: Removed depth buffer (24 → 0)"

# Patch 9: Add explicit stencil buffer — needed for rounded corners (enableRoundCornerStencil).
# Without explicit request, removing depth may also remove stencil (D24S8 is a packed format).
sed -i '/SDL_GL_DEPTH_SIZE,   0/a\\t\tSDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE,  8);' \
    es-core/src/renderers/Renderer_GLES10.cpp
echo "  Patch 9: Added stencil buffer (for rounded corners)"

# Patch 10: Remove depth clear from swapBuffers — no depth buffer, nothing to clear.
sed -i 's/glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT)/glClear(GL_COLOR_BUFFER_BIT)/' \
    es-core/src/renderers/Renderer_GLES10.cpp
echo "  Patch 10: Removed depth clear from swapBuffers"

# Patch 11: Remove depth clear from enableRoundCornerStencil — depth not used.
# Only removes standalone GL_DEPTH_BUFFER_BIT clear (line 403), NOT stencil clear (line 411).
sed -i '/glClear(GL_DEPTH_BUFFER_BIT);/d' \
    es-core/src/renderers/Renderer_GLES10.cpp
echo "  Patch 11: Removed depth clear from enableRoundCornerStencil"

# Patch 12: Explicitly disable depth test in createContext — belt and suspenders.
# With DEPTH_SIZE=0 the driver shouldn't allocate depth, but this ensures no depth pipeline.
sed -i '/glClearColor(0.0f, 0.0f, 0.0f, 0.0f);/a\\n\t\t// Arch R: No depth testing — 2D UI only. Saves GPU fill rate.\n\t\tglDisable(GL_DEPTH_TEST);\n\t\tglDepthMask(GL_FALSE);' \
    es-core/src/renderers/Renderer_GLES10.cpp
echo "  Patch 12: Disabled depth test + depth writes in createContext"

echo "  ✓ Performance patches applied (8-12)"

# Patch 13: Eliminate popen() from brightness polling — THE MAIN FPS KILLER.
# BrightnessInfoComponent polls getBrightnessLevel() every 40ms (CHECKBRIGHTNESSDELAY=40).
# When brightnessctl exists, it calls popen("brightnessctl -m | awk ...") = fork() 25x/second.
# Each fork() on ARM takes 2-5ms, easily pushing frames over 16.67ms → dropped frames.
# Fix: force mExistBrightnessctl=false → uses sysfs fallback (open/read/close, microseconds).
# The sysfs path already exists in the code (lines 104-138) and works perfectly on R36S.
sed -i 's|mExistBrightnessctl = Utils::FileSystem::exists(BRIGHTNESSCTL_PATH);|mExistBrightnessctl = false; // Arch R: force sysfs direct reads (no popen overhead)|' \
    es-core/src/DisplayPanelControl.cpp
echo "  Patch 13: Eliminated popen() from brightness polling (sysfs direct)"

# Patch 14: Increase brightness/volume polling intervals.
# Original: 40ms (25 polls/sec) — way too aggressive for info bar display.
# New: 500ms for brightness (sysfs is fast but no need to poll 25x/sec)
#      200ms for volume (ALSA mixer is fast, 5x/sec is responsive enough)
sed -i 's/#define CHECKBRIGHTNESSDELAY\t40/#define CHECKBRIGHTNESSDELAY\t500/' \
    es-core/src/components/BrightnessInfoComponent.cpp
sed -i 's/#define CHECKVOLUMEDELAY\t40/#define CHECKVOLUMEDELAY\t200/' \
    es-core/src/components/VolumeInfoComponent.cpp
echo "  Patch 14: Reduced polling intervals (brightness 500ms, volume 200ms)"

# Patch 6: Null safety for getShOutput() — popen() can return NULL.
# Without this check, fgets(buffer, size, NULL) → SIGSEGV/SIGABRT.
# GuiMenu calls getShOutput() for battery, volume, brightness, WiFi info.
sed -i 's|FILE\* pipe{popen(mStr.c_str(), "r")};|FILE* pipe{popen(mStr.c_str(), "r")};\n    if (!pipe) return "";|' \
    es-core/src/platform.cpp
echo "  Patched platform.cpp (getShOutput NULL safety)"

# Patch 7: Language change triggers ES restart instead of in-place menu reload.
# Original: s->setVariable("reloadGuiMenu", true) → delete/new GuiMenu in close()
# This causes SIGABRT (exit 134) on KMSDRM due to use-after-free or GL context loss.
# Fix: quitES(QuitMode::RESTART) → clean ES exit → shell loop restarts with new language.
sed -i '/setString("Language", language->getSelected())/{n;s|s->setVariable("reloadGuiMenu", true);|quitES(QuitMode::RESTART);|}' \
    es-app/src/guis/GuiMenu.cpp
echo "  Patched GuiMenu.cpp (language change → ES restart)"

# ==========================================================================
# Boot-time optimizations (patches 15-17) — Research-based, safe
# ==========================================================================

echo ""
echo "=== Applying boot-time optimizations ==="

THEME_CPP="es-core/src/ThemeData.cpp"
SYSDATA_CPP="es-app/src/SystemData.cpp"
TEXTURE_CPP="es-core/src/resources/TextureData.cpp"

# Patch 15: Cache getThemeSets() — THE BIGGEST WIN.
# getThemeSets() enumerates /etc/emulationstation/themes + ~/.emulationstation/themes
# via getDirContent() on EVERY call. Called per-system during loadTheme() (19+ times).
# Fix: static cache. First call populates, subsequent calls return cached result.
# Thread safety: pre-cache on main thread before ThreadPool starts.
#
# 15a: Add static cache to getThemeSets()
sed -i '/ThemeData::getThemeSets()/{n; /^{$/a\\tstatic bool sCached = false; static std::map<std::string, ThemeSet> sCache;\n\tif (sCached) return sCache;
}' "$THEME_CPP"
# 15b: Save cache before return in getThemeSets()
sed -i '/ThemeData::getThemeSets/,/^}/ {
    /\treturn sets;/i\\tsCached = true; sCache = sets;
}' "$THEME_CPP"
# 15c: Pre-cache on main thread before ThreadPool (avoids thread race)
sed -i '/ThreadPool\* pThreadPool = NULL;/i\\t\/\/ Arch R: pre-cache theme sets before parallel loading\n\tThemeData::getThemeSets();' \
    "$SYSDATA_CPP"
echo "  Patch 15: Cache getThemeSets() (19+ dir scans → 1)"

# Patch 16: Remove redundant readList() — dead code.
# SystemData.cpp loadSystem(): line creates vector 'list' that is NEVER used.
# The actual loop 4 lines later calls readList() again independently.
sed -i '/std::vector<std::string> list = readList(system.child("extension").text().get());/d' \
    "$SYSDATA_CPP"
echo "  Patch 16: Removed dead readList() call"

# Patch 17: NanoSVG — reuse static rasterizer instead of alloc/free per SVG.
# Current: nsvgCreateRasterizer() + nsvgDeleteRasterizer() for EVERY SVG file.
# Fix: static rasterizer, allocated once, reused for all SVGs.
sed -i 's/NSVGrasterizer\* rast = nsvgCreateRasterizer();/static NSVGrasterizer* rast = nsvgCreateRasterizer(); \/\/ Arch R: reuse/' \
    "$TEXTURE_CPP"
sed -i 's/nsvgDeleteRasterizer(rast);/\/\/ nsvgDeleteRasterizer(rast); \/\/ Arch R: static, reused/' \
    "$TEXTURE_CPP"
echo "  Patch 17: NanoSVG static rasterizer (saves alloc/free per SVG)"

# ==========================================================================
# Audit optimizations (patches 18-21) — Based on full source code audit
# ==========================================================================

echo ""
echo "=== Applying audit-based optimizations ==="

MAIN_CPP="es-app/src/main.cpp"
MAME_CPP="es-core/src/MameNames.cpp"

# Patch 18: Boot profiling — timestamps at key boot stages.
# Writes to stderr (captured in ~/es-debug.log by emulationstation.sh).
# Uses clock_gettime(CLOCK_MONOTONIC) for sub-ms precision.
cat > es-core/src/ArchrProfile.h << 'PROFEOF'
#pragma once
#include <time.h>
#include <stdio.h>
static struct timespec _archr_t0;
static inline void archr_profile_init() {
    clock_gettime(CLOCK_MONOTONIC, &_archr_t0);
}
static inline void archr_profile(const char* s) {
    struct timespec n;
    clock_gettime(CLOCK_MONOTONIC, &n);
    fprintf(stderr, "[BOOT %8.1fms] %s\n",
        (n.tv_sec - _archr_t0.tv_sec) * 1000.0 +
        (n.tv_nsec - _archr_t0.tv_nsec) / 1000000.0, s);
}
PROFEOF
sed -i '/#include "MameNames.h"/a\#include "ArchrProfile.h"' "$MAIN_CPP"
sed -i '/LOG(LogInfo) << "EmulationStation - v"/a\\tarchr_profile_init(); archr_profile("start");' "$MAIN_CPP"
sed -i '/if (!scrape_cmdline)/i\\tarchr_profile("before window.init");' "$MAIN_CPP"
sed -i '/if(!loadSystemConfigFile/i\\t\tarchr_profile("before loadConfig");' "$MAIN_CPP"
sed -i '/\/\/run the command line scraper/i\\tarchr_profile("after loadConfig");' "$MAIN_CPP"
sed -i '/window.endRenderLoadingScreen/i\\tarchr_profile("UI ready");' "$MAIN_CPP"
echo "  Patch 18: Boot profiling (5 timestamps → stderr/es-debug.log)"

# Patch 19: ThreadPool wait interval 10→500ms.
# renderLoadingScreen() calls swapBuffers() which blocks on VSync (~13ms at 78Hz).
# At 10ms interval: ~130 iterations × 13ms VSync = ~1.7s wasted on progress bar.
# At 500ms interval: ~6 iterations × 13ms = 78ms. Progress bar still updates, ~1.5s saved.
sed -i 's/}, 10);/}, 500); \/\/ Arch R: reduce VSync overhead (was 10ms)/' "$SYSDATA_CPP"
echo "  Patch 19: ThreadPool wait 10→500ms (saves ~1.5s VSync overhead)"

# Patch 20: Skip non-existent ROM directories early.
# loadSystem() creates SystemData + FolderData + calls opendir() for each system,
# even if the directory doesn't exist. Then deletes everything.
# Fix: quick isDirectory() stat BEFORE allocating objects.
sed -i '/\/\/create the system runtime environment data/i\\t// Arch R: Skip non-existent directories (avoids alloc + opendir on missing paths)\n\tif (!Utils::FileSystem::isDirectory(path))\n\t\treturn nullptr;\n' "$SYSDATA_CPP"
echo "  Patch 20: Skip non-existent ROM directories (fast stat before alloc)"

# Patch 21: MameNames lazy init with std::call_once.
# MameNames::init() at boot parses 3 XML files (mamenames, bioses, devices).
# Costs 50-100ms on ARM, only needed for arcade systems.
# Fix: remove eager init from main(), use thread-safe lazy init on first access.
sed -i '/#include <string.h>/a\#include <mutex>' "$MAME_CPP"
sed -i '/MameNames\* MameNames::sInstance = nullptr;/a\static std::once_flag sMameNamesOnce;' "$MAME_CPP"
sed -i '/MameNames\* MameNames::getInstance/,/} \/\/ getInstance/ {
/if(!sInstance)/d
}' "$MAME_CPP"
sed -i '/MameNames\* MameNames::getInstance/,/} \/\/ getInstance/ {
s/sInstance = new MameNames();/std::call_once(sMameNamesOnce, []() { sInstance = new MameNames(); });/
}' "$MAME_CPP"
sed -i 's/MameNames::init();/\/\/ MameNames::init(); \/\/ Arch R: deferred to lazy call_once/' "$MAIN_CPP"
echo "  Patch 21: MameNames lazy init (std::call_once, thread-safe)"

echo "=== ES Build: Installing VLC stub ==="

# VLC is NOT installed (pulls in mesa + 865MB of bloat).
# ES-fcamod deeply integrates VideoVlcComponent (9 files, 8 constructor calls).
# Solution: provide complete stub headers + library so cmake and gcc are happy.
# At runtime: libvlc_new()→NULL, ES disables video backgrounds gracefully.

mkdir -p /usr/include/vlc

# Complete VLC stub header with all types ES uses
cat > /usr/include/vlc/vlc.h << 'VLCHDR'
#ifndef VLC_VLC_H
#define VLC_VLC_H
#include <vlc/libvlc.h>
#include <vlc/libvlc_media.h>
#include <vlc/libvlc_media_player.h>
#endif
VLCHDR

cat > /usr/include/vlc/libvlc.h << 'VLCCORE'
#ifndef VLC_LIBVLC_H
#define VLC_LIBVLC_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct libvlc_instance_t libvlc_instance_t;
libvlc_instance_t *libvlc_new(int argc, const char *const *argv);
void libvlc_release(libvlc_instance_t *p);
const char *libvlc_get_version(void);
#ifdef __cplusplus
}
#endif
#endif
VLCCORE

cat > /usr/include/vlc/libvlc_media.h << 'VLCMEDIA'
#ifndef VLC_LIBVLC_MEDIA_H
#define VLC_LIBVLC_MEDIA_H
#include <vlc/libvlc.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct libvlc_media_t libvlc_media_t;

typedef enum {
    libvlc_media_parse_local   = 0x00,
    libvlc_media_parse_network = 0x01,
    libvlc_media_fetch_local   = 0x02,
    libvlc_media_fetch_network = 0x04
} libvlc_media_parse_flag_t;

typedef enum {
    libvlc_media_parsed_status_skipped = 1,
    libvlc_media_parsed_status_failed,
    libvlc_media_parsed_status_timeout,
    libvlc_media_parsed_status_done
} libvlc_media_parsed_status_t;

typedef enum {
    libvlc_track_unknown = -1,
    libvlc_track_audio   = 0,
    libvlc_track_video   = 1,
    libvlc_track_text    = 2
} libvlc_track_type_t;

typedef struct { unsigned i_channels; unsigned i_rate; } libvlc_audio_track_t;
typedef struct { unsigned i_height; unsigned i_width; } libvlc_video_track_t;
typedef struct { const char *psz_encoding; } libvlc_subtitle_track_t;

typedef struct libvlc_media_track_t {
    unsigned    i_codec;
    unsigned    i_original_fourcc;
    int         i_id;
    libvlc_track_type_t i_type;
    int         i_profile;
    int         i_level;
    union {
        libvlc_audio_track_t    *audio;
        libvlc_video_track_t    *video;
        libvlc_subtitle_track_t *subtitle;
    };
    unsigned    i_bitrate;
    char       *psz_language;
    char       *psz_description;
} libvlc_media_track_t;

libvlc_media_t *libvlc_media_new_path(libvlc_instance_t *inst, const char *path);
void libvlc_media_add_option(libvlc_media_t *m, const char *opt);
int libvlc_media_parse_with_options(libvlc_media_t *m, unsigned flags, int timeout);
int libvlc_media_get_parsed_status(libvlc_media_t *m);
unsigned libvlc_media_tracks_get(libvlc_media_t *m, libvlc_media_track_t ***tracks);
void libvlc_media_tracks_release(libvlc_media_track_t **tracks, unsigned count);
void libvlc_media_release(libvlc_media_t *m);
#ifdef __cplusplus
}
#endif
#endif
VLCMEDIA

cat > /usr/include/vlc/libvlc_media_player.h << 'VLCPLAYER'
#ifndef VLC_LIBVLC_MEDIA_PLAYER_H
#define VLC_LIBVLC_MEDIA_PLAYER_H
#include <vlc/libvlc_media.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct libvlc_media_player_t libvlc_media_player_t;

typedef enum {
    libvlc_NothingSpecial = 0,
    libvlc_Opening,
    libvlc_Buffering,
    libvlc_Playing,
    libvlc_Paused,
    libvlc_Stopped,
    libvlc_Ended,
    libvlc_Error
} libvlc_state_t;

typedef void *(*libvlc_video_lock_cb)(void *opaque, void **planes);
typedef void (*libvlc_video_unlock_cb)(void *opaque, void *picture, void *const *planes);
typedef void (*libvlc_video_display_cb)(void *opaque, void *picture);

libvlc_media_player_t *libvlc_media_player_new_from_media(libvlc_media_t *m);
void libvlc_media_player_set_media(libvlc_media_player_t *p, libvlc_media_t *m);
int libvlc_media_player_play(libvlc_media_player_t *p);
void libvlc_media_player_stop(libvlc_media_player_t *p);
libvlc_state_t libvlc_media_player_get_state(libvlc_media_player_t *p);
void libvlc_media_player_release(libvlc_media_player_t *p);
void libvlc_audio_set_mute(libvlc_media_player_t *p, int mute);
void libvlc_video_set_callbacks(libvlc_media_player_t *p,
    libvlc_video_lock_cb lock, libvlc_video_unlock_cb unlock,
    libvlc_video_display_cb display, void *opaque);
void libvlc_video_set_format(libvlc_media_player_t *p,
    const char *chroma, unsigned w, unsigned h, unsigned pitch);
#ifdef __cplusplus
}
#endif
#endif
VLCPLAYER

# Compile stub library (all functions return NULL/0/failure)
cat > /tmp/vlc-stub.c << 'VLCSTUB'
#include <stddef.h>
typedef void libvlc_instance_t;
typedef void libvlc_media_t;
typedef void libvlc_media_player_t;
typedef void libvlc_media_track_t;
libvlc_instance_t *libvlc_new(int c, const char *const *v) { return NULL; }
void libvlc_release(libvlc_instance_t *p) { }
const char *libvlc_get_version(void) { return "0.0.0-stub"; }
libvlc_media_t *libvlc_media_new_path(libvlc_instance_t *i, const char *p) { return NULL; }
void libvlc_media_add_option(libvlc_media_t *m, const char *o) { }
int libvlc_media_parse_with_options(libvlc_media_t *m, unsigned f, int t) { return -1; }
int libvlc_media_get_parsed_status(libvlc_media_t *m) { return 0; }
unsigned libvlc_media_tracks_get(libvlc_media_t *m, libvlc_media_track_t ***t) { return 0; }
void libvlc_media_tracks_release(libvlc_media_track_t **t, unsigned c) { }
void libvlc_media_release(libvlc_media_t *m) { }
libvlc_media_player_t *libvlc_media_player_new_from_media(libvlc_media_t *m) { return NULL; }
void libvlc_media_player_set_media(libvlc_media_player_t *p, libvlc_media_t *m) { }
int libvlc_media_player_play(libvlc_media_player_t *p) { return -1; }
void libvlc_media_player_stop(libvlc_media_player_t *p) { }
int libvlc_media_player_get_state(libvlc_media_player_t *p) { return 0; }
void libvlc_media_player_release(libvlc_media_player_t *p) { }
void libvlc_audio_set_mute(libvlc_media_player_t *p, int m) { }
void libvlc_video_set_callbacks(libvlc_media_player_t *p, void *l, void *u, void *d, void *o) { }
void libvlc_video_set_format(libvlc_media_player_t *p, const char *c, unsigned w, unsigned h, unsigned pi) { }
VLCSTUB

gcc -shared -fPIC -o /usr/lib/libvlc.so.5 /tmp/vlc-stub.c
ln -sf libvlc.so.5 /usr/lib/libvlc.so
ldconfig

# pkg-config so cmake FindVLC finds it
mkdir -p /usr/lib/pkgconfig
cat > /usr/lib/pkgconfig/libvlc.pc << 'VLCPC'
prefix=/usr
exec_prefix=${prefix}
libdir=${exec_prefix}/lib
includedir=${prefix}/include

Name: libvlc
Description: VLC media library (Arch R stub)
Version: 3.0.0
Libs: -L${libdir} -lvlc
Cflags: -I${includedir}
VLCPC

echo "  ✓ VLC stub installed (complete headers + libvlc.so.5 + pkg-config)"
rm -f /tmp/vlc-stub.c

echo "=== ES Build: Compiling ==="

# Clean previous build
rm -rf CMakeCache.txt CMakeFiles

# Configure — GLES 1.0 native mode (NO gl4es!)
# -DGLES=ON forces USE_OPENGLES_10 → uses Renderer_GLES10.cpp
# cmake FindOpenGLES resolves to Mesa's libGLESv1_CM.so
# Rendering pipeline: ES (GLES 1.0) → Mesa EGL → Panfrost (Mali-G31)
cmake . \
    -DCMAKE_BUILD_TYPE=Release \
    -DGLES=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_CXX_FLAGS="-O2 -march=armv8-a+crc -mtune=cortex-a35 -include cstdint -Wno-template-body"

# Build (limit jobs — QEMU chroot eats ~500MB/gcc, avoid OOM)
make -j2

echo "=== ES Build: Installing ==="

# Install binary
install -d /usr/bin/emulationstation
install -m 755 emulationstation /usr/bin/emulationstation/emulationstation

# Install resources
cp -r resources /usr/bin/emulationstation/

# Create symlink for easy execution
ln -sf /usr/bin/emulationstation/emulationstation /usr/local/bin/emulationstation

echo "=== ES Build: Complete ==="
ls -la /usr/bin/emulationstation/emulationstation
BUILD_EOF

chmod +x "$ROOTFS_DIR/tmp/build-es.sh"
chroot "$ROOTFS_DIR" /tmp/build-es.sh

log "  ✓ EmulationStation built and installed"

#------------------------------------------------------------------------------
# Step 5: Install Arch R configs
#------------------------------------------------------------------------------
log ""
log "Step 5: Installing Arch R EmulationStation configs..."

# es_systems.cfg
if [ -f "$SCRIPT_DIR/config/es_systems.cfg" ]; then
    mkdir -p "$ROOTFS_DIR/etc/emulationstation"
    cp "$SCRIPT_DIR/config/es_systems.cfg" "$ROOTFS_DIR/etc/emulationstation/"
    log "  ✓ es_systems.cfg installed"
fi

# ES launch script
install -m 755 "$SCRIPT_DIR/scripts/emulationstation.sh" \
    "$ROOTFS_DIR/usr/bin/emulationstation/emulationstation.sh"
log "  ✓ Launch script installed"

# EmulationStation systemd service — runs ES as archr user with DRM master capabilities
# This replaces the old autologin approach (getty@tty1 → .bash_profile)
# Service provides: TTY association, SDL/Mesa environment, capabilities, auto-restart
cat > "$ROOTFS_DIR/etc/systemd/system/emulationstation.service" << 'ES_SVC_EOF'
[Unit]
Description=EmulationStation
After=archr-boot-setup.service
Conflicts=getty@tty1.service
After=local-fs.target

[Service]
Type=simple
User=archr
Group=archr
WorkingDirectory=/home/archr

# VT association for DRM master access
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=tty
StandardError=journal
TTYVTDisallocate=no

# Environment
Environment="HOME=/home/archr"
Environment="TERM=linux"
Environment="XDG_RUNTIME_DIR=/run/user/1001"
Environment="SDL_VIDEODRIVER=KMSDRM"
Environment="SDL_VIDEO_DRIVER=KMSDRM"
Environment="SDL_AUDIODRIVER=alsa"
Environment="SDL_ASSERT=always_ignore"
Environment="SDL_LOG_PRIORITY=error"
Environment="SDL_LOGGING=*=error"
Environment="MESA_NO_ERROR=1"
Environment="MESA_SHADER_CACHE_DIR=/home/archr/.cache/mesa_shader_cache"
Environment="SDL_GAMECONTROLLERCONFIG_FILE=/etc/archr/gamecontrollerdb.txt"
Environment="SDL_AUDIO_DEVICE_SAMPLE_FRAMES=8192"

# Capabilities: SYS_ADMIN for DRM, SETUID/SETGID/DAC_OVERRIDE for sudo
AmbientCapabilities=CAP_SYS_ADMIN CAP_SETUID CAP_SETGID CAP_DAC_OVERRIDE CAP_AUDIT_WRITE
CapabilityBoundingSet=CAP_SYS_ADMIN CAP_SETUID CAP_SETGID CAP_DAC_OVERRIDE CAP_AUDIT_WRITE

ExecStart=/usr/bin/emulationstation/emulationstation.sh
Restart=on-failure
RestartSec=1

[Install]
WantedBy=multi-user.target
ES_SVC_EOF

# Enable the service (create symlink directly — no chroot needed)
mkdir -p "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/emulationstation.service \
    "$ROOTFS_DIR/etc/systemd/system/multi-user.target.wants/emulationstation.service"

# Disable getty@tty1 — ES service Conflicts with it, but also remove from wants
# to prevent getty from briefly starting before ES conflicts stop it
rm -f "$ROOTFS_DIR/etc/systemd/system/getty.target.wants/getty@tty1.service"

log "  ✓ emulationstation.service created and enabled"
log "  ✓ getty@tty1 disabled (ES service takes over tty1)"

#------------------------------------------------------------------------------
# Step 6: Cleanup
#------------------------------------------------------------------------------
log ""
log "Step 6: Cleaning up..."

# Remove build directory (saves ~200MB in rootfs)
rm -rf "$BUILD_DIR"
rm -f "$ROOTFS_DIR/tmp/build-es.sh"

# Remove build-only deps to save space
cat > "$ROOTFS_DIR/tmp/cleanup-es.sh" << 'CLEAN_EOF'
#!/bin/bash
pacman() { command pacman --disable-sandbox "$@"; }
# Remove build-only packages (not needed at runtime)
# KEEP gcc-libs (provides libstdc++.so — needed by everything C++)
for pkg in cmake eigen gcc make binutils autoconf automake \
           fakeroot patch bison flex m4 libtool texinfo; do
    pacman -Rdd --noconfirm "$pkg" 2>/dev/null || true
done
pacman -Scc --noconfirm
CLEAN_EOF
chmod +x "$ROOTFS_DIR/tmp/cleanup-es.sh"
chroot "$ROOTFS_DIR" /tmp/cleanup-es.sh
rm -f "$ROOTFS_DIR/tmp/cleanup-es.sh"

# Remove QEMU
rm -f "$ROOTFS_DIR/usr/bin/qemu-aarch64-static"

# Bind mounts are cleaned up by the EXIT trap (cleanup_mounts)

log "  ✓ Cleanup complete"

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
log ""
log "=== EmulationStation Build Complete ==="
log ""
log "Rendering: ES (GLES 1.0 native) → Mesa EGL → Panfrost (Mali-G31)"
log "  NO gl4es! Direct GLES 1.0 → Panfrost via Mesa TNL"
log ""
log "Patches applied:"
log "  1-5:  Context fixes (go2, MINOR, ES profile, null safety, MakeCurrent)"
log "  6-7:  Safety fixes (getShOutput, language restart)"
log "  8-12: Performance (no depth, stencil, disable depth test)"
log "  13-14: Eliminate popen, reduce polling intervals"
log "  15:   Cache getThemeSets() (19+ dir scans → 1)"
log "  16:   Remove dead readList() call"
log "  17:   NanoSVG static rasterizer"
log "  18:   Boot profiling (5 timestamps → es-debug.log)"
log "  19:   ThreadPool VSync reduction (10→500ms, ~1.5s saved)"
log "  20:   Skip non-existent ROM directories"
log "  21:   MameNames lazy init (call_once)"
log ""
log "Installed:"
log "  /usr/bin/emulationstation/emulationstation  (binary, -DGLES=ON)"
log "  /usr/bin/emulationstation/resources/         (themes/fonts)"
log "  /usr/bin/emulationstation/emulationstation.sh (launch script)"
log "  /usr/local/bin/emulationstation              (symlink)"
log "  /etc/emulationstation/es_systems.cfg         (system config)"
log ""
