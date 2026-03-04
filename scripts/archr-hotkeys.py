#!/usr/bin/python3
"""
Arch R - Hotkey Daemon
Listens for input events and handles:
  - KEY_VOLUMEUP/KEY_VOLUMEDOWN → ALSA volume adjust (from gpio-keys-vol)
  - MODE + VOL_UP/VOL_DOWN → brightness adjust
  - MODE + B → screenshot
  - MODE + X → WiFi toggle
  - SELECT + START (hold 1s) → kill running game
  - Headphone jack insertion → audio path toggle (from rk817 codec)

Volume device (gpio-keys-vol) is grabbed exclusively.
Gamepad device (gpio-keys or archr-singleadc-joypad) is monitored passively.
"""

import os
import sys
import time
import subprocess
import re
import select

try:
    import evdev
    from evdev import ecodes
except ImportError:
    print("ERROR: python-evdev not installed. Install with: pacman -S python-evdev")
    sys.exit(1)

# Volume step (percentage per key press)
VOL_STEP = 5
# Brightness step (percentage per key press)
BRIGHT_STEP = 5
# Minimum interval between volume/brightness actions (seconds)
# adc-keys autorepeat fires at ~30Hz — throttle to ~3 events/sec
VOL_THROTTLE = 0.3
# Minimum brightness percentage (prevent black screen)
BRIGHT_MIN = 5
# Brightness persistence file
BRIGHT_SAVE = "/home/archr/.config/archr/brightness"
VOL_SAVE = "/home/archr/.config/archr/volume"

# ALSA simple mixer control name for rk817 codec volume.
# Depends on machine driver:
#   BSP kernel (rk817-sound):        "DAC" (from "DAC Playback Volume")
#   Mainline (simple-audio-card):    "Master" (from "Master Playback Volume")
# Detected at startup by detect_alsa_controls().
ALSA_VOL_CTRL = "Master"  # default for mainline, overridden at startup
# Speaker/headphone switch control:
#   BSP: "Playback Path" (enum: OFF/SPK/HP/...)
#   Mainline: "Playback Mux" (enum: HP/SPK)
ALSA_PATH_CTRL = "Playback Mux"  # default for mainline, overridden at startup

# rk817 codec volume range: ALSA reports [0, 255] but codec rejects values > 252
# Writing > 252 causes "Volume out of range" and can ZERO the volume!
# Use percentage clamping: 0-98% stays within [0, 249] (safe margin)
VOL_MAX_PCT = 98
VOL_MIN_PCT = 0

# Kill switch: hold SELECT+START for this many seconds to kill running game
KILL_HOLD_TIME = 1.0
# Game PID file (written by retroarch-launch.sh and other wrappers)
GAME_PIDFILE = "/tmp/.archr-game-pid"
# Screenshot directory
SCREENSHOT_DIR = "/home/archr/screenshots"


# Log to BOOT partition (FAT32) — persistent across reboots, readable from PC
# /tmp is tmpfs and lost on power off, making debugging impossible
LOGFILE = "/boot/archr-hotkeys.log"


def detect_alsa_controls():
    """Detect ALSA volume and path control names at startup.
    BSP kernel uses 'DAC' + 'Playback Path'.
    Mainline simple-audio-card uses 'Master' + 'Playback Mux'."""
    global ALSA_VOL_CTRL, ALSA_PATH_CTRL
    try:
        r = subprocess.run("amixer scontrols", shell=True,
                           capture_output=True, text=True, timeout=5)
        controls = r.stdout
        if "'Master'" in controls:
            ALSA_VOL_CTRL = "Master"
        elif "'DAC'" in controls:
            ALSA_VOL_CTRL = "DAC"
        if "'Playback Mux'" in controls:
            ALSA_PATH_CTRL = "Playback Mux"
        elif "'Playback Path'" in controls:
            ALSA_PATH_CTRL = "Playback Path"
    except Exception:
        pass


def log(msg):
    """Append to log file for debugging."""
    try:
        with open(LOGFILE, "a") as f:
            f.write(f"{time.strftime('%H:%M:%S')} {msg}\n")
            f.flush()
    except Exception:
        pass


def run_cmd(cmd):
    """Run a shell command, log output for debugging."""
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, timeout=5, text=True)
        if result.returncode != 0:
            log(f"CMD FAIL [{result.returncode}]: {cmd}")
            if result.stderr:
                log(f"  stderr: {result.stderr.strip()}")
        else:
            if result.stdout:
                log(f"  stdout: {result.stdout.strip()[:200]}")
        return result.returncode
    except Exception as e:
        log(f"CMD ERROR: {cmd} -> {e}")
        return -1


