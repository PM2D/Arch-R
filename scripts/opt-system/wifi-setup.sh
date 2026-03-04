#!/bin/bash
# NAME: WiFi
. /usr/lib/archr/menu-lib.sh
tool_init

while true; do
    WIFI_STATE=$(nmcli radio wifi 2>/dev/null)
    if [ "$WIFI_STATE" = "enabled" ]; then
        SSID=$(nmcli -t -f active,ssid dev wifi 2>/dev/null | grep '^yes' | cut -d: -f2)
        [ -n "$SSID" ] && STATUS="ON (Connected: $SSID)" || STATUS="ON (not connected)"
        TOGGLE_LABEL="Turn WiFi OFF"
    else
        STATUS="OFF"
        TOGGLE_LABEL="Turn WiFi ON"
    fi

    menu_select "WiFi — Status: $STATUS" \
        "$TOGGLE_LABEL" \
        "Disconnect" || break

    case "$MENU_RESULT" in
        0)  # Toggle
            if [ "$WIFI_STATE" = "enabled" ]; then
                nmcli radio wifi off 2>/dev/null
                msg_show "WiFi" "WiFi disabled."
            else
                nmcli radio wifi on 2>/dev/null
                msg_show "WiFi" "WiFi enabled.\nScanning for networks..."
            fi
            ;;
        1)  # Disconnect
            nmcli dev disconnect wlan0 2>/dev/null
            msg_show "WiFi" "Disconnected."
            ;;
    esac
done
