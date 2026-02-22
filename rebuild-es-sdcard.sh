#!/bin/bash

#==============================================================================
# Arch R - Rebuild EmulationStation on SD Card
#==============================================================================
# Rebuilds ES-fcamod with Desktop OpenGL via gl4es (GL 1.x → GLES 2.0).
# gl4es translates Desktop GL calls to GLES 2.0 → Panfrost GPU (hardware).
#
# Why gl4es instead of native GLES?
#   ES-fcamod's Renderer_GLES10.cpp needs GLES 1.0 context, but Mesa Panfrost
#   only supports GLES 2.0+ (EGL_BAD_ALLOC on GLES 1.0). gl4es provides
#   libGL.so.1 that translates Desktop GL → GLES 2.0. Its EGL wrapper
#   intercepts context creation and creates GLES 2.0 context automatically.
#
# Usage: sudo ./rebuild-es-sdcard.sh
#
# Prerequisites:
#   - SD card mounted (ROOTFS at /media/$USER/ROOTFS)
#   - qemu-aarch64-static installed (sudo apt install qemu-user-static)
#   - ES source at .cache/EmulationStation-fcamod/
#   - gl4es pre-built at output/gl4es/ (from cross-compilation)
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/.cache"
OUTPUT_DIR="$SCRIPT_DIR/output"

# EmulationStation source
ES_REPO="https://github.com/christianhaitian/EmulationStation-fcamod.git"
ES_BRANCH="351v"
ES_CACHE="$CACHE_DIR/EmulationStation-fcamod"

# gl4es pre-built libraries (cross-compiled for aarch64)
GL4ES_DIR="$OUTPUT_DIR/gl4es"

# SD card paths
SD="/media/dgateles/ROOTFS"
BOOT="/media/dgateles/BOOT"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[ES-REBUILD]${NC} $1"; }
warn() { echo -e "${YELLOW}[ES-REBUILD] WARNING:${NC} $1"; }
error() { echo -e "${RED}[ES-REBUILD] ERROR:${NC} $1"; exit 1; }

#------------------------------------------------------------------------------
# Checks
#------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (for chroot). Use: sudo $0"
fi

if [ ! -d "$SD/usr" ]; then
    error "SD card rootfs not found at $SD. Mount the SD card first!"
fi

if [ ! -f "/usr/bin/qemu-aarch64-static" ]; then
    error "qemu-aarch64-static not found. Install: sudo apt install qemu-user-static"
fi

if [ ! -f "$GL4ES_DIR/libGL.so.1" ]; then
    error "gl4es not found at $GL4ES_DIR/. Cross-compile gl4es first!"
fi

log "=== Rebuilding EmulationStation with gl4es (Desktop GL → GLES 2.0) ==="
log "SD card rootfs: $SD"

#------------------------------------------------------------------------------
# Step 1: Get ES source
#------------------------------------------------------------------------------
log ""
log "Step 1: Getting EmulationStation source..."

mkdir -p "$CACHE_DIR"

if [ -d "$ES_CACHE/.git" ]; then
    log "  Using existing source at $ES_CACHE"
    cd "$ES_CACHE"
    git checkout "$ES_BRANCH"
    cd "$SCRIPT_DIR"
else
    log "  Cloning EmulationStation-fcamod..."
    git clone --depth 1 --recurse-submodules -b "$ES_BRANCH" "$ES_REPO" "$ES_CACHE"
fi

#------------------------------------------------------------------------------
# Step 2: Install gl4es on SD card rootfs
#------------------------------------------------------------------------------
log ""
log "Step 2: Installing gl4es on SD card rootfs..."

# gl4es runtime library — loaded via LD_LIBRARY_PATH in emulationstation.sh
install -d "$SD/usr/lib/gl4es"
install -m 755 "$GL4ES_DIR/libGL.so.1" "$SD/usr/lib/gl4es/"
ln -sf libGL.so.1 "$SD/usr/lib/gl4es/libGL.so"
log "  gl4es libGL.so.1 installed ($(du -h "$GL4ES_DIR/libGL.so.1" | cut -f1))"

