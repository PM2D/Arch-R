#!/bin/bash
# NAME: System Info
. /usr/lib/archr/menu-lib.sh
tool_init

# Gather system info
INFO=""
INFO+="Kernel:  $(uname -r)\n"

FREQ=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)
GOV=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)
[ -n "$FREQ" ] && INFO+="CPU:     $((FREQ/1000)) MHz ($GOV)\n"

GPU_FREQ=$(cat /sys/devices/platform/ff400000.gpu/devfreq/ff400000.gpu/cur_freq 2>/dev/null)
[ -n "$GPU_FREQ" ] && INFO+="GPU:     $((GPU_FREQ/1000000)) MHz\n"

TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null)
[ -n "$TEMP" ] && INFO+="Temp:    $((TEMP/1000))C\n"

MEM_TOTAL=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024)}')
MEM_AVAIL=$(grep MemAvailable /proc/meminfo | awk '{print int($2/1024)}')
INFO+="RAM:     ${MEM_AVAIL}MB free / ${MEM_TOTAL}MB total\n"

SWAP=$(grep SwapTotal /proc/meminfo | awk '{print int($2/1024)}')
[ "$SWAP" -gt 0 ] 2>/dev/null && INFO+="ZRAM:    ${SWAP}MB\n"

ROOT_USE=$(df -h / 2>/dev/null | tail -1 | awk '{print $3 " / " $2 " (" $5 ")"}')
INFO+="Root:    $ROOT_USE\n"

BAT_CAP=$(cat /sys/class/power_supply/*/capacity 2>/dev/null | head -1)
BAT_STATUS=$(cat /sys/class/power_supply/*/status 2>/dev/null | head -1)
[ -n "$BAT_CAP" ] && INFO+="Battery: ${BAT_CAP}% ($BAT_STATUS)\n"

BL_CUR=$(cat /sys/class/backlight/*/brightness 2>/dev/null | head -1)
BL_MAX=$(cat /sys/class/backlight/*/max_brightness 2>/dev/null | head -1)
[ -n "$BL_CUR" ] && [ -n "$BL_MAX" ] && [ "$BL_MAX" -gt 0 ] && \
    INFO+="Bright:  $((BL_CUR * 100 / BL_MAX))%\n"

WIFI_STATE=$(nmcli radio wifi 2>/dev/null)
if [ "$WIFI_STATE" = "enabled" ]; then
    SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes' | cut -d: -f2)
    [ -n "$SSID" ] && INFO+="WiFi:    $SSID\n" || INFO+="WiFi:    on (not connected)\n"
else
    INFO+="WiFi:    off\n"
fi

INFO+="Uptime:  $(uptime -p 2>/dev/null | sed 's/up //')\n"
VARIANT=$(cat /etc/archr/variant 2>/dev/null)
[ -n "$VARIANT" ] && INFO+="Variant: $VARIANT\n"

msg_show "Arch R — System Info" "$INFO"
