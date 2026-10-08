#!/bin/sh
# ============================================================================
#  USB install / uninstall / check of the unified HUD patch — no laptop needed.
#
#  Lives on the USB stick in hud-mod/ next to the package (install.sh,
#  uninstall.sh, the shims, ...). The toolkit's USB unlock stick starts it
#  from its on-screen XSS menu (buttons HUD+ / HUD- / HUD?) through the same
#  CGI its SSH button uses:
#     sh /tmp/mnt/sdX1/hud-mod/usb_run.sh install|uninstall|status
#  That menu fires every command several ways at once, so this script takes
#  a lock and only the first copy does anything.
#
#  The user sees one native dialog per run on the centre display, written to
#  be photographed and sent for support: what happened in plain words, an
#  error code (E1..E9), firmware + region, and what to do next. The same text
#  goes to hud-mod/logs/RESULT.txt on the stick, next to the full log.
#  install/uninstall reboot on success only; status never reboots.
# ============================================================================
ACTION=${1:-}
D=$(cd "$(dirname "$0")" && pwd)
LOCK=/tmp/hud-usb.lock
TITLE="HUD patch: CarPlay + Android Auto"
DLG=/jci/tools/jci-dialog
PHOTO="Photo this screen and send it to the author."

case "$ACTION" in install|uninstall|status) ;; *) echo "usage: $0 install|uninstall|status"; exit 2 ;; esac
mkdir "$LOCK" 2>/dev/null || exit 0          # another copy is already running

mount -o rw,remount "$D" 2>/dev/null         # FAT stick may be mounted ro
mkdir -p "$D/logs"
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$D/logs/$ACTION-$STAMP.log"
exec > "$LOG" 2>&1

VER=$(grep '^JCI_SW_VER=' /jci/version.ini 2>/dev/null | cut -d'"' -f2 | sed 's/MAZ_CMU-150_//')
FLAVOR=$(grep '^JCI_SW_FLAVOR=' /jci/version.ini 2>/dev/null | cut -d'"' -f2 | sed 's/cmu150_//')
FREE=$(df -k /data_persist 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
FACTS="FW ${VER:-?} ${FLAVOR:-?} | free ${FREE:-?} MB | $STAMP"
echo "=== hud-mod USB $ACTION | $FACTS | uptime $(cut -d' ' -f1 /proc/uptime) | from $D"

dialog() {  # text — replaces whatever dialog is showing
  killall -q jci-dialog 2>/dev/null
  [ -x "$DLG" ] && "$DLG" --info --title="$TITLE" --text="$1" --no-cancel &
  echo "[screen] $1"
}
# result CODE  HEADLINE  DETAIL  ADVICE  — the screen meant to be photographed.
# CODE: OK, E*/U* (errors), S0 (check: not installed), S1 (check: problem).
result() {
  code=$1; head=$2; detail=$3; advice=$4
  case "$code" in
    OK) text="$head" ;;
    S0) text="CHECK: $head" ;;
    S*) text="CHECK $code: $head" ;;
    *)  text="ERROR $code: $head" ;;
  esac
  [ -n "$detail" ] && text="$text\n$detail"
  [ -n "$advice" ] && text="$text\n$advice"
  text="$text\n$FACTS"
  case "$code" in OK|S0) ;; *) text="$text\n$PHOTO" ;; esac
  printf '%b\n' "$text" > "$D/logs/RESULT.txt"
  echo "full log: logs/$(basename "$LOG")" >> "$D/logs/RESULT.txt"
  dialog "$text"
}
finish() {  # 0 = reboot, 1 = keep the message up and stop, 2 = done (no reboot)
  sync
  case "$1" in
    0) sleep 10; killall -q jci-dialog 2>/dev/null; sync; reboot ;;
    1) sleep 45; killall -q jci-dialog 2>/dev/null ;;
    2) sleep 30; killall -q jci-dialog 2>/dev/null ;;
  esac
  rmdir "$LOCK" 2>/dev/null
  exit "$1"
}

