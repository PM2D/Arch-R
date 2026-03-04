#!/bin/bash
# NAME: USB Mode
. /usr/lib/archr/menu-lib.sh
tool_init

while true; do
    if [ -d /sys/kernel/config/usb_gadget/archr ]; then
        STATUS="Gadget (file transfer)"
    else
        STATUS="Host (default)"
    fi

    menu_select "USB Mode — Current: $STATUS" \
        "Host Mode (USB devices)" \
        "Gadget Mode (file transfer)" || break

    case "$MENU_RESULT" in
        0)
            archr-usbgadget stop 2>/dev/null
            msg_show "USB Mode" "Host mode enabled.\nConnect USB controllers or drives."
            ;;
        1)
            archr-usbgadget start 2>/dev/null
            msg_show "USB Mode" "Gadget mode enabled.\nConnect USB cable to PC."
            ;;
    esac
done
