# Arch R

<p align="center">
  <img src="ArchR.png" alt="Arch R" width="480">
</p>

> **Arch Linux-based gaming distribution for R36S and all clones.**
>
> Leve como uma pluma.

Arch R is a custom Linux distribution built from scratch for the R36S handheld gaming console (RK3326 SoC, Mali-G31 GPU, 640x480 MIPI DSI display). It supports all R36S variants and clones with 18 different display panels.

## Features

- **Kernel 6.6.89** (Rockchip BSP) — custom DTS with joypad, panel init sequences, audio, USB OTG
- **Mesa 26 Panfrost** — open-source GPU driver, GLES 1.0/2.0/3.1, no proprietary blobs
- **EmulationStation** (fcamod fork) — 78fps stable, GLES 1.0 native rendering
- **RetroArch 1.22.2** — KMS/DRM + EGL, 18+ cores pre-installed
- **19-second boot** — U-Boot logo → kernel → systemd → EmulationStation
- **Full audio** — ALSA, speaker + headphone auto-switch, volume hotkeys
- **Battery monitoring** — LED warning, capacity/voltage/temp reporting
- **Multi-panel support** — 18 panel DTBOs (6 original R36S + 12 clones)

## Quick Start — Flash a Pre-built Image

Download the latest image from [Releases](../../releases), then:

```bash
xz -d ArchR-R36S-*.img.xz
sudo dd if=ArchR-R36S-*.img of=/dev/sdX bs=4M status=progress
sync
```

Insert the SD card into your R36S and power on. First boot creates a ROMS partition automatically.

## Building from Source

### Host Requirements

- **OS:** Ubuntu 22.04+ (or any Linux with QEMU user-static support)
- **Disk:** 30GB+ free space
- **RAM:** 4GB+ recommended
- **Time:** ~3-4 hours (first build), ~1 hour (incremental)

### Install Dependencies

```bash
sudo apt install -y \
    gcc-aarch64-linux-gnu \
    qemu-user-static \
    binfmt-support \
    parted \
    dosfstools \
    e2fsprogs \
    rsync \
    xz-utils \
    imagemagick \
    device-tree-compiler \
    git \
    bc \
    flex \
    bison \
    libssl-dev
```

### Build Everything

```bash
git clone --recurse-submodules https://github.com/user/Arch-R.git
cd Arch-R

# Full build (kernel + rootfs + mesa + ES + retroarch + panels + image)
sudo ./build-all.sh
```

The flashable image will be at `output/images/ArchR-R36S-YYYYMMDD.img.xz` (~860MB compressed).

### Build Individual Components

```bash
sudo ./build-all.sh --kernel     # Kernel only (~10 min)
sudo ./build-all.sh --rootfs     # Rootfs + Mesa + ES + RetroArch (~3 hours)
sudo ./build-all.sh --image      # Image assembly only (~2 min)
sudo ./build-all.sh --clean      # Remove all build artifacts
```

### Build Pipeline

```
build-all.sh
  ├── build-kernel.sh          # Cross-compile kernel 6.6.89 (~10 min)
  ├── build-rootfs.sh          # Arch Linux ARM rootfs in QEMU chroot (~45 min)
  ├── build-mesa.sh            # Mesa 26 with Panfrost + GLES 1.0 (~30 min)
  ├── build-emulationstation.sh # ES-fcamod with 21 patches (~20 min)
  ├── build-retroarch.sh       # RetroArch + cores (~40 min)
  ├── generate-panel-dtbos.sh  # 18 panel DTBO overlays (~10 sec)
  └── build-image.sh           # Assemble SD card image (~2 min)
```

All builds happen inside a QEMU aarch64 chroot — no cross-compilation issues.

## Project Structure

```
Arch-R/
├── build-all.sh                  # Master build orchestrator
├── build-kernel.sh               # Kernel compilation
├── build-rootfs.sh               # Root filesystem (Arch Linux ARM + services)
├── build-mesa.sh                 # Mesa 26 GPU driver
├── build-emulationstation.sh     # EmulationStation frontend
├── build-retroarch.sh            # RetroArch + cores
├── build-image.sh                # SD card image assembly
├── config/
│   ├── archr-6.6-r36s.config     # Kernel config fragment (393 options)
│   ├── boot.ini                  # U-Boot fallback boot script
│   ├── es_systems.cfg            # EmulationStation system definitions
│   ├── retroarch.cfg             # RetroArch base configuration
│   ├── asound.conf               # ALSA audio configuration
│   └── autoconfig/               # RetroArch controller autoconfig
├── kernel/
│   └── dts/
│       ├── rk3326-gameconsole-r36s.dts  # Custom R36S device tree
│       └── R36S-DTB/                     # Reference panel DTBs
├── scripts/
│   ├── emulationstation.sh       # ES launch wrapper
│   ├── retroarch-launch.sh       # RetroArch launch wrapper
│   ├── archr-hotkeys.py          # Volume/brightness hotkey daemon
│   ├── first-boot.sh             # First boot setup (ROMS partition)
│   ├── generate-panel-dtbos.sh   # Panel overlay generator
│   ├── pmic-poweroff             # PMIC shutdown handler
│   └── vlc-stub.c                # VLC stub library for ES build
├── bootloader/
│   └── u-boot-r36s-working/      # Pre-built U-Boot binaries
├── prebuilt/
│   └── cores/                    # Pre-built RetroArch cores (FBNeo, MAME, N64, PSP)
├── ArchR.png                     # Boot logo source
└── ROADMAP.md                    # Development diary
```

