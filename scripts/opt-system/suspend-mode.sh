#!/bin/bash
# NAME: Sleep Mode
. /usr/lib/archr/menu-lib.sh
tool_init

while true; do
    CURRENT=$(archr-suspend-mode status 2>/dev/null || echo "unknown")

    menu_select "Sleep Mode — Current: $CURRENT" \
        "Deep Sleep (mem)" \
        "Freeze (s2idle)" \
        "Disable Sleep" || break

    case "$MENU_RESULT" in
        0)
            archr-suspend-mode mem 2>/dev/null
            msg_show "Sleep Mode" "Deep sleep (mem) enabled.\nLowest power, slower wake."
            ;;
        1)
            archr-suspend-mode freeze 2>/dev/null
            msg_show "Sleep Mode" "Freeze (s2idle) enabled.\nModerate power, fast wake."
            ;;
        2)
            archr-suspend-mode off 2>/dev/null
            msg_show "Sleep Mode" "Sleep disabled."
            ;;
    esac
done