# unset_preload.so — prevents LD_PRELOAD inheritance to child processes
# Without this, ES subprocesses (battery check, distro version) load gl4es
# and its init messages contaminate stdout → "BAT: 87LIBGL: Initialising gl4es..."
if [ -f "$OUTPUT_DIR/unset_preload.so" ]; then
    install -m 755 "$OUTPUT_DIR/unset_preload.so" "$SD/usr/lib/unset_preload.so"
    log "  unset_preload.so installed"
else
    warn "unset_preload.so not found — build it with build-gl4es.sh"
fi

# IMPORTANT: Do NOT install gl4es's libEGL.so.1 here!
# gl4es EGL wrapper is NOT a full EGL implementation — it only intercepts context creation.
# SDL3 KMSDRM needs real Mesa EGL for GBM display/surface init.
# If gl4es libEGL.so.1 is in /usr/lib/gl4es/, LD_LIBRARY_PATH shadows Mesa's → SIGSEGV.
# Instead, ES source is patched to request GLES 2.0 context (SDL_GL_CONTEXT_PROFILE_ES),
# and gl4es detects the existing GLES context for its GL→GLES2 translation.
rm -f "$SD/usr/lib/gl4es/libEGL.so.1" "$SD/usr/lib/gl4es/libEGL.so" 2>/dev/null
log "  gl4es libEGL.so.1 NOT installed (SDL needs real Mesa EGL)"

# System-level symlinks so ES build can find libGL for linking
# (cmake FindOpenGL looks in /usr/lib/)
ln -sf gl4es/libGL.so.1 "$SD/usr/lib/libGL.so.1"
ln -sf gl4es/libGL.so.1 "$SD/usr/lib/libGL.so"
log "  System libGL.so symlinks created"

# Install GL headers for compilation (gl4es provides Desktop GL headers)
if [ -d "$GL4ES_DIR/include/GL" ]; then
    install -d "$SD/usr/include/GL"
    cp "$GL4ES_DIR/include/GL/"*.h "$SD/usr/include/GL/"
    log "  GL headers installed"
fi

#------------------------------------------------------------------------------
# Step 3: Copy ES source to SD card rootfs
#------------------------------------------------------------------------------
log ""
log "Step 3: Copying ES source to SD card rootfs..."

BUILD_DIR="$SD/tmp/es-build"
rm -rf "$BUILD_DIR"
cp -a "$ES_CACHE" "$BUILD_DIR"

log "  Source copied"

#------------------------------------------------------------------------------
# Step 4: Setup chroot on SD card
#------------------------------------------------------------------------------
log ""
log "Step 4: Setting up chroot..."

cp /usr/bin/qemu-aarch64-static "$SD/usr/bin/"

mount --bind /dev "$SD/dev" 2>/dev/null || true
mount --bind /dev/pts "$SD/dev/pts" 2>/dev/null || true
mount --bind /proc "$SD/proc" 2>/dev/null || true
mount --bind /sys "$SD/sys" 2>/dev/null || true
mount --bind /run "$SD/run" 2>/dev/null || true
cp /etc/resolv.conf "$SD/etc/resolv.conf"

cleanup() {
    log "Cleaning up mounts..."
    umount -l "$SD/run" 2>/dev/null || true
    umount -l "$SD/sys" 2>/dev/null || true
    umount -l "$SD/proc" 2>/dev/null || true
    umount -l "$SD/dev/pts" 2>/dev/null || true
    umount -l "$SD/dev" 2>/dev/null || true
    rm -f "$SD/usr/bin/qemu-aarch64-static"
    rm -rf "$SD/tmp/es-build" "$SD/tmp/build-es.sh"
}
trap cleanup EXIT

log "  Chroot ready"

#------------------------------------------------------------------------------
# Step 5: Build ES inside SD card chroot
#------------------------------------------------------------------------------
log ""
log "Step 5: Building EmulationStation with Desktop GL (gl4es) inside chroot..."
log "  (This will take a while — QEMU aarch64 emulation is slow)"

