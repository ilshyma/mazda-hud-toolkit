#!/bin/sh
# ============================================================================
#  Unified HUD mod installer — CarPlay + Android Auto turn-by-turn on the HUD,
#  speed limit from the stock navigation, for Mazda CMU150 FW 74.00.324.
#
#  Run ON THE CMU as root, from a folder that holds:
#    libpatch-blmjcicarplay.so  libpatch-blmjciaapa.so
#    libpatch-svcjcinavi.so     libpatch-aap_service.so
#    libpatch.conf              aap_system_attributes.xml  aap_system_attributes_UCP.xml
#
#  What it does (idempotent; safe to re-run after an update):
#    1. copies the shims + libpatch.conf to /data_persist/oem-aa-mod/
#    2. LD_PRELOADs each shim into its OEM service in the active sm config
#       (jciCARPLAY, jciAAPA, jcinavi, aap_service), replacing any earlier
#       KidMixer / oem-aa-mod / cp-hud-mod line for those services
#    3. NaviSupported=TRUE (CarPlay nav advertisement)
#    4. installs the AA system-attribute XMLs (nav subscribe) if the
#       certificates they reference exist on this unit
#    5. stops and removes the old splim_bridge daemon (now built into the
#       svcjcinavi shim)
#  Every edited file is backed up once to /data_persist/hud-mod-backup/.
#  Undo: uninstall.sh
# ============================================================================
set -u
TAG="[hud-mod install]"
SRC=$(cd "$(dirname "$0")" && pwd)
MOD_DIR=/data_persist/oem-aa-mod
BAK_DIR=/data_persist/hud-mod-backup
MASTER=/etc/devmgr_config_master.xml
SHIMS="blmjcicarplay blmjciaapa svcjcinavi aap_service"
# svcjcinavi.so of FW 74.00.324A (NA and EU builds are byte-identical). The
# merge shim's force_street_name reads an OEM buffer at a fixed offset of it.
SVCNAVI_MD5=100adcd8b110d4d79afe2dc5e3e769b1

log() { echo "$TAG $*"; }
die() { echo "$TAG ERROR: $*"; mount -o remount,ro / 2>/dev/null; exit 1; }

# --- preflight ---------------------------------------------------------------
[ -f /jci/sm/sm.conf ] || die "not a CMU (no /jci/sm/sm.conf)"
for s in $SHIMS; do
  [ -f "$SRC/libpatch-$s.so" ] || die "missing $SRC/libpatch-$s.so"
done
[ -f "$SRC/libpatch.conf" ] || die "missing $SRC/libpatch.conf"

VER=$(grep '^JCI_SW_VER=' /jci/version.ini 2>/dev/null | cut -d'"' -f2)
FLAVOR=$(grep '^JCI_SW_FLAVOR=' /jci/version.ini 2>/dev/null | cut -d'"' -f2)
log "firmware: ${VER:-?} (${FLAVOR:-?})"
case "$VER" in
  *74.00.324*) ;;
  *) log "WARNING: built and tested for 74.00.324 — continuing, but check the HUD carefully" ;;
esac

NAV_MD5=$(md5sum /jci/navi/svcjcinavi.so 2>/dev/null | cut -d' ' -f1)
if [ -z "$NAV_MD5" ]; then
  log "WARNING: /jci/navi/svcjcinavi.so not found — no stock nav: no speed limit, CarPlay/AA arrows only"
elif [ "$NAV_MD5" != "$SVCNAVI_MD5" ]; then
  log "WARNING: svcjcinavi.so md5 $NAV_MD5 is not the known 74.00.324A build; force_street_name(_native) will be disabled"
fi
pidof NNG >/dev/null 2>&1 || ps | grep -q '[j]ci-linux_imx6' || \
  log "NOTE: NNG (nav SD card engine) not running right now — speed limit needs the nav SD card"

# --- which sm config does this unit boot? (same probe as /usr/bin/autostart) ---
BT=""
if [ -x /jci/scripts/get_board_type.sh ]; then
  /jci/scripts/get_board_type.sh >/dev/null 2>&1; BT=$?
fi
if [ "$BT" = "2" ] && [ -f /jci/sm/sm_WCP.conf ]; then
  CONF=/jci/sm/sm_WCP.conf; OTHER=/jci/sm/sm.conf