def get_volume_pct():
    """Read current DAC volume percentage from sysfs-style amixer output."""
    try:
        r = subprocess.run(
            f"amixer sget '{ALSA_VOL_CTRL}'",
            shell=True, capture_output=True, text=True, timeout=3
        )
        if r.returncode == 0:
            m = re.search(r'\[(\d+)%\]', r.stdout)
            if m:
                return int(m.group(1))
    except Exception:
        pass
    return -1


def set_volume_pct(pct):
    """Set DAC volume to exact percentage (with clamping for rk817 codec safety)."""
    pct = max(VOL_MIN_PCT, min(VOL_MAX_PCT, pct))
    rc = run_cmd(f"amixer -q sset '{ALSA_VOL_CTRL}' {pct}%")
    if rc != 0:
        log(f"VOL set {pct}% failed, fallback numid=8")
        # Convert percentage to raw value (0-249 safe range for codec max 252)
        raw = (pct * 249) // 100
        run_cmd(f"amixer cset numid=8 {raw},{raw}")
    return pct


def save_volume():
    """Save current volume percentage for persistence across reboots."""
    try:
        r = subprocess.run(
            f"amixer sget '{ALSA_VOL_CTRL}'",
            shell=True, capture_output=True, text=True, timeout=3
        )
        if r.returncode == 0:
            m = re.search(r'\[(\d+)%\]', r.stdout)
            if m:
                os.makedirs(os.path.dirname(VOL_SAVE), exist_ok=True)
                with open(VOL_SAVE, "w") as f:
                    f.write(m.group(1))
    except Exception:
        pass


def volume_up():
    cur = get_volume_pct()
    if cur < 0:
        cur = 80  # assume default if read fails
    new = min(cur + VOL_STEP, VOL_MAX_PCT)
    log(f"VOL+ {cur}% -> {new}%")
    set_volume_pct(new)
    save_volume()


def volume_down():
    cur = get_volume_pct()
    if cur < 0:
        cur = 80
    new = max(cur - VOL_STEP, VOL_MIN_PCT)
    log(f"VOL- {cur}% -> {new}%")
    set_volume_pct(new)
    save_volume()


def get_brightness_pct():
    """Read current brightness as percentage from sysfs."""
    try:
        with open("/sys/class/backlight/backlight/brightness") as f:
            cur = int(f.read().strip())
        with open("/sys/class/backlight/backlight/max_brightness") as f:
            mx = int(f.read().strip())
        return (cur * 100) // mx if mx > 0 else 50
    except Exception:
        return 50


def save_brightness():
    """Save current brightness value for persistence across reboots."""
    try:
        with open("/sys/class/backlight/backlight/brightness") as f:
            val = f.read().strip()
        os.makedirs(os.path.dirname(BRIGHT_SAVE), exist_ok=True)
        with open(BRIGHT_SAVE, "w") as f:
            f.write(val)
    except Exception:
        pass


def brightness_up():
    log("BRIGHT+ brightnessctl s +3%")
    run_cmd(f"brightnessctl -q s +{BRIGHT_STEP}%")
    save_brightness()


def brightness_down():
    if get_brightness_pct() <= BRIGHT_MIN:
        return
    log(f"BRIGHT- brightnessctl s {BRIGHT_STEP}%-")
    run_cmd(f"brightnessctl -q s {BRIGHT_STEP}%-")
    # Clamp: if we went below minimum, set to minimum
    if get_brightness_pct() < BRIGHT_MIN:
        run_cmd(f"brightnessctl -q s {BRIGHT_MIN}%")
    save_brightness()


def speaker_toggle(headphone_in):
    if headphone_in:
        run_cmd(f"amixer -q sset '{ALSA_PATH_CTRL}' HP")
    else:
        run_cmd(f"amixer -q sset '{ALSA_PATH_CTRL}' SPK")


def kill_running_game():
    """Kill the currently running game/emulator (not ES)."""
    # Try pidfile first (set by retroarch-launch.sh and other wrappers)
    if os.path.exists(GAME_PIDFILE):
        try:
            with open(GAME_PIDFILE) as f:
                pid = int(f.read().strip())
            os.kill(pid, 9)
            log(f"KILL: killed PID {pid} from pidfile")
            try:
                os.remove(GAME_PIDFILE)
            except OSError:
                pass
            return True
        except (ValueError, ProcessLookupError):
            pass

    # Fallback: kill known emulator process names
    for proc in ['retroarch', 'drastic', 'ppsspp', 'mupen64plus', 'flycast',
                 'desmume', 'picodrive', 'mednafen', 'archr-gptokeyb']:
        rc = run_cmd(f"pkill -9 -x {proc}")
        if rc == 0:
            log(f"KILL: killed {proc}")
            return True

    log("KILL: no game process found")
    return False


