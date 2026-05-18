# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2024-present ArchR (https://github.com/archr-linux/Arch-R)

PKG_NAME="compat-x265"
PKG_VERSION="3.4"
PKG_SHA256="7f2771799bea0f53b5ab47603d5bea46ea2a221e047a7ff398115e9976fd5f86"
PKG_LICENSE="GPL-2.0"
PKG_SITE="https://www.videolan.org/developers/x265.html"
PKG_URL="https://bitbucket.org/multicoreware/x265_git/get/${PKG_VERSION}.tar.gz"
PKG_DEPENDS_TARGET="toolchain"
PKG_LONGDESC="x265 v3.4 (libx265.so.192) for PortMaster compat layer."
PKG_TOOLCHAIN="manual"
PKG_BUILD_FLAGS="-cfg-libs"

# bitbucket /get/<tag>.tar.gz extrai para multicoreware-x265_git-<commit>/.
# O CMakeLists.txt esta em source/.

configure_target() {
  cd ${PKG_BUILD}
  if [ -d source ]; then
    SRC_SUBDIR="source"
  else
    SRC_SUBDIR="$(ls -d */source 2>/dev/null | head -1)"
  fi

  mkdir -p build-target
  cd build-target

  cmake ${TARGET_CMAKE_OPTS} \
        -DENABLE_SHARED=ON \
        -DENABLE_CLI=OFF \
        -DENABLE_PIC=ON \
        -DENABLE_ASSEMBLY=OFF \
        -DHIGH_BIT_DEPTH=OFF \
        ../${SRC_SUBDIR}
}

make_target() {
  cd ${PKG_BUILD}/build-target
  make ${MAKEFLAGS}
}

makeinstall_target() {
  cd ${PKG_BUILD}/build-target
  make install DESTDIR=${INSTALL}

  mkdir -p ${INSTALL}/usr/lib/compat
  if compgen -G "${INSTALL}/usr/lib/libx265.so*" > /dev/null; then
    cp -a ${INSTALL}/usr/lib/libx265.so.192* ${INSTALL}/usr/lib/compat/
  fi

  rm -rf ${INSTALL}/usr/include
  rm -rf ${INSTALL}/usr/share
  rm -rf ${INSTALL}/usr/lib/pkgconfig
  rm -f  ${INSTALL}/usr/lib/libx265*
}