cat > "$SD/tmp/build-es.sh" << 'BUILD_EOF'
#!/bin/bash
set -e

# Disable pacman Landlock sandbox (fails in QEMU chroot)
pacman() { command pacman --disable-sandbox "$@"; }

echo "=== Installing build dependencies ==="

pacman -S --noconfirm --needed base-devel
pacman -S --noconfirm --needed \
    make gcc cmake git unzip \
    sdl2 sdl2_mixer freetype2 curl rapidjson boost pugixml \
    alsa-lib vlc libdrm mesa

# Build FreeImage if not already installed
if ! pacman -Q freeimage &>/dev/null; then
    echo "=== Building FreeImage from source ==="
    cd /tmp
    rm -rf FreeImage FreeImage3180.zip
    curl -L -o FreeImage3180.zip \
        "https://downloads.sourceforge.net/project/freeimage/Source%20Distribution/3.18.0/FreeImage3180.zip"
    unzip -oq FreeImage3180.zip
    cd FreeImage
    cat >> Makefile.gnu << 'MKPATCH'
override CFLAGS += -include unistd.h -Wno-implicit-function-declaration -Wno-int-conversion -DPNG_ARM_NEON_OPT=0
override CXXFLAGS += -std=c++14 -include unistd.h -DPNG_ARM_NEON_OPT=0
MKPATCH
    make -j$(nproc)
    make install
    ldconfig
    cd /tmp && rm -rf FreeImage FreeImage3180.zip
    echo "  FreeImage built and installed"
fi

echo "=== Rebuilding SDL3 with KMSDRM support ==="

# CRITICAL: ALARM's SDL3 is built WITHOUT KMSDRM video backend.
if ! grep -ao 'KMSDRM[_A-Z]*' /usr/lib/libSDL3.so.0.* 2>/dev/null | grep -qi kmsdrm; then
    echo "  SDL3 missing KMSDRM support — rebuilding from source..."
    pacman -S --noconfirm --needed cmake meson ninja pkgconf libdrm mesa

    SDL3_VER=$(pacman -Q sdl3 2>/dev/null | awk '{print $2}' | cut -d- -f1)
    echo "  System SDL3 version: $SDL3_VER"

    cd /tmp && rm -rf SDL3-kmsdrm-build
    if [ -n "$SDL3_VER" ]; then
        git clone --depth 1 -b "release-${SDL3_VER}" \
            https://github.com/libsdl-org/SDL.git SDL3-kmsdrm-build 2>/dev/null \
        || git clone --depth 1 https://github.com/libsdl-org/SDL.git SDL3-kmsdrm-build
    else
        git clone --depth 1 https://github.com/libsdl-org/SDL.git SDL3-kmsdrm-build
    fi

    cd SDL3-kmsdrm-build
    cmake -B build \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
        -DSDL_KMSDRM=ON -DSDL_KMSDRM_SHARED=OFF \
        -DSDL_WAYLAND=OFF -DSDL_X11=OFF -DSDL_VULKAN=OFF \
        -DSDL_PIPEWIRE=OFF -DSDL_PULSEAUDIO=OFF -DSDL_ALSA=ON \
        -DSDL_TESTS=OFF -DSDL_INSTALL_TESTS=OFF
    cmake --build build -j$(nproc)

    install -m755 build/libSDL3.so.0.* /usr/lib/
    ldconfig
    cd /tmp && rm -rf SDL3-kmsdrm-build

    if grep -ao 'KMSDRM[_A-Z]*' /usr/lib/libSDL3.so.0.* 2>/dev/null | grep -qi kmsdrm; then
        echo "  SDL3 rebuilt with KMSDRM support — VERIFIED"
    else
        echo "  WARNING: SDL3 rebuild done but KMSDRM still not found!"
    fi
else
    echo "  SDL3 already has KMSDRM support — skipping rebuild"
fi

echo "=== Verifying gl4es ==="

