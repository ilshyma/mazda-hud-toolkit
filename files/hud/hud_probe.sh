#!/bin/sh
# ============================================================================
#  hud_probe — record one drive's worth of HUD data for CarPlay AND Android
#  Auto, for analysis/replay at home. Runs ON THE CMU (busybox sh), as root.
#
#    hud_probe.sh start [label]   begin a session (runs in the background)
#    hud_probe.sh mark  <text>    timestamped note ("AA Google Maps route")
#    hud_probe.sh status          is it running, sizes, last state sample
#    hud_probe.sh stop            finish: collect everything into a .tar.gz
#    hud_probe.sh list | clean    sessions on the unit / delete them
#
#  A session records:
#    dbus_service.log/.profile  NNG GuidanceChanged*, every HUD call
#                               (SetHUDDisplayMsgReq / Msg2 / lanes) with its
#                               sender, com.jci.aapa + com.jci.carplay
#    dbus_hmi.log/.profile      com.jci.aapa, com.jci.carplay, HUD settings
#    state.log                  every 2 s: service PIDs, OEM speed shared with
#                               CarPlay, CarPlay-owns-HUD marker, free memory
#    events.log                 service restarts (with loaded shims), dmesg
#                               changes, size guards
#    aa_nav.log cp_nav.log merge.log
#                               raw phone navigation + merge decisions — only
#                               with the diag build (tools/package.sh diag)
#    meta.txt                   firmware, shim md5s, sm preloads, libpatch.conf
#  The .profile files carry timestamps; join them to .log by sender+serial.
#
#  Data stays on /data_persist (survives a reboot or crash). A session cut
#  short by a reboot is packed on the next "start". Contains location data
#  (street names, maneuvers).
# ============================================================================
set -u
ROOT=/data_persist/hud-probe
LIVE=$ROOT/live                  # the diag shims write here while it exists
CUR=/tmp/hud-probe.session       # path of the running session (tmpfs: gone after reboot)
SVC_BUS=unix:path=/tmp/dbus_service_socket
HMI_BUS=unix:path=/tmp/dbus_hmi_socket
MAX_KB=40960                     # per capture file
MIN_FREE_KB=65536                # refuse to start / stop capturing below this
SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

