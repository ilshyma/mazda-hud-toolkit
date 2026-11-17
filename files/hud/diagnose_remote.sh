#!/bin/sh
# ============================================================================
#  HUD mod verbose diagnostic — runs ON THE CMU, prints human-readable output.
#  The toolkit (toolkit.sh / toolkit.bat) SCPs this file to /tmp and runs it.
# ============================================================================
set -u

echo
echo '─── 1. LD_PRELOAD wiring (sm.conf) ───'
grep -c libpatch /jci/sm/sm.conf 2>/dev/null | awk '{print "  sm.conf preload lines: "$0}'
grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null | awk '{print "  sm_WCP.conf preload lines: "$0}'
grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | tr -d '<>' | awk '{print "  "$0}'

echo
echo '─── 2. Target processes + shim loading ───'
for SVC in jciCARPLAY jciAAPA jcinavi aap_service; do
  P=$(ps | awk "/[L]_${SVC}/{print \$1; exit}")
  if [ -z "$P" ]; then
    case "$SVC" in
      aap_service) P=$(ps | awk '/[a]ap_service/{print $1; exit}') ;;
      jcinavi)     P=$(ps | awk '/[s]vcjcinavi/{print $1; exit}') ;;
    esac
  fi
  if [ -n "$P" ]; then
    echo "  $SVC: pid=$P"
    grep libpatch /proc/$P/maps 2>/dev/null | head -3 | sed 's/^/    /'
  else
    echo "  $SVC: NOT RUNNING"
  fi
done

echo
echo '─── 3. Shims on disk ───'
ls -la /data_persist/oem-aa-mod/libpatch-*.so 2>/dev/null | sed 's/^/  /'
echo "  version: $(cat /data_persist/oem-aa-mod/.version 2>/dev/null || echo '(none)')"

echo
echo '─── 4. Legacy cp-hud-mod (should be gone after migration) ───'
if [ -d /data_persist/cp-hud-mod ]; then
  echo '  ! cp-hud-mod still exists:'
  ls -la /data_persist/cp-hud-mod/ 2>/dev/null | sed 's/^/    /'
else
  echo '  cp-hud-mod: removed (good)'
fi

echo
echo '─── 5. HUD config ───'
if [ -f /data_persist/hud_config ]; then
  cat /data_persist/hud_config | sed 's/^/  /'
else
  echo '  (no hud_config — defaults apply)'
fi

echo
echo '─── 6. libpatch.conf key settings ───'
if [ -f /data_persist/oem-aa-mod/libpatch.conf ]; then
  grep -E '^(hud_transport|force_street_name|use_protocol_v1_6)' /data_persist/oem-aa-mod/libpatch.conf | sed 's/^/  /'
else
  echo '  (not found)'
fi

echo
echo '─── 7. Backup directory ───'
ls -la /data_persist/hud-mod-backup/ 2>/dev/null | sed 's/^/  /'
[ ! -d /data_persist/hud-mod-backup ] && echo '  (no backup dir)'

echo
echo '─── 8. System info ───'
echo "  firmware: $(grep '^JCI_SW_VER=' /jci/version.ini 2>/dev/null | cut -d'"' -f2)"
echo "  clock: $(date)"
echo "  uptime: $(uptime 2>/dev/null)"
