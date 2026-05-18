# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2024-present ArchR (https://github.com/archr-linux/Arch-R)

PKG_NAME="vim"
PKG_VERSION="9.1.0"
PKG_SHA256="ddb435f6e386c53799a3025bdc5a3533beac735a0ee596cb27ada97366a1c725"
PKG_LICENSE="VIM"
PKG_SITE="http://www.vim.org/"
PKG_URL="https://github.com/vim/vim/archive/v${PKG_VERSION}.tar.gz"
PKG_DEPENDS_TARGET="toolchain ncurses"
PKG_LONGDESC="Vim is a highly configurable text editor built to enable efficient text editing."
PKG_BUILD_FLAGS="-sysroot -cfg-libs"

PKG_CONFIGURE_OPTS_TARGET="vim_cv_getcwd_broken=no \
                           vim_cv_memmove_handles_overlap=yes \
                           vim_cv_stat_ignores_slash=yes \
                           vim_cv_terminfo=yes \
                           vim_cv_tgetent=zero \
                           vim_cv_toupper_broken=no \
                           vim_cv_tty_group=world \
                           vim_cv_tty_mode=0620 \
                           ac_cv_sizeof_int=4 \
                           ac_cv_small_wchar_t=no \
                           --datarootdir=/usr/share \
                           --disable-canberra \
                           --disable-nls \
                           --enable-selinux=no \
                           --enable-gui=no \
                           --with-compiledby=ArchR \
                           --with-features=normal \
                           --with-tlib=ncursesw \
                           --without-x"

pre_configure_target() {
  cd ..
  rm -rf .${TARGET_NAME}
  # tgetent vive em libtinfow.so. libncursesw.so so o referencia via
  # DT_NEEDED, e com `-Wl,--as-needed` o ld dropa -lncursesw quando o
  # conftest do configure procura tgetent diretamente. Linkamos -ltinfow
  # explicito para que o symbol seja resolvido na configure-time.
  export LIBS="-ltinfow ${LIBS}"
}

post_makeinstall_target() {
  # Trim runtime to the bare minimum: keep colors/syntax/indent, drop
  # docs/tutorials/spell files. PortMaster_CFW.md only requires a
  # working `vim` binary; the full ~30MB runtime would balloon the
  # image. Strip language packs we don't ship locales for.
  if [ -d "${INSTALL}/usr/share/vim/vim91" ]; then
    rm -rf ${INSTALL}/usr/share/vim/vim91/doc
    rm -rf ${INSTALL}/usr/share/vim/vim91/tutor
    rm -rf ${INSTALL}/usr/share/vim/vim91/spell
    rm -rf ${INSTALL}/usr/share/vim/vim91/lang
    rm -rf ${INSTALL}/usr/share/vim/vim91/keymap
    rm -rf ${INSTALL}/usr/share/vim/vim91/print
    rm -rf ${INSTALL}/usr/share/vim/vim91/tools
  fi
  rm -rf ${INSTALL}/usr/share/applications
  rm -rf ${INSTALL}/usr/share/icons
  rm -rf ${INSTALL}/usr/share/man

  # Drop xxd (we already have busybox alternatives if needed) and
  # symlink ex/view/vimdiff to vim; saves a few MB of duplicates.
  rm -f ${INSTALL}/usr/bin/xxd
  rm -f ${INSTALL}/usr/bin/ex ${INSTALL}/usr/bin/view ${INSTALL}/usr/bin/vimdiff ${INSTALL}/usr/bin/rvim ${INSTALL}/usr/bin/rview
  ln -sf vim ${INSTALL}/usr/bin/vi
}
