#!/bin/sh
# ============================================================================
#  HUD mod rollback verify + force-clean — runs ON THE CMU after uninstall.sh.
#  Strips any residual LD_PRELOAD lines, forces NaviSupported=FALSE, removes
#  mod directories.  The toolkit SCPs this to /tmp and runs it.
# ============================================================================
set -u

mount -o remount,rw / 2>/dev/null || true

for CONF in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
  [ -f "$CONF" ] || continue
  before=$(grep -c 'libpatch-' "$CONF" 2>/dev/null)
  before=${before:-0}
  if [ "$before" -gt 0 ]; then
    echo "  ! $CONF still has $before LD_PRELOAD lines — force-stripping"
    grep -v 'libpatch-' "$CONF" \
      | grep -v 'LD_LIBRARY_PATH.*jci/lib:/usr/lib' > /tmp/rb.clean
    cp /tmp/rb.clean "$CONF"
    rm -f /tmp/rb.clean
    sed -i '/name="jciCARPLAY"/ s/reset_board="no"/reset_board="yes"/' "$CONF"
  fi
done

if grep -q '<name>NaviSupported</name><value>TRUE</value>' /etc/devmgr_config_master.xml 2>/dev/null; then
  echo '  ! NaviSupported=TRUE — forcing to FALSE'
  sed -i 's#<name>NaviSupported</name><value>TRUE</value>#<name>NaviSupported</name><value>FALSE</value>#' /etc/devmgr_config_master.xml
fi

rm -rf /data_persist/cp-hud-mod
rm -rf /data_persist/oem-aa-mod
rm -f  /data_persist/hud_config
sync
mount -o remount,ro / 2>/dev/null || true

echo "  final: sm.conf preload=$(grep -c libpatch /jci/sm/sm.conf 2>/dev/null)  sm_WCP.conf preload=$(grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null)  NaviSupported=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | grep -oE '[A-Z]+$')"
