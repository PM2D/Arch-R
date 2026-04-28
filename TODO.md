# TODO — Curadoria de Performance do SO

> **Status (2026-04-18):** FASE 0-3 investigadas e implementadas. Itens marcados com ✅ estão concluídos.

**Hardware alvo:** Handheld open source com SoC **Rockchip RK3326** (4× Cortex-A35 @ 1.3–1.5 GHz, in-order dual-issue, 256KB L2 compartilhado), GPU **Mali-G31 MP2** (Bifrost v9), **1GB DDR3/DDR3L**, storage **microSD**, passivo (sem fan).

**Referências de comparação:**
- dArkOS: `/media/disco-local/dArkOS/`
- ROCKNIX: `/home/douglas/Documentos/distribution/`

**Princípio guia:** nenhuma feature pode ser removida (WiFi, BT, etc.) — tudo o que não é essencial durante gameplay deve ser *socket-activated* ou *on-demand*, não deletado.

**Convenção de tags:**
- `[PERF]` — item que altera FPS/frametime/latência direta
- `[FOOTPRINT]` — item que altera consumo de RAM, CPU idle, armazenamento
- `[AMBOS]` — item que afeta os dois
- `[INFRA]` — infraestrutura de medição/decisão, não é ganho em si

**Convenção de metas numéricas:** todas as metas deste documento são **hipóteses a validar por benchmark**, não garantias. Se a hipótese não se confirmar, o item vira investigação, não ação cega.

---

# FASE 0 — Pré-requisitos bloqueadores

Sem estes dois itens, qualquer mudança subsequente é chute.

---

## 0. ✅ Sanity check de release build `[INFRA][PERF]`

**Objetivo:** garantir que nada crítico no pipeline está compilado/executado em modo de desenvolvimento. É o ganho mais barato e invisível — se algum pacote central estiver em debug, o ceiling de todos os outros itens cai junto.

### 0.1 Kernel

```bash
# Extrair config do kernel em execução
zcat /proc/config.gz 2>/dev/null || cat /boot/config-$(uname -r)
```

**Checks obrigatórios:**

| Config | Esperado | Impacto |
|--------|----------|---------|
| `CONFIG_DEBUG_KERNEL` | `n` ou mínimo | overhead generalizado |
| `CONFIG_DEBUG_INFO` | off em release (ou em pkg separado) | tamanho |
| `CONFIG_LOCKDEP`, `CONFIG_PROVE_LOCKING` | `n` | overhead pesado |
| `CONFIG_DEBUG_LOCK_ALLOC` | `n` | |
| `CONFIG_KASAN`, `CONFIG_KMEMLEAK`, `CONFIG_KFENCE` | `n` | overhead + RAM |
| `CONFIG_SLUB_DEBUG_ON` | `n` (`CONFIG_SLUB_DEBUG=y` ok) | |
| `CONFIG_FTRACE`, `CONFIG_FUNCTION_TRACER` | `n` ou ao menos inativo | |
| `CONFIG_PREEMPT_TRACER`, `CONFIG_IRQSOFF_TRACER` | `n` | |
| `CONFIG_SCHEDSTATS` | `n` | |
| `CONFIG_DEBUG_PREEMPT` | `n` | |

**Em runtime:**
```bash
cat /sys/kernel/debug/tracing/tracing_on     # esperado: 0
cat /sys/kernel/debug/tracing/current_tracer # esperado: nop
dmesg | grep -iE "debug|warn|slub" | head -50
```

### 0.2 Mesa

No PKGBUILD / meson:
- `-Dbuildtype=release` (NÃO `debugoptimized`, NÃO `debug`)
- `-Db_ndebug=true` (asserts off)
- `-Db_lto=true` (opcional, recomendado)

Variáveis de ambiente que **jamais** podem estar setadas em produção:
```bash
env | grep -iE "MESA_DEBUG|MESA_VERBOSE|MESA_LOG|GALLIUM_DUMP|PAN_MESA_DEBUG|LIBGL_DEBUG"
```

Se `PAN_MESA_DEBUG` estiver setado, auditar o valor:
- `sync` → serialização total, perde ~30% FPS
- `trace` → captura de cada draw call
- `nocrc` → desliga transaction elimination (vai contra o item 4)

### 0.3 RetroArch

No configure/PKGBUILD:
- `--disable-debug`
- `--enable-lto` (se suportado)
- Nunca: `--enable-debug`, `--enable-profile`, `--enable-asan|ubsan|tsan`

Em runtime:
```bash
retroarch --version   # sem flags HAVE_DEBUG
```

