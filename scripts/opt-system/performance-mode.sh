#!/bin/bash
# NAME: Performance
. /usr/lib/archr/menu-lib.sh
tool_init

while true; do
    CPU_GOV=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null)
    CPU_FREQ=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq 2>/dev/null)
    [ -n "$CPU_FREQ" ] && CPU_MHZ="$((CPU_FREQ/1000)) MHz" || CPU_MHZ="unknown"

    menu_select "Performance — $CPU_MHZ ($CPU_GOV)" \
        "Max Performance" \
        "Normal (ondemand)" \
        "Power Save" || break

    case "$MENU_RESULT" in
        0)
            perfmax 2>/dev/null
            msg_show "Performance" "Max performance set.\nCPU + GPU locked to highest clocks."
            ;;
        1)
            perfnorm 2>/dev/null
            msg_show "Performance" "Normal mode set.\nCPU/GPU scale with demand."
            ;;
        2)
            echo powersave | tee /sys/devices/system/cpu/cpufreq/policy0/scaling_governor >/dev/null 2>&1
            echo powersave | tee /sys/devices/platform/ff400000.gpu/devfreq/ff400000.gpu/governor >/dev/null 2>&1
            msg_show "Performance" "Power save set.\nCPU + GPU at lowest clocks."
            ;;
    esac
done
