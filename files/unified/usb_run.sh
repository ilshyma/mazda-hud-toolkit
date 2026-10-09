#!/bin/sh
# ============================================================================
#  USB install / uninstall / check of the unified HUD patch — no laptop needed.
#
#  Lives on the USB stick in hud-mod/ next to the package (install.sh,
#  uninstall.sh, the shims, ...). The toolkit's USB unlock stick starts it
#  from its on-screen XSS menu (buttons HUD+ / HUD- / HUD?) through the same
#  CGI its SSH button uses:
#     sh <stick>/hud-mod/usb_run.sh install|uninstall|status [TOKEN]
#  (the stick is /tmp/mnt/sdX1 or /mnt/sdX1 depending on the firmware).
#  TOKEN tags /tmp/hud-usb-status.js, which the panel polls to print the
#  progress itself, so the user sees something even with no native dialog.
#  "check" is the console variant of status for the toolkits over SSH: prints
#  one OK/FAIL/MISS line per shim, no dialog, no lock, no log; exit 0 = all
#  loaded, 1 = problem, 3 = not installed.
#  That menu fires every command several ways at once, so this script takes
#  a lock and only the first copy does anything.
#
#  The user sees one native dialog per run on the centre display, written to
#  be photographed and sent for support: what happened in plain words, an
#  error code (E1..E9), firmware + region, and what to do next.
#  Every run gets its own folder on the stick, numbered because the CMU clock
#  reads 1970 right after boot:
#     hud-mod/logs/NNN_<action>_<date>/RESULT.txt   the text on the screen
#                                      run.log      the full log
#                                      system.txt   snapshot for remote analysis
#     hud-mod/logs/LAST_RESULT.txt                  copy of the latest RESULT
#  install/uninstall reboot on success only; status never reboots.
# ============================================================================
ACTION=${1:-}
TOKEN=$(printf '%s' "${2:-}" | tr -cd 'A-Za-z0-9' | cut -c1-40)  # the panel's run id
D=$(cd "$(dirname "$0")" && pwd)
LOCK=/tmp/hud-usb.lock
TITLE="HUD patch: CarPlay + Android Auto"
DLG=/jci/tools/jci-dialog
PHOTO="Photo this screen and send it to the author."

pid_of() { ps | awk -v p="$1" 'index($0, p) && !/awk/ { print $1; exit }'; }
SHIMS="L_jciCARPLAY:blmjcicarplay:CarPlay L_jciAAPA:blmjciaapa:AndroidAuto /usr/bin/aap_service:aap_service:AA-1.6 L_jcinavi:svcjcinavi:Navi/speed"
# shim_state SPEC -> prints "OK|NOT loaded|not running" for one shim
shim_state() {
  svc=${1%%:*}; rest=${1#*:}; so=${rest%%:*}
  pid=$(pid_of "$svc")
  if [ -z "$pid" ]; then echo "not running"
  elif grep -q "libpatch-$so.so" "/proc/$pid/maps" 2>/dev/null; then echo "OK"
  else echo "NOT loaded"; fi
}

case "$ACTION" in
  install|uninstall|status) ;;
  check)
    [ -f /data_persist/oem-aa-mod/libpatch-svcjcinavi.so ] || { echo "MISS the HUD patch is not installed"; exit 3; }
    rc=0
    for spec in $SHIMS; do
      label=${spec##*:}; st=$(shim_state "$spec")
      case "$st" in OK) echo "OK   $label: shim loaded" ;; "not running") echo "MISS $label: service not running"; rc=1 ;; *) echo "FAIL $label: shim NOT loaded"; rc=1 ;; esac
    done
    echo "INFO NaviSupported=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml | grep -oE '[A-Z]+$')"
    echo "INFO config: $(grep -E '^(hud_transport|force_street_name|force_street_name_native|use_protocol_v1_6)' /data_persist/oem-aa-mod/libpatch.conf | tr '\n' ' ')"
    echo "INFO stock-nav speed shared with CarPlay: $(cat /tmp/hud_oem_speed 2>/dev/null || echo 'none yet')"
    exit $rc ;;
  *) echo "usage: $0 install|uninstall|status|check"; exit 2 ;;