def take_screenshot():
    """Capture framebuffer to PNG."""
    ts = time.strftime('%Y%m%d_%H%M%S')
    os.makedirs(SCREENSHOT_DIR, exist_ok=True)
    out = f"{SCREENSHOT_DIR}/screenshot_{ts}.png"
    # Try fbgrab first (produces PNG)
    rc = run_cmd(f"fbgrab {out}")
    if rc != 0:
        # Fallback: raw framebuffer dump
        raw = f"{SCREENSHOT_DIR}/screenshot_{ts}.raw"
        run_cmd(f"cp /dev/fb0 {raw}")
        log(f"SCREENSHOT: raw capture → {raw}")
    else:
        log(f"SCREENSHOT: {out}")


def toggle_wifi():
    """Toggle WiFi radio on/off via NetworkManager."""
    try:
        r = subprocess.run("nmcli radio wifi", shell=True,
                           capture_output=True, text=True, timeout=5)
        state = r.stdout.strip()
        if state == "enabled":
            run_cmd("nmcli radio wifi off")
            log("WIFI: disabled")
        else:
            run_cmd("nmcli radio wifi on")
            log("WIFI: enabled")
    except Exception as e:
        log(f"WIFI toggle error: {e}")


def find_devices():
    """Find and categorize input devices by capabilities (not just name).
    Works with gpio-keys, adc-keys, and archr-singleadc-joypad."""
    vol_dev = None    # device with KEY_VOLUMEUP (grab: exclusive volume control)
    pad_dev = None    # device with BTN_SOUTH (no grab: monitor passively)
    sw_dev = None     # headphone jack (switch events)

    for path in evdev.list_devices():
        try:
            dev = evdev.InputDevice(path)
            caps = dev.capabilities()
            key_caps = caps.get(ecodes.EV_KEY, [])

            # Volume device: has KEY_VOLUMEUP
            if ecodes.KEY_VOLUMEUP in key_caps and not vol_dev:
                vol_dev = dev
            # Gamepad: has BTN_SOUTH or BTN_DPAD_UP (but NOT volume keys)
            elif (ecodes.BTN_SOUTH in key_caps or ecodes.BTN_DPAD_UP in key_caps) and not pad_dev:
                pad_dev = dev

            # Headphone jack switch events (from rk817 or similar codec)
            if ecodes.EV_SW in caps and not sw_dev:
                sw_dev = dev

        except Exception:
            continue

    return vol_dev, pad_dev, sw_dev


