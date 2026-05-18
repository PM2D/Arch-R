# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2024-present ArchR (https://github.com/archr-linux/Arch-R)

PKG_NAME="compat-codec2"
PKG_VERSION="0.9.2"
PKG_SHA256="19181a446f4df3e6d616b50cabdac4485abb9cd3242cf312a0785f892ed4c76c"
PKG_LICENSE="LGPL-2.1"
PKG_SITE="https://github.com/drowe67/codec2"
PKG_URL="https://snapshot.debian.org/archive/debian/20191223T030135Z/pool/main/c/codec2/codec2_0.9.2.orig.tar.gz"
PKG_DEPENDS_TARGET="toolchain"
PKG_LONGDESC="Codec2 v0.9.2 (libcodec2.so.0.9) for PortMaster compat layer."
PKG_TOOLCHAIN="manual"
PKG_BUILD_FLAGS="-cfg-libs"

# codec2 0.9.2 + Ninja gera build.ninja com $ nao escapado (bug do gerador
# Ninja desta versao especifica). Forcamos Unix Makefiles via cmake manual.

configure_target() {
  cd ${PKG_BUILD}
  mkdir -p build-target
  cd build-target
  cmake -G "Unix Makefiles" \
        ${TARGET_CMAKE_OPTS} \
        -DBUILD_SHARED_LIBS=ON \
        -DUNITTEST=OFF \
        ..
}

make_target() {
  cd ${PKG_BUILD}/build-target
  make ${MAKEFLAGS}
}

makeinstall_target() {
  cd ${PKG_BUILD}/build-target
  make install DESTDIR=${INSTALL}

  mkdir -p ${INSTALL}/usr/lib/compat
  if compgen -G "${INSTALL}/usr/lib/libcodec2.so*" > /dev/null; then
    cp -a ${INSTALL}/usr/lib/libcodec2.so.0.9* ${INSTALL}/usr/lib/compat/
  fi

  rm -rf ${INSTALL}/usr/include
  rm -rf ${INSTALL}/usr/share
  rm -rf ${INSTALL}/usr/bin
  rm -rf ${INSTALL}/usr/lib/cmake
  rm -rf ${INSTALL}/usr/lib/pkgconfig
  rm -f  ${INSTALL}/usr/lib/libcodec2*
}
