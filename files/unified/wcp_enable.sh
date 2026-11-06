#!/bin/sh
# ============================================================================
#  Wireless CarPlay (WCP) enabler for Mazda CMU150 FW 74.00.324.
#  Enables native wireless Apple CarPlay on legacy CMU hardware that ships
#  with wired-only CarPlay by spoofing the board-type detection.
#
#  Based on Kenatia/mazda-cmu150-wcp-mod (MIT).
#  Modifications: get_board_type.sh (process spoofing), sm_WCP.conf
#  (GPS/reset_board tuning), autostart (ublox.txt prevention).
#
#  Run ON THE CMU as root.  Backs up originals to /data_persist/hud-mod-backup/.
#  Undo: wcp_disable.sh
# ============================================================================
set -u
TAG="[wcp enable]"
SRC=$(cd "$(dirname "$0")" && pwd)
MOD_VERSION=$(cat "$SRC/VERSION" 2>/dev/null | tr -d '[:space:]')
: "${MOD_VERSION:=unknown}"
BAK_DIR=/data_persist/hud-mod-backup
GBT=/jci/scripts/get_board_type.sh
SMW=/jci/sm/sm_WCP.conf
AUTOSTART=/usr/bin/autostart

log() { echo "$TAG $*"; }
die() { echo "$TAG ERROR: $*"; mount -o remount,ro / 2>/dev/null; exit 1; }

log "toolkit version: v$MOD_VERSION"

# --- preflight ---------------------------------------------------------------
CMU_VER=$(grep '^JCI_SW_VER=' /jci/version.ini 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
case "$CMU_VER" in
  74.00.324*) ;;
  *) die "only firmware V74.00.324 is supported (found: V${CMU_VER:-?})" ;;
esac
[ -f "$GBT" ]       || die "$GBT not found"
[ -f "$SMW" ]       || die "$SMW not found"
[ -f "$AUTOSTART" ] || die "$AUTOSTART not found"

# already enabled?
if grep -q "vim_app" "$GBT" 2>/dev/null; then
  log "WCP mod is already enabled (get_board_type.sh contains vim_app spoof)"
  exit 0
fi

# check GPIO: if this is already a WCP CMU, the mod is not needed
DI_TP1056=/sys/class/gpio/DI_TP1056/value
DI_TP1029=/sys/class/gpio/DI_TP1029/value
if [ -e "$DI_TP1056" ] && [ -e "$DI_TP1029" ]; then
  v1=$(cat "$DI_TP1056" 2>/dev/null)
  v2=$(cat "$DI_TP1029" 2>/dev/null)
  if [ "$v1" = "1" ] || [ "$v2" = "1" ]; then
    log "this CMU already has native WCP hardware (GPIO=${v1}/${v2}) — mod not needed"
    exit 0
  fi
fi

mount -o remount,rw / 2>/dev/null || die "remount rw failed"
mkdir -p "$BAK_DIR" || die "mkdir $BAK_DIR failed"

# --- 1) backup originals (first time only) -----------------------------------
for f in "$GBT" "$SMW" "$AUTOSTART"; do
  b="$BAK_DIR/$(basename "$f").pre_wcp"
  [ -f "$b" ] || { cp -a "$f" "$b" && log "backup $f -> $b"; }
done

# --- 2) autostart: prevent ublox.txt creation (avoids DTC B119F) --------------
if grep -qF 'WCP mod: do not create ublox.txt' "$AUTOSTART"; then
  log "autostart already patched, skipping"
else
  if [ "$(grep -cF 'touch "$UBLOX_FILE"' "$AUTOSTART")" != "1" ]; then
    die "exactly one 'touch \"\$UBLOX_FILE\"' line not found in autostart"
  fi
  sed '/touch "\$UBLOX_FILE"/s/.*/    test -e "$UBLOX_FILE" \&\& rm -f "$UBLOX_FILE" # WCP mod: do not create ublox.txt/' \
    "$AUTOSTART" > "${AUTOSTART}.new"
  if grep -qF 'touch "$UBLOX_FILE"' "${AUTOSTART}.new" \
     || [ "$(wc -l < "${AUTOSTART}.new")" != "$(wc -l < "$AUTOSTART")" ] \
     || ! sh -n "${AUTOSTART}.new"; then
    rm -f "${AUTOSTART}.new"
    die "autostart patch produced invalid result"
  fi
  mv -f "${AUTOSTART}.new" "$AUTOSTART"
  log "autostart: ublox.txt creation disabled"
fi

# --- 3) sm_WCP.conf: remove GPS=UBLOX, disable reset_board on jciLDS/jcinavi -
sed -i '/name="jciLDS"/{s/ GPS=UBLOX//;s/reset_board="yes"/reset_board="no"/}' "$SMW"
sed -i '/name="jcinavi"/{s/args="wcp"/args=""/;s/reset_board="yes"/reset_board="no"/}' "$SMW"
log "sm_WCP.conf: GPS=UBLOX removed, reset_board=no on jciLDS/jcinavi"

# --- 4) get_board_type.sh: process-aware spoof --------------------------------
cat << 'GBTEOF' > "${GBT}.new"
#!/bin/sh
# WCP mod: spoof board type per caller process.
# vim_app -> exit 1 (legacy, keeps gauge cluster stable)
# everything else -> exit 2 (WCP enabled, loads sm_WCP.conf)
if [ -e /data_persist/wcp_force_off ]; then
    exit 1
fi

for p in $PPID $(cut -d' ' -f4 /proc/$PPID/stat 2>/dev/null); do
    if [ "$(cat /proc/$p/comm 2>/dev/null)" = "vim_app" ]; then
        exit 1
    fi
done

exit 2
GBTEOF
if ! sh -n "${GBT}.new"; then
  rm -f "${GBT}.new"
  die "get_board_type.sh replacement has syntax errors"
fi
chmod 0755 "${GBT}.new"
mv -f "${GBT}.new" "$GBT"
log "get_board_type.sh: process spoofing installed"

rm -f /data_persist/wcp_force_off /data_persist/ublox.txt 2>/dev/null

# --- done --------------------------------------------------------------------
sync
mount -o remount,ro / 2>/dev/null
echo ""
log "=== VERIFY ==="
log "  get_board_type.sh spoof: $(grep -c vim_app "$GBT") vim_app reference(s)"
log "  sm_WCP.conf jciLDS GPS=UBLOX: $(grep 'name="jciLDS"' "$SMW" | grep -c 'GPS=UBLOX')"
log "  sm_WCP.conf jciLDS reset_board: $(grep 'name="jciLDS"' "$SMW" | grep -oE 'reset_board="[a-z]*"')"
log "  autostart ublox: $(grep -c 'WCP mod' "$AUTOSTART") marker(s)"
echo ""
log "DONE. Reboot the unit to activate Wireless CarPlay."
