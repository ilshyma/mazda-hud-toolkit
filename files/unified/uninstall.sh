#!/bin/sh
# ============================================================================
#  Unified HUD mod uninstaller — returns the CMU to stock HUD behaviour.
#  Removes every libpatch LD_PRELOAD (this mod, KidMixer cp-hud-mod, oem-aa-mod)
#  from both sm configs, restores the files install.sh backed up, and deletes
#  /data_persist/oem-aa-mod. Backups in /data_persist/hud-mod-backup are kept.
#  Run ON THE CMU as root, then reboot.
# ============================================================================
set -u
TAG="[hud-mod uninstall]"
MOD_DIR=/data_persist/oem-aa-mod
BAK_DIR=/data_persist/hud-mod-backup
MASTER=/etc/devmgr_config_master.xml
log() { echo "$TAG $*"; }

[ -f /jci/sm/sm.conf ] || { log "not a CMU — aborting"; exit 1; }
mount -o remount,rw / 2>/dev/null || { log "remount rw failed"; exit 1; }

for C in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
  [ -f "$C" ] || continue
  grep -v 'env_name="LD_PRELOAD"[^>]*libpatch-' "$C" \
    | grep -v 'env_name="LD_LIBRARY_PATH" env_value="/jci/lib:/usr/lib"' > /tmp/hudmod.u \
    && sed -i '/name="jciCARPLAY"/ s/reset_board="no"/reset_board="yes"/' /tmp/hudmod.u \
    && cp /tmp/hudmod.u "$C" && log "$C: LD_PRELOAD lines removed"
  rm -f /tmp/hudmod.u
done

# Stock is FALSE. Not restored from backup: a unit that had KidMixer's mod
# before this one was backed up with TRUE already.
sed -i 's#<name>NaviSupported</name><value>TRUE</value>#<name>NaviSupported</name><value>FALSE</value>#' "$MASTER" 2>/dev/null
log "NaviSupported=FALSE"

for x in aap_system_attributes.xml aap_system_attributes_UCP.xml; do
  if [ -f "$BAK_DIR/$x.orig" ]; then
    cp -a "$BAK_DIR/$x.orig" "/etc/$x" && log "restored /etc/$x"
  elif [ -f "/etc/$x.orig" ]; then   # backup made by a manual oem-aa-mod install
    cp -a "/etc/$x.orig" "/etc/$x" && log "restored /etc/$x from /etc/$x.orig"
  fi
done

rm -rf "$MOD_DIR" && log "removed $MOD_DIR"
rm -f /tmp/hud_oem_speed /tmp/hud_carplay_active
sync
mount -o remount,ro / 2>/dev/null

log "=== VERIFY (expect 0) ==="
log "  libpatch lines: sm.conf=$(grep -c 'libpatch-' /jci/sm/sm.conf 2>/dev/null) sm_WCP.conf=$(grep -c 'libpatch-' /jci/sm/sm_WCP.conf 2>/dev/null)"
log "DONE. Reboot to return to stock. Backups kept in $BAK_DIR"