Flags que nunca devem estar no `retroarch.cfg` de produção:
```
log_verbosity = "false"
perfcnt_enable = "false"    # só durante benchmark
libretro_log_level = "3"    # error apenas
frontend_log_level = "3"
```

### 0.4 Cores libretro

```bash
for core in /usr/lib/libretro/*.so; do
  echo "=== $core ==="
  file "$core" | grep -o "not stripped\|stripped"
  nm -D "$core" 2>/dev/null | grep -iE "asan|ubsan|tsan|msan" | head -3
  du -h "$core"
done
```

Esperado: `stripped`, sem símbolos de sanitizer, tamanho razoável (cores em debug são 2–5x maiores).

### 0.5 Emuladores standalone

Mesma auditoria para PPSSPP, Dolphin, DuckStation, Flycast etc.:
- `CMAKE_BUILD_TYPE=Release` (ou `RelWithDebInfo` com debug em pkg separado)
- Nunca `Debug`
- Binário `stripped`

```bash
for bin in /usr/bin/{ppsspp,dolphin-emu,duckstation,flycast}; do
  [ -x "$bin" ] || continue
  echo "=== $bin ==="
  file "$bin" | grep -o "not stripped\|stripped"
  du -h "$bin"
done
```

### 0.6 Frontend

```bash
find /etc /opt -name "*.conf" -o -name "*.cfg" 2>/dev/null | \
  xargs grep -iE "log.*level|verbose|debug" 2>/dev/null | head -20
```

Muitos frontends vêm com log level `DEBUG` no default.

### 0.7 Comparação lateral com dArkOS/ROCKNIX

Gerar relatório de flags e buildtypes usados pelas distros concorrentes — às vezes eles descobriram algo que não está documentado, e vice-versa.

**Critério de aceitação:**
- Documento `/docs/build-audit.md` com checklist preenchido para cada subitem.
- Zero pacotes em buildtype `Debug`.
- Zero símbolos de sanitizer em binários de produção.
- Zero env vars de debug em `/etc/environment`, profiles, systemd units.

**Por que vem antes do benchmark:** se baseline for medido com Mesa `debugoptimized` ou core com asserts ativos, toda decisão subsequente parte de referência errada.

---

## 1. ✅ Baseline de benchmark reproduzível `[INFRA]`

**Objetivo:** script que rode cenários fixos e emita métricas completas para comparar nosso SO vs dArkOS vs ROCKNIX, de forma rastreável e reproduzível.

### 1.1 Cenários fixos (save states versionados no repo)

| Sistema | Jogo | Cena | Emulador primário | Por que importa |
|---------|------|------|-------------------|-----------------|
| SNES | Super Mario World | Yoshi's Island 1 | Snes9x2010 | smoke test, 60fps trivial |
| Mega Drive | Sonic 2 | Chemical Plant loop | Genesis Plus GX | scroll horizontal |
| GBA | Advance Wars 2 | mid-game map | mGBA | tile-heavy |
| PS1 | Crash Bandicoot 1 | Wumpa Island praia | Beetle PSX HW | texture streaming |
| PS1 | Tekken 3 | seleção | Beetle PSX HW | smoke test PS1 |
| N64 | Super Mario 64 | Bob-omb topo | Mupen64Plus-Next | draw distance |
| N64 | Zelda OoT | Hyrule Field meio-dia | Mupen64Plus-Next | fog + partículas |
| PSP | GTA VCS | intro cinemática | PPSSPP | cutscene streaming |
| PSP | Daxter | fase inicial | PPSSPP | FPS sustentado |
| DC | Soul Calibur | character select | Flycast | smoke test DC |
| DC | Crazy Taxi | start of level | Flycast | stress DC |

### 1.2 Matriz explícita libretro vs standalone

Comparação justa exige caminho equivalente. Distros tomam decisões diferentes — ROCKNIX pode usar PPSSPP libretro, dArkOS standalone (ou vice-versa). Misturar caminhos gera benchmark injusto.

Para cada cenário relevante, benchmarkar **ambos os caminhos** quando aplicável:

| Core/Emulador | Libretro | Standalone |
|---------------|----------|------------|
| PPSSPP | `ppsspp_libretro.so` | binário `ppsspp` |
| Beetle PSX HW | `mednafen_psx_hw_libretro.so` | — |
| DuckStation | `swanstation_libretro.so` | binário `duckstation` |
| Mupen64Plus-Next | `mupen64plus_next_libretro.so` | `mupen64plus` standalone |
| Flycast | `flycast_libretro.so` | binário `flycast` |
| Dolphin | `dolphin_libretro.so` (se existir) | `dolphin-emu` |