else
  CONF=/jci/sm/sm.conf; OTHER=/jci/sm/sm_WCP.conf
fi
log "active sm config: $CONF (get_board_type.sh=${BT:-n/a})"

# Strip every libpatch LD_PRELOAD (ours, KidMixer's cp-hud-mod, older oem-aa-mod
# paths) plus KidMixer's LD_LIBRARY_PATH from both configs, then insert one
# fresh set right after each target <service ...> line in the active config.
strip_conf() {  # $1 in, $2 out
  grep -v 'env_name="LD_PRELOAD"[^>]*libpatch-' "$1" \
    | grep -v 'env_name="LD_LIBRARY_PATH" env_value="/jci/lib:/usr/lib"' > "$2"
}
env_line() {  # $1 name, $2 value
  printf '            <environ_var env_name="%s" env_value="%s"/>\n' "$1" "$2"
}

# Preflight the active config BEFORE touching anything: all four target
# services present, and none carries an LD_PRELOAD that is not ours (two
# LD_PRELOAD environ_vars in one service would leave it to sm which one wins).
check_conf() {  # $1 = sm config
  strip_conf "$1" /tmp/hudmod.chk || return 1
  awk '
    BEGIN { n = split("jciCARPLAY jciAAPA jcinavi aap_service", a); for (i = 1; i <= n; i++) T[a[i]] = 1 }
    /<service / { svc = ""; for (t in T) if (index($0, "name=\"" t "\"")) { svc = t; seen[t] = 1 } }
    svc != "" && /env_name="LD_PRELOAD"/ { print "  foreign LD_PRELOAD in " svc ": " $0; bad = 1 }
    /<\/service>/ { svc = "" }
    END { for (t in T) if (!(t in seen)) { print "  service " t " not found"; bad = 1 }; exit bad }
  ' /tmp/hudmod.chk
  r=$?; rm -f /tmp/hudmod.chk; return $r
}
check_conf "$CONF" || die "$CONF is not as expected (see above) — nothing changed"

mount -o remount,rw / 2>/dev/null || die "remount rw failed"
mkdir -p "$MOD_DIR" "$BAK_DIR" || die "mkdir failed"

backup_once() {  # $1 = file, $2 = optional older pristine copy to back up instead
  [ -f "$1" ] || return 0
  b="$BAK_DIR/$(basename "$1").orig"
  src=$1
  [ -n "${2:-}" ] && [ -f "$2" ] && src=$2
  [ -f "$b" ] || { cp -a "$src" "$b" && log "backup $src -> $b"; }
}

# --- 1) files ------------------------------------------------------------------
for s in $SHIMS; do
  cp -f "$SRC/libpatch-$s.so" "$MOD_DIR/" || die "copy libpatch-$s.so failed"
  chmod 0644 "$MOD_DIR/libpatch-$s.so"
done
if [ -f "$MOD_DIR/libpatch.conf" ] && ! cmp -s "$SRC/libpatch.conf" "$MOD_DIR/libpatch.conf"; then
  cp -f "$SRC/libpatch.conf" "$MOD_DIR/libpatch.conf.new"
  log "kept your $MOD_DIR/libpatch.conf (new defaults saved as libpatch.conf.new)"
else
  cp -f "$SRC/libpatch.conf" "$MOD_DIR/libpatch.conf"
fi
if [ -n "$NAV_MD5" ] && [ "$NAV_MD5" != "$SVCNAVI_MD5" ]; then
  sed -i -e 's/^[[:space:]]*force_street_name[[:space:]]*=.*/force_street_name = false/' \
         -e 's/^[[:space:]]*force_street_name_native[[:space:]]*=.*/force_street_name_native = false/' "$MOD_DIR/libpatch.conf"
fi
log "installed shims + libpatch.conf in $MOD_DIR"

