#!/bin/sh
# ============================================================================
#  Wireless CarPlay (WCP) disabler — restores stock wired-only CarPlay.
#  Reverses the changes made by wcp_enable.sh:
#    get_board_type.sh, sm_WCP.conf, autostart
#  Run ON THE CMU as root, then reboot.
# ============================================================================
set -u
TAG="[wcp disable]"
SRC=$(cd "$(dirname "$0")" && pwd)
MOD_VERSION=$(cat "$SRC/VERSION" 2>/dev/null | tr -d '[:space:]')
: "${MOD_VERSION:=unknown}"
BAK_DIR=/data_persist/hud-mod-backup
GBT=/jci/scripts/get_board_type.sh
SMW=/jci/sm/sm_WCP.conf
AUTOSTART=/usr/bin/autostart

log() { echo "$TAG $*"; }

log "toolkit version: v$MOD_VERSION"
mount -o remount,rw / 2>/dev/null || { log "remount rw failed"; exit 1; }

# --- 1) get_board_type.sh ----------------------------------------------------
b="$BAK_DIR/get_board_type.sh.pre_wcp"
if [ -f "$b" ]; then
  cp -a "$b" "$GBT" && rm -f "$b"
  log "restored $GBT from backup"
else
  if grep -q "vim_app" "$GBT" 2>/dev/null; then
    log "no backup found, recreating stock get_board_type.sh"
    cat << 'STOCK' > "${GBT}.new"
#!/bin/sh
ret=1
DI_TP1056=/sys/class/gpio/DI_TP1056/value
DI_TP1029=/sys/class/gpio/DI_TP1029/value
if [ -e "$DI_TP1056" ] && [ -e "$DI_TP1029" ]; then
    for cnt in 0 1 2; do
        value1=$(cat $DI_TP1056)
        if [ $? = '0' ]; then
            if [ $value1 = '0' ] || [ $value1 = '1' ]; then
                value2=$(cat $DI_TP1029)
                if [ $? = '0' ]; then
                    if [ $value2 = '0' ] || [ $value2 = '1' ]; then
                        if [ $value1 = '1' ] || [ $value2 = '1' ]; then
                            ret=2
                        fi
                        break
                    fi
                fi
            fi
        fi
        sleep 1
    done
fi
exit $ret
STOCK
    chmod 0755 "${GBT}.new"
    mv -f "${GBT}.new" "$GBT"
  else
    log "$GBT does not contain WCP spoof, skipping"
  fi
fi

# --- 2) sm_WCP.conf ----------------------------------------------------------
b="$BAK_DIR/sm_WCP.conf.pre_wcp"
if [ -f "$b" ]; then
  cp -a "$b" "$SMW" && rm -f "$b"
  log "restored $SMW from backup"
else
  log "no sm_WCP.conf backup, performing manual undo"
  sed -i '/name="jciLDS"/{/GPS=UBLOX/!s/\(args="[^"]*\)"/\1 GPS=UBLOX"/;s/reset_board="no"/reset_board="yes"/}' "$SMW"
  sed -i '/name="jcinavi"/{s/args=""/args="wcp"/;s/reset_board="no"/reset_board="yes"/}' "$SMW"
fi

# --- 3) autostart -------------------------------------------------------------
b="$BAK_DIR/autostart.pre_wcp"
if [ -f "$b" ]; then
  cp -a "$b" "$AUTOSTART" && rm -f "$b"
  log "restored $AUTOSTART from backup"
else
  if grep -qF 'WCP mod: do not create ublox.txt' "$AUTOSTART"; then
    log "no autostart backup, performing manual undo"
    sed -i '/WCP mod: do not create ublox.txt/s/.*/    test ! -e "$UBLOX_FILE" \&\& touch "$UBLOX_FILE"/' "$AUTOSTART"
  fi
fi

# --- cleanup -----------------------------------------------------------------
rm -f /data_persist/wcp_force_off /tmp/wcp_board.log 2>/dev/null
sync
mount -o remount,ro / 2>/dev/null

log "=== VERIFY ==="
log "  get_board_type.sh spoof: $(grep -c vim_app "$GBT" 2>/dev/null) (expect 0)"
log "DONE. Reboot to return to wired-only CarPlay."
