#!/bin/bash
# If invoked as `sh toolkit.sh`, the shebang is ignored and /bin/sh runs us in
# POSIX mode. On macOS /bin/sh is bash-in-posix-mode, and its PARSER reads the
# whole script (including function bodies not yet called) before execution
# reaches this guard — so any bash-only syntax anywhere below (arrays,
# `< <(...)`, `read -p`, `[[`, brace expansion) fails to PARSE under `sh`,
# even though this exec guard is the very first thing that would *run*.
# Fix: (a) re-exec under real bash here, AND (b) keep every function body
# POSIX-parseable throughout the file regardless. Both are required.
if [ -z "${BASH_VERSION:-}" ]; then
  exec /bin/bash "$0" "$@"
fi

# ============================================================================
#  Mazda CMU CarPlay-HUD toolkit — macOS/Linux
# ============================================================================
#  MAIN MENU — everything a normal user needs:
#    1  Create USB stick — FAT32 "MZD" with the MP3-XSS unlock (SSH button)
#                          AND the HUD patch in hud-mod/ (HUD+ / HUD- / HUD?
#                          buttons install, remove and check it without a laptop)
#    2  Backup CMU       — safety net before touching anything
#    3  Rollback         — removes EVERY HUD patch (CarPlay + Android Auto,
#                          ilshyma v16 + speed daemon, KidMixer, oem-aa-mod),
#                          back to stock, reboots, confirms
#    4  Install HUD patch — CarPlay + Android Auto (files/unified): md5-verifies,
#                          installs, reboots, waits for SSH, validates the 4 shims
#
#  ADVANCED (A):
#    V  Validate installation (also runs after install; detects which patch)
#    S  Check SSH connection          D  Full diagnostic dump
#    Older CarPlay-only patches and their tools:
#    L  Install ilshyma HUD Patch v16   P  Install PURE KidMixer Patch
#    X  Install legacy pre-v16 mod .so  K  KidMixer rollback (old path)
#    F  Force-start the v16 speed daemon   T  Live-tail its log
#    C  CarPlay HUD arrow debug log
#
#  Payloads in ./files:
#    install.sh                        — KidMixer's own installer (LD_PRELOAD, NaviSupported=TRUE)
#    uninstall.sh                      — KidMixer's own uninstaller
#    libpatch-blmjcicarplay.so         — PURE KidMixer .so (27231 B, md5 0ce29da4…)
#    libpatch-blmjcicarplay-splim.so   — v16 mod .so (30699 B, md5 faf82efb…)
#                                         (patched read_splim rejects future-ts stale files)
#    libpatch-blmjcicarplay-splim-legacy.so — pre-v16 mod .so (md5 c8800f0e…), fallback
#    splim_bridge.sh                   — v16 daemon (name-based sender filter,
#                                         sticky 180 s refresh, no self-feedback loop).
#                                         Deployed to the CMU as "splim_udpd" (no .sh) —
#                                         the shim finds it via `pgrep splim_udpd`,
#                                         which matches on argv[0]'s basename.
#    splim_udpd_start.sh               — launcher the shim calls; BusyBox-compatible
#                                         (no `exec -a`, which BusyBox ash rejects)
# ============================================================================
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"
FILES="$DIR/files"
KEY="$DIR/id_rsa_cmu"
CMU=cmu@192.168.53.1
PORT=36000

# Expected md5 of shipped payloads (used to verify what's on the CMU after copy)
MD5_SO_PURE=0ce29da4f16f72b0b8f931bee88ff332
MD5_SO_MOD=faf82efb028c6af9898122a5ff5833be
MD5_SO_MOD_LEGACY=c8800f0e743612543ecae705738c987e
MD5_SPLIM_BRIDGE=0aa7119da7bbbdb25a3ab271e238ae44
MD5_SPLIM_LAUNCHER=26cdb9e1a2333425e57923b334c5cc50

[ -f "$KEY" ] || { echo "SSH key not found: $KEY"; exit 1; }
chmod 600 "$KEY" 2>/dev/null

# ServerAliveInterval/CountMax + TCPKeepAlive: general insurance so the SSH
# client notices a genuinely dead link and returns promptly instead of
# hanging, giving the retry wrappers below a chance to actually retry.
SSHOPTS="-i $KEY -o PubkeyAcceptedAlgorithms=+ssh-rsa -o StrictHostKeyChecking=no -o ConnectTimeout=15 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes"
SSH="ssh $SSHOPTS -p $PORT $CMU"
SCP="scp $SSHOPTS -P $PORT"

