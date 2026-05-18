# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2024-present ArchR (https://github.com/archr-linux/Arch-R)

PKG_NAME="portmaster-compat-libs"
PKG_VERSION="1.0"
PKG_ARCH="aarch64"
PKG_LICENSE="GPL-2.0"
PKG_SITE="https://github.com/archr-linux/Arch-R"
PKG_URL=""
PKG_DEPENDS_TARGET="toolchain compat-codec2 compat-x264 compat-x265"
PKG_LONGDESC="Meta-pacote: agrega libcodec2.so.0.9 + libx264.so.160 + libx265.so.192 (SONAMEs Debian 11/darkOS exigidos pelo PortMaster_CFW.md) compilados do upstream para /usr/lib/compat."
PKG_TOOLCHAIN="manual"
PKG_SECTION="virtual"

unpack() {
  : # Sem fontes proprias; tudo vem via PKG_DEPENDS_TARGET.
}

makeinstall_target() {
  : # Instalacao real e feita pelos pacotes compat-* dependencias.
}
