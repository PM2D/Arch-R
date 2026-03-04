#!/bin/bash

#==============================================================================
# Arch R - Generate Panel DTBO Overlays
#==============================================================================
# Generates DTBO overlay files for ALL panel variants using archr-dtbo.py
# (adapted from ROCKNIX overlay_server — identical output structure).
#
# Each overlay contains:
#   - Panel fragment: compatible, panel_description (G + 12 M modes + I lines)
#   - Pinctrl fragment: reset GPIO + power supply GPIO
#   - ADC keys fragment: enable/disable
#   - Joypad fragment: stick inversion
#   - Audio fragment: HP detect GPIO + pinctrl
#   - __fixups__: symbol references for GPIO/pinctrl phandles
#
# Sources:
#   - R36S originals (Panel 0-7): DTS in kernel/dts/R36S-DTB/DTS/
#   - R36S clones (Clone 1-10, R36 Max, RX6S): DTBs in R36S-Clones-DTB/
#==============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DTS_DIR="$PROJECT_DIR/kernel/dts/R36S-DTB/DTS"
CLONES_DIR="$PROJECT_DIR/kernel/dts/R36S-Clones-DTB"
OUTPUT_DIR="$PROJECT_DIR/output/panels"
DTBO_TOOL="$SCRIPT_DIR/archr-dtbo.py"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log() { echo -e "${GREEN}[PANEL]${NC} $1"; }
warn() { echo -e "${YELLOW}[PANEL] WARNING:${NC} $1"; }
error() { echo -e "${RED}[PANEL] ERROR:${NC} $1"; exit 1; }

# Check prerequisites
if ! command -v dtc &>/dev/null; then
    error "dtc (device-tree-compiler) not found. Install with: sudo apt install device-tree-compiler"
fi
if ! command -v python3 &>/dev/null; then
    error "python3 not found"
fi
if ! python3 -c "import fdt" 2>/dev/null; then
    error "Python fdt package not found. Install with: pip3 install --user --break-system-packages fdt"
fi
if [ ! -f "$DTBO_TOOL" ]; then
    error "archr-dtbo.py not found at: $DTBO_TOOL"
fi

mkdir -p "$OUTPUT_DIR"
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

#------------------------------------------------------------------------------
# Original R36S panels (Panel 0-7)
# These are DTS files — compile to DTB first, then generate overlay
#------------------------------------------------------------------------------
declare -A ORIG_DTS=(
    [0]="Panel0.dts"     [1]="Panel1.dts"     [2]="Panel2.dts"
    [3]="Panel3.dts"     [4]="Panel4-V22.dts"  [5]="Panel5.dts"
    [6]="Panel4.dts"     [7]="R46H.dts"
)
# Overlay flags per panel (same as ROCKNIX device config)
# Empty = defaults (no special flags)
declare -A ORIG_FLAGS=(
    [0]="" [1]="" [2]="" [3]="" [4]="" [5]=""
    [6]="" [7]=""
)

log "=== Generating Panel DTBO Overlays (ROCKNIX-identical structure) ==="
log "Source: $DTS_DIR"
log "Output: $OUTPUT_DIR"
log ""

GENERATED=0
FAILED=0

for panel_num in 0 1 2 3 4 5 6 7; do
    dts_file="$DTS_DIR/${ORIG_DTS[$panel_num]}"
    out_name=$(echo "${ORIG_DTS[$panel_num]%.dts}" | tr '[:upper:]' '[:lower:]')
    log "Panel ${panel_num}: ${ORIG_DTS[$panel_num]}"

    if [ ! -f "$dts_file" ]; then
        warn "  DTS not found: $dts_file"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Compile DTS to DTB (vendor DTS has __symbols__)
    tmp_dtb="$TMPDIR/${out_name}.dtb"
    if ! dtc -I dts -O dtb "$dts_file" -o "$tmp_dtb" 2>/dev/null; then
        warn "  Failed to compile DTS to DTB"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Generate overlay with archr-dtbo.py
    dtbo_file="$OUTPUT_DIR/${out_name}.dtbo"
    flags="${ORIG_FLAGS[$panel_num]}"
    if python3 "$DTBO_TOOL" "$tmp_dtb" "$flags" -o "$dtbo_file" 2>/dev/null; then
        dtbo_size=$(stat -c%s "$dtbo_file")
        # Count M lines
        m_count=$(dtc -I dtb -O dts "$dtbo_file" 2>/dev/null | grep -o 'M clock=' | wc -l)
        log "  Generated: ${out_name}.dtbo (${dtbo_size} bytes, ${m_count} timing modes)"
        GENERATED=$((GENERATED + 1))
    else
        warn "  archr-dtbo.py failed for ${out_name}"
        FAILED=$((FAILED + 1))
    fi
