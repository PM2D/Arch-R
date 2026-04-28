#!/bin/bash
# ArchR Performance Benchmark Script
# Run on device: bash /flash/bench.sh <scenario> [duration_seconds]
# Results saved to /storage/bench-results/

DURATION=${2:-60}
RESULTS_DIR="/storage/bench-results/$(date +%Y%m%d-%H%M%S)-${1:-general}"
mkdir -p "$RESULTS_DIR"

echo "========================================"
echo "  ArchR Benchmark: ${1:-general}"
echo "  Duration: ${DURATION}s"
echo "  Output: $RESULTS_DIR"
echo "========================================"

# Metadata
cat > "$RESULTS_DIR/meta.json" << METAEOF
{
  "timestamp": "$(date -Iseconds)",
  "kernel": "$(uname -r)",
  "distro": "$(grep ^NAME /etc/os-release | cut -d= -f2)",
  "cpu_governor": "$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)",
  "gpu_governor": "$(cat /sys/class/devfreq/ff400000.gpu/governor 2>/dev/null)",
  "dmc_governor": "$(cat /sys/class/devfreq/dmc/governor 2>/dev/null)",
  "mem_available_kb": $(grep MemAvailable /proc/meminfo | awk '{print $2}'),
  "cma_total_kb": $(grep CmaTotal /proc/meminfo | awk '{print $2}'),
  "cma_free_kb": $(grep CmaFree /proc/meminfo | awk '{print $2}'),
  "zram_algo": "$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr -d '[]')",
  "swap": "$(swapon --show --noheadings 2>/dev/null | head -1)",
  "swappiness": $(sysctl -n vm.swappiness 2>/dev/null),
  "vfs_cache_pressure": $(sysctl -n vm.vfs_cache_pressure 2>/dev/null),
  "temperature_start": $(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null),
  "sd_model": "$(cat /sys/block/mmcblk0/device/name 2>/dev/null)",
  "scenario": "${1:-general}"
}
METAEOF

# PSI monitoring (background)
echo "Starting PSI monitoring..."
(
  while true; do
    echo "$(date +%s.%N) $(cat /proc/pressure/cpu 2>/dev/null | head -1) $(cat /proc/pressure/memory 2>/dev/null | head -1) $(cat /proc/pressure/io 2>/dev/null | head -1)"
    sleep 1
  done
) > "$RESULTS_DIR/psi.log" &
PSI_PID=$!

# Frequency + temperature monitoring (background)
echo "Starting freq/temp monitoring..."
(
  while true; do
    CPU_FREQ=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)
    GPU_FREQ=$(cat /sys/class/devfreq/ff400000.gpu/cur_freq 2>/dev/null)
    DMC_FREQ=$(cat /sys/class/devfreq/dmc/cur_freq 2>/dev/null)
    TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
    MEM=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    echo "$(date +%s.%N) cpu=$CPU_FREQ gpu=$GPU_FREQ dmc=$DMC_FREQ temp=$TEMP mem=$MEM"
    sleep 1
  done
) > "$RESULTS_DIR/freq-therm.log" &
FREQ_PID=$!

# vmstat monitoring
vmstat 1 $DURATION > "$RESULTS_DIR/vmstat.log" &
VMSTAT_PID=$!

# dmesg monitoring
dmesg -w > "$RESULTS_DIR/dmesg.log" 2>/dev/null &
DMESG_PID=$!

echo ""
echo "Monitors running. Now launch your game/emulator."
echo "Press Ctrl+C after ${DURATION}s or when done testing."
echo ""

# Wait
sleep $DURATION 2>/dev/null || true

# Cleanup
kill $PSI_PID $FREQ_PID $VMSTAT_PID $DMESG_PID 2>/dev/null
wait 2>/dev/null

# Generate summary
TEMP_END=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
MEM_END=$(grep MemAvailable /proc/meminfo | awk '{print $2}')

cat > "$RESULTS_DIR/summary.json" << SUMEOF
{
  "duration_s": $DURATION,
  "temperature_end": $TEMP_END,
  "mem_available_end_kb": $MEM_END,
  "psi_samples": $(wc -l < "$RESULTS_DIR/psi.log"),
  "freq_samples": $(wc -l < "$RESULTS_DIR/freq-therm.log")
}
SUMEOF

echo ""
echo "========================================"
echo "  Benchmark complete!"
echo "  Results: $RESULTS_DIR"
echo "  Files: $(ls $RESULTS_DIR | wc -l)"
echo "========================================"
ls -lh "$RESULTS_DIR"