## Hardware

| Component | Details |
|-----------|---------|
| SoC | Rockchip RK3326 (4x Cortex-A35 @ 1.5GHz) |
| GPU | Mali-G31 Bifrost (Mesa Panfrost, 600MHz) |
| RAM | 1GB DDR3L (786MHz) |
| Display | 640x480 MIPI DSI (18 panel variants) |
| Audio | RK817 codec, speaker + headphone jack |
| Storage | MicroSD (boot + rootfs + ROMS) |
| Controls | D-pad, ABXY, L1/L2/R1/R2, dual analog sticks |
| Battery | 3200mAh Li-Po (RK817 charger) |
| USB | OTG with host mode (VBUS power on GPIO0_B7) |

## Supported Panels

Arch R supports 18 display panels via DTBO overlays. The default image boots with **Panel 4-V22** (the most common R36S panel).

### Panel Auto-Detection

On first boot, Arch R runs a **panel detection wizard** that guides you through selecting your display panel:

1. **If your screen works** (you see text on screen): press **A** to confirm the current panel
2. **If your screen is black** (wrong panel): listen for audio beeps and use buttons to navigate:
   - Each panel plays a different number of beeps (1 beep = first panel, 2 beeps = second, etc.)
   - Press **B** to skip to the next panel
   - Press **A** to confirm (you'll hear 3 rapid beeps)
   - The system reboots with the correct panel applied

Your selection is saved permanently. To reset it later, **hold X during boot**.

### Panel List

| # | Panel | Notes |
|---|-------|-------|
| 1 | **Panel 4-V22** *(default)* | Most common (~60% of R36S units) |
| 2 | Panel 3-V20 | V20 board marking |
| 3 | Panel 5-V22 Q8 | V22 Q8 variant |
| 4 | Clone Panel 8 | ST7703 (G80CA-MB) |
| 5 | Panel 0 | Early R36S units |
| 6 | Panel 1-V10 | V10 board marking |
| 7 | Panel 2-V12 | V12 board marking |
| 8 | Clone Panel 1 | ST7703 |
| 9 | Clone Panel 3 | NV3051D |
| 10 | Clone Panel 7 | JD9365DA |
| 11 | Clone Panel 9 | NV3051D |
| 12 | Clone Panel 10 | ST7703 variant |
| 13 | Clone Panel 2 | ST7703 |
| 14 | Clone Panel 4 | NV3051D |
| 15 | Clone Panel 5 | ST7703 |
| 16 | Clone Panel 6 | NV3051D |
| 17 | R36 Max | 720x720 ST7703 |
| 18 | RX6S | NV3051D variant |

### Manual Panel Selection

If you prefer to set the panel manually (e.g., you know which panel you have from ArkOS/dArkOS):

**Step 1 — Mount the BOOT partition on your PC**

```bash
lsblk
sudo mount /dev/sdX1 /mnt
```

**Step 2 — Create panel.txt**

```bash
# Example: Panel 3-V20
echo 'PanelNum=3
PanelDTBO=ScreenFiles/Panel 3/mipi-panel.dtbo' | sudo tee /mnt/panel.txt

# Mark as confirmed (skip wizard on next boot)
echo 'confirmed' | sudo tee /mnt/panel-confirmed
```

For default Panel 4-V22 (no overlay needed):
```bash
echo 'PanelNum=4
PanelDTBO=' | sudo tee /mnt/panel.txt
echo 'confirmed' | sudo tee /mnt/panel-confirmed
```

**Step 3 — Unmount and boot**

```bash
sudo umount /mnt
sync
```

**To reset panel selection:** hold **X** during boot, or delete `panel-confirmed` from the BOOT partition.

## Boot Flow

```
Power On
  → U-Boot (idbloader → trust → uboot.img)
  → logo.bmp displayed on screen
  → boot.ini: load panel.txt → apply DTBO overlay (if non-default panel)
  → Kernel 6.6.89 + rk3326-gameconsole-r36s.dtb
  → systemd → panel-detect.service (first boot only)
  → archr-boot-setup (GPU + governors)
  → emulationstation.service → EmulationStation UI
  ≈ 19 seconds total (+ wizard on first boot)
```

## Contributing

See [ROADMAP.md](ROADMAP.md) for current development status and planned features.

## License

GPL v3