esac
# --- one copy only ----------------------------------------------------------
# The lock holds the owner's pid, so a run that died (the unit kept /tmp) does
# not block every later tap until the next reboot.
take_lock() {
  if mkdir "$LOCK" 2>/dev/null; then echo $$ > "$LOCK/pid"; return 0; fi
  old=$(cat "$LOCK/pid" 2>/dev/null)
  if [ -z "$old" ]; then                       # a twin started this instant
    sleep 2; old=$(cat "$LOCK/pid" 2>/dev/null)
  fi
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then return 1; fi
  rm -rf "$LOCK"
  mkdir "$LOCK" 2>/dev/null || return 1
  echo $$ > "$LOCK/pid"
}
take_lock || exit 0
trap 'rm -rf "$LOCK"' EXIT

# --- live progress for the XSS panel ---------------------------------------
# /tmp is always writable; the panel polls this file and prints the lines,
# so even if the native dialog cannot be shown the user sees what happens.
STATUS_TXT=/tmp/hud-usb-status.txt
STATUS_JS=/tmp/hud-usb-status.js
RUNID=${TOKEN:-$ACTION}
PANEL_DONE=false
: > "$STATUS_TXT"
panel() {  # line — append to the panel; panel "" just republishes
  [ -n "$1" ] && printf '%s\n' "$1" >> "$STATUS_TXT"
  {
    printf 'window.hudUsbStatus={id:"%s",action:"%s",done:%s,lines:[' "$RUNID" "$ACTION" "$PANEL_DONE"
    sed 's/\\/\\\\/g; s/"/\\"/g; s/.*/"&",/' "$STATUS_TXT" | tr -d '\n' | sed 's/,$//'
    printf ']};\n'
  } > "$STATUS_JS.tmp" && mv "$STATUS_JS.tmp" "$STATUS_JS"
}
panel "The unit received the command: $ACTION (from $D, user $(id -un 2>/dev/null || id -u))"

dialog() {  # text — replaces whatever dialog is showing; mirrored to the panel
  printf '%b\n' "$1" | while IFS= read -r l; do panel "$l"; done
  killall -q jci-dialog 2>/dev/null
  [ -x "$DLG" ] && "$DLG" --info --title="$TITLE" --text="$1" --no-cancel &
  echo "[screen] $1"
}
case "$ACTION" in
  install)   dialog "Installing the HUD patch...\nDo not remove the USB drive." ;;
  uninstall) dialog "Removing the HUD patch...\nDo not remove the USB drive." ;;
  status)    dialog "Checking the HUD patch..." ;;
esac

VER=$(grep '^JCI_SW_VER=' /jci/version.ini 2>/dev/null | cut -d'"' -f2 | sed 's/MAZ_CMU-150_//')
FLAVOR=$(grep '^JCI_SW_FLAVOR=' /jci/version.ini 2>/dev/null | cut -d'"' -f2 | sed 's/cmu150_//')
FREE=$(df -k /data_persist 2>/dev/null | awk 'NR==2 {print int($4/1024)}')
STAMP=$(date +%Y%m%d-%H%M%S)
FACTS="FW ${VER:-?} ${FLAVOR:-?} | free ${FREE:-?} MB | $STAMP"

# --- logs on the stick ------------------------------------------------------
# The media player mounts the stick read-only: remount its MOUNT POINT (not a
# folder inside it) read-write. If that is impossible, keep the logs in /tmp
# and say so on screen.
MNT=$(awk -v d="$D/" 'index(d, $2 "/") == 1 && length($2) > length(m) { m = $2 } END { print m }' /proc/mounts 2>/dev/null)
[ -n "$MNT" ] && [ "$MNT" != / ] && mount -o remount,rw "$MNT" 2>/dev/null
LOGBASE="$D/logs"; LOGNOTE=""
if ! { mkdir -p "$LOGBASE" && touch "$LOGBASE/.w" && rm -f "$LOGBASE/.w"; } 2>/dev/null; then
  LOGBASE=/tmp/hud-mod-logs; LOGNOTE="USB is read-only: logs kept on the unit in $LOGBASE"
  mkdir -p "$LOGBASE"
  panel "$LOGNOTE"