# gl4es was pre-installed by the host script (cross-compiled for aarch64).
if [ -f /usr/lib/libGL.so.1 ] && file /usr/lib/gl4es/libGL.so.1 | grep -q 'aarch64'; then
    echo "  gl4es libGL.so.1: OK ($(du -h /usr/lib/gl4es/libGL.so.1 | cut -f1))"
else
    echo "  ERROR: gl4es libGL.so.1 not found or wrong architecture!"
    ls -la /usr/lib/gl4es/ 2>/dev/null || echo "  Directory not found"
    exit 1
fi
ldconfig

echo "=== Patching ES source for gl4es (Desktop GL mode) ==="

cd /tmp/es-build

# Patch 1: Fix CONTEXT_MAJOR_VERSION bug in setupWindow().
# Original lines 75-76 both set MAJOR_VERSION — second should be MINOR.
sed -i 's/SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 1);/SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 1);/' \
    es-core/src/renderers/Renderer_GL21.cpp

# Patch 2: Null safety for glGetString in createContext().
sed -i 's|std::string glExts = (const char\*)glGetString(GL_EXTENSIONS);|const char* extsPtr = (const char*)glGetString(GL_EXTENSIONS); std::string glExts = extsPtr ? extsPtr : "";|' \
    es-core/src/renderers/Renderer_GL21.cpp

# Patch 3: Re-establish GL context in setSwapInterval().
# setIcon() via sdl2-compat/SDL3 loses the EGL context.
sed -i '/\t\t\/\/ vsync/i\\t\t// Arch R: Re-establish GL context — setIcon() via sdl2-compat loses it\n\t\tSDL_GL_MakeCurrent(getSDLWindow(), sdlContext);' \
    es-core/src/renderers/Renderer_GL21.cpp

# Patch 4: Request GLES 2.0 context profile in setupWindow().
# Mesa Panfrost doesn't support Desktop GL contexts — only GLES 2.0+.
# Without this patch, SDL requests Desktop GL 2.1 → eglCreateContext fails → NULL context → SIGSEGV.
# With GLES 2.0 context, gl4es detects it (eglGetCurrentContext) and translates GL→GLES2.
sed -i '/SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);/i\\t\tSDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);' \
    es-core/src/renderers/Renderer_GL21.cpp

# Change MINOR version: 1 → 0 (GLES 2.0, not GL 2.1)
sed -i 's/SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 1);/SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);/' \
    es-core/src/renderers/Renderer_GL21.cpp

echo "  Patched Renderer_GL21.cpp (MAJOR/MINOR fix, null safety, GL context restore, GLES profile)"

# Patch 5: Null safety for getShOutput() — popen() can return NULL.
# Without this check, fgets(buffer, size, NULL) → SIGSEGV/SIGABRT.
# GuiMenu calls getShOutput() for battery, volume, brightness, WiFi info.
sed -i 's|FILE\* pipe{popen(mStr.c_str(), "r")};|FILE* pipe{popen(mStr.c_str(), "r")};\n    if (!pipe) return "";|' \
    es-core/src/platform.cpp
echo "  Patched platform.cpp (getShOutput NULL safety)"

echo "=== Compiling EmulationStation (Desktop GL mode) ==="

rm -rf CMakeCache.txt CMakeFiles

# -DGL=ON forces Desktop OpenGL (avoids libMali.so auto-detection)
# gl4es provides libGL.so.1 → translates Desktop GL → GLES 2.0 → Panfrost
cmake . \
    -DCMAKE_BUILD_TYPE=Release \
    -DGL=ON \
    -DOpenGL_GL_PREFERENCE=LEGACY \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_CXX_FLAGS="-O2 -march=armv8-a+crc -mtune=cortex-a35 -include cstdint"

make -j$(nproc)

echo "=== Installing ES ==="

install -d /usr/bin/emulationstation
install -m 755 emulationstation /usr/bin/emulationstation/emulationstation
cp -r resources /usr/bin/emulationstation/
ln -sf /usr/bin/emulationstation/emulationstation /usr/local/bin/emulationstation