# --- 2) sm config --------------------------------------------------------------
for C in "$CONF" "$OTHER"; do
  [ -f "$C" ] || continue
  backup_once "$C"
  strip_conf "$C" /tmp/hudmod.strip || die "strip failed on $C"
  if [ "$C" = "$CONF" ]; then
    awk -v cp="$(env_line LD_PRELOAD "$MOD_DIR/libpatch-blmjcicarplay.so")" \
        -v lp="$(env_line LD_LIBRARY_PATH /jci/lib:/usr/lib)" \
        -v aa="$(env_line LD_PRELOAD "$MOD_DIR/libpatch-blmjciaapa.so")" \
        -v nv="$(env_line LD_PRELOAD "$MOD_DIR/libpatch-svcjcinavi.so")" \
        -v as="$(env_line LD_PRELOAD "$MOD_DIR/libpatch-aap_service.so")" '
      { print }
      /<service / && /name="jciCARPLAY"/  { print cp; print lp; n++ }
      /<service / && /name="jciAAPA"/     { print aa; n++ }
      /<service / && /name="jcinavi"/     { print nv; n++ }
      /<service / && /name="aap_service"/ { print as; n++ }
      END { if (n != 4) exit 3 }
    ' /tmp/hudmod.strip > /tmp/hudmod.new || die "$C: expected 4 target services, sm config left untouched"
    sed -i '/name="jciCARPLAY"/ s/reset_board="yes"/reset_board="no"/' /tmp/hudmod.new
  else
    cp /tmp/hudmod.strip /tmp/hudmod.new
  fi
  base=$(grep -vc 'libpatch-\|LD_LIBRARY_PATH" env_value="/jci/lib:/usr/lib"' "$C")
  new=$(grep -vc 'libpatch-\|LD_LIBRARY_PATH" env_value="/jci/lib:/usr/lib"' /tmp/hudmod.new)
  [ "$base" = "$new" ] || die "$C: sanity check failed ($base vs $new non-mod lines), left untouched"
  cp /tmp/hudmod.new "$C" || die "write $C failed"
  log "$C: $(grep -c 'libpatch-' "$C") LD_PRELOAD line(s)"
done
rm -f /tmp/hudmod.strip /tmp/hudmod.new

# --- 3) NaviSupported ------------------------------------------------------------
if [ -f "$MASTER" ]; then
  backup_once "$MASTER"
  sed -i 's#<name>NaviSupported</name><value>FALSE</value>#<name>NaviSupported</name><value>TRUE</value>#' "$MASTER"
fi

# --- 4) AA system attributes (navigation subscribe for the HUD) ------------------
for x in aap_system_attributes.xml aap_system_attributes_UCP.xml; do
  [ -f "$SRC/$x" ] || { log "skip $x (not in package)"; continue; }
  missing=""
  for f in $(grep -oE '<(root_cert_file|client_cert_file|private_key_file)>[^<]+' "$SRC/$x" | sed 's/^<[a-z_]*>//'); do
    [ -f "$f" ] || missing="$missing $f"
  done
  if [ -n "$missing" ]; then
    log "WARNING: $x references files this unit lacks:$missing — left stock (fine if the other XML installed; if neither did, AA sends no HUD guidance)"
    continue
  fi
  backup_once "/etc/$x" "/etc/$x.orig"   # .orig = stock, if oem-aa-mod was installed by hand
  cp -f "$SRC/$x" "/etc/$x" && log "installed /etc/$x"
done

# --- 5) retire the splim_bridge daemon ---------------------------------------------
for p in $(ps | grep '[s]plim_udpd\|[s]plim_bridge' | awk '{print $1}'); do kill "$p" 2>/dev/null; done
rm -f /data_persist/splim_udpd_start.sh /data_persist/cp-hud-mod/splim_udpd \
      /data_persist/cp-hud-mod/splim_bridge.sh /data_persist/splim /tmp/splim_v16_last
rm -rf /tmp/splim_v16_cache

# --- done --------------------------------------------------------------------
sync
mount -o remount,ro / 2>/dev/null
echo ""
log "=== VERIFY ==="
for s in jciCARPLAY jciAAPA jcinavi aap_service; do
  line=$(awk -v s="name=\"$s\"" 'index($0,s) && /<service /{f=1;next} f&&/LD_PRELOAD/{print;exit} f&&/<\/service>/{exit}' "$CONF")
  log "  $s: $(echo "$line" | grep -oE 'libpatch-[a-z_]+\.so' || echo MISSING)"
done
log "  NaviSupported=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' "$MASTER" 2>/dev/null | grep -oE '[A-Z]+$')"
log "  config: $(grep -E '^(hud_transport|force_street_name|force_street_name_native|use_protocol_v1_6)' "$MOD_DIR/libpatch.conf" | tr '\n' ' ')"
log "DONE. Reboot the unit to load the shims."
