#!/bin/sh
# ============================================================================
#  HUD mod post-reboot validator — runs ON THE CMU, prints key=value pairs.
#  The toolkit (toolkit.sh / toolkit.bat) SCPs this file to /tmp, runs it via
#  SSH, and parses the output.  Keep the output format stable.
# ============================================================================
set -u

echo "PRELOAD_SM=$(grep -c libpatch /jci/sm/sm.conf 2>/dev/null || echo 0)"
echo "PRELOAD_WCP=$(grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null || echo 0)"
echo "NAVISUPPORTED=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | grep -oE '[A-Z]+$')"

for SVC in jciCARPLAY jciAAPA jcinavi aap_service; do
  P=$(ps | awk "/[L]_${SVC}/{print \$1; exit}")
  if [ -z "$P" ]; then
    case "$SVC" in
      aap_service) P=$(ps | awk '/[a]ap_service/{print $1; exit}') ;;
      jcinavi)     P=$(ps | awk '/[s]vcjcinavi/{print $1; exit}') ;;
    esac
  fi
  if [ -n "$P" ]; then
    LOADED=$(grep -c 'libpatch-' /proc/$P/maps 2>/dev/null)
    echo "${SVC}_PID=$P"
    echo "${SVC}_LOADED=$LOADED"
  else
    echo "${SVC}_PID=0"
    echo "${SVC}_LOADED=0"
  fi
done

echo "MOD_DIR_EXISTS=$([ -d /data_persist/oem-aa-mod ] && echo 1 || echo 0)"
echo "SHIM_COUNT=$(ls /data_persist/oem-aa-mod/libpatch-*.so 2>/dev/null | wc -l | tr -d ' ')"
echo "VERSION=$(cat /data_persist/oem-aa-mod/.version 2>/dev/null)"
echo "HUD_CONFIG=$(cat /data_persist/hud_config 2>/dev/null | tr '\n' ' ')"
echo "CLOCK=$(date)"