echo "  Binary linkage:"
ldd /usr/bin/emulationstation/emulationstation 2>/dev/null | grep -iE 'gl|egl' || true

echo "=== ES Build Complete (Desktop GL + gl4es) ==="
file /usr/bin/emulationstation/emulationstation
ls -la /usr/bin/emulationstation/emulationstation
BUILD_EOF

chmod +x "$SD/tmp/build-es.sh"
chroot "$SD" /tmp/build-es.sh

log "  EmulationStation rebuilt with Desktop GL + gl4es!"

#------------------------------------------------------------------------------
# Step 6: Install configs
#------------------------------------------------------------------------------
log ""
log "Step 6: Installing Arch R configs..."

# ES launch script (updated with gl4es env vars)
install -m 755 "$SCRIPT_DIR/scripts/emulationstation.sh" \
    "$SD/usr/bin/emulationstation/emulationstation.sh"
log "  emulationstation.sh updated"

# KMSDRM test script
if [ -f "$SCRIPT_DIR/scripts/test-kmsdrm.py" ]; then
    install -m 755 "$SCRIPT_DIR/scripts/test-kmsdrm.py" \
        "$SD/usr/bin/emulationstation/test-kmsdrm.py"
    log "  test-kmsdrm.py updated"
fi

# es_systems.cfg
if [ -f "$SCRIPT_DIR/config/es_systems.cfg" ]; then
    mkdir -p "$SD/etc/emulationstation"
    cp "$SCRIPT_DIR/config/es_systems.cfg" "$SD/etc/emulationstation/"
    log "  es_systems.cfg updated"
fi

# es_input.cfg
if [ -f "$SCRIPT_DIR/config/es_input.cfg" ]; then
    cp "$SCRIPT_DIR/config/es_input.cfg" "$SD/etc/emulationstation/"
    log "  es_input.cfg updated"
fi

# RetroArch config
if [ -f "$SCRIPT_DIR/config/retroarch.cfg" ]; then
    mkdir -p "$SD/home/archr/.config/retroarch"
    cp "$SCRIPT_DIR/config/retroarch.cfg" "$SD/home/archr/.config/retroarch/retroarch.cfg"
    log "  retroarch.cfg updated"
fi

# Hotkey daemon + ES info bar scripts
if [ -f "$SCRIPT_DIR/scripts/archr-hotkeys.py" ]; then
    install -m 755 "$SCRIPT_DIR/scripts/archr-hotkeys.py" "$SD/usr/local/bin/archr-hotkeys.py"
    log "  archr-hotkeys.py updated"
fi
if [ -f "$SCRIPT_DIR/scripts/current_volume" ]; then
    install -m 755 "$SCRIPT_DIR/scripts/current_volume" "$SD/usr/local/bin/current_volume"
    log "  current_volume updated"
fi
if [ -f "$SCRIPT_DIR/scripts/current_brightness" ]; then
    install -m 755 "$SCRIPT_DIR/scripts/current_brightness" "$SD/usr/local/bin/current_brightness"
    log "  current_brightness updated"
fi

# gamecontrollerdb
if [ -f "$SCRIPT_DIR/config/gamecontrollerdb.txt" ]; then
    mkdir -p "$SD/etc/archr"
    cp "$SCRIPT_DIR/config/gamecontrollerdb.txt" "$SD/etc/archr/"
    log "  gamecontrollerdb.txt updated"
fi

# Autologin approach — ES needs real VT session for DRM master access
if [ -f "$SD/etc/systemd/system/emulationstation.service" ]; then
    rm -f "$SD/etc/systemd/system/emulationstation.service"
    rm -f "$SD/etc/systemd/system/multi-user.target.wants/emulationstation.service"
    log "  Old emulationstation.service removed"
fi

rm -f "$SD/etc/systemd/system/getty@tty1.service"

mkdir -p "$SD/etc/systemd/system/getty@tty1.service.d"
cat > "$SD/etc/systemd/system/getty@tty1.service.d/autologin.conf" << 'AL_EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin archr --noclear %I $TERM
AL_EOF
log "  getty@tty1 autologin configured"

