#!/bin/sh
# splim_bridge v16 — feedback-loop-free + sticky display + name-based filter.
#
# Design:
#   * NAME-BASED filter: reject frames whose sender's dbus connection is owned
#     by a process whose cmdline contains "jciCARPLAY" (the shim host) — even
#     if jciCARPLAY restarts mid-session with a new PID. Lookup is via
#     dbus GetConnectionUnixProcessID → /proc/<pid>/cmdline. Per-sender result
#     cached (dbus names are per-connection — a new process gets a new :1.N).
#   * STICKY refresh: after a real capture, a subshell re-writes the file with
#     a fresh ts every 5 s for the next 60 s. Survives sparse publishing
#     (jciRM only pushes a few frames per minute). No feedback loop: refresh
#     writes the LAST captured value verbatim, not scraped state; and the
#     shim's own frames never make it through the name filter.
#   * Silent decay: after 60 s with no new captures, refresher stops touching
#     the file. It ages out via the shim's 8-s read_splim TTL → HUD → ---
#
# Field mapping in VbsNaviHudDisplay (uqyqyy):
#   idx 0  uint32  nextManeuverInfo
#   idx 1  uint16  distanceValue
#   idx 2  byte    distanceUnit
#   idx 3  uint16  displaySpeedLimit    ← the value we want
#   idx 4  byte    displaySpeedUnit
#   idx 5  byte    text_ID3

set -u
BUS=/tmp/dbus_service_socket
LOG=/mnt/data_persist/log/splim_v16.log
OUT=/mnt/data_persist/splim
LAST=/tmp/splim_v16_last          # last "<val> <capture_ts>" for refresher
HOLD_SEC=180                       # keep refreshing this long after last capture
REFRESH_EVERY=5

mkdir -p "$(dirname $LOG)"

# Cap the log before it grows unbounded. $LOG lives on persistent flash
# (/mnt/data_persist, not tmpfs) and survives every reboot — it's appended
# to on every captured frame with no external rotation, so left alone it
# would grow forever over months of daily driving. Truncate to the last
# 2000 lines (a few hundred KB at most) whenever it exceeds ~512 KB.
if [ -f "$LOG" ]; then
  sz=$(wc -c < "$LOG" 2>/dev/null); sz=${sz:-0}
  if [ "$sz" -gt 524288 ]; then
    tail -n 2000 "$LOG" > "${LOG}.tmp" 2>/dev/null && mv "${LOG}.tmp" "$LOG"
  fi
fi

echo "$(date +%s) v16.2 start pid=$$" >> $LOG

# One-time visibility check — we don't cache the PID; each frame gets its
# sender resolved fresh (with cache), so this only logs that a shim exists.
CARPLAY_PID=$(ps | awk '/[L]_jciCARPLAY/{print $1; exit}')
if [ -n "$CARPLAY_PID" ]; then
    echo "$(date +%s) jciCARPLAY seen: pid=$CARPLAY_PID (filter is by cmdline, not PID)" >> $LOG
else
    echo "$(date +%s) NOTE: jciCARPLAY not running yet — filter still works when it starts" >> $LOG
fi

# --- Sender→is_shim cache (dbus names are per-connection: new process → new :1.N) -
CACHE_DIR=/tmp/splim_v16_cache
rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"

# Returns 1 if sender's PID has "jciCARPLAY" or "blmjcicarplay" in cmdline, else 0.
sender_is_shim() {
    _s="$1"
    _f="$CACHE_DIR/${_s#:}.shim"
    if [ -f "$_f" ]; then
        cat "$_f"
        return
    fi
    _p=$(dbus-send --address="unix:path=$BUS" --print-reply --type=method_call \
        --dest=org.freedesktop.DBus /org/freedesktop/DBus \
        org.freedesktop.DBus.GetConnectionUnixProcessID \
        string:"$_s" 2>/dev/null \
        | awk '/uint32/{print $2; exit}')
    if [ -z "$_p" ] || [ ! -r "/proc/$_p/cmdline" ]; then
        # Sender may already have disconnected. Treat as "not shim" (accept the
        # frame — safer to include a legit rare source than to drop it).
        echo 0 > "$_f"
        echo 0
        return
    fi
    if tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | grep -qE 'jciCARPLAY|blmjcicarplay'; then
        echo 1 > "$_f"
        echo 1
    else
        echo 0 > "$_f"
        echo 0
    fi
}

# --- Sticky refresher --------------------------------------------------------
(
    while :; do
        sleep $REFRESH_EVERY
        [ -f "$LAST" ] || continue
        read val cap_ts _rest < "$LAST" 2>/dev/null
        [ -z "$val" ] && continue
        now=$(date +%s)
        age=$((now - cap_ts))
        [ $age -lt 0 ] && continue           # future-dated guard
        [ $age -gt $HOLD_SEC ] && continue    # window elapsed
        echo "$val $now" > "$OUT"
    done
) &
REFRESHER=$!

trap "kill $REFRESHER 2>/dev/null
      rm -f $OUT $LAST 2>/dev/null
      echo \"$(date +%s) exit pid=$$\" >> $LOG" INT TERM EXIT

# --- Main loop ---------------------------------------------------------------
while :; do
    dbus-monitor --address unix:path=$BUS \
        "type='method_call',interface='com.jci.vbs.navi',member='SetHUDDisplayMsgReq'" 2>>$LOG \
    | while read line; do
        case "$line" in
            *"method call"*)
                sender=""; idx=0; in_st=0
                nmi=""; dv=""; splim=""; splimU=""; spid=""
                for tok in $line; do
                    case "$tok" in sender=*) sender=${tok#sender=} ;; esac
                done
                if [ -n "$sender" ] && [ "$(sender_is_shim "$sender")" = "1" ]; then
                    in_st=-1
                fi
                continue
                ;;
        esac
        [ "${in_st:-0}" = "-1" ] && continue
        case "$line" in
            *"struct {"*) in_st=1; idx=0 ;;
            *"uint32 "*|*"uint16 "*|*"byte "*)
                [ "${in_st:-0}" = "1" ] || continue
                v=$(echo "$line" | awk '{print $NF}')
                case "$idx" in
                    0) nmi="$v" ;;
                    1) dv="$v" ;;
                    3) splim="$v" ;;
                    4) splimU="$v" ;;
                esac
                idx=$((idx + 1))
                ;;
            *"}"*)
                [ "${in_st:-0}" = "1" ] || continue
                in_st=0
                [ -n "$splim" ] && [ "$splim" -gt 4 ] && [ "$splim" -lt 200 ] || continue
                [ -n "$splimU" ] && [ "$splimU" -gt 0 ] || continue
                ts=$(date +%s)
                echo "$splim $ts" > "$OUT"
                echo "$splim $ts" > "$LAST"
                echo "$ts got splim=$splim unit=$splimU sender=$sender nmi=$nmi dv=$dv" >> $LOG
                ;;
        esac
    done
    echo "$(date +%s) monitor died sleep 3" >> $LOG
    sleep 3
done