fi
n=$(ls -d "$LOGBASE"/[0-9][0-9][0-9]_* 2>/dev/null | sed 's#.*/\([0-9]*\)_.*#\1#' | sort -n | tail -1)
n=$(echo "${n:-0}" | sed 's/^0*//'); n=$(( ${n:-0} + 1 )); n=$(printf '%03d' "$n" 2>/dev/null || echo "$n")
RUN="$LOGBASE/${n}_${ACTION}_$STAMP"
mkdir -p "$RUN"
LOG="$RUN/run.log"
exec > "$LOG" 2>&1
echo "=== hud-mod USB $ACTION | $FACTS | uptime $(cut -d' ' -f1 /proc/uptime) | from $D | mount $MNT"
[ -n "$LOGNOTE" ] && echo "NOTE: $LOGNOTE"
panel "Log: $RUN"
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
  [ -n "$LOGNOTE" ] && text="$text\n$LOGNOTE"
  printf '%b\n' "$text" > "$RUN/RESULT.txt"
  echo "log folder: $RUN/  (RESULT.txt, run.log, system.txt)" >> "$RUN/RESULT.txt"
  cp "$RUN/RESULT.txt" "$LOGBASE/LAST_RESULT.txt" 2>/dev/null
  snapshot
  dialog "$text\nFolder: $(basename "$LOGBASE")/$(basename "$RUN")"
  PANEL_DONE=true; panel ""
}
# What I would otherwise look at over SSH, saved next to the log.
snapshot() {
  {
    echo "=== $ACTION | $FACTS | uptime $(cut -d' ' -f1 /proc/uptime)"
    echo "--- version.ini"; grep -E '^JCI_(SW_VER|SW_FLAVOR|SW_VER_PATCH|OEM_PART_NUMBER)=' /jci/version.ini
    echo "--- sm configs (preloads + target services)"
    for c in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
      echo "[$c]"; grep -nE 'LD_PRELOAD|LD_LIBRARY_PATH|name="(jciCARPLAY|jciAAPA|jcinavi|aap_service)"' "$c" 2>/dev/null
    done
    echo "--- board type"; /jci/scripts/get_board_type.sh >/dev/null 2>&1; echo "get_board_type.sh=$?"
    echo "--- mod files"; ls -l /data_persist/oem-aa-mod/ /data_persist/cp-hud-mod/ /data_persist/hud-mod-backup/ 2>&1
    echo "--- shims md5"; md5sum /data_persist/oem-aa-mod/*.so 2>&1
    echo "--- libpatch.conf"; grep -v '^[[:space:]]*#' /data_persist/oem-aa-mod/libpatch.conf 2>/dev/null | grep .
    echo "--- shim state"; for spec in $SHIMS; do echo "${spec##*:}: $(shim_state "$spec")"; done
    echo "--- NaviSupported"; grep -o '<name>NaviSupported</name><value>[A-Z]*' /etc/devmgr_config_master.xml
    echo "--- stock nav"; ls -l /jci/navi/svcjcinavi.so 2>&1; md5sum /jci/navi/svcjcinavi.so 2>&1
    echo "--- hand-off state"; echo "hud_oem_speed=[$(cat /tmp/hud_oem_speed 2>/dev/null)] hud_carplay_active=[$(cat /tmp/hud_carplay_active 2>/dev/null)]"
    echo "--- storage"; df -k /data_persist /tmp / 2>&1
    echo "--- memory"; head -n 4 /proc/meminfo
    echo "--- processes"; ps | grep -E 'jciCARPLAY|jciAAPA|jcinavi|aap_service|NNG|jci-linux' | grep -v grep
    echo "--- dmesg (last 40)"; dmesg 2>/dev/null | tail -n 40
  } > "$RUN/system.txt" 2>&1
}

finish() {  # 0 = reboot, 1 = keep the message up and stop, 2 = done (no reboot)
  sync
  case "$1" in
    0) sleep 10; killall -q jci-dialog 2>/dev/null; sync; reboot ;;
    1) sleep 45; killall -q jci-dialog 2>/dev/null ;;
    2) sleep 30; killall -q jci-dialog 2>/dev/null ;;
  esac
  exit "$1"   # the EXIT trap drops the lock
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
      result E9 "The installer stopped unexpectedly." "${err:-no error text, see the full log}" "Send the photo and this folder from the USB." ;;
  esac
}

# a long run must not trip the hardware watchdog (same as the KidMixer USB installer)
echo 1 > "/sys/class/gpio/Watchdog Disable/value" 2>/dev/null

case "$ACTION" in
install)
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
  sh "$D/uninstall.sh"
  if grep -q 'DONE\. Reboot' "$LOG"; then
    result OK "HUD patch removed, back to stock. Rebooting in 10 s." "" ""
    finish 0
  fi
  result U1 "Removal did not finish." "$(grep -m1 -iE 'fail|error' "$LOG" | cut -c1-90)" "Send the photo and this folder from the USB."
  finish 1 ;;

status)
  # What a user can photograph when "it does not work": is each shim loaded?
  lines=""; bad=0
  for spec in $SHIMS; do
    st=$(shim_state "$spec")
    [ "$st" = OK ] || bad=$((bad + 1))
    lines="${lines:+$lines\n}${spec##*:}: $st"
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
