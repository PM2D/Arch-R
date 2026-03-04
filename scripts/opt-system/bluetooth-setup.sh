#!/bin/bash
# NAME: Bluetooth
. /usr/lib/archr/menu-lib.sh
tool_init

while true; do
    if systemctl is-active bluetooth &>/dev/null; then
        STATUS="ON"
        PAIRED=$(bluetoothctl devices Paired 2>/dev/null)
        if [ -n "$PAIRED" ]; then
            PAIR_INFO=""
            while read -r _ mac name; do
                [ -z "$mac" ] && continue
                if bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes"; then
                    PAIR_INFO+="  * $name [connected]\n"
                else
                    PAIR_INFO+="    $name\n"
                fi
            done <<< "$PAIRED"
        fi
    else
        STATUS="OFF"
    fi

    menu_select "Bluetooth — Status: $STATUS" \
        "Toggle Bluetooth" \
        "Make Discoverable (60s)" || break

    case "$MENU_RESULT" in
        0)  # Toggle
            if systemctl is-active bluetooth &>/dev/null; then
                systemctl stop bluetooth 2>/dev/null
                msg_show "Bluetooth" "Bluetooth stopped."
            else
                systemctl start bluetooth 2>/dev/null
                msg_show "Bluetooth" "Bluetooth started."
            fi
            ;;
        1)  # Discoverable
            if ! systemctl is-active bluetooth &>/dev/null; then
                systemctl start bluetooth 2>/dev/null
                sleep 1
            fi
            bluetoothctl discoverable on 2>/dev/null
            bluetoothctl pairable on 2>/dev/null
            msg_show "Bluetooth" "Discoverable for 60 seconds.\nPair from your device now."
            bluetoothctl discoverable off 2>/dev/null
            ;;
    esac
done
