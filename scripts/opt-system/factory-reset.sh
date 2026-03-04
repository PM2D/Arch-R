#!/bin/bash
# NAME: Factory Reset
. /usr/lib/archr/menu-lib.sh
tool_init

menu_select "Factory Reset" \
    "Cancel" \
    "Reset ALL settings" || exit 0

case "$MENU_RESULT" in
    0)  # Cancel
        ;;
    1)  # Reset
        # Second confirmation
        menu_select "Are you sure? ROMs/saves kept." \
            "No, cancel" \
            "Yes, reset everything" || exit 0

        if [ "$MENU_RESULT" -eq 1 ]; then
            clear
            echo "Resetting..."
            archr-factory-reset 2>/dev/null
            echo "Done. Restarting..."
            sleep 1
            systemctl restart emulationstation 2>/dev/null || reboot
        fi
        ;;
esac