now()  { echo "$(date +%s) $(cut -d' ' -f1 /proc/uptime)"; }
say()  { echo "[hud_probe] $*"; }
free_kb() { df -k /data_persist 2>/dev/null | awk 'NR==2 {print $4}'; }
session() { [ -f "$CUR" ] && cat "$CUR"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

# Pack a finished session dir into <dir>.tar.gz next to it.
pack() {
  d=$1
  [ -d "$d" ] || return 0
  tar czf "$d.tar.gz" -C "$ROOT" "$(basename "$d")" 2>/dev/null && rm -rf "$d" \
    && sync && say "packed $d.tar.gz ($(wc -c < "$d.tar.gz") bytes)"   # du shows 0 on flash before writeback
}

# Move the diag shims' live files into session dir $1, then drop live/ so the
# shims stop writing (they notice the unlinked file and cannot reopen).
sweep_live() {
  [ -d "$LIVE" ] || return 0
  for f in "$LIVE"/*.log; do
    [ -f "$f" ] || continue
    cp "$f" "$1/" && rm -f "$f"
  done
  rmdir "$LIVE" 2>/dev/null
}

start_capture() {  # name address rule...
  name=$1; addr=$2; shift 2
  # setsid: keep recording when the SSH session that started us goes away
  # (busybox setsid execs in place for a background job, so $! is the monitor).
  setsid dbus-monitor --address "$addr" "$@" > "$S/$name.log" 2>>"$S/errors.log" < /dev/null &
  echo "$! $name.log" >> "$S/pids"
  setsid dbus-monitor --profile --address "$addr" "$@" > "$S/$name.profile" 2>>"$S/errors.log" < /dev/null &
  echo "$! $name.profile" >> "$S/pids"
}

cmd_start() {
  s=$(session)
  if [ -n "$s" ] && [ -d "$s" ]; then say "already running: $s"; return 0; fi
  mkdir -p "$ROOT"
  # Sessions cut short by a reboot: sweep and pack them first.
  for d in "$ROOT"/session-*; do
    [ -d "$d" ] || continue
    say "recovering interrupted session $d"
    sweep_live "$d"; pack "$d"
  done
  fk=$(free_kb)
  if [ -n "$fk" ] && [ "$fk" -lt "$MIN_FREE_KB" ]; then
    say "only ${fk} KB free on /data_persist — fetch + clean old sessions first"; return 1
  fi

  S=$ROOT/session-$(date +%Y%m%d-%H%M%S)
  [ -e "$S" ] && S=$S-$$
  mkdir -p "$S" "$LIVE" || { say "mkdir failed"; return 1; }
  : > "$S/pids"
  {
    echo "label: ${1:-}"
    echo "started: $(now)  ($(date))"
    echo "--- version.ini"; cat /jci/version.ini
    echo "--- shims"; md5sum /data_persist/oem-aa-mod/*.so 2>&1
    echo "--- OEM binaries"; md5sum /jci/navi/svcjcinavi.so /jci/aapa/blmjciaapa.so \
         /jci/carplay/blmjcicarplay.so /usr/bin/aap_service 2>&1
    echo "--- sm preloads"; grep -n 'libpatch-\|LD_PRELOAD' /jci/sm/sm.conf /jci/sm/sm_WCP.conf
    echo "--- libpatch.conf"; grep -v '^[[:space:]]*#' /data_persist/oem-aa-mod/libpatch.conf 2>&1 | grep .
    echo "--- NaviSupported"; grep -o '<name>NaviSupported</name><value>[A-Z]*' /etc/devmgr_config_master.xml
    echo "--- HUD settings"; dbus-send --address="$HMI_BUS" --print-reply --dest=com.jci.navi2IHU \
         /com/jci/navi2IHU com.jci.navi2IHU.HUDSettings.GetHUDIsInstalled 2>&1 | tail -n 1
    echo "--- uname"; uname -a
  } > "$S/meta.txt" 2>&1

  start_capture dbus_service "$SVC_BUS" \
    "type='signal',interface='com.NNG.Api.Server.Guidance'" \
    "type='method_call',interface='com.jci.vbs.navi'" \
    "type='method_call',interface='com.jci.vbs.navi.tmc'" \
    "interface='com.jci.aapa'" \
    "interface='com.jci.carplay'"
  start_capture dbus_hmi "$HMI_BUS" \
    "interface='com.jci.aapa'" \
    "interface='com.jci.carplay'" \
    "interface='com.jci.navi2IHU.HUDSettings'"

  echo "$S" > "$CUR"
  setsid sh "$SELF" _sampler "$S" > /dev/null 2>>"$S/errors.log" < /dev/null &
  echo "$! sampler" >> "$S/pids"
  echo "$(now) START ${1:-}" >> "$S/marks.log"
  say "started $S"
  [ -n "$(ls /data_persist/oem-aa-mod/libpatch.conf 2>/dev/null)" ] || say "note: mod not installed?"
}

# Background loop: state every 2 s, restarts, dmesg, size + space guards.
cmd_sampler() {
  S=$1
  prev=""; last_dmesg=""; n=0
  while [ "$(session)" = "$S" ]; do
    ps_out=$(ps)
    pids=""
    for svc in L_jciCARPLAY L_jciAAPA L_jcinavi /usr/bin/aap_service; do
      p=$(echo "$ps_out" | awk -v s="$svc" 'index($0, s) && !/awk/ {print $1; exit}')
      pids="$pids ${p:--}"
    done
    if [ "$pids" != "$prev" ]; then
      {
        echo "$(now) PIDS cp/aa/nav/aas:$pids (was:${prev:- none})"
        for p in $pids; do
          [ "$p" = - ] && continue
          echo "    $p $(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-80) :: $(grep -o 'libpatch-[a-z_]*\.so' /proc/$p/maps 2>/dev/null | sort -u | tr '\n' ' ')"
        done
      } >> "$S/events.log"
      prev=$pids
    fi
    echo "$(now) pids:$pids speed=[$(cat /tmp/hud_oem_speed 2>/dev/null)] cp_active=[$(cat /tmp/hud_carplay_active 2>/dev/null)] memfree=$(awk '/^MemFree/ {print $2}' /proc/meminfo)" \
      | tr -d '\n' >> "$S/state.log"
    echo >> "$S/state.log"

    n=$((n + 1))
    if [ $((n % 15)) = 0 ]; then
      d=$(dmesg 2>/dev/null | tail -n 30)
      sum=$(echo "$d" | md5sum | cut -d' ' -f1)
      if [ "$sum" != "$last_dmesg" ]; then
        { echo "$(now) DMESG (last 30 lines)"; echo "$d" | sed 's/^/    /'; } >> "$S/events.log"
        last_dmesg=$sum
      fi
      # size guard: stop a capture that hit MAX_KB
      while read -r pid file; do
        [ "$file" = sampler ] && continue
        kb=$(du -k "$S/$file" 2>/dev/null | cut -f1)
        if [ -n "$kb" ] && [ "$kb" -gt "$MAX_KB" ] && alive "$pid"; then
          kill "$pid"; echo "$(now) CAP $file reached ${kb} KB, capture stopped" >> "$S/events.log"
        fi
      done < "$S/pids"
      fk=$(free_kb)
      if [ -n "$fk" ] && [ "$fk" -lt $((MIN_FREE_KB / 2)) ]; then
        echo "$(now) LOW SPACE ${fk} KB: stopping captures" >> "$S/events.log"
        while read -r pid file; do [ "$file" = sampler ] || kill "$pid" 2>/dev/null; done < "$S/pids"
        rmdir "$LIVE" 2>/dev/null; rm -rf "$LIVE"
      fi
    fi
    sleep 2
  done
}

cmd_stop() {
  S=$(session)
  [ -n "$S" ] && [ -d "$S" ] || { say "not running"; return 0; }
  echo "$(now) STOP" >> "$S/marks.log"
  rm -f "$CUR"                   # the sampler exits on its next tick
  while read -r pid file; do
    # only kill what we started (pid reuse guard)
    case "$(tr '\0' ' ' < /proc/$pid/cmdline 2>/dev/null)" in
      *dbus-monitor*|*hud_probe*) kill "$pid" 2>/dev/null ;;
    esac
  done < "$S/pids"
  sweep_live "$S"
  cp /tmp/carplay_bridge.log "$S/" 2>/dev/null
  {
    echo "stopped: $(now)  ($(date))"
    echo "--- /tmp/hud_*"; for f in /tmp/hud_oem_speed /tmp/hud_carplay_active; do echo "$f: $(cat $f 2>/dev/null)"; done
    echo "--- ps"; ps
    echo "--- meminfo"; head -n 5 /proc/meminfo
    echo "--- df"; df -k /data_persist /tmp
  } > "$S/final.txt" 2>&1
  dmesg > "$S/dmesg.txt" 2>/dev/null
  pack "$S"
}

cmd_status() {
  S=$(session)
  if [ -n "$S" ] && [ -d "$S" ]; then
    say "running: $S"
    ls -l "$S" | awk 'NR>1 {printf "    %8s  %s\n", $5, $NF}'
    [ -d "$LIVE" ] && ls -l "$LIVE" | awk 'NR>1 {printf "    %8s  live/%s\n", $5, $NF}'
    echo "    last: $(tail -n 1 "$S/state.log" 2>/dev/null)"
    [ -s "$S/errors.log" ] && { echo "    errors:"; tail -n 5 "$S/errors.log" | sed 's/^/      /'; }
  else
    say "not running"
  fi
  say "free on /data_persist: $(free_kb) KB"
}

case "${1:-}" in
  start)    cmd_start "${2:-}" ;;
  stop)     cmd_stop ;;
  status)   cmd_status ;;
  mark)     shift; S=$(session); [ -n "$S" ] && echo "$(now) $*" >> "$S/marks.log" && say "marked: $*" || say "not running" ;;
  list)     ls -l "$ROOT" 2>/dev/null; say "free: $(free_kb) KB" ;;
  clean)    [ -n "$(session)" ] && { say "stop first"; exit 1; }; rm -rf "$ROOT"/session-*; say "cleaned" ;;
  _sampler) cmd_sampler "$2" ;;
  *)        sed -n '2,30p' "$0"; exit 1 ;;
esac