**Saída esperada:** CSV separa path libretro vs standalone, não mistura. A comparação "nosso SO vs dArkOS no PSP" precisa ter as duas linhas quando ambas as distros expõem os dois caminhos.

### 1.3 Instrumentação — métricas por run

Coletar durante 60s por cenário, 5 runs cada.

**Frametime:**
```bash
# retroarch.cfg do bench (não o de produção)
video_frame_log = "true"
perfcnt_enable = "true"
```

**PSI (Pressure Stall Information) — crítico em 1GB:**

O problema real em 1GB raramente é "faltou RAM". É "entrou em pressão, kswapd ativo, frametime explodiu". PSI captura; MemAvailable não.

```bash
while [ running ]; do
  date +%s.%N
  cat /proc/pressure/cpu      # avg10, avg60, avg300
  cat /proc/pressure/memory   # some + full
  cat /proc/pressure/io
  sleep 1
done > psi.log
```

**Eventos de reclaim/OOM:**
```bash
dmesg -w > dmesg-during-bench.log &
# Filtrar: oom, kswapd, pagealloc, reclaim, compact_fail
```

**Contadores de sistema:**
```bash
vmstat 1 60 > vmstat.log
# si/so (swap in/out), wa (iowait), st (stolen), free, buff, cache
```

**Frequências CPU/GPU/DDR + temperatura:**
```bash
while [ running ]; do
  for cpu in /sys/devices/system/cpu/cpu[0-3]/cpufreq/scaling_cur_freq; do
    cat "$cpu"
  done
  cat /sys/class/devfreq/*gpu*/cur_freq
  cat /sys/class/devfreq/*dmc*/cur_freq
  cat /sys/class/thermal/thermal_zone0/temp
  sleep 1
done > freq-therm.log
```

**Input latency:** câmera 240fps + LED no botão + evento na tela (método RetroArch), executado separadamente, não por run.

### 1.4 Metadados obrigatórios de cada run

Sem isto, um benchmark "bom" vira folklore irreproduzível.

| Campo | Comando |
|-------|---------|
| `kernel_release` | `uname -r` |
| `kernel_commit` | `git -C <kernel-src> rev-parse HEAD` |
| `mesa_version` | `pacman -Qi mesa` |
| `mesa_commit` | do PKGBUILD ou `glxinfo` |
| `retroarch_version` | `retroarch --version` |
| `core_name` | path do core |
| `core_version` | metadata do .so |
| `emulator_standalone_version` | `ppsspp --version` etc. |
| `rom_sha256` | `sha256sum <rom>` |
| `bios_sha256` | `sha256sum <bios>` |
| `save_state_sha256` | idem |
| `power_source` | `/sys/class/power_supply/*/online` |
| `battery_charging` | `/sys/class/power_supply/*/status` |
| `battery_percent` | `/sys/class/power_supply/*/capacity` |
| `ambient_temp_c` | input manual |
| `microsd_model` | `cat /sys/block/mmcblk0/device/{name,manfid,oemid,cid}` |
| `microsd_speed_class` | `dmesg \| grep mmcblk0` ou input manual |
| `cpu_governor` | `cat /sys/.../scaling_governor` |
| `cpu_max_freq` | `scaling_max_freq` |
| `gpu_governor` | `/sys/class/devfreq/*gpu*/governor` |
| `dmc_governor` | `/sys/class/devfreq/*dmc*/governor` |
| `zram_active` | `swapon` |
| `zram_algo` | `cat /sys/block/zram0/comp_algorithm` |
| `thp_enabled` | `cat /sys/kernel/mm/transparent_hugepage/enabled` |
| `cma_total_kb` | `grep CmaTotal /proc/meminfo` |
| `cma_free_kb` | `grep CmaFree /proc/meminfo` |
| `memavailable_kb_start` | `grep MemAvailable /proc/meminfo` |
| `bench_script_commit` | `git rev-parse HEAD` do repo do bench |

Juntar em JSON de metadados + CSV de frametime.

### 1.5 Formato de saída

```
results/
├── YYYYMMDD-HHMMSS-<distro>-<cenario>-<path>/
│   ├── meta.json           # metadados da 1.4
│   ├── frametime.csv       # timestamp, frame_time_ms
│   ├── psi.log             # 1Hz sampling
│   ├── freq-therm.log
│   ├── vmstat.log
│   ├── dmesg.log
│   └── summary.json        # p50, p95, p99, fps_mean, max_temp, mem_pressure_pct
```

### 1.6 Dashboard de comparação