def main():
    print("Arch R Hotkey Daemon starting...")

    # Detect ALSA control names (Master vs DAC, Playback Mux vs Playback Path)
    detect_alsa_controls()
    print(f"  ALSA volume: '{ALSA_VOL_CTRL}', path: '{ALSA_PATH_CTRL}'")

    # Wait for input devices to appear
    # adc-keys (vol_dev) loads instantly (built-in), but singleadc-joypad (pad_dev)
    # is a module that loads later. Wait for BOTH, with a timeout for pad_dev.
    vol_dev, pad_dev, sw_dev = None, None, None
    for attempt in range(30):
        vol_dev, pad_dev, sw_dev = find_devices()
        if vol_dev and pad_dev:
            break
        # After 10s, start with just vol_dev (pad_dev may not exist on all boards)
        if vol_dev and attempt >= 10:
            log(f"WARN: pad_dev not found after {attempt}s, starting without gamepad")
            break
        time.sleep(1)

    if not vol_dev:
        print("ERROR: Volume input device (gpio-keys-vol) not found!")
        sys.exit(1)

    # Grab volume device exclusively (we handle volume events)
    vol_dev.grab()
    print(f"  Volume: {vol_dev.name} ({vol_dev.path}) [grabbed]")

    # Monitor gamepad passively for MODE button (brightness hotkey)
    devices = [vol_dev]
    if pad_dev:
        # DO NOT grab — ES needs this device for gamepad input
        print(f"  Gamepad: {pad_dev.name} ({pad_dev.path}) [passive]")
        devices.append(pad_dev)
    else:
        print("  Gamepad: not found yet (will rescan)")

    if sw_dev and sw_dev not in devices:
        print(f"  Switch: {sw_dev.name} ({sw_dev.path}) [passive]")
        devices.append(sw_dev)

    # Track button states
    mode_held = False
    select_held = False
    start_held = False
    kill_combo_start = 0.0  # monotonic time when SELECT+START both held
    # Throttle: last time a volume/brightness action was executed
    last_vol_action = 0.0
    # Rescan timer: if pad_dev was not found at startup, try again periodically
    last_rescan = time.monotonic()

    print("Hotkey daemon ready.")
    # Clear previous log on fresh start
    try:
        with open(LOGFILE, "w") as f:
            f.write(f"{time.strftime('%H:%M:%S')} === Daemon started (fresh) ===\n")
    except Exception:
        pass
    log(f"  vol_dev: {vol_dev.name} ({vol_dev.path})")
    if pad_dev:
        log(f"  pad_dev: {pad_dev.name} ({pad_dev.path})")
    else:
        log("  pad_dev: NOT FOUND (will rescan every 5s)")

    # Startup amixer diagnostic — confirm volume control works from daemon context
    log("--- Startup ALSA diagnostic ---")
    log(f"  vol_ctrl='{ALSA_VOL_CTRL}' path_ctrl='{ALSA_PATH_CTRL}'")
    r = subprocess.run(f"amixer sget '{ALSA_VOL_CTRL}' 2>&1", shell=True, capture_output=True, text=True, timeout=5)
    log(f"  amixer sget '{ALSA_VOL_CTRL}' rc={r.returncode}")
    for line in r.stdout.strip().split('\n'):
        log(f"    {line}")
    if r.stderr.strip():
        log(f"  stderr: {r.stderr.strip()}")
    # Volume NOT set here — user's saved volume is restored by emulationstation.sh
    log("--- End ALSA diagnostic ---")

    try:
        while True:
            # Rescan for pad_dev if not found yet (module may load late)
            if not pad_dev and time.monotonic() - last_rescan >= 5.0:
                last_rescan = time.monotonic()
                _, new_pad, new_sw = find_devices()
                if new_pad:
                    pad_dev = new_pad
                    devices.append(pad_dev)
                    log(f"RESCAN: pad_dev found: {pad_dev.name} ({pad_dev.path})")
                if new_sw and new_sw not in devices:
                    sw_dev = new_sw
                    devices.append(sw_dev)
                    log(f"RESCAN: sw_dev found: {sw_dev.name} ({sw_dev.path})")

            # Fast poll when kill combo is pending, otherwise idle
            timeout = 0.1 if kill_combo_start > 0 else 2.0
            r, _, _ = select.select(devices, [], [], timeout)

            # Check kill combo hold timer
            if kill_combo_start > 0:
                if select_held and start_held:
                    if time.monotonic() - kill_combo_start >= KILL_HOLD_TIME:
                        kill_running_game()
                        kill_combo_start = 0
                else:
                    kill_combo_start = 0  # one was released

            for dev in r:
                try:
                    for event in dev.read():
                        if event.type == ecodes.EV_KEY:
                            key = event.code
                            val = event.value  # 1=press, 0=release, 2=repeat
                            keyname = ecodes.KEY.get(key, ecodes.BTN.get(key, f"?{key}"))
                            valname = {0: "UP", 1: "DOWN", 2: "REPEAT"}.get(val, f"?{val}")
                            log(f"KEY: {keyname}({key}) {valname} dev={dev.name} mode={mode_held}")

                            # Track MODE button from gamepad (passive)
                            if key == ecodes.BTN_MODE:
                                mode_held = (val >= 1)

                            # Track SELECT for kill combo
                            elif key == ecodes.BTN_SELECT:
                                select_held = (val >= 1)
                                if select_held and start_held and kill_combo_start == 0:
                                    kill_combo_start = time.monotonic()

                            # Track START for kill combo
                            elif key == ecodes.BTN_START:
                                start_held = (val >= 1)
                                if select_held and start_held and kill_combo_start == 0:
                                    kill_combo_start = time.monotonic()

                            # Volume keys (grabbed): accept press + repeat,
                            # but throttle to max ~3 events/sec (300ms interval).
                            # MUST come before MODE combos — the generic mode_held
                            # handler would swallow volume keys otherwise.
                            elif key == ecodes.KEY_VOLUMEUP and val in (1, 2):
                                now = time.monotonic()
                                if now - last_vol_action >= VOL_THROTTLE:
                                    last_vol_action = now
                                    if mode_held:
                                        brightness_up()
                                    else:
                                        volume_up()

                            elif key == ecodes.KEY_VOLUMEDOWN and val in (1, 2):
                                now = time.monotonic()
                                if now - last_vol_action >= VOL_THROTTLE:
                                    last_vol_action = now
                                    if mode_held:
                                        brightness_down()
                                    else:
                                        volume_down()

                            # MODE combos (on initial press only, non-volume keys)
                            elif mode_held and val == 1:
                                if key == ecodes.BTN_EAST:    # B button
                                    take_screenshot()
                                elif key == ecodes.BTN_NORTH:  # X button
                                    toggle_wifi()

                        # Headphone jack switch
                        elif event.type == ecodes.EV_SW:
                            if event.code == ecodes.SW_HEADPHONE_INSERT:
                                speaker_toggle(event.value == 1)

                except OSError:
                    # Device disconnected
                    pass

    except KeyboardInterrupt:
        pass
    finally:
        try:
            vol_dev.ungrab()
        except Exception:
            pass
        print("Hotkey daemon stopped.")


if __name__ == "__main__":
    main()