done

#------------------------------------------------------------------------------
# Clone Panel Definitions
#------------------------------------------------------------------------------
declare -A CLONE_DTB=(
    ["Clone Panel 1"]="Panel 1/rf3536k4ka.dtb"
    ["Clone Panel 2"]="Panel 2/rf3536k4ka.dtb"
    ["Clone Panel 3"]="Panel 3/rf3536k4ka.dtb"
    ["Clone Panel 4"]="Panel 4/rf3536k4ka.dtb"
    ["Clone Panel 5"]="Panel 5/rf3536k4ka.dtb"
    ["Clone Panel 6"]="Panel 6/rf3536k4ka.dtb"
    ["Clone Panel 7"]="Panel 7/rf3536k4ka.dtb"
    ["Clone Panel 8"]="Panel 8/rf3536k4ka.dtb"
    ["Clone Panel 9"]="Panel 9/rf3536k4ka.dtb"
    ["Clone Panel 10"]="Panel 10/rf3536k3ka.dtb"
    ["R36 Max"]="R36 Max/rf3536k4ka.dtb"
    ["RX6S"]="RX6S/rf351g3ka.dtb"
)

# Overlay flags per clone panel (empty = defaults)
declare -A CLONE_FLAGS=(
    ["Clone Panel 1"]="" ["Clone Panel 2"]="" ["Clone Panel 3"]=""
    ["Clone Panel 4"]="" ["Clone Panel 5"]="" ["Clone Panel 6"]=""
    ["Clone Panel 7"]="" ["Clone Panel 8"]="" ["Clone Panel 9"]=""
    ["Clone Panel 10"]="" ["R36 Max"]="" ["RX6S"]=""
)

CLONE_ORDER=("Clone Panel 1" "Clone Panel 2" "Clone Panel 3" "Clone Panel 4" \
             "Clone Panel 5" "Clone Panel 6" "Clone Panel 7" "Clone Panel 8" \
             "Clone Panel 9" "Clone Panel 10" "R36 Max" "RX6S")

log ""
log "=== Generating Clone Panel DTBO Overlays ==="
log "Source: $CLONES_DIR"
log ""

for panel_name in "${CLONE_ORDER[@]}"; do
    dtb_file="$CLONES_DIR/${CLONE_DTB[$panel_name]}"
    safe_name=$(echo "$panel_name" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
    log "${panel_name}: ${CLONE_DTB[$panel_name]}"

    if [ ! -f "$dtb_file" ]; then
        warn "  DTB not found: $dtb_file"
        FAILED=$((FAILED + 1))
        continue
    fi

    dtbo_file="$OUTPUT_DIR/${safe_name}.dtbo"
    flags="${CLONE_FLAGS[$panel_name]}"
    if python3 "$DTBO_TOOL" "$dtb_file" "$flags" -o "$dtbo_file" 2>/dev/null; then
        dtbo_size=$(stat -c%s "$dtbo_file")
        m_count=$(dtc -I dtb -O dts "$dtbo_file" 2>/dev/null | grep -o 'M clock=' | wc -l)
        log "  Generated: ${safe_name}.dtbo (${dtbo_size} bytes, ${m_count} timing modes)"
        GENERATED=$((GENERATED + 1))
    else
        warn "  archr-dtbo.py failed for ${safe_name}"
        FAILED=$((FAILED + 1))
    fi
done

#------------------------------------------------------------------------------
# Summary
#------------------------------------------------------------------------------
log ""
log "=== Panel Generation Complete ==="
log "DTBOs generated: ${GENERATED}"
[ $FAILED -gt 0 ] && warn "Failed: ${FAILED}"
log ""
log "Output: $OUTPUT_DIR/"
ls -1 "$OUTPUT_DIR"/*.dtbo 2>/dev/null | while read f; do
    log "  $(basename "$f") ($(stat -c%s "$f") bytes)"
done
log ""
log "Panel overlays go in /overlays/ on BOOT partition."