Script que:
1. Carrega `summary.json` de N runs
2. Agrupa por `(distro, cenario, core_path)`
3. Emite pivot com medianas + IQR
4. Flagga runs com alta variância (σ/μ > 10%) para re-rodar
5. Gera gráficos de frametime density + PSI timeline

**Critério:** `./bench.sh <cenario> <distro>` grava resultados versionados. `./compare.py --cenario psp_vcs` gera tabela entre distros.

**Risco:** subestimar esforço. Planejar 2–3 dias. É o maior investimento de ROI do projeto.

---

# FASE 1 — TIER S (ganhos hipotéticos de 10%+)

---

## 2. ✅ zram com zstd `[AMBOS]`

**Hipótese:** em 1GB, PSP/N64/DC entram em pressão de memória que causa spikes de frametime. zram resolve sem I/O em microSD.

**Validação:** PSI `memory.some.avg60` durante PPSSPP/GTA VCS cai ≥50% vs baseline sem zram; frametime p99 estável ou melhor. Se a pressão já é baixa sem zram no cenário, ganho pode ser zero — investigar quais cenas realmente causam pressão.

**Auditar primeiro:**
```bash
cat /proc/swaps
cat /sys/block/zram0/comp_algorithm 2>/dev/null
zramctl
sysctl vm.swappiness vm.vfs_cache_pressure vm.page-cluster

grep -r "zram\|swapp\|compcache" /media/disco-local/dArkOS/ /home/douglas/Documentos/distribution/ 2>/dev/null
```

