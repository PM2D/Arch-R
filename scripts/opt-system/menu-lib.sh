#!/bin/bash
# Arch R — Shared menu library for system tools
# Source this at the top of each tool script:
#   . /usr/lib/archr/menu-lib.sh
#
# Provides:
#   tool_init          — start gptokeyb, set up console
#   tool_cleanup       — kill gptokeyb (called automatically on exit)
#   menu_select TITLE ITEM1 ITEM2 ...  — interactive menu, sets MENU_RESULT
#   msg_show TITLE TEXT                — display text, wait for A/B to return
#
# gptokeyb maps: D-pad=arrows, A/Start=Enter, B/Back=Escape

export TERM=linux
GPTK_PID=""

tool_init() {
    # Redirect stdin from tty1 (ES may have it as /dev/null)
    exec < /dev/tty1

    # Force fbcon redraw by clearing the console
    clear

    # Start gptokeyb for gamepad → keyboard mapping
    if [ -x /usr/local/bin/archr-gptokeyb ]; then
        /usr/local/bin/archr-gptokeyb "tool-menu" \
            -c /etc/archr/gptokeyb/tools.gptk &>/dev/null &
        GPTK_PID=$!
        # Wait for uinput device to register
        sleep 0.2
    fi
}

tool_cleanup() {
    # Kill gptokeyb if we started it
    if [ -n "$GPTK_PID" ]; then
        kill "$GPTK_PID" 2>/dev/null
        wait "$GPTK_PID" 2>/dev/null
        GPTK_PID=""
    fi
    # Show cursor
    tput cnorm 2>/dev/null
}

# Ensure cleanup runs on exit
trap tool_cleanup EXIT

# menu_select TITLE ITEM1 ITEM2 ...
# Sets MENU_RESULT to selected index (0-based)
# Returns 0 on select (A/Enter), 1 on cancel (B/Escape)
menu_select() {
    local title="$1"; shift
    local options=("$@")
    local selected=0
    local count=${#options[@]}

    tput civis 2>/dev/null  # hide cursor

    while true; do
        clear
        echo "==============================="
        echo "  $title"
        echo "==============================="
        echo ""

        for i in "${!options[@]}"; do
            if [ "$i" -eq "$selected" ]; then
                # Highlighted: inverse video
                echo -e "  \e[7m> ${options[$i]}\e[0m"
            else
                echo "    ${options[$i]}"
            fi
        done

        echo ""
        echo "  [D-pad] Navigate  [A] Select  [B] Back"

        # Read one character
        IFS= read -rsn1 key

        case "$key" in
            $'\x1b')
                # Escape sequence: read the rest (e.g. [A for up arrow)
                IFS= read -rsn2 -t 0.2 seq
                case "$seq" in
                    "[A") [ "$selected" -gt 0 ] && selected=$((selected - 1)) ;;
                    "[B") [ "$selected" -lt $((count - 1)) ] && selected=$((selected + 1)) ;;
                esac
                # Bare Escape (no seq) = cancel
                [ -z "$seq" ] && { tput cnorm 2>/dev/null; return 1; }
                ;;
            "")
                # Enter key = select
                tput cnorm 2>/dev/null
                MENU_RESULT=$selected
                return 0
                ;;
        esac
    done
}

# msg_show TITLE TEXT
# Displays text and waits for any key (A/B/Enter/Escape)
msg_show() {
    local title="$1"; shift
    local text="$*"

    tput civis 2>/dev/null
    clear
    echo "==============================="
    echo "  $title"
    echo "==============================="
    echo ""
    echo -e "$text"
    echo ""
    echo "  [A/B] Back"

    # Wait for any key
    IFS= read -rsn1 _
    # Consume escape sequence if arrow key was pressed
    IFS= read -rsn2 -t 0.1 _ 2>/dev/null
    tput cnorm 2>/dev/null
}
