#!/bin/sh
# Bridge between the CMU's native USB-update trigger and hud-mod/usb_run.sh.
# Trigger: jci-autoupdate on the USB starts the CMU's reflash scanner, which
# passes .up filenames to system() unsanitized (CVE-2024-8359 / ZDI-24-1191).
# Crafted .up filenames encode "sh /mnt/sd[abcd]1/t" via awk sprintf (the 't'
# trampoline deduplicates and calls this script).  Fallback for v58 and older:
# CMD_LINE=sh /mnt/sd*/tweaks.sh in dataRetrieval_config.txt (removed in v59+).
# Shows an Install/Uninstall/Status dialog, then delegates to usb_run.sh.
MYDIR=$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")
RUNNER="$MYDIR/hud-mod/usb_run.sh"
DLG=/jci/tools/jci-dialog
TITLE="HUD Patch: CarPlay + Android Auto"

hwclock --hctosys 2>/dev/null
echo 1 > "/sys/class/gpio/Watchdog Disable/value" 2>/dev/null

if [ ! -f "$RUNNER" ]; then
    $DLG --info --title="$TITLE" \
      --text="ERROR: hud-mod folder not found on USB.\nRecreate the stick with the toolkit." \
      --no-cancel &
    sleep 15; killall -q jci-dialog; exit 1
fi

# Detect current state
HUD_INSTALLED=false
WCP_ENABLED=false
[ -f /data_persist/oem-aa-mod/libpatch-svcjcinavi.so ] && HUD_INSTALLED=true
grep -q "vim_app" /jci/scripts/get_board_type.sh 2>/dev/null && WCP_ENABLED=true

if [ "$HUD_INSTALLED" = true ]; then
    if [ "$WCP_ENABLED" = true ]; then
        WCP_TAG=" | WCP: ON"
    else
        WCP_TAG=" | WCP: OFF"
    fi
    $DLG --3-button-dialog --title="$TITLE" \
      --text="HUD patch is installed${WCP_TAG}.\nWhat would you like to do?" \
      --ok-label="Uninstall HUD" --cancel-label="Wireless CarPlay" --button3-label="Check Status"
    CHOICE=$?
    if [ "$CHOICE" -eq 0 ]; then
        sh "$RUNNER" uninstall
    elif [ "$CHOICE" -eq 1 ]; then
        if [ "$WCP_ENABLED" = true ]; then
            $DLG --question --title="Wireless CarPlay" \
              --text="Wireless CarPlay is currently ENABLED.\nDisable it?" \
              --ok-label="Disable WCP" --cancel-label="Keep"
            if [ $? -eq 0 ]; then
                sh "$RUNNER" wcp_disable
            fi
        else
            $DLG --question --title="Wireless CarPlay" \
              --text="Enable native Wireless CarPlay?\n(iPhone connects via WiFi, no cable needed)\n\nNote: 2.4 GHz WiFi only." \
              --ok-label="Enable WCP" --cancel-label="Cancel"
            if [ $? -eq 0 ]; then
                sh "$RUNNER" wcp_enable
            fi
        fi
    else
        sh "$RUNNER" status
    fi
else
    $DLG --question --title="$TITLE" \
      --text="Install CarPlay + Android Auto HUD patch?" \
      --ok-label="Install" --cancel-label="Cancel"
    if [ $? -eq 0 ]; then
        sh "$RUNNER" install
    else
        $DLG --info --title="$TITLE" \
          --text="Cancelled. You can remove the USB drive." --no-cancel &
        sleep 10; killall -q jci-dialog
    fi
fi