**Ação:**
- Device zram com **zstd**, tamanho ~50% da RAM (512MB comprimido ≈ 170MB físicos em razão 1:3). Referência: [ArchWiki zram](https://wiki.archlinux.org/title/Zram).
- **Desabilitar zswap** (intercepta antes do zram). `zswap.enabled=0` na cmdline.
- Priority 100 no swapon.
- **Proibido** swap em microSD.

```ini
# /etc/sysctl.d/99-handheld.conf
vm.swappiness = 100
vm.vfs_cache_pressure = 50
vm.page-cluster = 0
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.dirty_expire_centisecs = 3000
vm.dirty_writeback_centisecs = 1500
```

**Risco:** CPU de compressão compete com emulador. Se p99 piorar em cenas leves, reduzir tamanho ou trocar zstd → lz4.

---

## 3. ✅ DDR frequency scaling (dmc devfreq) `[PERF]`

**Hipótese:** DDR3 é gargalo #1 de bandwidth do RK3326. DMC preso em freq baixa penaliza cenas texture-heavy em PS1/N64/PSP.

**Validação:** FPS em Crash Wumpa — hipótese de +5% a +15% com governor `performance` vs `simple_ondemand` conservador. Se não render, verificar `trans_stat` — governor pode estar escalando, mas o workload não pressiona DDR o suficiente para mostrar diferença.

**Auditar:**
```bash
ls /sys/class/devfreq/
cat /sys/class/devfreq/*dmc*/governor
cat /sys/class/devfreq/*dmc*/available_frequencies
cat /sys/class/devfreq/*dmc*/cur_freq
cat /sys/class/devfreq/*dmc*/trans_stat

find /media/disco-local/dArkOS/ -name "*.dts*" | xargs grep -l "dmc\|memory-controller" 2>/dev/null
find /home/douglas/Documentos/distribution/ -name "*.dts*" | xargs grep -l "dmc\|memory-controller" 2>/dev/null
```

**Ação:**
- `dmc_ondemand` com upthreshold ~40% OU `performance` via hook do frontend durante gameplay.
- Comparar OPPs de DDR no DT — às vezes há 933MHz escondido.

**Risco:** instabilidade em DDR alto. `memtester` 30min antes de promover.

---

## 4. ✅ Mesa atualizado + Panfrost Transaction Elimination `[PERF]`

**Hipótese:** Mesa 25.0+ habilita CRC por padrão, reduzindo bandwidth ao pular write-out de tiles inalterados. Em DDR3 apertado, ganho real. Referência: [Mesa 25.0 PanVK update](https://www.collabora.com/news-and-blog/news-and-events/mesa-25-panvk-moves-towards-production-quality.html).

**Validação:** hipótese de +3% a +8% FPS em cenas 3D com frames similares consecutivos (Zelda OoT parado em Hyrule Field). Se regredir, `PAN_MESA_DEBUG=nocrc` pode estar setado em algum lugar (auditar, vide item 0.2).

**Auditar:**
```bash
glxinfo -B 2>/dev/null | grep -i mesa
pacman -Qi mesa | grep Version

grep -rI "PAN_MESA_DEBUG" /etc/ /usr/share/ ~/.config/
env | grep -iE "PAN_|MESA_"
```

**Ação:**
- Mesa ≥ 25.0, compilado em release (item 0.2).
- Shader cache persistente:
  ```bash
  export MESA_SHADER_CACHE_DIR=/var/cache/mesa_shader_cache
  export MESA_SHADER_CACHE_MAX_SIZE=256MB
  ```
- `MESA_GLTHREAD=true` — testar per-core, regride em cores single-thread.
- Pré-aquecer cache em ROMs populares no primeiro boot.

---

## 5. Panfrost kernel driver — patch de powerup sequence `[PERF]`

**Hipótese:** patch de 2025 que reordena pd→reset→clock corrige comportamento conforme manual Mali. Testado em RK3326 Powkiddy RGB10X. Referência: [patch dri-devel](https://www.mail-archive.com/dri-devel@lists.freedesktop.org/msg541359.html).

**Validação:** estabilidade em suspend/resume; ausência de GPU hangs. Perf pode não mudar — foco é correção.

```bash
uname -r
grep -A 30 "panfrost_device_init" /path/to/kernel/drivers/gpu/drm/panfrost/panfrost_device.c
```

---

## 6. ✅ CMA / reserved-memory / carveouts `[FOOTPRINT][PERF]`

**Hipótese:** cada MB reservado em CMA é um MB a menos para userland em 1GB. SoCs Rockchip reservam 64–256MB típico. Reserva excessiva rouba RAM útil. Reserva insuficiente quebra video/VPU/GPU allocations.

**Validação:** MemAvailable em idle sobe ≥50MB após trim, sem quebrar playback V4L2 nem decode HEVC 1080p do frontend.

### 6.1 Auditar estado atual

```bash
grep -E "^Cma(Total|Free)" /proc/meminfo

mount -t debugfs none /sys/kernel/debug 2>/dev/null
for d in /sys/kernel/debug/cma/*/; do
  echo "=== $d ==="
  cat "$d/count"        # páginas totais
  cat "$d/used"         # páginas em uso
done

cat /sys/firmware/devicetree/base/reserved-memory/ranges 2>/dev/null
ls /sys/firmware/devicetree/base/reserved-memory/
```

### 6.2 Mapear reservas no DT em runtime

```bash
dtc -I fs /sys/firmware/devicetree/base > /tmp/runtime.dts
grep -A 5 "reserved-memory" /tmp/runtime.dts
grep -B 2 -A 10 "linux,cma\|shared-dma-pool\|no-map" /tmp/runtime.dts
```

**Reservas típicas em RK3326:**
- `linux,cma` global — 64–128MB comum; 256MB é exagero em 1GB
- `rockchip,drm-logo` — splash (pode sumir em release)
- `ramoops` — crash dump (pequeno, manter)
- VPU carveouts — verificar se são necessários ou se VPU usa CMA global

### 6.3 Comparar lateralmente

```bash
for DT in \
  /media/disco-local/dArkOS/boot/dtbs/rockchip/*rk3326*.dtb \
  /home/douglas/Documentos/distribution/boot/dtbs/rockchip/*rk3326*.dtb \
  /boot/dtbs/rockchip/*rk3326*.dtb; do
  [ -f "$DT" ] || continue
  echo "=== $DT ==="
  dtc -I dtb -O dts "$DT" 2>/dev/null | grep -B 2 -A 10 "linux,cma\|reserved-memory"
done
```

### 6.4 Ações possíveis

- **Reduzir CMA global** se `CmaFree` fica sempre alto (ex: 128MB reservado, 120MB livre = desperdício).
- **Remover carveouts de logo/splash** em release se não usados.
- **Consolidar** VPU/ISP carveouts em CMA compartilhada se possível.
- Configurar em cmdline: `cma=64M` ou DT override.

### 6.5 Validações pós-ajuste

Testar após cada mudança:
- Playback H.264 1080p no frontend — OK?
- V4L2 M2M decode (`ffmpeg -c:v h264_v4l2m2m`) — OK?
- GPU allocations grandes (PSP 2x internal) — sem falha?
- `dmesg | grep -iE "cma|dma|alloc fail"` — sem erros novos?

**Risco:** reserva insuficiente falha silenciosamente em decode. Testar playback intensivo antes de promover.

---

## 7. ✅ CFLAGS alinhados a Cortex-A35 `[PERF]`

**Hipótese:** A35 é in-order dual-issue, IPC baixo. Código genérico deixa 3–10% na mesa por core.

**Validação:** FPS em Sonic 2 Chemical Plant sobe ≥2% com `-O2 -flto -mtune=cortex-a35` vs `-O2` genérico. Se não, verificar se o build realmente absorveu as flags (`readelf -A` nos binários).

**`makepkg.conf`:**
```bash
CFLAGS="-march=armv8-a+crc+crypto -mtune=cortex-a35 -O2 -pipe -fno-plt -fstack-protector-strong"
CXXFLAGS="${CFLAGS}"
LDFLAGS="-Wl,-O1,--sort-common,--as-needed,-z,relro,-z,now"
MAKEFLAGS="-j$(nproc)"
```

**Observações:**
- **Não** `-O3` universal. L1I 32KB, L2 256KB; `-O3` infla binário e pressiona cache. Pontual após bench.
- **Não** `-mcpu=cortex-a35` em libs genéricas (quebra portabilidade).
- `-flto` em: mesa, retroarch, cores libretro, sdl2, ffmpeg, zlib-ng.

**Pacotes para recompilar:**
1. mesa (item 4)
2. retroarch
3. Cores libretro em uso
4. sdl2
5. ffmpeg com `--enable-neon --cpu=cortex-a35`
6. **zlib-ng** (substitui zlib, 10–30% em descompressão de ROMs zipadas)
7. zstd (para zram)

---

## 8. ✅ Device Tree diff profundo `[PERF][FOOTPRINT]`

**Hipótese:** DT é fonte comum de perf "misteriosa". Divergências entre distros raramente são acidentais.

**Validação:** `dt-findings.md` com N divergências categorizadas (cosmética / perf / estabilidade), cada uma com decisão registrada.

**Método:**
```bash
mkdir -p /tmp/dt-diff/{nosso,arkos,rocknix}
dtc -I dtb -O dts -o /tmp/dt-diff/nosso/board.dts /boot/dtbs/rockchip/*rk3326*.dtb
# Repetir para concorrentes

diff -u /tmp/dt-diff/nosso/board.dts /tmp/dt-diff/arkos/board.dts > /tmp/dt-diff/nosso-vs-arkos.patch
```

**Pontos:**
- `cpu0-opp-table` — 1.3GHz vs 1.5GHz?
- `gpu-opp-table` — freqs Mali-G31 (200/300/400/520/650)
- `dmc-opp-table` — DDR (786/933/1066)
- `thermal-zones` → trips + cooling-maps
- `regulator-*` → min/max-microvolt (margem de undervolt)
- `rockchip,pwm-regulator`
- `reserved-memory` — ver item 6

---

# FASE 2 — TIER A (ganhos hipotéticos de 3–10%)

---

## 9. ✅ I/O scheduler e bloco para microSD `[PERF]`

**Hipótese:** bfq + read_ahead alto reduz stutter em streaming de ROMs grandes.

**Validação:** load de ISO PSP GTA VCS cai ≥15%.

```bash
for d in /sys/block/mmcblk*; do
  echo "$d: $(cat $d/queue/scheduler)"
done

cat > /etc/udev/rules.d/60-mmcblk-scheduler.rules <<'EOF'
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/scheduler}="bfq"
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/iosched/low_latency}="1"
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/read_ahead_kb}="2048"
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/nr_requests}="128"
ACTION=="add|change", KERNEL=="mmcblk[0-9]*", ATTR{queue/rq_affinity}="2"
EOF
```

Mount: `noatime,nodiratime,commit=600,lazytime`. Manter ext4 (F2FS arriscado em microSD variável).

---

## 10. RetroArch em KMS/DRM puro `[FOOTPRINT][PERF]`

**Hipótese:** evitar compositor economiza 30–60MB residentes + buffer copy por frame.

**Validação:** MemAvailable em RetroArch fullscreen sobe ≥40MB vs modo com compositor.

```
video_driver = "drm"
video_context_driver = "kms"
```

Auditar: frontend está subindo X? Pode rodar em `cage` (Wayland kiosk) ou fbdev?

---

## 11. Render resolution sanity por core `[PERF]`

**Hipótese:** renderizar PSP em 2x (1920×1088) em painel 640×480 é desperdício puro.

Presets default:
- PPSSPP: `1x` em ≤480p, `1.5x` em 720p
- Beetle PSX HW: `1x`
- Mupen64Plus-Next: nativa (320x240 ou 640x480)
- Flycast: nativa (640×480)
- Dolphin/PCSX2: não aplicável em A35

**Ação:** `core-overrides/` versionado com presets conservadores por default.

---

## 12. ✅ Systemd trim cirúrgico `[FOOTPRINT]`

**Hipótese:** daemons socket-activated em vez de residentes liberam ≥60MB RSS sem remover funcionalidade.

**Validação:** RSS total de serviços residentes cai ≥60MB.

```bash
systemd-analyze blame > /tmp/blame-nosso.txt
systemctl list-units --state=running --type=service
```

**Alvos:**
- `ModemManager`, `cups`, `packagekit`, `tracker-*`, `geoclue`, `fwupd` → **mask**
- `avahi-daemon`, `bluetooth`, WiFi → **socket-activate**

Journal em RAM:
```ini
# /etc/systemd/journald.conf.d/handheld.conf
[Journal]
Storage=volatile
RuntimeMaxUse=16M
```

---

## 13. ✅ CPU governor + thermal trips `[PERF]`

**Hipótese:** sem fan, throttle precoce derruba perf sustentada. Trips conservadores herdados de smartphone.

**Validação:** 30min PSP mantém CPU ≥1.4GHz em ≥95% do tempo.

```bash
for z in /sys/class/thermal/thermal_zone*; do
  echo "=== $z ==="
  cat $z/type
  for t in $z/trip_point_*_temp; do
    echo "  $t: $(cat $t)"
  done
done
```

**Ação:**
- `performance` em gameplay via pre-launch hook; `schedutil` em idle.
- Comparar trips com dArkOS/ROCKNIX.
- Undervolt via `cpu-supply` no DT se houver margem (validar com stress-ng + memtester).

---

## 14. Vulkan (PanVK) — abordagem para Mali-G31 `[DECISÃO]`

**Situação:** PanVK conformante apenas em Mali-G610. Mali-G31 (Bifrost v9) = não-conformante. Mesa não expõe PanVK por padrão em G31.

**Três opções:**

- **A (default recomendado):** manter OpenGL ES, não expor Vulkan ao usuário, infra pronta.
- **B (opt-in):** toggle experimental, `PAN_I_WANT_A_BROKEN_VULKAN_DRIVER=1` sob demanda, documentar risco.
- **C (Zink pontual):** OpenGL sobre Vulkan, raramente ganha em G31.

Investigar o que dArkOS/ROCKNIX fazem:
```bash
grep -rI "vulkan\|PAN_I_WANT\|panvk" /media/disco-local/dArkOS/ /home/douglas/Documentos/distribution/ 2>/dev/null
```

**Critério:** decisão em `vulkan-decision.md`. Se B, lista de cores "funcionando"/"quebrados".

---

# FASE 3 — TIER B (qualidade e ganhos menores)

---

## 15. ✅ Input latency `[PERF]`

**Hipótese:** `CONFIG_HZ=1000` + polling 1000Hz + run-ahead 1–2 frames em cores leves reduz latência perceptível.

```bash
zcat /proc/config.gz | grep CONFIG_HZ=
cat /proc/bus/input/devices
```

RetroArch:
- `video_frame_delay` — testar 0–4 per-core
- `video_hard_sync = "true"` (custa CPU)
- Run-ahead: ON em SNES/GBA/MD/NES, OFF em PS1/N64/PSP/DC

---

## 16. Áudio — stack mínimo `[FOOTPRINT][PERF]`

**Hipótese:** ALSA direto economiza ~20MB vs PipeWire. Se PipeWire necessário, quantum 1024.

```ini
# /etc/pipewire/pipewire.conf.d/99-handheld.conf
default.clock.quantum = 1024
default.clock.min-quantum = 512
default.clock.max-quantum = 2048
```

**Validação:** sem crackle em 30min PSP. Latência áudio ≤96ms.

---

## 17. Locales, fonts, docs `[FOOTPRINT]`

**Hipótese:** ~300MB recuperados em microSD, menos pressão FS cache.

```ini
# /etc/pacman.conf
NoExtract = usr/share/locale/* !usr/share/locale/en* !usr/share/locale/pt_BR*
NoExtract = usr/share/man/* usr/share/doc/* usr/share/info/*
NoExtract = usr/share/gtk-doc/*
```

---

## 18. Per-game override infrastructure `[PERF]`

```
/opt/game-profiles/
├── system/
│   ├── psp/
│   │   ├── _default.conf
│   │   ├── ULUS10160.conf    # GTA VCS
│   │   └── ULUS10041.conf    # Daxter
```

Hook pre-launch aplica: cpufreq governor, dmc governor, GPU min_freq, RetroArch `--appendconfig`, Mesa env vars.

---

## 19. Frontend — lazy loading e cache `[FOOTPRINT][PERF]`

Auditar:
- Parse de gamelist.xml em lib ≥500 jogos
- Thumbnails lazy vs eager
- Preview videos via V4L2 M2M vs software
- Shaders de tema pesados

**Hipótese:** 2–5s de boot e 30–60MB de RAM.

---

## 20. Firmware Mali e V4L2 M2M `[PERF]`

```bash
dmesg | grep -i "mali\|panfrost\|firmware"
ls /lib/firmware/arm/mali/ 2>/dev/null

ffmpeg -hwaccels
ffmpeg -i preview.mp4 -c:v h264_v4l2m2m -f null -
```

Zero-copy DMA-BUF decoder→GPU→display.

---

# FASE 4 — Infraestrutura e meta

---

## 21. Repositório de comparativos `[INFRA]`

`/docs/comparativos/` versionado:
- `build-audit.md` (item 0)
- `dt-findings.md` (item 8)
- `cma-findings.md` (item 6)
- `sysctl-findings.md` — diff sysctl entre distros
- `service-audit.md` — daemons ativos por distro
- `cflags-audit.md` — flags por distro
- `mesa-version.md`
- `kernel-version.md`
- `vulkan-decision.md`

---

## 22. CI de performance `[INFRA]`

Quando item 1 maduro:
- Build → flash → bench → regressão em PR
- Alertar PRs que regridam p95 ≥3%

---

# Classificação rápida: perf direta vs footprint

| Item | Tag | Tier | Métrica principal |
|------|-----|------|-------------------|
| 0 | INFRA/PERF | 0 | ceiling do resto |
| 1 | INFRA | 0 | base de comparação |
| 2 | AMBOS | S | PSI memory + frametime p99 |
| 3 | PERF | S | FPS texture-heavy |
| 4 | PERF | S | FPS + bandwidth GPU |
| 5 | PERF | S | estabilidade GPU |
| 6 | AMBOS | S | MemAvailable + decode ok |
| 7 | PERF | S | FPS sustentado |
| 8 | AMBOS | S | depende da divergência |
| 9 | PERF | A | load time ROMs |
| 10 | AMBOS | A | MemAvailable + frametime |
| 11 | PERF | A | FPS em PS1/PSP HW |
| 12 | FOOTPRINT | A | RSS daemons |
| 13 | PERF | A | freq sustentada |
| 14 | DECISÃO | A | — |
| 15 | PERF | B | input latency ms |
| 16 | AMBOS | B | RSS + crackle |
| 17 | FOOTPRINT | B | disk + cache |
| 18 | PERF | B | FPS per-game |
| 19 | AMBOS | B | boot time + RSS |
| 20 | PERF | B | CPU em vídeo |

---

# Ordem recomendada de execução

| Fase | Itens | Duração estimada |
|------|-------|------------------|
| **Pré-req obrigatório** | 0, 1 | 3–5 dias |
| **Quick wins RAM/DDR/CMA** | 2, 3, 6 | 2 dias |
| **Stack gráfico** | 4, 5 | 1–2 dias |
| **DT archeology** | 8 | 2–3 dias |
| **Compilação tunada** | 7 | 1 dia + build time |
| **Polimento stack** | 9, 10, 11, 12, 13 | 3 dias |
| **Decisão Vulkan** | 14 | 1 dia |
| **Latência e áudio** | 15, 16 | 1 dia |
| **QoL e economia** | 17, 18, 19, 20 | 2 dias |
| **Documentação** | 21 | paralelo |
| **CI** | 22 | longo prazo |

**Total estimado:** ~3–4 semanas focadas + build time.

---

# Itens explicitamente DESCARTADOS (e por quê)

- ~~big.LITTLE / EAS~~ — RK3326 é 4× A35 homogêneos.
- ~~Transparent HugePages~~ — fragmenta em 1GB. Manter `never`.
- ~~CPU isolation (`isolcpus`, `nohz_full`)~~ — 4 cores é pouco.
- ~~PGO em Dolphin/PCSX2/RPCS3~~ — não rodam com perf útil no A35.
- ~~F2FS~~ — ext4 mais seguro em microSD variável.
- ~~Swap em microSD~~ — destrói cartão.
- ~~`-O3` universal~~ — icache apertado; pontual após bench.
- ~~`mitigations=off`~~ — ganho marginal em A35, risco ruim.

---

# Quando revisitar este TODO

- Após itens 0 e 1: reprioritizar com dados.
- A cada release do Mesa: PanVK em G31 saiu de experimental?
- A cada release do kernel: patches novos de Panfrost/rockchip?
- Se o projeto ganhar contribuidores: quebrar em issues granulares.