# Turn install.sh's last ERROR line into a code + plain explanation + advice.
explain_install_failure() {
  err=$(grep -m1 'ERROR:' "$LOG" | sed 's/.*ERROR: //')
  extra=$(grep -E '^  (foreign LD_PRELOAD|service .* not found)' "$LOG" | head -2 | sed 's/^ *//; s/<environ_var.*env_value="\([^"]*\)".*/\1/; s/[[:space:]][[:space:]]*/ /g')
  case "$err" in
    *"not a CMU"*)
      result E2 "This is not a supported Mazda CMU." "${err}" "Nothing was changed." ;;
    *"missing "*)
      result E1 "A file is missing on the USB stick." "${err}" "Copy the stick again with the toolkit. Nothing was changed." ;;
    *"is not as expected"*)
      result E3 "The system config of this unit is unusual." "${extra:-$err}" "Another mod may be installed. Nothing was changed." ;;
    *"remount rw failed"*)
      result E4 "Could not unlock the system partition." "${err}" "Restart the car and try again. Nothing was changed." ;;
    *"copy "*|*"mkdir failed"*|*"write "*)
      result E5 "Could not write to the unit's storage." "${err}" "Storage may be full (free ${FREE:-?} MB)." ;;
    *"sanity check"*|*"strip failed"*|*"expected 4 target"*)
      result E6 "The system config could not be patched safely." "${err}" "It was left untouched." ;;
    *)
      result E9 "The installer stopped unexpectedly." "${err:-no error text, see the full log}" "Send the photo and logs/$(basename "$LOG") from the USB." ;;
  esac
}

# a long run must not trip the hardware watchdog (same as the KidMixer USB installer)
echo 1 > "/sys/class/gpio/Watchdog Disable/value" 2>/dev/null

case "$ACTION" in
install)
  dialog "Installing the HUD patch...\nDo not remove the USB drive."
  # the shims must be exactly the released ones (a half-copied stick is common)
  bad=""
  [ -f "$D/MD5SUMS" ] || bad=" MD5SUMS"
  while read -r sum name; do
    [ -n "$name" ] || continue
    got=$(md5sum "$D/$name" 2>/dev/null | cut -d' ' -f1)
    [ "$got" = "$sum" ] || bad="$bad $name"
  done < "$D/MD5SUMS" 2>/dev/null
  if [ -n "$bad" ]; then
    result E1 "Damaged file(s) on the USB stick:" "$bad" "Copy the stick again with the toolkit. Nothing was changed."
    finish 1
  fi
  sh "$D/install.sh"
  if grep -q 'DONE\. Reboot' "$LOG"; then
    # one of the two AA XMLs being skipped is normal (they target different
    # hardware); only worth a note if neither was installed
    warn=$(grep 'WARNING' "$LOG" | grep -v 'fine if the other XML installed' | head -1 | sed 's/.*WARNING: //' | cut -c1-90)
    grep -q 'installed /etc/aap_system_attributes' "$LOG" || \
      warn="Android Auto XML not installed: AA HUD guidance may not work"
    result OK "HUD patch installed. Rebooting in 10 s." "${warn:+Note: $warn}" ""
    finish 0
  fi
  explain_install_failure
  finish 1 ;;

uninstall)
  dialog "Removing the HUD patch...\nDo not remove the USB drive."
  sh "$D/uninstall.sh"
  if grep -q 'DONE\. Reboot' "$LOG"; then
    result OK "HUD patch removed, back to stock. Rebooting in 10 s." "" ""
    finish 0
  fi
  result U1 "Removal did not finish." "$(grep -m1 -iE 'fail|error' "$LOG" | cut -c1-90)" "Send the photo and logs/$(basename "$LOG") from the USB."
  finish 1 ;;

status)
  # What a user can photograph when "it does not work": is each shim loaded?
  pid_of() { ps | awk -v p="$1" 'index($0, p) && !/awk/ { print $1; exit }'; }
  lines=""; bad=0
  for pair in L_jciCARPLAY:blmjcicarplay:CarPlay L_jciAAPA:blmjciaapa:AndroidAuto \
              /usr/bin/aap_service:aap_service:AA-1.6 L_jcinavi:svcjcinavi:Navi/speed; do
    svc=${pair%%:*}; rest=${pair#*:}; so=${rest%%:*}; label=${rest#*:}
    pid=$(pid_of "$svc")
    if [ -z "$pid" ]; then st="not running"; bad=$((bad + 1))
    elif grep -q "libpatch-$so.so" "/proc/$pid/maps" 2>/dev/null; then st="OK"
    else st="NOT loaded"; bad=$((bad + 1)); fi
    lines="${lines:+$lines\n}$label: $st"
  done
  installed=$([ -f /data_persist/oem-aa-mod/libpatch-svcjcinavi.so ] && echo yes || echo no)
  speed=$(cat /tmp/hud_oem_speed 2>/dev/null || echo none)
  if [ "$installed" = no ]; then
    result S0 "The HUD patch is not installed." "${lines}" "Use HUD+ to install it."
  elif [ "$bad" = 0 ]; then
    result OK "HUD patch is working." "$lines\nnav speed: $speed" ""
  else
    result S1 "HUD patch installed but $bad part(s) not active." "${lines}" "Restart the car once. If it stays, send this photo."
  fi
  finish 2 ;;
esac