# --- colors ------------------------------------------------------------------
if [ -t 1 ]; then
  C_R=$'\033[31m';   C_G=$'\033[32m';   C_Y=$'\033[33m'
  C_B=$'\033[34m';   C_M=$'\033[35m';   C_C=$'\033[36m'
  C_BR=$'\033[1;31m';C_BG=$'\033[1;32m';C_BY=$'\033[1;33m'
  C_BC=$'\033[1;36m';C_BM=$'\033[1;35m'
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m';  C_0=$'\033[0m'
else
  C_R="";C_G="";C_Y="";C_B="";C_M="";C_C=""
  C_BR="";C_BG="";C_BY="";C_BC="";C_BM=""
  C_BOLD="";C_DIM="";C_0=""
fi

ok(){   printf "%s✓%s %s\n"  "$C_BG" "$C_0" "$*"; }
err(){  printf "%s✗%s %s\n"  "$C_BR" "$C_0" "$*"; }
warn(){ printf "%s!%s %s\n"  "$C_BY" "$C_0" "$*"; }
info(){ printf "%s▸%s %s\n"  "$C_BC" "$C_0" "$*"; }
hdr(){  echo; printf "%s═══ %s ═══%s\n" "$C_BC" "$*" "$C_0"; }

# 1) Create USB unlock stick — number-picker (no path typing, no /dev/ mistakes)
make_usb() {
  hdr "Create USB unlock stick"
  info "detecting external USB drives..."
  echo

  # POSIX-friendly enumeration: pack "dev|size — name" into positional params
  # ($1, $2, …). No bash arrays, no `< <(…)` process substitution — so this
  # parses cleanly whether the script is invoked with bash or /bin/sh (macOS
  # `sh` is bash-in-posix and rejects both at PARSE time).
  local tmp
  tmp=$(mktemp -t mzdusb) || { err "mktemp failed"; return 1; }
  diskutil list external 2>/dev/null | grep -E '^/dev/disk[0-9]+ \(external' > "$tmp"

  set --
  local n=0
  local line id dev sz name
  while IFS= read -r line; do
    id="${line%% *}"                                 # "/dev/disk4"
    dev="${id##*/}"                                  # "disk4"
    sz=$(diskutil info "$id" 2>/dev/null | awk -F': *' '/^ *Disk Size/{print $2; exit}')
    name=$(diskutil info "$id" 2>/dev/null | awk -F': *' '/^ *Device \/ Media Name/{print $2; exit}')
    n=$((n+1))
    set -- "$@" "$dev|${sz:-?} — ${name:-USB drive}"
  done < "$tmp"
  rm -f "$tmp"

  if [ "$n" -eq 0 ]; then
    err "no external USB drive found. Plug one in and pick option 1 again."
    return 1
  fi

  echo "Pick the USB to WIPE and prepare as MZD (FAT32):"
  echo
  local i=1
  local e d l
  for e in "$@"; do
    d="${e%%|*}"
    l="${e#*|}"
    printf "  %s%d%s  /dev/%-7s  %s\n" "$C_BOLD" "$i" "$C_0" "$d" "$l"
    i=$((i+1))
  done
  printf "  %s0%s  cancel\n" "$C_BOLD" "$C_0"
  echo
  printf "> "
  read CH
  case "$CH" in
    ""|0) warn "cancelled"; return 0 ;;
    [1-9]|[1-9][0-9]) : ;;
    *) warn "invalid"; return 0 ;;
  esac
  if [ "$CH" -lt 1 ] || [ "$CH" -gt "$n" ]; then
    warn "invalid choice"; return 0
  fi
  # Pull the CH-th positional param via eval (POSIX way to index).
  local sel D INFO
  eval "sel=\${$CH}"
  D="${sel%%|*}"
  INFO="${sel#*|}"

  echo
  warn "about to WIPE /dev/$D  ($INFO)"
  printf "confirm? [y/N] > "
  read C
  case "$C" in y|Y) : ;; *) warn "cancelled"; return 0 ;; esac

  echo
  info "step 1/4 · unmounting /dev/$D..."
  diskutil unmountDisk "/dev/$D" 2>&1 | sed 's/^/    /' || true

  info "step 2/4 · erasing as FAT / MZD (MBR)..."
  # Deliberately using eraseDisk (NOT partitionDisk) with plain "MS-DOS" — this
  # is the exact same command as v1.0.0 that produced sticks the CMU media
  # player accepts. partitionDisk with an explicit "FAT32" type creates a
  # partition with different reserved-sector/alignment defaults, and on some
  # CMU firmware it plays the mp3s as silence or refuses to play them at all.
  if ! diskutil eraseDisk "MS-DOS" MZD MBR "/dev/$D" 2>&1 | sed 's/^/    /'; then
    err "eraseDisk failed. Fallback: format manually via Disk Utility"
    err "  (Applications → Utilities → Disk Utility → select drive → Erase"
    err "   → Format: MS-DOS (FAT), Scheme: Master Boot Record, Name: MZD)"
    err "then re-run option 1 — it will detect /Volumes/MZD and copy files."
    return 1
  fi

  # Wait for /Volumes/MZD to appear (macOS Finder takes a few seconds).
  local w=0
  while [ ! -d /Volumes/MZD ] && [ $w -lt 20 ]; do sleep 1; w=$((w+1)); done
  if [ ! -d /Volumes/MZD ]; then
    err "/Volumes/MZD did not mount after 20 s — check the drive is inserted and healthy"
    return 1
  fi

  info "step 3/4 · copying payload (AppleDouble sidecars disabled)..."
  # COPYFILE_DISABLE=1 → macOS won't write ._* metadata files on FAT32.
  # The CMU media scanner treats those as extra "tracks" and can miss the real
  # mp3s (or index the sidecars first and the XSS trigger never fires).
  ( export COPYFILE_DISABLE=1 && cp -R "$FILES/usb_unlock/"* /Volumes/MZD/ ) || {
    err "copy failed"; return 1;
  }

  # Also drop the 4 mp3s directly at the drive ROOT (duplicated, same names).
  # Some CMU head units auto-play the first root-level audio track the moment
  # the drive mounts — this is what made the very first working stick "just
  # play and pop the SSH menu" without anyone navigating into Media → USB →
  # a subfolder. Keeping the mp3/ copies too costs nothing and is what the
  # upstream mzd-connect-1-root repo ships, so both paths are covered.
  ( export COPYFILE_DISABLE=1 && cp "$FILES/usb_unlock/mp3/"*.mp3 /Volumes/MZD/ ) 2>/dev/null || true

  # The CarPlay + Android Auto HUD patch rides on the same stick: the XSS
  # menu's HUD+ / HUD- / HUD? buttons run hud-mod/usb_run.sh from it.
  # The 'h' dispatcher lives at the stick root — each HUD button fires a
  # short "sh /mnt/sda1/h <action> <token>" through the CGI (the CGI has a
  # URL-length limit, so the command must be SSH-sized).
  if [ -f "$UNIFIED/usb_run.sh" ]; then
    ( export COPYFILE_DISABLE=1 && mkdir -p /Volumes/MZD/hud-mod && cp "$UNIFIED/"* /Volumes/MZD/hud-mod/ ) || {
      err "copy of hud-mod failed"; return 1;
    }
  fi
  if [ -f "$FILES/usb_unlock/h" ]; then
    ( export COPYFILE_DISABLE=1 && cp "$FILES/usb_unlock/h" /Volumes/MZD/h ) || {
      err "copy of h dispatcher failed"; return 1;
    }
  fi

  # Also strip any macOS bookkeeping files that appeared regardless.
  find /Volumes/MZD \( -name '._*' -o -name '.DS_Store' -o -name '.Trashes' \
                       -o -name '.Spotlight-V100' -o -name '.fseventsd' \
                       -o -name '.TemporaryItems' -o -name '.apdisk' \) \
       -exec rm -rf {} + 2>/dev/null || true

  sync

  info "step 4/4 · verifying..."
  echo
  echo "  volume info:"
  diskutil info /Volumes/MZD 2>/dev/null | awk '
    /Volume Name/                 {printf "    %s\n",$0}
    /File System Personality/     {printf "    %s\n",$0}
    /Type \(Bundle\)/             {printf "    %s\n",$0}
    /Volume Total Space/          {printf "    %s\n",$0}
  '
  echo
  echo "  files:"
  ls -la /Volumes/MZD | sed 's/^/    /'
  echo

  local problems=0
  local f srcf src_md5 dst_md5
  for f in s dev.html mp3/a.mp3 mp3/b.mp3 mp3/c.mp3 mp3/d.mp3 \
           a.mp3 b.mp3 c.mp3 d.mp3 js/run.js js/enable_ssh.sh css/init.css; do
    if [ ! -e "/Volumes/MZD/$f" ]; then
      err "  MISSING: $f"
      problems=$((problems+1))
      continue
    fi
    case "$f" in
      a.mp3|b.mp3|c.mp3|d.mp3) srcf="$FILES/usb_unlock/mp3/$f" ;;
      *)                       srcf="$FILES/usb_unlock/$f" ;;
    esac
    # Byte-for-byte identity check — catches truncated / xattr-fluffed copies.
    src_md5=$(md5 -q "$srcf" 2>/dev/null)
    dst_md5=$(md5 -q "/Volumes/MZD/$f" 2>/dev/null)
    if [ "$src_md5" != "$dst_md5" ]; then
      err "  CORRUPT: $f  (src=$src_md5  dst=$dst_md5)"
      problems=$((problems+1))
    fi
  done
  for f in "$UNIFIED"/*; do
    [ -f "$f" ] || continue
    if [ "$(md5 -q "$f" 2>/dev/null)" != "$(md5 -q "/Volumes/MZD/hud-mod/$(basename "$f")" 2>/dev/null)" ]; then
      err "  MISSING/CORRUPT: hud-mod/$(basename "$f")"
      problems=$((problems+1))
    fi
  done
  # Reject if AppleDouble sidecars survived (they should not).
  local dsc
  dsc=$(find /Volumes/MZD -name '._*' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$dsc" -gt 0 ]; then
    err "  $dsc AppleDouble (._*) sidecar files leaked — this will break the CMU"
    problems=$((problems+dsc))
  fi

  if [ "$problems" -eq 0 ]; then
    ok "all critical files present + byte-identical to source, no AppleDouble junk"
  else
    err "$problems problem(s) above — stick will NOT trigger the XSS. Re-run option 1."
    diskutil eject /Volumes/MZD 2>/dev/null || true
    return 1
  fi

  diskutil eject /Volumes/MZD
  echo
  ok "USB ready. In the car: Media → USB → tap any mp3 (or wait — it may autoplay) → the XSS menu appears."
  info "  SSH   — enable SSH for this toolkit"
  info "  HUD+  — install the CarPlay + Android Auto HUD patch (tap twice; the unit reboots by itself)"
  info "  HUD-  — remove it (back to stock)      HUD? — check that every part is active"
  info "  Every HUD button ends with a message on screen — if it says ERROR, photo it and send it;"
  info "  the same text + the full log are on the stick in hud-mod/logs/."
}

# 2) Backup CMU state (before any mods)
backup() {
  hdr "Backup CMU state (before any mods)"
  local ts dst
  ts=$(date +%Y%m%d_%H%M%S)
  dst="$DIR/backups/$ts"
  mkdir -p "$dst"
  info "backing up to $dst"

  if ! $SSH 'tar -czf /tmp/backup.tar.gz \
    /jci/sm/sm.conf /jci/sm/sm_WCP.conf /etc/devmgr_config_master.xml \
    /jci/carplay/blmjcicarplay.so /jci/version.ini \
    /data_persist/cp-hud-mod /data_persist/splim_udpd_start.sh /data_persist/splim \
    2>/dev/null; ls -la /tmp/backup.tar.gz' | sed 's/^/  /'; then
    err "tar failed on CMU"
    return 1
  fi
  if ! $SCP "$CMU:/tmp/backup.tar.gz" "$dst/backup.tar.gz"; then
    err "scp of backup failed"
    return 1
  fi
  $SSH 'rm -f /tmp/backup.tar.gz' 2>/dev/null

  local sz
  sz=$(wc -c < "$dst/backup.tar.gz" 2>/dev/null | tr -d ' ')
  if [ -z "$sz" ] || [ "$sz" = "0" ]; then
    err "backup file is empty — something went wrong, check SSH and retry"
    return 1
  fi
  ok "backup saved: $dst/backup.tar.gz ($sz bytes)"
}

# --- shared: verify a local file exists and, if a checksum is given, matches -
# require_local PATH [EXPECTED_MD5]  → 0 on success, 1 with err() on failure.
require_local() {
  local f="$1" want="${2:-}"
  if [ ! -f "$f" ]; then
    err "local file missing: $f"
    err "  the toolkit tree is incomplete — re-download the release ZIP"
    return 1
  fi
  if [ -n "$want" ]; then
    local got
    got=$(md5 -q "$f" 2>/dev/null || md5sum "$f" 2>/dev/null | awk '{print $1}')
    if [ "$got" != "$want" ]; then
      err "local file has wrong md5: $f"
      err "  got:      $got"
      err "  expected: $want"
      err "  this file is stale — re-download the release ZIP"
      return 1
    fi
  fi
  return 0
}

# --- shared: run one remote command, retrying if the ssh invocation itself
# reports failure (dropped link, transient auth hiccup, etc). ---------------
# ssh_cmd_retry ATTEMPTS CMD  → prints stdout+stderr, returns the last
# attempt's exit code. Retries the WHOLE remote command on a non-zero ssh
# exit, instead of silently treating "connection problem" the same as
# "command ran and found nothing".
ssh_cmd_retry() {
  local attempts="$1"; shift
  local i=1 out rc
  while [ "$i" -le "$attempts" ]; do
    out=$($SSH "$@" 2>&1); rc=$?
    if [ "$rc" -eq 0 ]; then
      printf '%s' "$out"
      return 0
    fi
    i=$((i+1))
    [ "$i" -le "$attempts" ] && sleep 2
  done
  printf '%s' "$out"
  return "$rc"
}

# --- shared: scp a file to CMU and verify the remote md5 matches expected. ---
# push_verify LOCAL REMOTE_PATH EXPECTED_MD5 [ATTEMPTS]  → 0 ok, 1 loud fail.
# Retries the whole scp+md5-check cycle up to ATTEMPTS times (default 3)
# before giving up. A silently-failed scp used to let installs continue with
# stale/missing bits — this makes that loud and retried instead.
push_verify() {
  local src="$1" dst="$2" want="$3" attempts="${4:-3}"
  require_local "$src" "$want" || return 1
  info "  → $(basename "$src")  →  $dst"

  local i=1 got
  while [ "$i" -le "$attempts" ]; do
    if [ "$i" -gt 1 ]; then
      warn "    retry $i/$attempts..."
      sleep 2
    fi
    if $SCP "$src" "$CMU:$dst" 2>&1 | sed 's/^/      /'; then
      got=$($SSH "chmod 0644 '$dst' 2>/dev/null; md5sum '$dst' 2>/dev/null | awk '{print \$1}'")
      if [ "$got" = "$want" ]; then
        ok "    md5 verified ($want)"
        return 0
      fi
      warn "    md5 mismatch (got=${got:-<none>} want=$want)"
    else
      warn "    scp failed"
    fi
    i=$((i+1))
  done
  err "  giving up on $(basename "$src") after $attempts attempt(s)"
  return 1
}

# --- shared: run KidMixer's own install.sh (LD_PRELOAD + NaviSupported=TRUE) --
# Copies the PURE .so as libpatch-blmjcicarplay.so and runs KidMixer's installer.
# Idempotent — install.sh skips lines already present. Retries the whole
# copy+run cycle up to 3 times.
kidmixer_base_install() {
  info "copying KidMixer install.sh + pure .so"
  require_local "$FILES/install.sh"                               || return 1
  require_local "$FILES/libpatch-blmjcicarplay.so" "$MD5_SO_PURE"  || return 1

  local attempt=1
  while [ "$attempt" -le 3 ]; do
    if [ "$attempt" -gt 1 ]; then
      warn "  retry $attempt/3..."
      sleep 2
    fi
    if $SSH 'mkdir -p /tmp/cp-hud-install' \
      && $SCP "$FILES/install.sh"                $CMU:/tmp/cp-hud-install/ \
      && $SCP "$FILES/libpatch-blmjcicarplay.so" $CMU:/tmp/cp-hud-install/ \
      && $SSH 'cd /tmp/cp-hud-install && sh install.sh'; then
      return 0
    fi
    attempt=$((attempt+1))
  done
  err "KidMixer base install failed after 3 attempts"
  return 1
}

# --- shared: kill our speed daemon + wipe its state on CMU ------------------
# Used both by pure-KidMixer install (to clean any prior mod) and by rollback.
# IMPORTANT: plain pkill/pgrep here, NEVER `-f`. `-f` matches a process's
# FULL cmdline, and this very command's own text (passed to the remote shell
# as `sh -c "...pkill -9 -f splim_bridge..."`) contains the literal substring
# "splim_bridge"/"splim_udpd" — so `pkill -f splim_bridge` finds and SIGKILLs
# the script that is CURRENTLY RUNNING IT, terminating everything on that
# exact line with zero output, zero error. This is why force-start and
# rollback's daemon-cleanup step were dying silently right after their first
# echo, every single time — not a flaky SSH link. Plain (no -f) pkill/pgrep
# match only the process's short "comm" name (derived from the executed
# file's basename — "splim_udpd" for the daemon, "sh" for this management
# script), which correctly targets the real daemon and never self-matches.
wipe_speed_mod() {
  ssh_cmd_retry 2 '
    pkill -9 splim_bridge  2>/dev/null
    pkill -9 splim_udpd    2>/dev/null
    kill -9 $(pgrep splim_udpd) 2>/dev/null
    rm -f /data_persist/splim_udpd_start.sh
    rm -f /data_persist/cp-hud-mod/splim_bridge*.sh
    rm -f /data_persist/cp-hud-mod/splim_udpd
    rm -f /data_persist/cp-hud-mod/.variant
    rm -f /data_persist/splim /mnt/data_persist/splim
    rm -f /tmp/splim_v*_cache /tmp/splim_v*_last /tmp/splim_v*_tsr /tmp/splim_v*_nng /tmp/splim_v*_lanes
    rm -rf /tmp/splim_v*_cache
    sleep 1
    true
  ' >/dev/null 2>&1
}

# --- shared: poll until SSH answers again after a reboot ---------------------
# wait_for_ssh [MAX_SECONDS]  → 0 if SSH came back, 1 on timeout.
# The CMU's sshd does NOT persist across reboot on the read-only rootfs, so
# this can only succeed once the USB stick has been re-inserted and the XSS
# → SSH tap has run in the car. We poll patiently and tell the user exactly
# what to do while waiting.
wait_for_ssh() {
  local max_wait="${1:-300}" elapsed=0 interval=5
  echo
  warn "CMU is rebooting — this takes about 90 seconds."
  info "In the car: once the screen comes back, Media → USB → tap any mp3 (or let it autoplay) → tap SSH in the XSS menu."
  info "I'll detect the SSH connection automatically — checking every ${interval}s for up to $((max_wait/60)) min."
  echo
  while [ "$elapsed" -lt "$max_wait" ]; do
    if ping -c 1 -t 2 192.168.53.1 >/dev/null 2>&1 && $SSH 'true' 2>/dev/null; then
      printf "\r%-70s\n" " "
      ok "SSH is back (after ${elapsed}s)"
      return 0
    fi
    printf "\r  ...waiting (%3ds / %ds)   " "$elapsed" "$max_wait"
    sleep "$interval"
    elapsed=$((elapsed+interval))
  done
  printf "\r%-70s\n" " "
  warn "SSH did not come back within ${max_wait}s"
  warn "once you've done USB → XSS → SSH, run Advanced → V (Validate)"
  return 1
}

# ============================================================================
#  MAIN FLOW — menu 3
# ============================================================================
# Full rollback (restore stock)
# ---------------------------------------------------------------------
# Kills our daemon, wipes state, runs KidMixer's own uninstall.sh, then
# VERIFIES sm.conf is clean and NaviSupported=FALSE — force-strips residue
# if the .bak_precphud backup happened to contain a modded sm.conf (this
# happens when the very first install was run on an already-modded CMU:
# install.sh backs up the "current" state, so the backup is not stock).
# Reboots, waits for SSH, then confirms the final state.
rollback() {
  hdr "Full rollback — restore factory state"
  info "1/3 · killing our speed daemon + wiping state"
  wipe_speed_mod

  info "2/3 · running KidMixer uninstall.sh (restores sm.conf, NaviSupported=FALSE)"
  $SCP "$FILES/uninstall.sh" "$CMU:/tmp/uninstall.sh" || { err "scp uninstall.sh failed"; return 1; }
  $SSH 'sh /tmp/uninstall.sh' | sed 's/^/  /'

  info "3/3 · verifying + force-cleaning any residue"
  # Print current state, then unconditionally strip any leftover LD_PRELOAD /
  # LD_LIBRARY_PATH lines and force NaviSupported=FALSE. Safe even if already
  # clean — grep -v of absent lines is a no-op.
  $SSH '
    mount -o remount,rw / 2>/dev/null || true

    for CONF in /jci/sm/sm.conf /jci/sm/sm_WCP.conf; do
      [ -f "$CONF" ] || continue
      before=$(grep -c "libpatch-blmjcicarplay" "$CONF" 2>/dev/null); before=${before:-0}
      if [ "$before" -gt 0 ]; then
        echo "  ! $CONF still has $before LD_PRELOAD lines — force-stripping"
        grep -v "libpatch-blmjcicarplay" "$CONF" \
          | grep -v "LD_LIBRARY_PATH.*jci/lib:/usr/lib" > /tmp/rb.clean
        cp /tmp/rb.clean "$CONF"; rm -f /tmp/rb.clean
        sed -i "/name=\"jciCARPLAY\"/ s/reset_board=\"no\"/reset_board=\"yes\"/" "$CONF"
      fi
    done

    if grep -q "<name>NaviSupported</name><value>TRUE</value>" /etc/devmgr_config_master.xml 2>/dev/null; then
      echo "  ! NaviSupported=TRUE — forcing to FALSE"
      sed -i "s#<name>NaviSupported</name><value>TRUE</value>#<name>NaviSupported</name><value>FALSE</value>#" /etc/devmgr_config_master.xml
    fi

    rm -rf /data_persist/cp-hud-mod
    sync
    mount -o remount,ro / 2>/dev/null || true

    echo "  final: sm.conf preload=$(grep -c libpatch /jci/sm/sm.conf 2>/dev/null)  sm_WCP.conf preload=$(grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null)  NaviSupported=$(grep -oE "<name>NaviSupported</name><value>[A-Z]+" /etc/devmgr_config_master.xml 2>/dev/null | grep -oE "[A-Z]+$")"
  ' | sed 's/^/  /'

  ok "rollback commands complete. Rebooting..."
  $SSH 'sync && reboot' 2>&1 | head -3 || true

  if wait_for_ssh 300; then
    echo
    info "confirming factory state..."
    local st
    st=$($SSH '
      echo "PRELOAD_SM=$(grep -c libpatch /jci/sm/sm.conf 2>/dev/null || echo 0)"
      echo "PRELOAD_WCP=$(grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null || echo 0)"
      echo "NAVISUPPORTED=$(grep -oE "<name>NaviSupported</name><value>[A-Z]+" /etc/devmgr_config_master.xml 2>/dev/null | grep -oE "[A-Z]+$")"
    ' 2>&1)
    echo "$st" | sed 's/^/  /'
    if echo "$st" | grep -q "NAVISUPPORTED=FALSE" \
       && ! echo "$st" | grep -qE "PRELOAD_SM=[1-9]" \
       && ! echo "$st" | grep -qE "PRELOAD_WCP=[1-9]"; then
      ok "CMU confirmed back to factory state"
    else
      warn "CMU may still have residue — run Advanced → D for a full dump"
    fi
  else
    warn "run Advanced → S once SSH is back to confirm manually"
  fi
}

# ============================================================================
#  MAIN FLOW — menu 4 (recommended)
# ============================================================================
# Install KidMixer + our v16 speed patch (mod)
# ---------------------------------------------------------------------
# Result on HUD: CarPlay arrow + distance + street PLUS speed limit driven
# by the daemon that mirrors com.jci.vbs.navi.SetHUDDisplayMsgReq frames.
# The mod .so's patched read_splim rejects future-dated stale-file writes
# (fixes the post-reboot "20" latch when RTC starts at 1970).
# Every file copy is md5-verified with retries; after reboot this function
# waits for SSH to come back and automatically runs validate().
install_mod() {
  hdr "Install ilshyma HUD Patch  ★ recommended (v16 — speed limit fixed)"

  kidmixer_base_install || { err "aborted — base install failed"; return 1; }

  info "overlaying patched .so (v16)"
  $SSH 'mount -o remount,rw / 2>/dev/null; true'
  push_verify "$FILES/libpatch-blmjcicarplay-splim.so" \
              "/data_persist/cp-hud-mod/libpatch-blmjcicarplay.so" \
              "$MD5_SO_MOD" \
    || { err "aborted — v16 mod .so did not land correctly"; return 1; }

  info "deploying speed-mirror daemon (v16) + auto-launcher"
  # Deploy the daemon as "splim_udpd" (NO .sh) — the shim looks it up via
  # `pgrep splim_udpd`, which matches argv[0]'s basename. If we ship it as
  # splim_bridge.sh, pgrep never matches, the shim keeps re-spawning it, and
  # the launcher (`exec /data_persist/cp-hud-mod/splim_udpd`) fails ENOENT.
  push_verify "$FILES/splim_bridge.sh"     "/data_persist/cp-hud-mod/splim_udpd" "$MD5_SPLIM_BRIDGE"   || { err "aborted — daemon did not land correctly"; return 1; }
  push_verify "$FILES/splim_udpd_start.sh" "/data_persist/splim_udpd_start.sh"   "$MD5_SPLIM_LAUNCHER" || { err "aborted — launcher did not land correctly"; return 1; }
  # Clear any stale splim data file left from a PREVIOUS boot/session. The
  # CMU's RTC resets to 1970 on every reboot, so a leftover file's timestamp
  # from a session with more uptime than this fresh boot has accumulated so
  # far reads as "in the future" — the v16 read_splim() guard rejects that
  # correctly, but the stale file confuses validate()'s reporting and is
  # simply not needed going forward.
  # Also drop orphaned per-version debug logs from earlier development/testing
  # iterations (v5..v15) — only v16's own log is used going forward, and these
  # just waste space on persistent flash with nothing pointing at them anymore.
  $SSH 'chmod +x /data_persist/cp-hud-mod/splim_udpd /data_persist/splim_udpd_start.sh
        rm -f /data_persist/cp-hud-mod/splim_bridge.sh /data_persist/cp-hud-mod/splim_bridge_v*.sh
        rm -f /mnt/data_persist/splim /data_persist/splim
        rm -f /mnt/data_persist/log/splim_v5.log /mnt/data_persist/log/splim_v6.log \
              /mnt/data_persist/log/splim_v7.log /mnt/data_persist/log/splim_v8.log \
              /mnt/data_persist/log/splim_v9.log /mnt/data_persist/log/splim_v10.log \
              /mnt/data_persist/log/splim_v11.log /mnt/data_persist/log/splim_v12.log \
              /mnt/data_persist/log/splim_v13.log /mnt/data_persist/log/splim_v14.log \
              /mnt/data_persist/log/splim_v15.log
        echo v16 > /data_persist/cp-hud-mod/.variant'

  ok "install complete — every file verified. Rebooting..."
  $SSH 'sync && reboot' 2>&1 | head -3 || true

  if wait_for_ssh 300; then
    echo
    info "running automatic post-install validation..."
    validate
  else
    warn "validation skipped — run Advanced → V once SSH is back"
  fi
}

# ============================================================================
#  MAIN FLOW — menu 5
# ============================================================================
# Validate installation — checks every link in the chain, auto-fixes the
# speed daemon if it's dead, and gives a clear pass/fail verdict + a saved log.
# Safe to re-run any time (e.g. days later if the speed limit stops updating).
validate() {
  if unified_installed; then validate_unified; return; fi
  hdr "Validate installation"
  mkdir -p "$DIR/logs"
  local ts logfile problems=0
  ts=$(date +%Y%m%d_%H%M%S)
  logfile="$DIR/logs/validate_$ts.log"

  # Small grace period: right after a reboot, the service manager may still be
  # sequencing jciCARPLAY even though sshd already answered.
  info "collecting diagnostics from CMU (waiting 5s for services to settle)..."
  sleep 5

  local raw
  raw=$($SSH '
    echo "PRELOAD_SM=$(grep -c libpatch /jci/sm/sm.conf 2>/dev/null || echo 0)"
    echo "PRELOAD_WCP=$(grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null || echo 0)"
    echo "NAVISUPPORTED=$(grep -oE "<name>NaviSupported</name><value>[A-Z]+" /etc/devmgr_config_master.xml 2>/dev/null | grep -oE "[A-Z]+$")"
    P=$(ps | awk "/[L]_jciCARPLAY/{print \$1; exit}")
    echo "CARPLAY_PID=${P:-0}"
    if [ -n "$P" ]; then
      echo "CARPLAY_LOADED=$(tr "\0" "\n" < /proc/$P/maps 2>/dev/null | grep -c libpatch-blmjcicarplay)"
    else
      echo "CARPLAY_LOADED=0"
    fi
    echo "SO_MD5=$(md5sum /data_persist/cp-hud-mod/libpatch-blmjcicarplay.so 2>/dev/null | awk "{print \$1}")"
    echo "VARIANT=$(cat /data_persist/cp-hud-mod/.variant 2>/dev/null)"
    echo "DAEMON_COUNT=$(ps | grep -v grep | grep -cE "splim_udpd|splim_bridge")"
    echo "LAUNCHER_OK=$([ -x /data_persist/splim_udpd_start.sh ] && echo 1 || echo 0)"
    echo "DAEMON_BIN_OK=$([ -x /data_persist/cp-hud-mod/splim_udpd ] && echo 1 || echo 0)"
    SF=""
    [ -e /mnt/data_persist/splim ] && SF=$(cat /mnt/data_persist/splim 2>/dev/null)
    [ -z "$SF" ] && [ -e /data_persist/splim ] && SF=$(cat /data_persist/splim 2>/dev/null)
    echo "SPLIM_CONTENT=$SF"
    echo "CLOCK=$(date)"
  ' 2>&1)
  printf '%s\n' "$raw" > "$logfile"

  # fld NAME RAWTEXT → value after "NAME=" on its line (POSIX-safe extraction,
  # no bash-array/nested-scope trickery).
  fld() { printf '%s\n' "$2" | grep "^$1=" | head -1 | cut -d= -f2-; }

  local preload_sm preload_wcp navisupported carplay_pid carplay_loaded
  local so_md5 variant daemon_count launcher_ok daemon_bin_ok splim_content
  preload_sm=$(fld PRELOAD_SM "$raw")
  preload_wcp=$(fld PRELOAD_WCP "$raw")
  navisupported=$(fld NAVISUPPORTED "$raw")
  carplay_pid=$(fld CARPLAY_PID "$raw")
  carplay_loaded=$(fld CARPLAY_LOADED "$raw")
  so_md5=$(fld SO_MD5 "$raw")
  variant=$(fld VARIANT "$raw")
  daemon_count=$(fld DAEMON_COUNT "$raw")
  launcher_ok=$(fld LAUNCHER_OK "$raw")
  daemon_bin_ok=$(fld DAEMON_BIN_OK "$raw")
  splim_content=$(fld SPLIM_CONTENT "$raw")

  echo
  # 1. LD_PRELOAD wiring
  if [ "${preload_sm:-0}" -gt 0 ] || [ "${preload_wcp:-0}" -gt 0 ]; then
    ok "LD_PRELOAD wired  (sm.conf=$preload_sm  sm_WCP.conf=$preload_wcp)"
  else
    err "LD_PRELOAD missing from both sm.conf and sm_WCP.conf — install did not take"
    problems=$((problems+1))
  fi

  # 2. NaviSupported
  if [ "$navisupported" = "TRUE" ]; then
    ok "NaviSupported=TRUE"
  else
    err "NaviSupported=$navisupported (expected TRUE)"
    problems=$((problems+1))
  fi

  # 3. jciCARPLAY process + our .so loaded into it
  if [ "${carplay_pid:-0}" != "0" ] && [ -n "$carplay_pid" ]; then
    if [ "${carplay_loaded:-0}" -gt 0 ]; then
      ok "jciCARPLAY running (pid=$carplay_pid) with our shim loaded"
    else
      err "jciCARPLAY running (pid=$carplay_pid) but shim NOT loaded — try another reboot"
      problems=$((problems+1))
    fi
  else
    err "jciCARPLAY is not running"
    problems=$((problems+1))
  fi

  # 4. .so identity on disk
  case "$so_md5" in
    "$MD5_SO_MOD")        ok "mod .so on disk: v16 (speed-limit patch)" ;;
    "$MD5_SO_MOD_LEGACY")  ok "mod .so on disk: legacy pre-v16 (speed-limit patch)" ;;
    "$MD5_SO_PURE")        warn "PURE KidMixer .so on disk — no speed-limit patch installed (expected for menu P)" ;;
    "")                    err "no .so found on disk at /data_persist/cp-hud-mod/"; problems=$((problems+1)) ;;
    *)                     warn "unrecognized .so md5 on disk: $so_md5" ;;
  esac

  # 5. speed-mirror daemon — auto-fix if a mod variant expects one but it's dead
  case "$variant" in
    pure)
      info "PURE variant installed — no speed daemon expected (this is normal)"
      ;;
    v16|legacy|*)
      if [ "${daemon_count:-0}" -gt 0 ]; then
        ok "speed-mirror daemon is running ($daemon_count process(es))"
      else
        warn "speed-mirror daemon is NOT running — attempting to auto-start it now"
        if [ "$daemon_bin_ok" = "1" ] && [ "$launcher_ok" = "1" ]; then
          # Up to 3 attempts: this CMU's Wi-Fi has been observed to drop an
          # SSH command mid-way with no error, which alone can make a single
          # start-then-recheck cycle look like "daemon refuses to start" when
          # really the START command itself never fully landed. Sanitize the
          # recheck output to a clean digit before comparing — a dropped
          # connection returns ssh's own error text, not a bare "0".
          local fix_try=1 fix_ok=0 recheck_raw recheck
          while [ "$fix_try" -le 3 ] && [ "$fix_ok" -eq 0 ]; do
            [ "$fix_try" -gt 1 ] && warn "  retry $fix_try/3 (link may have dropped mid-command)..."
            force_start_daemon_quiet
            sleep 3
            recheck_raw=$(ssh_cmd_retry 2 'ps | grep -v grep | grep -cE "splim_udpd|splim_bridge"')
            case "$recheck_raw" in
              ''|*[!0-9]*) recheck=0 ;;
              *)           recheck=$recheck_raw ;;
            esac
            [ "$recheck" -gt 0 ] && fix_ok=1
            fix_try=$((fix_try+1))
          done
          if [ "$fix_ok" -eq 1 ]; then
            ok "  auto-fix worked — daemon is now running (attempt $((fix_try-1))/3)"
          else
            err "  auto-fix FAILED after 3 attempts — daemon still not running"
            err "  this is critical: the speed-limit slot will stay stuck at --- until this is fixed"
            {
              echo
              echo "=== uptime / load at time of failure (a saturated CPU can make our"
              echo "    few-second start/settle timing too tight) ==="
              ssh_cmd_retry 2 'uptime'
              echo
              echo "=== launcher stderr (/tmp/splim_launcher.log) ==="
              ssh_cmd_retry 2 'cat /tmp/splim_launcher.log 2>/dev/null'
              echo
              echo "=== full ps snapshot ==="
              ssh_cmd_retry 2 'ps'
            } >> "$logfile"
            err "  full diagnostic + launcher log saved to: $logfile"
            err "  try Advanced → D for a live verbose dump, or Advanced → F to retry manually"
            problems=$((problems+1))
          fi
        else
          err "  cannot auto-fix: daemon binary or launcher missing on CMU — re-run Advanced → L"
          problems=$((problems+1))
        fi
      fi
      ;;
  esac

  # 6. splim data file (informational — only populates once real driving data
  #    flows in from the OEM TSR camera or map data)
  if [ -n "$splim_content" ]; then
    info "speed-limit file currently holds: $splim_content  (updates live while driving)"
  else
    info "speed-limit file is empty — normal right after install; fills in once you drive past a sign"
  fi

  echo
  if [ "$problems" -eq 0 ]; then
    ok "═══ VALIDATION PASSED — HUD arrows are ready; speed limit will populate while driving ═══"
    info "log saved: $logfile"
    return 0
  else
    err "═══ VALIDATION FOUND $problems PROBLEM(S) ═══"
    err "full diagnostic saved to: $logfile"
    err "Advanced → D = verbose dump · Advanced → F = retry starting the daemon"
    return 1
  fi
}

# ============================================================================
#  MAIN FLOW — menu U / R  (CarPlay + Android Auto, one patch)
# ============================================================================
# files/unified/ is the release package of the unified branch
# (github.com/ilshyma/mazda-carplay-hud/tree/unified-carplay-aa):
#   4 shims — CarPlay (blmjcicarplay), Android Auto (blmjciaapa + aap_service)
#   and the svcjcinavi HUD arbiter that gives both phones the stock-nav speed
#   limit — plus its own install.sh / uninstall.sh, libpatch.conf and the AA
#   system-attribute XMLs. MD5SUMS pins the shims.
UNIFIED="$FILES/unified"
UNIFIED_REMOTE=/tmp/hud-mod
UNIFIED_DIR=/data_persist/oem-aa-mod

unified_installed() {
  $SSH "[ -f $UNIFIED_DIR/libpatch-svcjcinavi.so ] && grep -q 'oem-aa-mod/libpatch-blmjcicarplay' /jci/sm/sm.conf /jci/sm/sm_WCP.conf" 2>/dev/null
}

# Copy the package to the unit, every file md5-verified (retried by push_verify).
unified_push() {
  [ -f "$UNIFIED/MD5SUMS" ] || { err "missing $UNIFIED — the toolkit tree is incomplete, re-download it"; return 1; }
  $SSH "rm -rf $UNIFIED_REMOTE && mkdir -p $UNIFIED_REMOTE" || { err "cannot create $UNIFIED_REMOTE on the CMU"; return 1; }
  local f want
  for f in "$UNIFIED"/*; do
    [ "$(basename "$f")" = MD5SUMS ] && continue
    want=$(awk -v n="$(basename "$f")" '$2 == n {print $1}' "$UNIFIED/MD5SUMS")
    if [ -z "$want" ]; then   # scripts/config: verify the transfer against the local copy
      want=$(md5 -q "$f" 2>/dev/null || md5sum "$f" | awk '{print $1}')
    fi
    push_verify "$f" "$UNIFIED_REMOTE/$(basename "$f")" "$want" || return 1
  done
}

validate_unified() {
  hdr "Validate CarPlay + Android Auto patch"
  info "waiting 5s for services to settle..."
  sleep 5
  local out problems=0
  out=$($SSH 'sh -s' <<'REMOTE'
pid_of() { ps | awk -v p="$1" 'index($0, p) && !/awk/ { print $1; exit }'; }
for pair in L_jciCARPLAY:blmjcicarplay L_jciAAPA:blmjciaapa L_jcinavi:svcjcinavi /usr/bin/aap_service:aap_service; do
  svc=${pair%%:*}; so=${pair##*:}
  pid=$(pid_of "$svc")
  if [ -z "$pid" ]; then echo "MISS $svc not running"
  elif grep -q "libpatch-$so.so" /proc/$pid/maps 2>/dev/null; then echo "OK   $svc pid=$pid has libpatch-$so.so"
  else echo "FAIL $svc pid=$pid does NOT have libpatch-$so.so"; fi
done
echo "INFO NaviSupported=$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml | grep -oE '[A-Z]+$')"
echo "INFO config: $(grep -E '^(hud_transport|force_street_name|force_street_name_native|use_protocol_v1_6)' /data_persist/oem-aa-mod/libpatch.conf | tr '\n' ' ')"
echo "INFO stock-nav speed shared with CarPlay: $(cat /tmp/hud_oem_speed 2>/dev/null || echo 'none yet (appears with the first stock-nav HUD frame)')"
REMOTE
)
  echo "$out" | while IFS= read -r l; do
    case "$l" in
      OK*)   ok   "${l#OK   }" ;;
      FAIL*) err  "${l#FAIL }" ;;
      MISS*) warn "${l#MISS }" ;;
      *)     info "${l#INFO }" ;;
    esac
  done
  problems=$(echo "$out" | grep -cE '^(FAIL|MISS)')
  if [ "$problems" -eq 0 ] && echo "$out" | grep -q '^OK'; then
    ok "all 4 shims loaded — start a CarPlay or Android Auto route and watch the HUD"
  else
    err "$problems of 4 services not running or without their shim — wait a minute and re-run Advanced → V; if it stays, run Advanced → D"
    return 1
  fi
}

install_unified() {
  hdr "Install CarPlay + Android Auto HUD Patch (one patch for both phones)"
  info "arrows + distance on the HUD for CarPlay AND Android Auto,"
  info "speed-limit sign from the stock navigation for both (needs the nav SD card)."
  info "replaces any earlier HUD patch (KidMixer / ilshyma v16 / oem-aa-mod); every edited file is backed up."
  echo
  info "1/3 · copying the package (md5-verified)"
  unified_push || { err "aborted — package did not land correctly, nothing was changed"; return 1; }

  info "2/3 · running the installer on the CMU"
  local log
  log=$($SSH "cd $UNIFIED_REMOTE && sh install.sh" 2>&1)
  echo "$log" | sed 's/^/      /'
  if ! echo "$log" | grep -q 'DONE\. Reboot'; then
    err "installer did not finish — nothing to reboot for. The lines above say why."
    return 1
  fi
  # the old KidMixer speed daemon is retired by install.sh; make sure it is gone now, too
  $SSH 'for p in $(ps | grep "[s]plim_udpd" | awk "{print \$1}"); do kill $p; done' 2>/dev/null || true

  ok "installed — rebooting the CMU"
  $SSH 'sync && reboot' 2>&1 | head -3 || true

  info "3/3 · after the reboot"
  if wait_for_ssh 300; then
    validate_unified
  else
    warn "validation skipped — once SSH is back, run Advanced → V"
  fi
}

# Rollback for everyone (main menu 3): removes EVERY HUD patch this toolkit
# ever installed — the unified CarPlay + Android Auto patch, ilshyma v16 and
# its speed daemon, pure KidMixer, oem-aa-mod — and returns to stock.
# Uses the unified uninstall.sh, which strips every libpatch LD_PRELOAD from
# both sm configs, sets NaviSupported=FALSE and restores the AA XMLs.
rollback_all() {
  hdr "Rollback — remove every HUD patch, back to stock"
  printf "  This removes all HUD patches from the CMU and reboots. Continue? [y/N] "
  read C
  case "$C" in y|Y) : ;; *) warn "cancelled"; return 0 ;; esac
  local f="$UNIFIED/uninstall.sh"
  require_local "$f" || return 1

  info "1/3 · stopping the old speed daemon (v16), if any"
  wipe_speed_mod

  info "2/3 · removing the patches"
  push_verify "$f" /tmp/hud-mod-uninstall.sh "$(md5 -q "$f" 2>/dev/null || md5sum "$f" | awk '{print $1}')" || return 1
  $SSH 'sh /tmp/hud-mod-uninstall.sh; rm -rf /data_persist/cp-hud-mod /data_persist/splim_udpd_start.sh; sync' 2>&1 | sed 's/^/      /'
  ok "removed — rebooting the CMU"
  $SSH 'sync && reboot' 2>&1 | head -3 || true

  info "3/3 · confirming after the reboot"
  if wait_for_ssh 300; then
    local out
    out=$($SSH "echo \$(cat /jci/sm/sm.conf /jci/sm/sm_WCP.conf 2>/dev/null | grep -c libpatch-) \$(grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml | grep -oE '[A-Z]+\$')" 2>/dev/null)
    case "$out" in
      "0 FALSE") ok "back to stock: no patch preloads, NaviSupported=FALSE" ;;
      *)         warn "unexpected state after rollback: preload lines + NaviSupported = '$out' — run Advanced → D" ;;
    esac
  fi
}

# ============================================================================
#  ADVANCED — menu P
# ============================================================================
# Install PURE KidMixer (raw upstream code, no speed daemon)
# ---------------------------------------------------------------------
# Result on HUD: CarPlay maneuver arrow + distance + street; the built-in
# TSR-camera speed sign is untouched. No /data_persist/splim, no daemon.
install_pure() {
  hdr "Install PURE KidMixer Patch (known speed-limit issue)"
  kidmixer_base_install || { err "aborted — base install failed"; return 1; }

  # Force the pure .so to be the live one (in case a prior mod overlay is on disk).
  info "overlaying pure .so (in case a mod .so was on disk)"
  $SSH 'mount -o remount,rw / 2>/dev/null; true'
  push_verify "$FILES/libpatch-blmjcicarplay.so" \
              "/data_persist/cp-hud-mod/libpatch-blmjcicarplay.so" \
              "$MD5_SO_PURE" \
    || { err "aborted — pure .so did not land correctly"; return 1; }

  info "clearing any prior speed-mod daemon + state"
  wipe_speed_mod
  $SSH 'echo pure > /data_persist/cp-hud-mod/.variant' 2>/dev/null

  ok "pure KidMixer installed. Rebooting..."
  $SSH 'sync && reboot' 2>&1 | head -3 || true

  if wait_for_ssh 300; then
    echo
    info "running automatic post-install validation..."
    validate
  else
    warn "validation skipped — run Advanced → V once SSH is back"
  fi
}

# ============================================================================
#  ADVANCED — menu X
# ============================================================================
# Install ilshyma HUD Patch — LEGACY mod .so (pre-v16)
# ---------------------------------------------------------------------
# Fallback for if the v16 .so's future-ts read_splim guard ever misbehaves
# on a specific firmware (e.g. rejects legitimate frames it shouldn't).
# Uses the same v16 speed-mirror daemon + auto-launcher, but overlays the
# pre-v16 mod .so (md5 c8800f0e…). The HUD maneuver arrow itself (hud_send)
# is identical between the two .so builds — only read_splim() differs — so
# this is specifically a speed-limit-slot fallback, not an arrow fix.
# Trade-off vs v16: post-reboot, while the RTC is still near 1970, a stale
# splim file from a previous boot can briefly show its old value until the
# daemon writes a fresh frame (v16's guard exists precisely to avoid that).
install_mod_legacy() {
  hdr "Install ilshyma HUD Patch — LEGACY pre-v16 mod .so"

  kidmixer_base_install || { err "aborted — base install failed"; return 1; }

  info "overlaying LEGACY .so (pre-v16, md5 $MD5_SO_MOD_LEGACY)"
  $SSH 'mount -o remount,rw / 2>/dev/null; true'
  push_verify "$FILES/libpatch-blmjcicarplay-splim-legacy.so" \
              "/data_persist/cp-hud-mod/libpatch-blmjcicarplay.so" \
              "$MD5_SO_MOD_LEGACY" \
    || { err "aborted — legacy .so did not land correctly"; return 1; }

  info "deploying speed-mirror daemon (v16) + auto-launcher"
  push_verify "$FILES/splim_bridge.sh"     "/data_persist/cp-hud-mod/splim_udpd" "$MD5_SPLIM_BRIDGE"   || { err "aborted — daemon did not land correctly"; return 1; }
  push_verify "$FILES/splim_udpd_start.sh" "/data_persist/splim_udpd_start.sh"   "$MD5_SPLIM_LAUNCHER" || { err "aborted — launcher did not land correctly"; return 1; }
  $SSH 'chmod +x /data_persist/cp-hud-mod/splim_udpd /data_persist/splim_udpd_start.sh
        rm -f /data_persist/cp-hud-mod/splim_bridge.sh /data_persist/cp-hud-mod/splim_bridge_v*.sh
        rm -f /mnt/data_persist/splim /data_persist/splim
        rm -f /mnt/data_persist/log/splim_v5.log /mnt/data_persist/log/splim_v6.log \
              /mnt/data_persist/log/splim_v7.log /mnt/data_persist/log/splim_v8.log \
              /mnt/data_persist/log/splim_v9.log /mnt/data_persist/log/splim_v10.log \
              /mnt/data_persist/log/splim_v11.log /mnt/data_persist/log/splim_v12.log \
              /mnt/data_persist/log/splim_v13.log /mnt/data_persist/log/splim_v14.log \
              /mnt/data_persist/log/splim_v15.log
        echo legacy > /data_persist/cp-hud-mod/.variant'

  ok "legacy mod installed. Rebooting..."
  $SSH 'sync && reboot' 2>&1 | head -3 || true

  if wait_for_ssh 300; then
    echo
    info "running automatic post-install validation..."
    validate
  else
    warn "validation skipped — run Advanced → V once SSH is back"
  fi
}

# ============================================================================
#  ADVANCED — menu D
# ============================================================================
# Diagnose why the HUD speed-limit slot may be dead. Prints a compact, verbose
# report of every piece of the mod chain — for deep troubleshooting beyond
# what validate() summarizes.
diagnose() {
  hdr "Diagnose speed-limit chain (verbose)"
  $SSH "
    echo
    echo '─── 1. LD_PRELOAD wiring (sm.conf) ───'
    grep -c libpatch /jci/sm/sm.conf 2>/dev/null | awk '{print \"  sm.conf preload lines: \"\$0}'
    grep -c libpatch /jci/sm/sm_WCP.conf 2>/dev/null | awk '{print \"  sm_WCP.conf preload lines: \"\$0}'
    grep -oE '<name>NaviSupported</name><value>[A-Z]+' /etc/devmgr_config_master.xml 2>/dev/null | tr -d '<>' | awk '{print \"  \"\$0}'

    echo
    echo '─── 2. jciCARPLAY process (must be running, must carry LD_PRELOAD) ───'
    P=\$(ps | awk '/[L]_jciCARPLAY/{print \$1; exit}')
    if [ -n \"\$P\" ]; then
      echo \"  pid=\$P\"
      tr '\\0' '\\n' < /proc/\$P/maps 2>/dev/null | grep -o libpatch-blmjcicarplay | head -1 | awk '{print \"  loaded: \"\$0}'
      tr '\\0' ' '  < /proc/\$P/environ 2>/dev/null | tr ' ' '\\n' | grep LD_PRELOAD | awk '{print \"  \"\$0}'
    else
      echo '  ! jciCARPLAY not running — LD_PRELOAD did not fire'
    fi

    echo
    echo '─── 3. .so on disk + install variant ───'
    md5sum /data_persist/cp-hud-mod/libpatch-blmjcicarplay.so 2>/dev/null | awk '{print \"  \"\$0}'
    echo \"  variant marker: \$(cat /data_persist/cp-hud-mod/.variant 2>/dev/null || echo '(none)')\"

    echo
    echo '─── 4. speed-mirror daemon (must be running unless variant=pure) ───'
    DP=\$(ps | grep -v grep | grep -E 'splim_bridge|splim_udpd|dbus-monitor')
    if [ -n \"\$DP\" ]; then
      echo \"\$DP\" | awk '{print \"  \"\$0}'
    else
      echo '  ! no splim processes running'
    fi

    echo
    echo '─── 5. splim file (daemon writes this; shim reads it every 500 ms) ───'
    for P in /mnt/data_persist/splim /data_persist/splim; do
      if [ -e \"\$P\" ]; then
        printf '  %s → ' \"\$P\"
        ls -la \"\$P\" | awk '{print \$5\" bytes, mtime \"\$6\" \"\$7\" \"\$8}'
        printf '    content: '
        cat \"\$P\" 2>/dev/null; echo
        NOW=\$(date +%s)
        TS=\$(awk '{print \$2}' \"\$P\" 2>/dev/null)
        if [ -n \"\$TS\" ]; then
          echo \"    now=\$NOW  ts_in_file=\$TS  age=\$((NOW-TS))s\"
        fi
      else
        echo \"  \$P → does not exist\"
      fi
    done

    echo
    echo '─── 6. auto-launcher ───'
    ls -la /data_persist/splim_udpd_start.sh 2>/dev/null | awk '{print \"  \"\$0}'
    [ -f /data_persist/splim_udpd_start.sh ] || echo '  ! launcher missing'

    echo
    echo '─── 7. daemon log tail (last 15 lines) ───'
    L=\$(ls -t /mnt/data_persist/log/splim_v*.log 2>/dev/null | head -1)
    if [ -n \"\$L\" ]; then
      echo \"  \$L:\"
      tail -15 \"\$L\" | sed 's/^/    /'
    else
      echo '  ! no splim_v*.log found — daemon never wrote'
    fi

    echo
    echo '─── 8. RTC (patched shim rejects future-ts; check the clock is sane) ───'
    date | awk '{print \"  \"\$0}'
  "
}

# ============================================================================
#  ADVANCED — menu F
# ============================================================================
# Quiet variant used internally by validate()'s auto-fix path — no narration,
# just (re)start the daemon via the same launcher path the shim itself uses.
force_start_daemon_quiet() {
  # nohup, NOT setsid: the shim's own on-demand spawn (baked into the .so)
  # uses `setsid sh ... &`, and the daemon has never once been observed to
  # auto-start via that path in testing. `nohup /path/to/script &` is the
  # exact invocation manually confirmed to work (spawned {splim_udpd} +
  # dbus-monitor successfully) — use that proven path instead of guessing
  # setsid is fine on this BusyBox build.
  # Plain (no -f) pkill/pgrep — see the big comment on wipe_speed_mod() for
  # why `-f` here would make the command SIGKILL itself mid-script.
  ssh_cmd_retry 2 '
    pkill -9 splim_bridge 2>/dev/null
    kill -9 $(pgrep splim_udpd) 2>/dev/null
    rm -f /mnt/data_persist/splim /data_persist/splim
    sleep 1
    nohup /data_persist/splim_udpd_start.sh >/tmp/splim_launcher.log 2>&1 &
    true
  ' >/dev/null 2>&1
}

# Force-restart the speed-mirror daemon, with full narration. Useful when the
# shim's on-demand launch never fired (e.g. no CarPlay-nav session yet) or the
# daemon crashed and the shim's throttled retry hasn't kicked in.
force_start_daemon() {
  hdr "Force-restart speed-mirror daemon"
  # Wrapped in ssh_cmd_retry as extra insurance against a genuinely dropped
  # SSH link. Plain (no -f) pkill/pgrep below — see wipe_speed_mod()'s
  # comment: `-f` would match this very command's OWN full cmdline text
  # (which literally contains the words "splim_bridge"/"splim_udpd") and
  # SIGKILL the script that's running it, mid-line, with zero output. That
  # self-inflicted kill — not Wi-Fi flakiness — is why this always died
  # right after the first echo in every previous test.
  local out
  out=$(ssh_cmd_retry 2 '
    echo "─── killing anything old ───"
    pkill -9 splim_bridge 2>/dev/null
    pkill -9 splim_udpd    2>/dev/null
    kill -9 $(pgrep splim_udpd) 2>/dev/null
    sleep 1

    echo "─── clearing stale splim file (ts from previous boot) ───"
    rm -f /mnt/data_persist/splim /data_persist/splim
    rm -f /tmp/splim_v*_last /tmp/splim_v*_cache
    rm -rf /tmp/splim_v*_cache

    echo "─── starting via launcher (nohup — proven to work; the shims own setsid-based spawn never has) ───"
    if [ ! -x /data_persist/splim_udpd_start.sh ]; then
      echo "  ! /data_persist/splim_udpd_start.sh missing or not executable — install first (menu 4)"
      exit 1
    fi
    if [ ! -x /data_persist/cp-hud-mod/splim_udpd ]; then
      echo "  ! /data_persist/cp-hud-mod/splim_udpd missing — re-install (menu 4 or X) to deploy it"
      exit 1
    fi
    nohup /data_persist/splim_udpd_start.sh >/tmp/splim_launcher.log 2>&1 &
    sleep 3

    echo "─── after 3 s ───"
    DP=$(ps | grep -v grep | grep -E "splim_bridge|splim_udpd|dbus-monitor")
    if [ -n "$DP" ]; then
      echo "$DP" | sed "s/^/  /"
    else
      echo "  ! still no splim/dbus-monitor processes running"
    fi
    echo
    echo "  launcher stderr: /tmp/splim_launcher.log"
    tail -20 /tmp/splim_launcher.log 2>/dev/null | sed "s/^/    /"
    echo
    L=$(ls -t /mnt/data_persist/log/splim_v*.log 2>/dev/null | head -1)
    if [ -n "$L" ]; then
      echo "  latest daemon log: $L"
      tail -5 "$L" | sed "s/^/    /"
    fi
    echo
    echo "  splim file now:"
    for P in /mnt/data_persist/splim /data_persist/splim; do
      if [ -e "$P" ]; then
        printf "    %s → " "$P"; cat "$P" 2>/dev/null; echo
      else
        echo "    $P → still absent (waiting for a real HUD frame on d-bus)"
      fi
    done
  ')
  printf '%s\n' "$out"
  echo
  info "now start CarPlay navigation in the car and watch option T (live tail) —"
  info "you should see 'got splim=NN unit=2' lines each time a speed sign is captured."
}

# ============================================================================
#  ADVANCED — menu T
# ============================================================================
# Live-tail whichever splim_v*.log the daemon is writing (useful after mod install)
tail_log() {
  hdr "Live tail splim log (Ctrl+C to exit)"
  $SSH 'ls -t /mnt/data_persist/log/splim_v*.log 2>/dev/null | head -1 | xargs -r tail -F 2>/dev/null'
}

# ============================================================================
#  ADVANCED — menu C
# ============================================================================
# Dump the SHIM's own debug log (/tmp/carplay_bridge.log — a debug build of
# libpatch-blmjcicarplay.so writes here). This is a DIFFERENT subsystem from
# the speed-mirror daemon: it covers the maneuver arrow/distance/street the
# shim itself sends to the HUD via hud_send(). Useful when the arrow appears
# once but never updates to the next turn — this log shows every
# SetHUDDisplayMsgReq / SetHUD_Display_Msg2 attempt and any rc!=0 failures
# on send/clear. Lives in /tmp (tmpfs) so it only covers the CURRENT boot.
carplay_log() {
  hdr "CarPlay HUD arrow debug log (/tmp/carplay_bridge.log)"
  $SSH '
    if [ ! -s /tmp/carplay_bridge.log ]; then
      echo "  (empty or missing — either no CarPlay nav session has run yet this"
      echo "   boot, or this .so build does not emit debug output)"
      exit 0
    fi
    echo "  size: $(wc -c < /tmp/carplay_bridge.log) bytes"
    echo
    echo "  distinct maneuver/street lines seen (more than one means the shim"
    echo "  IS sending updates — a still HUD may just be waiting for the next turn):"
    grep -iE "maneuver|street|distance|nextManeuver" /tmp/carplay_bridge.log 2>/dev/null | sort -u | sed "s/^/    /" | head -30
    echo
    echo "  any send/clear failures (rc!=0 — a real transmission problem):"
    grep -iE "failed rc=|exception swallowed|conn_create failed|conn_connect failed" /tmp/carplay_bridge.log 2>/dev/null | sed "s/^/    /" | head -20
    echo
    echo "  last 30 lines:"
    tail -30 /tmp/carplay_bridge.log | sed "s/^/    /"
  '
}

# ============================================================================
#  UTILITY — menu 9
# ============================================================================
# Preflight: SSH check
check() {
  hdr "SSH check"
  if ping -c 2 -t 2 192.168.53.1 >/dev/null 2>&1 && \
     $SSH 'uname -a && uptime' 2>/dev/null; then
    ok "SSH ok"
  else
    err "SSH not reachable. Insert USB, tap SSH in XSS menu on CMU."
    return 1
  fi
}

# ============================================================================
#  MENU
# ============================================================================
advanced_menu() {
  while :; do
    echo
    printf "%s══════════════════════════════════════════════════════════%s\n" "$C_BY" "$C_0"
    printf "%s  ADVANCED — not needed for normal use%s\n" "$C_BY" "$C_0"
    printf "%s══════════════════════════════════════════════════════════%s\n" "$C_BY" "$C_0"
    printf "  %sV%s   Validate installation  (also runs by itself after install)\n" "$C_BOLD" "$C_0"
    printf "  %sS%s   Check SSH connection\n"                                       "$C_BOLD" "$C_0"
    printf "  %sD%s   Full diagnostic dump  (verbose)\n"                            "$C_BOLD" "$C_0"
    printf "\n  %sOlder CarPlay-only patches%s\n" "$C_DIM" "$C_0"
    printf "  %sL%s   Install ilshyma HUD Patch v16  (CarPlay only)\n"             "$C_BOLD" "$C_0"
    printf "  %sP%s   Install PURE KidMixer Patch  (CarPlay only, no speed-limit fix)\n" "$C_BOLD" "$C_0"
    printf "  %sX%s   Install legacy pre-v16 mod .so  (speed-limit fallback)\n"    "$C_BOLD" "$C_0"
    printf "  %sK%s   KidMixer rollback  (old v16 rollback path)\n"                "$C_BOLD" "$C_0"
    printf "  %sF%s   Force-start v16 speed daemon\n"                              "$C_BOLD" "$C_0"
    printf "  %sT%s   Live-tail v16 daemon log\n"                                  "$C_BOLD" "$C_0"
    printf "  %sC%s   CarPlay HUD arrow debug log\n"                               "$C_BOLD" "$C_0"
    printf "\n  %s0%s   Back\n" "$C_BOLD" "$C_0"
    echo
    printf "> "
    read C
    case "$C" in
      V|v) check && validate ;;
      S|s) check ;;
      D|d) check && diagnose ;;
      L|l) check && install_mod ;;
      P|p) check && install_pure ;;
      X|x) check && install_mod_legacy ;;
      K|k) check && rollback ;;
      F|f) check && force_start_daemon ;;
      T|t) check && tail_log ;;
      C|c) check && carplay_log ;;
      0|q|Q|"") return 0 ;;
      *) warn "invalid" ;;
    esac
  done
}

while :; do
  echo
  printf "%s Mazda CMU HUD toolkit — CarPlay + Android Auto %s\n" "$C_BOLD" "$C_0"
  printf "%s══════════════════════════════════════════════════════════%s\n" "$C_BG" "$C_0"
  printf "  %s1%s   Create USB stick  (SSH unlock + HUD patch on one stick)\n" "$C_BOLD" "$C_0"
  printf "  %s2%s   Backup CMU\n"                                               "$C_BOLD" "$C_0"
  printf "  %s3%s   Rollback  (remove every HUD patch, back to stock)\n"        "$C_BOLD" "$C_0"
  printf "  %s4%s   Install HUD patch  (CarPlay + Android Auto)\n"              "$C_BOLD" "$C_0"
  printf "%s══════════════════════════════════════════════════════════%s\n" "$C_BG" "$C_0"
  printf "  %sA%s   Advanced options\n" "$C_BOLD" "$C_0"
  printf "  %s0%s   Exit\n"             "$C_BOLD" "$C_0"
  echo
  printf "> "
  read C
  case "$C" in
    1) make_usb ;;
    2) check && backup ;;
    3) check && rollback_all ;;
    4) check && install_unified ;;
    A|a) advanced_menu ;;
    0|q|Q|"") exit 0 ;;
    *) warn "invalid" ;;
  esac
done
