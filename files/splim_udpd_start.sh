#!/bin/sh
# Called by libpatch-blmjcicarplay.so:
#   pgrep splim_udpd >/dev/null 2>&1 || setsid sh /data_persist/splim_udpd_start.sh >/dev/null 2>&1 &
#
# BusyBox-compatible: NO `exec -a` (that's a bash extension the CMU shell rejects
# with "exec: -a: not found"). Instead, the daemon script is installed as
# /data_persist/cp-hud-mod/splim_udpd (no .sh suffix), so argv[0] carries the
# name "splim_udpd" that the shim's `pgrep splim_udpd` matches.
exec /data_persist/cp-hud-mod/splim_udpd
