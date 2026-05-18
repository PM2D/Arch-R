# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2024-present ArchR (https://github.com/archr-linux/Arch-R)

PKG_NAME="compat-x264"
PKG_VERSION="cde9a93"
PKG_SHA256="239f1d36dbe672a436a46098cb24d15e90df4a5eafda947acaa9d0cccd92c13e"
PKG_LICENSE="GPL-2.0"
PKG_SITE="https://www.videolan.org/developers/x264.html"
PKG_URL="https://code.videolan.org/videolan/x264/-/archive/${PKG_VERSION}/x264-${PKG_VERSION}.tar.gz"
PKG_DEPENDS_TARGET="toolchain"
PKG_LONGDESC="x264 git rev cde9a93 (libx264.so.160) for PortMaster compat layer."
PKG_TOOLCHAIN="manual"
PKG_BUILD_FLAGS="-cfg-libs"

configure_target() {
  cd ${PKG_BUILD}
  ./configure \
    --host=${TARGET_NAME} \
    --cross-prefix=${TARGET_PREFIX} \
    --sysroot=${SYSROOT_PREFIX} \
    --prefix=/usr \
    --enable-shared \
    --disable-static \
    --disable-cli \
    --disable-opencl \
    --disable-asm
}

makeinstall_target() {
  make DESTDIR=${INSTALL} install-lib-shared

  mkdir -p ${INSTALL}/usr/lib/compat
  if compgen -G "${INSTALL}/usr/lib/libx264.so*" > /dev/null; then
    cp -a ${INSTALL}/usr/lib/libx264.so.160* ${INSTALL}/usr/lib/compat/
  fi

  rm -rf ${INSTALL}/usr/include
  rm -rf ${INSTALL}/usr/lib/pkgconfig
  rm -f  ${INSTALL}/usr/lib/libx264*
}