cat > "$SD/etc/systemd/system/archr-boot-setup.service" << 'SETUP_EOF'
[Unit]
Description=Arch R Boot Setup (governors + DRM permissions)
After=systemd-modules-load.service
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'chmod 666 /dev/dri/* 2>/dev/null; echo performance > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null; echo performance > /sys/devices/platform/ff400000.gpu/devfreq/ff400000.gpu/governor 2>/dev/null; echo dmc_ondemand > /sys/devices/platform/dmc/devfreq/dmc/governor 2>/dev/null; true'

[Install]
WantedBy=multi-user.target
SETUP_EOF
ln -sf /etc/systemd/system/archr-boot-setup.service \
    "$SD/etc/systemd/system/multi-user.target.wants/archr-boot-setup.service"
log "  archr-boot-setup.service installed"

cat > "$SD/home/archr/.bash_profile" << 'PROFILE_EOF'
# Arch R: Auto-launch EmulationStation on tty1
# SSH and serial sessions (tty2+) get a normal shell
if [ "$(tty)" = "/dev/tty1" ]; then
    exec /usr/bin/emulationstation/emulationstation.sh
fi
PROFILE_EOF
chown 1001:1001 "$SD/home/archr/.bash_profile"
log "  .bash_profile installed (ES auto-launch on tty1)"

ES_SETTINGS="$SD/home/archr/.emulationstation/es_settings.cfg"
if [ -f "$ES_SETTINGS" ] && grep -q '<settings>' "$ES_SETTINGS"; then
    sed -i 's|<settings>|<config>|; s|</settings>|</config>|' "$ES_SETTINGS"
    log "  es_settings.cfg fixed (<settings> → <config>)"
fi

chown -R 1001:1001 "$SD/home/archr"

# Install runtime packages
cat > "$SD/tmp/install-runtime.sh" << 'RUNTIME_EOF'
#!/bin/bash
pacman() { command pacman --disable-sandbox "$@"; }
pacman -S --noconfirm --needed python-evdev brightnessctl 2>/dev/null || true
RUNTIME_EOF
chmod +x "$SD/tmp/install-runtime.sh"
chroot "$SD" /tmp/install-runtime.sh
rm -f "$SD/tmp/install-runtime.sh"
log "  Runtime packages installed (python-evdev, brightnessctl)"

#------------------------------------------------------------------------------
# Step 7: Cleanup build deps
#------------------------------------------------------------------------------
log ""
log "Step 7: Cleaning up build dependencies..."

cat > "$SD/tmp/cleanup-es.sh" << 'CLEAN_EOF'
#!/bin/bash
pacman() { command pacman --disable-sandbox "$@"; }
for pkg in cmake eigen gcc make binutils autoconf automake \
           fakeroot patch bison flex m4 libtool texinfo; do
    pacman -Rdd --noconfirm "$pkg" 2>/dev/null || true
done
pacman -Scc --noconfirm
CLEAN_EOF
chmod +x "$SD/tmp/cleanup-es.sh"
chroot "$SD" /tmp/cleanup-es.sh
rm -f "$SD/tmp/cleanup-es.sh"

log "  Build deps cleaned"

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
log ""
log "=== EmulationStation Rebuild Complete ==="
log ""
log "GL rendering pipeline:"
log "  ES (Desktop GL 2.1) → gl4es (translate) → GLES 2.0 → Panfrost (Mali-G31 GPU)"
log ""
log "Changes applied:"
log "  - gl4es installed (/usr/lib/gl4es/ — Desktop GL → GLES 2.0 translation)"
log "  - ES rebuilt with Desktop GL mode (Renderer_GL21.cpp)"
log "  - gl4es EGL wrapper intercepts context creation → GLES 2.0"
log "  - SDL3 rebuilt with KMSDRM support"
log "  - Autologin + boot services configured"
log ""
log "Eject the SD card safely and test on the R36S!"
