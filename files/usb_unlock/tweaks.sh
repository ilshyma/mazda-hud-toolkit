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

if [ -f /data_persist/oem-aa-mod/libpatch-svcjcinavi.so ]; then
    $DLG --question --title="$TITLE" \
      --text="The HUD patch is installed.\nWhat would you like to do?" \
      --ok-label="Uninstall" --cancel-label="Check Status"
    if [ $? -eq 0 ]; then
        sh "$RUNNER" uninstall
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
