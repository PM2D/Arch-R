# SPDX-License-Identifier: GPL-2.0
# Copyright (C) 2024-present ArchR (https://github.com/archr-linux/Arch-R)

. ${ROOT}/packages/virtual/debug/package.mk

PKG_DEPENDS_TARGET+=" nvtop apitrace valgrind vim"

# strace 6.19 quebra apenas em devices SM8650|SM8550|SM8250|H700 (case do
# packages/debug/strace/package.mk). Demais devices, incluindo RK3326,
# recebem strace 6.17 e funcionam normalmente.
case "${DEVICE}" in
  SM8650|SM8550|SM8250|H700)
    PKG_DEPENDS_TARGET=${PKG_DEPENDS_TARGET//"strace"/}
    ;;
esac

# ltrace nao foi adicionado porque o upstream esta abandonado desde
# 0.7.3 (2013), nao tem suporte estavel a aarch64 e os mantenedores
# do Debian/Alpine reportam falhas com glibc moderna. Ports que
# precisem de tracing de symbol-level devem usar gdb (presente) ou
# perf trace.
