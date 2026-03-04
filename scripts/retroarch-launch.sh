#!/bin/bash

#==============================================================================
# Arch R - RetroArch Launch Wrapper
#==============================================================================
# Launched by ES via es_systems.cfg. Ensures ALSA mixer state, sets
# performance governor, and launches RetroArch with proper environment.
# After RetroArch exits, restores ALSA mixer state (like dArkOS verifyaudio.sh).
#
# Usage: retroarch-launch /usr/lib/libretro/<core>.so /roms/<sys>/rom.ext
#==============================================================================

# Root guard: RetroArch must run as archr, never as root
if [ "$(id -u)" = "0" ]; then
    exec su -l archr -c "$(printf '%q ' "$0" "$@")"
fi

# Hide VT flash: blank screen immediately to avoid showing shell between ES→RetroArch
# When ES releases DRM (HideWindow=true), fbcon shows VT1 briefly before RetroArch
# acquires DRM. Fill framebuffer with black (zeros) to make transition seamless.
printf '\033[2J\033[H\033[?25l\033[30;40m' > /dev/tty1 2>/dev/null
dd if=/dev/zero of=/dev/fb0 bs=4096 count=300 2>/dev/null

# Auto-detect ALSA control names (BSP: DAC/Playback Path, Mainline: Master/Playback Mux)
if amixer sget 'Master' &>/dev/null; then
    ALSA_VOL=Master
    ALSA_PATH="Playback Mux"
else
    ALSA_VOL=DAC
    ALSA_PATH="Playback Path"
fi

# Save current volume before RetroArch (it may change it on exit)
SAVED_VOL=$(amixer sget "$ALSA_VOL" 2>/dev/null | grep -oE '\[.*%\]' | head -1 | tr -d '[]%')

# Ensure ALSA mixer is set for speaker output
amixer -q sset "$ALSA_PATH" SPK 2>/dev/null
amixer -q sset "$ALSA_VOL" 80% 2>/dev/null

# Performance governor (archr has NOPASSWD sudo for perfmax/perfnorm)
sudo /usr/local/bin/perfmax 2>/dev/null

# Merge gamepad inputs: gpio-keys (buttons) + adc-joystick (analog sticks)
# into a single virtual "Arch R Gamepad" so RetroArch sees one device.
# Without this, RetroArch assigns each to a different player port and
# analog sticks end up ignored (max_users=1).
INPUT_MERGE=/usr/local/bin/input-merge
if [ -x "$INPUT_MERGE" ]; then
    sudo "$INPUT_MERGE" &
    MERGE_PID=$!
    # Wait for virtual device to appear
    for i in 1 2 3 4 5 6 7 8 9 10; do
        [ -f /run/input-merge.pid ] && break
        sleep 0.1
    done
fi

# Log file — write to HOME dir (archr can write here), copy to /boot after
# CRITICAL: /boot is FAT32 mounted as root — archr CANNOT write there directly!
LOGFILE="$HOME/retroarch.log"
{
    echo "=== RetroArch Launch: $(date) ==="
    echo "Core: $1"
    echo "ROM: $2"
    echo "User: $(id)"
    echo "ALSA mixer before ($ALSA_VOL/$ALSA_PATH):"
    amixer sget "$ALSA_PATH" 2>/dev/null | grep "Item0:"
    echo "  $ALSA_VOL: ${SAVED_VOL}%"
    echo "DRI:"
    ls -la /dev/dri/ 2>&1
} >> "$LOGFILE"

# Enforce critical config settings before every launch.
# Guards against config reverts (e.g. user toggling config_save_on_exit in RA menu).
RA_CFG="$HOME/.config/retroarch/retroarch.cfg"
if [ -f "$RA_CFG" ]; then
    sed -i 's|^log_verbosity = "true"|log_verbosity = "false"|' "$RA_CFG"
    sed -i 's|^gamemode_enable = "true"|gamemode_enable = "false"|' "$RA_CFG"
    sed -i 's|^config_save_on_exit = "true"|config_save_on_exit = "false"|' "$RA_CFG"
fi

# Ensure core_info cache dir is writable (may have been reset by package update)
[ -d /usr/share/libretro/info ] && chmod 777 /usr/share/libretro/info 2>/dev/null

# Launch RetroArch
# - Runs as archr so HOME=/home/archr → finds retroarch.cfg at ~/.config/retroarch/
# - DRM access: /dev/dri/* already chmod 666 by emulationstation.sh
retroarch -L "$@" >> "$LOGFILE" 2>&1 &
RA_PID=$!
echo "$RA_PID" > /tmp/.archr-game-pid
wait "$RA_PID"
ret=$?
rm -f /tmp/.archr-game-pid

# Stop input merger (ungrab devices so ES can use them again)
if [ -n "$MERGE_PID" ]; then
    sudo kill "$MERGE_PID" 2>/dev/null
    wait "$MERGE_PID" 2>/dev/null
fi

# Restore ALSA mixer state after RetroArch exits (like dArkOS verifyaudio.sh)
# RetroArch may modify mixer controls on exit — restore to known good state
amixer -q sset "$ALSA_PATH" SPK 2>/dev/null
if [ -n "$SAVED_VOL" ] && [ "$SAVED_VOL" -gt 0 ] 2>/dev/null; then
    amixer -q sset "$ALSA_VOL" "${SAVED_VOL}%" 2>/dev/null
else
    amixer -q sset "$ALSA_VOL" 80% 2>/dev/null
fi

{
    echo "RetroArch exited with code: $ret"
    echo "ALSA mixer after restore:"
    amixer sget "$ALSA_PATH" 2>/dev/null | grep "Item0:"
    amixer sget "$ALSA_VOL" 2>/dev/null | grep -oE '\[.*%\]' | head -1
    echo "==="
} >> "$LOGFILE"

# Copy log to /boot for easy PC access (needs sudo — archr can't write /boot)
sudo cp "$LOGFILE" /boot/retroarch.log 2>/dev/null

# Restore normal governor
sudo /usr/local/bin/perfnorm 2>/dev/null

exit $ret
